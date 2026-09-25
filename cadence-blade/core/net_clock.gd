class_name NetClock
extends RefCounted

# net_clock.gd -- Estimates a delayed copy of a remote peer's simulation clock, used
# as the read head for NetInterp buffers.
#
# Model: for a packet sent at sender time S and arriving at local time L, the sample
# offset (S - L) equals the true clock offset minus that packet's latency. Latency is
# always >= 0, so the MAXIMUM observed offset is the best estimate of the true offset
# -- the fastest packet is the least-delayed reference. We ratchet the estimate up
# instantly on a faster packet and let it decay slowly, which makes this a min-latency
# filter with a self-sizing window. `delay` then only has to absorb jitter ABOVE the
# minimum latency plus one packet interval, not absolute latency.
#
# The playback head is a separate rate-limited integrator, never written directly from
# a packet, so a correction is a brief small speed change rather than a visible pop.

## |offset error| above this is a real discontinuity (peer restart, long stall).
## Snap rather than warp.
const RESYNC_SNAP: float = 0.25
## Proportional gain pulling the play head toward its target. ~0.4 s convergence.
const CATCHUP_GAIN: float = 3.0
## The play head never runs slower than 0.90x or faster than 1.10x. This is the single
## most important constant here: it is what keeps resync corrections below the
## perceptual threshold instead of reintroducing the stutter we are removing.
const MAX_WARP: float = 0.10
## Seconds per second the offset estimate decays. Covers crystal drift (~100 ppm worst
## case) with orders of magnitude to spare, and sizes the min-latency window to ~1 s.
const OFFSET_DECAY: float = 0.01
## The read head may never run more than one frame past the newest sample held.
const NEWEST_CEILING: float = 0.02

## Interpolation delay in seconds. Set by the owner, per stream.
var delay: float = 0.085
var started: bool = false
var play_time: float = 0.0

var _offset: float = 0.0
var _newest_ts: float = 0.0


## Call once per received packet that carries a sender timestamp.
func on_packet(sender_ts: float, local_now: float) -> void:
	var s: float = sender_ts - local_now
	if sender_ts > _newest_ts:
		_newest_ts = sender_ts
	if not started:
		started = true
		_offset = s
		play_time = local_now + _offset - delay
		return
	if absf(s - _offset) > RESYNC_SNAP:
		# Sender restarted, or a multi-second stall. Rebase rather than warp.
		_offset = s
		_newest_ts = sender_ts
		play_time = local_now + _offset - delay
		return
	if s > _offset:
		# Arrived faster than anything recently, so the old estimate was too
		# pessimistic. Correcting up immediately is mandatory: a too-low offset
		# means the read head sits past the buffer and starves permanently.
		_offset = s


## Call exactly ONCE per frame per clock. Returns the sender-clock time to sample at.
## Calling this more than once per frame runs playback at a multiple of real speed and
## permanently starves the buffer.
func advance(delta: float, local_now: float) -> float:
	if not started:
		return 0.0
	_offset -= OFFSET_DECAY * delta
	play_time += delta
	var target: float = local_now + _offset - delay
	var err: float = target - play_time
	if absf(err) > RESYNC_SNAP:
		play_time = target
	else:
		play_time += clampf(err * CATCHUP_GAIN, -MAX_WARP, MAX_WARP) * delta
	# Under normal operation newest_ts is `delay` ahead of the head so this never
	# binds; it exists so a mis-estimated offset degrades into "hold last position"
	# rather than "extrapolate into orbit".
	play_time = minf(play_time, _newest_ts + NEWEST_CEILING)
	return play_time


func reset() -> void:
	started = false
	play_time = 0.0
	_offset = 0.0
	_newest_ts = 0.0

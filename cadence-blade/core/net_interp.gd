class_name NetInterp
extends RefCounted

# net_interp.gd -- Timestamped position buffer with two-sample linear interpolation.
# Shared by remote player puppets (run_manager.gd) and joiner-side enemies
# (enemy_spawner.gd) so there is exactly one copy of this logic in the project.
#
# Timestamps are SENDER simulation time (physics frame / physics_ticks_per_second),
# never arrival time. The read head comes from a NetClock.

## Buffer cap. At 20 Hz this is 0.6 s of history -- far more than the interpolation
## delay needs, and enough to survive a burst of dropped packets.
const MAX_SAMPLES: int = 12
## A gap larger than this between two samples is a teleport (respawn, dash, desync).
## Never lerp across it.
const TELEPORT_DISTANCE: float = 300.0
## How far past the newest sample sample() extrapolates before holding. One 60 Hz
## frame, no more -- on a rubber-banding link a hold looks better than an overshoot.
const MAX_EXTRAPOLATION: float = 0.02

var _t: Array[float] = []
var _p: Array[Vector2] = []
var has_data: bool = false
## Set by sample(): true when the read head ran past the newest sample we hold.
## Log this rather than guessing when tuning the interpolation delay.
var starving: bool = false


func push(ts: float, pos: Vector2) -> void:
	var n: int = _t.size()
	if n > 0:
		if ts < _t[n - 1] - 1.0:
			clear()  # Sender clock went backwards (peer restarted) -- start over.
		elif ts <= _t[n - 1]:
			# Duplicate or stale tick: overwrite the tail, never append a
			# zero-duration segment (that would read as an instant jump).
			_t[n - 1] = ts
			_p[n - 1] = pos
			return
	_t.append(ts)
	_p.append(pos)
	has_data = true
	while _t.size() > MAX_SAMPLES:
		_t.remove_at(0)
		_p.remove_at(0)


func clear() -> void:
	_t.clear()
	_p.clear()
	has_data = false
	starving = false


func newest_time() -> float:
	return _t[_t.size() - 1] if not _t.is_empty() else 0.0


func newest_pos() -> Vector2:
	return _p[_p.size() - 1] if not _p.is_empty() else Vector2.ZERO


## Position at render_time, expressed on the sender's clock (already delayed by NetClock).
func sample(render_time: float) -> Vector2:
	starving = false
	var n: int = _t.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1:
		return _p[0]

	# Read head fell behind the buffer (long stall, then resume): show the oldest.
	if render_time <= _t[0]:
		return _p[0]

	# Read head ran past the newest sample: brief extrapolation, then hold.
	if render_time >= _t[n - 1]:
		starving = true
		var over: float = render_time - _t[n - 1]
		if over > MAX_EXTRAPOLATION:
			return _p[n - 1]
		var span_last: float = _t[n - 1] - _t[n - 2]
		if span_last <= 0.0001:
			return _p[n - 1]
		var step: Vector2 = _p[n - 1] - _p[n - 2]
		if step.length() > TELEPORT_DISTANCE:
			return _p[n - 1]
		return _p[n - 1] + (step / span_last) * over

	# Walk back from the newest end; the buffer is tiny so this stays cheap.
	for i in range(n - 1, 0, -1):
		if render_time >= _t[i - 1]:
			var span: float = _t[i] - _t[i - 1]
			if span <= 0.0001:
				return _p[i]
			var a: Vector2 = _p[i - 1]
			var b: Vector2 = _p[i]
			if a.distance_to(b) > TELEPORT_DISTANCE:
				return b  # Teleport: jump, never lerp.
			return a.lerp(b, (render_time - _t[i - 1]) / span)
	return _p[0]

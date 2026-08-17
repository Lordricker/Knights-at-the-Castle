# webrtc_manager.gd
# Raw WebRTC data-channel transport + Firebase signaling.
#
# Architecture:
#   Two WebRTCDataChannels (negotiated, fixed ids):
#       "reliable"   — ordered, guaranteed (spawn/despawn/gameover events)
#       "unreliable" — unreliable ordered  (input + state snapshots)
#   NO WebRTCMultiplayerPeer, NO @rpc, NO multiplayer.get_unique_id().
#   Host runs all physics; joiner sends input and receives state.
#   Firebase is signaling only — no gameplay traffic touches Firebase.
#
# Public API:
#   send_reliable(d: Dictionary)   — reliable ordered packet
#   send_unreliable(d: Dictionary) — unreliable ordered packet
#
# Signals:
#   connected()                    — both data channels are open
#   disconnected()                 — peer dropped / connection failed
#   packet_received(d: Dictionary) — inbound packet (either channel)
#   debug_status(msg: String)      — live log line for UI / console
#
# Add as autoload: Project > Project Settings > Autoload
#   Name: WebRTCManager   Path: res://core/webrtc_manager.gd

extends Node

signal connected()
signal disconnected()
signal packet_received(data: Dictionary)
signal connection_failed(reason: String)
## Emitted at each signaling step so the UI can display live progress.
signal debug_status(message: String)

enum State { IDLE, SIGNALING, CONNECTED }
var state: State = State.IDLE

const ICE_SERVERS: Array = [
	{"urls": "stun:stun.relay.metered.ca:80"},
	{"urls": "turn:global.relay.metered.ca:80",                    "username": "28a7d695fb2888e9055f8a30", "credential": "fGphVlenByKERTrN"},
	{"urls": "turn:global.relay.metered.ca:80?transport=tcp",      "username": "28a7d695fb2888e9055f8a30", "credential": "fGphVlenByKERTrN"},
	{"urls": "turn:global.relay.metered.ca:443",                   "username": "28a7d695fb2888e9055f8a30", "credential": "fGphVlenByKERTrN"},
	{"urls": "turns:global.relay.metered.ca:443?transport=tcp",    "username": "28a7d695fb2888e9055f8a30", "credential": "fGphVlenByKERTrN"},
]

## How often (seconds) to poll Firebase for the remote SDP and ICE candidates.
const POLL_INTERVAL: float = 0.8
## How often (seconds) to batch and write locally collected ICE candidates to Firebase.
const ICE_BATCH_INTERVAL: float = 0.5
## Seconds before giving up on a connection attempt.
const CONNECT_TIMEOUT: float = 40.0

var _is_host: bool = false
var _session_id: String = ""
var _peer_conn: WebRTCPeerConnection = null
var _ch_reliable:   WebRTCDataChannel = null
var _ch_unreliable: WebRTCDataChannel = null

var _poll_timer: float = 0.0
var _ice_batch_timer: float = 0.0
var _connect_timer: float = 0.0
var _debug_timer: float = 0.0
## Total local ICE candidates generated this session.
var _ice_local_count: int = 0
## Last known connection/gathering states -- used to detect transitions.
var _last_conn_state: int = -1
var _last_gather_state: int = -1

var _offer_sent: bool = false
var _offer_received: bool = false
var _answer_sent: bool = false
var _answer_received: bool = false

## Local ICE candidates pending the next batch flush to Firebase.
var _pending_local_ice: Array[Dictionary] = []
## All local ICE candidates accumulated this session (written in full each flush).
var _all_local_ice: Array[Dictionary] = []
## Count of remote ICE candidates we have already applied.
var _remote_ice_applied: int = 0
## Set to true once set_remote_description() has been called for this side.
## addIceCandidate() must not be called before the remote SDP is accepted.
var _remote_sdp_set: bool = false
## ICE candidates received before remote SDP was ready; applied once it is.
var _buffered_remote_ice: Array[Dictionary] = []


func _ready() -> void:
	GameManager.connect_webrtc_signals()
	set_process(false)


# ── Public ─────────────────────────────────────────────────────────────────────

## Host side: set up the WebRTC connection and wait for a joiner's offer.
func host_session(session_id: String) -> void:
	if state != State.IDLE:
		push_warning("WebRTCManager: host_session called while not IDLE")
		return
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the GDExtension.")
		return
	_session_id = session_id
	_is_host = true
	state = State.SIGNALING
	_dbg("HOST: Starting signaling for session '%s'" % session_id)
	_setup_webrtc()
	set_process(true)


## Joiner side: create an offer and send it to the host.
func join_session(session_id: String) -> void:
	if state != State.IDLE:
		push_warning("WebRTCManager: join_session called while not IDLE")
		return
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the GDExtension.")
		return
	_session_id = session_id
	_is_host = false
	state = State.SIGNALING
	_dbg("JOINER: Starting signaling for session '%s'" % session_id)
	_setup_webrtc()
	_dbg("JOINER: Calling create_offer()...")
	var offer_err: int = _peer_conn.create_offer()
	if offer_err != OK:
		push_error("WebRTCManager: create_offer() failed: %d" % offer_err)
		connection_failed.emit("create_offer() error %d" % offer_err)
		_cleanup(false)
		return
	set_process(true)


## Send a reliable ordered packet (spawn/despawn/gameover/quit events).
func send_reliable(data: Dictionary) -> void:
	if _ch_reliable == null or _ch_reliable.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		push_warning("WebRTCManager: reliable channel not open — packet dropped")
		return
	_ch_reliable.put_packet(JSON.stringify(data).to_utf8_buffer())


## Send an unreliable ordered packet (input/state snapshots — loss is acceptable).
func send_unreliable(data: Dictionary) -> void:
	if _ch_unreliable == null or _ch_unreliable.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		return  # silently drop; caller will retry next frame
	_ch_unreliable.put_packet(JSON.stringify(data).to_utf8_buffer())


## Disconnect and return to IDLE.
func disconnect_peer() -> void:
	if GameManager.is_host and GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
	_cleanup(false)


# ── WebRTC setup ───────────────────────────────────────────────────────────────

func _setup_webrtc() -> void:
	_peer_conn = WebRTCPeerConnection.new()
	var init_err: int = _peer_conn.initialize({"iceServers": ICE_SERVERS})
	if init_err != OK:
		push_error("WebRTCManager: initialize() failed: %d" % init_err)
		connection_failed.emit("WebRTC init error %d" % init_err)
		_cleanup(false)
		return
	_dbg("WebRTCPeerConnection initialized with %d ICE servers" % ICE_SERVERS.size())

	_peer_conn.session_description_created.connect(_on_sdp_created)
	_peer_conn.ice_candidate_created.connect(_on_ice_created)
	# Joiner receives host-created channels via this signal.
	_peer_conn.data_channel_received.connect(_on_data_channel_received)

	if _is_host:
		# Both sides create negotiated channels by id so no extra signaling is needed.
		var opt_r: Dictionary = {"negotiated": true, "id": 0, "ordered": true}
		var opt_u: Dictionary = {"negotiated": true, "id": 1, "ordered": true, "maxRetransmits": 0}
		_ch_reliable   = _peer_conn.create_data_channel("reliable",   opt_r)
		_ch_unreliable = _peer_conn.create_data_channel("unreliable", opt_u)
		_dbg("HOST: negotiated data channels created (ids 0=reliable 1=unreliable)")
	else:
		# Joiner also creates its end of the negotiated channels.
		var opt_r: Dictionary = {"negotiated": true, "id": 0, "ordered": true}
		var opt_u: Dictionary = {"negotiated": true, "id": 1, "ordered": true, "maxRetransmits": 0}
		_ch_reliable   = _peer_conn.create_data_channel("reliable",   opt_r)
		_ch_unreliable = _peer_conn.create_data_channel("unreliable", opt_u)
		_dbg("JOINER: negotiated data channels created (ids 0=reliable 1=unreliable)")


# ── Process loop ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _peer_conn == null:
		return
	_peer_conn.poll()

	# Drain inbound packets from both channels (works in SIGNALING and CONNECTED).
	_poll_channels()

	_connect_timer += delta

	# Timeout guard during signaling.
	if state == State.SIGNALING and _connect_timer >= CONNECT_TIMEOUT:
		_print_debug_state()
		connection_failed.emit("Connection timed out after %.0f seconds" % CONNECT_TIMEOUT)
		_cleanup(true)
		return

	# Detect and log WebRTC state transitions.
	var conn_names: Array = ["new", "connecting", "connected", "disconnected", "FAILED", "closed"]
	var gather_names: Array = ["new", "gathering", "complete"]
	var cs: int = _peer_conn.get_connection_state()
	var gs: int = _peer_conn.get_gathering_state()
	if cs != _last_conn_state:
		_last_conn_state = cs
		var cn: String = conn_names[cs] if cs < conn_names.size() else str(cs)
		_dbg(">>> Connection state changed: %s" % cn)
		if cs == 4:  # FAILED
			_print_debug_state()
			connection_failed.emit("ICE connection FAILED")
			_cleanup(true)
			return
		if (cs == 3 or cs == 5) and state == State.CONNECTED:  # disconnected/closed
			_cleanup(true)
			return
	if gs != _last_gather_state:
		_last_gather_state = gs
		var gn: String = gather_names[gs] if gs < gather_names.size() else str(gs)
		_dbg(">>> ICE gathering state: %s (local candidates so far: %d)" % [gn, _ice_local_count])

	if state == State.SIGNALING:
		_debug_timer += delta
		if _debug_timer >= 5.0:
			_debug_timer = 0.0
			_print_debug_state()

		_ice_batch_timer += delta
		if _ice_batch_timer >= ICE_BATCH_INTERVAL:
			_ice_batch_timer = 0.0
			_flush_local_ice()

		_poll_timer += delta
		if _poll_timer >= POLL_INTERVAL:
			_poll_timer = 0.0
			_do_signal_poll()

		# Check whether both data channels opened once the PeerConnection is up.
		if cs == 2:  # "connected"
			_check_channels_open()


## Drain any waiting packets from both data channels and emit packet_received.
func _poll_channels() -> void:
	if _ch_reliable != null and _ch_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while _ch_reliable.get_available_packet_count() > 0:
			_parse_and_emit(_ch_reliable.get_packet())
	if _ch_unreliable != null and _ch_unreliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while _ch_unreliable.get_available_packet_count() > 0:
			_parse_and_emit(_ch_unreliable.get_packet())


func _parse_and_emit(raw: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) == OK:
		packet_received.emit(json.data)


## Transition to CONNECTED once both data channels are open.
func _check_channels_open() -> void:
	var r_open: bool = _ch_reliable   != null and _ch_reliable.get_ready_state()   == WebRTCDataChannel.STATE_OPEN
	var u_open: bool = _ch_unreliable != null and _ch_unreliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN
	if r_open and u_open:
		state = State.CONNECTED
		_dbg("Both data channels OPEN — P2P ready after %.1fs" % _connect_timer)
		FirebaseClient.delete_signal_data(_session_id, func(_c, _d): pass)
		connected.emit()


# ── Data channel received (joiner only, non-negotiated fallback) ───────────────

func _on_data_channel_received(channel: WebRTCDataChannel) -> void:
	# With negotiated channels this fires as a secondary notification; we already
	# hold references from create_data_channel() so we can safely ignore it.
	_dbg("data_channel_received: '%s' (already stored via negotiated id)" % channel.get_label())


func _do_signal_poll() -> void:
	if state != State.SIGNALING:
		return

	# Host waits for joiner's offer; joiner waits for host's answer.
	if _is_host and not _offer_received:
		FirebaseClient.read_signal_data(_session_id, "offer", _on_received_offer)
	elif not _is_host and not _answer_received:
		FirebaseClient.read_signal_data(_session_id, "answer", _on_received_answer)

	# Only poll for the remote ICE candidates after our remote description is set.
	# Applying ICE before setRemoteDescription() resolves silently drops candidates.
	if _remote_sdp_set:
		var remote_ice_key: String = "ice_joiner" if _is_host else "ice_host"
		FirebaseClient.read_signal_data(_session_id, remote_ice_key, _on_received_ice_batch)


# ── SDP exchange ───────────────────────────────────────────────────────────────

## Called by WebRTCPeerConnection when the local SDP offer or answer is ready.
func _on_sdp_created(type: String, sdp: String) -> void:
	_peer_conn.set_local_description(type, sdp)
	# Joiner writes "offer"; host writes "answer".
	if not _is_host and not _offer_sent:
		_offer_sent = true
		_dbg("JOINER: Local SDP ready (type=%s, %d chars) -- writing offer to Firebase" % [type, sdp.length()])
		FirebaseClient.write_signal_data(_session_id, "offer", {"type": type, "sdp": sdp},
			func(c: int, _d: Variant) -> void:
				if c == 200:
					_dbg("JOINER: Offer written OK (HTTP 200) -- waiting for host answer")
				else:
					_dbg("JOINER: WARNING -- offer write returned HTTP %d" % c))
	elif _is_host and not _answer_sent:
		_answer_sent = true
		_dbg("HOST: Local SDP ready (type=%s, %d chars) -- writing answer to Firebase" % [type, sdp.length()])
		FirebaseClient.write_signal_data(_session_id, "answer", {"type": type, "sdp": sdp},
			func(c: int, _d: Variant) -> void:
				if c == 200:
					_dbg("HOST: Answer written OK (HTTP 200) -- waiting for ICE to settle")
				else:
					_dbg("HOST: WARNING -- answer write returned HTTP %d" % c))


func _on_received_offer(_code: int, data: Variant) -> void:
	if _offer_received or data == null or not (data is Dictionary) or not data.has("sdp"):
		return
	_offer_received = true
	_dbg("HOST: Received joiner offer (%d chars) -- setting remote description" % (data["sdp"] as String).length())
	var set_err: int = _peer_conn.set_remote_description(data.get("type", "offer"), data["sdp"])
	if set_err != OK:
		push_error("WebRTCManager: set_remote_description(offer) failed: %d" % set_err)
		_dbg("HOST: ERROR set_remote_description failed: %d" % set_err)
	# Flag that the remote SDP is now set -- ICE candidates can be applied safely.
	_remote_sdp_set = true
	_dbg("HOST: Remote SDP set -- applying %d buffered ICE candidates (answer auto-created by set_remote_description)" % _buffered_remote_ice.size())
	_apply_buffered_ice()
	# Immediately poll for the joiner's ICE candidates -- don't wait for the next timer tick.
	_poll_timer = 0.0
	_do_signal_poll()
	# NOTE: set_remote_description() with an offer automatically fires session_description_created
	# with the answer -- no create_answer() call needed (it doesn't exist on WebRTCPeerConnectionJS).


func _on_received_answer(_code: int, data: Variant) -> void:
	if _answer_received or data == null or not (data is Dictionary) or not data.has("sdp"):
		return
	_answer_received = true
	_dbg("JOINER: Received host answer (%d chars) -- setting remote description" % (data["sdp"] as String).length())
	var set_err: int = _peer_conn.set_remote_description(data.get("type", "answer"), data["sdp"])
	if set_err != OK:
		push_error("WebRTCManager: set_remote_description(answer) failed: %d" % set_err)
		_dbg("JOINER: ERROR set_remote_description failed: %d" % set_err)
	# Flag that the remote SDP is now set -- ICE candidates can be applied safely.
	_remote_sdp_set = true
	_dbg("JOINER: Remote SDP set -- applying %d buffered ICE candidates" % _buffered_remote_ice.size())
	_apply_buffered_ice()
	# Immediately poll for the host's ICE candidates -- don't wait for the next timer tick.
	_poll_timer = 0.0
	_do_signal_poll()


# ── ICE candidate exchange ─────────────────────────────────────────────────────

## Called by WebRTCPeerConnection for each locally generated ICE candidate.
func _on_ice_created(media: String, index: int, name: String) -> void:
	var candidate := {"media": media, "index": index, "name": name}
	_pending_local_ice.append(candidate)
	_all_local_ice.append(candidate)
	_ice_local_count += 1
	# Parse the candidate type from the SDP string (host / srflx / relay).
	var ctype: String = "unknown"
	for part in name.split(" "):
		if part == "host" or part == "srflx" or part == "relay" or part == "prflx":
			ctype = part
			break
	_dbg("ICE #%d: type=%s media=%s" % [_ice_local_count, ctype, media])


## Write all accumulated local ICE candidates to Firebase (single overwrite -- no read needed).
func _flush_local_ice() -> void:
	if _pending_local_ice.is_empty():
		return
	var flush_count: int = _pending_local_ice.size()
	_pending_local_ice.clear()
	var my_ice_key: String = "ice_host" if _is_host else "ice_joiner"
	_dbg("Flushing %d new ICE candidates to Firebase (total: %d)" % [flush_count, _all_local_ice.size()])
	# Overwrite with the full running list -- remote only applies candidates it hasn't seen yet.
	FirebaseClient.write_signal_data(_session_id, my_ice_key,
		{"candidates": _all_local_ice},
		func(c: int, _rd: Variant) -> void:
			if c != 200:
				_dbg("WARNING: ICE flush returned HTTP %d" % c))


## Apply any new remote ICE candidates we haven't seen yet.
## If the remote description isn't set yet, buffer candidates until it is.
func _on_received_ice_batch(_code: int, data: Variant) -> void:
	if data == null or not (data is Dictionary) or not data.has("candidates"):
		return
	var candidates: Array = data["candidates"]
	var new_count: int = candidates.size() - _remote_ice_applied
	if not _remote_sdp_set:
		# Store all unseen candidates; _apply_buffered_ice() will apply them later.
		var prev_buffered: int = _buffered_remote_ice.size()
		for i in range(_buffered_remote_ice.size(), candidates.size()):
			var c: Variant = candidates[i]
			if c is Dictionary:
				_buffered_remote_ice.append(c)
		if _buffered_remote_ice.size() > prev_buffered:
			_dbg("Buffering %d remote ICE candidates (remote SDP not set yet)" % _buffered_remote_ice.size())
		return
	if new_count > 0:
		_dbg("Received %d remote ICE candidates, applying %d new (total seen: %d)" % [candidates.size(), new_count, candidates.size()])
	for i in range(_remote_ice_applied, candidates.size()):
		var c: Variant = candidates[i]
		if c is Dictionary and c.has("media") and c.has("index") and c.has("name"):
			_peer_conn.add_ice_candidate(c["media"], int(c["index"]), c["name"])
	_remote_ice_applied = candidates.size()


## Apply ICE candidates that were received before the remote SDP was ready.
func _apply_buffered_ice() -> void:
	for c in _buffered_remote_ice:
		if c.has("media") and c.has("index") and c.has("name"):
			_peer_conn.add_ice_candidate(c["media"], int(c["index"]), c["name"])
			_remote_ice_applied += 1
	_buffered_remote_ice.clear()


# ── Cleanup ────────────────────────────────────────────────────────────────────

func _cleanup(emit_disc: bool) -> void:
	set_process(false)
	state = State.IDLE
	_is_host = false
	_session_id = ""
	_offer_sent = false
	_offer_received = false
	_answer_sent = false
	_answer_received = false
	_pending_local_ice.clear()
	_all_local_ice.clear()
	_remote_ice_applied = 0
	_remote_sdp_set = false
	_buffered_remote_ice.clear()
	_poll_timer = 0.0
	_ice_batch_timer = 0.0
	_connect_timer = 0.0
	_debug_timer = 0.0
	_ice_local_count = 0
	_last_conn_state = -1
	_last_gather_state = -1
	_ch_reliable = null
	_ch_unreliable = null
	if _peer_conn != null:
		_peer_conn.close()
		_peer_conn = null
	if emit_disc:
		disconnected.emit()


# ---- Debug helpers -----------------------------------------------------------

## Print msg to the console AND emit debug_status so the UI can show it.
func _dbg(msg: String) -> void:
	print("[WebRTC] " + msg)
	debug_status.emit(msg)


## Dump the current WebRTC peer connection states to console and UI.
func _print_debug_state() -> void:
	if _peer_conn == null:
		_dbg("[dump] No peer connection object yet")
		return
	var conn_names: Array = ["new", "connecting", "connected", "disconnected", "FAILED", "closed"]
	var gather_names: Array = ["new", "gathering", "complete"]
	var sig_names: Array = ["stable", "have-local-offer", "have-remote-offer", "have-local-pranswer", "have-remote-pranswer", "closed"]
	var cs: int = _peer_conn.get_connection_state()
	var gs: int = _peer_conn.get_gathering_state()
	var ss: int = _peer_conn.get_signaling_state()
	var cn: String = conn_names[cs] if cs < conn_names.size() else str(cs)
	var gn: String = gather_names[gs] if gs < gather_names.size() else str(gs)
	var sn: String = sig_names[ss] if ss < sig_names.size() else str(ss)
	_dbg("[dump t=%.0fs] conn=%s gather=%s sig=%s | offer(sent=%s recv=%s) answer(sent=%s recv=%s) | local_ice=%d remote_ice=%d buffered=%d" % [
		_connect_timer, cn, gn, sn,
		str(_offer_sent), str(_offer_received),
		str(_answer_sent), str(_answer_received),
		_all_local_ice.size(), _remote_ice_applied, _buffered_remote_ice.size()
	])

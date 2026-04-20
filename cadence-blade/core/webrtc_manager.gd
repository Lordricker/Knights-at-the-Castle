# webrtc_manager.gd
# Manages WebRTC peer-to-peer connection using Firebase Realtime Database for signaling.
#
# Once mesh_ready fires, multiplayer.multiplayer_peer is set and all @rpc calls
# in the game work normally through the P2P connection.
#
# LIMITATIONS (HTML5 / browser builds only):
#   WebRTCPeerConnection is only available in HTML5 exports. In the Godot editor
#   (which runs natively on desktop), you need the WebRTC GDExtension to test.
#   See MULTIPLAYER_SETUP.md for details.
#
# Add as autoload: Project > Project Settings > Autoload
#   Name: WebRTCManager   Path: res://core/webrtc_manager.gd

extends Node

signal mesh_ready()
signal connection_failed(reason: String)
signal peer_disconnected(peer_id: int)

enum State { IDLE, SIGNALING, CONNECTED }

var state: State = State.IDLE

const ICE_SERVERS: Array = [
	{"urls": "stun:stun.l.google.com:19302"},
	{"urls": "stun:stun1.l.google.com:19302"},
	{"urls": "stun:stun.cloudflare.com:3478"},
	# Free public TURN relay — required for most mobile and carrier-NAT connections.
	{"urls": "turn:openrelay.metered.ca:80",  "username": "openrelayproject", "credential": "openrelayproject"},
	{"urls": "turn:openrelay.metered.ca:443", "username": "openrelayproject", "credential": "openrelayproject"},
]

## How often (seconds) to poll Firebase for the remote SDP and ICE candidates.
const POLL_INTERVAL: float = 0.8
## How often (seconds) to batch and write locally collected ICE candidates to Firebase.
const ICE_BATCH_INTERVAL: float = 0.5
## Seconds before giving up on a connection attempt.
const CONNECT_TIMEOUT: float = 40.0

var _is_host: bool = false
var _session_id: String = ""
var _rtc_multi: WebRTCMultiplayerPeer = null
var _peer_conn: WebRTCPeerConnection = null

var _poll_timer: float = 0.0
var _ice_batch_timer: float = 0.0
var _connect_timer: float = 0.0

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
	set_process(false)


# ── Public ─────────────────────────────────────────────────────────────────────

## Call after creating a Firebase session. Sets up the WebRTC host side and waits
## for a joiner to send an offer.
func host_session(session_id: String) -> void:
	if state != State.IDLE:
		push_warning("WebRTCManager: host_session called while not IDLE")
		return
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the WebRTC GDExtension for desktop testing.")
		return
	_session_id = session_id
	_is_host = true
	state = State.SIGNALING
	_setup_webrtc()
	set_process(true)


## Call after the player selects a session. Creates an offer and sends it to the host.
func join_session(session_id: String) -> void:
	if state != State.IDLE:
		push_warning("WebRTCManager: join_session called while not IDLE")
		return
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the WebRTC GDExtension for desktop testing.")
		return
	_session_id = session_id
	_is_host = false
	state = State.SIGNALING
	_setup_webrtc()
	# Joiner creates and sends the WebRTC offer.
	var offer_err: int = _peer_conn.create_offer()
	if offer_err != OK:
		push_error("WebRTCManager: create_offer() failed: %d" % offer_err)
		connection_failed.emit("create_offer() error %d" % offer_err)
		_cleanup()
		return
	set_process(true)


## Disconnect and return to IDLE state.
func disconnect_peer() -> void:
	if GameManager.is_host and GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
	_cleanup()


# ── WebRTC setup ───────────────────────────────────────────────────────────────

func _setup_webrtc() -> void:
	_rtc_multi = WebRTCMultiplayerPeer.new()
	if _is_host:
		_rtc_multi.create_server()
	else:
		# Client always receives peer ID 2 in a 2-player session.
		_rtc_multi.create_client(2)

	_peer_conn = WebRTCPeerConnection.new()
	var init_err: int = _peer_conn.initialize({"iceServers": ICE_SERVERS})
	if init_err != OK:
		push_error("WebRTCManager: WebRTCPeerConnection.initialize() failed: %d" % init_err)
		connection_failed.emit("WebRTC init error %d" % init_err)
		_cleanup()
		return

	_peer_conn.session_description_created.connect(_on_sdp_created)
	_peer_conn.ice_candidate_created.connect(_on_ice_created)

	# Host = peer ID 1, joiner = peer ID 2.
	var remote_peer_id: int = 2 if _is_host else 1
	_rtc_multi.add_peer(_peer_conn, remote_peer_id)
	_rtc_multi.peer_connected.connect(_on_rtc_peer_connected)
	_rtc_multi.peer_disconnected.connect(_on_rtc_peer_disconnected)


# ── Process loop ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _rtc_multi != null:
		_rtc_multi.poll()

	_connect_timer += delta
	if state == State.SIGNALING and _connect_timer >= CONNECT_TIMEOUT:
		connection_failed.emit("Connection timed out after %.0f seconds" % CONNECT_TIMEOUT)
		_cleanup()
		return

	_ice_batch_timer += delta
	if _ice_batch_timer >= ICE_BATCH_INTERVAL:
		_ice_batch_timer = 0.0
		_flush_local_ice()

	_poll_timer += delta
	if _poll_timer >= POLL_INTERVAL:
		_poll_timer = 0.0
		_do_signal_poll()


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
		print("WebRTCManager [joiner]: writing offer to Firebase")
		FirebaseClient.write_signal_data(_session_id, "offer", {"type": type, "sdp": sdp},
			func(_c, _d): pass)
	elif _is_host and not _answer_sent:
		_answer_sent = true
		print("WebRTCManager [host]: writing answer to Firebase")
		FirebaseClient.write_signal_data(_session_id, "answer", {"type": type, "sdp": sdp},
			func(_c, _d): pass)


func _on_received_offer(_code: int, data: Variant) -> void:
	if _offer_received or data == null or not (data is Dictionary) or not data.has("sdp"):
		return
	_offer_received = true
	print("WebRTCManager [host]: received offer, setting remote description")
	var set_err: int = _peer_conn.set_remote_description(data.get("type", "offer"), data["sdp"])
	if set_err != OK:
		push_error("WebRTCManager: set_remote_description(offer) failed: %d" % set_err)
	# Flag that the remote SDP is now set — ICE candidates can be applied safely.
	_remote_sdp_set = true
	_apply_buffered_ice()
	# Immediately poll for the joiner's ICE candidates — don't wait for the next timer tick.
	_poll_timer = 0.0
	_do_signal_poll()
	# Creating the answer triggers session_description_created on success.
	var ans_err: int = _peer_conn.create_answer()
	if ans_err != OK:
		push_error("WebRTCManager: create_answer() failed: %d" % ans_err)


func _on_received_answer(_code: int, data: Variant) -> void:
	if _answer_received or data == null or not (data is Dictionary) or not data.has("sdp"):
		return
	_answer_received = true
	print("WebRTCManager [joiner]: received answer, setting remote description")
	_peer_conn.set_remote_description(data.get("type", "answer"), data["sdp"])
	# Flag that the remote SDP is now set — ICE candidates can be applied safely.
	_remote_sdp_set = true
	_apply_buffered_ice()
	# Immediately poll for the host's ICE candidates — don't wait for the next timer tick.
	_poll_timer = 0.0
	_do_signal_poll()


# ── ICE candidate exchange ─────────────────────────────────────────────────────

## Called by WebRTCPeerConnection for each locally generated ICE candidate.
func _on_ice_created(media: String, index: int, name: String) -> void:
	var candidate := {"media": media, "index": index, "name": name}
	_pending_local_ice.append(candidate)
	_all_local_ice.append(candidate)


## Write all accumulated local ICE candidates to Firebase (single overwrite — no read needed).
func _flush_local_ice() -> void:
	if _pending_local_ice.is_empty():
		return
	_pending_local_ice.clear()
	var my_ice_key: String = "ice_host" if _is_host else "ice_joiner"
	# Overwrite with the full running list — remote only applies candidates it hasn't seen yet.
	FirebaseClient.write_signal_data(_session_id, my_ice_key,
		{"candidates": _all_local_ice}, func(_rc, _rd): pass)


## Apply any new remote ICE candidates we haven't seen yet.
## If the remote description isn't set yet, buffer candidates until it is.
func _on_received_ice_batch(_code: int, data: Variant) -> void:
	if data == null or not (data is Dictionary) or not data.has("candidates"):
		return
	var candidates: Array = data["candidates"]
	if not _remote_sdp_set:
		# Store all unseen candidates; _apply_buffered_ice() will apply them later.
		for i in range(_buffered_remote_ice.size(), candidates.size()):
			var c: Variant = candidates[i]
			if c is Dictionary:
				_buffered_remote_ice.append(c)
		return
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


# ── Peer events ────────────────────────────────────────────────────────────────

func _on_rtc_peer_connected(_id: int) -> void:
	if state == State.CONNECTED:
		return
	print("WebRTCManager: peer %d connected — P2P mesh ready!" % _id)
	state = State.CONNECTED
	set_process(false)
	# Assign the WebRTC peer as Godot's multiplayer backend — enables @rpc.
	multiplayer.multiplayer_peer = _rtc_multi
	# Tidy up signaling data from Firebase now that P2P is live.
	FirebaseClient.delete_signal_data(_session_id, func(_c, _d): pass)
	mesh_ready.emit()


func _on_rtc_peer_disconnected(id: int) -> void:
	peer_disconnected.emit(id)
	_cleanup()


# ── Cleanup ────────────────────────────────────────────────────────────────────

func _cleanup() -> void:
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
	# Restore offline multiplayer peer.
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_rtc_multi = null
	_peer_conn = null

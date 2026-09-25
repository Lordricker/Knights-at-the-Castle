# webrtc_manager.gd
# Raw WebRTC data-channel transport + Firebase signaling — STAR topology.
#
# Architecture:
#   The host keeps one PeerLink per joiner slot (2, 3). Each joiner keeps a single
#   PeerLink to the host. Joiners never connect to each other — the host is the
#   sole authority and relays all display state.
#
#   Each link owns two negotiated WebRTCDataChannels (fixed ids):
#       "reliable"   — ordered, guaranteed (spawn/despawn/gameover/purchases/hello)
#       "unreliable" — unreliable ordered  (input + state snapshots)
#   NO WebRTCMultiplayerPeer, NO @rpc, NO multiplayer.get_unique_id().
#
#   Firebase is signaling only. Each joiner slot uses its own namespace:
#       /signaling/{sid}/{slot}/offer | answer | ice_host | ice_joiner
#
# Public API:
#   host_session(session_id)            — (re)arm signaling for every free joiner slot
#   join_session(session_id, my_slot)   — connect to the host as `my_slot`
#   send_reliable(d)   / send_unreliable(d)   — host: broadcast to all links; joiner: to host
#   send_reliable_to(slot, d)                 — host: targeted to one joiner slot
#   disconnect_peer()                         — tear everything down
#
# Signals:
#   connected()                    — this peer has its first open link
#   disconnected()                 — joiner: lost the host / host: lost every link
#   peer_connected(slot)           — a link to `slot` just opened
#   peer_disconnected(slot)        — an open link to `slot` dropped
#   packet_received(data)          — inbound packet; data["_from"] = sender slot
#   connection_failed(reason)      — signaling failed before any link opened
#   debug_status(message)          — live log line for UI / console

extends Node

signal connected()
signal disconnected()
signal peer_connected(slot: int)
signal peer_disconnected(slot: int)
signal packet_received(data: Dictionary)
signal connection_failed(reason: String)
## Emitted at each signaling step so the UI can display live progress.
signal debug_status(message: String)

enum State { IDLE, SIGNALING, CONNECTED }
var state: State = State.IDLE

## STUN/TURN servers come from IceConfig, which fetches short-lived relay credentials
## at runtime — see core/ice_config.gd for why they are no longer listed here.

## Poll interval (seconds) while a mid-handshake link exchanges answer/ICE — kept
## short so connection latency stays low.
const ACTIVE_POLL_INTERVAL: float = 0.8
## Poll interval (seconds) while the host is merely *waiting* for a joiner's offer.
## Longer, to keep idle Firebase traffic on an open public session low.
const IDLE_POLL_INTERVAL: float = 2.5
## How often (seconds) to batch and write locally collected ICE candidates to Firebase.
const ICE_BATCH_INTERVAL: float = 0.5
## Seconds before giving up on a joiner-side connection attempt.
const CONNECT_TIMEOUT: float = 40.0
## Joiner slots the host will accept, lowest first. The host arms only ONE pending
## slot at a time — the next is armed once the current one connects.
const HOST_SLOTS: Array = [2, 3]

var _is_host: bool = false
var _session_id: String = ""
## Joiner: this peer's own slot. Host: always 1.
var _my_slot: int = 1
## Whether this peer is currently hosting / joining (drives re-arm + aggregate state).
var _hosting: bool = false
var _joining: bool = false
## Whether connected() has already been emitted this session.
var _emitted_connected: bool = false

## remote_slot -> PeerLink. Host: entries for joiner slots. Joiner: single entry keyed 1.
var _links: Dictionary = {}


## Per-connection signaling + channel state.
class PeerLink:
	## Host: the joiner's slot. Joiner: 1 (the host).
	var slot: int = 0
	var conn: WebRTCPeerConnection = null
	var ch_reliable: WebRTCDataChannel = null
	var ch_unreliable: WebRTCDataChannel = null

	var offer_sent: bool = false
	var offer_received: bool = false
	var answer_sent: bool = false
	var answer_received: bool = false
	var remote_sdp_set: bool = false

	var pending_local_ice: Array = []
	var all_local_ice: Array = []
	var remote_ice_applied: int = 0
	var buffered_remote_ice: Array = []

	var poll_timer: float = 0.0
	var ice_batch_timer: float = 0.0
	var connect_timer: float = 0.0
	var debug_timer: float = 0.0
	var last_conn_state: int = -1
	var last_gather_state: int = -1

	var is_open: bool = false


func _ready() -> void:
	GameManager.connect_webrtc_signals()
	set_process(false)


# ── Public ─────────────────────────────────────────────────────────────────────

## Host side: (re)arm signaling for every joiner slot that has no open link yet.
## Safe to call repeatedly — used both on session start and after a joiner drops.
func host_session(session_id: String) -> void:
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the GDExtension.")
		return
	_is_host = true
	_my_slot = 1
	_session_id = session_id
	_hosting = true
	_recompute_state()
	# Relay credentials are fetched at runtime. Normally already in hand by now (the
	# fetch starts at boot); if not, wait rather than arm connections without a relay.
	if not IceConfig.is_ready():
		await IceConfig.ensure_ready()
		if not _hosting:
			return  # Player backed out while we waited.
	_arm_next_free_slot()
	set_process(true)


## Host: ensure signaling is armed for EVERY joiner slot that isn't already
## connected. Called on session start and each time a slot connects or drops.
## A joiner is assigned its slot by the lobby (`_free_joiner_slot`), which can be
## 3 while 2 is still free (e.g. slot 2 has a stale players/ entry), so the host
## must poll all free slots — arming only the lowest would leave that joiner
## stuck on "Connecting..." forever because its offer is never read.
func _arm_next_free_slot() -> void:
	if not _hosting:
		return
	for slot in HOST_SLOTS:
		var link: PeerLink = _links.get(slot)
		if link == null:
			_create_link(int(slot))
			_dbg("HOST: armed signaling for slot %d (session '%s')" % [slot, _session_id])


## Joiner side: create an offer for the host under this peer's own slot namespace.
func join_session(session_id: String, my_slot: int = 2) -> void:
	if state != State.IDLE:
		# A previous host/join attempt was left half-open (e.g. the player pressed
		# Back while "Connecting..."). Tear it down so this fresh attempt can start,
		# rather than silently no-op'ing and hanging on "Connecting..." forever.
		push_warning("WebRTCManager: join_session called while not IDLE — cleaning up the stale attempt first")
		_cleanup(false)
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		connection_failed.emit("WebRTCPeerConnection not available — use an HTML5 export or install the GDExtension.")
		return
	_is_host = false
	_my_slot = my_slot
	_session_id = session_id
	_joining = true
	# Claim SIGNALING before the await below so a second join_session() call trips the
	# not-IDLE guard above instead of racing this one.
	state = State.SIGNALING
	_dbg("JOINER(slot %d): starting signaling for session '%s'" % [my_slot, session_id])
	if not IceConfig.is_ready():
		await IceConfig.ensure_ready()
		if not _joining:
			return  # Player backed out while we waited.
	var link := _create_link(1)
	var offer_err: int = link.conn.create_offer()
	if offer_err != OK:
		push_error("WebRTCManager: create_offer() failed: %d" % offer_err)
		connection_failed.emit("create_offer() error %d" % offer_err)
		_cleanup(false)
		return
	_recompute_state()
	set_process(true)


## Host: broadcast to every open link. Joiner: send to the host.
func send_reliable(data: Dictionary) -> void:
	var buf := JSON.stringify(data).to_utf8_buffer()
	for slot in _links:
		var link: PeerLink = _links[slot]
		if link.ch_reliable != null and link.ch_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			link.ch_reliable.put_packet(buf)


## Host only: send a reliable packet to one joiner slot.
func send_reliable_to(slot: int, data: Dictionary) -> void:
	var link: PeerLink = _links.get(slot)
	if link != null and link.ch_reliable != null and link.ch_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		link.ch_reliable.put_packet(JSON.stringify(data).to_utf8_buffer())


## Host: broadcast to every open link. Joiner: send to the host. Loss acceptable.
func send_unreliable(data: Dictionary) -> void:
	var buf := JSON.stringify(data).to_utf8_buffer()
	for slot in _links:
		var link: PeerLink = _links[slot]
		if link.ch_unreliable != null and link.ch_unreliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			link.ch_unreliable.put_packet(buf)


## Disconnect everything and return to IDLE.
func disconnect_peer() -> void:
	if _is_host and _session_id != "":
		FirebaseClient.delete_session(_session_id, func(_c, _d): pass)
	_cleanup(false)


# ── Link setup ─────────────────────────────────────────────────────────────────

func _create_link(slot: int) -> PeerLink:
	var link := PeerLink.new()
	link.slot = slot
	link.conn = WebRTCPeerConnection.new()
	var init_err: int = link.conn.initialize({"iceServers": IceConfig.ice_servers()})
	if init_err != OK:
		push_error("WebRTCManager: initialize() failed: %d" % init_err)
		connection_failed.emit("WebRTC init error %d" % init_err)
		return link
	link.conn.session_description_created.connect(_on_sdp_created.bind(link))
	link.conn.ice_candidate_created.connect(_on_ice_created.bind(link))
	link.conn.data_channel_received.connect(_on_data_channel_received.bind(link))
	# Both sides create negotiated channels by id so no extra signaling is needed.
	var opt_r: Dictionary = {"negotiated": true, "id": 0, "ordered": true}
	var opt_u: Dictionary = {"negotiated": true, "id": 1, "ordered": true, "maxRetransmits": 0}
	link.ch_reliable   = link.conn.create_data_channel("reliable",   opt_r)
	link.ch_unreliable = link.conn.create_data_channel("unreliable", opt_u)
	_links[slot] = link
	return link


## Close and forget a link (does not emit peer_disconnected).
func _destroy_link(link: PeerLink) -> void:
	if link == null:
		return
	_links.erase(link.slot)
	link.ch_reliable = null
	link.ch_unreliable = null
	if link.conn != null:
		link.conn.close()
		link.conn = null


## Host: a link failed or an open link dropped — forget it and re-arm the lowest
## free slot so a replacement joiner can take it.
func _rearm_link(slot: int) -> void:
	var old: PeerLink = _links.get(slot)
	if old != null:
		_destroy_link(old)
	_arm_next_free_slot()


# ── Process loop ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# Iterate a copy — links may be destroyed/re-armed mid-loop.
	for slot in _links.keys():
		var link: PeerLink = _links.get(slot)
		if link == null or link.conn == null:
			continue
		link.conn.poll()
		_poll_link_channels(link)
		_process_link_signaling(link, delta)
	_recompute_state()


func _process_link_signaling(link: PeerLink, delta: float) -> void:
	link.connect_timer += delta

	var cs: int = link.conn.get_connection_state()
	var gs: int = link.conn.get_gathering_state()

	if cs != link.last_conn_state:
		link.last_conn_state = cs
		var conn_names: Array = ["new", "connecting", "connected", "disconnected", "FAILED", "closed"]
		var cn: String = conn_names[cs] if cs < conn_names.size() else str(cs)
		_dbg("[slot %d] connection state: %s" % [link.slot, cn])
		if cs == 4:  # FAILED
			_fail_link(link, "ICE connection FAILED")
			return
		if (cs == 3 or cs == 5) and link.is_open:  # disconnected / closed
			_drop_open_link(link)
			return
	if gs != link.last_gather_state:
		link.last_gather_state = gs
		var gather_names: Array = ["new", "gathering", "complete"]
		var gn: String = gather_names[gs] if gs < gather_names.size() else str(gs)
		_dbg("[slot %d] ICE gathering: %s (%d local)" % [link.slot, gn, link.all_local_ice.size()])

	if link.is_open:
		return

	# Joiner-side timeout: give up on the whole attempt. The host has no timeout —
	# an un-filled joiner slot just keeps polling Firebase for an offer.
	if not _is_host and link.connect_timer >= CONNECT_TIMEOUT:
		_fail_link(link, "Connection timed out after %.0f seconds" % CONNECT_TIMEOUT)
		return

	link.ice_batch_timer += delta
	if link.ice_batch_timer >= ICE_BATCH_INTERVAL:
		link.ice_batch_timer = 0.0
		_flush_local_ice(link)

	link.poll_timer += delta
	if link.poll_timer >= _poll_interval_for(link):
		link.poll_timer = 0.0
		_do_signal_poll(link)

	if cs == 2:  # "connected"
		_check_link_open(link)


## A host link that hasn't received an offer yet polls slowly (idle public
## session); everything mid-handshake polls fast.
func _poll_interval_for(link: PeerLink) -> float:
	if _is_host and not link.offer_received:
		return IDLE_POLL_INTERVAL
	return ACTIVE_POLL_INTERVAL


func _poll_link_channels(link: PeerLink) -> void:
	if link.ch_reliable != null and link.ch_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while link.ch_reliable.get_available_packet_count() > 0:
			_parse_and_emit(link.ch_reliable.get_packet(), link)
	if link.ch_unreliable != null and link.ch_unreliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while link.ch_unreliable.get_available_packet_count() > 0:
			_parse_and_emit(link.ch_unreliable.get_packet(), link)


func _parse_and_emit(raw: PackedByteArray, link: PeerLink) -> void:
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return
	var d: Variant = json.data
	if d is Dictionary:
		# Tag the sender so host-side handlers know which joiner a packet came from.
		d["_from"] = link.slot if _is_host else 1
		packet_received.emit(d)


func _check_link_open(link: PeerLink) -> void:
	var r_open: bool = link.ch_reliable   != null and link.ch_reliable.get_ready_state()   == WebRTCDataChannel.STATE_OPEN
	var u_open: bool = link.ch_unreliable != null and link.ch_unreliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN
	if not (r_open and u_open):
		return
	link.is_open = true
	_dbg("[slot %d] both data channels OPEN after %.1fs" % [link.slot, link.connect_timer])
	# Clean up this slot's signaling namespace (leave other slots' data intact).
	FirebaseClient.delete_signal_slot(_session_id, _my_slot if not _is_host else link.slot, func(_c, _d): pass)
	if not _emitted_connected:
		_emitted_connected = true
		connected.emit()
	peer_connected.emit(link.slot)
	# Now that this slot is filled, arm the next joiner slot (if any).
	if _is_host:
		_arm_next_free_slot()


# ── Data channel received (negotiated fallback) ───────────────────────────────

func _on_data_channel_received(channel: WebRTCDataChannel, link: PeerLink) -> void:
	_dbg("[slot %d] data_channel_received: '%s' (already stored via negotiated id)" % [link.slot, channel.get_label()])


# ── Signaling poll ─────────────────────────────────────────────────────────────

func _signal_slot(link: PeerLink) -> int:
	# The Firebase namespace is always keyed by the joiner's slot.
	return _my_slot if not _is_host else link.slot


func _do_signal_poll(link: PeerLink) -> void:
	if link.is_open:
		return
	var ns: int = _signal_slot(link)
	if _is_host and not link.offer_received:
		FirebaseClient.read_signal_data(_session_id, "%d/offer" % ns, _on_received_offer.bind(link))
	elif not _is_host and not link.answer_received:
		FirebaseClient.read_signal_data(_session_id, "%d/answer" % ns, _on_received_answer.bind(link))

	if link.remote_sdp_set:
		var remote_ice_key: String = "ice_joiner" if _is_host else "ice_host"
		FirebaseClient.read_signal_data(_session_id, "%d/%s" % [ns, remote_ice_key], _on_received_ice_batch.bind(link))


# ── SDP exchange ───────────────────────────────────────────────────────────────

func _on_sdp_created(type: String, sdp: String, link: PeerLink) -> void:
	if link.conn == null:
		return
	link.conn.set_local_description(type, sdp)
	var ns: int = _signal_slot(link)
	if not _is_host and not link.offer_sent:
		link.offer_sent = true
		_dbg("[slot %d] JOINER: offer ready (%d chars) — writing to Firebase" % [link.slot, sdp.length()])
		FirebaseClient.write_signal_data(_session_id, "%d/offer" % ns, {"type": type, "sdp": sdp}, func(_c, _d): pass)
	elif _is_host and not link.answer_sent:
		link.answer_sent = true
		_dbg("[slot %d] HOST: answer ready (%d chars) — writing to Firebase" % [link.slot, sdp.length()])
		FirebaseClient.write_signal_data(_session_id, "%d/answer" % ns, {"type": type, "sdp": sdp}, func(_c, _d): pass)


func _on_received_offer(_code: int, data: Variant, link: PeerLink) -> void:
	if link.conn == null or link.offer_received or not (data is Dictionary) or not data.has("sdp"):
		return
	link.offer_received = true
	_dbg("[slot %d] HOST: received joiner offer — setting remote description" % link.slot)
	var set_err: int = link.conn.set_remote_description(data.get("type", "offer"), data["sdp"])
	if set_err != OK:
		push_error("WebRTCManager: set_remote_description(offer) failed: %d" % set_err)
	link.remote_sdp_set = true
	_apply_buffered_ice(link)
	link.poll_timer = 0.0
	_do_signal_poll(link)


func _on_received_answer(_code: int, data: Variant, link: PeerLink) -> void:
	if link.conn == null or link.answer_received or not (data is Dictionary) or not data.has("sdp"):
		return
	link.answer_received = true
	_dbg("[slot %d] JOINER: received host answer — setting remote description" % link.slot)
	var set_err: int = link.conn.set_remote_description(data.get("type", "answer"), data["sdp"])
	if set_err != OK:
		push_error("WebRTCManager: set_remote_description(answer) failed: %d" % set_err)
	link.remote_sdp_set = true
	_apply_buffered_ice(link)
	link.poll_timer = 0.0
	_do_signal_poll(link)


# ── ICE candidate exchange ─────────────────────────────────────────────────────

func _on_ice_created(media: String, index: int, name: String, link: PeerLink) -> void:
	var candidate := {"media": media, "index": index, "name": name}
	link.pending_local_ice.append(candidate)
	link.all_local_ice.append(candidate)


func _flush_local_ice(link: PeerLink) -> void:
	if link.pending_local_ice.is_empty():
		return
	link.pending_local_ice.clear()
	var ns: int = _signal_slot(link)
	var my_ice_key: String = "ice_host" if _is_host else "ice_joiner"
	FirebaseClient.write_signal_data(_session_id, "%d/%s" % [ns, my_ice_key],
		{"candidates": link.all_local_ice}, func(_c, _d): pass)


func _on_received_ice_batch(_code: int, data: Variant, link: PeerLink) -> void:
	if link.conn == null or not (data is Dictionary) or not data.has("candidates"):
		return
	var candidates: Array = data["candidates"]
	if not link.remote_sdp_set:
		for i in range(link.buffered_remote_ice.size(), candidates.size()):
			var c: Variant = candidates[i]
			if c is Dictionary:
				link.buffered_remote_ice.append(c)
		return
	for i in range(link.remote_ice_applied, candidates.size()):
		var c: Variant = candidates[i]
		if c is Dictionary and c.has("media") and c.has("index") and c.has("name"):
			link.conn.add_ice_candidate(c["media"], int(c["index"]), c["name"])
	link.remote_ice_applied = candidates.size()


func _apply_buffered_ice(link: PeerLink) -> void:
	for c in link.buffered_remote_ice:
		if c.has("media") and c.has("index") and c.has("name"):
			link.conn.add_ice_candidate(c["media"], int(c["index"]), c["name"])
			link.remote_ice_applied += 1
	link.buffered_remote_ice.clear()


# ── Link failure / drop ────────────────────────────────────────────────────────

## A link failed before ever opening.
func _fail_link(link: PeerLink, reason: String) -> void:
	_dbg("[slot %d] link failed: %s" % [link.slot, reason])
	if _is_host:
		# One joiner slot couldn't connect — re-arm it, keep the session alive.
		_rearm_link(link.slot)
		_recompute_state()
		return
	# Joiner: the whole attempt failed.
	if not IceConfig.has_turn():
		# By design there is no relay (see core/ice_config.gd), so every session needs a
		# direct player-to-player connection. Tell the player what to try instead of
		# showing them a raw ICE error they can do nothing with.
		reason = "Couldn't connect to the host. Your network may block direct connections — try a phone hotspot. (%s)" % reason
	connection_failed.emit(reason)
	_cleanup(true)


## An open link dropped mid-session.
func _drop_open_link(link: PeerLink) -> void:
	var slot := link.slot
	_dbg("[slot %d] open link dropped" % slot)
	link.is_open = false
	if _is_host:
		peer_disconnected.emit(slot)
		_rearm_link(slot)
		_recompute_state()
		return
	# Joiner lost the host.
	peer_disconnected.emit(1)
	disconnected.emit()
	_cleanup(false)


# ── State / cleanup ────────────────────────────────────────────────────────────

func _recompute_state() -> void:
	var any_open := false
	for slot in _links:
		if (_links[slot] as PeerLink).is_open:
			any_open = true
			break
	if any_open:
		state = State.CONNECTED
	elif _hosting or _joining:
		state = State.SIGNALING
	else:
		state = State.IDLE


func _cleanup(emit_disc: bool) -> void:
	set_process(false)
	for slot in _links.keys():
		_destroy_link(_links[slot])
	_links.clear()
	_is_host = false
	_hosting = false
	_joining = false
	_my_slot = 1
	_session_id = ""
	_emitted_connected = false
	state = State.IDLE
	if emit_disc:
		disconnected.emit()


# ── Debug ──────────────────────────────────────────────────────────────────────

func _dbg(msg: String) -> void:
	print("[WebRTC] " + msg)
	debug_status.emit(msg)

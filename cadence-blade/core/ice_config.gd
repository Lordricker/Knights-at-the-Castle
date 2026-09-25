# ice_config.gd
# Supplies the ICE server list (STUN + TURN relay) used for every WebRTC connection.
#
# WHY THIS EXISTS:
#   Relay (TURN) servers cost bandwidth, so they need a username/password. A permanent
#   one used to be hardcoded here in the source, which meant it shipped inside every
#   build and sat in a public git repo — anyone could extract it and spend the relay
#   quota. Instead, the secret now lives only in the Cloudflare Worker under
#   services/turn-credentials/, which hands out a short-lived credential at runtime.
#
# IF THE FETCH FAILS the game still works: FALLBACK_SERVERS is STUN-only, which is
# enough for two players to connect directly. Only players whose network blocks a
# direct connection (strict NAT, some mobile carriers) need a relay, and they get a
# clear reason from WebRTCManager.connection_failed.
#
# Add as autoload: Project > Project Settings > Autoload
#   Name: IceConfig   Path: res://core/ice_config.gd

extends Node

# ── CONFIGURE THIS ─────────────────────────────────────────────────────────────
## Deployed worker URL, including the /ice path, or empty for no relay at all.
##
## DELIBERATELY EMPTY: runs are peer-to-peer, hosted on a player's PC, and a relay is
## only ever a fallback for players whose network blocks a direct connection. Metered's
## free tier is 500 MB/month while a single relayed 10-minute trio run costs ~48 MB of
## it (measured), so a relay could serve about ten sessions before running dry — not
## enough to be worth depending on. Those players get a clear failure instead.
##
## Set this only alongside a relay with real bandwidth (a self-hosted coturn box, or a
## paid plan). services/turn-credentials/README.md has the worker that fills it in.
const ICE_ENDPOINT: String = ""
# ──────────────────────────────────────────────────────────────────────────────

## Used until a fetch succeeds, and whenever one fails. No relay — direct connections
## only. Two providers so a single provider outage doesn't cost us STUN as well.
const FALLBACK_SERVERS: Array = [
	{"urls": "stun:stun.relay.metered.ca:80"},
	{"urls": "stun:stun.l.google.com:19302"},
]

## Seconds a fetched credential set is reused before being re-fetched. The worker
## rotates on its own schedule and its reply carries the real value; this is only
## the default when it doesn't.
const DEFAULT_TTL_SECONDS: float = 3600.0
## Seconds to wait for the worker before falling back to STUN-only.
const REQUEST_TIMEOUT_SECONDS: float = 6.0
## Seconds to wait before retrying after a failed fetch, so a player on a broken
## connection isn't delayed on every single host/join attempt.
const RETRY_DELAY_SECONDS: float = 30.0

## Emitted when a fetch attempt finishes — on success AND on failure, so awaiting
## this can never hang the host/join flow.
signal loaded()

var _servers: Array = FALLBACK_SERVERS.duplicate(true)
var _has_turn: bool = false
var _loading: bool = false
## Time of the last completed attempt (msec since start), or -1 if never attempted.
var _last_attempt_ms: int = -1
var _ttl_ms: int = int(DEFAULT_TTL_SECONDS * 1000.0)
var _http: HTTPRequest


func _ready() -> void:
	if ICE_ENDPOINT.is_empty():
		print("[ICE] STUN-only by design — sessions are peer-to-peer, no relay fallback")
		return
	# Fetch during the main menu so the list is ready long before anyone hosts.
	refresh()


# ── Public API ─────────────────────────────────────────────────────────────────

## The ICE servers to hand to WebRTCPeerConnection.initialize().
func ice_servers() -> Array:
	return _servers


## Whether the list currently includes a working relay.
func has_turn() -> bool:
	return _has_turn


## True when there is nothing worth waiting for: either fresh relay credentials are
## in hand, or a recent attempt failed and STUN-only is the answer for now.
func is_ready() -> bool:
	if _loading:
		return false
	if ICE_ENDPOINT.is_empty():
		return true  # Deliberately unconfigured — STUN-only is the final answer.
	if _last_attempt_ms < 0:
		return false
	if _has_turn:
		return not _is_stale()
	return Time.get_ticks_msec() - _last_attempt_ms < int(RETRY_DELAY_SECONDS * 1000.0)


## Await this before creating connections. Returns at once when is_ready() is true.
func ensure_ready() -> void:
	if is_ready():
		return
	if not _loading:
		refresh()
	if _loading:
		await loaded


## Start a fetch unless one is already running or no endpoint is configured.
## A failed fetch keeps whatever list is already in hand rather than dropping back to
## FALLBACK_SERVERS: credentials are minted with hours of validity left, so slightly
## stale ones are far more likely to work than no relay at all.
func refresh() -> void:
	if _loading or ICE_ENDPOINT.is_empty():
		return
	_loading = true
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = REQUEST_TIMEOUT_SECONDS
		_http.request_completed.connect(_on_completed)
		add_child(_http)
	var err: int = _http.request(ICE_ENDPOINT)
	if err != OK:
		_finish("HTTPRequest could not start: error %d" % err)


# ── Internal ───────────────────────────────────────────────────────────────────

func _is_stale() -> bool:
	return _last_attempt_ms < 0 or Time.get_ticks_msec() - _last_attempt_ms > _ttl_ms


func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish("request failed (result %d)" % result)
		return
	if response_code != 200:
		_finish("worker returned HTTP %d" % response_code)
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not (json.data is Dictionary):
		_finish("worker reply was not valid JSON")
		return
	var data: Dictionary = json.data
	var raw: Variant = data.get("iceServers")
	if not (raw is Array) or (raw as Array).is_empty():
		_finish("worker reply had no iceServers")
		return

	# Keep only well-formed entries — a malformed one would make initialize() fail
	# for every connection, which is worse than quietly running with fewer servers.
	var parsed: Array = []
	var relay_found: bool = false
	for entry in raw:
		if not (entry is Dictionary) or not (entry as Dictionary).has("urls"):
			continue
		var urls: String = str((entry as Dictionary)["urls"])
		if urls.is_empty():
			continue
		parsed.append(entry)
		if urls.begins_with("turn:") or urls.begins_with("turns:"):
			relay_found = true
	if parsed.is_empty():
		_finish("worker reply had no usable iceServers")
		return

	_servers = parsed
	_has_turn = relay_found
	var ttl: float = float(data.get("ttl", DEFAULT_TTL_SECONDS))
	_ttl_ms = int(maxf(ttl, 60.0) * 1000.0)
	if relay_found:
		_finish("")
	else:
		_finish("worker reported no relay available: %s" % str(data.get("error", "unknown reason")))


## Mark the attempt finished and wake anyone awaiting. An empty reason means success.
func _finish(reason: String) -> void:
	_loading = false
	_last_attempt_ms = Time.get_ticks_msec()
	if reason.is_empty():
		print("[ICE] %d servers, relay available" % _servers.size())
	else:
		# Not an error worth pushing to the user: STUN-only still plays.
		print("[ICE] no relay — %s (using %d STUN server(s))" % [reason, _servers.size()])
	loaded.emit()

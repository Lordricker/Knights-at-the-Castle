# firebase_client.gd
# Thin Firebase Realtime Database REST wrapper using a serial HTTP request queue.
# Works on all platforms including HTML5 without any Firebase JS SDK.
#
# SETUP:
#   1. Create a Firebase project at console.firebase.google.com
#   2. Go to Build > Realtime Database > Create Database
#   3. Copy your database URL (looks like: https://my-game-default-rtdb.firebaseio.com)
#   4. Paste it into FIREBASE_DB_URL below (remove the trailing slash)
#   5. Set database rules to allow read/write — see MULTIPLAYER_SETUP.md
#
# Add as autoload: Project > Project Settings > Autoload
#   Name: FirebaseClient   Path: res://core/firebase_client.gd

extends Node

# ── CONFIGURE THIS ─────────────────────────────────────────────────────────────
## Your Firebase Realtime Database URL. No trailing slash.
## Example: "https://my-game-12345-default-rtdb.firebaseio.com"
const FIREBASE_DB_URL: String = "https://cadence-blade-default-rtdb.firebaseio.com"
# ──────────────────────────────────────────────────────────────────────────────

var _http: HTTPRequest
var _queue: Array[Dictionary] = []
var _busy: bool = false
var _current_cb: Callable = Callable()


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_completed)
	add_child(_http)


# ── Public API ─────────────────────────────────────────────────────────────────

## Fetch all session entries. cb(response_code: int, data: Variant)
func get_sessions(cb: Callable) -> void:
	_enqueue("GET", "/sessions.json", "", cb)


## Write (overwrite) a session entry.
func create_session(session_id: String, data: Dictionary, cb: Callable) -> void:
	_enqueue("PUT", "/sessions/%s.json" % session_id, JSON.stringify(data), cb)


## Merge fields into an existing session entry.
func update_session(session_id: String, data: Dictionary, cb: Callable) -> void:
	_enqueue("PATCH", "/sessions/%s.json" % session_id, JSON.stringify(data), cb)


## Delete a session entry.
func delete_session(session_id: String, cb: Callable) -> void:
	_enqueue("DELETE", "/sessions/%s.json" % session_id, "", cb)


## Write a WebRTC signaling payload (offer, answer, or ICE batch).
func write_signal_data(session_id: String, key: String, data: Dictionary, cb: Callable) -> void:
	_enqueue("PUT", "/signaling/%s/%s.json" % [session_id, key], JSON.stringify(data), cb)


## Read a WebRTC signaling payload.
func read_signal_data(session_id: String, key: String, cb: Callable) -> void:
	_enqueue("GET", "/signaling/%s/%s.json" % [session_id, key], "", cb)


## Delete all signaling data for a session (cleanup after P2P connects).
func delete_signal_data(session_id: String, cb: Callable) -> void:
	_enqueue("DELETE", "/signaling/%s.json" % session_id, "", cb)


## PUT data to an arbitrary sub-path under the DB root.
## path must start with "/" and end with ".json", e.g. "/sessions/abc123/players/2.json"
func put_subpath(path: String, data: Dictionary, cb: Callable) -> void:
	_enqueue("PUT", path, JSON.stringify(data), cb)


# ── Internal queue ─────────────────────────────────────────────────────────────

func _enqueue(method: String, path: String, body: String, cb: Callable) -> void:
	_queue.append({"method": method, "path": path, "body": body, "cb": cb})
	_flush()


func _flush() -> void:
	if _busy or _queue.is_empty():
		return
	var item: Dictionary = _queue.pop_front()
	_busy = true
	_current_cb = item["cb"]

	var http_method: int
	match item["method"]:
		"PUT":    http_method = HTTPClient.METHOD_PUT
		"PATCH":  http_method = HTTPClient.METHOD_PATCH
		"DELETE": http_method = HTTPClient.METHOD_DELETE
		_:        http_method = HTTPClient.METHOD_GET

	var headers: PackedStringArray = ["Content-Type: application/json"]
	var url: String = FIREBASE_DB_URL.rstrip("/") + item["path"]
	var err: int = _http.request(url, headers, http_method, item["body"])
	if err != OK:
		push_warning("FirebaseClient: request error %d for %s %s" % [err, item["method"], item["path"]])
		_busy = false
		_current_cb = Callable()
		_flush()


func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data: Variant = null
	if result == HTTPRequest.RESULT_SUCCESS and body.size() > 0:
		var text: String = body.get_string_from_utf8()
		if text != "null" and text != "":
			var json := JSON.new()
			if json.parse(text) == OK:
				data = json.data

	var cb := _current_cb
	_busy = false
	_current_cb = Callable()
	if cb.is_valid():
		cb.call(response_code, data)
	_flush()

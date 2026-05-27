extends Node

# GameManager — global game state autoload
# Register in: Project > Project Settings > Autoload > Name: "GameManager"

enum GameState {
	MENU,
	PLAYING,
	PAUSED,
	GAME_OVER,
}

var current_state: GameState = GameState.MENU
var active_players: Array = []
var current_level_variant: String = "day"  # "day", "night", "dusk"

signal state_changed(new_state: GameState)
## Emitted on the host when the joiner disconnects mid-run (host continues solo).
signal joiner_left()

# ── Multiplayer session state ───────────────────────────────────────────────────

## Current session ID (6-char alphanumeric). Empty when playing offline.
var session_id: String = ""
## True if this peer created the session (Godot peer ID 1, the "server" authority).
var is_host: bool = false
## The character key this player chose. "red_knight" | "green_archer"
var my_character: String = ""
## peer_id (int) -> character key (String) for all peers in the session.
## Populated from Firebase when mesh_ready fires.
var peer_characters: Dictionary = {}

## Path to the game level scene loaded when a session starts.
const GAME_LEVEL_SCENE: String = "res://level/variants/level1.tscn"
## Path to the main menu scene (used when returning from a session).
const MAIN_MENU_SCENE: String = "res://ui/menus/main_menu.tscn"

# ── High score ─────────────────────────────────────────────────────────────────

var best_time: float = 0.0
const _HS_KEY: String = "cadence_blade_best_time"


func _ready() -> void:
	_load_best_time()
	# Signal wiring is done from WebRTCManager._ready() because it loads after us.


func connect_webrtc_signals() -> void:
	WebRTCManager.connected.connect(_on_connected)
	WebRTCManager.connection_failed.connect(_on_connection_failed)
	WebRTCManager.disconnected.connect(_on_disconnected)
	print("[GM] WebRTC signals connected")


func change_state(new_state: GameState) -> void:
	current_state = new_state
	state_changed.emit(new_state)


func set_level_variant(variant: String) -> void:
	current_level_variant = variant


# ── Session helpers ────────────────────────────────────────────────────────────

## Start a solo offline run — skips all networking.
func start_solo() -> void:
	session_id = ""
	is_host = true
	my_character = ""
	peer_characters = {}
	get_tree().change_scene_to_file(GAME_LEVEL_SCENE)


## Called by SessionCreate after Firebase session is registered.
## Begins WebRTC host-side signaling.
func begin_hosting(chosen_character: String) -> void:
	my_character = chosen_character
	is_host = true
	peer_characters[1] = chosen_character
	WebRTCManager.host_session(session_id)
	# Register a browser-level cleanup so closing/refreshing the tab deletes the session.
	if OS.has_feature("web"):
		_register_beforeunload_cleanup()


## Called by SessionJoin after the player picks a character.
## Begins WebRTC joiner-side signaling (sends offer to host).
func begin_joining(target_session_id: String, chosen_character: String) -> void:
	session_id = target_session_id
	my_character = chosen_character
	is_host = false
	peer_characters[2] = chosen_character
	WebRTCManager.join_session(session_id)


## Leave the current session gracefully: delete Firebase entry (host only),
## disconnect WebRTC, reset all session state, and return to the main menu.
## Call this from the quit button — not from game-over screen alone.
func leave_session() -> void:
	# Delete the Firebase session now, while is_host / session_id are still valid.
	if is_host and session_id != "":
		FirebaseClient.delete_session(session_id, func(_c, _d): pass)
	# Reset state BEFORE disconnecting so that the disconnect callback's
	# early-out check (session_id == "") prevents a double scene-change.
	session_id = ""
	is_host = false
	my_character = ""
	peer_characters = {}
	change_state(GameState.MENU)
	WebRTCManager.disconnect_peer()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


## Returns which characters are already taken in a session's players data.
## Accepts both Dictionary ({"1": {"character": "key"}}) and Array —
## Firebase may coerce integer-keyed objects to sparse arrays.
static func parse_taken_characters(players_dict: Variant) -> Array[String]:
	var taken: Array[String] = []
	if players_dict is Dictionary:
		for peer_id in players_dict:
			var entry: Variant = players_dict[peer_id]
			if entry is Dictionary and entry.has("character"):
				taken.append(str(entry["character"]))
	elif players_dict is Array:
		# Firebase coerces {"0":…,"1":…} to a sparse array — handle both.
		for entry in players_dict:
			if entry is Dictionary and entry.has("character"):
				taken.append(str(entry["character"]))
	return taken


## Generates a random 6-character session ID using unambiguous characters.
static func generate_session_id() -> String:
	const CHARS: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var id: String = ""
	for _i in 6:
		id += CHARS[randi() % CHARS.length()]
	return id


# ── WebRTC event handlers ──────────────────────────────────────────────────────

func _on_connected() -> void:
	var role: String = "HOST" if is_host else "JOINER"
	print("[GM] connected | role=%s my_char=%s" % [role, my_character])
	if not is_host:
		# Joiner loads the level. RunManager._ready will send a hello packet to the host.
		get_tree().change_scene_to_file(GAME_LEVEL_SCENE)
	else:
		# Host is already in the level. RunManager is listening for the joiner's hello packet.
		# Mark the session as in-game so the lobby hides it.
		if session_id != "":
			FirebaseClient.update_session(session_id, {"status": "in_game"}, func(_c, _d): pass)


func _on_connection_failed(reason: String) -> void:
	push_warning("GameManager: connection failed — %s" % reason)
	# If the host timed out waiting for a NEW joiner during an active run (re-hosting
	# after the previous joiner left), just stay in the run — don't clear session state.
	if is_host and current_state == GameState.PLAYING:
		return  # WebRTC is already IDLE; session stays alive in Firebase.
	session_id = ""
	is_host = false
	peer_characters = {}


func _on_disconnected() -> void:
	if session_id == "":
		return  # leave_session() already cleaned up; nothing left to do.
	if is_host:
		# Joiner disconnected — host continues the run solo.
		# Reset session to "waiting" so a new joiner can find it in the lobby,
		# then re-enter hosting so we can actually accept them.
		FirebaseClient.update_session(session_id, {"status": "waiting"}, func(_c, _d): pass)
		peer_characters.erase(2)
		joiner_left.emit()
		WebRTCManager.host_session(session_id)
		return
	# Joiner: host disconnected unexpectedly — go back to menu.
	session_id = ""
	is_host = false
	peer_characters = {}
	change_state(GameState.MENU)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


## Handle app quit on non-web platforms (desktop / editor runs).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if is_host and session_id != "":
			FirebaseClient.delete_session(session_id, func(_c, _d): pass)


## Inject a JavaScript beforeunload listener that executes a synchronous DELETE
## request against Firebase when the browser tab closes or refreshes.
## Synchronous XHR is permitted in beforeunload handlers specifically for cleanup.
func _register_beforeunload_cleanup() -> void:
	if not OS.has_feature("web"):
		return
	var url: String = (
		"https://cadence-blade-default-rtdb.firebaseio.com/sessions/%s.json" % session_id
	)
	JavaScriptBridge.eval("""
		(function() {
			var _cadenceCleanupUrl = '%s';
			function _cadenceBeforeUnload() {
				try {
					var xhr = new XMLHttpRequest();
					xhr.open('DELETE', _cadenceCleanupUrl, false);
					xhr.setRequestHeader('Content-Type', 'application/json');
					xhr.send();
				} catch(e) {}
			}
			window.removeEventListener('beforeunload', window._cadenceCleanupHandler);
			window._cadenceCleanupHandler = _cadenceBeforeUnload;
			window.addEventListener('beforeunload', window._cadenceCleanupHandler);
		})();
	""" % url)



# ── High score ─────────────────────────────────────────────────────────────────

## Submit a completed run time. Persists if it beats the existing best.
## Returns true when a new high score is set.
func submit_time(t: float) -> bool:
	if t <= best_time:
		return false
	best_time = t
	_save_best_time()
	return true


func _load_best_time() -> void:
	if OS.has_feature("web"):
		var val = JavaScriptBridge.eval(
			"(function(){ var v = localStorage.getItem('%s'); return v !== null ? v : ''; })()" % _HS_KEY
		)
		if typeof(val) == TYPE_STRING and val != "":
			best_time = float(val)
	else:
		var cfg := ConfigFile.new()
		if cfg.load("user://highscore.cfg") == OK:
			best_time = cfg.get_value("score", "best_time", 0.0)


func _save_best_time() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.setItem('%s', '%s');" % [_HS_KEY, str(best_time)])
	else:
		var cfg := ConfigFile.new()
		cfg.set_value("score", "best_time", best_time)
		cfg.save("user://highscore.cfg")

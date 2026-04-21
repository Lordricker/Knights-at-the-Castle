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
	WebRTCManager.mesh_ready.connect(_on_mesh_ready)
	WebRTCManager.connection_failed.connect(_on_connection_failed)
	WebRTCManager.peer_disconnected.connect(_on_peer_disconnected)
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


## Returns which characters are already taken in a session's players Dictionary.
static func parse_taken_characters(players_dict: Variant) -> Array[String]:
	var taken: Array[String] = []
	if players_dict is Dictionary:
		for peer_id in players_dict:
			var entry: Variant = players_dict[peer_id]
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

func _on_mesh_ready() -> void:
	var role: String = "HOST" if is_host else "JOINER"
	print("[GM] mesh_ready | role=%s peer_id=%d my_char=%s" % [role, multiplayer.get_unique_id(), my_character])
	# Read the full player list from Firebase so peer_characters is complete on both sides.
	FirebaseClient.get_sessions(func(_code: int, data: Variant) -> void:
		if data != null and (data is Dictionary) and data.has(session_id):
			var players: Variant = data[session_id].get("players", {})
			if players is Dictionary:
				for pid_str in players:
					var pid: int = int(pid_str)
					var entry: Variant = players[pid_str]
					var ch: String = entry.get("character", "") if entry is Dictionary else ""
					if not ch.is_empty():
						peer_characters[pid] = ch
		print("[GM] peer_characters=%s" % str(peer_characters))

		if is_host:
			# Host is already in the running level. Spawn the joiner's character there.
			var joiner_id: int = 2
			var joiner_char: String = peer_characters.get(joiner_id, "")
			if joiner_char.is_empty():
				push_warning("[GM] HOST: joiner character not found in Firebase")
				return
			var run_mgr: Node = get_tree().get_first_node_in_group(&"run_manager")
			print("[GM] HOST: spawning joiner %d (%s) mid-game, run_mgr=%s" % [joiner_id, joiner_char, str(run_mgr != null)])
			if run_mgr != null and run_mgr.has_method("spawn_peer_mid_game"):
				run_mgr.spawn_peer_mid_game(joiner_id, joiner_char)
			if session_id != "":
				FirebaseClient.update_session(session_id, {"status": "in_game"}, func(_c, _d): pass)
		else:
			# Joiner: load the level. RunManager._ready() will request a state snapshot from host.
			get_tree().change_scene_to_file(GAME_LEVEL_SCENE)
	)


func _on_connection_failed(reason: String) -> void:
	push_warning("GameManager: connection failed — %s" % reason)
	session_id = ""
	is_host = false
	peer_characters = {}


func _on_peer_disconnected(_peer_id: int) -> void:
	if session_id == "":
		return  # leave_session() already cleaned up; nothing left to do.
	# Partner disconnected unexpectedly — host cleans up the Firebase session.
	if is_host:
		FirebaseClient.delete_session(session_id, func(_c, _d): pass)
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

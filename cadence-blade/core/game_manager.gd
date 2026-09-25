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
## Emitted on the host when a joiner disconnects mid-run. Carries the freed slot
## (2 or 3). The host keeps running; the slot re-opens for a replacement joiner.
signal joiner_left(slot: int)

# ── Shared coin pool (run currency) ───────────────────────────────────────────
## Authoritative party-wide coin balance. Every character reads and writes this
## through CharacterBase.coins / add_coins(), so the host and joiner never drift
## apart no matter which code path (pickup, blacksmith, TNT, unit hut) touches it.
## Reset to 0 at the start of each run by RunManager.
var coin_balance: int = 0
## Fired whenever coin_balance changes. CharacterBase re-emits this as its own
## coins_changed signal so existing HUD wiring keeps working unchanged.
signal coin_balance_changed(new_balance: int)


## Zero the shared coin pool. Called once per run from RunManager._ready().
func reset_coins() -> void:
	coin_balance = 0
	coin_balance_changed.emit(coin_balance)


## Add (or, with a negative amount, spend) coins in the shared pool.
func add_coins(amount: int) -> void:
	coin_balance += amount
	coin_balance_changed.emit(coin_balance)


## Overwrite the shared pool outright. Used by the join-time world resync, where the
## joiner adopts the host's balance rather than accumulating its own from zero.
func set_coins(amount: int) -> void:
	coin_balance = amount
	coin_balance_changed.emit(coin_balance)

# ── Kill tally (game-over podium) ─────────────────────────────────────────────
## Enemies each player slot has personally killed this run (slot -> count). Only the
## killing blow counts, and only when a player dealt it — see EnemyBase.player_hit().
## Authoritative on the host (or solo); joiners receive the final standings in the
## "gameover" packet rather than mirroring this live.
var kill_counts: Dictionary = {}
## slot -> Time.get_ticks_msec() of that slot's most recent kill. Breaks podium ties.
var _kill_stamps: Dictionary = {}


## Zero the tally. Called once per run from RunManager._ready().
func reset_kills() -> void:
	kill_counts.clear()
	_kill_stamps.clear()


## Drop one slot's tally — a joiner left, and a replacement in that slot starts fresh.
func clear_kills_for(slot: int) -> void:
	kill_counts.erase(slot)
	_kill_stamps.erase(slot)


## Credit one kill to a player slot. Slot 0 (no player behind the blow) is ignored.
func record_kill(slot: int) -> void:
	if slot <= 0:
		return
	kill_counts[slot] = kills_of(slot) + 1
	_kill_stamps[slot] = Time.get_ticks_msec()


func kills_of(slot: int) -> int:
	return int(kill_counts.get(slot, 0))


## The given slots ordered best-first by kills. A tie goes to whoever reached the
## shared count first (their latest kill is the older one), then to the lower slot.
func rank_by_kills(slots: Array) -> Array:
	var ranked: Array = slots.duplicate()
	ranked.sort_custom(func(a: int, b: int) -> bool:
		var ka: int = kills_of(a)
		var kb: int = kills_of(b)
		if ka != kb:
			return ka > kb
		var ta: int = int(_kill_stamps.get(a, 0))
		var tb: int = int(_kill_stamps.get(b, 0))
		if ta != tb:
			return ta < tb
		return a < b)
	return ranked

# ── Multiplayer session state ───────────────────────────────────────────────────

## Current session ID (6-char alphanumeric). Empty when playing offline.
var session_id: String = ""
## True if this peer created the session (Godot peer ID 1, the "server" authority).
var is_host: bool = false
## This peer's player slot: 1 = host, 2 or 3 = joiner (assigned when joining).
var my_slot: int = 1
## The character key this player chose. "red_knight" | "green_archer" | "rogue"
var my_character: String = ""
## peer_id (int) -> character key (String) for all peers in the session.
## Populated from Firebase when mesh_ready fires.
var peer_characters: Dictionary = {}

## Path to the game level scene loaded when a session starts.
const GAME_LEVEL_SCENE: String = "res://level/variants/level1.tscn"
## Path to the guided tutorial level.
const TUTORIAL_LEVEL_SCENE: String = "res://level/variants/tutorial.tscn"
## Path to the main menu scene (used when returning from a session).
const MAIN_MENU_SCENE: String = "res://ui/menus/main_menu.tscn"

# ── High score ─────────────────────────────────────────────────────────────────

var best_time: float = 0.0
const _HS_KEY: String = "cadence_blade_best_time"


func _ready() -> void:
	_load_best_time()
	_strip_mouse_bindings_on_touch()
	# Signal wiring is done from WebRTCManager._ready() because it loads after us.


## True on phones/tablets and touch browsers. Desktop ("pc") builds always count as
## mouse + keyboard: Windows/Linux report a touchscreen on many laptops, and treating
## those as touch devices would strip click-to-attack/aim and show the mobile controls.
func is_touch_device() -> bool:
	return DisplayServer.is_touchscreen_available() and not OS.has_feature("pc")


## On touchscreens, Godot's "Emulate Mouse from Touch" setting fires a synthetic
## left-click InputEventMouseButton for every tap. Since action1/action2 are also
## bound to LMB/RMB (for desktop click-to-attack), that phantom click makes action1
## register as "just pressed" on ANY touch — including taps on the mobile K/L attack
## buttons — and it wins the elif chain in each character's _handle_attack_input, so
## K/L attacks incorrectly fall through to attack 1. The on-screen TouchScreenButtons
## call Input.action_press() directly by action name, so they don't need these mouse
## InputMap bindings — safe to drop them here.
func _strip_mouse_bindings_on_touch() -> void:
	if not is_touch_device():
		return
	for action in [&"action1", &"action2", &"action3"]:
		for event in InputMap.action_get_events(action):
			if event is InputEventMouseButton:
				InputMap.action_erase_event(action, event)


func connect_webrtc_signals() -> void:
	WebRTCManager.connected.connect(_on_connected)
	WebRTCManager.connection_failed.connect(_on_connection_failed)
	WebRTCManager.disconnected.connect(_on_disconnected)
	WebRTCManager.peer_connected.connect(_on_peer_connected)
	WebRTCManager.peer_disconnected.connect(_on_peer_disconnected)
	print("[GM] WebRTC signals connected")


func change_state(new_state: GameState) -> void:
	current_state = new_state
	state_changed.emit(new_state)


func set_level_variant(variant: String) -> void:
	current_level_variant = variant


# ── Session helpers ────────────────────────────────────────────────────────────

## Start a solo offline run — skips all networking.
## chosen_character is the key the player picked ("red_knight" | "green_archer" |
## "rogue"); RunManager._spawn_players reads GameManager.my_character to pick the
## matching player scene, exactly like a host run. Empty falls back to the first
## inspector-assigned player scene.
func start_solo(chosen_character: String = "") -> void:
	session_id = ""
	is_host = true
	my_slot = 1
	my_character = chosen_character
	peer_characters = {}
	get_tree().change_scene_to_file(GAME_LEVEL_SCENE)


## Start the guided tutorial — solo/offline like start_solo(), but always the Red
## Knight and always the tutorial level, regardless of what the player has selected.
func start_tutorial() -> void:
	session_id = ""
	is_host = true
	my_slot = 1
	my_character = "red_knight"
	peer_characters = {}
	get_tree().change_scene_to_file(TUTORIAL_LEVEL_SCENE)


## Called by SessionCreate after Firebase session is registered.
## Begins WebRTC host-side signaling.
func begin_hosting(chosen_character: String) -> void:
	my_character = chosen_character
	is_host = true
	my_slot = 1
	_connected_joiner_slots.clear()
	peer_characters[1] = chosen_character
	WebRTCManager.host_session(session_id)
	# Register a browser-level cleanup so closing/refreshing the tab deletes the session.
	if OS.has_feature("web"):
		_register_beforeunload_cleanup()


## Called by SessionJoin after the player picks a character.
## Begins WebRTC joiner-side signaling (sends offer to host).
func begin_joining(target_session_id: String, chosen_character: String, slot: int = 2) -> void:
	session_id = target_session_id
	my_character = chosen_character
	is_host = false
	my_slot = slot
	peer_characters[slot] = chosen_character
	WebRTCManager.join_session(session_id, slot)


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
	my_slot = 1
	my_character = ""
	peer_characters = {}
	_connected_joiner_slots.clear()
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

## Host: joiner slots that currently have an open WebRTC link.
var _connected_joiner_slots: Dictionary = {}
## Joiner slots the host accepts (star topology).
const JOINER_SLOTS: Array = [2, 3]


func _on_connected() -> void:
	var role: String = "HOST" if is_host else "JOINER"
	print("[GM] connected | role=%s my_char=%s" % [role, my_character])
	if not is_host:
		# Joiner loads the level. RunManager._ready will send a hello packet to the host.
		get_tree().change_scene_to_file(GAME_LEVEL_SCENE)


## Host: mark the session "in_game" only when every joiner slot is full, otherwise
## keep it "waiting" so the lobby still advertises the open slot (mid-run join).
func _refresh_session_status() -> void:
	if not is_host or session_id == "":
		return
	var full: bool = _connected_joiner_slots.size() >= JOINER_SLOTS.size()
	FirebaseClient.update_session(session_id, {"status": "in_game" if full else "waiting"}, func(_c, _d): pass)


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
	# In star topology this only fires for a joiner that lost the host. Per-joiner
	# drops on the host come through _on_peer_disconnected instead.
	if is_host:
		return
	# Joiner: host disconnected unexpectedly — go back to menu.
	session_id = ""
	is_host = false
	my_slot = 1
	peer_characters = {}
	change_state(GameState.MENU)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


## Host: a joiner slot connected.
func _on_peer_connected(slot: int) -> void:
	if not is_host or session_id == "":
		return
	print("[GM] peer connected on slot %d" % slot)
	_connected_joiner_slots[slot] = true
	_refresh_session_status()


## Host: a joiner dropped. Free their slot for a replacement and keep running.
## WebRTCManager has already re-armed signaling for `slot`.
func _on_peer_disconnected(slot: int) -> void:
	if not is_host:
		return
	print("[GM] peer disconnected on slot %d — freeing it" % slot)
	_connected_joiner_slots.erase(slot)
	peer_characters.erase(slot)
	if session_id != "":
		FirebaseClient.delete_subpath("/sessions/%s/players/%d.json" % [session_id, slot], func(_c, _d): pass)
	_refresh_session_status()
	joiner_left.emit(slot)


## Handle app quit on non-web platforms (desktop / editor runs).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if not OS.has_feature("web") and is_host and session_id != "":
			# Async requests never finish before the process exits, so block briefly.
			FirebaseClient.delete_session_blocking(session_id)
			session_id = ""


## Desktop: F11 or Alt+Enter toggles fullscreen (there is no options menu for it).
func _unhandled_key_input(event: InputEvent) -> void:
	if OS.has_feature("web"):
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F11 or (key.keycode == KEY_ENTER and key.alt_pressed):
		var is_fullscreen: bool = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_WINDOWED if is_fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)
		get_viewport().set_input_as_handled()


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

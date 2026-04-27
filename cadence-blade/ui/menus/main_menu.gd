# main_menu.gd
# Scene-driven main menu.
#
# Two screens live inside this CanvasLayer, toggled with a fade:
#
#   MainScreen    — title + PLAY + HELP buttons.
#   SessionScreen — permanent host entry + scrollable list of joinable sessions.
#
# ── Required scene structure ────────────────────────────────────────────────
# Wire every @export var in the Inspector after attaching this script.
#
#   MainMenu (CanvasLayer)
#   ├── MainScreen (Control)                    ← @export main_screen
#   │   ├── PlayButton (Button)                 ← @export play_button
#   │   ├── HelpButton (Button)                 ← @export help_button
#   │   └── BestTimeLabel (Label)  [optional]   ← @export best_time_label
#   ├── SessionScreen (Control)                 ← @export session_screen
#   │   ├── BackButton (Button)                 ← @export back_button
#   │   ├── StatusLabel (Label)    [optional]   ← @export session_status_label
#   │   ├── PermanentEntry (Control)            ← @export permanent_entry
#   │   │     [instance of session_entry.tscn, host mode]
#   │   └── ScrollContainer
#   │       └── SessionsContainer (VBoxContainer) ← @export sessions_container
#   └── HelpOverlay (Control)                   ← @export help_overlay
#       └── CloseButton (Button)                ← @export help_close_button
# ────────────────────────────────────────────────────────────────────────────

extends CanvasLayer

# Character keys — must match session_entry.gd and Firebase data.
const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer"]

const SESSION_ENTRY_SCENE: String = "res://ui/menus/session_entry.tscn"
const POLL_INTERVAL:  float = 5.0
const FADE_DURATION:  float = 0.3

# ── Exported references ──────────────────────────────────────────────────────
@export var main_screen:          Control
@export var session_screen:       Control
@export var play_button:          Button
@export var help_button:          Button
@export var back_button:          Button
@export var help_overlay:         Control
@export var help_close_button:    Button
@export var best_time_label:      Label     # optional
@export var session_status_label: Label     # optional — shows Firebase errors
## Permanent SessionEntry instance (host-create mode).
@export var permanent_entry:      Control
## VBoxContainer inside the ScrollContainer; populated with join entries.
@export var sessions_container:   VBoxContainer

# ── Runtime state ────────────────────────────────────────────────────────────
var _poll_timer: float = 0.0
var _is_busy:    bool  = false


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Button wiring.
	if play_button:
		play_button.pressed.connect(_on_play_pressed)
	if help_button:
		help_button.pressed.connect(_on_help_pressed)
	if back_button:
		back_button.pressed.connect(_on_back_pressed)
	if help_close_button:
		help_close_button.pressed.connect(func() -> void:
			if help_overlay: help_overlay.hide())

	# Initial visibility — main screen shown, session screen hidden.
	if help_overlay:
		help_overlay.hide()
	if session_screen:
		session_screen.modulate.a = 0.0
		session_screen.hide()
	if main_screen:
		main_screen.modulate.a = 1.0
		main_screen.show()

	# Best time display.
	if best_time_label:
		if GameManager.best_time > 0.0:
			var m: int = int(GameManager.best_time) / 60
			var s: int = int(GameManager.best_time) % 60
			best_time_label.text = "Best: %d:%02d" % [m, s]
		else:
			best_time_label.hide()

	# Wire the permanent (host) entry.
	if permanent_entry and permanent_entry.has_method("setup_as_host"):
		permanent_entry.play_pressed.connect(_on_permanent_play_pressed)
		permanent_entry.setup_as_host()

	# WebRTC failure forwarding.
	WebRTCManager.connection_failed.connect(_on_connection_failed)


func _process(delta: float) -> void:
	# Auto-poll while the session screen is visible and not mid-transaction.
	if _is_busy:
		return
	if session_screen == null or not session_screen.visible:
		return
	_poll_timer += delta
	if _poll_timer >= POLL_INTERVAL:
		_poll_timer = 0.0
		_refresh_sessions()


# ── Screen transitions ────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	if play_button:
		play_button.disabled = true
	await _fade_out(main_screen)
	if main_screen:
		main_screen.hide()
	if session_screen:
		session_screen.modulate.a = 0.0
		session_screen.show()
		await _fade_in(session_screen)
	if play_button:
		play_button.disabled = false
	# Trigger an immediate poll.
	_poll_timer = POLL_INTERVAL


func _on_back_pressed() -> void:
	# Cancel any pending host session.
	if GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
		GameManager.session_id = ""
	_is_busy = false
	_clear_join_entries()
	await _fade_out(session_screen)
	if session_screen:
		session_screen.hide()
	if main_screen:
		main_screen.modulate.a = 0.0
		main_screen.show()
		await _fade_in(main_screen)
	# Refresh host session ID so it's fresh next time the screen opens.
	if permanent_entry and permanent_entry.has_method("setup_as_host"):
		permanent_entry.setup_as_host()


# ── Help overlay ──────────────────────────────────────────────────────────────

func _on_help_pressed() -> void:
	if help_overlay:
		help_overlay.show()


# ── Session list ──────────────────────────────────────────────────────────────

func _refresh_sessions() -> void:
	FirebaseClient.get_sessions(_on_sessions_received)


func _on_sessions_received(_code: int, data: Variant) -> void:
	_clear_join_entries()

	if data == null or not (data is Dictionary) or data.is_empty():
		return

	var now: int = int(Time.get_unix_time_from_system())
	for sid in data:
		var session: Variant = data[sid]
		if not (session is Dictionary):
			continue
		if session.get("is_private", false):
			continue
		if session.get("status", "waiting") == "in_game":
			continue
		var last_seen: int = int(session.get("last_seen", session.get("created_at", now)))
		if now - last_seen > 30:
			FirebaseClient.delete_session(sid, func(_c, _d): pass)
			continue
		var players: Variant = session.get("players", {})
		var taken: Array[String] = GameManager.parse_taken_characters(players)
		if taken.size() >= CHARACTER_KEYS.size():
			continue
		_add_join_entry(sid, taken)


func _add_join_entry(sid: String, taken_characters: Array[String]) -> void:
	if sessions_container == null:
		return
	var entry := load(SESSION_ENTRY_SCENE).instantiate() as Control
	if entry == null:
		return
	sessions_container.add_child(entry)
	if entry.has_method("setup_as_join"):
		entry.setup_as_join(sid, taken_characters)
	entry.join_pressed.connect(_on_join_entry_pressed)


func _clear_join_entries() -> void:
	if sessions_container == null:
		return
	for child in sessions_container.get_children():
		if child != permanent_entry:
			child.queue_free()


# ── Session actions ───────────────────────────────────────────────────────────

func _on_permanent_play_pressed(entry: Control) -> void:
	if _is_busy:
		return
	_is_busy = true
	_set_status("Creating session...")

	var sid: String       = entry.get("session_id")
	var character: String = entry.get("selected_character")
	var priv: bool        = entry.get("is_private")

	GameManager.session_id = sid

	var session_data: Dictionary = {
		"is_private":       priv,
		"status":           "waiting",
		"elapsed_seconds":  0,
		"created_at":       Time.get_unix_time_from_system(),
		"last_seen":        Time.get_unix_time_from_system(),
		"players":          {"1": {"character": character}},
	}

	FirebaseClient.create_session(sid, session_data,
		func(code: int, _data: Variant) -> void:
			if code != 200:
				_set_status("Firebase error (code %d). Check DB URL and rules." % code)
				_is_busy = false
				GameManager.session_id = ""
				return
			GameManager.begin_hosting(character)
			get_tree().change_scene_to_file(GameManager.GAME_LEVEL_SCENE)
	)


func _on_join_entry_pressed(entry: Control) -> void:
	if _is_busy:
		return
	_is_busy = true
	_set_status("Connecting...")

	var sid: String       = entry.get("session_id")
	var character: String = entry.get("selected_character")

	FirebaseClient.put_subpath(
		"/sessions/%s/players/2.json" % sid,
		{"character": character},
		func(_code: int, _data: Variant) -> void:
			GameManager.begin_joining(sid, character)
	)


func _on_connection_failed(reason: String) -> void:
	_is_busy = false
	_set_status("Connection failed: %s" % reason)
	if GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
		GameManager.session_id = ""


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_status(msg: String) -> void:
	if session_status_label:
		session_status_label.text = msg


func _fade_out(node: Control) -> void:
	if node == null:
		return
	var tween := create_tween()
	tween.tween_property(node, "modulate:a", 0.0, FADE_DURATION)
	await tween.finished


func _fade_in(node: Control) -> void:
	if node == null:
		return
	var tween := create_tween()
	tween.tween_property(node, "modulate:a", 1.0, FADE_DURATION)
	await tween.finished

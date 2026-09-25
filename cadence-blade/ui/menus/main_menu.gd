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
const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer", "rogue"]

const SESSION_ENTRY_SCENE: String = "res://ui/menus/session_entry.tscn"
const POLL_INTERVAL:  float = 5.0
const FADE_DURATION:  float = 0.3

## Discord invite — use an invite link (discord.gg/...) so non-members can join,
## not a channels/ deep link which only works for people already in the server.
const DISCORD_URL: String = "https://discord.gg/3ACT6w5fXV"

# ── Exported references ──────────────────────────────────────────────────────
@export var main_screen:          Control
@export var session_screen:       Control
@export var play_button:          Button
@export var help_button:          Button
## Toggle buttons — MUSIC/SFX on the main screen. Pressed = muted.
@export var music_button:         Button
@export var sfx_button:           Button
@export var back_button:          Button
## Opens the community Discord in the browser.
@export var discord_button:       Button
@export var help_overlay:         Control
@export var help_close_button:    Button
## Buttons inside HelpScreen that open the Combat/UnitHut sub-help panels.
@export var combat_help_button:   Button
@export var unit_hut_help_button: Button
## Sub-help panels, each shown from HelpScreen and returning to it via their own close button.
@export var combat_help:          Control
@export var combat_help_close:    Button
@export var unit_hut_help:        Control
@export var unit_hut_help_close:  Button
## "Character Details" button — shown only while a character is selected.
@export var details_button:       Button
@export var best_time_label:      Label     # optional
@export var session_status_label: Label     # optional — shows Firebase errors
@export var debug_label:          Label     # optional — shows debug info for join flow
## Permanent SessionEntry instance (host-create mode).
@export var permanent_entry:      Control
## VBoxContainer inside the ScrollContainer; populated with join entries.
@export var sessions_container:   VBoxContainer

# ── Runtime state ────────────────────────────────────────────────────────────
var _poll_timer: float = 0.0
var _is_busy:    bool  = false
## sid -> raw Firebase "players" value, kept so a joiner can pick a free slot (2/3).
var _session_players: Dictionary = {}


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	AudioManager.play_menu_music()

	# Button wiring.
	if play_button:
		play_button.pressed.connect(_on_play_pressed)
	if help_button:
		help_button.pressed.connect(_on_help_pressed)
	if music_button:
		music_button.toggle_mode = true
		music_button.button_pressed = AudioManager.music_muted
		music_button.toggled.connect(_on_music_button_toggled)
	if sfx_button:
		sfx_button.toggle_mode = true
		sfx_button.button_pressed = AudioManager.sfx_muted
		sfx_button.toggled.connect(_on_sfx_button_toggled)
	if back_button:
		back_button.pressed.connect(_on_back_pressed)
	if discord_button:
		discord_button.pressed.connect(_on_discord_pressed)
	if help_close_button:
		help_close_button.pressed.connect(func() -> void:
			if help_overlay: help_overlay.hide())
	if combat_help_button:
		combat_help_button.pressed.connect(func() -> void:
			if help_overlay: help_overlay.hide()
			if combat_help: combat_help.show())
	if unit_hut_help_button:
		unit_hut_help_button.pressed.connect(func() -> void:
			if help_overlay: help_overlay.hide()
			if unit_hut_help: unit_hut_help.show())
	if combat_help_close:
		combat_help_close.pressed.connect(func() -> void:
			if combat_help: combat_help.hide()
			if help_overlay: help_overlay.show())
	if unit_hut_help_close:
		unit_hut_help_close.pressed.connect(func() -> void:
			if unit_hut_help: unit_hut_help.hide()
			if help_overlay: help_overlay.show())
	if details_button:
		details_button.pressed.connect(_on_details_pressed)
		details_button.hide()
	var tutorial_button := get_node_or_null("sessionscreen/TutorialButton") as Button
	if tutorial_button:
		tutorial_button.pressed.connect(_on_tutorial_button_pressed)
	# Quit button — desktop only (a browser tab can't close itself, and mobile apps don't quit).
	# The node is still named "TutorialButton" (it was duplicated from the tutorial button);
	# the real tutorial button is the one under sessionscreen/. Update this path if it's renamed.
	var quit_button := get_node_or_null("MainScreen/TutorialButton") as Button
	if quit_button:
		quit_button.visible = OS.has_feature("pc")
		quit_button.pressed.connect(_on_quit_pressed)

	# Clear debug label at start
	if debug_label:
		debug_label.text = ""

	# Initial visibility — main screen shown, session screen hidden.
	if help_overlay:
		help_overlay.hide()
	if combat_help:
		combat_help.hide()
	if unit_hut_help:
		unit_hut_help.hide()
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
		# Pass the description panel so character button presses populate it.
		var desc := get_node_or_null("sessionscreen/Descriptionpanel") as Control
		if desc != null:
			permanent_entry.set("description_panel", desc)
		_wire_selection_panels(permanent_entry)

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
	if debug_label:
		debug_label.text = "Opening session list..."
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
	# Tear down any in-flight WebRTC attempt (e.g. Back pressed mid "Connecting...")
	# so the transport returns to IDLE and the next join isn't silently blocked.
	WebRTCManager.disconnect_peer()
	# Only delete the Firebase session if WE own it (host). A joiner's
	# GameManager.session_id points at the *host's* session — deleting it here
	# would kick the host and everyone else out of the lobby.
	if GameManager.session_id != "":
		if GameManager.is_host:
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


# ── Discord ───────────────────────────────────────────────────────────────────

func _on_discord_pressed() -> void:
	# Call straight from the press (no await) so web exports keep it click-initiated
	# and browsers don't block it as a popup.
	OS.shell_open(DISCORD_URL)


# ── Quit ──────────────────────────────────────────────────────────────────────

func _on_quit_pressed() -> void:
	get_tree().quit()


# ── Audio toggles ─────────────────────────────────────────────────────────────

func _on_music_button_toggled(pressed: bool) -> void:
	AudioManager.set_music_muted(pressed)


func _on_sfx_button_toggled(pressed: bool) -> void:
	AudioManager.set_sfx_muted(pressed)


# ── Character details ────────────────────────────────────────────────────────

func _on_details_pressed() -> void:
	var stats_panel := get_node_or_null("sessionscreen/DetailedStatsPanel")
	if stats_panel != null and stats_panel.has_method("open"):
		stats_panel.open()


## Passes the DetailsButton and DetailedStatsPanel to a session_entry instance
## so its character selection keeps both in sync (same pattern as description_panel).
func _wire_selection_panels(entry: Control) -> void:
	if details_button != null:
		entry.set("details_button", details_button)
	var stats_panel := get_node_or_null("sessionscreen/DetailedStatsPanel")
	if stats_panel != null:
		entry.set("detailed_stats_panel", stats_panel)


# ── Session list ──────────────────────────────────────────────────────────────

func _refresh_sessions() -> void:
	FirebaseClient.get_sessions(_on_sessions_received)


func _on_sessions_received(_code: int, data: Variant) -> void:
	_clear_join_entries()
	_session_players.clear()

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
		_session_players[sid] = players
		_add_join_entry(sid, taken)


func _add_join_entry(sid: String, taken_characters: Array[String]) -> void:
	if sessions_container == null:
		return
	var entry := load(SESSION_ENTRY_SCENE).instantiate() as Control
	if entry == null:
		return
	sessions_container.add_child(entry)
	# Share the on-screen status line (DebugLabel) so join attempts show
	# "Loading..." / "Connecting..." the same way the host entry does.
	var status := get_node_or_null("sessionscreen/DebugLabel") as Label
	if status != null:
		entry.set("status_label", status)
	if entry.has_method("setup_as_join"):
		entry.setup_as_join(sid, taken_characters)
	entry.join_pressed.connect(_on_join_entry_pressed)
	# Pass the same description panel so this join entry can also populate it.
	var desc := get_node_or_null("sessionscreen/Descriptionpanel") as Control
	if desc != null:
		entry.set("description_panel", desc)
	_wire_selection_panels(entry)


func _clear_join_entries() -> void:
	if sessions_container == null:
		return
	for child in sessions_container.get_children():
		if child != permanent_entry:
			child.queue_free()


# ── Session actions ───────────────────────────────────────────────────────────

func _on_tutorial_button_pressed() -> void:
	GameManager.start_tutorial()


func _on_permanent_play_pressed(entry: Control) -> void:
	if _is_busy:
		return
	var sid: String       = entry.get("session_id")
	var character: String = entry.get("selected_character")
	var priv: bool        = entry.get("is_private")
	var solo: bool        = bool(entry.get("is_solo"))
	if debug_label:
		debug_label.text = "Host: validating character..."
	if character == "" or character == null:
		if debug_label:
			debug_label.text = "Select a character first!"
		return

	# Solo: skip Firebase + WebRTC entirely and load straight into an offline run.
	if solo:
		_set_status("Loading solo run...")
		if debug_label:
			debug_label.text = "Solo: loading level..."
		GameManager.start_solo(character)
		return

	_is_busy = true
	_set_status("Creating session...")
	if debug_label:
		debug_label.text = "Host: creating session..."
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
				if debug_label:
					debug_label.text = "Host: Firebase error (code %d)" % code
				return
			if debug_label:
				debug_label.text = "Host: starting WebRTC..."
			GameManager.begin_hosting(character)
			get_tree().change_scene_to_file(GameManager.GAME_LEVEL_SCENE)
	)


func _on_join_entry_pressed(entry: Control) -> void:
	if _is_busy:
		return
	var sid: String       = entry.get("session_id")
	var character: String = entry.get("selected_character")
	if debug_label:
		debug_label.text = "Join: validating character..."
	if character == "" or character == null:
		if debug_label:
			debug_label.text = "Select a character first!"
		return
	var slot: int = _free_joiner_slot(_session_players.get(sid, {}))
	if slot == 0:
		_is_busy = false
		_set_status("Session is full.")
		if debug_label:
			debug_label.text = "Join: session full"
		return
	_is_busy = true
	_set_status("Connecting...")
	if debug_label:
		debug_label.text = "Join: sending character to server (slot %d)..." % slot
	FirebaseClient.put_subpath(
		"/sessions/%s/players/%d.json" % [sid, slot],
		{"character": character},
		func(_code: int, _data: Variant) -> void:
			if debug_label:
				debug_label.text = "Join: starting WebRTC connection..."
			GameManager.begin_joining(sid, character, slot)
	)


## Lowest unoccupied joiner slot (2 or 3) for a session, or 0 when full.
## Handles both the Dictionary and Firebase-coerced sparse-Array form of `players`.
func _free_joiner_slot(players: Variant) -> int:
	var occupied: Dictionary = {}
	if players is Dictionary:
		for k in players:
			occupied[int(k)] = true
	elif players is Array:
		for i in (players as Array).size():
			if players[i] != null:
				occupied[i] = true
	for s in [2, 3]:
		if not occupied.has(s):
			return s
	return 0


func _on_connection_failed(reason: String) -> void:
	_is_busy = false
	_set_status("Connection failed: %s" % reason)
	# Only the host may delete the session. A joiner failing to connect must not
	# wipe the host's lobby entry out from under everyone else — but it should
	# release the joiner slot it reserved so a retry can reuse it.
	if GameManager.session_id != "":
		if GameManager.is_host:
			FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
		elif GameManager.my_slot >= 2:
			FirebaseClient.delete_subpath(
				"/sessions/%s/players/%d.json" % [GameManager.session_id, GameManager.my_slot],
				func(_c, _d): pass)
		GameManager.session_id = ""

	if debug_label:
		debug_label.text = "Connection failed: %s" % reason


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_status(msg: String) -> void:
	if session_status_label:
		session_status_label.text = msg
	# Fall back to the shared DebugLabel so status still shows when no
	# dedicated session_status_label is wired (e.g. the join flow).
	elif debug_label == null:
		var status := get_node_or_null("sessionscreen/DebugLabel") as Label
		if status != null:
			status.text = msg


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

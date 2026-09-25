class_name HUD
extends CanvasLayer

# hud.gd — Live HUD (timer + coins) and game-over overlay (restart/quit).
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Wire all exports in the Inspector.
#   Live HUD:
#     • hud_timer_label  — top-left timer Label (updates every frame)
#     • hud_coins_label  — top-left coins Label (auto-connects to player signal)
#     • run_manager      — RunManager node (must expose float `time_elapsed`)
#   Game Over Screen:
#     • game_over_control  — Control that wraps the game-over panel (hidden by default)
#     • game_over_label    — optional Label for "CASTLE DESTROYED" text
#     • game_over_time_label — optional Label for "Survived 1:23" text
#     • restart_button / quit_button — Buttons inside game_over_control
#     • podium_first / podium_second / podium_third — PodiumPlace nodes; filled with each
#       player's kills and character, best first. Spots with no player are hidden.

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Live HUD")
## Top-left timer Label. Updated every frame from run_manager.time_elapsed.
@export var hud_timer_label: Label
## Top-left coins Label. Automatically connects to the first player's coins_changed signal.
@export var hud_coins_label: Label
## Label that displays the all-time best survival time (loaded from browser localStorage).
@export var hud_best_time_label: Label
## Label showing the active multiplayer session ID. Leave empty for solo play.
@export var session_id_label: Label
## VerticalHealthBar (e.g. the "VerticalHealthBar" child of a CastleHPBar instance).
## Automatically connects to the castle's health_changed signal once RunManager is found.
@export var castle_hp_bar: Node
## Optional RunManager override. If left empty, the HUD finds it after the level loads.
@export var run_manager: Node

@export_group("Game Over Screen")
## Scale applied to the currently selected button. Others return to 1.0.
@export var selected_button_scale: float = 1.25
## The root Control that shows/hides when the game ends. Hidden on _ready.
@export var game_over_control: Control
## Optional Label for the status message (e.g. "CASTLE DESTROYED").
@export var game_over_label: Label
## Optional Label for the survived time (e.g. "Survived 1:23").
@export var game_over_time_label: Label
## Button to restart the run.
@export var restart_button: Button
## Button to quit to menu (game-over screen).
@export var quit_button: Button
## Smaller quit button visible during play (not just on game-over screen).
@export var in_game_quit_button: Button
## Podium spots (PodiumPlace on the game-over screen). Filled by kill count, best first.
@export var podium_first: PodiumPlace
@export var podium_second: PodiumPlace
@export var podium_third: PodiumPlace

@export_group("Pause Menu")
## Button that opens the pause menu. Automatically hidden in online sessions —
## you can't freeze the tree without desyncing peers, so pause is solo-only.
@export var pause_button: Button
## Root Control for the pause overlay. Hidden by default. Set its process_mode to
## "When Paused" in the Inspector so its buttons still respond while the tree is frozen.
@export var pause_control: Control
## Resume button inside pause_control.
@export var pause_resume_button: Button
## Restart button inside pause_control (reuses the game-over restart path).
@export var pause_restart_button: Button
## Quit-to-menu button inside pause_control.
@export var pause_quit_button: Button
## Opens the character-details panel from the pause menu.
@export var pause_details_button: Button
## The details panel itself (holds the per-character containers + a Close button).
## Hidden until pause_details_button is pressed.
@export var pause_details_panel: Control
## Close button inside pause_details_panel — hides it, back to the pause menu.
@export var pause_details_close_button: Button
## Per-character detail containers inside pause_details_panel. Only the one
## matching the player's chosen character (GameManager.my_character) is shown.
@export var pause_knight_container: Control
@export var pause_archer_container: Control
@export var pause_rogue_container: Control

@export_group("Tutorial")
## Root Control shown/hidden while a tutorial explanation panel is up.
## Its process_mode is "When Paused" so it stays interactive while the tree is frozen.
@export var tutorial_pause_control: Control
## Label inside tutorial_pause_control showing the current step's instructions.
@export var tutorial_panel_label: Label
## Full-rect invisible button behind/over the panel — "click anywhere to continue".
@export var tutorial_advance_button: Button
## Panel flashed over the stat pips to draw attention to them.
@export var tutorial_stat_highlight: Control

@export_group("Settings Screen")
## Root Control for the in-run settings overlay. Hidden by default.
@export var settings_control: Control
## Button that opens/closes the settings overlay (visible during play).
@export var settings_button: Button
## HSlider for music volume (min 0, max 1).
@export var music_slider: HSlider
## HSlider for SFX volume (min 0, max 1).
@export var sfx_slider: HSlider
## Button inside the settings panel that closes it.
@export var close_settings_button: Button

# ── Runtime state ─────────────────────────────────────────────────────────────

var _buttons: Array[Button] = []
var _selected: int = 0
var _coins_connected: bool = false
var _castle_hp_connected: bool = false
var _prev_coins: int = 0
var _prev_minute: int = -1
var _coins_tween: Tween = null
var _timer_tween: Tween = null
var _stat_highlight_tween: Tween = null

# Castle HP bar shake — mirrors level_camera.gd's trauma-based shake.
const HP_BAR_SHAKE_MAX_OFFSET: float = 8.0
const HP_BAR_SHAKE_DECAY: float = 3.0
var _hp_bar_shake_trauma: float = 0.0
var _hp_bar_base_position: Vector2 = Vector2.ZERO
## The node actually shaken. castle_hp_bar (VerticalHealthBar) has no sprites
## of its own — its fill draws into a sibling sprite (HpFill) — so we shake
## its parent (the CastleHPBar root), which holds all the visible sprites.
var _hp_bar_shake_node: Node2D = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_resolve_run_manager()
	if game_over_control != null:
		game_over_control.hide()
	if settings_control != null:
		settings_control.hide()
	# HUD keeps processing while the tree is paused so keyboard pause-toggle and
	# the pause overlay's buttons still work. _process() early-outs when paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_pause_menu()
	_setup_tutorial_ui()
	var _focus_empty := StyleBoxEmpty.new()
	if restart_button != null:
		restart_button.pressed.connect(_on_restart_pressed)
		restart_button.add_theme_stylebox_override(&"focus", _focus_empty)
		_buttons.append(restart_button)
	if quit_button != null:
		quit_button.pressed.connect(_on_quit_pressed)
		quit_button.add_theme_stylebox_override(&"focus", _focus_empty)
		_buttons.append(quit_button)
	if in_game_quit_button != null:
		in_game_quit_button.pressed.connect(_on_quit_pressed)
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_button_pressed)
	if close_settings_button != null:
		close_settings_button.pressed.connect(_on_close_settings_pressed)
	if music_slider != null:
		music_slider.min_value = 0.0
		music_slider.max_value = 1.0
		music_slider.step = 0.01
		music_slider.value = AudioManager.music_volume_linear
		music_slider.value_changed.connect(_on_music_slider_changed)
	if sfx_slider != null:
		sfx_slider.min_value = 0.0
		sfx_slider.max_value = 1.0
		sfx_slider.step = 0.01
		sfx_slider.value = AudioManager.sfx_volume_linear
		sfx_slider.value_changed.connect(_on_sfx_slider_changed)
	if hud_coins_label != null:
		hud_coins_label.text = "0"
	if session_id_label != null:
		var sid: String = GameManager.session_id if "session_id" in GameManager else ""
		session_id_label.visible = sid != ""
		if sid != "":
			session_id_label.text = "ID: " + sid
	_try_connect_coins()
	_try_connect_castle_hp()
	_refresh_best_time_label()


func _process(delta: float) -> void:
	# process_mode is ALWAYS (see _ready) so keyboard pause-toggle keeps working;
	# skip all the per-frame HUD work while the run is frozen.
	if get_tree().paused:
		return
	# Update the live timer label every frame.
	if hud_timer_label != null and run_manager != null and "time_elapsed" in run_manager:
		var total: int = int(run_manager.time_elapsed)
		var minutes: int = total / 60
		hud_timer_label.text = "%d:%02d" % [minutes, total % 60]
		if minutes > 0 and minutes != _prev_minute:
			_prev_minute = minutes
			_play_timer_juice()
	# Retry coin connection each frame until a player enters the scene tree.
	if not _coins_connected:
		_try_connect_coins()
	if not _castle_hp_connected:
		_try_connect_castle_hp()
	if run_manager == null:
		_resolve_run_manager()
	_update_hp_bar_shake(delta)


func _update_hp_bar_shake(delta: float) -> void:
	if _hp_bar_shake_node == null or _hp_bar_shake_trauma <= 0.0:
		return
	var falloff := _hp_bar_shake_trauma * _hp_bar_shake_trauma
	var shake_offset := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * HP_BAR_SHAKE_MAX_OFFSET * falloff
	_hp_bar_shake_node.position = _hp_bar_base_position + shake_offset
	_hp_bar_shake_trauma = maxf(0.0, _hp_bar_shake_trauma - HP_BAR_SHAKE_DECAY * delta)
	if _hp_bar_shake_trauma <= 0.0:
		_hp_bar_shake_node.position = _hp_bar_base_position


func _unhandled_input(event: InputEvent) -> void:
	# Esc toggles the pause menu in solo runs (also unpauses).
	if event.is_action_pressed(&"ui_cancel") and _can_pause() \
			and not (game_over_control and game_over_control.visible):
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if not (game_over_control and game_over_control.visible):
		return
	if event.is_action_pressed(&"move_up"):
		_selected = maxi(0, _selected - 1)
		_update_selection()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"move_down"):
		_selected = mini(_selected + 1, _buttons.size() - 1)
		_update_selection()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"slash") or event.is_action_pressed(&"thrust"):
		get_viewport().set_input_as_handled()
		if _selected >= 0 and _selected < _buttons.size():
			_buttons[_selected].pressed.emit()


func _update_selection() -> void:
	for i in _buttons.size():
		var s := selected_button_scale if i == _selected else 1.0
		_buttons[i].scale = Vector2(s, s)
		_buttons[i].pivot_offset = _buttons[i].size / 2.0
	if _selected >= 0 and _selected < _buttons.size():
		_buttons[_selected].grab_focus()


# ── Coin connection ───────────────────────────────────────────────────────────

func _resolve_run_manager() -> void:
	if run_manager != null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var nodes: Array[Node] = tree.get_nodes_in_group(&"run_manager")
	if not nodes.is_empty():
		run_manager = nodes[0]
		return
	var current_scene := tree.current_scene
	if current_scene == null:
		return
	run_manager = current_scene.find_child("RunManager", true, false)


func _try_connect_castle_hp() -> void:
	if castle_hp_bar == null or not castle_hp_bar.has_method(&"set_health"):
		_castle_hp_connected = true
		return
	if run_manager == null or not ("castle" in run_manager):
		return
	var castle_node: Node = run_manager.castle
	if castle_node == null or not castle_node.has_signal(&"health_changed"):
		return
	castle_node.health_changed.connect(_on_castle_health_changed)
	if castle_node.has_signal(&"low_hp_pulse"):
		castle_node.low_hp_pulse.connect(_on_castle_low_hp_pulse)
	var parent := castle_hp_bar.get_parent()
	_hp_bar_shake_node = parent if parent is Node2D else castle_hp_bar
	_hp_bar_base_position = _hp_bar_shake_node.position
	if "health" in castle_node and "max_health" in castle_node:
		_on_castle_health_changed(castle_node.health, castle_node.max_health)
	_castle_hp_connected = true


func _on_castle_health_changed(new_health: float, max_hp: float) -> void:
	if castle_hp_bar != null:
		castle_hp_bar.set_health(new_health, max_hp)


func _on_castle_low_hp_pulse() -> void:
	_hp_bar_shake_trauma = 1.0


func _try_connect_coins() -> void:
	if hud_coins_label == null:
		_coins_connected = true
		return
	var players: Array[Node] = get_tree().get_nodes_in_group(&"players")
	for p in players:
		if p.has_signal(&"coins_changed"):
			p.coins_changed.connect(_on_coins_changed)
			if "coins" in p:
				var initial: int = int(p.coins)
				hud_coins_label.text = str(initial)
				_prev_coins = initial
			_coins_connected = true
			return


func _on_coins_changed(new_coins: int) -> void:
	if hud_coins_label == null:
		return
	hud_coins_label.text = str(new_coins)
	if new_coins > _prev_coins:
		_play_coins_juice(Color.GREEN)
	elif new_coins < _prev_coins:
		_play_coins_juice(Color.RED)
	_prev_coins = new_coins


func _play_coins_juice(color: Color) -> void:
	hud_coins_label.pivot_offset = hud_coins_label.size / 3.0
	if _coins_tween:
		_coins_tween.kill()
	hud_coins_label.modulate = color
	_coins_tween = create_tween()
	_coins_tween.tween_property(hud_coins_label, "scale", Vector2(1.35, 1.35), 0.12).set_ease(Tween.EASE_OUT)
	_coins_tween.tween_property(hud_coins_label, "scale", Vector2(1.0, 1.0), 0.2).set_ease(Tween.EASE_IN)
	_coins_tween.parallel().tween_property(hud_coins_label, "modulate", Color.WHITE, 0.25).set_ease(Tween.EASE_IN)


## Called by shop nodes (CastleInside, UnitHut) when a purchase attempt fails
## for lack of coins. Grows the coin label to 2x scale, flashes it red, then
## eases back to normal size/colour over ~1 second.
func flash_insufficient() -> void:
	if hud_coins_label == null:
		return
	hud_coins_label.pivot_offset = hud_coins_label.size / 3.0
	if _coins_tween:
		_coins_tween.kill()
	hud_coins_label.modulate = Color.RED
	_coins_tween = create_tween()
	_coins_tween.tween_property(hud_coins_label, "scale", Vector2(2.0, 2.0), 0.3).set_ease(Tween.EASE_OUT)
	_coins_tween.tween_property(hud_coins_label, "scale", Vector2(1.0, 1.0), 0.7).set_ease(Tween.EASE_IN)
	_coins_tween.parallel().tween_property(hud_coins_label, "modulate", Color.WHITE, 0.7).set_ease(Tween.EASE_IN)


func _play_timer_juice() -> void:
	hud_timer_label.pivot_offset = hud_timer_label.size / 3.0
	if _timer_tween:
		_timer_tween.kill()
	_timer_tween = create_tween()
	_timer_tween.tween_property(hud_timer_label, "scale", Vector2(1.4, 1.4), 0.15).set_ease(Tween.EASE_OUT)
	_timer_tween.tween_property(hud_timer_label, "scale", Vector2(1.0, 1.0), 0.25).set_ease(Tween.EASE_IN)


# ── Game over ─────────────────────────────────────────────────────────────────

## Called by RunManager when the castle dies. standings is the podium order, best first
## ({"slot", "ch" (character key), "k" (kills)}); character_scenes maps "ch" to the
## character's PackedScene so each podium spot can show its idle animation.
func show_screen(run_time_seconds: float, standings: Array = [], character_scenes: Dictionary = {}) -> void:
	GameManager.submit_time(run_time_seconds)
	_refresh_best_time_label()
	_selected = 0
	if game_over_control != null:
		game_over_control.show()
	if game_over_label != null:
		game_over_label.text = "CASTLE DESTROYED"
	if game_over_time_label != null:
		var mins := int(run_time_seconds) / 60
		var secs := int(run_time_seconds) % 60
		game_over_time_label.text = "Survived  %d:%02d" % [mins, secs]
	_fill_podium(standings, character_scenes)
	_update_selection()


## Spots with no player behind them are hidden, so a solo run stands alone in first.
func _fill_podium(standings: Array, character_scenes: Dictionary) -> void:
	var places: Array[PodiumPlace] = [podium_first, podium_second, podium_third]
	for i in places.size():
		var place: PodiumPlace = places[i]
		if place == null:
			continue
		if i >= standings.size():
			place.hide()
			continue
		var entry: Dictionary = standings[i]
		place.show_entry(int(entry.get("k", 0)),
				character_scenes.get(String(entry.get("ch", ""))) as PackedScene)


func _refresh_best_time_label() -> void:
	if hud_best_time_label == null:
		return
	if GameManager.best_time <= 0.0:
		hud_best_time_label.text = "BEST: --:--"
	else:
		var mins := int(GameManager.best_time) / 60
		var secs := int(GameManager.best_time) % 60
		hud_best_time_label.text = "BEST: %d:%02d" % [mins, secs]


# ── Pause menu ────────────────────────────────────────────────────────────────

## Pause is solo-only: freezing get_tree() in an online session would desync peers.
func _can_pause() -> bool:
	return GameManager.session_id == ""


func _setup_pause_menu() -> void:
	if pause_control != null:
		pause_control.hide()
		pause_control.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	if pause_button != null:
		pause_button.visible = _can_pause()
		if _can_pause():
			pause_button.pressed.connect(_toggle_pause)
	if pause_resume_button != null:
		pause_resume_button.pressed.connect(_set_paused.bind(false))
	if pause_restart_button != null:
		pause_restart_button.pressed.connect(func() -> void:
			_set_paused(false)
			_on_restart_pressed())
	if pause_quit_button != null:
		pause_quit_button.pressed.connect(func() -> void:
			_set_paused(false)
			_on_quit_pressed())
	if pause_details_panel != null:
		pause_details_panel.hide()
	if pause_details_button != null:
		pause_details_button.pressed.connect(_open_pause_details)
	if pause_details_close_button != null:
		pause_details_close_button.pressed.connect(_close_pause_details)


func _toggle_pause() -> void:
	_set_paused(not get_tree().paused)


func _set_paused(want_paused: bool) -> void:
	if not _can_pause():
		return
	get_tree().paused = want_paused
	if pause_control != null:
		pause_control.visible = want_paused
	# Always return to the pause menu proper — details panel opens on demand.
	if not want_paused:
		_close_pause_details()
	elif pause_details_panel != null:
		pause_details_panel.hide()


## Opens the character-details panel showing only the player's character.
func _open_pause_details() -> void:
	_show_pause_character(GameManager.my_character)
	if pause_details_panel != null:
		pause_details_panel.show()


func _close_pause_details() -> void:
	if pause_details_panel != null:
		pause_details_panel.hide()


## Shows only the details container matching the player's chosen character.
## Falls back to the Knight (the default solo character) for an unset key.
func _show_pause_character(character_key: String) -> void:
	var containers := {
		"red_knight":   pause_knight_container,
		"green_archer": pause_archer_container,
		"rogue":        pause_rogue_container,
	}
	var shown_key := character_key if character_key in containers else "red_knight"
	for key in containers:
		var c: Control = containers[key]
		if c != null:
			c.visible = (key == shown_key)


# ── Tutorial panel ────────────────────────────────────────────────────────────

func _setup_tutorial_ui() -> void:
	if tutorial_pause_control != null:
		tutorial_pause_control.hide()
	if tutorial_stat_highlight != null:
		tutorial_stat_highlight.modulate.a = 0.0
	if tutorial_advance_button != null:
		var empty := StyleBoxEmpty.new()
		for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
			tutorial_advance_button.add_theme_stylebox_override(style_name, empty)
		tutorial_advance_button.text = ""
		tutorial_advance_button.focus_mode = Control.FOCUS_NONE


## Called by TutorialRunManager. Shows the pause-and-explain panel with `text`;
## the caller awaits tutorial_advance_button.pressed to know when it was dismissed.
func show_tutorial_panel(text: String) -> void:
	if tutorial_panel_label != null:
		tutorial_panel_label.text = text
	if tutorial_pause_control != null:
		tutorial_pause_control.show()


func hide_tutorial_panel() -> void:
	if tutorial_pause_control != null:
		tutorial_pause_control.hide()
	_stop_stat_highlight()


## Pulses the stat pips highlight (0 -> 200 -> 0 alpha, repeating) to draw the
## player's attention to them. Runs until hide_tutorial_panel() stops it.
func flash_stat_highlight() -> void:
	if tutorial_stat_highlight == null:
		return
	_stop_stat_highlight()
	tutorial_stat_highlight.modulate.a = 0.0
	_stat_highlight_tween = create_tween()
	_stat_highlight_tween.set_loops()
	_stat_highlight_tween.tween_property(tutorial_stat_highlight, "modulate:a", 200.0 / 255.0, 0.5)
	_stat_highlight_tween.tween_property(tutorial_stat_highlight, "modulate:a", 0.0, 0.5)


func _stop_stat_highlight() -> void:
	if _stat_highlight_tween != null and _stat_highlight_tween.is_valid():
		_stat_highlight_tween.kill()
	_stat_highlight_tween = null
	if tutorial_stat_highlight != null:
		tutorial_stat_highlight.modulate.a = 0.0


# ── Button callbacks ──────────────────────────────────────────────────────────

func _on_settings_button_pressed() -> void:
	if settings_control != null:
		settings_control.visible = not settings_control.visible


func _on_close_settings_pressed() -> void:
	if settings_control != null:
		settings_control.hide()


func _on_music_slider_changed(value: float) -> void:
	AudioManager.set_music_volume(value)


func _on_sfx_slider_changed(value: float) -> void:
	AudioManager.set_sfx_volume(value)


func _on_restart_pressed() -> void:
	if GameManager.session_id == "" or GameManager.is_host:
		# Solo or host: if host, tell joiner to restart before reloading.
		if GameManager.session_id != "" and GameManager.is_host:
			WebRTCManager.send_reliable({"t": "restart"})
		get_tree().reload_current_scene()
	else:
		# Joiner: cannot restart on their own — wait for the host to restart.
		if restart_button != null:
			restart_button.text = "Waiting for host..."
			restart_button.disabled = true


func _on_quit_pressed() -> void:
	GameManager.leave_session()

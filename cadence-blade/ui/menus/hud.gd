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

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_resolve_run_manager()
	if game_over_control != null:
		game_over_control.hide()
	if settings_control != null:
		settings_control.hide()
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


func _process(_delta: float) -> void:
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


func _unhandled_input(event: InputEvent) -> void:
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
	if "health" in castle_node and "max_health" in castle_node:
		_on_castle_health_changed(castle_node.health, castle_node.max_health)
	_castle_hp_connected = true


func _on_castle_health_changed(new_health: float, max_hp: float) -> void:
	if castle_hp_bar != null:
		castle_hp_bar.set_health(new_health, max_hp)


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

## Called by RunManager when the castle dies.
func show_screen(run_time_seconds: float) -> void:
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
	_update_selection()


func _refresh_best_time_label() -> void:
	if hud_best_time_label == null:
		return
	if GameManager.best_time <= 0.0:
		hud_best_time_label.text = "BEST: --:--"
	else:
		var mins := int(GameManager.best_time) / 60
		var secs := int(GameManager.best_time) % 60
		hud_best_time_label.text = "BEST: %d:%02d" % [mins, secs]


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

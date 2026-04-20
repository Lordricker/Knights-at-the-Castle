class_name GameOverScreen
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
## Button to quit to menu.
@export var quit_button: Button

# ── Runtime state ─────────────────────────────────────────────────────────────

var _buttons: Array[Button] = []
var _selected: int = 0
var _coins_connected: bool = false

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_resolve_run_manager()
	if game_over_control != null:
		game_over_control.hide()
	var _focus_empty := StyleBoxEmpty.new()
	if restart_button != null:
		restart_button.pressed.connect(_on_restart_pressed)
		restart_button.add_theme_stylebox_override(&"focus", _focus_empty)
		_buttons.append(restart_button)
	if quit_button != null:
		quit_button.pressed.connect(_on_quit_pressed)
		quit_button.add_theme_stylebox_override(&"focus", _focus_empty)
		_buttons.append(quit_button)
	if hud_coins_label != null:
		hud_coins_label.text = "0"
	_try_connect_coins()
	_refresh_best_time_label()


func _process(_delta: float) -> void:
	# Update the live timer label every frame.
	if hud_timer_label != null and run_manager != null and "time_elapsed" in run_manager:
		var total: int = int(run_manager.time_elapsed)
		hud_timer_label.text = "%d:%02d" % [total / 60, total % 60]
	# Retry coin connection each frame until a player enters the scene tree.
	if not _coins_connected:
		_try_connect_coins()
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

func _try_connect_coins() -> void:
	if hud_coins_label == null:
		_coins_connected = true
		return
	var players: Array[Node] = get_tree().get_nodes_in_group(&"players")
	for p in players:
		if p.has_signal(&"coins_changed"):
			p.coins_changed.connect(_on_coins_changed)
			if "coins" in p:
				_on_coins_changed(int(p.coins))
			_coins_connected = true
			return


func _on_coins_changed(new_coins: int) -> void:
	if hud_coins_label != null:
		hud_coins_label.text = str(new_coins)


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

func _on_restart_pressed() -> void:
	get_tree().reload_current_scene()


func _on_quit_pressed() -> void:
	get_tree().quit()

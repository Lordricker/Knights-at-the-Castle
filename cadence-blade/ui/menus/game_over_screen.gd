class_name GameOverScreen
extends CanvasLayer

# game_over_screen.gd — Game-over overlay showing run time and offering restart/quit.
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Manually add these nodes as children of this CanvasLayer, then wire them in
#   the Inspector:
#   • Control (game_over_control) — the main panel, hidden by default
#     ├── Label (game_over_label) — displays "Castle has died" or victory text
#     ├── Label (time_label) — displays run time (e.g. "1:23")
#     ├── Button (restart_button) — press to restart
#     └── Button (quit_button) — press to quit
#
#   Wire all four into the exports below.

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("UI References")
## The root Control that shows/hides when the game ends. Assign in Inspector.
@export var game_over_control: Control
## Label that displays the status message (e.g. "GAME OVER").
@export var game_over_label: Label
## Label that displays elapsed time (e.g. "Survived 1:23").
@export var time_label: Label
## Button to restart the run.
@export var restart_button: Button
## Button to quit to menu.
@export var quit_button: Button

# ── Runtime state ────────────────────────────────────────────────────────────

var _buttons: Array[Button] = []
var _selected: int = 0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	if game_over_control != null:
		game_over_control.hide()
	if restart_button != null:
		restart_button.pressed.connect(_on_restart_pressed)
		_buttons.append(restart_button)
	if quit_button != null:
		quit_button.pressed.connect(_on_quit_pressed)
		_buttons.append(quit_button)


func _unhandled_input(event: InputEvent) -> void:
	if not (game_over_control and game_over_control.visible):
		return
	if event.is_action_pressed(&"move_up"):
		_selected = maxi(0, _selected - 1)
		_update_selection()
		get_tree().root.set_input_as_handled()
	elif event.is_action_pressed(&"move_down"):
		_selected = mini(_selected + 1, _buttons.size() - 1)
		_update_selection()
		get_tree().root.set_input_as_handled()
	elif event.is_action_pressed(&"slash") or event.is_action_pressed(&"thrust"):
		if _selected >= 0 and _selected < _buttons.size():
			_buttons[_selected].pressed.emit()
		get_tree().root.set_input_as_handled()


func _update_selection() -> void:
	if _selected >= 0 and _selected < _buttons.size():
		_buttons[_selected].grab_focus()


## Called by RunManager when the castle dies.
func show_screen(run_time_seconds: float) -> void:
	_selected = 0
	if game_over_control != null:
		game_over_control.show()
	if game_over_label != null:
		game_over_label.text = "CASTLE DESTROYED"
	if time_label != null:
		var mins := int(run_time_seconds) / 60
		var secs := int(run_time_seconds) % 60
		time_label.text = "Survived  %d:%02d" % [mins, secs]
	_update_selection()


# ── Button callbacks ──────────────────────────────────────────────────────────

func _on_restart_pressed() -> void:
	get_tree().reload_current_scene()


func _on_quit_pressed() -> void:
	get_tree().quit()

class_name GameOverScreen
extends CanvasLayer

# game_over_screen.gd — Game-over overlay with sprite-based buttons and
# keyboard / mouse navigation.
#
# ── SCENE PLACEMENT ───────────────────────────────────────────────────────────
#   Add a CanvasLayer to your level scene and attach this script.
#   Wire it into RunManager.game_over_screen.
#
# ── INSPECTOR SETUP ───────────────────────────────────────────────────────────
#   • Drag your restart-button texture into restart_texture.
#   • Drag your quit-button texture into quit_texture.
#   • Textures should already have button text baked in — no text is
#     rendered by code.
#   • Tune selected_scale and button_gap to taste.
#
# ── CONTROLS ──────────────────────────────────────────────────────────────────
#   W / move_up   — highlight Restart
#   S / move_down — highlight Quit
#   J (slash) or K (thrust) — confirm selected button
#   Left-click on a button — confirm that button directly

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Button Sprites")
## Texture with "Restart" text baked in.  No code text is added.
@export var restart_texture: Texture2D
## Texture with "Quit" text baked in.
@export var quit_texture: Texture2D
## Horizontal offset from screen centre for the Restart button (pixels).
@export var restart_x_offset: float = 0.0
## Horizontal offset from screen centre for the Quit button (pixels).
@export var quit_x_offset: float = 0.0

@export_group("Selection")
## How much larger the selected button renders (1.15 = 15 % bigger).
@export var selected_scale: float = 1.15
## Vertical gap in pixels between the two buttons.
@export var button_gap: float = 16.0

# ── Runtime ───────────────────────────────────────────────────────────────────

var _time_label: Label
var _buttons: Array[Sprite2D] = []
var _selected: int = 0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_build_ui()
	hide()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"move_up"):
		_selected = maxi(0, _selected - 1)
		_update_selection()
	elif event.is_action_pressed(&"move_down"):
		_selected = mini(_selected + 1, _buttons.size() - 1)
		_update_selection()
	elif event.is_action_pressed(&"slash") or event.is_action_pressed(&"thrust"):
		_confirm()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			for i in _buttons.size():
				if _sprite_hit(_buttons[i], mb.position):
					_selected = i
					_confirm()
					return


## Called by RunManager when the castle dies.
func show_screen(run_time_seconds: float) -> void:
	_selected = 0
	_update_selection()
	var mins := int(run_time_seconds) / 60
	var secs := int(run_time_seconds) % 60
	_time_label.text = "Survived  %d:%02d" % [mins, secs]
	show()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var vp := get_viewport().get_visible_rect().size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.5

	# Semi-transparent dim overlay.
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Title label.
	var title := Label.new()
	title.text = "THE CASTLE HAS FALLEN"
	title.add_theme_color_override(&"font_color", Color(0.88, 0.18, 0.12))
	title.position = Vector2(cx - 120.0, cy - 90.0)
	add_child(title)

	# Run-time label (text filled in by show_screen).
	_time_label = Label.new()
	_time_label.position = Vector2(cx - 70.0, cy - 55.0)
	add_child(_time_label)

	# Sprite buttons — Restart then Quit, stacked vertically below centre.
	var textures: Array = [restart_texture, quit_texture]
	var x_offsets: Array = [restart_x_offset, quit_x_offset]
	var y := cy + 10.0
	for i in textures.size():
		var tex: Texture2D = textures[i]
		var h: float = tex.get_height() if tex != null else 32.0
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.position = Vector2(cx + x_offsets[i], y + h * 0.5)
		add_child(spr)
		_buttons.append(spr)
		y += h + button_gap

	_update_selection()


func _update_selection() -> void:
	for i in _buttons.size():
		var s := selected_scale if i == _selected else 1.0
		_buttons[i].scale = Vector2(s, s)


## Returns true if point is inside the sprite's scaled bounding rect.
func _sprite_hit(spr: Sprite2D, point: Vector2) -> bool:
	if spr.texture == null:
		return false
	var half := spr.texture.get_size() * spr.scale * 0.5
	return Rect2(spr.position - half, half * 2.0).has_point(point)


# ── Confirm ───────────────────────────────────────────────────────────────────

func _confirm() -> void:
	if _selected == 0:
		_on_restart()
	else:
		_on_quit()


func _on_restart() -> void:
	GameManager.change_state(GameManager.GameState.MENU)
	get_tree().reload_current_scene()


func _on_quit() -> void:
	get_tree().quit()

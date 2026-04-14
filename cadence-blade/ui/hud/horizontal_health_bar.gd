class_name HorizontalHealthBar
extends Node2D

# horizontal_health_bar.gd — Masked horizontal health bar using clip_children.
# Fills left-to-right, otherwise identical to VerticalHealthBar.
#
# HOW TO USE:
#   1. Add a Node2D (e.g. "HPBar") to the castle. Attach this script.
#   2. Add a Sprite2D as its child. Assign your white fill-area mask PNG as its
#      texture — WHITE where the fill shows, TRANSPARENT elsewhere.
#   3. In the Inspector on HPBar, drag that Sprite2D into the "Fill Window" slot.
#   4. Place your decorative frame art separately however you like.
#
# The script sets clip_children = CLIP_CHILDREN_ONLY on the fill_window sprite,
# clipping all fill drawing to the PNG's opaque pixels.

@export_group("Fill Window")
## Drag your white fill-area mask Sprite2D here.
@export var fill_window: Sprite2D

@export_group("Colors")
@export var fill_color: Color = Color(0.15, 0.75, 0.15, 1.0)
@export var background_color: Color = Color(0.06, 0.06, 0.06, 0.75)

@export_group("Fill")
## Local X of the 0% HP mark (left edge of the fill).
@export var fill_left_x: float = 0.0
## Local X of the 100% HP mark (right edge of the fill).
@export var fill_right_x: float = 100.0

var _ratio: float = 1.0
var _draw_node: Node2D


func _ready() -> void:
	if fill_window == null:
		push_error(name + ": fill_window is not assigned in the Inspector.")
		return
	fill_window.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_draw_node = Node2D.new()
	fill_window.add_child(_draw_node)
	_draw_node.draw.connect(_on_draw_fill)
	_draw_node.queue_redraw()


func set_health(current_health: float, max_health: float) -> void:
	_ratio = clampf(current_health / maxf(max_health, 0.001), 0.0, 1.0)
	_redraw()


func set_ratio(value: float) -> void:
	_ratio = clampf(value, 0.0, 1.0)
	_redraw()


func _redraw() -> void:
	if _draw_node != null:
		_draw_node.queue_redraw()


func _get_local_bounds() -> Rect2:
	if fill_window == null or fill_window.texture == null:
		return Rect2(Vector2(-50.0, -5.0), Vector2(100.0, 10.0))
	var sz := fill_window.texture.get_size()
	var off := fill_window.offset
	if fill_window.centered:
		return Rect2(-sz * 0.5 + off, sz)
	return Rect2(off, sz)


func _on_draw_fill() -> void:
	var b := _get_local_bounds()

	# Background fills the entire window area.
	_draw_node.draw_rect(b, background_color)

	var total_w := fill_right_x - fill_left_x
	if total_w <= 0.0:
		return
	var filled_w := total_w * _ratio
	if filled_w <= 0.0:
		return

	_draw_node.draw_rect(Rect2(Vector2(fill_left_x, b.position.y), Vector2(filled_w, b.size.y)), fill_color)

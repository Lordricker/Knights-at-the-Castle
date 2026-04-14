class_name VerticalHealthBar
extends Node2D

# vertical_health_bar.gd — Masked vertical health bar using clip_children.
#
# HOW TO USE:
#   1. Add a Node2D to the character. Name it "HealthBar". Attach this script.
#   2. Add a Sprite2D as a child (of HealthBar or anywhere nearby). Assign your white
#      fill-area mask PNG as its texture. The PNG should be WHITE where the fill
#      should show, TRANSPARENT everywhere else.
#   3. In the Inspector on HealthBar, drag that Sprite2D into the "Fill Window" slot.
#   4. Place your decorative container frame art separately however you like.
#
# The script sets clip_children = CLIP_CHILDREN_ONLY on the fill_window sprite.
# Godot clips all fill drawing to the PNG's non-transparent pixels, giving the
# correct curved/custom shape. The white PNG itself is not visible.

@export_group("Fill Window")
## Drag your white fill-area mask Sprite2D here.
@export var fill_window: Sprite2D

@export_group("Colors")
@export var fill_color: Color = Color(0.86, 0.12, 0.12, 1.0)
@export var background_color: Color = Color(0.06, 0.06, 0.06, 0.75)

@export_group("Fill")
## Local Y of the 100% HP mark (top of the fill, at this node's origin).
@export var fill_top_y: float = 0.0
## Local Y of the 0% HP mark (bottom of the fill, Y increases downward in Godot).
@export var fill_bottom_y: float = 60.0

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


# Returns the fill_window sprite's bounds in its own local space,
# accounting for the centered flag and offset property.
func _get_local_bounds() -> Rect2:
	if fill_window == null or fill_window.texture == null:
		return Rect2(Vector2(-10.0, -30.0), Vector2(20.0, 30.0))
	var sz := fill_window.texture.get_size()
	var off := fill_window.offset
	if fill_window.centered:
		return Rect2(-sz * 0.5 + off, sz)
	return Rect2(off, sz)


func _on_draw_fill() -> void:
	var b := _get_local_bounds()

	# Background fills the entire window area.
	_draw_node.draw_rect(b, background_color)

	var total_h := fill_bottom_y - fill_top_y
	if total_h <= 0.0:
		return
	var filled_h := total_h * _ratio
	if filled_h <= 0.0:
		return

	var top_y := fill_bottom_y - filled_h
	_draw_node.draw_rect(Rect2(Vector2(b.position.x, top_y), Vector2(b.size.x, filled_h)), fill_color)

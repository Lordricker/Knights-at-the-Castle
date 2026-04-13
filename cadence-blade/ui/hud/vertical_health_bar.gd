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
## What fraction of the window height counts as 100% HP.
## Lower this to shrink the maximum fill height so hits are visible from the start.
@export_range(0.1, 1.0, 0.01) var fill_height_ratio: float = 0.75

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

	# Cap the usable height so 100% HP never reaches the very top.
	var usable_h := b.size.y * fill_height_ratio
	var filled_h := usable_h * _ratio
	if filled_h > 0.0:
		_draw_node.draw_rect(
			Rect2(Vector2(b.position.x, b.end.y - filled_h), Vector2(b.size.x, filled_h)),
			fill_color
		)

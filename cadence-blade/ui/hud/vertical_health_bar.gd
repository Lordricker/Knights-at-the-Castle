class_name VerticalHealthBar
extends Node2D

# vertical_health_bar.gd — Masked vertical health bar.
#
# HOW TO USE:
#   1. Add a Node2D to the character. Name it "HealthBar". Attach this script.
#   2. Add a Sprite2D as a child (of HealthBar or anywhere nearby). Assign your white
#      fill-area mask PNG as its texture. The PNG should be WHITE where the fill
#      should show, TRANSPARENT everywhere else.
#   3. In the Inspector on HealthBar, drag that Sprite2D into the "Fill Window" slot.
#   4. Place your decorative container frame art separately however you like.
#
# The script gives the fill_window sprite the masked_bar shader, which paints the
# fill only on the PNG's non-transparent pixels, giving the correct curved/custom
# shape. The white PNG itself is not visible. (clip_children used to do this, but
# Safari ignores it and drew the fill as one big rectangle.)

@export_group("Fill Window")
## Drag your white fill-area mask Sprite2D here.
@export var fill_window: Sprite2D

@export_group("Colors")
## How the fill color is chosen:
##   AUTO   - walk up the parent chain, pick ENEMY tint if the owner is an
##            EnemyBase (or in the "enemies" group), otherwise ALLY tint.
##   ALLY   - always use ally_fill_color.
##   ENEMY  - always use enemy_fill_color.
enum Team { AUTO, ALLY, ENEMY }
@export var team: Team = Team.AUTO
## Fill tint for friendly units (players, hut units, castle, towers).
@export var ally_fill_color: Color = Color(0.15, 0.75, 0.15, 1.0)
## Fill tint for hostile units.
@export var enemy_fill_color: Color = Color(0.86, 0.12, 0.12, 1.0)
## Resolved at runtime from the settings above; also used as a manual override
## if you set it in a script before _ready().
@export var fill_color: Color = Color(0.86, 0.12, 0.12, 1.0)
@export var background_color: Color = Color(0.06, 0.06, 0.06, 0.75)

@export_group("Fill")
## Local Y of the 100% HP mark (top of the fill, at this node's origin).
@export var fill_top_y: float = 0.0
## Local Y of the 0% HP mark (bottom of the fill, Y increases downward in Godot).
@export var fill_bottom_y: float = 60.0

const GHOST_HOLD_TIME := 1.0
const GHOST_DRAIN_TIME := 0.35
const MASKED_BAR_SHADER := preload("res://ui/shaders/masked_bar.gdshader")

var _ratio: float = 1.0
var _ghost_ratio: float = 1.0
var _ghost_ratio_start: float = 1.0
var _ghost_hold_timer: float = 0.0
var _ghost_drain_timer: float = 0.0
var _mat: ShaderMaterial


func _ready() -> void:
	fill_color = _resolve_fill_color()
	if fill_window == null:
		push_error(name + ": fill_window is not assigned in the Inspector.")
		return
	_mat = ShaderMaterial.new()
	_mat.shader = MASKED_BAR_SHADER
	fill_window.material = _mat
	_redraw()


func set_health(current_health: float, max_health: float) -> void:
	var new_ratio := clampf(current_health / maxf(max_health, 0.001), 0.0, 1.0)
	if new_ratio < _ratio:
		_ghost_ratio = _ratio
		_ghost_ratio_start = _ratio
		_ghost_hold_timer = GHOST_HOLD_TIME
		_ghost_drain_timer = 0.0
	_ratio = new_ratio
	_redraw()


func set_ratio(value: float) -> void:
	var new_ratio := clampf(value, 0.0, 1.0)
	if new_ratio < _ratio:
		_ghost_ratio = _ratio
		_ghost_ratio_start = _ratio
		_ghost_hold_timer = GHOST_HOLD_TIME
		_ghost_drain_timer = 0.0
	_ratio = new_ratio
	_redraw()


func _process(delta: float) -> void:
	if _ghost_hold_timer > 0.0:
		_ghost_hold_timer -= delta
		if _ghost_hold_timer <= 0.0:
			_ghost_hold_timer = 0.0
			_ghost_drain_timer = GHOST_DRAIN_TIME
		_redraw()
	elif _ghost_drain_timer > 0.0:
		_ghost_drain_timer -= delta
		if _ghost_drain_timer <= 0.0:
			_ghost_drain_timer = 0.0
			_ghost_ratio = _ratio
		else:
			var t := 1.0 - (_ghost_drain_timer / GHOST_DRAIN_TIME)
			_ghost_ratio = lerpf(_ghost_ratio_start, _ratio, t)
		_redraw()


## Pushes the current fill/ghost extents to the mask's shader.
func _redraw() -> void:
	if _mat == null:
		return
	var b := _get_local_bounds()
	_mat.set_shader_parameter(&"vertical", true)
	_mat.set_shader_parameter(&"background_color", background_color)
	_mat.set_shader_parameter(&"band0_color", Color.WHITE)
	_mat.set_shader_parameter(&"band1_color", fill_color)

	var ghost := Vector2.ZERO
	var fill := Vector2.ZERO
	var total_h := fill_bottom_y - fill_top_y
	var filled_h := total_h * _ratio
	if total_h > 0.0 and filled_h > 0.0:
		# Ghost (white) shows the recently lost portion for GHOST_HOLD_TIME seconds.
		if _ghost_ratio > _ratio:
			ghost = Vector2(_to_v(b, fill_bottom_y - _ghost_ratio * total_h), _to_v(b, fill_bottom_y - _ratio * total_h))
		fill = Vector2(_to_v(b, fill_bottom_y - filled_h), _to_v(b, fill_bottom_y))
	_mat.set_shader_parameter(&"band0", ghost)
	_mat.set_shader_parameter(&"band1", fill)


## Picks the fill color from `team`, auto-detecting the owning unit's side by
## walking up the parent chain when team == AUTO.
func _resolve_fill_color() -> Color:
	match team:
		Team.ALLY:
			return ally_fill_color
		Team.ENEMY:
			return enemy_fill_color
		_:
			return enemy_fill_color if _owner_is_enemy() else ally_fill_color


func _owner_is_enemy() -> bool:
	var node: Node = get_parent()
	while node != null:
		if node is EnemyBase or node.is_in_group(&"enemies"):
			return true
		if node is CharacterBase or node is Castle or node.is_in_group(&"hut_units"):
			return false
		node = node.get_parent()
	return false


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


# Local Y inside the fill_window sprite -> its texture's V coordinate.
func _to_v(b: Rect2, y: float) -> float:
	return (y - b.position.y) / maxf(b.size.y, 0.001)

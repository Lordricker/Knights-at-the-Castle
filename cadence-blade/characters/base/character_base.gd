class_name CharacterBase
extends CharacterBody2D

# CharacterBase — shared base class for all playable characters.
# Free 2D movement: WASD moves in X and Y.
# Assign a Path2D to walk_path to constrain Y to that spline.

@export var move_speed: float = 200.0

## How many pixels above/below the path centre the character can freely move.
@export var path_y_margin: float = 40.0

# The AnimatedSprite2D child node must be named exactly "AnimatedSprite2D".
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var walk_path: Path2D = null
var is_dead: bool = false
var knockback_velocity: Vector2 = Vector2.ZERO

## How fast knockback decelerates in pixels/sec².
@export var knockback_friction: float = 800.0

signal died()


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)  # bodies never physically push each other; Area2D masks handle detection
	if animated_sprite == null:
		push_error(str(name) + ": no AnimatedSprite2D child found. Name it 'AnimatedSprite2D'.")
	# Find the walk path from the level scene by group name.
	# Add your Path2D to the group "walk_path" in the level scene.
	var paths: Array[Node] = get_tree().get_nodes_in_group("walk_path")
	if paths.size() > 0:
		walk_path = paths[0] as Path2D
	else:
		push_warning(str(name) + ": no Path2D found in group 'walk_path'. Y movement will be unconstrained.")


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_handle_movement()
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	if walk_path != null:
		_constrain_to_path()
	# Snap to whole pixels to prevent sub-pixel blur during movement.
	position = position.round()


## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Override in subclass to handle input and set velocity.
func _handle_movement() -> void:
	pass


## Constrains the character's Y to a band around the path at the current X.
func _constrain_to_path() -> void:
	var path_y: float = _sample_path_y(global_position.x)
	global_position.y = clampf(global_position.y, path_y - path_y_margin, path_y + path_y_margin)


## Samples the walk_path curve to get the Y value at a given world X position.
func _sample_path_y(world_x: float) -> float:
	var curve: Curve2D = walk_path.curve
	var baked: PackedVector2Array = curve.get_baked_points()
	if baked.size() < 2:
		return global_position.y

	# Clamp X to the range of the path.
	var first_x: float = baked[0].x + walk_path.global_position.x
	var last_x: float = baked[baked.size() - 1].x + walk_path.global_position.x
	world_x = clampf(world_x, first_x, last_x)

	# Find the two baked points that bracket world_x and lerp between them.
	for i in range(baked.size() - 1):
		var ax: float = baked[i].x + walk_path.global_position.x
		var bx: float = baked[i + 1].x + walk_path.global_position.x
		if world_x >= ax and world_x <= bx:
			var t: float = (world_x - ax) / (bx - ax) if bx != ax else 0.0
			var ay: float = baked[i].y + walk_path.global_position.y
			var by: float = baked[i + 1].y + walk_path.global_position.y
			return lerp(ay, by, t)

	return global_position.y


## Call when the character runs out of health.
func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()

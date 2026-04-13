class_name EnemyBase
extends CharacterBody2D

# EnemyBase - shared base class for all enemy types.
# Follows the same walk_path group as the player.

@export var max_health: float = 100.0
@export var move_speed: float = 80.0
@export var attack_damage: float = 10.0
@export var attack_range: float = 60.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var health: float = max_health
var is_dead: bool = false
var target: Node2D = null
var walk_path: Path2D = null
var knockback_velocity: Vector2 = Vector2.ZERO

## How fast knockback decelerates in pixels/sec.
@export var knockback_friction: float = 600.0

@export_group("Path Oscillation")
## If true the enemy bobs up and down relative to the path instead of locking to it.
@export var oscillate: bool = false
## How many pixels above and below the path centre the enemy travels.
@export var oscillate_amplitude: float = 20.0
## Full cycles per second.
@export var oscillate_speed: float = 0.5

var _oscillate_time: float = 0.0

signal died(enemy: EnemyBase)
signal health_changed(new_health: float, max_hp: float)


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	health = max_health


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Lazy lookup - retry until the level's Path2D is in the tree.
	if walk_path == null:
		var paths: Array[Node] = get_tree().get_nodes_in_group("walk_path")
		if paths.size() > 0:
			walk_path = paths[0] as Path2D
	if oscillate:
		_oscillate_time += delta
	_handle_ai(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	if walk_path != null:
		_constrain_to_path()
	position = position.round()
	# Depth sort: lower on screen (higher Y) is drawn in front.
	z_index = 1000 + roundi(global_position.y)


## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Override in subclasses to implement movement and attack AI.
func _handle_ai(_delta: float) -> void:
	pass


func take_damage(amount: float) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit(self)


## Constrains Y to the walk path, with optional oscillation.
func _constrain_to_path() -> void:
	var path_y: float = _sample_path_y(global_position.x)
	if oscillate:
		path_y += sin(_oscillate_time * oscillate_speed * TAU) * oscillate_amplitude
	global_position.y = path_y


func _sample_path_y(world_x: float) -> float:
	var curve: Curve2D = walk_path.curve
	var baked: PackedVector2Array = curve.get_baked_points()
	if baked.size() < 2:
		return global_position.y
	var first_x: float = baked[0].x + walk_path.global_position.x
	var last_x: float = baked[baked.size() - 1].x + walk_path.global_position.x
	world_x = clampf(world_x, first_x, last_x)
	for i in range(baked.size() - 1):
		var ax: float = baked[i].x + walk_path.global_position.x
		var bx: float = baked[i + 1].x + walk_path.global_position.x
		if world_x >= ax and world_x <= bx:
			var t: float = (world_x - ax) / (bx - ax) if bx != ax else 0.0
			var ay: float = baked[i].y + walk_path.global_position.y
			var by: float = baked[i + 1].y + walk_path.global_position.y
			return lerp(ay, by, t)
	return global_position.y


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)  # bodies never physically push each other; Area2D masks handle detection
	health = max_health


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Lazy lookup - retry until the level's Path2D is in the tree.
	if walk_path == null:
		var paths: Array[Node] = get_tree().get_nodes_in_group("walk_path")
		if paths.size() > 0:
			walk_path = paths[0] as Path2D
	_handle_ai(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	if walk_path != null:
		_constrain_to_path()
	position = position.round()
	# Depth sort: lower on screen (higher Y) is drawn in front.
	z_index = 1000 + roundi(global_position.y)


## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Override in subclasses to implement movement and attack AI.
func _handle_ai(_delta: float) -> void:
	pass


func take_damage(amount: float) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit(self)


## Constrains Y to the walk path at the current X position.
func _constrain_to_path() -> void:
	var path_y: float = _sample_path_y(global_position.x)
	global_position.y = path_y


func _sample_path_y(world_x: float) -> float:
	var curve: Curve2D = walk_path.curve
	var baked: PackedVector2Array = curve.get_baked_points()
	if baked.size() < 2:
		return global_position.y
	var first_x: float = baked[0].x + walk_path.global_position.x
	var last_x: float = baked[baked.size() - 1].x + walk_path.global_position.x
	world_x = clampf(world_x, first_x, last_x)
	for i in range(baked.size() - 1):
		var ax: float = baked[i].x + walk_path.global_position.x
		var bx: float = baked[i + 1].x + walk_path.global_position.x
		if world_x >= ax and world_x <= bx:
			var t: float = (world_x - ax) / (bx - ax) if bx != ax else 0.0
			var ay: float = baked[i].y + walk_path.global_position.y
			var by: float = baked[i + 1].y + walk_path.global_position.y
			return lerp(ay, by, t)
	return global_position.y

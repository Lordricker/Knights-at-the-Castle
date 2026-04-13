class_name EnemyBase
extends CharacterBody2D

# EnemyBase - shared base class for all enemy types.
# Follows the same walk_path group as the player.

@export var max_health: float = 100.0
@export var move_speed: float = 80.0
@export var attack_damage: float = 10.0
@export var attack_range: float = 60.0

@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D

# ── Facing / bars ─────────────────────────────────────────────────────────────
## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

## Optional: assign a child Node2D whose X scale is flipped to mirror all children.
@export var facing_pivot: Node2D
## Drag the HealthBar Node2D (vertical_health_bar.gd) here in the Inspector.
@export var health_bar: Node2D

var _health_bar_api: Node = null
var _health_bar_right_pos: Vector2 = Vector2.ZERO

# ── Movement / physics ─────────────────────────────────────────────────────────
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
	scale.x = 1.0  # never flip the CharacterBody2D root
	health = max_health
	_capture_right_facing_transforms()
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	health_changed.connect(_on_health_changed)
	_on_health_changed(health, max_health)
	_apply_facing()
	add_to_group(&"entities")


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Lazy lookup - retry until the level's Path2D is in the tree.
	if walk_path == null:
		var paths: Array[Node] = get_tree().get_nodes_in_group("walk_path")
		if paths.size() > 0:
			walk_path = paths[0] as Path2D
	if oscillate and not _is_attacking():
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


## Override to return true while attacking so oscillation pauses.
func _is_attacking() -> bool:
	return false


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
	set_collision_layer(0)
	set_collision_mask(0)
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	died.emit(self)
	# Signal the level so it can spawn the death poof at our position.
	if get_tree().current_scene.has_method("on_entity_died"):
		get_tree().current_scene.on_entity_died(global_position)
	# Clean up after 5 seconds.
	get_tree().create_timer(5.0).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _on_health_changed(new_health: float, max_hp: float) -> void:
	if _health_bar_api != null and _health_bar_api.has_method("set_health"):
		_health_bar_api.set_health(new_health, max_hp)


## Recursively search descendants of root for a node that has the required_method.
func _resolve_bar_api(root: Node, required_method: StringName) -> Node:
	if root == null:
		return null
	if root.has_method(required_method):
		return root
	for child in root.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		var found: Node = _resolve_bar_api(child_node, required_method)
		if found != null:
			return found
	return null


## Record right-facing local positions once in _ready() before any flip.
## Override in subclasses to also capture subclass-specific nodes (call super() first).
func _capture_right_facing_transforms() -> void:
	if health_bar != null:
		_health_bar_right_pos = health_bar.position


## Apply the current facing direction to the sprite and positioned child nodes.
## Override in subclasses to mirror additional nodes (call super() first).
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	if facing_pivot != null:
		animated_sprite.flip_h = false
		var s := facing_pivot.scale
		s.x = absf(s.x) * facing
		facing_pivot.scale = s
		return
	animated_sprite.flip_h = facing < 0.0
	if health_bar != null:
		health_bar.position = Vector2(_health_bar_right_pos.x * facing, _health_bar_right_pos.y)


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()


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

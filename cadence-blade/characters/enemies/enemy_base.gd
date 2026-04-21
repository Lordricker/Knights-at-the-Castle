class_name EnemyBase
extends CharacterBody2D

# EnemyBase - shared base class for all enemy types.
# Follows the same walk_path group as the player.

@export var max_health: float = 100.0
@export var move_speed: float = 80.0
# Set by subclasses in _ready() — not exported to avoid inspector value overriding the subclass assignment.
var attack_damage: float = 10.0

@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D

# ── Facing / bars ─────────────────────────────────────────────────────────────
## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

## Optional: assign a child Node2D whose X scale is flipped to mirror all children.
@export var facing_pivot: Node2D
## Drag the HealthBar Node2D (vertical_health_bar.gd) here in the Inspector.
@export var health_bar: Node2D
## Area2D used to detect attackable targets. Bodies in the "Kill" group will be targeted.
@export var detection_zone: Area2D

var _health_bar_api: Node = null
var _health_bar_right_pos: Vector2 = Vector2.ZERO

# ── Movement / physics ─────────────────────────────────────────────────────────
var health: float = max_health
var is_dead: bool = false
var target: Node2D = null
## Set by EnemySpawner. 0=none, 1=Coin, 2=Coin2, 3=Coin4.
var coin_tier: int = 1
## Set by EnemySpawner. 0=same as coin_tier, otherwise overrides on flow kill.
var flow_kill_coin_tier: int = 0
var walk_path: Path2D = null
var knockback_velocity: Vector2 = Vector2.ZERO
## When true, movement, AI, and knockback are suspended (Freeze Enemies upgrade).
var is_frozen: bool = false

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

## Network position target received from host. Only used on joiner.
var _net_target_pos: Vector2 = Vector2.ZERO
## True once the first position sync has arrived -- prevents lerping from origin.
var _net_synced: bool = false
var _net_sync_counter: int = 0

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
	if is_frozen:
		velocity = Vector2.ZERO
		knockback_velocity = Vector2.ZERO
		return

	# Joiner: no local AI -- interpolate toward the host-authoritative position.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		if _net_synced:
			var dist := global_position.distance_to(_net_target_pos)
			if dist > 300.0:
				global_position = _net_target_pos  # teleport if desynced
			else:
				global_position = global_position.lerp(_net_target_pos, minf(10.0 * delta, 1.0))
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

	# Host: broadcast position and facing to joiner every 3 frames.
	if multiplayer.has_multiplayer_peer():
		_net_sync_counter = (_net_sync_counter + 1) % 3
		if _net_sync_counter == 0:
			rpc("_rpc_net_sync", global_position, facing)


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


## Returns all nodes overlapping detection_zone that belong to the "Kill" group.
## Checks both physics bodies (players/enemies) and areas (e.g. castle hitbox).
func _get_targets_in_range() -> Array:
	if detection_zone == null:
		return []
	var results: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body.is_in_group(&"Kill"):
			results.append(body)
	for area in detection_zone.get_overlapping_areas():
		if area.is_in_group(&"Kill"):
			results.append(area)
	return results


func take_damage(amount: float, flow_success: bool = false) -> void:
	if is_dead:
		return
	# Enemy health is host-authoritative. Joiner attacks forward to host via RPC.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		rpc_id(1, "_rpc_take_damage", amount, flow_success)
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if multiplayer.has_multiplayer_peer():
		rpc("_rpc_sync_health_enemy", health)
	if health == 0.0:
		die(flow_success)


func die(flow_success: bool = false) -> void:
	if is_dead:
		return
	is_dead = true
	# Host broadcasts death so the joiner's copy also plays death effects and frees.
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		rpc("_rpc_die_net", flow_success)
	set_collision_layer(0)
	set_collision_mask(0)
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	died.emit(self)
	# Signal the level so it can spawn the death poof and the correct coin.
	# Only run on host (or offline) -- joiner must not duplicate coins.
	# Deferred so this never runs mid-physics-flush (e.g. triggered by a hitbox signal).
	if (not multiplayer.has_multiplayer_peer() or multiplayer.is_server()) and \
			get_tree().current_scene.has_method("on_entity_died"):
		var tier: int = coin_tier
		if flow_success and flow_kill_coin_tier > 0:
			tier = flow_kill_coin_tier
		get_tree().current_scene.call_deferred("on_entity_died", global_position, true, tier)
	# Clean up after the death poof finishes (~2 seconds).
	# Use owner (the scene root Node2D) so the entire instance is freed,
	# not just this CharacterBody2D child node.
	var scene_root: Node = owner if owner != null else self
	get_tree().create_timer(2.5).timeout.connect(scene_root.queue_free, CONNECT_ONE_SHOT)


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


# ── Network sync (multiplayer only) ───────────────────────────────────────────

## Received on joiner every 3 frames: update interpolation target.
@rpc("authority", "unreliable_ordered")
func _rpc_net_sync(pos: Vector2, face: float) -> void:
	_net_target_pos = pos
	_net_synced = true
	if face != facing:
		_set_facing(face)


## Received on joiner: enemy was damaged on host -- update health display.
@rpc("authority", "reliable")
func _rpc_sync_health_enemy(new_health: float) -> void:
	if multiplayer.is_server():
		return
	health = new_health
	health_changed.emit(health, max_health)


## Received on host: joiner player hit this enemy. Host applies damage.
@rpc("any_peer", "reliable")
func _rpc_take_damage(amount: float, flow_success: bool) -> void:
	if not multiplayer.is_server():
		return
	take_damage(amount, flow_success)


## Received on joiner: this enemy died on the host -- play death effects and free.
@rpc("authority", "reliable")
func _rpc_die_net(flow_success: bool) -> void:
	if multiplayer.is_server():
		return
	die(flow_success)

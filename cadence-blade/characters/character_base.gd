class_name CharacterBase
extends CharacterBody2D

# CharacterBase - shared base class for all playable characters.
# Free 2D movement: WASD moves in X and Y.
# Add a Polygon2D to the level scene in the group "walk_area" to constrain movement.

@export var move_speed: float = 200.0
## Drag your CollisionShape2D here so the whole box is constrained inside the walk area.
@export var body_box: CollisionShape2D

# The AnimatedSprite2D child node must be named exactly "AnimatedSprite2D".
@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D

# ── Health ─────────────────────────────────────────────────────────────────────
@export var max_health: float = 100.0
var health: float = 0.0
signal health_changed(new_health: float, max_hp: float)

# ── Coins (run currency) ───────────────────────────────────────────────────────
## Current coin balance. Modified by add_coins(); persists for the whole run.
var coins: int = 0
signal coins_changed(new_coins: int)

# ── Stat bonuses (from blacksmith upgrades) ────────────────────────────────────
## Flat damage bonus added on top of the base attack damage each hit.
var attack_bonus: float = 0.0
## Flat speed bonus added on top of move_speed every frame.
var speed_bonus: float = 0.0
## Run-time seconds to subtract when sampling flow window size curves.
## Set to run_manager.time_elapsed when a +Flow upgrade is purchased, so the
## curve resets from the beginning (simulating a second wind).
var flow_time_offset: float = 0.0

# ── Interaction locks (set by CastleInside) ────────────────────────────────────
## When true, CastleInside is playing the "heal" animation; subclasses pause
## normal animation selection so the heal pose can hold.
var healing_locked: bool = false
## When true, new attack actions are suppressed (player is at the blacksmith).
var attacks_locked: bool = false

# ── Facing / bars ─────────────────────────────────────────────────────────────
## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

## Optional: assign a child Node2D whose X scale is flipped to mirror all children.
@export var facing_pivot: Node2D
## Drag the HealthBar Node2D (vertical_health_bar.gd) here in the Inspector.
@export var health_bar: Node2D
## Drag the FlowBar Node2D (flow_timing_bar.gd) here in the Inspector.
@export var flow_bar: Node2D

# ── Flow timing ───────────────────────────────────────────────────────────────
# ── Flow timing (set per-attack by _start_flow callers) ──────────────────────

var _health_bar_api: Node = null
var _health_bar_right_pos: Vector2 = Vector2.ZERO
var _flow_bar_api: Node = null
var _flow_bar_right_pos: Vector2 = Vector2.ZERO
var _flow_active: bool = false
var _flow_input_action: StringName = &""
var _flow_progress: float = 0.0
var _flow_on_resolved: Callable
var _flow_fill_duration: float = 0.45
var _flow_miss_damage_multiplier: float = 0.6

# ── Movement / physics ─────────────────────────────────────────────────────────
var walk_area: Polygon2D = null
var is_dead: bool = false
var knockback_velocity: Vector2 = Vector2.ZERO
var _orig_layer: int = 0

## How fast knockback decelerates in pixels/sec.
@export var knockback_friction: float = 800.0

signal died()

# ── Player slot / input routing ───────────────────────────────────────────────
## 1 = player 1 (default), 2 = player 2.
## player_slot routes _action_* helpers to matching p2_ InputMap actions (local co-op).
## In online mode, use_input_override takes priority and injects input via a dict,
## which is more reliable than Input.action_press in HTML5 exports.
var player_slot: int = 1
## When true, _action_* helpers read from input_override instead of live Input.
var use_input_override: bool = false
## Keys are action names (e.g. "move_left", "action1"). Values: true = held this frame.
var input_override: Dictionary = {}
## Previous frame's snapshot — used to emulate is_action_just_pressed.
var _prev_input_override: Dictionary = {}


func _ready() -> void:
	_orig_layer = get_collision_layer()
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	scale.x = 1.0  # never flip the CharacterBody2D root
	if animated_sprite == null:
		push_error(str(name) + ": no AnimatedSprite2D child found. Name it 'AnimatedSprite2D'.")
		return
	health = max_health
	health_changed.connect(_on_health_changed)
	add_to_group(&"entities")
	add_to_group(&"Kill")
	add_to_group(&"KillCharacter")
	_capture_right_facing_transforms()
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	_flow_bar_api = _resolve_bar_api(flow_bar, &"start_flow")
	_on_health_changed(health, max_health)
	if flow_bar != null:
		flow_bar.hide()
	_apply_facing()


## Advance the override snapshot. Call once per physics frame before _handle_movement.
func tick_input_override() -> void:
	_prev_input_override = input_override.duplicate()


## Drop-in for Input.is_action_pressed. Dict override wins; then player_slot routing.
func _action_pressed(action: StringName) -> bool:
	if use_input_override:
		return input_override.get(action, false)
	if player_slot == 2:
		return Input.is_action_pressed("p2_" + action)
	return Input.is_action_pressed(action)


## Drop-in for Input.is_action_just_pressed. Dict override uses prev-frame diff.
func _action_just_pressed(action: StringName) -> bool:
	if use_input_override:
		return input_override.get(action, false) and not _prev_input_override.get(action, false)
	if player_slot == 2:
		return Input.is_action_just_pressed("p2_" + action)
	return Input.is_action_just_pressed(action)


## Drop-in for Input.get_axis. Dict override wins; then player_slot routing.
func _get_axis(neg: StringName, pos: StringName) -> float:
	if use_input_override:
		return float(input_override.get(pos, false)) - float(input_override.get(neg, false))
	if player_slot == 2:
		return Input.get_axis("p2_" + neg, "p2_" + pos)
	return Input.get_axis(neg, pos)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Lazy lookup - retry until the level's Polygon2D is in the tree.
	if walk_area == null:
		var areas: Array[Node] = get_tree().get_nodes_in_group("walk_area")
		if areas.size() > 0:
			walk_area = areas[0] as Polygon2D
	_handle_movement()
	_update_flow(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	# Snapshot input AFTER this frame's logic so next frame's just_pressed diff is correct.
	# Must be after move_and_slide so the packet received in _process this frame is used
	# by _handle_movement above, and then captured as "previous" for next frame.
	if use_input_override:
		tick_input_override()
	if walk_area != null:
		_constrain_to_walk_area()
	# Snap to whole pixels to prevent sub-pixel blur during movement.
	position = position.round()
## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Override in subclass to handle input and set velocity.
func _handle_movement() -> void:
	pass


## Keeps the character inside the walk_area polygon.
func _constrain_to_walk_area() -> void:
	var xform: Transform2D = walk_area.global_transform
	var world_poly: PackedVector2Array = PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)

	# Collect test points from the collision shape edges.
	var test_points: Array[Vector2] = _get_shape_test_points()

	# Find the largest push needed to bring any outside point back in.
	var total_offset: Vector2 = Vector2.ZERO
	for tp in test_points:
		if Geometry2D.is_point_in_polygon(tp, world_poly):
			continue
		var best: Vector2 = tp
		var best_dist: float = INF
		for i in range(world_poly.size()):
			var a: Vector2 = world_poly[i]
			var b: Vector2 = world_poly[(i + 1) % world_poly.size()]
			var closest: Vector2 = _nearest_point_on_segment(tp, a, b)
			var d: float = tp.distance_squared_to(closest)
			if d < best_dist:
				best_dist = d
				best = closest
		var offset: Vector2 = best - tp
		if offset.length_squared() > total_offset.length_squared():
			total_offset = offset

	if total_offset != Vector2.ZERO:
		global_position += total_offset
		velocity = Vector2.ZERO
		knockback_velocity = Vector2.ZERO


## Returns key points on the collision shape boundary to test against the polygon.
func _get_shape_test_points() -> Array[Vector2]:
	if body_box == null or body_box.shape == null:
		return [global_position]
	var center: Vector2 = body_box.global_position
	if body_box.shape is RectangleShape2D:
		var half: Vector2 = (body_box.shape as RectangleShape2D).size / 2.0
		return [
			center + Vector2(-half.x, -half.y),
			center + Vector2( half.x, -half.y),
			center + Vector2( half.x,  half.y),
			center + Vector2(-half.x,  half.y),
		]
	elif body_box.shape is CapsuleShape2D:
		var cap: CapsuleShape2D = body_box.shape as CapsuleShape2D
		return [
			center + Vector2(0, -cap.height / 2.0),
			center + Vector2(0,  cap.height / 2.0),
			center + Vector2(-cap.radius, 0),
			center + Vector2( cap.radius, 0),
		]
	# Fallback: just test the center.
	return [center]


func _nearest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq == 0.0:
		return a
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


func take_damage(amount: float, _flow_success: bool = false) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		die()


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
	if flow_bar != null:
		_flow_bar_right_pos = flow_bar.position


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
	if flow_bar != null:
		flow_bar.position = Vector2(_flow_bar_right_pos.x * facing, _flow_bar_right_pos.y)


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()


## Add (positive) or remove (negative) coins and emit the coins_changed signal.
func add_coins(amount: int) -> void:
	coins += amount
	coins_changed.emit(coins)


## Call when the character runs out of health.
func die() -> void:
	if is_dead:
		return
	is_dead = true
	set_collision_layer(0)
	set_collision_mask(0)
	set_physics_process(false)
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	if flow_bar != null:
		flow_bar.hide()
	died.emit()
	# Signal the level to spawn the death poof. Pass spawn_coin=false so only
	# enemy deaths drop coins, not player deaths.
	# Deferred so this never runs mid-physics-flush (e.g. triggered by a hitbox signal).
	if get_tree().current_scene.has_method("on_entity_died"):
		get_tree().current_scene.call_deferred("on_entity_died", global_position, false)


## Revive this character at the given world position, restoring full health.
## Called by RunManager after the respawn delay expires.
func revive(at: Vector2) -> void:
	if not is_dead:
		return
	is_dead = false
	health = max_health
	global_position = at
	knockback_velocity = Vector2.ZERO
	set_collision_layer(_orig_layer)
	set_physics_process(true)
	set_process(true)
	set_process_input(true)
	set_process_unhandled_input(true)
	if animated_sprite != null:
		animated_sprite.show()
		animated_sprite.play(&"idle")
	if health_bar != null:
		health_bar.show()
	if flow_bar != null:
		flow_bar.hide()
	health_changed.emit(health, max_health)


# ── Flow timing ────────────────────────────────────────────────────────────────

## Subclasses call this to begin a flow sequence.
## window_center: normalized bar position (0=bottom, 1=top) for the midpoint of the green zone.
## window_half: half-width of the green zone (full zone = center +/- half).
## window_random: max random shift applied to the center each attack.
func _start_flow(input_action: StringName, on_resolved: Callable,
		fill_duration: float = 0.45, miss_multiplier: float = 0.6,
		window_center: float = 0.5, window_half: float = 0.1,
		window_random: float = 0.0) -> void:
	_flow_input_action = input_action
	_flow_on_resolved = on_resolved
	_flow_fill_duration = fill_duration
	_flow_miss_damage_multiplier = miss_multiplier
	_flow_active = true
	_flow_progress = 0.0
	if flow_bar != null:
		flow_bar.show()
	if _flow_bar_api != null:
		var _shift: float = randf_range(-window_random, window_random)
		var _clamped_center: float = clampf(window_center + _shift, window_half, 1.0 - window_half)
		_flow_bar_api.success_window_start = _clamped_center - window_half
		_flow_bar_api.success_window_end = _clamped_center + window_half
		if _flow_bar_api.has_method("start_flow"):
			_flow_bar_api.start_flow()


func _stop_flow() -> void:
	_flow_active = false
	_flow_input_action = &""
	_flow_progress = 0.0
	_flow_on_resolved = Callable()
	if _flow_bar_api != null and _flow_bar_api.has_method("stop_flow"):
		_flow_bar_api.stop_flow()
	if flow_bar != null:
		flow_bar.hide()


## Called every physics frame while a flow sequence is running.
func _update_flow(delta: float) -> void:
	if not _flow_active:
		return
	var reached_top: bool = false
	if _flow_bar_api != null and _flow_bar_api.has_method("advance"):
		reached_top = _flow_bar_api.advance(delta, _flow_fill_duration)
	else:
		_flow_progress = clampf(_flow_progress + delta / maxf(_flow_fill_duration, 0.001), 0.0, 1.0)
		reached_top = _flow_progress >= 1.0
	if reached_top:
		if _flow_bar_api != null and _flow_bar_api.has_method("mark_missed"):
			_flow_bar_api.mark_missed()
		var cb := _flow_on_resolved
		_stop_flow()
		if cb.is_valid():
			cb.call(_flow_miss_damage_multiplier)


## Called when a PAUSED attack state is active. Pass the relevant input action.
func _handle_flow_attempt(action_name: StringName) -> void:
	if not _flow_active:
		return
	if not _action_just_pressed(action_name):
		return
	if _flow_bar_api == null or not _flow_bar_api.has_method("try_attempt"):
		var cb := _flow_on_resolved
		_stop_flow()
		if cb.is_valid():
			cb.call(1.0)
		return
	var result: FlowTimingBar.AttemptResult = _flow_bar_api.try_attempt()
	match result:
		FlowTimingBar.AttemptResult.SUCCESS:
			var cb := _flow_on_resolved
			_stop_flow()
			if cb.is_valid():
				cb.call(1.0)
		FlowTimingBar.AttemptResult.MISS:
			pass  # bar keeps filling grey; auto-resolves in _update_flow
		FlowTimingBar.AttemptResult.NONE:
			pass  # attempt already used

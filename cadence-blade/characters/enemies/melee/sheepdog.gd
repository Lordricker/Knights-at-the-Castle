extends EnemyBase

# sheepdog.gd — Enemy: Sheepdog.
#
# Unlike other enemies the sheepdog chases the nearest living player and is
# constrained by the Polygon2D "walk_area" (same bounds system as players).
#
# SCENE STRUCTURE:
#   Node2D  (scene root, y_sort_enabled)
#   └── CharacterBody2D  (this script)
#       ├── CollisionShape2D        ← assign to body_box in Inspector
#       └── Pivot  (Node2D, facing_pivot)
#           ├── AnimatedSprite2D    (animations: "running", "bash")
#           ├── BashHitbox   (Area2D — active on bash frames 3, 4, 5)
#           │   └── CollisionShape2D
#           ├── DetectionZone (Area2D — triggers bash when player enters)
#           │   └── CollisionShape2D
#           └── HPBar

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Combat")
## Damage dealt per bash hit.
@export var bash_damage: float = 25.0
## Which 0-indexed frames of the bash animation activate the BashHitbox.
@export var bash_hitbox_frames: Array[int] = [3, 4, 5]
## Knockback force applied to targets hit by the bash.
@export var knockback_force: float = 350.0
## Pixels per second the sheepdog lunges horizontally during active bash frames.
@export var bash_lunge_speed: float = 120.0

## Drag the main CollisionShape2D here for polygon boundary constraint.
@export var body_box: CollisionShape2D
## Sound played when a bash begins.
@export var bash_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var bash_sound_volume_db: float = 0.0
## Animation frame indices that trigger the bash sound.
@export var bash_sound_frames: Array[int] = []
## Weapon type reported to the target when the bash connects.
@export var bash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.CLAW

# ── Internal state ─────────────────────────────────────────────────────────────

enum BashState { NONE, ATTACKING }

var bash_state: BashState = BashState.NONE
var _bash_lunge_active: bool = false

## Polygon2D from the "walk_area" group — constrains movement like the players.
var walk_area: Polygon2D = null

@onready var bash_hitbox: Area2D = find_child("BashHitbox") as Area2D

var _bash_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = bash_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	detection_zone.monitoring = true
	_set_hitbox(bash_hitbox, false)
	if bash_hitbox != null:
		bash_hitbox.body_entered.connect(_on_hit_body)
		bash_hitbox.area_entered.connect(_on_hit_area)
	animated_sprite.play("running")
	_bash_audio = _make_sfx_player(bash_sound, bash_sound_volume_db)


# ── Physics (replaces EnemyBase version to use walk_area instead of walk_path) ─

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if is_frozen:
		velocity = Vector2.ZERO
		knockback_velocity = Vector2.ZERO
		return

	# Joiner: no local AI — interpolate toward the host-authoritative position.
	if GameManager.session_id != "" and not GameManager.is_host:
		if _net_synced:
			var dist := global_position.distance_to(_net_target_pos)
			if dist > 300.0:
				global_position = _net_target_pos
			else:
				global_position = global_position.lerp(_net_target_pos, minf(10.0 * delta, 1.0))
		return

	# Lazy lookup for walk_area polygon.
	if walk_area == null:
		var areas: Array[Node] = get_tree().get_nodes_in_group("walk_area")
		if areas.size() > 0:
			walk_area = areas[0] as Polygon2D

	_handle_ai(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)

	# Lunge is applied after move_and_slide so the polygon constraint can clamp it.
	if _bash_lunge_active:
		global_position.x += facing * bash_lunge_speed * delta

	if walk_area != null:
		_constrain_to_walk_area()

	position = position.round()


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(_delta: float) -> void:
	# Locked during bash animation.
	if bash_state == BashState.ATTACKING:
		velocity = Vector2.ZERO
		return

	# Player is in detection zone — stop and bash.
	var in_range := _get_targets_in_range()
	if in_range.size() > 0:
		target = in_range[0]
		velocity = Vector2.ZERO
		_begin_bash()
		return

	# Chase nearest living player.
	var nearest := _get_nearest_player()
	if nearest != null:
		target = nearest
		var dir := (nearest.global_position - global_position).normalized()
		velocity = dir * move_speed
		_set_facing(1.0 if dir.x >= 0.0 else -1.0)
	else:
		target = null
		velocity = Vector2.ZERO


func _is_attacking() -> bool:
	return bash_state == BashState.ATTACKING


## Override: only players (KillCharacter group) trigger the bash — not the castle hitbox.
func _get_targets_in_range() -> Array:
	if detection_zone == null:
		return []
	var results: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body.is_in_group(&"KillCharacter") and not body.get("is_dead"):
			results.append(body)
	return results


## Returns the nearest CharacterBase node in the "KillCharacter" group that is alive.
func _get_nearest_player() -> Node2D:
	var players := get_tree().get_nodes_in_group("KillCharacter")
	var best: Node2D = null
	var best_dist: float = INF
	for p in players:
		var pb := p as Node2D
		if pb == null:
			continue
		if pb.get("is_dead"):
			continue
		var d := global_position.distance_squared_to(pb.global_position)
		if d < best_dist:
			best_dist = d
			best = pb
	return best


# ── Attack ─────────────────────────────────────────────────────────────────────

func _begin_bash() -> void:
	bash_state = BashState.ATTACKING
	_bash_lunge_active = false
	animated_sprite.stop()
	animated_sprite.play("bash")
	if target != null:
		_set_facing(1.0 if target.global_position.x >= global_position.x else -1.0)


func _stop_bash() -> void:
	bash_state = BashState.NONE
	_bash_lunge_active = false
	_set_hitbox(bash_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


func die(flow_success: bool = false) -> void:
	bash_state = BashState.NONE
	_bash_lunge_active = false
	_set_hitbox(bash_hitbox, false)
	super(flow_success)


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	if bash_state == BashState.ATTACKING:
		var active: bool = animated_sprite.frame in bash_hitbox_frames
		_set_hitbox(bash_hitbox, active)
		_bash_lunge_active = active
		if animated_sprite.frame in bash_sound_frames:
			_play_sfx(_bash_audio)


func _on_animation_finished() -> void:
	if bash_state == BashState.ATTACKING:
		if _get_targets_in_range().size() > 0:
			_begin_bash()
		else:
			_stop_bash()


# ── Hitbox helper ──────────────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


## Called when BashHitbox overlaps a CharacterBody2D / StaticBody2D.
func _on_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	if body.has_method("take_damage"):
		body.take_damage(attack_damage, false, bash_weapon_type)
	# Apply knockback only to characters, not static objects like the castle.
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


## Called when BashHitbox overlaps an Area2D (e.g. the castle's Kill hitbox).
func _on_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(attack_damage, false, bash_weapon_type)


# ── Walk area polygon constraint (mirrors CharacterBase._constrain_to_walk_area) ─

func _constrain_to_walk_area() -> void:
	var xform: Transform2D = walk_area.global_transform
	var world_poly: PackedVector2Array = PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)

	var test_points: Array[Vector2] = _get_shape_test_points()

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
	return [center]


func _nearest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq == 0.0:
		return a
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t

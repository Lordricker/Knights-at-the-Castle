extends EnemyBase

# skeleton_knight.gd -- Elite enemy: Skeleton Knight.
#
# Behaviors:
#   * Two detection ranges. DetectionZone (wide): leave the walk path and chase
#     the nearest target in 2D. AttackZone (tight, in front): stop and perform a
#     random action. Once no target remains he eases back onto the walk path.
#   * Three slashes, each with its own hitbox and movement:
#       - "slash"  : plain, contact on slash_hit_frames.
#       - "slash2" : upward slash. On slash2_dash_frame he darts
#                    slash2_dash_offset (x mirrored by facing, +y = down)
#                    swiftly toward where he's locked, then swings and keeps
#                    fighting from the new spot.
#       - "slash3" : frame 0 = ready, on slash3_jump_frame he jumps
#                    slash3_jump_distance forward, turns around, then swings.
#   * "block" : copied from the Green Knight -- reduces incoming damage and
#     knocks the attacker back -- and additionally mirrors the sprite for the
#     block's duration.
#   * Action choice is an even 1/4 split (slash / slash2 / slash3 / block).
#
# SCENE STRUCTURE:
#   Node2D
#   +-- CharacterBody2D  (this script)
#       +-- body            (HurtBox, 1x)
#       +-- Pivot (Node2D -- facing_pivot; scale.x flipped for direction)
#           +-- AnimatedSprite2D  ("running", "slash", "slash2", "slash3", "block", "idle", "death")
#           +-- SlashHitbox   (Area2D -- slash)
#           +-- SlashHitbox2  (Area2D -- slash2, positioned high for the upward swing)
#           +-- SlashHitbox3  (Area2D -- slash3)
#           +-- DetectionZone (Area2D -- wide; triggers the chase)
#           +-- AttackZone    (Area2D -- tight; triggers an action)
#           +-- head          (HurtBox, 2x)
#           +-- HPBar


# ---- Slash ------------------------------------------------------------------

@export_group("Slash")
@export var slash_hitbox: Area2D
@export var slash_damage: float = 25.0
@export var slash_hit_frames: Array[int] = [3]
@export var slash_knockback_force: float = 300.0
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD


# ---- Slash2 (upward slash + down-forward dart) ------------------------------

@export_group("Slash2")
@export var slash2_hitbox: Area2D
@export var slash2_damage: float = 30.0
@export var slash2_hit_frames: Array[int] = [2]
@export var slash2_knockback_force: float = 350.0
@export var slash2_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
## Frame on which the dart begins.
@export var slash2_dash_frame: int = 1
## Offset from his current position. x is mirrored by facing; +y is downward.
@export var slash2_dash_offset: Vector2 = Vector2(50.0, 50.0)
## How fast (px/s) he covers slash2_dash_offset.
@export var slash2_dash_speed: float = 700.0


# ---- Slash3 (jump forward, turn around, swing) -----------------------------

@export_group("Slash3")
@export var slash3_hitbox: Area2D
@export var slash3_damage: float = 30.0
@export var slash3_hit_frames: Array[int] = [2]
@export var slash3_knockback_force: float = 350.0
@export var slash3_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
## Frame on which the jump launches (frame 0 is the "ready" pose).
@export var slash3_jump_frame: int = 1
## How far forward (px, in the facing direction) he jumps.
@export var slash3_jump_distance: float = 80.0
## How fast (px/s) he covers the jump.
@export var slash3_jump_speed: float = 900.0


# ---- Block -----------------------------------------------------------------

@export_group("Block")
## Optional Area2D probe. Block damage reduction works via take_damage() even
## when this is unassigned; leave null unless you want a dedicated overlap box.
@export var block_zone: Area2D
## Percentage of incoming damage negated while blocking (0-100).
@export_range(0.0, 100.0, 1.0) var block_damage_reduction: float = 90.0
## Knockback force applied back to the attacker when a hit is blocked.
@export var block_knockback_force: float = 450.0
## When unchecked the skeleton never blocks (rolls a slash instead).
@export var enable_block: bool = true


# ---- Zones / navigation ---------------------------------------------------

@export_group("Zones")
## Tight Area2D just in front of him -- a target inside it triggers an action.
@export var attack_zone: Area2D
## move_speed is multiplied by this while chasing a target seen in DetectionZone.
@export var chase_speed_multiplier: float = 1.5
## Pixels/sec he eases vertically back onto the walk path once combat ends.
@export var path_return_speed: float = 60.0
## CollisionShape2D used to keep his body inside the "walk_area" polygon while
## in combat (same containment the players use). Drag body/bodybox here.
@export var body_box: CollisionShape2D


# ---- Swing sound --------------------------------------------------------------

@export_group("Swing Sound")
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices (any slash) that trigger the swing sound.
@export var slash_swing_sound_frames: Array[int] = []

@export_group("")


# ---- Internal state --------------------------------------------------------

enum SKState { NONE, SLASHING, SLASHING2, SLASHING3, BLOCKING }

var _state: SKState = SKState.NONE

## True while chasing a DetectionZone target or mid-action -- suspends the
## walk-path Y lock so he can move freely in 2D.
var _in_combat: bool = false

var _dashing: bool = false
var _dash_target: Vector2 = Vector2.ZERO
var _dash_speed: float = 0.0
var _pending_turnaround: bool = false

## Polygon2D from the "walk_area" group -- constrains his body while in combat.
var walk_area: Polygon2D = null

var _swing_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = slash_damage
	if death_animation == &"":
		death_animation = &"death"
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	if detection_zone != null:
		detection_zone.monitoring = true
	if attack_zone != null:
		attack_zone.monitoring = true
	for box in _distinct_slash_hitboxes():
		_set_hitbox(box, false)
		box.body_entered.connect(_on_attack_hit_body)
		box.area_entered.connect(_on_attack_hit_area)
	_set_hitbox(block_zone, false)
	if block_zone != null:
		block_zone.area_entered.connect(_on_block_zone_area_entered)
	animated_sprite.play("running")
	_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)


## The slash hitbox nodes, de-duplicated (several exports may point at one node).
func _distinct_slash_hitboxes() -> Array[Area2D]:
	var result: Array[Area2D] = []
	for box in [slash_hitbox, slash2_hitbox, slash3_hitbox]:
		if box != null and box not in result:
			result.append(box)
	return result


# ---- AI ------------------------------------------------------------------

## Facing only re-commits once he's this far past the guard line (world x = 0),
## well outside the 4px stop radius below. Repeated small knockback (e.g. a hut
## archer plinking him while he holds his post) can rock him a few px back and
## forth across x = 0 — without this margin, _set_facing would flip every time
## that noise crosses zero and the sprite would waffle in place.
const GUARD_LINE_FACING_COMMIT: float = 12.0

func _handle_ai(_delta: float) -> void:
	# Locked during any action animation (dash moves the body itself).
	if _state != SKState.NONE:
		_in_combat = true
		velocity = Vector2.ZERO
		return

	# Target inside the tight attack zone -> stop and act.
	var atk := _nearest(_get_attack_zone_targets())
	if atk != null:
		_in_combat = true
		target = atk
		_face_target()
		velocity = Vector2.ZERO
		_begin_random_action()
		return

	# Target inside the wide detection zone -> leave the path, chase in 2D.
	var seen := _get_targets_in_range()
	var chase := _nearest(seen)
	if chase != null:
		_in_combat = true
		target = chase
		var to_target: Vector2 = chase.global_position - global_position
		velocity = to_target.normalized() * move_speed * chase_speed_multiplier
		_set_facing(1.0 if to_target.x >= 0.0 else -1.0)
		if animated_sprite.animation != &"running":
			animated_sprite.play("running")
		return

	# Nothing in range -- march toward world x = 0; _constrain_to_path eases
	# him back onto the path.
	_in_combat = false
	target = null
	var dist: float = global_position.x
	if absf(dist) < 4.0:
		velocity.x = 0.0
	else:
		var dir: float = -signf(dist)
		velocity.x = move_speed * dir
		if absf(dist) > GUARD_LINE_FACING_COMMIT:
			_set_facing(1.0 if dir > 0.0 else -1.0)
	velocity.y = 0.0
	if animated_sprite.animation != &"running":
		animated_sprite.play("running")


func _physics_process(delta: float) -> void:
	super(delta)
	if is_dead or is_frozen:
		return
	# Joiner has no local AI -- position comes from the host.
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	if _dashing:
		global_position = global_position.move_toward(_dash_target, _dash_speed * delta)
		if global_position.distance_to(_dash_target) < 1.0:
			_dashing = false
			if _pending_turnaround:
				_pending_turnaround = false
				_set_facing(-facing)
	# While chasing/fighting he moves freely in 2D -- keep his body inside the
	# walk_area polygon, sliding along the edge, exactly like the players.
	if _in_combat:
		if walk_area == null:
			var areas: Array[Node] = get_tree().get_nodes_in_group("walk_area")
			if areas.size() > 0:
				walk_area = areas[0] as Polygon2D
		if walk_area != null:
			_constrain_to_walk_area()


func _is_attacking() -> bool:
	return _state != SKState.NONE


## Suspends the hard walk-path Y lock while in combat; once combat ends, eases
## Y back toward the path before handing control back to EnemyBase's lock.
func _constrain_to_path() -> void:
	if walk_path == null:
		return
	if _in_combat:
		return
	var path_y: float = _sample_path_y(global_position.x)
	if absf(global_position.y - path_y) <= 1.0:
		super()
	else:
		global_position.y = move_toward(
			global_position.y, path_y,
			path_return_speed * get_physics_process_delta_time())


# ---- Target queries -----------------------------------------------------

## Kill-group bodies/areas overlapping the tight attack zone.
func _get_attack_zone_targets() -> Array:
	if attack_zone == null:
		return []
	var results: Array = []
	for body in attack_zone.get_overlapping_bodies():
		if body.is_in_group(&"Kill"):
			results.append(body)
	for area in attack_zone.get_overlapping_areas():
		if area.is_in_group(&"Kill"):
			results.append(area)
	return results


func _nearest(candidates: Array) -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	for c in candidates:
		var n := c as Node2D
		if n == null:
			continue
		var d: float = global_position.distance_squared_to(n.global_position)
		if d < best_dist:
			best_dist = d
			best = n
	return best


func _face_target() -> void:
	if target != null:
		_set_facing(1.0 if target.global_position.x >= global_position.x else -1.0)


# ---- Actions ------------------------------------------------------------

func _begin_random_action() -> void:
	var roll: int = randi() % (4 if enable_block else 3)
	match roll:
		0: _begin_slash()
		1: _begin_slash2()
		2: _begin_slash3()
		3: _begin_block()


func _begin_slash() -> void:
	_reset_hitboxes()
	_state = SKState.SLASHING
	animated_sprite.stop()
	animated_sprite.play("slash")
	_face_target()


func _begin_slash2() -> void:
	_reset_hitboxes()
	_state = SKState.SLASHING2
	animated_sprite.stop()
	animated_sprite.play("slash2")
	_face_target()


func _begin_slash3() -> void:
	_reset_hitboxes()
	_state = SKState.SLASHING3
	animated_sprite.stop()
	animated_sprite.play("slash3")
	_face_target()


func _reset_hitboxes() -> void:
	for box in _distinct_slash_hitboxes():
		_set_hitbox(box, false)
	_set_hitbox(block_zone, false)


func _begin_block() -> void:
	_reset_hitboxes()
	_state = SKState.BLOCKING
	_set_overlap_probe(slash_hitbox, true)
	animated_sprite.stop()
	animated_sprite.play("block")
	_set_hitbox(block_zone, true)


func _start_dash(offset: Vector2, speed: float, turnaround: bool) -> void:
	_dash_target = global_position + offset
	_dash_speed = speed
	_pending_turnaround = turnaround
	_dashing = true


func _stop_action() -> void:
	_state = SKState.NONE
	_dashing = false
	_pending_turnaround = false
	_reset_hitboxes()
	animated_sprite.stop()
	animated_sprite.play("running")


func die(flow_success: bool = false) -> void:
	_state = SKState.NONE
	_dashing = false
	_pending_turnaround = false
	_reset_hitboxes()
	super(flow_success)


# ---- Damage override (block) ------------------------------------------------

func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	var effective_flow_success := flow_success
	if _state == SKState.BLOCKING:
		effective_flow_success = false
		_apply_block_contact_knockback()
		amount = amount * (1.0 - clampf(block_damage_reduction, 0.0, 100.0) / 100.0)
	super(amount, effective_flow_success, weapon_type)


func _apply_block_contact_knockback() -> void:
	if slash_hitbox == null:
		return
	var pushed: Dictionary = {}
	for body in slash_hitbox.get_overlapping_bodies():
		var atk := body as Node2D
		if atk == null or not atk.is_in_group(&"KillCharacter"):
			continue
		if not atk.has_method("apply_knockback"):
			continue
		var id: int = atk.get_instance_id()
		if pushed.has(id):
			continue
		pushed[id] = true
		atk.apply_knockback(global_position, block_knockback_force)


# ---- Frame / animation signals --------------------------------------------

func _on_frame_changed() -> void:
	if is_dead:
		return
	var frame: int = animated_sprite.frame
	match _state:
		SKState.SLASHING:
			_set_hitbox(slash_hitbox, frame in slash_hit_frames)
			_maybe_swing_sound(frame)
		SKState.SLASHING2:
			if frame == slash2_dash_frame and not _dashing:
				_start_dash(Vector2(slash2_dash_offset.x * facing, slash2_dash_offset.y),
					slash2_dash_speed, false)
			_set_hitbox(slash2_hitbox, frame in slash2_hit_frames)
			_maybe_swing_sound(frame)
		SKState.SLASHING3:
			if frame == slash3_jump_frame and not _dashing:
				_start_dash(Vector2(slash3_jump_distance * facing, 0.0),
					slash3_jump_speed, true)
			_set_hitbox(slash3_hitbox, frame in slash3_hit_frames)
			_maybe_swing_sound(frame)


func _maybe_swing_sound(frame: int) -> void:
	if frame in slash_swing_sound_frames:
		_play_sfx(_swing_audio)


func _on_animation_finished() -> void:
	if is_dead:
		return
	match _state:
		SKState.SLASHING, SKState.SLASHING2, SKState.SLASHING3, SKState.BLOCKING:
			if _get_attack_zone_targets().size() > 0:
				_begin_random_action()
			else:
				_stop_action()


func _on_block_zone_area_entered(_area: Area2D) -> void:
	# Knockback + reduction are handled in take_damage(); this is a hook only.
	pass


# ---- Hit resolution ------------------------------------------------------

func _on_attack_hit_body(body: Node2D) -> void:
	if is_dead:
		return
	if not body.is_in_group(&"Kill"):
		return
	var dmg: float
	var kb: float
	var wtype: WeaponType.WeaponType
	match _state:
		SKState.SLASHING:
			dmg = slash_damage
			kb = slash_knockback_force
			wtype = slash_weapon_type
		SKState.SLASHING2:
			dmg = slash2_damage
			kb = slash2_knockback_force
			wtype = slash2_weapon_type
		SKState.SLASHING3:
			dmg = slash3_damage
			kb = slash3_knockback_force
			wtype = slash3_weapon_type
		_:
			return
	if body.has_method("take_damage"):
		body.take_damage(dmg, false, wtype)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, kb)


func _on_attack_hit_area(area: Area2D) -> void:
	if is_dead:
		return
	if not area.is_in_group(&"Kill"):
		return
	var dmg: float
	var wtype: WeaponType.WeaponType
	match _state:
		SKState.SLASHING:
			dmg = slash_damage
			wtype = slash_weapon_type
		SKState.SLASHING2:
			dmg = slash2_damage
			wtype = slash2_weapon_type
		SKState.SLASHING3:
			dmg = slash3_damage
			wtype = slash3_weapon_type
		_:
			return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(dmg, false, wtype)


# ---- Hitbox helpers ------------------------------------------------------

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


func _set_overlap_probe(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", false)


# ---- Walk-area polygon containment (mirrors CharacterBase) ------------------

## Keeps his body_box inside the walk_area polygon, pushing the largest
## out-of-bounds corner back to the nearest edge. Velocity into the wall is
## cancelled so the along-wall component carries -- i.e. he slides.
func _constrain_to_walk_area() -> void:
	var xform: Transform2D = walk_area.global_transform
	var world_poly: PackedVector2Array = PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)

	var total_offset: Vector2 = Vector2.ZERO
	for tp in _get_shape_test_points():
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
		var wall_normal: Vector2 = total_offset.normalized()
		velocity -= wall_normal * minf(velocity.dot(wall_normal), 0.0)
		knockback_velocity -= wall_normal * minf(knockback_velocity.dot(wall_normal), 0.0)


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

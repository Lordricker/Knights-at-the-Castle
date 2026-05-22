extends EnemyBase

# green_dragon.gd — Elite enemy: Green Dragon.
#
# Has two attacks:
#   - Slash:    Close-range melee triggered by DetectionZone.
#   - Fireball: Long-range projectile triggered by FireballZone.
#
# The dragon is a flying unit (oscillate = true). During the fireball
# cast animation the Pivot node shifts vertically per-frame using
# fireball_y_offsets so the dragon visually rises/dips while charging.
#
# SCENE STRUCTURE:
#   Node2D  (scene root)
#   └── CharacterBody2D  (this script)
#       ├── CollisionShape2D
#       └── Pivot  (Node2D — facing_pivot; scale.x flipped for direction)
#           ├── AnimatedSprite2D  (animations: "running", "slash", "fireball")
#           ├── SlashHitbox       (Area2D — active on slash_hitbox_frames)
#           │   └── CollisionShape2D
#           ├── DetectionZone     (Area2D — close range, triggers slash)
#           │   └── CollisionShape2D
#           ├── FireballZone      (Area2D — long range, triggers fireball)
#           │   └── CollisionShape2D
#           └── HPBar


# ── Slash ─────────────────────────────────────────────────────────────────────

@export_group("Slash")
## Area2D weapon hitbox — drag SlashHitbox here in the Inspector.
@export var slash_hitbox: Area2D
## Damage dealt per slash hit.
@export var slash_damage: float = 25.0
## Animation frame indices that activate the slash hitbox.
@export var slash_hitbox_frames: Array[int] = [2, 3]
## Knockback force applied to targets hit by slash.
@export var slash_knockback_force: float = 350.0## Sound played when the dragon begins a slash.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Sound played when the slash hitbox contacts a target.
@export var slash_hit_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_hit_sound_volume_db: float = 0.0

# ── Fireball ──────────────────────────────────────────────────────────────────

@export_group("Fireball")
## PackedScene for the fireball projectile (assign fireball.tscn in Inspector).
@export var fireball_scene: PackedScene
## Damage the fireball deals on impact.
@export var fireball_damage: float = 30.0
## Travel speed of the fireball in pixels per second.
@export var fireball_speed: float = 300.0
## Seconds before the fireball auto-explodes if it misses.
@export var fireball_lifetime: float = 3.0
## Additional launch angle in degrees — mirrored by facing (negative = upward).
@export_range(-90.0, 90.0, 1.0, "degrees") var fireball_angle: float = 0.0
## Animation frame on which the fireball is launched.
@export var fireball_fire_frame: int = 7
## Animation frame on which the windup particles begin emitting.
@export var fireball_windup_start_frame: int = 2
## Marker2D inside FireballZone indicating the fireball's spawn position.
## Drag the Marker2D node here in the Inspector.
@export var fireball_marker: Marker2D
## Area2D with a wider range that triggers the fireball attack.
## Drag the FireballZone node here in the Inspector.
@export var fireball_zone: Area2D
## Parent node holding all windup particle effects.
## Drag the parent CPUParticles2D (or Node2D) here — it will be shown/hidden as a group.
@export var fireball_windup_particles: Node2D
## Sound played when the fireball launches.
@export var fireball_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var fireball_sound_volume_db: float = 0.0

@export_group("Fireball Flight Offsets")
## Vertical offset applied to the Pivot node on each frame of the "fireball"
## animation. This shifts all visuals (and hitboxes) up or down without
## moving the physics body off the walk path — use it to make the dragon
## appear to rise or dip while charging.
## Array length should match the "fireball" animation frame count.
@export var fireball_y_offsets: Array[float] = [0.0, -5.0, -12.0, -20.0, -28.0, -32.0, -28.0, -20.0, -10.0]

@export_group("")


# ── Head hitbox ───────────────────────────────────────────────────────────────

@export_group("Head Hitbox")
## Area2D positioned over the dragon's head (needs a CollisionShape2D child).
## Fires area_entered independently from the body — deals 2× damage on its own.
@export var head_hitbox: Area2D
@export_group("")


# ── Internal state ─────────────────────────────────────────────────────────────

enum AttackState { NONE, SLASHING, CASTING_FIREBALL }

var attack_state: AttackState = AttackState.NONE
var _fireball_fired: bool = false

var _slash_swing_audio: AudioStreamPlayer2D = null
var _slash_hit_audio: AudioStreamPlayer2D = null
var _fireball_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = slash_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	if detection_zone != null:
		detection_zone.monitoring = true
	if fireball_zone != null:
		fireball_zone.monitoring = true
	_set_hitbox(slash_hitbox, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_slash_hit_body)
		slash_hitbox.area_entered.connect(_on_slash_hit_area)
	if head_hitbox != null:
		head_hitbox.collision_mask = 0xFFFF_FFFF
		head_hitbox.monitoring = true
		head_hitbox.area_entered.connect(_on_head_hit_area)
	animated_sprite.play("running")
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)
	_slash_hit_audio = _make_sfx_player(slash_hit_sound, slash_hit_sound_volume_db)
	_fireball_audio = _make_sfx_player(fireball_sound, fireball_sound_volume_db)


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(_delta: float) -> void:
	# Locked during any attack animation.
	if attack_state != AttackState.NONE:
		velocity = Vector2.ZERO
		return

	# Slash range takes priority over fireball range.
	var slash_targets := _get_targets_in_range()
	if slash_targets.size() > 0:
		target = slash_targets[0]
		velocity = Vector2.ZERO
		_begin_slash()
		return

	var fireball_targets := _get_fireball_targets()
	if fireball_targets.size() > 0:
		target = fireball_targets[0]
		velocity = Vector2.ZERO
		_begin_fireball()
		return

	# Walk toward world x = 0.
	target = null
	var dist: float = global_position.x
	if absf(dist) < 4.0:
		velocity.x = 0.0
	else:
		var dir: float = -signf(dist)
		velocity.x = move_speed * dir
		_set_facing(1.0 if dir > 0.0 else -1.0)
	velocity.y = 0.0


func _physics_process(delta: float) -> void:
	super(delta)


func _is_attacking() -> bool:
	return attack_state != AttackState.NONE


# ── Slash ──────────────────────────────────────────────────────────────────────

func _begin_slash() -> void:
	attack_state = AttackState.SLASHING
	_play_sfx(_slash_swing_audio)
	animated_sprite.stop()
	animated_sprite.play("slash")
	_face_target()


func _stop_slash() -> void:
	attack_state = AttackState.NONE
	_set_hitbox(slash_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


# ── Fireball ───────────────────────────────────────────────────────────────────

func _begin_fireball() -> void:
	attack_state = AttackState.CASTING_FIREBALL
	_fireball_fired = false
	_set_windup_particles(false)
	animated_sprite.stop()
	animated_sprite.play("fireball")
	_face_target()


func _stop_fireball() -> void:
	attack_state = AttackState.NONE
	_fireball_fired = false
	_set_windup_particles(false)
	# Reset any per-frame vertical flight offset.
	if facing_pivot != null:
		facing_pivot.position.y = 0.0
	animated_sprite.stop()
	animated_sprite.play("running")


func _fire_fireball() -> void:
	if fireball_scene == null:
		return
	_play_sfx(_fireball_audio)
	var fb := fireball_scene.instantiate() as Fireball
	if fb == null:
		return

	var shoot_dir: Vector2
	if target != null:
		shoot_dir = (target.global_position - global_position).normalized()
	else:
		shoot_dir = Vector2(facing, 0.0)

	# Mirror the angle offset by facing, matching how Arrow handles arrow_angle.
	# facing right (1) → negate the angle; facing left (-1) → keep as-is.
	if fireball_angle != 0.0:
		shoot_dir = shoot_dir.rotated(deg_to_rad(fireball_angle * -facing))

	var spawn_pos: Vector2
	if fireball_marker != null:
		spawn_pos = fireball_marker.global_position
	else:
		spawn_pos = global_position

	fb.collision_mask = 1
	fb.configure(spawn_pos, shoot_dir, fireball_speed, fireball_damage, 0.0, fireball_lifetime)

	get_tree().current_scene.call_deferred("add_child", fb)

	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":  "enemy_fireball",
			"x":  spawn_pos.x,
			"y":  spawn_pos.y,
			"dx": shoot_dir.x,
			"dy": shoot_dir.y,
			"sp": fireball_speed,
			"lt": fireball_lifetime,
		})


func _set_windup_particles(visible: bool) -> void:
	if fireball_windup_particles != null and is_instance_valid(fireball_windup_particles):
		fireball_windup_particles.visible = visible


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	var frame := animated_sprite.frame

	if attack_state == AttackState.SLASHING:
		_set_hitbox(slash_hitbox, frame in slash_hitbox_frames)

	elif attack_state == AttackState.CASTING_FIREBALL:
		# Apply per-frame vertical offset to all visuals via the Pivot node.
		if facing_pivot != null and frame < fireball_y_offsets.size():
			facing_pivot.position.y = fireball_y_offsets[frame]
		# Start windup particles on the designated frame.
		if frame == fireball_windup_start_frame:
			_set_windup_particles(true)
		# Stop windup particles and launch the fireball on the fire frame.
		if frame == fireball_fire_frame and not _fireball_fired:
			_fireball_fired = true
			_set_windup_particles(false)
			_fire_fireball()


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASHING:
			if _get_targets_in_range().size() > 0:
				_begin_slash()
			else:
				_stop_slash()
		AttackState.CASTING_FIREBALL:
			if _get_fireball_targets().size() > 0:
				_begin_fireball()
			else:
				_stop_fireball()


# ── Fireball zone target query ─────────────────────────────────────────────────

## Returns Kill-group targets from the fireball detection zone.
func _get_fireball_targets() -> Array:
	if fireball_zone == null:
		return []
	var results: Array = []
	for body in fireball_zone.get_overlapping_bodies():
		if body.is_in_group(&"Kill"):
			results.append(body)
	for area in fireball_zone.get_overlapping_areas():
		if area.is_in_group(&"Kill"):
			results.append(area)
	return results


# ── Facing helpers ─────────────────────────────────────────────────────────────

func _face_target() -> void:
	if target != null:
		_set_facing(1.0 if target.global_position.x > global_position.x else -1.0)


# ── Head hitbox ────────────────────────────────────────────────────────────────

## Called when an attacking Area2D (arrow, melee hitbox) enters the head zone.
## Fires independently from the body — no take_damage override needed.
func _on_head_hit_area(area: Area2D) -> void:
	# Ignore areas that belong to this dragon.
	if is_ancestor_of(area):
		return
	# Resolve the damage amount from the attacking area.
	var dmg := 0.0
	# Arrow exposes get_damage().
	if area.has_method("get_damage"):
		dmg = float(area.call("get_damage"))
	# Generic: area has a public damage property (e.g. future projectile types).
	elif "damage" in area:
		dmg = float(area.get("damage"))
	# Melee hitbox: damage lives on the owner character (CharacterBody2D).
	elif area.owner != null:
		if area.owner.has_method("_get_current_attack_damage"):
			dmg = float(area.owner.call("_get_current_attack_damage"))
		elif "attack_damage" in area.owner:
			dmg = float(area.owner.get("attack_damage"))
	if dmg > 0.0:
		take_damage(dmg * 2.0)


# ── Death ──────────────────────────────────────────────────────────────────────

func die(flow_success: bool = false) -> void:
	attack_state = AttackState.NONE
	_set_hitbox(slash_hitbox, false)
	if facing_pivot != null:
		facing_pivot.position.y = 0.0
	_set_windup_particles(false)
	super(flow_success)


# ── Slash hitbox helpers ───────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


func _on_slash_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	_play_sfx(_slash_hit_audio)
	if body.has_method("take_damage"):
		body.take_damage(slash_damage)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, slash_knockback_force)


func _on_slash_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	_play_sfx(_slash_hit_audio)
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(slash_damage)

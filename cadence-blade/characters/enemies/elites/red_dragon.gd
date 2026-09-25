extends EnemyBase

# red_dragon.gd — Elite enemy: Red Dragon.
#
# Has four attacks:
#   - Slash:      Close-range melee. One of three attacks randomly picked when a
#                 target enters DetectionZone (see Close-Range Attack Mix below).
#   - Pounce:     Close-range lunge, similar to the sheepdog's bash / weasel's
#                 lunge. Flips facing mid-animation (pounce_flip_frame) so the
#                 dragon looks like it turns around in the air after leaping
#                 past the target.
#   - Firebreath: Close-range breath weapon. Unlike Slash/Pounce (single hit via
#                 body_entered), FirebreathHitbox is polled every frame in
#                 firebreath_hitbox_frames and re-applies damage to whatever is
#                 still standing in it — a target that stays in the flame takes
#                 one tick of damage per active frame.
#   - Fireball:   Long-range projectile triggered by FireballZone. Same as
#                 GreenDragon — lower priority than the three close attacks.
#
# The dragon is a flying unit (oscillate = true). During the fireball
# cast animation the Pivot node shifts vertically per-frame using
# fireball_y_offsets so the dragon visually rises/dips while charging.
#
# SCENE STRUCTURE:
#   Node2D  (scene root)
#   └── CharacterBody2D  (this script)
#       ├── CollisionShape2D
#       ├── hitparticles / pounceparticles  (CPUParticles2D — one-shot FX)
#       └── Pivot  (Node2D — facing_pivot; scale.x flipped for direction)
#           ├── AnimatedSprite2D     (animations: "running", "slash", "pounce", "firebreath", "fireball")
#           ├── SlashHitbox          (Area2D — active on slash_hitbox_frames)
#           ├── PounceHitbox         (Area2D — active on pounce_hitbox_frames)
#           ├── FirebreathHitbox     (Area2D — active + damage-ticking on firebreath_hitbox_frames)
#           ├── breathparticles      (CPUParticles2D — main flame stream)
#           ├── groundbreathparticles (CPUParticles2D — ground scorch/bounce, windowed)
#           ├── DetectionZone        (Area2D — close range, triggers Slash/Pounce/Firebreath)
#           ├── FireballZone         (Area2D — long range, triggers Fireball)
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
@export var slash_knockback_force: float = 350.0
## Sound played when the dragon begins a slash.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash swing sound.
@export var slash_swing_sound_frames: Array[int] = []
## Weapon type reported to the target when the claw slash connects.
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.CLAW

# ── Pounce ────────────────────────────────────────────────────────────────────

@export_group("Pounce")
## Area2D weapon hitbox — drag PounceHitbox here in the Inspector.
@export var pounce_hitbox: Area2D
## Damage dealt if the pounce connects.
@export var pounce_damage: float = 25.0
## Animation frame indices that activate the pounce hitbox (and apply lunge speed).
@export var pounce_hitbox_frames: Array[int] = [3, 4]
## Pixels per second the dragon lunges horizontally during active pounce frames.
@export var pounce_lunge_speed: float = 260.0
## Frame on which the dragon flips facing mid-air, as if turning around after
## leaping past the target.
@export var pounce_flip_frame: int = 3
## Knockback force applied to targets hit by the pounce.
@export var pounce_knockback_force: float = 350.0
## One-shot CPUParticles2D played on pounce_particles_frame — drag "pounceparticles" here.
@export var pounce_particles: CPUParticles2D
## Frame on which pounce_particles fires (the landing impact).
@export var pounce_particles_frame: int = 6
## Sound played when the dragon begins a pounce.
@export var pounce_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var pounce_sound_volume_db: float = 0.0
## Animation frame indices that trigger the pounce sound.
@export var pounce_sound_frames: Array[int] = []
## Weapon type reported to the target when the pounce connects.
@export var pounce_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.CLAW

# ── Firebreath ────────────────────────────────────────────────────────────────

@export_group("Firebreath")
## Area2D weapon hitbox — drag FirebreathHitbox here in the Inspector.
@export var firebreath_hitbox: Area2D
## Damage applied on EVERY frame in firebreath_hitbox_frames that a target is
## still standing in the hitbox (a target that doesn't leave gets hit once per
## active frame, not just once per breath).
@export var firebreath_damage: float = 8.0
## Animation frame indices that activate the firebreath hitbox and tick damage.
@export var firebreath_hitbox_frames: Array[int] = [2, 3, 4, 5, 6, 7, 8, 9]
## Knockback force applied the first time the breath connects with a given
## target this cycle (0 = no knockback; damage still ticks every active frame).
@export var firebreath_knockback_force: float = 0.0
## Main flame CPUParticles2D — drag "breathparticles" here. Shown for the whole
## breath attack.
@export var breath_particles: Node2D
## Ground scorch / ricochet CPUParticles2D — drag "groundbreathparticles" here.
## Turns on ground_breath_start_frame (shortly after the main flame starts) and
## turns off ground_breath_off_delay seconds after the main flame stops — so
## the sequence is: flame on → ground on → flame off → ground off.
@export var ground_breath_particles: Node2D
## Frame the ground breath particles turn on.
@export var ground_breath_start_frame: int = 3
## Seconds after the main flame stops before the ground breath turns off.
@export var ground_breath_off_delay: float = 0.15
## Sound played when the dragon begins breathing fire.
@export var firebreath_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var firebreath_sound_volume_db: float = 0.0
## Animation frame indices that trigger the firebreath sound.
@export var firebreath_sound_frames: Array[int] = []
## Weapon type reported to targets hit by the breath.
@export var firebreath_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.FIREBALL

# ── Fireball ──────────────────────────────────────────────────────────────────

@export_group("Fireball")
## PackedScene for the fireball projectile (assign fireball.tscn in Inspector).
@export var fireball_scene: PackedScene
## Damage the fireball deals to the target it directly hits.
@export var fireball_damage: float = 30.0
## Damage dealt to every other Kill-group target caught in the impact splash (0 = no splash).
@export var fireball_splash_damage: float = 15.0
## Seconds the fireball's splash zone keeps dealing damage after impact.
@export var fireball_splash_duration: float = 1.0
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
## Animation frame indices that trigger the fireball sound.
@export var fireball_sound_frames: Array[int] = []

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


# ── Approach ──────────────────────────────────────────────────────────────────

@export_group("Approach")
## Area2D wider than DetectionZone — drag "ApproachZone" here in the Inspector.
## While a player is inside it (and no melee/breath attack is available yet),
## the dragon walks toward them instead of idling at the world-x=0 guard line,
## until DetectionZone reaches them and a close-range attack takes over.
@export var approach_zone: Area2D
@export_group("")


# ── Internal state ─────────────────────────────────────────────────────────────

enum AttackState { NONE, SLASHING, POUNCING, BREATHING, CASTING_FIREBALL }

## Close-range attacks — one is picked at random each time a target enters
## DetectionZone (and again each time the dragon re-attacks a target that's
## still in range).
const _CLOSE_RANGE_ATTACKS: Array[int] = [
	AttackState.SLASHING, AttackState.POUNCING, AttackState.BREATHING,
]

var attack_state: AttackState = AttackState.NONE
var _fireball_fired: bool = false
var _pounce_lunge_active: bool = false
var _pounce_flipped: bool = false
## Direction the pounce lunges in, locked in when the pounce begins. The
## frame-3 flip changes `facing` (sprite + hitbox) but must NOT reverse the
## direction of travel — otherwise the dragon reverses into a retreat right
## when it should be plowing through the target.
var _pounce_lunge_dir: float = 1.0
## Targets already knocked back by the current firebreath cycle (damage still
## ticks every active frame regardless of this).
var _firebreath_knockback_done: Dictionary = {}
## Bumped every time a firebreath cycle begins. Lets a delayed ground-breath
## turn-off (see _schedule_ground_breath_off) detect a new breath having
## started in the meantime and bail out instead of cutting the new one short.
var _firebreath_cycle: int = 0

var _slash_swing_audio: AudioStreamPlayer2D = null
var _pounce_audio: AudioStreamPlayer2D = null
var _firebreath_audio: AudioStreamPlayer2D = null
var _fireball_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = slash_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	if detection_zone != null:
		detection_zone.monitoring = true
	if approach_zone != null:
		approach_zone.monitoring = true
	if fireball_zone != null:
		fireball_zone.monitoring = true
	_set_hitbox(slash_hitbox, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_slash_hit_body)
		slash_hitbox.area_entered.connect(_on_slash_hit_area)
	_set_hitbox(pounce_hitbox, false)
	if pounce_hitbox != null:
		pounce_hitbox.body_entered.connect(_on_pounce_hit_body)
		pounce_hitbox.area_entered.connect(_on_pounce_hit_area)
	_set_hitbox(firebreath_hitbox, false)
	_set_breath_particles(false)
	_set_ground_breath_particles(false)
	# Head hitbox is now a HurtBox — it self-initializes in its own _ready().
	# Assign it in the Inspector's "hurtboxes" array with damage_multiplier = 2.0.
	animated_sprite.play("running")
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)
	_pounce_audio = _make_sfx_player(pounce_sound, pounce_sound_volume_db)
	_firebreath_audio = _make_sfx_player(firebreath_sound, firebreath_sound_volume_db)
	_fireball_audio = _make_sfx_player(fireball_sound, fireball_sound_volume_db)


# ── AI ─────────────────────────────────────────────────────────────────────────

## Facing only re-commits once the dragon is this far past the guard line (world
## x = 0), well outside the 4px stop radius below. A hut unit's arrows (or any
## other repeated small knockback) can rock the dragon a few px back and forth
## across x = 0 while it holds its post — without this margin, _set_facing would
## flip every time that noise crosses zero and the sprite would waffle in place.
const GUARD_LINE_FACING_COMMIT: float = 12.0

func _handle_ai(_delta: float) -> void:
	# Locked during any attack animation.
	if attack_state != AttackState.NONE:
		velocity = Vector2.ZERO
		return

	# Close-range (Slash / Pounce / Firebreath) takes priority over Fireball range.
	var close_targets := _get_targets_in_range()
	if close_targets.size() > 0:
		target = close_targets[0]
		velocity = Vector2.ZERO
		_begin_close_attack()
		return

	# A player close enough to walk to takes priority over lobbing fireballs
	# from a distance — close the gap toward them instead.
	var approach_target := _get_approach_target()
	if approach_target != null:
		target = approach_target
		var dir: float = signf(approach_target.global_position.x - global_position.x)
		velocity.x = move_speed * dir
		if dir != 0.0:
			_set_facing(dir)
		velocity.y = 0.0
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
		if absf(dist) > GUARD_LINE_FACING_COMMIT:
			_set_facing(1.0 if dir > 0.0 else -1.0)
	velocity.y = 0.0


func _physics_process(delta: float) -> void:
	super(delta)
	# Pounce lunge is applied after move_and_slide so it doesn't fight the
	# walk-path/knockback resolution above (mirrors sheepdog/red_knight lunges).
	if _pounce_lunge_active:
		global_position.x += _pounce_lunge_dir * pounce_lunge_speed * delta


func _is_attacking() -> bool:
	return attack_state != AttackState.NONE


## Randomly picks one of the three close-range attacks and begins it.
func _begin_close_attack() -> void:
	match _CLOSE_RANGE_ATTACKS[randi() % _CLOSE_RANGE_ATTACKS.size()]:
		AttackState.SLASHING:
			_begin_slash()
		AttackState.POUNCING:
			_begin_pounce()
		AttackState.BREATHING:
			_begin_firebreath()


# ── Slash ──────────────────────────────────────────────────────────────────────

func _begin_slash() -> void:
	attack_state = AttackState.SLASHING
	animated_sprite.stop()
	animated_sprite.play("slash")
	_face_target()


func _stop_slash() -> void:
	attack_state = AttackState.NONE
	_set_hitbox(slash_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


# ── Pounce ─────────────────────────────────────────────────────────────────────

func _begin_pounce() -> void:
	attack_state = AttackState.POUNCING
	_pounce_lunge_active = false
	_pounce_flipped = false
	animated_sprite.stop()
	animated_sprite.play("pounce")
	_face_target()
	# Lock the travel direction in now — the frame-3 flip only turns the
	# sprite/hitbox around, it must not reverse where the lunge is heading.
	_pounce_lunge_dir = facing


func _stop_pounce() -> void:
	attack_state = AttackState.NONE
	_pounce_lunge_active = false
	_set_hitbox(pounce_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


# ── Firebreath ─────────────────────────────────────────────────────────────────

func _begin_firebreath() -> void:
	attack_state = AttackState.BREATHING
	_firebreath_cycle += 1
	_firebreath_knockback_done.clear()
	_set_ground_breath_particles(false)
	animated_sprite.stop()
	animated_sprite.play("firebreath")
	_face_target()
	_set_breath_particles(true)


## Ends the breath attack: hitbox and main flame cut immediately, ground
## breath fades out ground_breath_off_delay seconds later. Called both when
## the dragon stops attacking entirely and when it chains straight into
## another close-range attack (see _on_animation_finished) — the hitbox/main
## flame must be torn down there too, or they're left running "stuck on"
## under whichever attack gets picked next.
func _end_firebreath_attack() -> void:
	_set_hitbox(firebreath_hitbox, false)
	_set_breath_particles(false)
	_schedule_ground_breath_off()


func _stop_firebreath() -> void:
	attack_state = AttackState.NONE
	_end_firebreath_attack()
	animated_sprite.stop()
	animated_sprite.play("running")


func _set_breath_particles(on: bool) -> void:
	if breath_particles != null and is_instance_valid(breath_particles):
		breath_particles.visible = on


func _set_ground_breath_particles(on: bool) -> void:
	if ground_breath_particles != null and is_instance_valid(ground_breath_particles):
		ground_breath_particles.visible = on


## Turns the ground breath off ground_breath_off_delay seconds from now,
## unless a new firebreath cycle has already started by then (cycle mismatch)
## — in which case the new cycle owns the particles and this no-ops.
func _schedule_ground_breath_off() -> void:
	if ground_breath_particles == null:
		return
	var cycle: int = _firebreath_cycle
	get_tree().create_timer(ground_breath_off_delay, false).timeout.connect(
		func() -> void:
			if is_instance_valid(self) and cycle == _firebreath_cycle:
				_set_ground_breath_particles(false)
	)


## Damages every Kill-group target still overlapping the firebreath hitbox.
## Called once per active frame — unlike Slash/Pounce this is NOT a one-shot
## body_entered hit, so a target that stays put takes one tick per active frame.
func _apply_firebreath_damage() -> void:
	if firebreath_hitbox == null:
		return
	for body in firebreath_hitbox.get_overlapping_bodies():
		_damage_firebreath_target(body)
	for area in firebreath_hitbox.get_overlapping_areas():
		var owner_node := area.get_parent()
		if owner_node != null:
			_damage_firebreath_target(owner_node)


func _damage_firebreath_target(node: Node) -> void:
	if node == null or not node.is_in_group(&"Kill"):
		return
	if node.has_method("take_damage"):
		node.take_damage(firebreath_damage, false, firebreath_weapon_type)
	if firebreath_knockback_force > 0.0 and node.is_in_group(&"KillCharacter") \
			and node.has_method("apply_knockback"):
		var id := node.get_instance_id()
		if not _firebreath_knockback_done.has(id):
			_firebreath_knockback_done[id] = true
			node.apply_knockback(global_position, firebreath_knockback_force)


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

	fb.collision_layer = 0  # invisible to Area2D monitors; damage via own body_entered
	fb.collision_mask = 1
	fb.shooter = self
	fb.configure(spawn_pos, shoot_dir, fireball_speed, fireball_damage, 0.0, fireball_lifetime,
		fireball_splash_damage, fireball_splash_duration)

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

	match attack_state:
		AttackState.SLASHING:
			_set_hitbox(slash_hitbox, frame in slash_hitbox_frames)
			if frame in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)

		AttackState.POUNCING:
			var active: bool = frame in pounce_hitbox_frames
			_set_hitbox(pounce_hitbox, active)
			_pounce_lunge_active = active
			if frame == pounce_flip_frame and not _pounce_flipped:
				_pounce_flipped = true
				_set_facing(-facing)
			if frame == pounce_particles_frame and pounce_particles != null:
				pounce_particles.restart()
			if frame in pounce_sound_frames:
				_play_sfx(_pounce_audio)

		AttackState.BREATHING:
			var breath_active: bool = frame in firebreath_hitbox_frames
			# Non-deferred: _apply_firebreath_damage() below queries overlaps in
			# this same call, so the hitbox needs monitoring on immediately
			# rather than at the next physics flush.
			if firebreath_hitbox != null:
				firebreath_hitbox.monitoring = breath_active
				firebreath_hitbox.monitorable = breath_active
			if breath_active:
				_apply_firebreath_damage()
			if frame == ground_breath_start_frame:
				_set_ground_breath_particles(true)
			if frame in firebreath_sound_frames:
				_play_sfx(_firebreath_audio)

		AttackState.CASTING_FIREBALL:
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
			if frame in fireball_sound_frames:
				_play_sfx(_fireball_audio)


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASHING, AttackState.POUNCING, AttackState.BREATHING:
			var was_breathing: bool = attack_state == AttackState.BREATHING
			var close_targets := _get_targets_in_range()
			if close_targets.size() > 0:
				# Refresh target every re-attack (not just on the very first
				# trigger) — bodies sort before areas in _get_targets_in_range,
				# so this is also what makes a player take priority over the
				# castle the moment they're both in range.
				target = close_targets[0]
				# Chaining straight into the next close-range attack — if we
				# were breathing, tear its hitbox/flame down first (see
				# _end_firebreath_attack) instead of leaving them running
				# under whatever attack gets picked next.
				if was_breathing:
					_end_firebreath_attack()
				_begin_close_attack()
			else:
				match attack_state:
					AttackState.SLASHING: _stop_slash()
					AttackState.POUNCING: _stop_pounce()
					AttackState.BREATHING: _stop_firebreath()
		AttackState.CASTING_FIREBALL:
			# A player closing to melee range takes priority over continuing to
			# lob fireballs at the castle — break out of the fireball loop so
			# _handle_ai() picks a close-range attack on the next physics tick.
			if _get_targets_in_range().size() > 0:
				_stop_fireball()
				return
			var fireball_targets := _get_fireball_targets()
			if fireball_targets.size() > 0:
				# Same refresh as above: a player in fireball range also sorts
				# ahead of the castle, so re-picking here re-targets onto them.
				target = fireball_targets[0]
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


# ── Approach zone target query ──────────────────────────────────────────────────

## Nearest living player inside ApproachZone, or null. Players only — the
## castle doesn't move, so there's nothing to "approach" it for; the existing
## guard-line walk already gets the dragon to it.
func _get_approach_target() -> Node2D:
	if approach_zone == null:
		return null
	var best: Node2D = null
	var best_dist: float = INF
	for body in approach_zone.get_overlapping_bodies():
		if not body.is_in_group(&"KillCharacter") or bool(body.get("is_dead")):
			continue
		var player := body as Node2D
		if player == null:
			continue
		var d: float = global_position.distance_squared_to(player.global_position)
		if d < best_dist:
			best_dist = d
			best = player
	return best


# ── Facing helpers ─────────────────────────────────────────────────────────────

func _face_target() -> void:
	if target != null:
		_set_facing(1.0 if target.global_position.x > global_position.x else -1.0)


# ── Death ──────────────────────────────────────────────────────────────────────

func die(flow_success: bool = false) -> void:
	attack_state = AttackState.NONE
	_pounce_lunge_active = false
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(pounce_hitbox, false)
	_set_hitbox(firebreath_hitbox, false)
	_set_breath_particles(false)
	_set_ground_breath_particles(false)
	if facing_pivot != null:
		facing_pivot.position.y = 0.0
	_set_windup_particles(false)
	super(flow_success)


# ── Hitbox helpers ──────────────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


func _on_slash_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	if body.has_method("take_damage"):
		body.take_damage(slash_damage, false, slash_weapon_type)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, slash_knockback_force)


func _on_slash_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(slash_damage, false, slash_weapon_type)


func _on_pounce_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	if body.has_method("take_damage"):
		body.take_damage(pounce_damage, false, pounce_weapon_type)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, pounce_knockback_force)


func _on_pounce_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(pounce_damage, false, pounce_weapon_type)

extends EnemyBase

# green_knight.gd -- Elite enemy: Green Knight.
# An upgraded variant of the Black Knight with two slash attacks and a block.
#
# ANIMATIONS (AnimatedSprite2D SpriteFrames):
#   "running" -- loop ON  (identical to Black Knight)
#   "slash"   -- loop OFF
#   "slash2"  -- loop OFF
#   "block"   -- loop OFF
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   +-- CollisionShape2D
#   +-- Pivot (Node2D)
#       +-- AnimatedSprite2D
#       +-- SlashHitbox   (Area2D -- drag into Inspector "slash_hitbox")
#       |   +-- CollisionShape2D
#       +-- Slash2Hitbox  (Area2D -- drag into Inspector "slash2_hitbox")
#       |   +-- CollisionShape2D
#       +-- BlockZone     (Area2D -- drag into Inspector "block_zone")
#       |   +-- CollisionShape2D  (covers knight body; set mask to player attack layer)
#       +-- DetectionZone (Area2D -- drag into Inspector "detection_zone")
#       |   +-- CollisionShape2D
#       +-- HPBar


# ---- Slash -------------------------------------------------------------------

@export_group("Slash")
## Drag the Area2D weapon hitbox for the "slash" animation here.
## Keeping this as a node reference means renaming the node won't break it.
@export var slash_hitbox: Area2D
## Damage dealt per slash hit.
@export var slash_damage: float = 20.0
## Frame index (0-based) that activates the slash hitbox.
@export var slash_attack_frame: int = 3
## Knockback force applied to targets hit by slash.
@export var slash_knockback_force: float = 300.0
## Sound played when a slash begins.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash swing sound.
@export var slash_swing_sound_frames: Array[int] = []
## Weapon type reported to the target when the slash connects.
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD


# ---- Slash2 ------------------------------------------------------------------

@export_group("Slash2")
## Drag the Area2D weapon hitbox for the "slash2" animation here.
@export var slash2_hitbox: Area2D
## Damage dealt per slash2 hit.
@export var slash2_damage: float = 25.0
## Frame index (0-based) that activates the slash2 hitbox.
@export var slash2_attack_frame: int = 4
## Knockback force applied to targets hit by slash2.
@export var slash2_knockback_force: float = 350.0
## Parent CPUParticles2D node to emit during the slash2 animation.
@export var slash2_particles: CPUParticles2D
## Frame index (0-based) on which to emit slash2_particles.
@export var slash2_particle_frame: int = 4
## Sound played when slash2 begins.
@export var slash2_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash2_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash2 swing sound.
@export var slash2_swing_sound_frames: Array[int] = []
## Weapon type reported to the target when slash2 connects.
@export var slash2_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD


# ---- Block -------------------------------------------------------------------

@export_group("Block")
## Drag the Area2D that detects incoming attack hitboxes while blocking.
## IMPORTANT: set its collision mask to match the layer your player attack
## hitboxes live on so they can be detected during a block.
@export var block_zone: Area2D
## Percentage of incoming damage negated while blocking (0-100).
@export_range(0.0, 100.0, 1.0) var block_damage_reduction: float = 20.0
## Knockback force applied back to the attacker when a hit is blocked.
@export var block_knockback_force: float = 300.0
## When unchecked the enemy never uses the block action (e.g. spearman variants).
@export var enable_block: bool = true

@export_group("")


# ---- Internal state ----------------------------------------------------------

enum GKState { NONE, SLASHING, SLASHING2, BLOCKING }

var _state: GKState = GKState.NONE

var _slash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _slash2_hitbox_right_pos: Vector2 = Vector2.ZERO
var _detection_zone_right_pos: Vector2 = Vector2.ZERO

var _slash_swing_audio: AudioStreamPlayer2D = null
var _slash2_swing_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = slash_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	if detection_zone != null:
		detection_zone.monitoring = true
	_set_hitbox(slash_hitbox, false)
	# slash2_hitbox may point to the same node as slash_hitbox; only connect once.
	if slash2_hitbox != null and slash2_hitbox != slash_hitbox:
		_set_hitbox(slash2_hitbox, false)
	_set_hitbox(block_zone, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_attack_hit_body)
		slash_hitbox.area_entered.connect(_on_attack_hit_area)
	if slash2_hitbox != null and slash2_hitbox != slash_hitbox:
		slash2_hitbox.body_entered.connect(_on_attack_hit_body)
		slash2_hitbox.area_entered.connect(_on_attack_hit_area)
	if block_zone != null:
		block_zone.area_entered.connect(_on_block_zone_area_entered)
	animated_sprite.play("running")
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)
	_slash2_swing_audio = _make_sfx_player(slash2_swing_sound, slash2_swing_sound_volume_db)


# ---- AI ----------------------------------------------------------------------

func _handle_ai(_delta: float) -> void:
	var bodies := _get_targets_in_range()
	var in_range := bodies.size() > 0

	if in_range:
		target = bodies[0]

	# Locked during any action animation.
	if _state != GKState.NONE:
		velocity = Vector2.ZERO
		return

	if in_range:
		velocity = Vector2.ZERO
		_begin_random_action()
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
	return _state != GKState.NONE


# ---- Actions -----------------------------------------------------------------

func _begin_random_action() -> void:
	if enable_block:
		match randi() % 3:
			0: _begin_slash()
			1: _begin_slash2()
			2: _begin_block()
	else:
		if randi() % 2 == 0:
			_begin_slash()
		else:
			_begin_slash2()


func _begin_slash() -> void:
	_state = GKState.SLASHING
	_set_hitbox(block_zone, false)
	animated_sprite.stop()
	animated_sprite.play("slash")
	_face_target()


func _begin_slash2() -> void:
	_state = GKState.SLASHING2
	_set_hitbox(block_zone, false)
	animated_sprite.stop()
	animated_sprite.play("slash2")
	_face_target()


func _begin_block() -> void:
	_state = GKState.BLOCKING
	_set_overlap_probe(slash_hitbox, true)
	if slash2_hitbox != null and slash2_hitbox != slash_hitbox:
		_set_hitbox(slash2_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("block")
	_set_hitbox(block_zone, true)


func _face_target() -> void:
	if target != null:
		_set_facing(1.0 if target.global_position.x > global_position.x else -1.0)


func _stop_action() -> void:
	_state = GKState.NONE
	_set_hitbox(slash_hitbox, false)
	if slash2_hitbox != null and slash2_hitbox != slash_hitbox:
		_set_hitbox(slash2_hitbox, false)
	_set_hitbox(block_zone, false)
	animated_sprite.stop()
	animated_sprite.play("running")


func die(flow_success: bool = false) -> void:
	_state = GKState.NONE
	_set_hitbox(slash_hitbox, false)
	if slash2_hitbox != null and slash2_hitbox != slash_hitbox:
		_set_hitbox(slash2_hitbox, false)
	_set_hitbox(block_zone, false)
	super(flow_success)


# ---- Damage override ---------------------------------------------------------

## Reduce incoming damage while blocking. Knockback to the attacker is handled
## from the AttackHitbox overlap when damage actually lands.
func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	var effective_flow_success := flow_success
	if _state == GKState.BLOCKING:
		effective_flow_success = false
		_apply_block_contact_knockback()
		amount = amount * (1.0 - clampf(block_damage_reduction, 0.0, 100.0) / 100.0)
	super(amount, effective_flow_success, weapon_type)


# ---- Frame / animation signals -----------------------------------------------

func _on_frame_changed() -> void:
	match _state:
		GKState.SLASHING:
			_set_hitbox(slash_hitbox, animated_sprite.frame == slash_attack_frame)
			if animated_sprite.frame in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)
		GKState.SLASHING2:
			_set_hitbox(slash2_hitbox, animated_sprite.frame == slash2_attack_frame)
			if slash2_particles != null and animated_sprite.frame == slash2_particle_frame:
				slash2_particles.restart()
			if animated_sprite.frame in slash2_swing_sound_frames:
				_play_sfx(_slash2_swing_audio)


func _on_animation_finished() -> void:
	match _state:
		GKState.SLASHING, GKState.SLASHING2, GKState.BLOCKING:
			if _get_targets_in_range().size() > 0:
				_begin_random_action()
			else:
				_stop_action()


# ---- Block zone --------------------------------------------------------------

## Fires when an Area2D enters the block zone (block_zone must be monitoring).
## Knockback is handled from take_damage() so the player is only pushed when
## the block actually absorbs a hit.
func _on_block_zone_area_entered(area: Area2D) -> void:
	pass


# ---- Hitbox helpers ----------------------------------------------------------

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


func _apply_block_contact_knockback() -> void:
	var probe: Area2D = slash_hitbox if slash_hitbox != null else slash2_hitbox
	if probe == null:
		return
	var pushed: Dictionary = {}
	for body in probe.get_overlapping_bodies():
		var target := body as Node2D
		if target == null:
			continue
		if not target.is_in_group(&"KillCharacter"):
			continue
		if not target.has_method("apply_knockback"):
			continue
		var id: int = target.get_instance_id()
		if pushed.has(id):
			continue
		pushed[id] = true
		target.apply_knockback(global_position, block_knockback_force)


## Unified handler for both slash and slash2 hitboxes hitting a body.
## Reads damage and knockback from the currently active attack state.
func _on_attack_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	var dmg: float
	var kb: float
	var wtype: WeaponType.WeaponType
	match _state:
		GKState.SLASHING:
			dmg = slash_damage
			kb = slash_knockback_force
			wtype = slash_weapon_type
		GKState.SLASHING2:
			dmg = slash2_damage
			kb = slash2_knockback_force
			wtype = slash2_weapon_type
		_:
			return
	if body.has_method("take_damage"):
		body.take_damage(dmg, false, wtype)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, kb)


## Unified handler for both slash and slash2 hitboxes hitting an Area2D.
func _on_attack_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	var dmg: float
	var wtype: WeaponType.WeaponType
	match _state:
		GKState.SLASHING:
			dmg = slash_damage
			wtype = slash_weapon_type
		GKState.SLASHING2:
			dmg = slash2_damage
			wtype = slash2_weapon_type
		_:
			return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(dmg, false, wtype)


# ---- Facing ------------------------------------------------------------------

func _capture_right_facing_transforms() -> void:
	super()
	if slash_hitbox != null:
		_slash_hitbox_right_pos = slash_hitbox.position
	if slash2_hitbox != null:
		_slash2_hitbox_right_pos = slash2_hitbox.position
	if detection_zone != null:
		_detection_zone_right_pos = detection_zone.position


func _apply_facing() -> void:
	if animated_sprite == null:
		return
	super()
	if facing_pivot != null:
		return
	if slash_hitbox != null:
		slash_hitbox.position = Vector2(_slash_hitbox_right_pos.x * facing, _slash_hitbox_right_pos.y)
	if slash2_hitbox != null:
		slash2_hitbox.position = Vector2(_slash2_hitbox_right_pos.x * facing, _slash2_hitbox_right_pos.y)
	if detection_zone != null:
		detection_zone.position = Vector2(_detection_zone_right_pos.x * facing, _detection_zone_right_pos.y)

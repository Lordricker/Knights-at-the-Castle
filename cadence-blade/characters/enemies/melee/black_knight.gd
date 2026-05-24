extends EnemyBase

# black_knight.gd — Elite enemy: Black Knight.
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D  (animations: "running", "slash")
#   ├── CollisionShape2D
#   ├── SlashHitbox   (Area2D — weapon hitbox, enabled on attack frames)
#   │   └── CollisionShape2D
#   └── DetectionZone (Area2D — triggers attack when player walks into it)
#       └── CollisionShape2D  (set width to represent attack range)

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Combat")
## Damage dealt per slash hit.
@export var slash_damage: float = 20.0
## Which frames of the slash animation activate the weapon hitbox.
@export var slash_hitbox_frames: Array[int] = [2, 6]
## How hard the black knight's slash knocks the player back.
@export var knockback_force: float = 300.0
## Sound played when a slash begins.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash swing sound.
@export var slash_swing_sound_frames: Array[int] = []
## Weapon type reported to the target when this slash connects.
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD


# ── Internal state ─────────────────────────────────────────────────────────────

enum SlashState { NONE, ATTACKING }

var slash_state: SlashState = SlashState.NONE

var _slash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _detection_zone_right_pos: Vector2 = Vector2.ZERO

@onready var slash_hitbox: Area2D = find_child("SlashHitbox") as Area2D

var _slash_swing_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	
	attack_damage = slash_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	# Ensure detection zone is always active regardless of inspector state.
	detection_zone.monitoring = true
	_set_hitbox(slash_hitbox, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_hit_body)
		slash_hitbox.area_entered.connect(_on_hit_area)
	animated_sprite.play("running")
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(_delta: float) -> void:
	# Poll the detection zone for "Kill" group bodies every frame.
	var bodies := _get_targets_in_range()
	var in_range := bodies.size() > 0

	if in_range:
		target = bodies[0]

	# Locked during attack animation.
	if slash_state == SlashState.ATTACKING:
		velocity = Vector2.ZERO
		return

	# Player is in detection zone — stop and attack.
	if in_range:
		velocity = Vector2.ZERO
		_begin_slash()
		return

	# Walk toward world x = 0.
	target = null
	var dist: float = global_position.x
	if absf(dist) < 4.0:
		velocity.x = 0.0
	else:
		var dir: float = -signf(dist)
		velocity.x = move_speed * dir
		# Face toward x = 0 (the direction we're walking).
		_set_facing(1.0 if dir > 0.0 else -1.0)

	# Y is handled by _constrain_to_path() in EnemyBase._physics_process.
	velocity.y = 0.0


func _physics_process(delta: float) -> void:
	super(delta)


func _is_attacking() -> bool:
	return slash_state == SlashState.ATTACKING


func _begin_slash() -> void:
	slash_state = SlashState.ATTACKING
	animated_sprite.stop()  # interrupt walk animation immediately
	animated_sprite.play("slash")
	# Face toward the detected player.
	if target != null:
		if target.global_position.x > global_position.x:
			_set_facing(1.0)
		else:
			_set_facing(-1.0)


func _stop_attack() -> void:
	slash_state = SlashState.NONE
	_set_hitbox(slash_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


func die(flow_success: bool = false) -> void:
	slash_state = SlashState.NONE
	_set_hitbox(slash_hitbox, false)
	super(flow_success)


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	if slash_state == SlashState.ATTACKING:
		_set_hitbox(slash_hitbox, animated_sprite.frame in slash_hitbox_frames)
		if animated_sprite.frame in slash_swing_sound_frames:
			_play_sfx(_slash_swing_audio)


func _on_animation_finished() -> void:
	if slash_state == SlashState.ATTACKING:
		# Poll again at animation end to decide whether to loop or stop.
		if _get_targets_in_range().size() > 0:
			_begin_slash()
		else:
			_stop_attack()


# ── Hitbox helper ──────────────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


## Called when the slash hitbox touches a CharacterBody2D / StaticBody2D.
func _on_hit_body(body: Node2D) -> void:
	if not body.is_in_group(&"Kill"):
		return
	if body.has_method("take_damage"):
		body.take_damage(attack_damage, false, slash_weapon_type)
	# Only apply knockback to characters, not static objects like the castle.
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


## Called when the slash hitbox touches an Area2D (e.g. the castle's Kill hitbox).
## Walks up to the parent to find the node that owns take_damage().
func _on_hit_area(area: Area2D) -> void:
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(attack_damage, false, slash_weapon_type)


func _capture_right_facing_transforms() -> void:
	super()
	if slash_hitbox != null:
		_slash_hitbox_right_pos = slash_hitbox.position
	if detection_zone != null:
		_detection_zone_right_pos = detection_zone.position


func _apply_facing() -> void:
	if animated_sprite == null:
		return
	super()  # handles pivot scale or sprite flip_h + health_bar mirroring
	if facing_pivot != null:
		return
	# No pivot: additionally mirror knight-specific nodes.
	if slash_hitbox != null:
		slash_hitbox.position = Vector2(_slash_hitbox_right_pos.x * facing, _slash_hitbox_right_pos.y)
	if detection_zone != null:
		detection_zone.position = Vector2(_detection_zone_right_pos.x * facing, _detection_zone_right_pos.y)

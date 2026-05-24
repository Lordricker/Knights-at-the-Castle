extends EnemyBase

# black_archer.gd — Ranged enemy: Black Archer.
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── CollisionShape2D
#   └── Pivot (Node2D, facing_pivot)
#       ├── AnimatedSprite2D  (animations: "running", "shoot")
#       ├── DetectionZone (Area2D — wide range; triggers shoot when a player enters)
#       │   └── CollisionShape2D
#       └── HPBar
#
# Assign arrow.tscn to arrow_scene in the Inspector before use.

const SHOOT_FRAME: int = 5

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Combat")
## Arrow PackedScene to instantiate on each shot (assign arrow.tscn in Inspector).
@export var arrow_scene: PackedScene
## Damage the arrow deals on hit.
@export var arrow_damage: float = 15.0
## Arrow travel speed in pixels per second.
@export var arrow_speed: float = 400.0
## Seconds before the arrow despawns if it hasn't hit anything.
@export var arrow_lifetime: float = 2.5
## Fixed angle offset added to the shot direction in degrees (negative = upward).
@export_range(-90.0, 90.0, 1.0, "degrees") var arrow_angle: float = 0.0
## Sound played when an arrow fires.
@export var shoot_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var shoot_sound_volume_db: float = 0.0
## Animation frame indices that trigger the shoot sound.
@export var shoot_sound_frames: Array[int] = []

# ── Internal state ─────────────────────────────────────────────────────────────

enum ShootState { NONE, ATTACKING }

var shoot_state: ShootState = ShootState.NONE
## Guards against firing the arrow more than once per animation play.
var _arrow_fired: bool = false

var _shoot_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	attack_damage = arrow_damage
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	detection_zone.monitoring = true
	animated_sprite.play("running")
	_shoot_audio = _make_sfx_player(shoot_sound, shoot_sound_volume_db)


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(_delta: float) -> void:
	var bodies := _get_targets_in_range()
	var in_range := bodies.size() > 0

	if in_range:
		target = bodies[0]

	# Locked during shoot animation.
	if shoot_state == ShootState.ATTACKING:
		velocity = Vector2.ZERO
		return

	# Player is in detection zone — stop and shoot.
	if in_range:
		velocity = Vector2.ZERO
		_begin_shoot()
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
	return shoot_state == ShootState.ATTACKING


func _begin_shoot() -> void:
	shoot_state = ShootState.ATTACKING
	_arrow_fired = false
	animated_sprite.stop()
	animated_sprite.play("shoot")
	if target != null:
		_set_facing(1.0 if target.global_position.x > global_position.x else -1.0)


func _stop_attack() -> void:
	shoot_state = ShootState.NONE
	animated_sprite.stop()
	animated_sprite.play("running")


func die(flow_success: bool = false) -> void:
	shoot_state = ShootState.NONE
	super(flow_success)


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	if shoot_state == ShootState.ATTACKING:
		if animated_sprite.frame in shoot_sound_frames:
			_play_sfx(_shoot_audio)
		if animated_sprite.frame == SHOOT_FRAME and not _arrow_fired:
			_arrow_fired = true
			_fire_arrow()


func _on_animation_finished() -> void:
	if shoot_state == ShootState.ATTACKING:
		if _get_targets_in_range().size() > 0:
			_begin_shoot()
		else:
			_stop_attack()


# ── Arrow firing ───────────────────────────────────────────────────────────────

func _fire_arrow() -> void:
	if arrow_scene == null:
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return

	var shoot_dir: Vector2
	if target != null:
		shoot_dir = (target.global_position - global_position).normalized()
	else:
		shoot_dir = Vector2(facing, 0.0)

	# facing right (1) → negate the angle; facing left (-1) → use as entered.
	if arrow_angle != 0.0:
		shoot_dir = shoot_dir.rotated(deg_to_rad(arrow_angle * -facing))

	# collision_mask = 1 so the arrow detects players and the castle StaticBody2D.
	arrow.collision_mask = 1
	arrow.configure(global_position, shoot_dir, arrow_speed, arrow_damage, 0.0)
	arrow.lifetime = arrow_lifetime
	# Lambda: handle Area2D hits (e.g. castle's Kill area).
	# Self-contained so it works even if the archer is freed before the arrow lands.
	var dmg := arrow_damage
	arrow.area_entered.connect(func(area: Area2D) -> void:
		if not area.is_in_group(&"Kill"):
			return
		var owner_node := area.get_parent()
		if owner_node != null and owner_node.has_method("take_damage"):
			owner_node.take_damage(dmg, false, arrow.weapon_type)
		if is_instance_valid(arrow):
			arrow.queue_free()
	)
	get_tree().current_scene.call_deferred("add_child", arrow)
	# Broadcast to joiner so they see a display-only copy of the arrow.
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":  "enemy_arrow",
			"x":  global_position.x,
			"y":  global_position.y,
			"dx": shoot_dir.x,
			"dy": shoot_dir.y,
			"sp": arrow_speed,
			"lt": arrow_lifetime,
		})

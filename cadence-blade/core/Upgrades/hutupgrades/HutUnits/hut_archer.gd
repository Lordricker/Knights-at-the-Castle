extends CharacterBody2D

# hut_archer.gd — Friendly ranged unit spawned by UnitHut.
#
# Walks from its spawn position to `destination` (a Marker2D assigned at
# runtime by UnitHut._spawn_unit()), then holds that position and shoots
# arrows at any EnemyBase that enters DetectionZone. Never targets the
# "Kill" group (players/castle) — only real EnemyBase instances.
#
# SCENE STRUCTURE (unchanged from the original enemy prefab):
#   CharacterBody2D  (this script)
#   ├── CollisionShape2D
#   ├── Pivot
#   │   ├── AnimatedSprite2D  (animations: "idle", "running", "shoot")
#   │   ├── DetectionZone (Area2D — wide range; triggers shoot when an enemy is near)
#   │   └── HPBar
#   └── hitparticles (CPUParticles2D)

const DamageNumber = preload("res://FX/damage_number.gd")
const HutDot = preload("res://core/Upgrades/hutupgrades/HutUnits/hut_dot.gd")
const SHOOT_FRAME: int = 5

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Combat")
@export var arrow_scene: PackedScene
@export var arrow_damage: float = 15.0
@export var arrow_speed: float = 400.0
@export var arrow_lifetime: float = 2.5
@export_range(-90.0, 90.0, 1.0, "degrees") var arrow_angle: float = 0.0
@export var shoot_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var shoot_sound_volume_db: float = 0.0
@export var shoot_sound_frames: Array[int] = []

@export_group("Stats")
@export var max_health: float = 100.0
@export var move_speed: float = 80.0

@export_group("Setup")
@export var facing_pivot: Node2D
@export var health_bar: Node2D
@export var detection_zone: Area2D
@export var hit_particles: CPUParticles2D
## Assigned at runtime by UnitHut._spawn_unit(). Not set in the editor.
var destination: Marker2D = null

## Lvl3+: arrow hits apply a poison damage-over-time effect.
@export_group("Poison")
@export var poison_enabled: bool = false
@export var poison_damage_per_tick: float = 3.0
@export var poison_tick_interval: float = 1.0
@export var poison_duration: float = 4.0

@export_group("Walk Sound")
@export var walk_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var walk_sound_volume_db: float = 0.0
@export var walk_sound_footstep_frames: Array[int] = []

@export_group("Hit Sounds")
@export var hit_sound_sword: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_sword_volume_db: float = 0.0
@export var hit_sound_arrow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_arrow_volume_db: float = 0.0
@export var hit_sound_hammer: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_hammer_volume_db: float = 0.0
@export var hit_sound_claw: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_claw_volume_db: float = 0.0
@export var hit_sound_fireball: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_fireball_volume_db: float = 0.0
@export var hit_sound_sword_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_sword_flow_volume_db: float = 0.0
@export var hit_sound_arrow_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_arrow_flow_volume_db: float = 0.0
@export var hit_sound_hammer_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_hammer_flow_volume_db: float = 0.0
@export var hit_sound_claw_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_claw_flow_volume_db: float = 0.0
@export var hit_sound_fireball_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_fireball_flow_volume_db: float = 0.0

# ── Runtime state ─────────────────────────────────────────────────────────────

enum GuardState { WALK, GUARD }
enum ShootState { NONE, ATTACKING }

var _guard_state: GuardState = GuardState.WALK
var shoot_state: ShootState = ShootState.NONE
var health: float = 0.0
var is_dead: bool = false
var target: Node2D = null
var facing: float = 1.0
var _arrow_fired: bool = false
var _prev_footstep_frame: int = -1
## Keyed by target instance ID -> {ticks_left, timer}. See hut_dot.gd.
var _active_dots: Dictionary = {}

signal health_changed(new_health: float, max_hp: float)
## Emitted once, right when death starts. UnitHut listens for this to drive respawn.
signal died

var _shoot_audio: AudioStreamPlayer2D = null
var _walk_audio: AudioStreamPlayer2D = null
var _hit_audio_sword: AudioStreamPlayer2D = null
var _hit_audio_arrow: AudioStreamPlayer2D = null
var _hit_audio_hammer: AudioStreamPlayer2D = null
var _hit_audio_claw: AudioStreamPlayer2D = null
var _hit_audio_fireball: AudioStreamPlayer2D = null
var _hit_audio_sword_flow: AudioStreamPlayer2D = null
var _hit_audio_arrow_flow: AudioStreamPlayer2D = null
var _hit_audio_hammer_flow: AudioStreamPlayer2D = null
var _hit_audio_claw_flow: AudioStreamPlayer2D = null
var _hit_audio_fireball_flow: AudioStreamPlayer2D = null

var _hit_flash_material: ShaderMaterial = null
var _hit_flash_tween: Tween = null
const _HIT_FLASH_SHADER := "res://assets/shaders/hit_flash.gdshader"
const _HIT_FLASH_DURATION := 0.15

@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	health = max_health
	health_changed.connect(_on_health_changed)
	health_changed.emit(health, max_health)
	add_to_group(&"entities")
	add_to_group(&"Kill")  # so real enemies can target this unit back
	add_to_group(&"hut_units")  # so the priest can find/heal this unit

	if detection_zone != null:
		detection_zone.monitoring = true

	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play(&"running")

	_shoot_audio         = _make_sfx_player(shoot_sound, shoot_sound_volume_db)
	_walk_audio          = _make_sfx_player(walk_sound, walk_sound_volume_db)
	_hit_audio_sword     = _make_sfx_player(hit_sound_sword, hit_sound_sword_volume_db)
	_hit_audio_arrow     = _make_sfx_player(hit_sound_arrow, hit_sound_arrow_volume_db)
	_hit_audio_hammer    = _make_sfx_player(hit_sound_hammer, hit_sound_hammer_volume_db)
	_hit_audio_claw      = _make_sfx_player(hit_sound_claw, hit_sound_claw_volume_db)
	_hit_audio_fireball  = _make_sfx_player(hit_sound_fireball, hit_sound_fireball_volume_db)
	_hit_audio_sword_flow    = _make_sfx_player(hit_sound_sword_flow, hit_sound_sword_flow_volume_db)
	_hit_audio_arrow_flow    = _make_sfx_player(hit_sound_arrow_flow, hit_sound_arrow_flow_volume_db)
	_hit_audio_hammer_flow   = _make_sfx_player(hit_sound_hammer_flow, hit_sound_hammer_flow_volume_db)
	_hit_audio_claw_flow     = _make_sfx_player(hit_sound_claw_flow, hit_sound_claw_flow_volume_db)
	_hit_audio_fireball_flow = _make_sfx_player(hit_sound_fireball_flow, hit_sound_fireball_flow_volume_db)

	var mat := ShaderMaterial.new()
	mat.shader = load(_HIT_FLASH_SHADER)
	animated_sprite.material = mat
	_hit_flash_material = mat


func _physics_process(_delta: float) -> void:
	if is_dead:
		return
	match _guard_state:
		GuardState.WALK:
			_handle_walk()
		GuardState.GUARD:
			_handle_guard()
	move_and_slide()
	_check_footstep_sound()

# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_walk() -> void:
	if destination == null:
		_guard_state = GuardState.GUARD
		velocity = Vector2.ZERO
		animated_sprite.play(&"idle")
		return
	var to_dest: Vector2 = destination.global_position - global_position
	if to_dest.length() < 4.0:
		global_position = destination.global_position
		velocity = Vector2.ZERO
		_guard_state = GuardState.GUARD
		animated_sprite.play(&"idle")
		return
	velocity = to_dest.normalized() * move_speed
	_set_facing(1.0 if to_dest.x >= 0.0 else -1.0)
	if animated_sprite.animation != &"running":
		animated_sprite.play(&"running")


func _handle_guard() -> void:
	if shoot_state == ShootState.ATTACKING:
		velocity = Vector2.ZERO
		return

	var enemies := _get_enemies_in_range()
	if enemies.size() == 0:
		target = null
		velocity = Vector2.ZERO
		if animated_sprite.animation != &"idle":
			animated_sprite.play(&"idle")
		return

	target = _find_closest(enemies)
	velocity = Vector2.ZERO
	_begin_shoot()


func _get_enemies_in_range() -> Array:
	if detection_zone == null:
		return []
	var results: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body is EnemyBase and not body.is_dead:
			results.append(body)
	return results


func _find_closest(enemies: Array) -> Node2D:
	var closest: Node2D = enemies[0]
	var best_dist: float = global_position.distance_squared_to(closest.global_position)
	for i in range(1, enemies.size()):
		var d: float = global_position.distance_squared_to(enemies[i].global_position)
		if d < best_dist:
			best_dist = d
			closest = enemies[i]
	return closest


func _begin_shoot() -> void:
	shoot_state = ShootState.ATTACKING
	_arrow_fired = false
	animated_sprite.stop()
	animated_sprite.play(&"shoot")
	if target != null:
		_set_facing(1.0 if target.global_position.x > global_position.x else -1.0)


func _stop_attack() -> void:
	shoot_state = ShootState.NONE
	animated_sprite.stop()
	animated_sprite.play(&"idle")

# ── Facing ─────────────────────────────────────────────────────────────────────

func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	if facing_pivot != null:
		var s := facing_pivot.scale
		s.x = absf(s.x) * facing
		facing_pivot.scale = s
	else:
		animated_sprite.flip_h = facing < 0.0

# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	if shoot_state == ShootState.ATTACKING:
		if animated_sprite.frame in shoot_sound_frames:
			_play_sfx(_shoot_audio)
		if animated_sprite.frame == SHOOT_FRAME and not _arrow_fired:
			_arrow_fired = true
			_fire_arrow()
	_check_footstep_sound()


func _on_animation_finished() -> void:
	if shoot_state == ShootState.ATTACKING:
		if _get_enemies_in_range().size() > 0:
			_begin_shoot()
		else:
			_stop_attack()


func _check_footstep_sound() -> void:
	if walk_sound_footstep_frames.is_empty():
		return
	if animated_sprite.animation == &"running":
		var f: int = animated_sprite.frame
		if f != _prev_footstep_frame and f in walk_sound_footstep_frames:
			_prev_footstep_frame = f
			_play_sfx(_walk_audio)
	else:
		_prev_footstep_frame = -1

# ── Arrow firing ───────────────────────────────────────────────────────────────

func _fire_arrow() -> void:
	if arrow_scene == null:
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return

	var shoot_dir: Vector2
	if target != null and is_instance_valid(target):
		shoot_dir = (target.global_position - global_position).normalized()
	else:
		shoot_dir = Vector2(facing, 0.0)

	if arrow_angle != 0.0:
		shoot_dir = shoot_dir.rotated(deg_to_rad(arrow_angle * -facing))

	# collision_mask = 2 so the arrow only hits real enemies, never the player/castle.
	arrow.collision_mask = 2
	arrow.configure(global_position, shoot_dir, arrow_speed, arrow_damage, 0.0)
	arrow.lifetime = arrow_lifetime
	if poison_enabled:
		# Non-pierce arrows free themselves on their first hit, so whatever
		# they hit is safely assumed to be `target` — the one we aimed at.
		var poison_target := target
		arrow.enemy_hit.connect(func() -> void:
			HutDot.apply(self, _active_dots, poison_target, poison_damage_per_tick, poison_tick_interval, poison_duration, WeaponType.WeaponType.ARROW)
		)
	get_tree().current_scene.call_deferred("add_child", arrow)

# ── Health / damage ────────────────────────────────────────────────────────────

## Called by hut_priest.gd. Restores health, clamped to max_health.
func heal(amount: float) -> void:
	if is_dead:
		return
	health = minf(max_health, health + amount)
	health_changed.emit(health, max_health)


func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	DamageNumber.spawn_at(get_tree().current_scene, global_position, amount)
	_flash_white()
	if hit_particles != null:
		hit_particles.restart()
	_play_weapon_hit_sound(weapon_type, flow_success)
	if health == 0.0:
		_die()


func apply_knockback(_source_position: Vector2, _force: float) -> void:
	pass  # guard units hold position


func _die() -> void:
	died.emit()
	is_dead = true
	shoot_state = ShootState.NONE
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	var scene_root: Node = owner if owner != null else self
	get_tree().create_timer(2.0).timeout.connect(scene_root.queue_free, CONNECT_ONE_SHOT)


func _on_health_changed(new_health: float, max_hp: float) -> void:
	if health_bar != null and health_bar.has_method("set_health"):
		health_bar.set_health(new_health, max_hp)

# ── SFX / hit-flash helpers ────────────────────────────────────────────────────

func _make_sfx_player(stream: AudioStream, volume_db: float) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.stream = stream
	p.volume_db = volume_db
	p.bus = &"SFX"
	add_child(p)
	return p


func _play_sfx(player: AudioStreamPlayer2D) -> void:
	if player != null and player.stream != null:
		player.play()


func _flash_white() -> void:
	if _hit_flash_material == null:
		return
	if _hit_flash_tween != null and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	_hit_flash_material.set_shader_parameter(&"flash_amount", 1.0)
	_hit_flash_tween = create_tween()
	_hit_flash_tween.tween_method(
		func(v: float) -> void: _hit_flash_material.set_shader_parameter(&"flash_amount", v),
		1.0, 0.0, _HIT_FLASH_DURATION)


func _play_weapon_hit_sound(weapon_type: WeaponType.WeaponType, flow_success: bool = false) -> void:
	match weapon_type:
		WeaponType.WeaponType.SWORD:
			_play_sfx(_hit_audio_sword_flow if flow_success and _hit_audio_sword_flow != null and _hit_audio_sword_flow.stream != null else _hit_audio_sword)
		WeaponType.WeaponType.ARROW:
			_play_sfx(_hit_audio_arrow_flow if flow_success and _hit_audio_arrow_flow != null and _hit_audio_arrow_flow.stream != null else _hit_audio_arrow)
		WeaponType.WeaponType.HAMMER:
			_play_sfx(_hit_audio_hammer_flow if flow_success and _hit_audio_hammer_flow != null and _hit_audio_hammer_flow.stream != null else _hit_audio_hammer)
		WeaponType.WeaponType.CLAW:
			_play_sfx(_hit_audio_claw_flow if flow_success and _hit_audio_claw_flow != null and _hit_audio_claw_flow.stream != null else _hit_audio_claw)
		WeaponType.WeaponType.FIREBALL:
			_play_sfx(_hit_audio_fireball_flow if flow_success and _hit_audio_fireball_flow != null and _hit_audio_fireball_flow.stream != null else _hit_audio_fireball)

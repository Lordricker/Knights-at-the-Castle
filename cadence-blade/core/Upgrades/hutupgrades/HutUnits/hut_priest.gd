extends CharacterBody2D

# hut_priest.gd — Friendly support unit spawned by UnitHut.
#
# Walks from its spawn position to `destination` (a Marker2D assigned at
# runtime by UnitHut._spawn_unit()), then holds that position.
#
# Two mutually exclusive modes, chosen per-level via the exported toggles:
#   - Heal mode (lvl1-4, freeze_enabled = false): every heal_tick_interval
#     seconds, heals the `heal_targets` lowest-HP allies (other hut units)
#     inside `detection_zone` for `heal_amount` each.
#   - Freeze mode (lvl5, freeze_enabled = true): whenever a real enemy enters
#     `detection_zone`, it's frozen (EnemyBase.is_frozen) for freeze_seconds.
#     No healing happens in this mode.
#
# SCENE STRUCTURE (mirrors hut_warrior.gd/hut_archer.gd):
#   CharacterBody2D  (this script)
#   ├── CollisionShape2D
#   ├── Pivot
#   │   ├── AnimatedSprite2D  (animations: "idle", "running")
#   │   ├── DetectionZone (Area2D, CircleShape2D — heal/freeze radius)
#   │   └── HPBar
#   └── hitparticles (CPUParticles2D)

const DamageNumber = preload("res://FX/damage_number.gd")

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Stats")
@export var max_health: float = 80.0
@export var move_speed: float = 80.0

@export_group("Setup")
@export var facing_pivot: Node2D
@export var health_bar: Node2D
@export var detection_zone: Area2D
@export var hit_particles: CPUParticles2D
## Assigned at runtime by UnitHut._spawn_unit(). Not set in the editor.
var destination: Marker2D = null

@export_group("Healing")
## How many of the lowest-HP allies in range get healed each tick.
@export var heal_targets: int = 1
@export var heal_amount: float = 10.0
@export var heal_tick_interval: float = 1.5

## Lvl5 branch: replaces healing with a freeze pulse on enemies that enter range.
@export_group("Freeze")
@export var freeze_enabled: bool = false
@export var freeze_seconds: float = 3.0

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

var _guard_state: GuardState = GuardState.WALK
var health: float = 0.0
var is_dead: bool = false
var facing: float = 1.0
var _prev_footstep_frame: int = -1

signal health_changed(new_health: float, max_hp: float)
## Emitted once, right when death starts. UnitHut listens for this to drive respawn.
signal died

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
@onready var _heal_timer: Timer = Timer.new()


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	health = max_health
	health_changed.connect(_on_health_changed)
	health_changed.emit(health, max_health)
	add_to_group(&"entities")
	add_to_group(&"Kill")  # so real enemies can target this unit back
	add_to_group(&"hut_units")  # so it (and other priests) can be healed too

	if detection_zone != null:
		detection_zone.monitoring = true
		detection_zone.body_entered.connect(_on_detection_body_entered)

	animated_sprite.play(&"running")

	_heal_timer.wait_time = heal_tick_interval
	_heal_timer.autostart = true
	_heal_timer.timeout.connect(_on_heal_tick)
	add_child(_heal_timer)

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
			velocity = Vector2.ZERO
			if animated_sprite.animation != &"idle":
				animated_sprite.play(&"idle")
	move_and_slide()
	_check_footstep_sound()

# ── Movement ─────────────────────────────────────────────────────────────────

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

# ── Healing ────────────────────────────────────────────────────────────────────

func _on_heal_tick() -> void:
	if freeze_enabled or _guard_state != GuardState.GUARD or detection_zone == null:
		return
	var candidates: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body == self or not body.is_in_group(&"hut_units"):
			continue
		if body.get("is_dead") == true or not body.has_method(&"heal"):
			continue
		if float(body.get("health")) >= float(body.get("max_health")):
			continue
		candidates.append(body)
	candidates.sort_custom(func(a, b) -> bool: return float(a.get("health")) < float(b.get("health")))
	for i in mini(heal_targets, candidates.size()):
		candidates[i].heal(heal_amount)

# ── Freeze ─────────────────────────────────────────────────────────────────────

func _on_detection_body_entered(body: Node2D) -> void:
	if not freeze_enabled or not (body is EnemyBase) or body.is_dead:
		return
	body.is_frozen = true
	var timer := get_tree().create_timer(freeze_seconds)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.is_frozen = false
	)

# ── Health / damage ────────────────────────────────────────────────────────────

## Called by another priest. Restores health, clamped to max_health.
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

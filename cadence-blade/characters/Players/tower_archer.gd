extends CharacterBody2D

const DamageNumber = preload("res://FX/damage_number.gd")

# tower_archer.gd — Stationary allied archer placed on a tower.
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script, collision_layer = 1 so enemy arrows hit it)
#   ├── CollisionShape2D
#   └── Pivot (Node2D, facing_pivot)
#       ├── AnimatedSprite2D  (animations: "idle", "shoot")
#       ├── DetectionZone (Area2D — detects enemies that enter range)
#       │   └── CollisionShape2D
#       └── HPBar
#
# Assign arrow.tscn to arrow_scene in the Inspector.
# Set `facing` to 1.0 (right tower) or -1.0 (left tower) in the Inspector.
# The parent node starts with process_mode = DISABLED and is hidden.
# The upgrade activates it via CastleInside._activate_tower_archer().
# On death the archer deactivates itself (process_mode = DISABLED + hide).

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

@export_group("Stats")
## Max HP of the tower archer.
@export var max_health: float = 100.0
## How fast knockback decelerates (kept for EnemyBase arrow compatibility).
@export var knockback_friction: float = 600.0

@export_group("Setup")
## Which direction the archer faces. 1.0 = right tower, -1.0 = left tower.
@export_range(-1.0, 1.0, 2.0) var facing: float = 1.0
## Optional Node2D pivot whose X scale is flipped to face the correct direction.
@export var facing_pivot: Node2D
## Area2D used to detect enemies in range.
@export var detection_zone: Area2D
## HPBar node (assign vertical_health_bar.tscn instance in Inspector).
@export var health_bar: Node2D

@export_group("Hit Sounds")
## Sound played when hit by a sword or spear.
@export var hit_sound_sword: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_sword_volume_db: float = 0.0
## Sound played when hit by an arrow.
@export var hit_sound_arrow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_arrow_volume_db: float = 0.0
## Sound played when hit by a hammer.
@export var hit_sound_hammer: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_hammer_volume_db: float = 0.0
## Sound played when hit by claws or a natural weapon.
@export var hit_sound_claw: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_claw_volume_db: float = 0.0
## Sound played when hit by a fireball.
@export var hit_sound_fireball: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_fireball_volume_db: float = 0.0
## Flow-success variant: played instead of hit_sound_sword when the hit was in the green window.
@export var hit_sound_sword_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_sword_flow_volume_db: float = 0.0
## Flow-success variant for arrow hits.
@export var hit_sound_arrow_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_arrow_flow_volume_db: float = 0.0
## Flow-success variant for hammer hits.
@export var hit_sound_hammer_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_hammer_flow_volume_db: float = 0.0
## Flow-success variant for claw hits.
@export var hit_sound_claw_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_claw_flow_volume_db: float = 0.0
## Flow-success variant for fireball hits.
@export var hit_sound_fireball_flow: AudioStream
@export_range(-40.0, 6.0, 0.1) var hit_sound_fireball_flow_volume_db: float = 0.0
@export_group("")

# ── Runtime state ─────────────────────────────────────────────────────────────

var health: float = 0.0
var is_dead: bool = false

enum ShootState { NONE, ATTACKING }
var shoot_state: ShootState = ShootState.NONE
var _arrow_fired: bool = false
var _target: Node2D = null
var _health_bar_api: Node = null
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

signal health_changed(new_health: float, max_hp: float)

# ── Hit-flash ─────────────────────────────────────────────────────────────────
var _hit_flash_material: ShaderMaterial = null
var _hit_flash_tween: Tween = null
const _HIT_FLASH_SHADER := "res://assets/shaders/hit_flash.gdshader"
const _HIT_FLASH_DURATION := 0.15

@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D


func _ready() -> void:
	health = max_health
	# Auto-detect facing from the parent wrapper's X scale.
	# Setting scale.x = -1 on the root TowerArcher Node2D in the level editor
	# is all that's needed to create the mirrored left-side archer.
	# The parent flip already mirrors the sprite visually, so we only derive
	# `facing` here for the arrow angle offset — we do NOT flip facing_pivot.
	var parent := get_parent()
	if parent != null and parent.scale.x < 0.0:
		facing = -1.0
	else:
		facing = 1.0
	if detection_zone != null:
		detection_zone.monitoring = true
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	health_changed.connect(_on_health_changed)
	health_changed.emit(health, max_health)
	# Targetable by enemy archers (same layer as players).
	add_to_group(&"entities")
	add_to_group(&"Kill")
	animated_sprite.play(&"idle")
	_hit_audio_sword = _make_sfx_player(hit_sound_sword, hit_sound_sword_volume_db)
	_hit_audio_arrow = _make_sfx_player(hit_sound_arrow, hit_sound_arrow_volume_db)
	_hit_audio_hammer = _make_sfx_player(hit_sound_hammer, hit_sound_hammer_volume_db)
	_hit_audio_claw = _make_sfx_player(hit_sound_claw, hit_sound_claw_volume_db)
	_hit_audio_fireball = _make_sfx_player(hit_sound_fireball, hit_sound_fireball_volume_db)
	_hit_audio_sword_flow = _make_sfx_player(hit_sound_sword_flow, hit_sound_sword_flow_volume_db)
	_hit_audio_arrow_flow = _make_sfx_player(hit_sound_arrow_flow, hit_sound_arrow_flow_volume_db)
	_hit_audio_hammer_flow = _make_sfx_player(hit_sound_hammer_flow, hit_sound_hammer_flow_volume_db)
	_hit_audio_claw_flow = _make_sfx_player(hit_sound_claw_flow, hit_sound_claw_flow_volume_db)
	_hit_audio_fireball_flow = _make_sfx_player(hit_sound_fireball_flow, hit_sound_fireball_flow_volume_db)
	var mat := ShaderMaterial.new()
	mat.shader = load(_HIT_FLASH_SHADER)
	animated_sprite.material = mat
	_hit_flash_material = mat


func _physics_process(_delta: float) -> void:
	if is_dead or shoot_state == ShootState.ATTACKING:
		return

	var enemies := _get_enemies_in_range()
	if enemies.size() == 0:
		_target = null
		return

	_target = _find_closest(enemies)
	_begin_shoot()


# ── Health ─────────────────────────────────────────────────────────────────────

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


func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	DamageNumber.spawn_at(get_tree().current_scene, global_position, amount)
	_flash_white()
	_play_weapon_hit_sound(weapon_type, flow_success)
	if health == 0.0:
		_die()


## Stub so enemy arrows that call apply_knockback don't error.
func apply_knockback(_source: Vector2, _force: float) -> void:
	pass


func _die() -> void:
	is_dead = true
	shoot_state = ShootState.NONE
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	# Deactivate the parent wrapper node so the upgrade can be purchased again.
	var parent := get_parent()
	if parent != null:
		parent.process_mode = Node.PROCESS_MODE_DISABLED
		parent.hide()


func _on_health_changed(new_health: float, max_hp: float) -> void:
	if _health_bar_api != null and _health_bar_api.has_method("set_health"):
		_health_bar_api.set_health(new_health, max_hp)


# ── Shoot logic ────────────────────────────────────────────────────────────────

func _begin_shoot() -> void:
	shoot_state = ShootState.ATTACKING
	_arrow_fired = false
	animated_sprite.stop()
	animated_sprite.play(&"shoot")


func _stop_attack() -> void:
	shoot_state = ShootState.NONE
	animated_sprite.stop()
	animated_sprite.play(&"idle")


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_animation_finished() -> void:
	if shoot_state == ShootState.ATTACKING:
		var enemies := _get_enemies_in_range()
		if enemies.size() > 0:
			_target = _find_closest(enemies)
			_begin_shoot()
		else:
			_stop_attack()


func _on_frame_changed() -> void:
	if shoot_state == ShootState.ATTACKING \
			and animated_sprite.frame == SHOOT_FRAME \
			and not _arrow_fired:
		_arrow_fired = true
		_fire_arrow()


# ── Arrow firing ───────────────────────────────────────────────────────────────

func _fire_arrow() -> void:
	if arrow_scene == null:
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return

	var shoot_dir: Vector2
	if _target != null and is_instance_valid(_target):
		shoot_dir = (_target.global_position - global_position).normalized()
	else:
		shoot_dir = Vector2(facing, 0.0)

	if arrow_angle != 0.0:
		shoot_dir = shoot_dir.rotated(deg_to_rad(arrow_angle * -facing))

	# collision_mask = 2 so the arrow only hits enemy bodies (layer 2).
	arrow.collision_mask = 2
	arrow.configure(global_position, shoot_dir, arrow_speed, arrow_damage, 0.0)
	arrow.lifetime = arrow_lifetime
	get_tree().current_scene.call_deferred("add_child", arrow)


# ── Helpers ────────────────────────────────────────────────────────────────────

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


func _resolve_bar_api(root: Node, required_method: StringName) -> Node:
	if root == null:
		return null
	if root.has_method(required_method):
		return root
	for child in root.get_children():
		var found: Node = _resolve_bar_api(child, required_method)
		if found != null:
			return found
	return null

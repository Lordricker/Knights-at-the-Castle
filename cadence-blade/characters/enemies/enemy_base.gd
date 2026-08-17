class_name EnemyBase
extends CharacterBody2D

const DamageNumber = preload("res://FX/damage_number.gd")

# EnemyBase - shared base class for all enemy types.
# Follows the same walk_path group as the player.

@export var max_health: float = 100.0
@export var move_speed: float = 80.0
# Set by subclasses in _ready() — not exported to avoid inspector value overriding the subclass assignment.
var attack_damage: float = 10.0

@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D

# ── Facing / bars ─────────────────────────────────────────────────────────────
## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

## Optional: assign a child Node2D whose X scale is flipped to mirror all children.
@export var facing_pivot: Node2D
## Drag the HealthBar Node2D (vertical_health_bar.gd) here in the Inspector.
@export var health_bar: Node2D
## Area2D used to detect attackable targets. Bodies in the "Kill" group will be targeted.
@export var detection_zone: Area2D
## Drag a CPUParticles2D here to play it whenever the enemy takes damage.
@export var hit_particles: CPUParticles2D
## Drag HurtBox Area2D nodes here. Each box auto-applies its damage_multiplier when hit.
## e.g. body box at 1.0×, head box at 2.0×. Boxes self-initialize via their own _ready().
@export var hurtboxes: Array[Area2D] = []

var _health_bar_api: Node = null
var _health_bar_right_pos: Vector2 = Vector2.ZERO

# ── Movement / physics ─────────────────────────────────────────────────────────
var health: float = max_health
var is_dead: bool = false
var target: Node2D = null
## Set by EnemySpawner. 0=none, 1=Coin, 2=Coin2, 3=Coin4.
var coin_tier: int = 1
## Set by EnemySpawner. 0=same as coin_tier, otherwise overrides on flow kill.
var flow_kill_coin_tier: int = 0
var walk_path: Path2D = null
var knockback_velocity: Vector2 = Vector2.ZERO
## When true, movement, AI, and knockback are suspended (Freeze Enemies upgrade).
var is_frozen: bool = false

## How fast knockback decelerates in pixels/sec.
@export var knockback_friction: float = 600.0

@export_group("SFX Distance")
## Beyond this many pixels from the audio listener (camera / local player) volume falls to zero.
@export_range(50.0, 3000.0, 10.0) var sfx_max_distance: float = 700.0
## Rolloff exponent: 1 = linear, 2 = quadratic (drops faster). Higher = sharper fade.
@export_range(0.1, 4.0, 0.1) var sfx_attenuation: float = 1.0
@export_group("")

@export_group("Walk Sound")
## AudioStream to play on each footstep while moving.
@export var walk_sound: AudioStream
## Per-footstep volume in dB (0 = full volume, negative = quieter).
@export_range(-40.0, 6.0, 0.1) var walk_sound_volume_db: float = 0.0
## Running animation frame indices that trigger a footstep sound.
@export var walk_sound_footstep_frames: Array[int] = []
@export_group("")

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

@export_group("Path Oscillation")
## If true the enemy bobs up and down relative to the path instead of locking to it.
@export var oscillate: bool = false
## How many pixels above and below the path centre the enemy travels.
@export var oscillate_amplitude: float = 20.0
## Full cycles per second.
@export var oscillate_speed: float = 0.5

var _oscillate_time: float = 0.0

var _walk_audio: AudioStreamPlayer2D = null
var _prev_footstep_frame: int = -1
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

## Network position target received from host. Only used on joiner.
var _net_target_pos: Vector2 = Vector2.ZERO
## True once the first position sync has arrived -- prevents lerping from origin.
var _net_synced: bool = false

signal died(enemy: EnemyBase)
signal health_changed(new_health: float, max_hp: float)

# ── Hit-flash ─────────────────────────────────────────────────────────────────
var _hit_flash_material: ShaderMaterial = null
var _hit_flash_tween: Tween = null
const _HIT_FLASH_SHADER := "res://assets/shaders/hit_flash.gdshader"
const _HIT_FLASH_DURATION := 0.15


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	scale.x = 1.0  # never flip the CharacterBody2D root
	health = max_health
	_capture_right_facing_transforms()
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	health_changed.connect(_on_health_changed)
	_on_health_changed(health, max_health)
	_apply_facing()
	add_to_group(&"entities")
	_walk_audio = _make_sfx_player(walk_sound, walk_sound_volume_db)
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
	_setup_hit_flash()


func _setup_hit_flash() -> void:
	if animated_sprite == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = load(_HIT_FLASH_SHADER)
	animated_sprite.material = mat
	_hit_flash_material = mat


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


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if is_frozen:
		velocity = Vector2.ZERO
		knockback_velocity = Vector2.ZERO
		return

	# Joiner: no local AI -- interpolate toward the host-authoritative position.
	if GameManager.session_id != "" and not GameManager.is_host:
		if _net_synced:
			var dist := global_position.distance_to(_net_target_pos)
			if dist > 300.0:
				global_position = _net_target_pos  # teleport if desynced
			else:
				global_position = global_position.lerp(_net_target_pos, minf(10.0 * delta, 1.0))
		return

	# Lazy lookup - retry until the level's Path2D is in the tree.
	if walk_path == null:
		var paths: Array[Node] = get_tree().get_nodes_in_group("walk_path")
		if paths.size() > 0:
			walk_path = paths[0] as Path2D
	if oscillate and not _is_attacking():
		_oscillate_time += delta
	_handle_ai(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	if walk_path != null:
		_constrain_to_path()
	_check_footstep_sound()


## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Creates and adds an AudioStreamPlayer2D child routed to the SFX bus.
func _make_sfx_player(stream: AudioStream, volume_db: float) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.stream = stream
	p.volume_db = volume_db
	p.bus = &"SFX"
	p.max_distance = sfx_max_distance
	p.attenuation = sfx_attenuation
	add_child(p)
	return p


## Plays the given SFX player only if a stream is assigned.
func _play_sfx(player: AudioStreamPlayer2D) -> void:
	if player != null and player.stream != null:
		player.play()


## Called each physics frame to trigger footstep sounds at configured running frames.
func _check_footstep_sound() -> void:
	if animated_sprite == null or walk_sound_footstep_frames.is_empty():
		return
	if animated_sprite.animation == &"running":
		var f: int = animated_sprite.frame
		if f != _prev_footstep_frame and f in walk_sound_footstep_frames:
			_prev_footstep_frame = f
			_play_sfx(_walk_audio)
	else:
		_prev_footstep_frame = -1


## Override in subclasses to implement movement and attack AI.
func _handle_ai(_delta: float) -> void:
	pass


## Override to return true while attacking so oscillation pauses.
func _is_attacking() -> bool:
	return false


## Returns all nodes overlapping detection_zone that belong to the "Kill" group.
## Checks both physics bodies (players/enemies) and areas (e.g. castle hitbox).
func _get_targets_in_range() -> Array:
	if detection_zone == null:
		return []
	var results: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body.is_in_group(&"Kill"):
			results.append(body)
	for area in detection_zone.get_overlapping_areas():
		if area.is_in_group(&"Kill"):
			results.append(area)
	return results


func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if is_dead:
		return
	# Enemy physics is disabled on joiner — this should not fire there, but guard anyway.
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	DamageNumber.spawn_at(get_tree().current_scene, global_position, amount)
	_flash_white()
	if hit_particles != null:
		hit_particles.restart()
	_play_weapon_hit_sound(weapon_type, flow_success)
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "hit_fx", "p": str(get_path()), "wt": int(weapon_type), "fs": 1 if flow_success else 0, "dmg": amount, "dx": global_position.x, "dy": global_position.y})
	if health == 0.0:
		die(flow_success)


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


func die(flow_success: bool = false) -> void:
	if is_dead:
		return
	is_dead = true
	set_collision_layer(0)
	set_collision_mask(0)
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	died.emit(self)
	# Signal the level so it can spawn the death poof and the correct coin.
	# Only run on host (or offline) -- joiner must not duplicate coins.
	# Deferred so this never runs mid-physics-flush (e.g. triggered by a hitbox signal).
	if (GameManager.session_id == "" or GameManager.is_host) and \
			get_tree().current_scene.has_method("on_entity_died"):
		var tier: int = coin_tier
		if flow_success and flow_kill_coin_tier > 0:
			tier = flow_kill_coin_tier
		get_tree().current_scene.call_deferred("on_entity_died", global_position, true, tier)
	# Clean up after the death poof finishes (~2 seconds).
	# Use owner (the scene root Node2D) so the entire instance is freed,
	# not just this CharacterBody2D child node.
	var scene_root: Node = owner if owner != null else self
	get_tree().create_timer(2.5).timeout.connect(scene_root.queue_free, CONNECT_ONE_SHOT)


func _on_health_changed(new_health: float, max_hp: float) -> void:
	if _health_bar_api != null and _health_bar_api.has_method("set_health"):
		_health_bar_api.set_health(new_health, max_hp)


## Recursively search descendants of root for a node that has the required_method.
func _resolve_bar_api(root: Node, required_method: StringName) -> Node:
	if root == null:
		return null
	if root.has_method(required_method):
		return root
	for child in root.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		var found: Node = _resolve_bar_api(child_node, required_method)
		if found != null:
			return found
	return null


## Record right-facing local positions once in _ready() before any flip.
## Override in subclasses to also capture subclass-specific nodes (call super() first).
func _capture_right_facing_transforms() -> void:
	if health_bar != null:
		_health_bar_right_pos = health_bar.position


## Apply the current facing direction to the sprite and positioned child nodes.
## Override in subclasses to mirror additional nodes (call super() first).
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	if facing_pivot != null:
		animated_sprite.flip_h = false
		var s := facing_pivot.scale
		s.x = absf(s.x) * facing
		facing_pivot.scale = s
		return
	animated_sprite.flip_h = facing < 0.0
	if health_bar != null:
		health_bar.position = Vector2(_health_bar_right_pos.x * facing, _health_bar_right_pos.y)


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()


## Constrains Y to the walk path, with optional oscillation.
func _constrain_to_path() -> void:
	var path_y: float = _sample_path_y(global_position.x)
	if oscillate:
		path_y += sin(_oscillate_time * oscillate_speed * TAU) * oscillate_amplitude
	global_position.y = path_y


func _sample_path_y(world_x: float) -> float:
	var curve: Curve2D = walk_path.curve
	var baked: PackedVector2Array = curve.get_baked_points()
	if baked.size() < 2:
		return global_position.y
	# Use the full transform (not just position) — several walk paths are
	# mirrored via scale = (-1, 1) to reuse one curve for both sides of the
	# map, and a position-only offset silently reverses/misplaces those.
	var xform: Transform2D = walk_path.global_transform
	var first: Vector2 = xform * baked[0]
	var last: Vector2 = xform * baked[baked.size() - 1]
	world_x = clampf(world_x, minf(first.x, last.x), maxf(first.x, last.x))
	for i in range(baked.size() - 1):
		var a: Vector2 = xform * baked[i]
		var b: Vector2 = xform * baked[i + 1]
		if (world_x >= a.x and world_x <= b.x) or (world_x <= a.x and world_x >= b.x):
			var t: float = (world_x - a.x) / (b.x - a.x) if b.x != a.x else 0.0
			return lerp(a.y, b.y, t)
	return global_position.y


# ── Network position (set by EnemySpawner.apply_enemy_state on joiner) ────────
## _net_target_pos and _net_synced are set externally each state snapshot tick.

extends CharacterBody2D

# hut_priest.gd — Friendly support unit spawned by UnitHut.
#
# Walks from its spawn position to `destination` (a Marker2D assigned at
# runtime by UnitHut._spawn_unit()), then holds that position.
#
# Two mutually exclusive modes, chosen per-level via the exported toggles:
#   - Heal mode (lvl1-4, freeze_enabled = false): every heal_tick_interval
#     seconds, heals for `heal_amount` each the `heal_targets` allies inside
#     `detection_zone` that have lost the largest percentage of their max HP.
#     Allies means both other hut units and players; anyone at full health is
#     skipped.
#   - Freeze mode (lvl5, freeze_enabled = true): whenever a real enemy enters
#     `detection_zone`, it's frozen (EnemyBase.is_frozen) for freeze_seconds.
#     No healing happens in this mode.
# Both modes play the "shoot" animation as the cast tell.
#
# Every priest also fetches coins: while holding its post it walks to the
# nearest uncollected coin in range, banks it into the shared player pool, then
# returns to its post.
#
# Allies and coins are found by radius against the "hut_units" / "players" /
# "coins" groups rather than by DetectionZone overlap — the zone only masks the
# enemy physics layer, so overlap queries never see them.
#
# SCENE STRUCTURE (mirrors hut_warrior.gd/hut_archer.gd):
#   CharacterBody2D  (this script)
#   ├── CollisionShape2D
#   ├── Pivot
#   │   ├── AnimatedSprite2D  (animations: "idle", "running", "shoot")
#   │   ├── DetectionZone (Area2D, CircleShape2D — heal/freeze/fetch radius)
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

@export_group("Coin Fetching")
## When true, this priest leaves its post to pick up coins that drop in range.
@export var fetch_coins_enabled: bool = true
## How close the priest must get before the coin is banked.
@export var coin_pickup_range: float = 10.0

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

## How far (px) a freshly-spawned unit walks straight down out of its hut
## before switching to navmesh-following. Huts sit outside walk_area (the
## polygon isn't carved out around each one), so a unit starts off-mesh —
## this gets it clear of the hut without needing nav queries against a
## point that isn't inside the walkable area yet.
const WALK_OUT_DISTANCE: float = 120.0

## Within this distance of the target, steer straight at it instead of through
## the navmesh. The last few px of a nav path can oscillate around a point that
## sits just off the baked mesh — that never satisfies the arrival check, so the
## priest walks in place and (see below) flip-flops its sprite.
const NAV_ARRIVE_RADIUS: float = 32.0
## Movement dirs whose horizontal component (post-normalize) is below this don't
## update facing, so a priest jittering in place near its post doesn't waffle.
const FACING_DEADZONE: float = 0.15

# ── Runtime state ─────────────────────────────────────────────────────────────

enum GuardState { WALK_OUT, WALK, GUARD, FETCH }

var _guard_state: GuardState = GuardState.WALK_OUT
var _walk_out_start: Vector2 = Vector2.ZERO
## Polygon2D from the "walk_area" group — same shared navmesh source the
## sheepdog uses (see EnemyNavigation).
var walk_area: Polygon2D = null
var nav_region: NavigationRegion2D = null
var health: float = 0.0
var is_dead: bool = false
var facing: float = 1.0
var _prev_footstep_frame: int = -1
## True while the "shoot" cast animation is playing, so the idle/walk animation
## calls don't cut it short.
var _casting: bool = false
## Coin this priest is currently walking to, claimed so other priests pick a
## different one. Cleared on pickup, on give-up, and on death.
var _coin_target: Node2D = null
## DetectionZone circle radius in global units, resolved once in _ready().
var _detect_radius: float = 0.0
## HPBar.tscn's root is a plain Node2D; the set_health() API lives on its
## VerticalHealthBar child, so resolve it once instead of calling the root.
var _health_bar_api: Node = null

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
@onready var nav_agent: NavigationAgent2D = find_child("NavigationAgent2D") as NavigationAgent2D


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	health = max_health
	_walk_out_start = global_position
	health_changed.connect(_on_health_changed)
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	health_changed.emit(health, max_health)
	add_to_group(&"entities")
	add_to_group(&"Kill")  # so real enemies can target this unit back
	add_to_group(&"hut_units")  # so it (and other priests) can be healed too

	if detection_zone != null:
		detection_zone.monitoring = true
		detection_zone.body_entered.connect(_on_detection_body_entered)
	_detect_radius = _resolve_detection_radius()

	animated_sprite.animation_finished.connect(_on_animation_finished)
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
	if walk_area == null:
		walk_area = EnemyNavigation.find_walk_area(get_tree())
	if walk_area != null and nav_region == null:
		nav_region = EnemyNavigation.get_or_create_nav_region(walk_area)
	match _guard_state:
		GuardState.WALK_OUT:
			_handle_walk_out()
		GuardState.WALK:
			_handle_walk()
		GuardState.GUARD:
			_handle_guard()
		GuardState.FETCH:
			_handle_fetch()
	move_and_slide()
	_check_footstep_sound()

# ── Movement ─────────────────────────────────────────────────────────────────

## Straight walk clear of the hut (see WALK_OUT_DISTANCE) until this unit is
## either inside walk_area or has gone far enough — then hand off to navmesh
## steering. Huts aren't carved out of the polygon, so units always spawn off-mesh.
func _handle_walk_out() -> void:
	if (walk_area != null and EnemyNavigation.is_inside(walk_area, global_position)) \
			or global_position.distance_to(_walk_out_start) >= WALK_OUT_DISTANCE:
		_guard_state = GuardState.WALK
		return
	velocity = Vector2.DOWN * move_speed
	if animated_sprite.animation != &"running":
		animated_sprite.play(&"running")


func _handle_walk() -> void:
	if destination == null:
		_enter_guard()
		return
	var to_dest: Vector2 = destination.global_position - global_position
	if to_dest.length() < 4.0:
		global_position = destination.global_position
		_enter_guard()
		return
	_move_toward_nav(destination.global_position)


func _handle_guard() -> void:
	velocity = Vector2.ZERO
	var coin := _find_fetchable_coin()
	if coin != null:
		_claim_coin(coin)
		_guard_state = GuardState.FETCH
		return
	if not _casting and animated_sprite.animation != &"idle":
		animated_sprite.play(&"idle")


func _handle_fetch() -> void:
	if _coin_target == null or not is_instance_valid(_coin_target) \
			or not _coin_target.is_available():
		_abandon_coin()
		return
	var to_coin: Vector2 = _coin_target.global_position - global_position
	if to_coin.length() <= coin_pickup_range:
		_coin_target.try_collect()
		_abandon_coin()
		return
	_move_toward_nav(_coin_target.global_position)


## Heads back to the post. The walk state re-runs the arrival check, so this is
## also correct when the priest is already standing on it.
func _abandon_coin() -> void:
	_release_coin()
	velocity = Vector2.ZERO
	_guard_state = GuardState.WALK


func _enter_guard() -> void:
	velocity = Vector2.ZERO
	_guard_state = GuardState.GUARD
	if not _casting:
		animated_sprite.play(&"idle")


## Steers toward `target_pos` via the navmesh when it's ready (routes around
## the castle and other walk_area boundaries), falling back to a straight
## line only if no walk_area/nav region exists yet.
func _move_toward_nav(target_pos: Vector2) -> void:
	var to_target: Vector2 = target_pos - global_position
	var dir: Vector2
	if nav_agent != null and nav_region != null and to_target.length() > NAV_ARRIVE_RADIUS:
		nav_agent.target_position = target_pos
		dir = (nav_agent.get_next_path_position() - global_position).normalized()
	else:
		dir = to_target.normalized()
	velocity = dir * move_speed
	if absf(dir.x) >= FACING_DEADZONE:
		_set_facing(1.0 if dir.x >= 0.0 else -1.0)
	if animated_sprite.animation != &"running":
		_casting = false  # walking outranks a cast tell
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

# ── Range queries ──────────────────────────────────────────────────────────────

## Reads the DetectionZone's circle radius once. Uses the shape's global scale
## so a scaled Pivot still yields the on-screen radius.
func _resolve_detection_radius() -> float:
	if detection_zone == null:
		return 0.0
	for child in detection_zone.get_children():
		var shape := child as CollisionShape2D
		if shape == null or not (shape.shape is CircleShape2D):
			continue
		return (shape.shape as CircleShape2D).radius * absf(shape.global_scale.x)
	return 0.0


func _in_range(node: Node2D) -> bool:
	return global_position.distance_to(node.global_position) <= _detect_radius

# ── Healing ────────────────────────────────────────────────────────────────────

func _on_heal_tick() -> void:
	if freeze_enabled or _guard_state != GuardState.GUARD:
		return
	var candidates: Array = []
	for group in [&"hut_units", &"players"]:
		for node in get_tree().get_nodes_in_group(group):
			var ally := node as Node2D
			if ally == null or ally == self or ally in candidates:
				continue
			if not _in_range(ally) or ally.get("is_dead") == true:
				continue
			if not ally.has_method(&"heal"):
				continue
			if float(ally.get("health")) >= float(ally.get("max_health")):
				continue
			candidates.append(ally)
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a, b) -> bool:
		return _missing_health_ratio(a) > _missing_health_ratio(b))
	for i in mini(heal_targets, candidates.size()):
		candidates[i].heal(heal_amount)
	_play_cast()


## Fraction of max HP the ally is missing: 0.0 at full health, 1.0 at zero.
## Ranking by this rather than absolute HP keeps the priest from favouring
## low-max-HP allies now that players share the pool — a red knight at 100/200
## is 50% down and outranks a hut archer at 70/80, which is only 12% down.
func _missing_health_ratio(ally: Node2D) -> float:
	var max_hp: float = maxf(float(ally.get("max_health")), 0.001)
	return 1.0 - float(ally.get("health")) / max_hp

# ── Freeze ─────────────────────────────────────────────────────────────────────

func _on_detection_body_entered(body: Node2D) -> void:
	if not freeze_enabled or not (body is EnemyBase) or body.is_dead:
		return
	body.is_frozen = true
	_play_cast()
	var timer := get_tree().create_timer(freeze_seconds)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.is_frozen = false
	)

# ── Cast animation ─────────────────────────────────────────────────────────────

## Plays the "shoot" tell used for both healing and freezing. Ignored while the
## priest is moving, where the running animation should stay on screen.
func _play_cast() -> void:
	if is_dead or _guard_state != GuardState.GUARD:
		return
	_casting = true
	animated_sprite.stop()
	animated_sprite.play(&"shoot")


func _on_animation_finished() -> void:
	if animated_sprite.animation != &"shoot":
		return
	_casting = false
	if _guard_state == GuardState.GUARD:
		animated_sprite.play(&"idle")

# ── Coin fetching ──────────────────────────────────────────────────────────────

## Nearest unclaimed, uncollected coin inside the detection radius, or null.
func _find_fetchable_coin() -> Node2D:
	if not fetch_coins_enabled:
		return null
	# Joiner coins are display-only; the host banks them and syncs the result.
	if GameManager.session_id != "" and not GameManager.is_host:
		return null
	var best: Node2D = null
	var best_dist: float = INF
	for node in get_tree().get_nodes_in_group(&"coins"):
		var coin := node as Node2D
		if coin == null or not coin.has_method(&"try_collect") or not coin.is_available():
			continue
		if _is_claimed_by_other(coin):
			continue
		var d: float = global_position.distance_to(coin.global_position)
		if d <= _detect_radius and d < best_dist:
			best_dist = d
			best = coin
	return best


## True when a different living priest is already walking to this coin, so the
## whole hut doesn't converge on one drop.
func _is_claimed_by_other(coin: Node2D) -> bool:
	var claim: int = int(coin.get_meta(&"fetch_claim", 0))
	if claim == 0 or claim == get_instance_id() or not is_instance_id_valid(claim):
		return false
	var claimant := instance_from_id(claim) as Node
	return claimant != null and claimant.get("is_dead") != true


func _claim_coin(coin: Node2D) -> void:
	_coin_target = coin
	coin.set_meta(&"fetch_claim", get_instance_id())


func _release_coin() -> void:
	if _coin_target != null and is_instance_valid(_coin_target) \
			and int(_coin_target.get_meta(&"fetch_claim", 0)) == get_instance_id():
		_coin_target.remove_meta(&"fetch_claim")
	_coin_target = null

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

# ── Waypoint ───────────────────────────────────────────────────────────────────

## Called by UnitHut when the player relocates this hut's waypoint, so an
## already-spawned unit walks to the new post instead of staying on the old one.
func return_to_post() -> void:
	if is_dead:
		return
	if _guard_state == GuardState.FETCH:
		_release_coin()
	velocity = Vector2.ZERO
	_guard_state = GuardState.WALK


## Places this unit at its post immediately, skipping the walk-out. Used when a
## joiner adopts the host's world state mid-run: on the host these units reached
## their posts long ago, so the joiner must not watch them march out again.
func snap_to_post() -> void:
	if destination == null:
		return
	if _guard_state == GuardState.FETCH:
		_release_coin()
	global_position = destination.global_position
	velocity = Vector2.ZERO
	_guard_state = GuardState.GUARD
	if animated_sprite != null:
		animated_sprite.play(&"idle")


func _die() -> void:
	died.emit()
	is_dead = true
	_release_coin()
	set_physics_process(false)
	if animated_sprite != null:
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	var scene_root: Node = owner if owner != null else self
	get_tree().create_timer(2.0).timeout.connect(scene_root.queue_free, CONNECT_ONE_SHOT)


func _on_health_changed(new_health: float, max_hp: float) -> void:
	if _health_bar_api != null:
		_health_bar_api.set_health(new_health, max_hp)


## Walks `root` depth-first for the node exposing `required_method`, so the
## Inspector can be pointed at either the HPBar scene root or the bar itself.
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

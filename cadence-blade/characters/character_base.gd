class_name CharacterBase
extends CharacterBody2D

const DamageNumber = preload("res://FX/damage_number.gd")
const HealNumber = preload("res://FX/heal_number.gd")

# CharacterBase - shared base class for all playable characters.
# Free 2D movement: WASD moves in X and Y.
# Add a Polygon2D to the level scene in the group "walk_area" to constrain movement.

@export var move_speed: float = 200.0
@export_group("Character Description")
## Custom name shown in the character selection screen description panel.
@export var display_name: String = ""
@export_group("")
## Drag your CollisionShape2D here so the whole box is constrained inside the walk area.
@export var body_box: CollisionShape2D

# The AnimatedSprite2D child node must be named exactly "AnimatedSprite2D".
@onready var animated_sprite: AnimatedSprite2D = find_child("AnimatedSprite2D") as AnimatedSprite2D

# ── Health ─────────────────────────────────────────────────────────────────────
@export var max_health: float = 100.0
var health: float = 0.0
signal health_changed(new_health: float, max_hp: float)

# ── Coins (run currency) ───────────────────────────────────────────────────────
## Current coin balance. Backed by the party-wide shared pool on GameManager so
## every character (host char, joiner char, joiner's host puppet) always reports
## the same number. Modify only through add_coins().
var coins: int:
	get:
		return GameManager.coin_balance
signal coins_changed(new_coins: int)

# ── Stat bonuses (from blacksmith upgrades) ────────────────────────────────────
## Flat damage bonus added on top of the base attack damage each hit.
## Derived from stat_pips.attack — do not set directly; call add_stat_pip("attack").
var attack_bonus: float = 0.0
## Flat speed bonus added on top of move_speed every frame.
## Derived from stat_pips.speed — do not set directly; call add_stat_pip("speed").
var speed_bonus: float = 0.0
## Legacy: run-time seconds subtracted when sampling flow window size curves.
## No longer used for window sizing (flow window now steps with stat_pips.flow),
## kept so any external reference still resolves.
var flow_time_offset: float = 0.0

# ── Stat pips (bounded blacksmith upgrades) ────────────────────────────────────
## Maximum pips per stat category.
const MAX_PIPS: int = 5
## Max-HP added per HP pip.
@export var hp_per_pip: float = 25.0
## attack_bonus added per Attack pip.
@export var attack_per_pip: float = 5.0
## speed_bonus added per Speed pip.
@export var speed_per_pip: float = 20.0
## Pip counts per category. hp/attack/speed start at 0; flow starts full.
## Host-authoritative in multiplayer — joiners receive this via a "stat_pips" packet
## and apply it verbatim through set_stat_pips().
var stat_pips: Dictionary = {"hp": 0, "attack": 0, "speed": 0, "flow": MAX_PIPS}
## Captured base max_health before any HP-pip bonus is applied.
var _base_max_health: float = 0.0
## Emitted whenever stat_pips changes so the HUD pip bar can refresh.
signal stat_pips_changed(stats: Dictionary)

# ── Interaction locks (set by CastleInside) ────────────────────────────────────
## When true, CastleInside is playing the "heal" animation; subclasses pause
## normal animation selection so the heal pose can hold.
var healing_locked: bool = false
## When true, new attack actions are suppressed (player is at the blacksmith).
var attacks_locked: bool = false

# ── Facing / bars ─────────────────────────────────────────────────────────────
## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

## Optional: assign a child Node2D whose X scale is flipped to mirror all children.
@export var facing_pivot: Node2D
## Drag the HealthBar Node2D (vertical_health_bar.gd) here in the Inspector.
@export var health_bar: Node2D
## Drag the FlowBar Node2D (flow_timing_bar.gd) here in the Inspector.
@export var flow_bar: Node2D
## Drag a CPUParticles2D here to play it whenever the character takes damage.
@export var hit_particles: CPUParticles2D
## Drag HurtBox Area2D nodes here. Each box auto-applies its damage_multiplier when hit.
## e.g. body box at 1.0×, head box at 2.0×. Boxes self-initialize via their own _ready().
@export var hurtboxes: Array[Area2D] = []

# ── Flow timing ───────────────────────────────────────────────────────────────
# ── Flow timing (set per-attack by _start_flow callers) ──────────────────────

var _health_bar_api: Node = null
var _health_bar_right_pos: Vector2 = Vector2.ZERO
var _flow_bar_api: Node = null
var _flow_bar_right_pos: Vector2 = Vector2.ZERO
var _flow_active: bool = false
var _flow_input_action: StringName = &""
var _flow_progress: float = 0.0
var _flow_on_resolved: Callable
var _flow_fill_duration: float = 0.45
var _flow_miss_damage_multiplier: float = 0.6
## True once the animation has reached the pause frame — callback may fire immediately.
var _flow_can_resolve: bool = false
## Stores the damage multiplier from an attempt made during windup (-1.0 = none yet).
var _flow_early_mult: float = -1.0
## True if the early windup attempt was a SUCCESS (green window hit). False = MISS.
## Only a SUCCESS fires immediately at the pause frame; a MISS waits for the bar to fill.
var _flow_early_was_success: bool = false

## Linger length (in animation frames) that the white "success" fill stays on
## screen after a SUCCESS resolves. Same value for every attack.
@export var flow_linger_frames: float = 2.0
## True while the white fill is lingering after a SUCCESS (attack already executed).
var _flow_lingering: bool = false
var _flow_linger_remaining: float = 0.0
## True from a SUCCESS resolve until the attack fully ends or is cancelled.
## Marks the current *_FINISH animation as interruptible by the next attack.
var _flow_success_finish: bool = false

# ── Movement / physics ─────────────────────────────────────────────────────────
var walk_area: Polygon2D = null
var is_dead: bool = false
var knockback_velocity: Vector2 = Vector2.ZERO
var _orig_layer: int = 0

## How fast knockback decelerates in pixels/sec.
@export var knockback_friction: float = 800.0

@export_group("SFX Distance")
## Beyond this many pixels from the audio listener (camera / local player) volume falls to zero.
@export_range(50.0, 3000.0, 10.0) var sfx_max_distance: float = 700.0
## Rolloff exponent: 1 = linear, 2 = quadratic (drops faster). Higher = sharper fade.
@export_range(0.1, 4.0, 0.1) var sfx_attenuation: float = 1.0
@export_group("")

@export_group("Walk Sound")
## AudioStream to play on each footstep while running.
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

signal died()

# ── Player slot / input routing ───────────────────────────────────────────────
## 1 = player 1 (default), 2 = player 2.
## player_slot routes _action_* helpers to matching p2_ InputMap actions (local co-op).
## In online mode, use_input_override takes priority and injects input via a dict,
## which is more reliable than Input.action_press in HTML5 exports.
var player_slot: int = 1
## When true, _action_* helpers read from input_override instead of live Input.
var use_input_override: bool = false
## Keys are action names (e.g. "move_left", "action1"). Values: true = held this frame.
var input_override: Dictionary = {}
## Previous frame's snapshot — used to emulate is_action_just_pressed.
var _prev_input_override: Dictionary = {}
var disable_local_attack_input: bool = false
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
## Joiner-only visual lock used when the host is currently driving a non-locomotion animation.
## While this is set, local movement code leaves the sprite animation alone.
var network_animation_override: StringName = &""

# ── Hit-flash ─────────────────────────────────────────────────────────────────
var _hit_flash_material: ShaderMaterial = null
var _hit_flash_tween: Tween = null
const _HIT_FLASH_SHADER := "res://assets/shaders/hit_flash.gdshader"
const _HIT_FLASH_DURATION := 0.15


func _ready() -> void:
	_orig_layer = get_collision_layer()
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	set_collision_mask(0)
	scale.x = 1.0  # never flip the CharacterBody2D root
	if animated_sprite == null:
		push_error(str(name) + ": no AnimatedSprite2D child found. Name it 'AnimatedSprite2D'.")
		return
	_base_max_health = max_health
	health = max_health
	health_changed.connect(_on_health_changed)
	# Mirror shared-pool coin changes onto this character's own signal so the HUD
	# and any per-character listeners keep working without knowing about the pool.
	GameManager.coin_balance_changed.connect(_on_coin_balance_changed)
	add_to_group(&"entities")
	add_to_group(&"Kill")
	add_to_group(&"KillCharacter")
	_capture_right_facing_transforms()
	_health_bar_api = _resolve_bar_api(health_bar, &"set_health")
	_flow_bar_api = _resolve_bar_api(flow_bar, &"start_flow")
	_on_health_changed(health, max_health)
	# Apply any starting pips (also emits stat_pips_changed for a HUD already listening).
	_apply_stat_pips()
	if health_bar != null:
		health_bar.show()
	if flow_bar != null:
		flow_bar.hide()
	_apply_facing()
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


## Advance the override snapshot. Call once per physics frame before _handle_movement.
func tick_input_override() -> void:
	_prev_input_override = input_override.duplicate()


func _is_attack_input_action(action: StringName) -> bool:
	return action == &"action1" or action == &"action2" or action == &"action3"


## True when the mouse cursor is currently over a UI Control (buttons, panels,
## sliders, etc). Input.is_action_just_pressed/is_action_pressed reflect raw
## hardware/action state and are never blocked by Control mouse_filter, so
## clicking a UI element (e.g. the settings button, or anywhere inside the open
## settings panel) would otherwise also register as an attack click. Checked
## live on every poll rather than cached, so there's no signal-timing race
## between a Button's "pressed" event and the same click's action state.
func _is_mouse_over_ui() -> bool:
	var vp := get_viewport()
	return vp != null and vp.gui_get_hovered_control() != null


func _ignore_client_side_gameplay() -> bool:
	return GameManager.session_id != "" and not GameManager.is_host


func has_network_animation_override() -> bool:
	return not network_animation_override.is_empty()


func set_network_animation_override(anim_name: StringName) -> void:
	network_animation_override = anim_name


func clear_network_animation_override() -> void:
	network_animation_override = &""


## Drop-in for Input.is_action_pressed. Dict override wins; then player_slot routing.
func _action_pressed(action: StringName) -> bool:
	if use_input_override:
		return input_override.get(action, false)
	if disable_local_attack_input and _is_attack_input_action(action):
		return false
	if _is_attack_input_action(action) and _is_mouse_over_ui():
		return false
	# p2_ routing is local co-op only; in online sessions each client uses direct input.
	if player_slot == 2 and GameManager.session_id == "":
		return Input.is_action_pressed("p2_" + action)
	return Input.is_action_pressed(action)


## Drop-in for Input.is_action_just_pressed. Dict override uses prev-frame diff.
func _action_just_pressed(action: StringName) -> bool:
	if use_input_override:
		return input_override.get(action, false) and not _prev_input_override.get(action, false)
	if disable_local_attack_input and _is_attack_input_action(action):
		return false
	if _is_attack_input_action(action) and _is_mouse_over_ui():
		return false
	# p2_ routing is local co-op only; in online sessions each client uses direct input.
	if player_slot == 2 and GameManager.session_id == "":
		return Input.is_action_just_pressed("p2_" + action)
	return Input.is_action_just_pressed(action)


## Drop-in for Input.get_axis. Dict override wins; then player_slot routing.
func _get_axis(neg: StringName, pos: StringName) -> float:
	if use_input_override:
		return float(input_override.get(pos, false)) - float(input_override.get(neg, false))
	# p2_ routing is local co-op only; in online sessions each client uses direct input.
	if player_slot == 2 and GameManager.session_id == "":
		return Input.get_axis("p2_" + neg, "p2_" + pos)
	return Input.get_axis(neg, pos)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Lazy lookup - retry until the level's Polygon2D is in the tree.
	if walk_area == null:
		var areas: Array[Node] = get_tree().get_nodes_in_group("walk_area")
		if areas.size() > 0:
			walk_area = areas[0] as Polygon2D
	_handle_movement()
	_update_flow(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
	# Snapshot input AFTER this frame's logic so next frame's just_pressed diff is correct.
	# Must be after move_and_slide so the packet received in _process this frame is used
	# by _handle_movement above, and then captured as "previous" for next frame.
	if use_input_override:
		tick_input_override()
	if walk_area != null:
		_constrain_to_walk_area()
	# Position stays sub-pixel. Pixel snapping happens at render time via
	# rendering/2d/snap/snap_2d_transforms_to_pixel — rounding here would quantise
	# the authoritative position that gets broadcast over the network.
	_check_footstep_sound()

## Push this character away from source_position.
func apply_knockback(source_position: Vector2, force: float) -> void:
	if _ignore_client_side_gameplay():
		return
	var dir := (global_position - source_position).normalized()
	knockback_velocity = dir * force


## Override in subclass to handle input and set velocity.
func _handle_movement() -> void:
	pass


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


## Keeps the character inside the walk_area polygon.
func _constrain_to_walk_area() -> void:
	var xform: Transform2D = walk_area.global_transform
	var world_poly: PackedVector2Array = PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)

	# Collect test points from the collision shape edges.
	var test_points: Array[Vector2] = _get_shape_test_points()

	# Find the largest push needed to bring any outside point back in.
	var total_offset: Vector2 = Vector2.ZERO
	for tp in test_points:
		if Geometry2D.is_point_in_polygon(tp, world_poly):
			continue
		var best: Vector2 = tp
		var best_dist: float = INF
		for i in range(world_poly.size()):
			var a: Vector2 = world_poly[i]
			var b: Vector2 = world_poly[(i + 1) % world_poly.size()]
			var closest: Vector2 = _nearest_point_on_segment(tp, a, b)
			var d: float = tp.distance_squared_to(closest)
			if d < best_dist:
				best_dist = d
				best = closest
		var offset: Vector2 = best - tp
		if offset.length_squared() > total_offset.length_squared():
			total_offset = offset

	if total_offset != Vector2.ZERO:
		global_position += total_offset
		# Cancel only the into-wall component so the along-wall component
		# survives -- knockback and movement slide along the edge instead
		# of stopping dead.
		var wall_normal: Vector2 = total_offset.normalized()
		velocity -= wall_normal * minf(velocity.dot(wall_normal), 0.0)
		knockback_velocity -= wall_normal * minf(knockback_velocity.dot(wall_normal), 0.0)


## Returns key points on the collision shape boundary to test against the polygon.
func _get_shape_test_points() -> Array[Vector2]:
	if body_box == null or body_box.shape == null:
		return [global_position]
	var center: Vector2 = body_box.global_position
	if body_box.shape is RectangleShape2D:
		var half: Vector2 = (body_box.shape as RectangleShape2D).size / 2.0
		return [
			center + Vector2(-half.x, -half.y),
			center + Vector2( half.x, -half.y),
			center + Vector2( half.x,  half.y),
			center + Vector2(-half.x,  half.y),
		]
	elif body_box.shape is CapsuleShape2D:
		var cap: CapsuleShape2D = body_box.shape as CapsuleShape2D
		return [
			center + Vector2(0, -cap.height / 2.0),
			center + Vector2(0,  cap.height / 2.0),
			center + Vector2(-cap.radius, 0),
			center + Vector2( cap.radius, 0),
		]
	# Fallback: just test the center.
	return [center]


## Returns true if the given global-space point lies within this character's body_box shape.
## Used by abilities that need to detect a click/tap directly on this character (e.g. the
## Red Knight's Preparation ability activation).
func _is_point_in_own_hitbox(point: Vector2) -> bool:
	if body_box == null or body_box.shape == null:
		return false
	var local_point: Vector2 = body_box.global_transform.affine_inverse() * point
	if body_box.shape is RectangleShape2D:
		var half: Vector2 = (body_box.shape as RectangleShape2D).size / 2.0
		return absf(local_point.x) <= half.x and absf(local_point.y) <= half.y
	elif body_box.shape is CapsuleShape2D:
		var cap: CapsuleShape2D = body_box.shape as CapsuleShape2D
		var half_seg: float = maxf(cap.height / 2.0 - cap.radius, 0.0)
		var closest_y: float = clampf(local_point.y, -half_seg, half_seg)
		return local_point.distance_to(Vector2(0.0, closest_y)) <= cap.radius
	return point.distance_to(body_box.global_position) <= 1.0


func _nearest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq == 0.0:
		return a
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


## Restore health, clamped to max_health. Used by friendly healers such as the
## hut priest. Mirrors take_damage()'s guards: the joiner never edits its own HP,
## so the host heals and the periodic state snapshot syncs the result back.
func heal(amount: float) -> void:
	if is_dead:
		return
	if _ignore_client_side_gameplay():
		return
	health = minf(max_health, health + amount)
	health_changed.emit(health, max_health)
	HealNumber.spawn_at(get_tree().current_scene, global_position, amount)


func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if is_dead:
		return
	if _ignore_client_side_gameplay():
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	DamageNumber.spawn_at(get_tree().current_scene, global_position, amount)
	_flash_white()
	if hit_particles != null:
		hit_particles.restart()
	_play_weapon_hit_sound(weapon_type, flow_success)
	if OS.get_name() == "Web":
		JavaScriptBridge.eval("try { navigator.vibrate([200]); } catch(e) { console.warn('vibrate:', e); }")
	else:
		Input.vibrate_handheld(200, 0.7)
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "hit_fx", "p": str(get_path()), "wt": int(weapon_type), "fs": 1 if flow_success else 0, "dmg": amount, "dx": global_position.x, "dy": global_position.y})
	if health == 0.0:
		die()


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
	if flow_bar != null:
		_flow_bar_right_pos = flow_bar.position


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
	if flow_bar != null:
		flow_bar.position = Vector2(_flow_bar_right_pos.x * facing, _flow_bar_right_pos.y)


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()


## Add (positive) or remove (negative) coins from the shared party pool.
## The GameManager.coin_balance_changed handler wired in _ready() re-emits
## coins_changed, so callers and the HUD see the update the same as before.
func add_coins(amount: int) -> void:
	GameManager.add_coins(amount)


## Re-emit shared-pool changes as this character's own coins_changed signal.
func _on_coin_balance_changed(new_balance: int) -> void:
	coins_changed.emit(new_balance)


# ── Stat pips ─────────────────────────────────────────────────────────────────

## Recompute derived stats (max_health / attack_bonus / speed_bonus) from stat_pips
## and notify listeners. Safe to call any time after _ready().
func _apply_stat_pips() -> void:
	var hp_pips: int = int(stat_pips.get("hp", 0))
	var atk_pips: int = int(stat_pips.get("attack", 0))
	var spd_pips: int = int(stat_pips.get("speed", 0))
	max_health = _base_max_health + hp_pips * hp_per_pip
	health = minf(health, max_health)
	attack_bonus = atk_pips * attack_per_pip
	speed_bonus = spd_pips * speed_per_pip
	health_changed.emit(health, max_health)
	stat_pips_changed.emit(stat_pips)


## Replace the whole pip dictionary (network sync path — joiners apply host state
## verbatim). Missing keys keep their current value.
func set_stat_pips(stats: Dictionary) -> void:
	for key in ["hp", "attack", "speed", "flow"]:
		if stats.has(key):
			stat_pips[key] = int(stats[key])
	_apply_stat_pips()


## Add one pip to `category`. hp/attack/speed cap at MAX_PIPS (returns false when
## already full); "flow" always succeeds and refills to MAX_PIPS.
func add_stat_pip(category: String) -> bool:
	if category == "flow":
		stat_pips.flow = MAX_PIPS
		_apply_stat_pips()
		return true
	if not stat_pips.has(category):
		return false
	if int(stat_pips[category]) >= MAX_PIPS:
		return false
	stat_pips[category] = int(stat_pips[category]) + 1
	_apply_stat_pips()
	return true


## Remove one pip from a random non-empty category among hp/attack/speed.
## Returns the chosen category, or "" when all three are already empty.
func remove_random_stat_pip() -> String:
	var candidates: Array[String] = []
	for category in ["hp", "attack", "speed"]:
		if int(stat_pips.get(category, 0)) > 0:
			candidates.append(category)
	if candidates.is_empty():
		return ""
	var chosen: String = candidates[randi() % candidates.size()]
	stat_pips[chosen] = int(stat_pips[chosen]) - 1
	_apply_stat_pips()
	return chosen


## Flow window multiplier: 1.0 at full flow pips, 0.0 when exhausted (in 0.2 steps).
func get_flow_window_scale() -> float:
	return float(int(stat_pips.get("flow", MAX_PIPS))) / float(MAX_PIPS)


## Call when the character runs out of health.
func die() -> void:
	if is_dead:
		return
	is_dead = true
	clear_network_animation_override()
	set_collision_layer(0)
	set_collision_mask(0)
	set_physics_process(false)
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.hide()
	if health_bar != null:
		health_bar.hide()
	if flow_bar != null:
		flow_bar.hide()
	died.emit()
	# Signal the level to spawn the death poof. Pass spawn_coin=false so only
	# enemy deaths drop coins, not player deaths.
	# Deferred so this never runs mid-physics-flush (e.g. triggered by a hitbox signal).
	if get_tree().current_scene.has_method("on_entity_died"):
		get_tree().current_scene.call_deferred("on_entity_died", global_position, false)


## Revive this character at the given world position, restoring full health.
## Called by RunManager after the respawn delay expires.
func revive(at: Vector2) -> void:
	if not is_dead:
		return
	is_dead = false
	clear_network_animation_override()
	health = max_health
	global_position = at
	knockback_velocity = Vector2.ZERO
	set_collision_layer(_orig_layer)
	set_physics_process(true)
	set_process(true)
	set_process_input(true)
	set_process_unhandled_input(true)
	if animated_sprite != null:
		animated_sprite.show()
		animated_sprite.play(&"idle")
	if health_bar != null:
		health_bar.show()
	if flow_bar != null:
		flow_bar.hide()
	health_changed.emit(health, max_health)


# ── Flow timing ────────────────────────────────────────────────────────────────

## Subclasses call this to begin a flow sequence.
## window_center: normalized bar position (0=bottom, 1=top) for the midpoint of the green zone.
## window_half: half-width of the green zone (full zone = center +/- half).
## window_random: max random shift applied to the center each attack.
func _start_flow(input_action: StringName, on_resolved: Callable,
		fill_duration: float = 0.45, miss_multiplier: float = 0.6,
		window_center: float = 0.5, window_half: float = 0.1,
		window_random: float = 0.0) -> void:
	_begin_flow_common(input_action, on_resolved, fill_duration, miss_multiplier,
		window_center, window_half, window_random)


## Like _start_flow, but the bar goes straight to the resolve-ready state with no
## animation-driven pause frame. Used when a new attack interrupts the tail of a
## previous swing: the previous animation keeps playing while this bar fills.
func start_interrupt_flow(input_action: StringName, on_resolved: Callable,
		fill_duration: float = 0.45, miss_multiplier: float = 0.6,
		window_center: float = 0.5, window_half: float = 0.1,
		window_random: float = 0.0) -> void:
	_begin_flow_common(input_action, on_resolved, fill_duration, miss_multiplier,
		window_center, window_half, window_random)
	_flow_can_resolve = true


func _begin_flow_common(input_action: StringName, on_resolved: Callable,
		fill_duration: float, miss_multiplier: float,
		window_center: float, window_half: float, window_random: float) -> void:
	_flow_input_action = input_action
	_flow_on_resolved = on_resolved
	_flow_fill_duration = fill_duration
	_flow_miss_damage_multiplier = miss_multiplier
	_flow_active = true
	_flow_can_resolve = false
	_flow_early_mult = -1.0
	_flow_early_was_success = false
	_flow_progress = 0.0
	_flow_lingering = false
	_flow_linger_remaining = 0.0
	_flow_success_finish = false
	if flow_bar != null:
		flow_bar.show()
	if _flow_bar_api != null:
		var _shift: float = randf_range(-window_random, window_random)
		var _clamped_center: float = clampf(window_center + _shift, window_half, 1.0 - window_half)
		_flow_bar_api.success_window_start = _clamped_center - window_half
		_flow_bar_api.success_window_end = _clamped_center + window_half
		if _flow_bar_api.has_method("start_flow"):
			_flow_bar_api.start_flow()


func _stop_flow() -> void:
	_flow_active = false
	_flow_can_resolve = false
	_flow_early_mult = -1.0
	_flow_early_was_success = false
	_flow_input_action = &""
	_flow_progress = 0.0
	_flow_on_resolved = Callable()
	_flow_lingering = false
	_flow_linger_remaining = 0.0
	_flow_success_finish = false
	if _flow_bar_api != null and _flow_bar_api.has_method("stop_flow"):
		_flow_bar_api.stop_flow()
	if flow_bar != null:
		flow_bar.hide()


## True while a flow bar is filling OR its post-success white linger is showing.
## The next attack must not start until this is false.
func is_flow_busy() -> bool:
	return _flow_active or _flow_lingering


## True when the current *_FINISH animation came from a SUCCESS and its linger has
## elapsed — the next attack may now interrupt it.
func flow_finish_interruptible() -> bool:
	return _flow_success_finish and not is_flow_busy()


## Clears the active-flow bookkeeping but leaves the bar on screen so the white
## success fill can linger. Call this instead of _stop_flow() on a SUCCESS resolve.
func _clear_flow_active_keep_bar() -> void:
	_flow_active = false
	_flow_can_resolve = false
	_flow_early_mult = -1.0
	_flow_early_was_success = false
	_flow_input_action = &""
	_flow_progress = 0.0
	_flow_on_resolved = Callable()


## Begin the post-success white linger. The attack has already executed; the bar
## just stays visible for flow_linger_frames animation frames.
func _begin_flow_linger() -> void:
	if _flow_active:
		return  # a fresh flow was started inside the resolve callback — leave it alone
	var fps: float = 6.0
	if animated_sprite != null and animated_sprite.sprite_frames != null:
		var a: StringName = animated_sprite.animation
		if animated_sprite.sprite_frames.has_animation(a):
			fps = maxf(animated_sprite.sprite_frames.get_animation_speed(a), 0.001)
	_flow_lingering = true
	_flow_success_finish = true
	_flow_linger_remaining = flow_linger_frames / fps


## Linger elapsed — hide the bar. _flow_success_finish stays true so the FINISH
## animation remains interruptible until it ends.
func _end_flow_linger() -> void:
	_flow_lingering = false
	_flow_linger_remaining = 0.0
	if _flow_bar_api != null and _flow_bar_api.has_method("stop_flow"):
		_flow_bar_api.stop_flow()
	if flow_bar != null:
		flow_bar.hide()


## Called every physics frame while a flow sequence is running.
func _update_flow(delta: float) -> void:
	if _flow_lingering:
		_flow_linger_remaining -= delta
		if _flow_linger_remaining <= 0.0:
			_end_flow_linger()
		return
	if not _flow_active:
		return
	# Safety net: if the bar was stopped out from under us (e.g. a stray network
	# packet stopped only the bar and not _flow_active), advance() would return
	# false forever and the attack would hang mid-animation. Force an auto-miss
	# resolve so the state machine always makes progress.
	if _flow_bar_api != null and _flow_bar_api.has_method("is_active") and not _flow_bar_api.is_active():
		var heal_cb := _flow_on_resolved
		var heal_mult: float = _flow_miss_damage_multiplier if _flow_early_mult < 0.0 else _flow_early_mult
		_stop_flow()
		if heal_cb.is_valid():
			heal_cb.call(heal_mult)
		return
	var reached_top: bool = false
	if _flow_bar_api != null and _flow_bar_api.has_method("advance"):
		reached_top = _flow_bar_api.advance(delta, _flow_fill_duration)
	else:
		_flow_progress = clampf(_flow_progress + delta / maxf(_flow_fill_duration, 0.001), 0.0, 1.0)
		reached_top = _flow_progress >= 1.0
	if reached_top:
		# Only record the miss once (first time bar reaches top).
		if _flow_early_mult < 0.0:
			if _flow_bar_api != null and _flow_bar_api.has_method("mark_missed"):
				_flow_bar_api.mark_missed()
			_flow_early_mult = _flow_miss_damage_multiplier
		if _flow_can_resolve:
			var mult := _flow_early_mult
			var cb := _flow_on_resolved
			_stop_flow()
			if cb.is_valid():
				cb.call(mult)
		# else: windup — stored in _flow_early_mult, fires when pause frame is reached.


## Call from any attack state (windup or paused) to register the player's timing press.
## During windup (_flow_can_resolve = false) the result is stored and fires at the pause frame.
## During pause (_flow_can_resolve = true) SUCCESS resolves immediately as before.
func _handle_flow_attempt(action_name: StringName) -> void:
	if not _flow_active:
		return
	if not _action_just_pressed(action_name):
		return
	if _flow_bar_api == null or not _flow_bar_api.has_method("try_attempt"):
		if _flow_can_resolve:
			var cb := _flow_on_resolved
			_clear_flow_active_keep_bar()
			if cb.is_valid():
				cb.call(1.0)
			_begin_flow_linger()
		else:
			_flow_early_mult = 1.0
			_flow_early_was_success = true
		return
	var result: FlowTimingBar.AttemptResult = _flow_bar_api.try_attempt()
	match result:
		FlowTimingBar.AttemptResult.SUCCESS:
			if _flow_can_resolve:
				var cb := _flow_on_resolved
				_clear_flow_active_keep_bar()
				if cb.is_valid():
					cb.call(1.0)
				_begin_flow_linger()
			else:
				_flow_early_mult = 1.0
				_flow_early_was_success = true  # defer until pause frame; fires immediately on arrival
		FlowTimingBar.AttemptResult.MISS:
			_flow_early_mult = _flow_miss_damage_multiplier  # bar keeps filling grey
		FlowTimingBar.AttemptResult.NONE:
			pass  # attempt already used


## Called at the pause frame of an animation. If an early attempt result is pending it
## fires immediately (skipping the pause); otherwise marks resolves-allowed so the next
## attempt or bar-fill fires without delay. Returns true if flow resolved during this call.
func _flow_set_can_resolve() -> bool:
	if not _flow_active:
		return false
	_flow_can_resolve = true
	# Only fire immediately if the early attempt was a SUCCESS (green window hit).
	# A MISS during windup keeps the animation paused and waits for the bar to fill.
	if _flow_early_mult >= 0.0 and _flow_early_was_success:
		var mult := _flow_early_mult
		var cb := _flow_on_resolved
		_clear_flow_active_keep_bar()
		if cb.is_valid():
			cb.call(mult)
		_begin_flow_linger()
		return true
	return false

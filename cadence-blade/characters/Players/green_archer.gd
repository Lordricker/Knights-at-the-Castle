extends CharacterBase

# green_archer.gd -- Playable Green Archer character.
#
# INPUT ACTIONS (Project > Project Settings > Input Map):
#   "move_right" -> D     "move_left" -> A
#   "move_up"    -> W     "move_down" -> S
#   "shoot"      -> J  (or whichever key you assign)
#
# ANIMATIONS (AnimatedSprite2D SpriteFrames):
#   "idle"   -- loop ON
#   "running" -- loop ON
#   "shoot"  -- loop OFF  (pauses on frame 2 for flow charge)
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   +-- AnimatedSprite2D
#   +-- CollisionShape2D (bodyBox)
#   +-- Pivot (Node2D, facing_pivot)
#       +-- HealthBar
#       +-- FlowBar
#
# After flow resolves the archer fires an Arrow instance at the scene root.
# Drag an arrow.tscn PackedScene into arrow_scene in the Inspector.

const SHOOT_PAUSE_FRAME: int = 2
const KICK_PAUSE_FRAME: int = 1
const KICK_HITBOX_FRAMES: Array[int] = [2, 3, 4, 5]
const KICK_LUNGE_START_FRAME: int = 2
const KICK_LUNGE_END_FRAME: int = 5
const KICK_FLOW_CHECK_COUNT: int = 2

enum AttackState {
	NONE,
	SHOOT_WINDUP,
	SHOOT_PAUSED,
	SHOOT_FINISH,
	PIERCE_WINDUP,
	PIERCE_PAUSED,
	PIERCE_FINISH,
	KICK_WINDUP,
	KICK_PAUSED,
	KICK_FINISH,
}

var attack_state: AttackState = AttackState.NONE
var _current_attack_damage_multiplier: float = 1.0
## Whether the current attack is a pierce shot.
var _current_attack_is_pierce: bool = false

# ── Kick state ────────────────────────────────────────────────────────────────
var _kick_invincible: bool = false
var _kick_lunge_active: bool = false
var _kick_flow_checks_completed: int = 0

# ── Combo system ──────────────────────────────────────────────────────────────
## Number of consecutive enemy hits (resets when any arrow misses).
var _combo_hits: int = 0

# ── Shoot Attack ──────────────────────────────────────────────────────────────

@export_group("Shoot Attack")
## Arrow PackedScene to instantiate when the shot fires.
@export var arrow_scene: PackedScene
## Base damage the arrow deals on hit.
@export var arrow_damage: float = 30.0
## Arrow travel speed in pixels per second.
@export var arrow_speed: float = 600.0
## Knockback applied to enemies hit by the arrow.
@export var arrow_knockback_force: float = 200.0
## Movement speed multiplier while the shoot animation is playing.
@export_range(0.0, 1.0, 0.01) var shoot_move_mult: float = 0.25
## Seconds for the flow bar to fill during the shoot pause.
@export var shoot_flow_fill_duration: float = 0.8
## Damage multiplier when the bar auto-resolves without a successful press.
@export var shoot_flow_miss_multiplier: float = 0.5
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var shoot_flow_window_center: float = 0.5
## Half-width of the green zone. Window spans [center - half, center + half].
@export_range(0.0, 0.5, 0.01) var shoot_flow_window_half_size: float = 0.1
## Max random shift applied to the window center each shot.
@export_range(0.0, 0.5, 0.01) var shoot_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time (x=1 fresh, x=0 tired).
## Overrides the fixed half-size above when assigned.
@export var shoot_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var shoot_flow_window_curve_max_time: float = 300.0
@export_group("")

@export_group("Pierce Attack")
## Base damage the pierce arrow deals per enemy hit.
@export var pierce_damage: float = 20.0
## Pierce arrow travel speed in pixels per second.
@export var pierce_speed: float = 700.0
## Knockback applied to each enemy the pierce arrow hits.
@export var pierce_knockback_force: float = 100.0
## Movement speed multiplier while the pierce animation is playing.
@export_range(0.0, 1.0, 0.01) var pierce_move_mult: float = 0.25
## Seconds for the flow bar to fill during the pierce pause.
@export var pierce_flow_fill_duration: float = 0.8
## Damage multiplier when the pierce bar auto-resolves without a successful press.
@export var pierce_flow_miss_multiplier: float = 0.5
## Center of the green zone for pierce.
@export_range(0.0, 1.0, 0.01) var pierce_flow_window_center: float = 0.5
## Half-width of the green zone for pierce.
@export_range(0.0, 0.5, 0.01) var pierce_flow_window_half_size: float = 0.1
## Max random shift applied to the pierce window center each shot.
@export_range(0.0, 0.5, 0.01) var pierce_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var pierce_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the pierce size curve.
@export var pierce_flow_window_curve_max_time: float = 300.0
@export_group("")

@export_group("Kick Attack")
## Base damage the kick deals on hit.
@export var kick_damage: float = 40.0
## Knockback force applied to enemies hit by the kick.
@export var kick_knockback_force: float = 500.0
## Pixels per second the archer lunges during kick frames 2–5.
@export var kick_lunge_speed: float = 80.0
## Seconds for the flow bar to fill during each kick pause.
@export var kick_flow_fill_duration: float = 0.45
## Damage multiplier when the kick bar auto-resolves (missed timing).
@export var kick_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom, 1 = top).
@export_range(0.0, 1.0, 0.01) var kick_flow_window_center: float = 0.5
## Half-width of the green zone.
@export_range(0.0, 0.5, 0.01) var kick_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each kick check.
@export_range(0.0, 0.5, 0.01) var kick_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var kick_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the kick size curve.
@export var kick_flow_window_curve_max_time: float = 300.0
@export_group("")
## Added damage multiplier per consecutive hit (stacks up to 2 extra hits).
## At combo hit 1: 1 + combo_step_multiplier. At hit 2+: 1 + 2*combo_step_multiplier.
@export var combo_step_multiplier: float = 0.5
@export_group("")

# ── Movement bounds ───────────────────────────────────────────────────────────

@export var x_min: float = -1000.0
@export var x_max: float = 1000.0
@export var y_min: float = -270.0
@export var y_max: float = 270.0

@export var kick_hitbox: Area2D


func _ready() -> void:
	super()
	if animated_sprite == null:
		return
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play("idle")
	_set_kick_hitbox(false)
	if kick_hitbox != null:
		kick_hitbox.body_entered.connect(_on_kick_hit_body)


func _physics_process(delta: float) -> void:
	super(delta)
	global_position.x = clampf(global_position.x, x_min, x_max)
	global_position.y = clampf(global_position.y, y_min, y_max)
	if _kick_lunge_active:
		global_position.x += facing * kick_lunge_speed * delta


# ── Movement ──────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_attack: bool = attack_state != AttackState.NONE
	var speed_mult: float = shoot_move_mult if in_attack else 1.0

	var dir_x: float = _get_axis("move_left", "move_right")
	var dir_y: float = _get_axis("move_up", "move_down")

	var effective_speed: float = move_speed + speed_bonus
	velocity.x = dir_x * effective_speed * speed_mult
	velocity.y = dir_y * effective_speed * speed_mult

	if not _action_pressed("face_lock"):
		if dir_x > 0.0:
			_set_facing(1.0)
		elif dir_x < 0.0:
			_set_facing(-1.0)

	_update_animation(dir_x, dir_y)
	_handle_attack_input()


func _update_animation(dir_x: float, dir_y: float) -> void:
	if has_network_animation_override():
		return
	if attack_state != AttackState.NONE:
		return
	if healing_locked:
		if animated_sprite.animation != "heal":
			animated_sprite.play(&"heal")
		return
	if dir_x != 0.0 or dir_y != 0.0:
		if animated_sprite.animation != "running":
			animated_sprite.play("running")
	else:
		if animated_sprite.animation != "idle":
			animated_sprite.play("idle")


# ── Attack input ──────────────────────────────────────────────────────────────

func _handle_attack_input() -> void:
	match attack_state:
		AttackState.NONE:
			if not attacks_locked:
				if _action_just_pressed("action1"):
					_begin_shoot(false)
				elif _action_just_pressed("action2"):
					_begin_shoot(true)
				elif _action_just_pressed("action3"):
					_begin_kick()
		AttackState.SHOOT_WINDUP:
			_handle_flow_attempt(&"action1")
		AttackState.SHOOT_PAUSED:
			_handle_flow_attempt(&"action1")
		AttackState.PIERCE_WINDUP:
			_handle_flow_attempt(&"action2")
		AttackState.PIERCE_PAUSED:
			_handle_flow_attempt(&"action2")
		AttackState.KICK_WINDUP:
			_handle_flow_attempt(&"action3")
		AttackState.KICK_PAUSED:
			_handle_flow_attempt(&"action3")


func _begin_kick() -> void:
	attack_state = AttackState.KICK_WINDUP
	_current_attack_damage_multiplier = 1.0
	_kick_flow_checks_completed = 0
	_kick_lunge_active = false
	_stop_flow()
	animated_sprite.play("kick")
	animated_sprite.frame = 0

	_start_kick_flow_check(false)


func _start_kick_flow_check(allow_immediate: bool = false) -> void:
	var _half := _sample_window_half(kick_flow_window_size_curve,
		kick_flow_window_half_size, kick_flow_window_curve_max_time)

	_start_flow(&"action3",
		func(mult: float):
			_current_attack_damage_multiplier = minf(_current_attack_damage_multiplier, mult)
			_kick_flow_checks_completed += 1
			if _kick_flow_checks_completed < KICK_FLOW_CHECK_COUNT:
				# Pause at the pause frame and wait for the next check
				attack_state = AttackState.KICK_PAUSED
				animated_sprite.frame = KICK_PAUSE_FRAME
				animated_sprite.pause()
				# Schedule the next flow check on the next idle so we don't nest callbacks
				call_deferred("_start_kick_flow_check", true)
				return
			# All checks complete: proceed to finish the kick animation (resume from pause)
			attack_state = AttackState.KICK_FINISH
			animated_sprite.frame = KICK_PAUSE_FRAME
			animated_sprite.play("kick"),
		kick_flow_fill_duration, kick_flow_miss_multiplier,
		kick_flow_window_center, _half, kick_flow_window_random_range)

	# If caller requested immediate resolution while paused, allow attempts now
	if allow_immediate:
		_flow_can_resolve = true


func _begin_shoot(is_pierce: bool) -> void:
	_current_attack_is_pierce = is_pierce
	attack_state = AttackState.PIERCE_WINDUP if is_pierce else AttackState.SHOOT_WINDUP
	_current_attack_damage_multiplier = 1.0
	_stop_flow()
	animated_sprite.play("shoot")
	animated_sprite.frame = 0
	if is_pierce:
		var _ph := _sample_window_half(
				pierce_flow_window_size_curve,
				pierce_flow_window_half_size,
				pierce_flow_window_curve_max_time)
		_start_flow(&"action2",
			func(mult: float):
				_current_attack_damage_multiplier = mult
				attack_state = AttackState.PIERCE_FINISH
				animated_sprite.play("shoot")
				animated_sprite.frame = SHOOT_PAUSE_FRAME
				_queue_fire_arrow(true),
			pierce_flow_fill_duration, pierce_flow_miss_multiplier,
			pierce_flow_window_center, _ph, pierce_flow_window_random_range)
	else:
		var _sh := _sample_window_half(
				shoot_flow_window_size_curve,
				shoot_flow_window_half_size,
				shoot_flow_window_curve_max_time)
		_start_flow(&"action1",
			func(mult: float):
				_current_attack_damage_multiplier = mult
				attack_state = AttackState.SHOOT_FINISH
				animated_sprite.play("shoot")
				animated_sprite.frame = SHOOT_PAUSE_FRAME
				_queue_fire_arrow(false),
			shoot_flow_fill_duration, shoot_flow_miss_multiplier,
			shoot_flow_window_center, _sh, shoot_flow_window_random_range)


# ── AnimatedSprite2D signal handlers ─────────────────────────────────────────

func _on_frame_changed() -> void:
	var f: int = animated_sprite.frame
	match attack_state:
		AttackState.SHOOT_WINDUP:
			if f >= SHOOT_PAUSE_FRAME:
				attack_state = AttackState.SHOOT_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true
		AttackState.PIERCE_WINDUP:
			if f >= SHOOT_PAUSE_FRAME:
				attack_state = AttackState.PIERCE_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true
		AttackState.KICK_WINDUP:
			if f >= KICK_PAUSE_FRAME:
				attack_state = AttackState.KICK_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true
		AttackState.KICK_PAUSED:
			pass  # waiting for flow; hitbox not active until KICK_FINISH
		AttackState.KICK_FINISH:
			var kick_active: bool = f in KICK_HITBOX_FRAMES
			_set_kick_hitbox(kick_active)
			_kick_invincible = kick_active
			if f == KICK_LUNGE_START_FRAME:
				_kick_lunge_active = true
			elif f > KICK_LUNGE_END_FRAME:
				_kick_lunge_active = false


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SHOOT_FINISH, AttackState.PIERCE_FINISH:
			attack_state = AttackState.NONE
			_current_attack_damage_multiplier = 1.0
			_stop_flow()
			animated_sprite.play("idle")
		AttackState.KICK_FINISH:
			attack_state = AttackState.NONE
			_current_attack_damage_multiplier = 1.0
			_kick_flow_checks_completed = 0
			_kick_invincible = false
			_kick_lunge_active = false
			_stop_flow()
			_set_kick_hitbox(false)
			animated_sprite.play("idle")


# ── Arrow firing ──────────────────────────────────────────────────────────────

## Returns the combo multiplier for the current combo hit count.
## hit 0 = 1.0x, hit 1 = 1+step, hit 2+ = 1+2*step (capped).
func _combo_multiplier() -> float:
	return 1.0 + minf(float(_combo_hits), 2.0) * combo_step_multiplier


## Schedules arrow creation outside the physics step to avoid collision-server conflicts.
## is_pierce: if true, arrow has pierce=true and uses pierce stats.
func _queue_fire_arrow(is_pierce: bool) -> void:
	if arrow_scene == null:
		return
	# Joiner authority: fire a local zero-damage tracking arrow for visual + combo feedback,
	# then route the real damage to the host via a "flow_fire" reliable packet.
	if GameManager.session_id != "" and not GameManager.is_host:
		var base_spd_j: float = pierce_speed if is_pierce else arrow_speed
		var flow_suc_j: bool = _current_attack_damage_multiplier >= 1.0
		var dmg_j: float = ((pierce_damage if is_pierce else arrow_damage) + attack_bonus) \
				* _current_attack_damage_multiplier * _combo_multiplier()
		var tracking := arrow_scene.instantiate() as Arrow
		if tracking != null:
			tracking.configure(global_position, Vector2(facing, 0.0), base_spd_j, 0.0, 0.0, false)
			if is_pierce:
				tracking.pierce = true
			if _combo_hits >= 2:
				tracking.set_combo_color(tracking.combo_color_2)
			elif _combo_hits == 1:
				tracking.set_combo_color(tracking.combo_color_1)
			tracking.body_entered.connect(_on_arrow_hit_enemy.bind(tracking))
			tracking.missed.connect(_on_arrow_missed)
			get_tree().current_scene.call_deferred("add_child", tracking)
		WebRTCManager.send_reliable({
			"t":   "flow_fire",
			"x":   global_position.x,
			"y":   global_position.y,
			"dx":  facing,
			"sp":  base_spd_j,
			"pi":  1 if is_pierce else 0,
			"dmg": dmg_j,
			"s":   1 if flow_suc_j else 0,
			"cc":  _combo_hits,
		})
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return
	var base_dmg: float = pierce_damage if is_pierce else arrow_damage
	var base_speed: float = pierce_speed if is_pierce else arrow_speed
	var base_kb: float = pierce_knockback_force if is_pierce else arrow_knockback_force
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	# Damage = (base + upgrade bonus) * flow_multiplier * combo_multiplier
	var dmg := (base_dmg + attack_bonus) * _current_attack_damage_multiplier * _combo_multiplier()
	arrow.configure(global_position, Vector2(facing, 0.0), base_speed, dmg, base_kb, flow_success)
	if is_pierce:
		arrow.pierce = true
	# Apply combo particle color before adding to tree.
	if _combo_hits >= 2:
		arrow.set_combo_color(arrow.combo_color_2)
	elif _combo_hits == 1:
		arrow.set_combo_color(arrow.combo_color_1)
	# Connect the arrow's body_entered to track combo hits (only when not display-only).
	# We do this before add_child so the signal is wired from the start.
	arrow.body_entered.connect(_on_arrow_hit_enemy.bind(arrow))
	arrow.missed.connect(_on_arrow_missed)
	get_tree().current_scene.call_deferred("add_child", arrow)
	# Tell the joiner to spawn a visual-only arrow.
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":   "arrow",
			"x":   global_position.x,
			"y":   global_position.y,
			"dx":  facing,
			"sp":  base_speed,
			"pi":  1 if is_pierce else 0,
			"cc":  _combo_hits,  # joiner uses this to tint the display arrow
		})


## Fires when one of the host-side arrows hits an enemy — advances combo streak.
func _on_arrow_hit_enemy(body: Node2D, _arrow: Arrow) -> void:
	if not body.has_method("take_damage"):
		return
	_combo_hits = mini(_combo_hits + 1, 999)


## Arrow expired without hitting any enemy — reset combo streak.
func _on_arrow_missed() -> void:
	_combo_hits = 0


# ── Die / Revive ──────────────────────────────────────────────────────────────

func die() -> void:
	attack_state = AttackState.NONE
	_current_attack_damage_multiplier = 1.0
	_kick_flow_checks_completed = 0
	_kick_invincible = false
	_kick_lunge_active = false
	_combo_hits = 0
	_stop_flow()
	_set_kick_hitbox(false)
	super()


func revive(at: Vector2) -> void:
	attack_state = AttackState.NONE
	_current_attack_damage_multiplier = 1.0
	_kick_flow_checks_completed = 0
	_kick_invincible = false
	_kick_lunge_active = false
	_combo_hits = 0
	_stop_flow()
	super(at)


## Block incoming damage while the kick hitbox is active (i-frames).
func take_damage(amount: float, flow_success: bool = false) -> void:
	if _kick_invincible:
		return
	super(amount, flow_success)


func _set_kick_hitbox(enabled: bool) -> void:
	if kick_hitbox == null:
		return
	kick_hitbox.set_deferred(&"monitoring", enabled)
	kick_hitbox.set_deferred(&"monitorable", enabled)


func _on_kick_hit_body(body: Node2D) -> void:
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	var dmg: float = (kick_damage + attack_bonus) * _current_attack_damage_multiplier
	if body.has_method("take_damage"):
		body.take_damage(dmg, flow_success)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, kick_knockback_force)
	if GameManager.session_id != "" and not GameManager.is_host:
		var eid: int = int(body.get_meta(&"spawn_id", -1))
		if eid >= 0:
			WebRTCManager.send_reliable({
				"t":   "melee_hit",
				"eid": eid,
				"dmg": dmg,
				"kbf": kick_knockback_force,
				"kbx": global_position.x,
				"kby": global_position.y,
				"s":   1 if flow_success else 0,
			})


# ── Flow window helpers ────────────────────────────────────────────────────────

## Returns the effective elapsed run time used to sample flow window size curves.
## Subtracts flow_time_offset so a +Flow upgrade resets the curve to the start.
func _get_run_elapsed() -> float:
	var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
	if rm != null and "time_elapsed" in rm:
		return maxf(0.0, float(rm.time_elapsed) - flow_time_offset)
	return 0.0


func _sample_window_half(curve: Curve, default_half: float, curve_max_time: float) -> float:
	if curve == null:
		return default_half
	var t := clampf(_get_run_elapsed() / maxf(curve_max_time, 1.0), 0.0, 1.0)
	return curve.sample_baked(t)

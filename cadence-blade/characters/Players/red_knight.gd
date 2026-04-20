extends CharacterBase

# red_knight.gd — playable Red Knight character.
#
# INPUT ACTIONS (Project > Project Settings > Input Map):
#   "move_right" → D     "move_left" → A
#   "move_up"    → W     "move_down" → S
#   "slash"      → J     "thrust"    → K     "spin" → L
#
# ANIMATIONS (AnimatedSprite2D SpriteFrames):
#   "idle"    — loop ON
#   "running" — loop ON
#   "slash"   — loop OFF
#   "thrust"  — loop OFF
#   "spin"    — loop OFF
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D
#   ├── CollisionShape2D
#   ├── SlashHitbox   (Area2D — wide rectangle, positioned at sword reach)
#   │   └── CollisionShape2D
#   ├── ThrustHitbox  (Area2D — tall narrow rectangle, positioned forward)
#   │   └── CollisionShape2D
#   ├── SpinHitbox    (Area2D — arc/circle, positioned around the knight)
#   │   └── CollisionShape2D
#   ├── HealthBar     (Node2D — attach ui/hud/vertical_health_bar.gd)
#   └── FlowBar       (Node2D — attach ui/hud/flow_timing_bar.gd)

# ── Constants ─────────────────────────────────────────────────────────────────

const SLASH_PAUSE_FRAME: int = 2
const THRUST_PAUSE_FRAME: int = 3
const ATTACK_MOVE_MULT: float = 0.3

# Slash hitbox active on frames 3 and 5.
const SLASH_HITBOX_FRAMES: Array[int] = [4, 8]
# Thrust hitbox active on frames 5 and 6.
const THRUST_HITBOX_FRAMES: Array[int] = [5, 6]
# Lunge is active during frames 5–7 of the thrust finish animation.
const THRUST_LUNGE_START_FRAME: int = 5
const THRUST_LUNGE_END_FRAME: int = 7
# Spin hitbox active on frames 5 and 6. Frame 6 mirrors the hitbox to the opposite side.
const SPIN_HITBOX_FRAMES: Array[int] = [5, 6]
const SPIN_MIRROR_FRAME: int = 6
const SPIN_PAUSE_FRAME: int = 3
const SPIN_FLOW_CHECK_COUNT: int = 2

# ── Attack state machine ───────────────────────────────────────────────────────

enum AttackState {
	NONE,
	SLASH_WINDUP,
	SLASH_PAUSED,
	SLASH_FINISH,
	THRUST_WINDUP,
	THRUST_PAUSED,
	THRUST_FINISH,
	SPIN_WINDUP,
	SPIN_PAUSED,
	SPIN_FINISH,
}

var attack_state: AttackState = AttackState.NONE
var lunge_active: bool = false
var _slash_effect_pending_hide: bool = false
# True while the thrust FINISH animation is playing — player cannot take damage.
var _thrust_invincible: bool = false
var _spin_flow_checks_completed: int = 0


# ── Slash Attack ──────────────────────────────────────────────────────────────

@export_group("Slash Attack")
## Base damage dealt by a slash attack.
@export var slash_damage: float = 35.0
## Knockback force applied to enemies hit by a slash.
@export var slash_knockback_force: float = 400.0
## Seconds for the flow bar to fill during the slash pause.
@export var slash_flow_fill_duration: float = 0.45
## Damage multiplier when the slash bar auto-resolves (missed timing).
@export var slash_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var slash_flow_window_center: float = 0.5
## Half-width of the green zone. Window spans [center - half, center + half].
@export_range(0.0, 0.5, 0.01) var slash_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each slash.
@export_range(0.0, 0.5, 0.01) var slash_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time (x=0 fresh, x=1 tired).
## Overrides the fixed half-size above when assigned.
@export var slash_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var slash_flow_window_curve_max_time: float = 300.0

# ── Thrust Attack ─────────────────────────────────────────────────────────────

@export_group("Thrust Attack")
## Base damage dealt by a thrust attack.
@export var thrust_damage: float = 45.0
## Knockback force applied to enemies hit by a thrust.
@export var thrust_knockback_force: float = 400.0
## Pixels per second the Red Knight lunges forward during thrust frames 5-7.
@export var thrust_lunge_speed: float = 80.0
## Seconds for the flow bar to fill during the thrust pause.
@export var thrust_flow_fill_duration: float = 0.45
## Damage multiplier when the thrust bar auto-resolves (missed timing).
@export var thrust_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var thrust_flow_window_center: float = 0.5
## Half-width of the green zone.
@export_range(0.0, 0.5, 0.01) var thrust_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each thrust.
@export_range(0.0, 0.5, 0.01) var thrust_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var thrust_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var thrust_flow_window_curve_max_time: float = 300.0

# ── Spin Attack ───────────────────────────────────────────────────────────────

@export_group("Spin Attack")
## Base damage dealt by a spin attack.
@export var spin_damage: float = 40.0
## Knockback force applied to enemies hit by a spin.
@export var spin_knockback_force: float = 500.0
## Seconds for the flow bar to fill during the spin pause.
@export var spin_flow_fill_duration: float = 0.45
## Damage multiplier when the spin bar auto-resolves (missed timing).
@export var spin_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var spin_flow_window_center: float = 0.5
## Half-width of the green zone.
@export_range(0.0, 0.5, 0.01) var spin_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each spin check.
@export_range(0.0, 0.5, 0.01) var spin_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var spin_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var spin_flow_window_curve_max_time: float = 300.0
@export_group("")

# ── Movement bounds (pixels -- set to match your level art) ───────────────────

@export var x_min: float = -1000.0
@export var x_max: float = 1000.0
@export var y_min: float = -270.0
@export var y_max: float = 270.0

# ── Hitbox nodes ──────────────────────────────────────────────────────────────

@onready var slash_hitbox: Area2D = find_child("SlashHitbox") as Area2D
@onready var thrust_hitbox: Area2D = find_child("ThrustHitbox") as Area2D
@onready var spin_hitbox: Area2D = find_child("SpinHitbox") as Area2D
@onready var slash_effect_root: Node2D = _find_slash_effect_root()
@onready var slash_effect_sprite: Sprite2D = _find_slash_effect_sprite()
@onready var slash_effect_particles_down: CPUParticles2D = _find_slash_effect_particles("ParticalsDown")
@onready var slash_effect_particles_up: CPUParticles2D = _find_slash_effect_particles("ParticalsUp")

var _slash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _thrust_hitbox_right_pos: Vector2 = Vector2.ZERO
var _spin_hitbox_right_pos: Vector2 = Vector2.ZERO

var _current_attack_damage_multiplier: float = 1.0


func _ready() -> void:
	super()
	if animated_sprite == null:
		return
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play("idle")
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	_set_hitbox(spin_hitbox, false)
	_initialize_slash_effect()
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_slash_hit_body)
	if thrust_hitbox != null:
		thrust_hitbox.body_entered.connect(_on_thrust_hit_body)
	if spin_hitbox != null:
		spin_hitbox.body_entered.connect(_on_spin_hit_body)


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = (attack_state == AttackState.SLASH_PAUSED
						or attack_state == AttackState.THRUST_PAUSED
						or attack_state == AttackState.SPIN_PAUSED)
	var in_finish: bool = (attack_state == AttackState.SLASH_FINISH
						or attack_state == AttackState.THRUST_FINISH
						or attack_state == AttackState.SPIN_FINISH)

	var speed_mult: float = ATTACK_MOVE_MULT if (in_pause or in_finish) else 1.0

	var dir_x: float = Input.get_axis("move_left", "move_right")
	var dir_y: float = Input.get_axis("move_up", "move_down")

	var effective_speed: float = move_speed + speed_bonus
	velocity.x = dir_x * effective_speed * speed_mult
	velocity.y = dir_y * effective_speed * speed_mult

	# Facing: driven purely by input direction.
	# Shift held = lock facing. Otherwise, pressing left/right sets direction.
	if not Input.is_action_pressed("face_lock"):
		if dir_x > 0.0:
			_set_facing(1.0)
		elif dir_x < 0.0:
			_set_facing(-1.0)

	_update_animation(dir_x, dir_y)
	_handle_attack_input()


func _physics_process(delta: float) -> void:
	super(delta)
	# Clamp to walkable area after move_and_slide (world space).
	global_position.x = clampf(global_position.x, x_min, x_max)
	global_position.y = clampf(global_position.y, y_min, y_max)
	# Smooth lunge: applied every physics frame while lunge is active.
	if lunge_active:
		global_position.x += facing * thrust_lunge_speed * delta


func _update_animation(dir_x: float, dir_y: float) -> void:
	# Attack animations own the sprite — hands off.
	if attack_state != AttackState.NONE:
		return

	# CastleInside requests the heal pose while the player is in the monk zone.
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


# ── Attack input ───────────────────────────────────────────────────────────────

func _handle_attack_input() -> void:
	match attack_state:
		AttackState.NONE:
			# Suppress new attacks while the player is at the blacksmith.
			if not attacks_locked:
				if Input.is_action_just_pressed("slash"):
					_begin_attack("slash", AttackState.SLASH_WINDUP)
				elif Input.is_action_just_pressed("thrust"):
					_begin_attack("thrust", AttackState.THRUST_WINDUP)
				elif Input.is_action_just_pressed("spin"):
					_begin_attack("spin", AttackState.SPIN_WINDUP)

		AttackState.SLASH_PAUSED:
			_handle_flow_attempt(&"slash")

		AttackState.THRUST_PAUSED:
			_handle_flow_attempt(&"thrust")

		AttackState.SPIN_PAUSED:
			_handle_flow_attempt(&"spin")


## Disable hitboxes and reset attack state immediately on death,
## so a mid-animation attack cannot keep dealing damage after the poof.
func die() -> void:
	attack_state = AttackState.NONE
	lunge_active = false
	_thrust_invincible = false
	_spin_flow_checks_completed = 0
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_stop_flow()
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	_set_hitbox(spin_hitbox, false)
	_set_slash_effect_sprite(false)
	super()

## Block incoming damage while the thrust lunge is active (i-frames).
func take_damage(amount: float, flow_success: bool = false) -> void:
	if _thrust_invincible:
		return
	super(amount, flow_success)

## Reset all attack state on respawn so the player does not resume mid-swing.
func revive(at: Vector2) -> void:
	attack_state = AttackState.NONE
	lunge_active = false
	_thrust_invincible = false
	_spin_flow_checks_completed = 0
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_stop_flow()
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	_set_hitbox(spin_hitbox, false)
	_set_slash_effect_sprite(false)
	super(at)


func _begin_attack(anim_name: String, next_state: AttackState) -> void:
	attack_state = next_state
	_current_attack_damage_multiplier = 1.0
	_spin_flow_checks_completed = 0
	_stop_flow()
	animated_sprite.play(anim_name)
	animated_sprite.frame = 0


func _start_spin_flow_check() -> void:
	var _half := _sample_window_half(spin_flow_window_size_curve,
			spin_flow_window_half_size, spin_flow_window_curve_max_time)
	_start_flow(&"spin", func(mult: float):
		_current_attack_damage_multiplier = minf(_current_attack_damage_multiplier, mult)
		_spin_flow_checks_completed += 1
		if _spin_flow_checks_completed < SPIN_FLOW_CHECK_COUNT:
			_start_spin_flow_check()
			return
		_finish_attack("spin", SPIN_PAUSE_FRAME, AttackState.SPIN_FINISH),
		spin_flow_fill_duration, spin_flow_miss_multiplier,
		spin_flow_window_center, _half, spin_flow_window_random_range)


func _finish_attack(anim_name: String, resume_frame: int, next_state: AttackState) -> void:
	attack_state = next_state
	# Resume the animation from the pause frame.
	# Calling play() on the already-current animation resumes without resetting
	# the frame in Godot 4 (same animation name = no reset). As a safety net
	# we also force the frame immediately after.
	animated_sprite.play(anim_name)
	animated_sprite.frame = resume_frame


# ── AnimatedSprite2D signal handlers ──────────────────────────────────────────

func _on_frame_changed() -> void:
	var f: int = animated_sprite.frame
	match attack_state:
		AttackState.SLASH_WINDUP:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()
			if f >= SLASH_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.SLASH_PAUSED
				var _half := _sample_window_half(slash_flow_window_size_curve,
						slash_flow_window_half_size, slash_flow_window_curve_max_time)
				_start_flow(&"slash", func(mult: float):
					_current_attack_damage_multiplier = mult
					_finish_attack("slash", SLASH_PAUSE_FRAME, AttackState.SLASH_FINISH),
					slash_flow_fill_duration, slash_flow_miss_multiplier,
					slash_flow_window_center, _half, slash_flow_window_random_range)

		AttackState.SLASH_PAUSED:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()

		AttackState.SLASH_FINISH:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()

		AttackState.THRUST_WINDUP:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f >= THRUST_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.THRUST_PAUSED
				var _half := _sample_window_half(thrust_flow_window_size_curve,
						thrust_flow_window_half_size, thrust_flow_window_curve_max_time)
				_start_flow(&"thrust", func(mult: float):
					_current_attack_damage_multiplier = mult
					_thrust_invincible = true
					_finish_attack("thrust", THRUST_PAUSE_FRAME, AttackState.THRUST_FINISH),
					thrust_flow_fill_duration, thrust_flow_miss_multiplier,
					thrust_flow_window_center, _half, thrust_flow_window_random_range)

		AttackState.THRUST_PAUSED:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)

		AttackState.THRUST_FINISH:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f == THRUST_LUNGE_START_FRAME:
				lunge_active = true
			elif f > THRUST_LUNGE_END_FRAME:
				lunge_active = false

		AttackState.SPIN_WINDUP:
			# Hitbox frames are past the pause point, so they only fire in SPIN_FINISH.
			if f >= SPIN_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.SPIN_PAUSED
				_start_spin_flow_check()

		AttackState.SPIN_PAUSED:
			pass  # waiting for flow input; hitbox not active until SPIN_FINISH

		AttackState.SPIN_FINISH:
			var spin_active: bool = f in SPIN_HITBOX_FRAMES
			_set_hitbox(spin_hitbox, spin_active)
			if spin_hitbox != null:
				# Frame 6 only: flip to the opposite side in pivot-local space.
				# The pivot's scale.x already handles world-space facing, so no * facing here.
				# All other frames (incl. frame 7+) restore to the captured right-side position.
				var x_mult: float = -1.0 if f == SPIN_MIRROR_FRAME else 1.0
				spin_hitbox.position = Vector2(_spin_hitbox_right_pos.x * x_mult, _spin_hitbox_right_pos.y)


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASH_FINISH, AttackState.THRUST_FINISH, AttackState.SPIN_FINISH:
			attack_state = AttackState.NONE
			lunge_active = false
			_thrust_invincible = false
			_spin_flow_checks_completed = 0
			_current_attack_damage_multiplier = 1.0
			_stop_flow()
			_set_hitbox(slash_hitbox, false)
			_set_hitbox(thrust_hitbox, false)
			_set_hitbox(spin_hitbox, false)
			_slash_effect_pending_hide = false
			_set_slash_effect_sprite(false)
			animated_sprite.play("idle")


## Called when any active hitbox touches an enemy body.
func _on_slash_hit_body(body: Node2D) -> void:
	_apply_hit_body(body)
	_sync_slash_effect_facing()
	_set_slash_effect_sprite(true)
	_slash_effect_pending_hide = true
	_restart_slash_particles(slash_effect_particles_down)
	_restart_slash_particles(slash_effect_particles_up)


func _on_thrust_hit_body(body: Node2D) -> void:
	_apply_hit_body(body)


func _on_spin_hit_body(body: Node2D) -> void:
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	if body.has_method("take_damage"):
		body.take_damage(_get_current_attack_damage(), flow_success)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, spin_knockback_force)


func _apply_hit_body(body: Node2D) -> void:
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	if body.has_method("take_damage"):
		body.take_damage(_get_current_attack_damage(), flow_success)
	if body.has_method("apply_knockback"):
		var kforce: float
		match attack_state:
			AttackState.THRUST_WINDUP, AttackState.THRUST_PAUSED, AttackState.THRUST_FINISH:
				kforce = thrust_knockback_force
			_:
				kforce = slash_knockback_force
		body.apply_knockback(global_position, kforce)


## Enable or disable an Area2D hitbox.
## Always deferred so this is safe to call from body_entered / frame_changed signals.
func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


func _initialize_slash_effect() -> void:
	_sync_slash_effect_facing()
	if slash_effect_sprite != null:
		slash_effect_sprite.z_as_relative = false
		slash_effect_sprite.z_index = 100
		slash_effect_sprite.hide()
	if slash_effect_particles_down != null:
		slash_effect_particles_down.emitting = false
	if slash_effect_particles_up != null:
		slash_effect_particles_up.emitting = false


func _set_slash_effect_sprite(show_it: bool) -> void:
	if slash_effect_sprite != null:
		slash_effect_sprite.visible = show_it


## Called each animation frame tick during a slash. Hides the sprite one
## animation frame after contact was made, keeping it at animation speed.
func _flush_slash_effect_sprite() -> void:
	if _slash_effect_pending_hide:
		_slash_effect_pending_hide = false
		_set_slash_effect_sprite(false)


func _restart_slash_particles(particles: CPUParticles2D) -> void:
	if particles == null:
		return
	particles.emitting = false
	particles.restart()
	particles.emitting = true


func _find_slash_effect_root() -> Node2D:
	var effect: Node = get_node_or_null("slashEffect")
	if effect == null:
		effect = get_node_or_null("../slashEffect")
	if effect == null:
		effect = find_child("slashEffect", true, false)
	return effect as Node2D


func _find_slash_effect_sprite() -> Sprite2D:
	if slash_effect_root == null:
		return null
	return slash_effect_root.get_node_or_null("SlashEffect") as Sprite2D


func _find_slash_effect_particles(node_name: String) -> CPUParticles2D:
	if slash_effect_root == null:
		return null
	return slash_effect_root.get_node_or_null(node_name) as CPUParticles2D


func _capture_right_facing_transforms() -> void:
	super()
	if slash_hitbox != null:
		_slash_hitbox_right_pos = slash_hitbox.position
	if thrust_hitbox != null:
		_thrust_hitbox_right_pos = thrust_hitbox.position
	if spin_hitbox != null:
		_spin_hitbox_right_pos = spin_hitbox.position


# ── Flow timing ────────────────────────────────────────────────────────────────
# _start_flow, _stop_flow, _update_flow, _handle_flow_attempt are all
# inherited from CharacterBase. Each _start_flow call passes a Callable that
# captures the attack-specific resume logic.


## Returns the correct base damage for the current attack scaled by the timing multiplier.
func _get_current_attack_damage() -> float:
	var base: float
	match attack_state:
		AttackState.SLASH_WINDUP, AttackState.SLASH_PAUSED, AttackState.SLASH_FINISH:
			base = slash_damage
		AttackState.THRUST_WINDUP, AttackState.THRUST_PAUSED, AttackState.THRUST_FINISH:
			base = thrust_damage
		AttackState.SPIN_WINDUP, AttackState.SPIN_PAUSED, AttackState.SPIN_FINISH:
			base = spin_damage
		_:
			base = slash_damage
	# attack_bonus from blacksmith upgrades is added flat before the timing multiplier.
	return (base + attack_bonus) * _current_attack_damage_multiplier


func _sync_slash_effect_facing() -> void:
	if slash_effect_root == null:
		return
	if facing_pivot != null and facing_pivot.is_ancestor_of(slash_effect_root):
		return
	var effect_scale: Vector2 = slash_effect_root.scale
	effect_scale.x = absf(effect_scale.x) * facing
	slash_effect_root.scale = effect_scale


# ── Flow window helpers ────────────────────────────────────────────────────────

## Returns the elapsed run time from RunManager, or 0 if not available.
func _get_run_elapsed() -> float:
	var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
	if rm != null and "time_elapsed" in rm:
		return rm.time_elapsed
	return 0.0


## Returns the window half-size for this attack frame, sampling the curve when
## one is assigned. curve_max_time is the run duration (seconds) that maps to x=1.
func _sample_window_half(curve: Curve, default_half: float, curve_max_time: float) -> float:
	if curve == null:
		return default_half
	var t := clampf(_get_run_elapsed() / maxf(curve_max_time, 1.0), 0.0, 1.0)
	return curve.sample_baked(t)


## Apply the facing variable to the sprite and all hitbox positions.
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	super()  # handles pivot scale or sprite flip_h + health_bar mirroring
	if facing_pivot != null:
		_sync_slash_effect_facing()
		return
	# No pivot: additionally mirror knight-specific nodes.
	if slash_hitbox != null:
		slash_hitbox.position = Vector2(_slash_hitbox_right_pos.x * facing, _slash_hitbox_right_pos.y)
	if thrust_hitbox != null:
		thrust_hitbox.position = Vector2(_thrust_hitbox_right_pos.x * facing, _thrust_hitbox_right_pos.y)
	_sync_slash_effect_facing()

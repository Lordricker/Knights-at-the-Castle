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
	## Shared state: a new attack's flow bar is filling while the previous swing's
	## *_FINISH animation keeps playing. The previous attack is interrupted only
	## when this bar resolves (see _commit_interrupt).
	INTERRUPT_WINDUP,
}

var attack_state: AttackState = AttackState.NONE
## Input action ("action1/2/3") of the attack currently overlapping in INTERRUPT_WINDUP.
var _pending_interrupt_action: StringName = &""
var lunge_active: bool = false
var _slash_effect_pending_hide: bool = false
# True from 2 frames after any attack's pause frame until the attack ends —
# player takes no damage or knockback (i-frames for the attack's commitment window).
var _attack_invincible: bool = false
var _spin_flow_checks_completed: int = 0

# ── Preparation ability state ───────────────────────────────────────────────────
## True only while the "buff" windup animation is playing — movement is locked.
var is_preparing: bool = false
## True while the post-preparation speed/damage-reduction buff is active.
var is_prepare_buff_active: bool = false
var _prepare_buff_time_remaining: float = 0.0
var _prepare_cooldown_remaining: float = 0.0
## Set by _unhandled_input when a click/tap lands on this knight's own hitbox;
## consumed (and cleared) by _handle_attack_input on the next physics frame.
var _prepare_click_pending: bool = false
## Drawn procedurally (no art dependency) — depletes right-to-left as the buff runs out.
var _prepare_bar_node: Node2D = null


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
@export var slash_flow_window_curve_max_time: float = 60.0
## Sound played when a slash begins.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash swing sound.
@export var slash_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the slash.
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD

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
@export var thrust_flow_window_curve_max_time: float = 60.0
## Sound played when a thrust begins.
@export var thrust_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var thrust_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the thrust swing sound.
@export var thrust_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the thrust.
@export var thrust_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD

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
@export var spin_flow_window_curve_max_time: float = 60.0
## Sound played when a spin begins.
@export var spin_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var spin_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the spin swing sound.
@export var spin_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the spin.
@export var spin_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
@export_group("")

# ── Preparation Ability ───────────────────────────────────────────────────────

@export_group("Preparation Ability")
## Flat movement-speed bonus applied while the post-preparation buff is active.
@export var prepare_speed_bonus: float = 40.0
## Fraction of incoming damage negated while the post-preparation buff is active.
@export_range(0.0, 1.0, 0.01) var prepare_damage_reduction: float = 0.25
## Seconds the speed/damage-reduction buff lasts after the "buff" animation finishes.
@export var prepare_buff_duration: float = 5.0
## Seconds after the buff ends before Preparation can be activated again.
@export var prepare_cooldown_duration: float = 1.0
## Background color of the buff-timer bar shown above the knight's head while the buff is active.
@export var prepare_bar_background_color: Color = Color(0.06, 0.06, 0.06, 0.75)
## Foreground (fill) color of the buff-timer bar.
@export var prepare_bar_foreground_color: Color = Color(1.0, 0.85, 0.2, 1.0)
## How far above this character's origin (in pixels) the bar is drawn.
@export var prepare_bar_height_above_origin: float = 70.0
## Width of the buff-timer bar, in pixels.
@export var prepare_bar_width: float = 40.0
## Height of the buff-timer bar, in pixels.
@export var prepare_bar_height: float = 6.0
@export_group("")

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

var _slash_swing_audio: AudioStreamPlayer2D = null
var _thrust_swing_audio: AudioStreamPlayer2D = null
var _spin_swing_audio: AudioStreamPlayer2D = null


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
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)
	_thrust_swing_audio = _make_sfx_player(thrust_swing_sound, thrust_swing_sound_volume_db)
	_spin_swing_audio = _make_sfx_player(spin_swing_sound, spin_swing_sound_volume_db)
	_setup_prepare_bar()


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = (attack_state == AttackState.SLASH_PAUSED
						or attack_state == AttackState.THRUST_PAUSED
						or attack_state == AttackState.SPIN_PAUSED
						or attack_state == AttackState.INTERRUPT_WINDUP)
	var in_finish: bool = (attack_state == AttackState.SLASH_FINISH
						or attack_state == AttackState.THRUST_FINISH
						or attack_state == AttackState.SPIN_FINISH)

	var speed_mult: float = ATTACK_MOVE_MULT if (in_pause or in_finish) else 1.0

	var dir_x: float = _get_axis("move_left", "move_right")
	var dir_y: float = _get_axis("move_up", "move_down")

	if is_preparing:
		# Locked in place for the whole "buff" windup animation.
		velocity.x = 0.0
		velocity.y = 0.0
	else:
		var effective_speed: float = move_speed + speed_bonus + (prepare_speed_bonus if is_prepare_buff_active else 0.0)
		velocity.x = dir_x * effective_speed * speed_mult
		velocity.y = dir_y * effective_speed * speed_mult

	# Facing: driven purely by input direction.
	# Lock facing during thrust FINISH, and while preparing, so direction can't flip.
	var _thrust_finishing: bool = (attack_state == AttackState.THRUST_FINISH)
	if not _action_pressed("face_lock") and not _thrust_finishing and not is_preparing:
		if dir_x > 0.0:
			_set_facing(1.0)
		elif dir_x < 0.0:
			_set_facing(-1.0)

	_update_animation(dir_x, dir_y)
	_handle_attack_input()


func _physics_process(delta: float) -> void:
	super(delta)
	# Smooth lunge: applied every physics frame while lunge is active.
	if lunge_active:
		global_position.x += facing * thrust_lunge_speed * delta
	_update_prepare_timers(delta)


func _update_prepare_timers(delta: float) -> void:
	if is_prepare_buff_active:
		_prepare_buff_time_remaining -= delta
		if _prepare_buff_time_remaining <= 0.0:
			is_prepare_buff_active = false
			_prepare_cooldown_remaining = prepare_cooldown_duration
	elif _prepare_cooldown_remaining > 0.0:
		_prepare_cooldown_remaining -= delta
	if _prepare_bar_node != null:
		_prepare_bar_node.visible = is_prepare_buff_active
		if is_prepare_buff_active:
			_prepare_bar_node.queue_redraw()


## Creates the procedural buff-timer bar drawn above the knight's head. No art
## dependency — fully described by the prepare_bar_* Inspector fields.
func _setup_prepare_bar() -> void:
	_prepare_bar_node = Node2D.new()
	_prepare_bar_node.z_as_relative = false
	_prepare_bar_node.z_index = 100
	_prepare_bar_node.visible = false
	add_child(_prepare_bar_node)
	_prepare_bar_node.draw.connect(_on_prepare_bar_draw)


## Draws the background bar plus a foreground fill that depletes right-to-left
## (fixed at the left edge, its right edge recedes leftward) as % of buff time remaining.
func _on_prepare_bar_draw() -> void:
	var top_left := Vector2(-prepare_bar_width / 2.0, -prepare_bar_height_above_origin)
	_prepare_bar_node.draw_rect(Rect2(top_left, Vector2(prepare_bar_width, prepare_bar_height)), prepare_bar_background_color)
	var ratio: float = clampf(_prepare_buff_time_remaining / maxf(prepare_buff_duration, 0.001), 0.0, 1.0)
	if ratio > 0.0:
		_prepare_bar_node.draw_rect(Rect2(top_left, Vector2(prepare_bar_width * ratio, prepare_bar_height)), prepare_bar_foreground_color)


func _update_animation(dir_x: float, dir_y: float) -> void:
	if has_network_animation_override():
		return
	# Attack animations own the sprite — hands off.
	if attack_state != AttackState.NONE:
		return

	# The "buff" preparation animation owns the sprite while locked in place.
	if is_preparing:
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

## Detects a click/tap landing directly on this knight's own hitbox, to activate
## Preparation. Checked here (rather than via the "action1" InputMap action) because
## LMB is also bound to "action1" (slash) — this lets us decide, before that action's
## just_pressed state is ever consumed, whether the click should be a Preparation
## activation instead of an attack.
func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return
	# Remote puppets (this instance mirrors another peer's character) must not react to
	# this machine's own mouse input — only a locally-driven instance reads live input.
	if use_input_override:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if disable_local_attack_input or attacks_locked or is_preparing or is_prepare_buff_active or attack_state != AttackState.NONE or _prepare_cooldown_remaining > 0.0:
		return
	if _is_point_in_own_hitbox(get_global_mouse_position()):
		_prepare_click_pending = true


func _activate_prepare() -> void:
	is_preparing = true
	is_prepare_buff_active = false
	animated_sprite.play(&"buff")
	animated_sprite.frame = 0


func _handle_attack_input() -> void:
	if is_preparing:
		_prepare_click_pending = false
		return
	if _try_begin_interrupt():
		return
	match attack_state:
		AttackState.NONE:
			if _prepare_click_pending:
				_prepare_click_pending = false
				_activate_prepare()
				return
			# Suppress new attacks while the player is at the blacksmith.
			if not attacks_locked:
				if _action_just_pressed("action1"):
					_start_slash_attack(false)
				elif _action_just_pressed("action2"):
					_start_thrust_attack(false)
				elif _action_just_pressed("action3"):
					_start_spin_attack(false)

		AttackState.SLASH_WINDUP:
			_handle_flow_attempt(&"action1")

		AttackState.SLASH_PAUSED:
			_handle_flow_attempt(&"action1")

		AttackState.THRUST_WINDUP:
			_handle_flow_attempt(&"action2")

		AttackState.THRUST_PAUSED:
			_handle_flow_attempt(&"action2")

		AttackState.SPIN_WINDUP:
			_handle_flow_attempt(&"action3")

		AttackState.SPIN_PAUSED:
			_handle_flow_attempt(&"action3")

		AttackState.INTERRUPT_WINDUP:
			_handle_flow_attempt(_pending_interrupt_action)


## True while an attack's *_FINISH animation is playing.
func _is_finish_state(s: AttackState) -> bool:
	return (s == AttackState.SLASH_FINISH
			or s == AttackState.THRUST_FINISH
			or s == AttackState.SPIN_FINISH)


## After a SUCCESS swing's white linger elapses, a fresh attack press starts that
## attack's flow bar right away while the current swing keeps playing. The current
## swing is cut off only when the new bar resolves. Returns true if started.
func _try_begin_interrupt() -> bool:
	if attacks_locked or not _is_finish_state(attack_state):
		return false
	if not flow_finish_interruptible():
		return false
	if _action_just_pressed("action1"):
		_reset_attack_runtime_state()
		_pending_interrupt_action = &"action1"
		_start_slash_attack(true)
		return true
	if _action_just_pressed("action2"):
		_reset_attack_runtime_state()
		_pending_interrupt_action = &"action2"
		_start_thrust_attack(true)
		return true
	if _action_just_pressed("action3"):
		_reset_attack_runtime_state()
		_pending_interrupt_action = &"action3"
		_start_spin_attack(true)
		return true
	return false


func _commit_interrupt(anim_name: String, resume_frame: int, next_state: AttackState) -> void:
	_pending_interrupt_action = &""
	_finish_attack(anim_name, resume_frame, next_state)


func _start_slash_attack(as_interrupt: bool) -> void:
	var _sh := _sample_window_half(slash_flow_window_size_curve,
			slash_flow_window_half_size, slash_flow_window_curve_max_time)
	var on_res := func(mult: float) -> void:
		_current_attack_damage_multiplier = mult
		if as_interrupt:
			_commit_interrupt("slash", SLASH_PAUSE_FRAME, AttackState.SLASH_FINISH)
		else:
			_finish_attack("slash", SLASH_PAUSE_FRAME, AttackState.SLASH_FINISH)
	if as_interrupt:
		attack_state = AttackState.INTERRUPT_WINDUP
		_current_attack_damage_multiplier = 1.0
		start_interrupt_flow(&"slash", on_res,
			slash_flow_fill_duration, slash_flow_miss_multiplier,
			slash_flow_window_center, _sh, slash_flow_window_random_range)
	else:
		_begin_attack("slash", AttackState.SLASH_WINDUP)
		_start_flow(&"slash", on_res,
			slash_flow_fill_duration, slash_flow_miss_multiplier,
			slash_flow_window_center, _sh, slash_flow_window_random_range)


func _start_thrust_attack(as_interrupt: bool) -> void:
	var _th := _sample_window_half(thrust_flow_window_size_curve,
			thrust_flow_window_half_size, thrust_flow_window_curve_max_time)
	var on_res := func(mult: float) -> void:
		_current_attack_damage_multiplier = mult
		if as_interrupt:
			_commit_interrupt("thrust", THRUST_PAUSE_FRAME, AttackState.THRUST_FINISH)
		else:
			_finish_attack("thrust", THRUST_PAUSE_FRAME, AttackState.THRUST_FINISH)
	if as_interrupt:
		attack_state = AttackState.INTERRUPT_WINDUP
		_current_attack_damage_multiplier = 1.0
		start_interrupt_flow(&"thrust", on_res,
			thrust_flow_fill_duration, thrust_flow_miss_multiplier,
			thrust_flow_window_center, _th, thrust_flow_window_random_range)
	else:
		_begin_attack("thrust", AttackState.THRUST_WINDUP)
		_start_flow(&"thrust", on_res,
			thrust_flow_fill_duration, thrust_flow_miss_multiplier,
			thrust_flow_window_center, _th, thrust_flow_window_random_range)


func _start_spin_attack(as_interrupt: bool) -> void:
	if as_interrupt:
		attack_state = AttackState.INTERRUPT_WINDUP
		_current_attack_damage_multiplier = 1.0
		_spin_flow_checks_completed = 0
		_start_spin_flow_check(true, true)
	else:
		_begin_attack("spin", AttackState.SPIN_WINDUP)
		_start_spin_flow_check()


## Returns a stats dictionary consumed by character_description_panel.gd.
## Call get_character_stats() on the instantiated scene to read current Inspector values.
func get_character_stats() -> Dictionary:
	return {
		"display_name": display_name,
		"max_health":   max_health,
		"move_speed":   move_speed,
		"knockback_friction": knockback_friction,
		"action1": {"name": "[ J ] Double Slash    ",  "damage": slash_damage,  "knockback": slash_knockback_force},
		"action2": {"name": "[ K ] Lunging Thrust   	", "damage": thrust_damage, "knockback": thrust_knockback_force},
		"action3": {"name": "[ L ] Lawnmower",   "damage": spin_damage,   "knockback": spin_knockback_force},
	}


## Disable hitboxes and reset attack state immediately on death,
## so a mid-animation attack cannot keep dealing damage after the poof.
func die() -> void:
	attack_state = AttackState.NONE
	_pending_interrupt_action = &""
	_reset_attack_runtime_state()
	_stop_flow()
	is_preparing = false
	is_prepare_buff_active = false
	_prepare_buff_time_remaining = 0.0
	_prepare_cooldown_remaining = 0.0
	_prepare_click_pending = false
	if _prepare_bar_node != null:
		_prepare_bar_node.hide()
	super()

## Block incoming damage during an attack's i-frame window, and reduce it while the
## Preparation buff is active.
func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if _attack_invincible:
		return
	if is_prepare_buff_active:
		amount *= (1.0 - prepare_damage_reduction)
	super(amount, flow_success, weapon_type)


## Block incoming knockback during an attack's i-frame window.
func apply_knockback(source_position: Vector2, force: float) -> void:
	if _attack_invincible:
		return
	super(source_position, force)

## Reset all attack state on respawn so the player does not resume mid-swing.
func revive(at: Vector2) -> void:
	attack_state = AttackState.NONE
	_pending_interrupt_action = &""
	_reset_attack_runtime_state()
	_stop_flow()
	is_preparing = false
	is_prepare_buff_active = false
	_prepare_buff_time_remaining = 0.0
	_prepare_cooldown_remaining = 0.0
	_prepare_click_pending = false
	super(at)


## Disables every attack hitbox and clears per-swing runtime bookkeeping.
## Does NOT touch flow state (callers clear the bar via _stop_flow() when needed).
func _reset_attack_runtime_state() -> void:
	lunge_active = false
	_attack_invincible = false
	_spin_flow_checks_completed = 0
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	_set_hitbox(spin_hitbox, false)
	_set_slash_effect_sprite(false)


func _begin_attack(anim_name: String, next_state: AttackState) -> void:
	attack_state = next_state
	_current_attack_damage_multiplier = 1.0
	_spin_flow_checks_completed = 0
	_stop_flow()
	animated_sprite.play(anim_name)
	animated_sprite.frame = 0


func _start_spin_flow_check(allow_immediate: bool = false, is_interrupt: bool = false) -> void:
	var _half := _sample_window_half(spin_flow_window_size_curve,
			spin_flow_window_half_size, spin_flow_window_curve_max_time)
	_start_flow(&"spin",
		func(mult: float):
			_current_attack_damage_multiplier = minf(_current_attack_damage_multiplier, mult)
			_spin_flow_checks_completed += 1
			if is_interrupt:
				# First interrupt check resolved: previous swing ends, spin takes over.
				_pending_interrupt_action = &""
			if _spin_flow_checks_completed < SPIN_FLOW_CHECK_COUNT:
				attack_state = AttackState.SPIN_PAUSED
				animated_sprite.play("spin")
				animated_sprite.frame = SPIN_PAUSE_FRAME
				animated_sprite.pause()
				call_deferred("_start_spin_flow_check", true)
				return
			_finish_attack("spin", SPIN_PAUSE_FRAME, AttackState.SPIN_FINISH),
		spin_flow_fill_duration, spin_flow_miss_multiplier,
		spin_flow_window_center, _half, spin_flow_window_random_range)

	if allow_immediate:
		_flow_can_resolve = true


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
	# Remote puppet fallback: when this character is the host's slot viewed on the
	# joiner, attack_state is always NONE (input is never processed here).
	# Infer the attack from animation name so swing sounds still play.
	if attack_state == AttackState.NONE:
		match animated_sprite.animation:
			&"slash":
				if f in slash_swing_sound_frames:
					_play_sfx(_slash_swing_audio)
			&"thrust":
				if f in thrust_swing_sound_frames:
					_play_sfx(_thrust_swing_audio)
			&"spin":
				if f in spin_swing_sound_frames:
					_play_sfx(_spin_swing_audio)
	else:
		# I-frames: 2 frames after the active attack's pause frame, for the rest of the swing.
		var pause_frame := _current_attack_pause_frame()
		if pause_frame >= 0 and f >= pause_frame + 2:
			_attack_invincible = true
	match attack_state:
		AttackState.SLASH_WINDUP:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)
			if f >= SLASH_PAUSE_FRAME:
				attack_state = AttackState.SLASH_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.SLASH_PAUSED:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)

		AttackState.SLASH_FINISH:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)

		AttackState.THRUST_WINDUP:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f in thrust_swing_sound_frames:
				_play_sfx(_thrust_swing_audio)
			if f >= THRUST_PAUSE_FRAME:
				attack_state = AttackState.THRUST_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.THRUST_PAUSED:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f in thrust_swing_sound_frames:
				_play_sfx(_thrust_swing_audio)

		AttackState.THRUST_FINISH:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f in thrust_swing_sound_frames:
				_play_sfx(_thrust_swing_audio)
			if f == THRUST_LUNGE_START_FRAME:
				lunge_active = true
			elif f > THRUST_LUNGE_END_FRAME:
				lunge_active = false

		AttackState.SPIN_WINDUP:
			# Hitbox frames are past the pause point, so they only fire in SPIN_FINISH.
			if f in spin_swing_sound_frames:
				_play_sfx(_spin_swing_audio)
			if f >= SPIN_PAUSE_FRAME:
				attack_state = AttackState.SPIN_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.SPIN_PAUSED:
			if f in spin_swing_sound_frames:
				_play_sfx(_spin_swing_audio)
			# waiting for flow input; hitbox not active until SPIN_FINISH

		AttackState.SPIN_FINISH:
			if f in spin_swing_sound_frames:
				_play_sfx(_spin_swing_audio)
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
			_reset_attack_runtime_state()
			_stop_flow()
			animated_sprite.play("idle")
		AttackState.NONE:
			pass
		_:
			# Attack animation ended while still in a windup / paused / interrupt
			# state — the normal pause→resolve path was skipped (frame-skip on a lag
			# spike, or external interference). If a flow bar is still live, leave it
			# for _update_flow to resolve; otherwise force a clean idle so the knight
			# never hangs mid-swing.
			if not is_flow_busy():
				attack_state = AttackState.NONE
				_pending_interrupt_action = &""
				_reset_attack_runtime_state()
				_stop_flow()
				animated_sprite.play("idle")

	if is_preparing and animated_sprite.animation == &"buff":
		is_preparing = false
		is_prepare_buff_active = true
		_prepare_buff_time_remaining = prepare_buff_duration
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
	EnemyBase.player_hit(body, player_slot, _get_current_attack_damage(), flow_success, spin_weapon_type)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, spin_knockback_force)
	# Joiner: enemy take_damage returns early locally — forward the hit to the host.
	if GameManager.session_id != "" and not GameManager.is_host:
		var eid: int = int(body.get_meta(&"spawn_id", -1))
		if eid >= 0:
			WebRTCManager.send_reliable({
				"t":   "melee_hit",
				"eid": eid,
				"dmg": _get_current_attack_damage(),
				"kbf": spin_knockback_force,
				"kbx": global_position.x,
				"kby": global_position.y,
				"s":   1 if flow_success else 0,
				"wt":  int(spin_weapon_type),
			})


## Knockback force for the attack in progress. Mirrors the selection in
## _apply_hit_body so hurtbox-routed hits (dragon, skeleton knight) knock back the
## same as body_entered hits. Read by HurtBox when forwarding a joiner's hit.
func _get_current_knockback_force() -> float:
	match attack_state:
		AttackState.THRUST_WINDUP, AttackState.THRUST_PAUSED, AttackState.THRUST_FINISH:
			return thrust_knockback_force
		AttackState.SPIN_WINDUP, AttackState.SPIN_PAUSED, AttackState.SPIN_FINISH:
			return spin_knockback_force
		_:
			return slash_knockback_force


## Whether the attack in progress landed its flow window. Read by HurtBox so
## hurtbox-routed hits (dragon, skeleton knight) get the same crit FX/audio as
## body_entered hits.
func _get_current_flow_success() -> bool:
	return _current_attack_damage_multiplier >= 1.0


func _apply_hit_body(body: Node2D) -> void:
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	var kforce: float
	var wtype: WeaponType.WeaponType
	match attack_state:
		AttackState.THRUST_WINDUP, AttackState.THRUST_PAUSED, AttackState.THRUST_FINISH:
			kforce = thrust_knockback_force
			wtype = thrust_weapon_type
		_:
			kforce = slash_knockback_force
			wtype = slash_weapon_type
	EnemyBase.player_hit(body, player_slot, _get_current_attack_damage(), flow_success, wtype)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, kforce)
	# Joiner: enemy take_damage returns early locally — forward the hit to the host.
	if GameManager.session_id != "" and not GameManager.is_host:
		var eid: int = int(body.get_meta(&"spawn_id", -1))
		if eid >= 0:
			WebRTCManager.send_reliable({
				"t":   "melee_hit",
				"eid": eid,
				"dmg": _get_current_attack_damage(),
				"kbf": kforce,
				"kbx": global_position.x,
				"kby": global_position.y,
				"s":   1 if flow_success else 0,
				"wt":  int(wtype),
			})


## Enable or disable an Area2D hitbox.
## Always deferred so this is safe to call from body_entered / frame_changed signals.
func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if not is_instance_valid(box):
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


## Returns the pause frame for whichever attack is currently active, or -1 if none.
func _current_attack_pause_frame() -> int:
	match attack_state:
		AttackState.SLASH_WINDUP, AttackState.SLASH_PAUSED, AttackState.SLASH_FINISH:
			return SLASH_PAUSE_FRAME
		AttackState.THRUST_WINDUP, AttackState.THRUST_PAUSED, AttackState.THRUST_FINISH:
			return THRUST_PAUSE_FRAME
		AttackState.SPIN_WINDUP, AttackState.SPIN_PAUSED, AttackState.SPIN_FINISH:
			return SPIN_PAUSE_FRAME
		_:
			return -1


func _sync_slash_effect_facing() -> void:
	if slash_effect_root == null:
		return
	if facing_pivot != null and facing_pivot.is_ancestor_of(slash_effect_root):
		return
	var effect_scale: Vector2 = slash_effect_root.scale
	effect_scale.x = absf(effect_scale.x) * facing
	slash_effect_root.scale = effect_scale


# ── Flow window helpers ────────────────────────────────────────────────────────

## Returns the effective elapsed run time used to sample flow window size curves.
## Subtracts flow_time_offset so a +Flow upgrade resets the curve to the start.
func _get_run_elapsed() -> float:
	var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
	if rm != null and "time_elapsed" in rm:
		return maxf(0.0, float(rm.time_elapsed) - flow_time_offset)
	return 0.0


## Returns the window half-size for this attack frame. The window now steps with
## the player's Flow pips: full size at 5 pips, shrinking 20% per lost pip and
## fully closed (no green window) at 0 pips. `curve` / `curve_max_time` are
## retained for signature compatibility but no longer used.
func _sample_window_half(_curve: Curve, default_half: float, _curve_max_time: float) -> float:
	var half := default_half * get_flow_window_scale()
	return 0.0 if half < 0.005 else half


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

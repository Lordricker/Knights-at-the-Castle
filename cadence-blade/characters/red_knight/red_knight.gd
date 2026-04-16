extends CharacterBase

# red_knight.gd — playable Red Knight character.
#
# INPUT ACTIONS (Project > Project Settings > Input Map):
#   "move_right" → D     "move_left" → A
#   "move_up"    → W     "move_down" → S
#   "slash"      → J     "thrust"    → K
#
# ANIMATIONS (AnimatedSprite2D SpriteFrames):
#   "idle"    — loop ON
#   "running" — loop ON
#   "slash"   — loop OFF
#   "thrust"  — loop OFF
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D
#   ├── CollisionShape2D
#   ├── SlashHitbox   (Area2D — wide rectangle, positioned at sword reach)
#   │   └── CollisionShape2D
#   ├── ThrustHitbox  (Area2D — tall narrow rectangle, positioned forward)
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

# ── Attack state machine ───────────────────────────────────────────────────────

enum AttackState {
	NONE,
	SLASH_WINDUP,
	SLASH_PAUSED,
	SLASH_FINISH,
	THRUST_WINDUP,
	THRUST_PAUSED,
	THRUST_FINISH,
}

var attack_state: AttackState = AttackState.NONE
var lunge_active: bool = false
var _slash_effect_pending_hide: bool = false


# ── Damage ────────────────────────────────────────────────────────────────────

@export_group("Combat Damage")
## Base damage dealt by a slash attack.
@export var slash_damage: float = 35.0
## Base damage dealt by a thrust attack.
@export var thrust_damage: float = 45.0


# ── Movement bounds (pixels — set to match your level art) ────────────────────

@export var x_min: float = -1000.0
@export var x_max: float = 1000.0
@export var y_min: float = -270.0
@export var y_max: float = 270.0

# ── Hitbox nodes ──────────────────────────────────────────────────────────────

## How hard the player's attacks knock enemies back.
@export var knockback_force: float = 400.0
## Pixels per second the Red Knight lunges forward during thrust frames 5–7.
@export var thrust_lunge_speed: float = 80.0

## Drag the FlowBar Node2D (with flow_timing_bar.gd) here in the Inspector.
## (Inherited from CharacterBase — assign in the Inspector.)

@onready var slash_hitbox: Area2D = find_child("SlashHitbox") as Area2D
@onready var thrust_hitbox: Area2D = find_child("ThrustHitbox") as Area2D
@onready var slash_effect_root: Node2D = _find_slash_effect_root()
@onready var slash_effect_sprite: Sprite2D = _find_slash_effect_sprite()
@onready var slash_effect_particles_down: CPUParticles2D = _find_slash_effect_particles("ParticalsDown")
@onready var slash_effect_particles_up: CPUParticles2D = _find_slash_effect_particles("ParticalsUp")

var _slash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _thrust_hitbox_right_pos: Vector2 = Vector2.ZERO

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
	_initialize_slash_effect()
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_slash_hit_body)
	if thrust_hitbox != null:
		thrust_hitbox.body_entered.connect(_on_thrust_hit_body)


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = (attack_state == AttackState.SLASH_PAUSED
						or attack_state == AttackState.THRUST_PAUSED)
	var in_finish: bool = (attack_state == AttackState.SLASH_FINISH
						or attack_state == AttackState.THRUST_FINISH)

	var speed_mult: float = ATTACK_MOVE_MULT if (in_pause or in_finish) else 1.0

	var dir_x: float = Input.get_axis("move_left", "move_right")
	var dir_y: float = Input.get_axis("move_up", "move_down")

	velocity.x = dir_x * move_speed * speed_mult
	velocity.y = dir_y * move_speed * speed_mult

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
			if Input.is_action_just_pressed("slash"):
				_begin_attack("slash", AttackState.SLASH_WINDUP)
			elif Input.is_action_just_pressed("thrust"):
				_begin_attack("thrust", AttackState.THRUST_WINDUP)

		AttackState.SLASH_PAUSED:
			_handle_flow_attempt(&"slash")

		AttackState.THRUST_PAUSED:
			_handle_flow_attempt(&"thrust")


## Reset all attack state on respawn so the player does not resume mid-swing.
func revive(at: Vector2) -> void:
	attack_state = AttackState.NONE
	lunge_active = false
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_stop_flow()
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	_set_slash_effect_sprite(false)
	super(at)


func _begin_attack(anim_name: String, next_state: AttackState) -> void:
	attack_state = next_state
	_current_attack_damage_multiplier = 1.0
	_stop_flow()
	animated_sprite.play(anim_name)
	animated_sprite.frame = 0


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
				_start_flow(&"slash", func(mult: float):
					_current_attack_damage_multiplier = mult
					_finish_attack("slash", SLASH_PAUSE_FRAME, AttackState.SLASH_FINISH))

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
				_start_flow(&"thrust", func(mult: float):
					_current_attack_damage_multiplier = mult
					_finish_attack("thrust", THRUST_PAUSE_FRAME, AttackState.THRUST_FINISH))

		AttackState.THRUST_PAUSED:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)

		AttackState.THRUST_FINISH:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f == THRUST_LUNGE_START_FRAME:
				lunge_active = true
			elif f > THRUST_LUNGE_END_FRAME:
				lunge_active = false


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASH_FINISH, AttackState.THRUST_FINISH:
			attack_state = AttackState.NONE
			lunge_active = false
			_current_attack_damage_multiplier = 1.0
			_stop_flow()
			_set_hitbox(slash_hitbox, false)
			_set_hitbox(thrust_hitbox, false)
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


func _apply_hit_body(body: Node2D) -> void:
	if body.has_method("take_damage"):
		body.take_damage(_get_current_attack_damage())
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


## Enable or disable an Area2D hitbox.
func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.monitoring = enabled
	box.monitorable = enabled


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
		_:
			base = slash_damage
	return base * _current_attack_damage_multiplier


func _sync_slash_effect_facing() -> void:
	if slash_effect_root == null:
		return
	if facing_pivot != null and facing_pivot.is_ancestor_of(slash_effect_root):
		return
	var effect_scale: Vector2 = slash_effect_root.scale
	effect_scale.x = absf(effect_scale.x) * facing
	slash_effect_root.scale = effect_scale


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

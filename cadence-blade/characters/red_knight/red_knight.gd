extends CharacterBase

# red_knight.gd — playable Red Knight character.
#
# INPUT ACTIONS (add these in Project > Project Settings > Input Map):
#   "move_right"    → D key
#   "move_left"     → A key
#   "move_up"       → W key  (switch to back lane)
#   "move_down"     → S key  (switch to forward lane)
#   "slash"         → J key
#   "thrust"        → K key
#
# ANIMATIONS (set up in the AnimatedSprite2D SpriteFrames resource):
#   "idle"    — loops
#   "running" — loops
#   "slash"   — no loop; pause triggers at frame SLASH_PAUSE_FRAME (2)
#   "thrust"  — no loop; pause triggers at frame THRUST_PAUSE_FRAME (3)

# ── Constants ─────────────────────────────────────────────────────────────────

const SLASH_PAUSE_FRAME: int = 2
const THRUST_PAUSE_FRAME: int = 3
const ATTACK_MOVE_MULT: float = 0.3

# ── Attack state machine ───────────────────────────────────────────────────────

enum AttackState {
	NONE,
	SLASH_WINDUP,   # animation playing toward pause frame
	SLASH_PAUSED,   # frozen at pause frame, waiting for second J
	SLASH_FINISH,   # playing out the rest of the animation
	THRUST_WINDUP,
	THRUST_PAUSED,
	THRUST_FINISH,
}

var attack_state: AttackState = AttackState.NONE

# ── Level bounds (set these to match your level's walkable X range) ────────────

@export var lane_x_min: float = -480.0
@export var lane_x_max: float = 480.0


func _ready() -> void:
	super()
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play("idle")


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = attack_state == AttackState.SLASH_PAUSED \
						or attack_state == AttackState.THRUST_PAUSED

	var speed_mult: float = ATTACK_MOVE_MULT if in_pause else 1.0

	# Horizontal movement
	var dir_x: float = Input.get_axis("move_left", "move_right")
	velocity.x = dir_x * move_speed * speed_mult

	# Lane switching — only when not in an attack pause
	if not in_pause:
		if Input.is_action_just_pressed("move_up"):
			change_lane(-1)
		elif Input.is_action_just_pressed("move_down"):
			change_lane(1)

	# Clamp horizontal position to the lane bounds
	position.x = clampf(position.x + velocity.x * get_physics_process_delta_time(),
						lane_x_min, lane_x_max)
	# Zero out X so move_and_slide doesn't double-apply it after the clamp
	# (we applied it manually above)
	velocity.x = 0.0

	# Facing direction — only update outside of attack pauses
	if not in_pause and dir_x != 0.0:
		animated_sprite.flip_h = dir_x < 0.0

	_update_animation(dir_x)
	_handle_attack_input()


func _update_animation(dir_x: float) -> void:
	# Attack animations own the sprite; don't touch them here.
	if attack_state != AttackState.NONE:
		return

	var moving: bool = dir_x != 0.0 \
		or Input.is_action_pressed("move_up") \
		or Input.is_action_pressed("move_down")

	if moving:
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
			if Input.is_action_just_pressed("slash"):
				_finish_attack("slash", SLASH_PAUSE_FRAME, AttackState.SLASH_FINISH)

		AttackState.THRUST_PAUSED:
			if Input.is_action_just_pressed("thrust"):
				_finish_attack("thrust", THRUST_PAUSE_FRAME, AttackState.THRUST_FINISH)


func _begin_attack(anim_name: String, next_state: AttackState) -> void:
	attack_state = next_state
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
	match attack_state:
		AttackState.SLASH_WINDUP:
			if animated_sprite.frame >= SLASH_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.SLASH_PAUSED

		AttackState.THRUST_WINDUP:
			if animated_sprite.frame >= THRUST_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.THRUST_PAUSED


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASH_FINISH, AttackState.THRUST_FINISH:
			attack_state = AttackState.NONE
			animated_sprite.play("idle")

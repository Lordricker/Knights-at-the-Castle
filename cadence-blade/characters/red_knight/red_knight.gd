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
#   └── ThrustHitbox  (Area2D — tall narrow rectangle, positioned forward)
#       └── CollisionShape2D

# ── Constants ─────────────────────────────────────────────────────────────────

const SLASH_PAUSE_FRAME: int = 2
const THRUST_PAUSE_FRAME: int = 3
const ATTACK_MOVE_MULT: float = 0.3

# Slash hitbox active on frames 3 and 5.
const SLASH_HITBOX_FRAMES: Array[int] = [3, 5]
# Thrust hitbox active on frames 5 and 6.
const THRUST_HITBOX_FRAMES: Array[int] = [5, 6]

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

## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

# ── Movement bounds (pixels — set to match your level art) ────────────────────

@export var x_min: float = -1000.0
@export var x_max: float = 1000.0
@export var y_min: float = -270.0
@export var y_max: float = 270.0

# ── Hitbox nodes ──────────────────────────────────────────────────────────────

## How hard the player's attacks knock enemies back.
@export var knockback_force: float = 400.0

@onready var slash_hitbox: Area2D = $SlashHitbox
@onready var thrust_hitbox: Area2D = $ThrustHitbox


func _ready() -> void:
	super()
	scale.x = 1.0  # never flip the CharacterBody2D root
	if animated_sprite == null:
		return
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play("idle")
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(thrust_hitbox, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_hit_body)
	if thrust_hitbox != null:
		thrust_hitbox.body_entered.connect(_on_hit_body)


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = (attack_state == AttackState.SLASH_PAUSED
						or attack_state == AttackState.THRUST_PAUSED)
	var in_finish: bool = (attack_state == AttackState.SLASH_FINISH
						or attack_state == AttackState.THRUST_FINISH)

	# Locked out entirely during the finish animation.
	if in_finish:
		velocity = Vector2.ZERO
		_handle_attack_input()
		return

	var speed_mult: float = ATTACK_MOVE_MULT if in_pause else 1.0

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
	# Clamp to walkable area after move_and_slide.
	position.x = clampf(position.x, x_min, x_max)
	position.y = clampf(position.y, y_min, y_max)


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
	var f: int = animated_sprite.frame
	match attack_state:
		AttackState.SLASH_WINDUP:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)
			if f >= SLASH_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.SLASH_PAUSED

		AttackState.SLASH_PAUSED:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)

		AttackState.SLASH_FINISH:
			_set_hitbox(slash_hitbox, f in SLASH_HITBOX_FRAMES)

		AttackState.THRUST_WINDUP:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)
			if f >= THRUST_PAUSE_FRAME:
				animated_sprite.pause()
				attack_state = AttackState.THRUST_PAUSED

		AttackState.THRUST_PAUSED:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)

		AttackState.THRUST_FINISH:
			_set_hitbox(thrust_hitbox, f in THRUST_HITBOX_FRAMES)


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASH_FINISH, AttackState.THRUST_FINISH:
			attack_state = AttackState.NONE
			_set_hitbox(slash_hitbox, false)
			_set_hitbox(thrust_hitbox, false)
			animated_sprite.play("idle")


## Called when any active hitbox touches an enemy body.
func _on_hit_body(body: Node2D) -> void:
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


## Enable or disable an Area2D hitbox.
func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.monitoring = enabled
	box.monitorable = enabled


## Apply the facing variable to the sprite and all hitbox positions.
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	animated_sprite.flip_h = facing < 0.0
	if slash_hitbox != null:
		slash_hitbox.position.x = -slash_hitbox.position.x
	if thrust_hitbox != null:
		thrust_hitbox.position.x = -thrust_hitbox.position.x


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()

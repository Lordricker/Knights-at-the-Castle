extends EnemyBase

# black_knight.gd — Elite enemy: Black Knight.
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D  (animations: "running", "slash")
#   ├── CollisionShape2D
#   └── SlashHitbox  (Area2D)
#       └── CollisionShape2D

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Movement")
## Horizontal walk speed in pixels per second.
@export var walk_speed: float = 80.0
## How far above and below the start Y the knight bounces (0 = no bounce).
@export var y_oscillation_range: float = 60.0
## How many full bounces per second.
@export var y_oscillation_speed: float = 0.5

@export_group("Combat")
## Damage dealt per slash hit.
@export var slash_damage: float = 20.0
## Which frames of the slash animation activate the hitbox.
@export var slash_hitbox_frames: Array[int] = [2, 6]
## Pause the slash animation on this frame, waiting for the next phase.
@export var slash_pause_frame: int = 4

@export_group("Health")
## Starting hit points.
@export var starting_hp: float = 150.0

# ── Internal state ─────────────────────────────────────────────────────────────

enum SlashState { NONE, WINDUP, PAUSED, FINISH }

var slash_state: SlashState = SlashState.NONE
var _start_y: float = 0.0
var _time: float = 0.0
## Direction of travel: 1 = right, -1 = left.
var _dir: float = -1.0

@onready var slash_hitbox: Area2D = $SlashHitbox


func _ready() -> void:
	max_health = starting_hp
	attack_damage = slash_damage
	super()
	_start_y = position.y
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	_set_hitbox(slash_hitbox, false)
	animated_sprite.play("running")


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(delta: float) -> void:
	if slash_state == SlashState.FINISH or slash_state == SlashState.PAUSED:
		velocity = Vector2.ZERO
		return

	_time += delta

	# Horizontal walk — bounce off x bounds (reuse EnemyBase attack_range as patrol bounds).
	velocity.x = walk_speed * _dir

	# Y oscillation using a sine wave.
	if y_oscillation_range > 0.0:
		var target_y: float = _start_y + sin(_time * y_oscillation_speed * TAU) * y_oscillation_range
		# Drive Y by setting velocity so move_and_slide handles it.
		velocity.y = (target_y - position.y) / delta

	# Face direction of travel.
	animated_sprite.flip_h = _dir < 0.0

	# Reverse direction at level bounds (use parent attack_range export as half-width patrol).
	if position.x <= -attack_range and _dir < 0.0:
		_dir = 1.0
	elif position.x >= attack_range and _dir > 0.0:
		_dir = -1.0

	# Periodically trigger a slash (every ~3 seconds).
	if fmod(_time, 3.0) < delta and slash_state == SlashState.NONE:
		_begin_slash()


func _begin_slash() -> void:
	slash_state = SlashState.WINDUP
	animated_sprite.play("slash")
	animated_sprite.frame = 0


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	var f: int = animated_sprite.frame
	match slash_state:
		SlashState.WINDUP:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)
			if f >= slash_pause_frame:
				animated_sprite.pause()
				slash_state = SlashState.PAUSED

		SlashState.PAUSED:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)

		SlashState.FINISH:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)


func _on_animation_finished() -> void:
	if slash_state == SlashState.FINISH:
		slash_state = SlashState.NONE
		_set_hitbox(slash_hitbox, false)
		animated_sprite.play("running")


# ── Hitbox helper ──────────────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.monitoring = enabled
	box.monitorable = enabled
	box.scale.x = -1.0 if animated_sprite.flip_h else 1.0

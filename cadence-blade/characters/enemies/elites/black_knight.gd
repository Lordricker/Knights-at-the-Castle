extends EnemyBase

# black_knight.gd — Elite enemy: Black Knight.
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D  (animations: "running", "slash")
#   ├── CollisionShape2D
#   ├── SlashHitbox   (Area2D — weapon hitbox, enabled on attack frames)
#   │   └── CollisionShape2D
#   └── DetectionZone (Area2D — triggers attack when player walks into it)
#       └── CollisionShape2D  (set width to represent attack range)

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Movement")
## Horizontal walk speed in pixels per second.
@export var walk_speed: float = 80.0

@export_group("Combat")
## Damage dealt per slash hit.
@export var slash_damage: float = 20.0
## Which frames of the slash animation activate the weapon hitbox.
@export var slash_hitbox_frames: Array[int] = [2, 6]
## How hard the black knight's slash knocks the player back.
@export var knockback_force: float = 300.0

@export_group("Health")
## Starting hit points.
@export var starting_hp: float = 150.0

@export_group("Debug")
## Enable to show all collision shapes in-game (works in editor/debug builds only).
@export var debug_show_collisions: bool = false

# ── Internal state ─────────────────────────────────────────────────────────────

enum SlashState { NONE, ATTACKING }

var slash_state: SlashState = SlashState.NONE

## 1.0 = facing right, -1.0 = facing left.
var facing: float = 1.0

@onready var slash_hitbox: Area2D = $SlashHitbox
@onready var detection_zone: Area2D = $DetectionZone


func _ready() -> void:
	max_health = starting_hp
	attack_damage = slash_damage
	super()
	if debug_show_collisions:
		get_tree().debug_collisions_hint = true
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	# Ensure detection zone is always active regardless of inspector state.
	detection_zone.monitoring = true
	scale.x = 1.0  # never flip the CharacterBody2D root
	_set_hitbox(slash_hitbox, false)
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_hit_body)
	animated_sprite.play("running")


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(_delta: float) -> void:
	# Poll the detection zone directly every frame — more reliable than signals.
	var bodies := detection_zone.get_overlapping_bodies()
	var in_range := bodies.size() > 0

	if in_range:
		target = bodies[0]

	# Locked during attack animation.
	if slash_state == SlashState.ATTACKING:
		velocity = Vector2.ZERO
		return

	# Player is in detection zone — stop and attack.
	if in_range:
		velocity = Vector2.ZERO
		_begin_slash()
		return

	# Walk toward world x = 0.
	target = null
	var dist: float = global_position.x
	if absf(dist) < 4.0:
		velocity.x = 0.0
	else:
		var dir: float = -signf(dist)
		velocity.x = walk_speed * dir
		# Face toward x = 0 (the direction we're walking).
		_set_facing(1.0 if dir > 0.0 else -1.0)

	# Y is handled by _constrain_to_path() in EnemyBase._physics_process.
	velocity.y = 0.0


func _physics_process(delta: float) -> void:
	super(delta)


func _begin_slash() -> void:
	slash_state = SlashState.ATTACKING
	animated_sprite.stop()  # interrupt walk animation immediately
	animated_sprite.play("slash")
	# Face toward the detected player.
	if target != null:
		if target.global_position.x > global_position.x:
			_set_facing(1.0)
		else:
			_set_facing(-1.0)


func _stop_attack() -> void:
	slash_state = SlashState.NONE
	_set_hitbox(slash_hitbox, false)
	animated_sprite.stop()
	animated_sprite.play("running")


# ── Frame / animation signals ──────────────────────────────────────────────────

func _on_frame_changed() -> void:
	if slash_state == SlashState.ATTACKING:
		_set_hitbox(slash_hitbox, animated_sprite.frame in slash_hitbox_frames)


func _on_animation_finished() -> void:
	if slash_state == SlashState.ATTACKING:
		# Poll again at animation end to decide whether to loop or stop.
		if detection_zone.get_overlapping_bodies().size() > 0:
			_begin_slash()
		else:
			_stop_attack()


# ── Hitbox helper ──────────────────────────────────────────────────────────────

func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if box == null:
		return
	box.monitoring = enabled
	box.monitorable = enabled


## Called when the slash hitbox touches the player body.
func _on_hit_body(body: Node2D) -> void:
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


## Apply the facing variable to the sprite and all hitbox/detection positions.
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	animated_sprite.flip_h = facing < 0.0
	if slash_hitbox != null:
		slash_hitbox.position.x = -slash_hitbox.position.x
	if detection_zone != null:
		detection_zone.position.x = -detection_zone.position.x


## Only flip when direction actually changes to avoid double-negation.
func _set_facing(new_facing: float) -> void:
	if new_facing == facing:
		return
	facing = new_facing
	_apply_facing()

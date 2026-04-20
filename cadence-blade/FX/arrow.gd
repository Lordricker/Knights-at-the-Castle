class_name Arrow
extends Area2D

# arrow.gd -- Self-propelling projectile fired by the GreenArcher.
#
# USAGE:
#   1. Instantiate the arrow scene.
#   2. Call configure() with spawn position, direction, and combat values
#      BEFORE calling add_child() on the parent scene.
#   3. Arrow._ready() applies the position and begins movement automatically.
#
# SCENE STRUCTURE:
#   Arrow (Area2D, this script)
#   +-- CollisionShape2D   (set collision_mask to match enemy layer)
#   +-- Sprite2D           (assign your arrow texture; rotation auto-applied)
#
# The arrow despawns when it hits an enemy body or its lifetime expires.

## Seconds before the arrow despawns automatically.
@export var lifetime: float = 2.0
## Downward acceleration in pixels/sec^2 applied every physics frame.
@export var drop_gravity: float = 0.0

var _velocity: Vector2 = Vector2.ZERO
var _damage: float = 0.0
var _knockback_force: float = 0.0
var _configured: bool = false
var _age: float = 0.0

@onready var _sprite: Sprite2D = find_child("Sprite2D") as Sprite2D


## Call this before add_child(). Sets spawn position and all combat values.
## Arrow._ready() reads these to initialize itself once in the scene tree.
func configure(spawn_pos: Vector2, direction: Vector2, speed: float,
		damage: float, knockback_force: float) -> void:
	_damage = damage
	_knockback_force = knockback_force
	_velocity = direction.normalized() * speed
	# Store the spawn position as the local position; _ready() will have a
	# parent by the time it runs, making global_position usable.
	global_position = spawn_pos
	_configured = true


func _ready() -> void:
	# Orient sprite to face the direction of travel.
	if _sprite != null and _velocity != Vector2.ZERO:
		rotation = _velocity.angle()
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if not _configured:
		return
	_age += delta
	if _age >= lifetime:
		queue_free()
		return
	_velocity.y += drop_gravity * delta
	global_position += _velocity * delta
	if _velocity != Vector2.ZERO:
		rotation = _velocity.angle()


func _on_body_entered(body: Node2D) -> void:
	if body.has_method("take_damage"):
		body.take_damage(_damage, true)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, _knockback_force)
	queue_free()

class_name Fireball
extends Area2D

# fireball.gd — Projectile fired by the GreenDragon.
#
# USAGE:
#   1. Instantiate the fireball scene.
#   2. Call configure() with spawn position, direction, damage, and lifetime
#      BEFORE calling add_child() on the parent scene.
#   3. Fireball._ready() begins movement and starts the expiration timer automatically.
#
# SCENE STRUCTURE:
#   Fireball (Area2D, this script)
#   ├── CollisionShape2D    (set collision_mask to hit player layer)
#   ├── ExpirationTimer     (Timer node — lifetime before auto-explode)
#   ├── TrailParticles      (CPUParticles2D — continuous trail while flying)
#   └── ExplosionParticles  (CPUParticles2D — one-shot burst on hit or expiry)
#
# The fireball explodes on impact with any Kill-group target, or when its
# lifetime expires. Explosion particles play before the node frees itself.

## Damage dealt to any Kill-group target on impact.
@export var damage: float = 30.0
## Knockback force applied to characters on impact.
@export var knockback_force: float = 200.0
## Seconds before the fireball auto-explodes if it hasn't hit anything.
@export var lifetime: float = 3.0

var _velocity: Vector2 = Vector2.ZERO
var _configured: bool = false
var _exploding: bool = false

@onready var _trail: CPUParticles2D = find_child("TrailParticles") as CPUParticles2D
@onready var _explosion: CPUParticles2D = find_child("ExplosionParticles") as CPUParticles2D
@onready var _timer: Timer = $ExpirationTimer


## Call this before add_child(). Sets spawn position and all combat values.
func configure(spawn_pos: Vector2, direction: Vector2, speed: float,
		p_damage: float, p_knockback_force: float = 0.0, p_lifetime: float = 3.0) -> void:
	damage = p_damage
	knockback_force = p_knockback_force
	lifetime = p_lifetime
	_velocity = direction.normalized() * speed
	global_position = spawn_pos
	_configured = true
	# If already in the tree (buildup pattern: add_child before configure), start now.
	if is_inside_tree():
		_start_active_state()


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	_timer.one_shot = true
	_timer.timeout.connect(_on_expired)
	# If configure() was already called before add_child(), start immediately.
	if _configured:
		_start_active_state()


## Starts the expiration timer and trail particles.
## Called from _ready() when pre-configured, or from configure() when already in tree.
func _start_active_state() -> void:
	_timer.wait_time = lifetime
	_timer.start()
	if _trail != null:
		_trail.emitting = true


func _physics_process(delta: float) -> void:
	if not _configured or _exploding:
		return
	global_position += _velocity * delta


# ── Explosion ──────────────────────────────────────────────────────────────────

func _explode() -> void:
	if _exploding:
		return
	_exploding = true
	_timer.stop()
	_velocity = Vector2.ZERO
	if _trail != null:
		_trail.emitting = false
	if _explosion != null:
		_explosion.emitting = true
		# Wait for explosion particles to finish, then free the scene.
		get_tree().create_timer(_explosion.lifetime + 0.1).timeout.connect(
			queue_free, CONNECT_ONE_SHOT)
	else:
		queue_free()


func _on_expired() -> void:
	_explode()


# ── Collision ──────────────────────────────────────────────────────────────────

func _on_body_entered(body: Node2D) -> void:
	if _exploding:
		return
	if body.has_method("take_damage"):
		body.take_damage(damage)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)
	_explode()


func _on_area_entered(area: Area2D) -> void:
	if _exploding:
		return
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(damage)
	_explode()

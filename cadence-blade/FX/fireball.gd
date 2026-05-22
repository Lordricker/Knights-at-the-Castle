class_name Fireball
extends Area2D

# fireball.gd — Projectile fired by the GreenDragon.
#
# USAGE:
#   1. Attach this script to the root Area2D of Fireball.tscn.
#   2. Call configure() with spawn position, direction, damage, and lifetime
#      BEFORE calling add_child() on the parent scene.
#   3. Fireball._ready() begins movement automatically.
#
## Flying trail particles — hidden when the fireball dies.
@export var trail_particles: CPUParticles2D
## One-shot explosion particles — played for 1 second after the fireball dies.
@export var explosion_particles: CPUParticles2D

var damage: float = 0.0
var knockback_force: float = 0.0
var lifetime: float = 3.0

var _velocity: Vector2 = Vector2.ZERO
var _configured: bool = false
var _exploding: bool = false


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
	# If configure() was already called before add_child(), start immediately.
	if _configured:
		_start_active_state()


## Starts the lifetime timer and trail particles.
## Called from _ready() when pre-configured, or from configure() when already in tree.
func _start_active_state() -> void:
	get_tree().create_timer(lifetime, false).timeout.connect(_on_expired, CONNECT_ONE_SHOT)
	if trail_particles != null:
		trail_particles.emitting = true


func _physics_process(delta: float) -> void:
	if not _configured or _exploding:
		return
	global_position += _velocity * delta


# ── Explosion ──────────────────────────────────────────────────────────────────

func _explode() -> void:
	if _exploding:
		return
	_exploding = true
	_velocity = Vector2.ZERO
	# Hide the trail so it doesn't keep emitting during the death linger.
	if trail_particles != null:
		trail_particles.hide()
	# Play the one-shot explosion and linger 1 second to let it finish.
	if explosion_particles != null:
		explosion_particles.restart()
	get_tree().create_timer(1.0, false).timeout.connect(queue_free, CONNECT_ONE_SHOT)


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

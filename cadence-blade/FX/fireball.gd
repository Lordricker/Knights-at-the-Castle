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
# SPLASH:
#   When splash_damage > 0 the fireball activates SplashZone (a wider Area2D,
#   disabled during flight) on impact. It damages every Kill-group target inside
#   the radius on contact and keeps catching newcomers for splash_duration
#   seconds before the fireball frees itself.
#
## Flying trail particles — hidden when the fireball dies.
@export var trail_particles: CPUParticles2D
## One-shot explosion particles — played for 1 second after the fireball dies.
@export var explosion_particles: CPUParticles2D
## Wider Area2D (kept disabled during flight) that deals area damage on impact.
@export var splash_zone: Area2D

@export_group("Weapon Type")
## Weapon type reported to the target when this fireball connects.
@export var weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.FIREBALL
@export_group("")

var damage: float = 0.0
var knockback_force: float = 0.0
var lifetime: float = 3.0
## Damage dealt to each Kill-group target caught by the impact splash (0 = no splash).
var splash_damage: float = 0.0
## Seconds the splash zone stays active after impact.
var splash_duration: float = 1.0
## Set to the node that fired this fireball so it never damages itself.
var shooter: Node = null

var _velocity: Vector2 = Vector2.ZERO
var _configured: bool = false
var _exploding: bool = false
## Instance IDs already damaged by the splash (also seeded with the direct-hit
## target so the epicentre isn't hit twice).
var _splash_hit: Dictionary = {}


## Call this before add_child(). Sets spawn position and all combat values.
func configure(spawn_pos: Vector2, direction: Vector2, speed: float,
		p_damage: float, p_knockback_force: float = 0.0, p_lifetime: float = 3.0,
		p_splash_damage: float = 0.0, p_splash_duration: float = 1.0) -> void:
	damage = p_damage
	knockback_force = p_knockback_force
	lifetime = p_lifetime
	splash_damage = p_splash_damage
	splash_duration = p_splash_duration
	_velocity = direction.normalized() * speed
	global_position = spawn_pos
	if _velocity != Vector2.ZERO:
		rotation = _velocity.angle()
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
		if _velocity != Vector2.ZERO:
			rotation = _velocity.angle()


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
	# Play the one-shot explosion particles.
	if explosion_particles != null:
		explosion_particles.restart()
	# Linger long enough for both the explosion particles and the splash window.
	var linger: float = 1.0
	if splash_damage > 0.0 and splash_zone != null:
		linger = maxf(linger, splash_duration)
		_activate_splash()
	get_tree().create_timer(linger, false).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _on_expired() -> void:
	_explode()


# ── Splash ─────────────────────────────────────────────────────────────────────

## Enables the wide SplashZone on impact, damages everything already inside, and
## keeps catching targets that wander in for splash_duration seconds.
func _activate_splash() -> void:
	# Hit the same layers the projectile does (players / castle).
	splash_zone.collision_mask = collision_mask
	if not splash_zone.body_entered.is_connected(_on_splash_body):
		splash_zone.body_entered.connect(_on_splash_body)
	if not splash_zone.area_entered.is_connected(_on_splash_area):
		splash_zone.area_entered.connect(_on_splash_area)
	splash_zone.monitoring = true

	# Wait one physics frame so overlaps are populated, then sweep them.
	await get_tree().physics_frame
	if not is_instance_valid(self) or not is_instance_valid(splash_zone):
		return
	for body in splash_zone.get_overlapping_bodies():
		_on_splash_body(body)
	for area in splash_zone.get_overlapping_areas():
		_on_splash_area(area)

	# Stop dealing damage once the window closes (the node frees itself shortly after).
	await get_tree().create_timer(maxf(0.05, splash_duration), false).timeout
	if is_instance_valid(splash_zone):
		splash_zone.monitoring = false


func _on_splash_body(body: Node2D) -> void:
	if body == shooter:
		return
	if not body.is_in_group(&"Kill"):
		return
	var id := body.get_instance_id()
	if _splash_hit.has(id):
		return
	_splash_hit[id] = true
	if body.has_method("take_damage"):
		body.take_damage(splash_damage, false, weapon_type)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)


func _on_splash_area(area: Area2D) -> void:
	if area == shooter or (shooter != null and shooter.is_ancestor_of(area)):
		return
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node == null:
		return
	var id := owner_node.get_instance_id()
	if _splash_hit.has(id):
		return
	_splash_hit[id] = true
	if owner_node.has_method("take_damage"):
		owner_node.take_damage(splash_damage, false, weapon_type)


# ── Collision ──────────────────────────────────────────────────────────────────

func _on_body_entered(body: Node2D) -> void:
	if _exploding:
		return
	if body == shooter:
		return
	# Only damage Kill-group targets (players, castle) — not other enemies.
	if not body.is_in_group(&"Kill"):
		return
	if body.has_method("take_damage"):
		body.take_damage(damage, false, weapon_type)
	if body.is_in_group(&"KillCharacter") and body.has_method("apply_knockback"):
		body.apply_knockback(global_position, knockback_force)
	# The direct-hit target already took the full hit — exclude it from the splash.
	_splash_hit[body.get_instance_id()] = true
	_explode()


func _on_area_entered(area: Area2D) -> void:
	if _exploding:
		return
	if area == shooter or (shooter != null and shooter.is_ancestor_of(area)):
		return
	if not area.is_in_group(&"Kill"):
		return
	var owner_node := area.get_parent()
	if owner_node != null and owner_node.has_method("take_damage"):
		owner_node.take_damage(damage, false, weapon_type)
	if owner_node != null:
		_splash_hit[owner_node.get_instance_id()] = true
	_explode()

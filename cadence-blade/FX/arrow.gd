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
#   +-- CPUParticles2D     (optional; tinted by combo streak via set_combo_color)
#
# The arrow despawns when it hits an enemy body or its lifetime expires.
# Pierce arrows pass through enemies and deal damage to all in their path.

## Emitted when the arrow despawns without having dealt damage to any enemy.
## Archer connects this to reset the combo streak.
signal missed
## Emitted each time the arrow registers a successful hit (body or hurtbox).
## Archer connects this to advance the combo streak.
signal enemy_hit

## Seconds before the arrow despawns automatically.
@export var lifetime: float = 2.0
## Downward acceleration in pixels/sec^2 applied every physics frame.
@export var drop_gravity: float = 0.0

@export_group("Weapon Type")
## Weapon type reported to the target when this arrow connects.
@export var weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.ARROW
@export_group("")

@export_group("Combo Particle Colors")
## Particle color when the archer is on combo hit 1 (first streak hit).
@export var combo_color_1: Color = Color(1.0, 0.65, 0.0, 1.0)  # orange
## Particle color when the archer is on combo hit 2+ (full streak).
@export var combo_color_2: Color = Color(0.2, 0.8, 1.0, 1.0)   # cyan
@export_group("")

var _velocity: Vector2 = Vector2.ZERO
var _damage: float = 0.0
var _knockback_force: float = 0.0
var _flow_success: bool = false
var _configured: bool = false
var _age: float = 0.0
## When true the arrow passes through enemies and hits all in its path.
var pierce: bool = false
## Tracks which enemies have already been hit this flight (pierce mode).
var _hit_enemies: Array[Node] = []
## Set to true the first time any enemy is hit; used to decide whether to emit missed.
var _hit_any: bool = false
## Set to true by a HurtBox when it claims this arrow, preventing double-damage
## if body_entered fires in the same physics step.
var consumed: bool = false
## Player slot that fired this arrow (1-3), or 0 for enemy / tower / hut arrows. A kill
## made by this arrow is credited to that slot. Read by HurtBox for hurtbox-only enemies.
var shooter_slot: int = 0

@onready var _sprite: Sprite2D = find_child("Sprite2D") as Sprite2D
@onready var _particles: CPUParticles2D = find_child("CPUParticles2D") as CPUParticles2D
@onready var _particles_2: CPUParticles2D = find_child("CPUParticles2D2") as CPUParticles2D


## Call this before add_child(). Sets spawn position and all combat values.
## Arrow._ready() reads these to initialize itself once in the scene tree.
func configure(spawn_pos: Vector2, direction: Vector2, speed: float,
		damage: float, knockback_force: float, flow_success: bool = false) -> void:
	_damage = damage
	_knockback_force = knockback_force
	_flow_success = flow_success
	_velocity = direction.normalized() * speed
	global_position = spawn_pos
	_configured = true


## Tint the CPUParticles2D to the given combo color.
## Call after configure() and before add_child() so color is set from frame 0.
func set_combo_color(c: Color) -> void:
	if _particles != null or _particles_2 != null:
		_apply_particle_color(c)
	else:
		# Particles may not be ready yet if called before _ready; store for _ready.
		_pending_particle_color = c
		_pending_color_set = true

var _pending_particle_color: Color = Color.WHITE
var _pending_color_set: bool = false


## Returns the damage this arrow deals on hit. Used by external hit detectors (e.g. head hitbox).
func get_damage() -> float:
	return _damage


## Returns whether this arrow was fired on a successful flow-window press.
## Used by HurtBox so head/body hurtbox hits still register a flow crit
## (body_entered on plain enemies already gets this via _flow_success).
func get_flow_success() -> bool:
	return _flow_success


func _apply_particle_color(c: Color) -> void:
	if _particles != null:
		_particles.color = c
	if _particles_2 != null:
		_particles_2.color = c


func _ready() -> void:
	if _sprite != null and _velocity != Vector2.ZERO:
		rotation = _velocity.angle()
	# collision_layer defaults to 32 (layer 6) on the scene itself — see arrow.tscn —
	# which makes an arrow detectable by monitoring Area2Ds (e.g. a dragon's head/body
	# HurtBox). It must NOT be forced here: callers configure() an arrow and set
	# collision_layer BEFORE add_child (same pattern as collision_mask below), and
	# add_child is deferred, so a hardcoded assignment in _ready() would run after
	# and silently overwrite it. That previously made enemy archers' attempt to move
	# their arrows off layer 32 a no-op, letting their arrows trigger the dragon's
	# own HurtBox as if a player had fired them.
	body_entered.connect(_on_body_entered)
	if _pending_color_set and (_particles != null or _particles_2 != null):
		_apply_particle_color(_pending_particle_color)
	tree_exiting.connect(_on_tree_exiting)


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


func _on_tree_exiting() -> void:
	if not _hit_any:
		missed.emit()


func _on_body_entered(body: Node2D) -> void:
	# A HurtBox already claimed this arrow in the same physics step — skip.
	if consumed:
		return
	if pierce:
		# Piercing: damage each enemy only once per flight, then keep going.
		if body in _hit_enemies:
			return
		_hit_enemies.append(body)
		_hit_any = true
		EnemyBase.player_hit(body, shooter_slot, _damage, _flow_success, weapon_type)
		if body.has_method("apply_knockback"):
			body.apply_knockback(global_position, _knockback_force)
		enemy_hit.emit()
		# Do NOT queue_free — keep flying.
	else:
		# Normal arrow: stop on first hit.
		_hit_any = true
		EnemyBase.player_hit(body, shooter_slot, _damage, _flow_success, weapon_type)
		if body.has_method("apply_knockback"):
			body.apply_knockback(global_position, _knockback_force)
		enemy_hit.emit()
		queue_free()

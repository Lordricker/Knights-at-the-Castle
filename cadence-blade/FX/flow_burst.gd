class_name FlowBurst
extends CPUParticles2D

## One-shot white/gold radial particle burst for a successful flow attack.
## Spawn via FlowBurst.spawn_at() — do not add to the scene manually.

const _LIFETIME := 0.3


func setup() -> void:
	z_index = 4096
	z_as_relative = false
	emitting = false
	one_shot = true
	amount = 16
	lifetime = _LIFETIME
	explosiveness = 1.0
	lifetime_randomness = 0.2
	emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	emission_sphere_radius = 4.0
	direction = Vector2.UP
	spread = 180.0
	gravity = Vector2.ZERO
	initial_velocity_min = 90.0
	initial_velocity_max = 170.0
	angular_velocity_min = -180.0
	angular_velocity_max = 180.0
	scale_amount_min = 3.0
	scale_amount_max = 4.5
	color = Color(1.0, 0.95, 0.7)
	color_ramp = _build_fade_ramp()


func _build_fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.9, 0.5, 1.0))
	g.set_color(1, Color(1.0, 0.9, 0.5, 0.0))
	return g


## Instantiate and play a flow-crit burst at the given world position.
## Pass the scene root (or any persistent parent) as `parent`.
static func spawn_at(parent: Node, world_pos: Vector2) -> void:
	var burst := FlowBurst.new()
	burst.setup()
	parent.add_child(burst)
	burst.global_position = world_pos
	burst.restart()
	burst.get_tree().create_timer(_LIFETIME + 0.1).timeout.connect(burst.queue_free, CONNECT_ONE_SHOT)

class_name FXManager
extends RefCounted

## Static helpers for bundled "crit" feedback on a successful flow attack.
## Not an autoload — call FXManager.flow_crit(context, target) from wherever
## a flow-success hit lands (e.g. EnemyBase.take_damage, or the joiner-side
## hit_fx replay in run_manager.gd), mirroring the DamageNumber/HealNumber
## static-helper convention (context node supplies scene-tree access).

const FlowBurst = preload("res://FX/flow_burst.gd")

const _HIT_STOP_SCALE := 0.05
const _HIT_STOP_DURATION := 0.07
const _SHAKE_AMOUNT := 0.6


## Triggers hit-stop, camera shake, and a white burst particle at target's position.
static func flow_crit(context: Node, target: Node2D) -> void:
	_hit_stop(context)
	var cam := context.get_viewport().get_camera_2d()
	if cam != null and cam.has_method(&"add_shake"):
		cam.call(&"add_shake", _SHAKE_AMOUNT)
	FlowBurst.spawn_at(context.get_tree().current_scene, target.global_position)


static func _hit_stop(context: Node) -> void:
	Engine.time_scale = _HIT_STOP_SCALE
	# ignore_time_scale=true so this restore timer isn't itself slowed down.
	context.get_tree().create_timer(_HIT_STOP_DURATION, true, false, true) \
		.timeout.connect(func() -> void: Engine.time_scale = 1.0, CONNECT_ONE_SHOT)

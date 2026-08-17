class_name HutDot
extends RefCounted

# hut_dot.gd — Shared damage-over-time helper for hut units (warrior bleed,
# archer poison). Re-hitting an already-affected target refreshes the
# duration rather than stacking additional ticks.
#
# Usage: caster keeps its own `var _active_dots: Dictionary = {}` and calls
# HutDot.apply(self, _active_dots, target, ...) whenever a hit should apply/
# refresh the effect.

static func apply(caster: Node, active_dots: Dictionary, target: Node,
		damage_per_tick: float, tick_interval: float, duration: float,
		weapon_type: WeaponType.WeaponType) -> void:
	if target == null or not is_instance_valid(target):
		return
	var key: int = target.get_instance_id()
	var total_ticks: int = ceili(duration / tick_interval)
	if active_dots.has(key):
		active_dots[key].ticks_left = total_ticks
		return

	var timer := Timer.new()
	timer.wait_time = tick_interval
	timer.autostart = true
	caster.add_child(timer)
	var state: Dictionary = {"ticks_left": total_ticks, "timer": timer}
	active_dots[key] = state

	timer.timeout.connect(func() -> void:
		if not is_instance_valid(target) or target.get("is_dead") == true:
			timer.queue_free()
			active_dots.erase(key)
			return
		target.take_damage(damage_per_tick, false, weapon_type)
		state.ticks_left -= 1
		if state.ticks_left <= 0:
			timer.queue_free()
			active_dots.erase(key)
	)

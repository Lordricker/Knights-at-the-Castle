extends "res://characters/enemies/melee/black_knight.gd"

# tutorial_black_knight.gd — shared script for WeakBlackKnight.tscn / StrongBlackKnight.tscn,
# spawned normally by EnemySpawner (via the tutorial's own SpawnScheduleConfig — see
# level/schedules/tutorial_spawn_schedule.tres). Adds a signal exposing whether each
# landed hit was a flow-success (crit), which EnemyBase.health_changed/died don't
# carry, so TutorialRunManager can tell a normal kill from a crit kill.

## Set true only on StrongBlackKnight.tscn so TutorialRunManager can find and
## despawn it once it has done its job (killed the player).
@export var is_tutorial_boss: bool = false
## While true, only a flow-success hit does anything — a normal hit still
## flashes/plays its sound (so the miss reads as "no effect", not "nothing
## happened") but deals no damage and can't kill it. Toggled at runtime by
## TutorialRunManager during the crit-teaching step.
@export var crit_only: bool = false

signal hit_landed(flow_success: bool)


func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	hit_landed.emit(flow_success)
	if crit_only and not flow_success:
		super.take_damage(0.0, flow_success, weapon_type)
		return
	super.take_damage(amount, flow_success, weapon_type)

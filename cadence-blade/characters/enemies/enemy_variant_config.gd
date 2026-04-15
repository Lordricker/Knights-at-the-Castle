class_name EnemyVariantConfig
extends Resource

# enemy_variant_config.gd — Inspector-configurable data for one enemy variant
# (e.g. "Blue Archer", "Red Knight").
#
# Attach one of these resources to each entry in EnemyTypeConfig.variants.
#
# All curves use normalised X [0.0 – 1.0] where 1.0 = the spawner's
# curve_time_scale_minutes setting.  Y values are sampled at the current
# elapsed-time fraction every spawn attempt.

@export_group("Identity")
## Human-readable label shown in the Inspector (no effect at runtime).
@export var display_name: String = "Variant"
## The scene to instantiate for this variant. Must extend EnemyBase.
@export var scene: PackedScene

@export_group("Lottery Pool")
## How many tickets this variant contributes to the spawn lottery pool over time.
## X = normalised elapsed time, Y = ticket count (rounded to int).
## Set Y to 0 until the game time when this variant should start appearing.
## Example: flat 0 for the first 30 % of the run, then ramp up to 5 tickets.
@export var pool_tickets_curve: Curve

@export_group("Alive Cap")
## Maximum number of this variant that may be simultaneously alive.
## X = normalised elapsed time, Y = max alive count (rounded to int).
## The lottery skips this variant when the cap is reached and retries.
@export var max_alive_curve: Curve

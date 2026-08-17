class_name NightPeriod
extends Resource

# night_period.gd — Inspector-configurable data for one "night" breather.
# Attach one of these resources to each entry in EnemySpawner.night_periods.
# Embedded inline in the scene when added via the array Inspector — no
# separate .tres file needed.

## When this night begins, in minutes into the run. Same axis as the spawn
## curves (X=1 → 1 min, X=5 → 5 min).
@export var start_minute: float = 1.0

## How long the breather lasts, in seconds (e.g. 10 for a 10-second pause).
@export var duration_seconds: float = 10.0

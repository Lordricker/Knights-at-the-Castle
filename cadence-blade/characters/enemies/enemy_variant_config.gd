class_name EnemyVariantConfig
extends Resource

# enemy_variant_config.gd — Inspector-configurable data for one enemy variant
# (e.g. "Blue Archer", "Red Knight").
#
# Attach one of these resources to each entry in EnemyTypeConfig.variants.
#
# All curves: X axis = minutes into the run.  X=0 → start, X=1 → 1 minute.
# The curve holds its last value for the rest of the run after X=1.

@export_group("Identity")
## Human-readable label shown in the Inspector (no effect at runtime).
@export var display_name: String = "Variant"
## The scene to instantiate for this variant. Must extend EnemyBase.
@export var scene: PackedScene

@export_group("Lottery Pool")
## How many tickets this variant contributes to the spawn lottery pool over time.
## X = minutes into the run (X=1 → 1 min).  Y = ticket count (rounded to int).
## Set Y to 0 until the minute this variant should start appearing.
@export var pool_tickets_curve: Curve

@export_group("Alive Cap")
## Maximum number of this variant that may be simultaneously alive.
## X = minutes into the run (X=1 → 1 min).  Y = max alive count (rounded to int).
## The lottery skips this variant when the cap is reached and retries.
@export var max_alive_curve: Curve

@export_group("Guaranteed Spawns")
## List of run times (in minutes) at which this variant is guaranteed to spawn next.
## When the run reaches a listed minute, this variant is pushed onto a FIFO queue.
## The next spawn attempt drains the queue before running the lottery.
## If multiple guaranteed spawns are queued (from any variant), they fire one per attempt.
## Example: [1.25, 3.0] — guaranteed spawn at 1m15s and again at 3m00s.
@export var guaranteed_spawn_minutes: Array[float] = []

@export_group("Rewards")
## Which coin tier drops on a normal kill. 0 = none, 1 = Coin, 2 = Coin2, 3 = Coin4.
@export_enum("None", "Coin (1)", "Coin 2 (2)", "Coin 4 (4)") var coin_tier: int = 1
## Which coin tier drops when killed with a perfect flow hit.
## Set to 0 to use the same tier as a normal kill.
@export_enum("None", "Coin (1)", "Coin 2 (2)", "Coin 4 (4)") var flow_kill_coin_tier: int = 0

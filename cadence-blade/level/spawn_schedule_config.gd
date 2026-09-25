class_name SpawnScheduleConfig
extends Resource

# spawn_schedule_config.gd — The complete enemy-spawn schedule for one level, in
# a single resource so it can be authored in the Spawn Designer tool, saved as a
# standalone .tres, and diffed in git.
#
# EnemySpawner reads every field below from its `schedule` export. All curves use
# X = minutes into the run; Y meaning is noted per-curve. The X axis range shown
# in the Spawn Designer is `run_length_minutes`.
#
# ── AUTHORING ─────────────────────────────────────────────────────────────────
#   • Set run_length_minutes to the intended run duration.
#   • spawn_rate_curve / max_total_curve are the global knobs.
#   • enemy_types holds one EnemyTypeConfig per sprite category; each holds its
#     own variants array (EnemyVariantConfig), each with a pool_tickets_curve
#     and a max_alive_curve.
#   • night_periods pause spawning for a breather window.

@export_group("Run")
## Intended run length in minutes. Sets the X-axis range in the Spawn Designer
## and the max_domain applied to every curve on run start. Curves are sampled at
## the real elapsed time — a value past this point just reads the curve's last
## point (no hard gameplay clamp).
@export var run_length_minutes: float = 20.0

@export_group("Global Curves")
## Seconds between spawn attempts over time. X = minutes. Y = seconds between
## spawns (lower = faster). Minimum interval enforced: 0.1 s.
@export var spawn_rate_curve: Curve
## Max enemies alive simultaneously before spawn attempts are skipped.
## X = minutes. Y = max alive count (rounded to int).
@export var max_total_curve: Curve
## Optional solo-run override for max_total_curve. When set, an offline solo run
## (GameManager.session_id == "") uses this instead — one player can't hold back
## the same crowd as three. Leave null to reuse max_total_curve for solo too.
## Edited on the Spawn Designer's Global tab as the "Max total alive (solo)" line.
@export var solo_max_total_curve: Curve

@export_group("Night Cycle (Breather)")
## One NightPeriod resource per night. Spawning pauses entirely for that window.
## Typed as Array[Resource] (not Array[NightPeriod]) on purpose — see the note in
## enemy_spawner.gd: the global-class scan on Array[NightPeriod] kept breaking.
@export var night_periods: Array[Resource] = []
## Seconds the screen tint takes to fade in before a night and out after it.
## Purely visual — spawning still pauses exactly on the night_periods window.
@export var night_fade_seconds: float = 3.0

@export_group("Enemies")
## One entry per sprite category (Knight, Archer, Warrior, …). Each
## EnemyTypeConfig holds its own inner variants array.
@export var enemy_types: Array[EnemyTypeConfig] = []

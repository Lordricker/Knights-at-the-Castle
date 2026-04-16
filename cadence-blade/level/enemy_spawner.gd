class_name EnemySpawner
extends Node2D

# enemy_spawner.gd — Rogue-loop enemy spawner driven by a lottery-pool system.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   Node2D            (this script)
#   ├── Marker2D  "LeftSpawnPoint"    — world position on the left edge of the map
#   └── Marker2D  "RightSpawnPoint"   — world position on the right edge of the map
#
# ── HOW IT WORKS ──────────────────────────────────────────────────────────────
#   1. A global timer counts up; the normalised fraction t ∈ [0,1] drives all curves.
#   2. Each tick a lottery pool is built: per variant, sample pool_tickets_curve → N
#      tickets added for that variant.  Variants with 0 tickets at the current time
#      are absent from the pool (natural unlock mechanic).
#   3. One ticket is drawn at random.  If that variant is at/above its max_alive cap
#      (from max_alive_curve), all its tickets are stripped and a new draw happens.
#      This repeats until a valid variant is found or the pool is exhausted.
#   4. max_total_curve caps the global alive count before the lottery even starts.
#   5. spawn_rate_curve controls how many seconds between spawn attempts.
#
# ── EDITOR SETUP ──────────────────────────────────────────────────────────────
#   • Create EnemyTypeConfig resources and add them to enemy_types.
#   • Inside each EnemyTypeConfig, create EnemyVariantConfig resources.
#   • Assign a PackedScene and two Curve resources to every EnemyVariantConfig.
#   • All curves share the same time axis: X=0 → t=0, X=1 → t=curve_time_scale_minutes.
#   • Enemies are parented to enemy_container (defaults to this node's parent).
#   • The walk path is found automatically by EnemyBase via the "walk_path" group
#     in the scene tree — no manual wiring needed here.

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Enemy Types")
## Outer array: one entry per sprite category (e.g. Knight, Archer, Warrior).
## Each EnemyTypeConfig holds an inner variants array.
@export var enemy_types: Array[EnemyTypeConfig] = []

@export_group("Global Spawn Curves")
## Seconds between spawn attempts over time.
## X = normalised time, Y = seconds (floor-clamped to 0.1 s minimum).
## Lower Y = faster spawns.  Falling curve recommended for increasing difficulty.
@export var spawn_rate_curve: Curve

## Maximum total enemies alive simultaneously over time.
## X = normalised time, Y = count (rounded to int).
## Rising curve recommended so early waves stay small.
@export var max_total_curve: Curve

## What X = 1.0 on every curve represents, in minutes.
## All EnemyVariantConfig curves and the global curves share this scale.
@export var curve_time_scale_minutes: float = 10.0

@export_group("Scene Wiring")
## Node that spawned enemies are added to.  Defaults to this node's parent
## if left unassigned — assign explicitly when nesting the spawner deeper.
@export var enemy_container: Node

# ── Internal references ───────────────────────────────────────────────────────

@onready var _left_point: Marker2D = $LeftSpawnPoint
@onready var _right_point: Marker2D = $RightSpawnPoint

# ── Runtime state ─────────────────────────────────────────────────────────────

## Total seconds since the run started.
var time_elapsed: float = 0.0

var _spawn_timer: float = 0.0

## Vector2i(type_index, variant_index) → int  (alive count)
var _alive_counts: Dictionary = {}

var _total_alive: int = 0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	if enemy_container == null:
		enemy_container = get_parent()

	# Pre-populate alive counts for every configured variant.
	for ti in enemy_types.size():
		var type_cfg: EnemyTypeConfig = enemy_types[ti]
		for vi in type_cfg.variants.size():
			_alive_counts[Vector2i(ti, vi)] = 0

	# Prime the timer so the first spawn fires after one full interval.
	_spawn_timer = _sample_spawn_interval(0.0)


func _process(delta: float) -> void:
	time_elapsed += delta
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_attempt_spawn()
		_spawn_timer = _sample_spawn_interval(_normalized_time())


# ── Curve helpers ─────────────────────────────────────────────────────────────

func _normalized_time() -> float:
	return clamp(time_elapsed / (curve_time_scale_minutes * 60.0), 0.0, 1.0)


func _sample_spawn_interval(t: float) -> float:
	if spawn_rate_curve == null:
		return 3.0
	return maxf(0.1, spawn_rate_curve.sample_baked(t))


func _sample_max_total(t: float) -> int:
	if max_total_curve == null:
		return 20
	return roundi(max_total_curve.sample_baked(t))


# ── Spawn logic ───────────────────────────────────────────────────────────────

func _attempt_spawn() -> void:
	var t := _normalized_time()

	# Global cap check.
	if _total_alive >= _sample_max_total(t):
		return

	var pool := _build_pool(t)
	if pool.is_empty():
		return

	pool.shuffle()

	# Draw until a non-capped variant is found or the pool is exhausted.
	var chosen := Vector2i(-1, -1)
	var skip: Dictionary = {}

	while pool.size() > 0:
		var pick: Vector2i = pool.pop_back()

		# Skip variants already confirmed maxed this attempt.
		if pick in skip:
			continue

		var vi_cfg: EnemyVariantConfig = enemy_types[pick.x].variants[pick.y]
		var max_alive := 999
		if vi_cfg.max_alive_curve != null:
			max_alive = roundi(vi_cfg.max_alive_curve.sample_baked(t))

		if _alive_counts.get(pick, 0) < max_alive:
			chosen = pick
			break
		else:
			# Mark as exhausted and strip remaining tickets from pool.
			skip[pick] = true
			pool = pool.filter(func(k: Vector2i) -> bool: return k != pick)

	if chosen == Vector2i(-1, -1):
		return

	_spawn_variant(chosen)


func _build_pool(t: float) -> Array[Vector2i]:
	var pool: Array[Vector2i] = []
	for ti in enemy_types.size():
		var type_cfg: EnemyTypeConfig = enemy_types[ti]
		for vi in type_cfg.variants.size():
			var vi_cfg: EnemyVariantConfig = type_cfg.variants[vi]
			if vi_cfg == null or vi_cfg.scene == null or vi_cfg.pool_tickets_curve == null:
				continue
			var tickets := roundi(vi_cfg.pool_tickets_curve.sample_baked(t))
			for _i in tickets:
				pool.append(Vector2i(ti, vi))
	return pool


func _spawn_variant(key: Vector2i) -> void:
	var vi_cfg: EnemyVariantConfig = enemy_types[key.x].variants[key.y]

	var instance: Node = vi_cfg.scene.instantiate()
	enemy_container.add_child(instance)

	# Pick a spawn point at random.
	var use_left := randf() < 0.5
	instance.global_position = _left_point.global_position if use_left else _right_point.global_position

	# Track alive count; lambda captures key by value.
	# The scene root may be a plain Node2D wrapper — find the actual enemy node.
	var signal_source: Node = instance
	if not instance.has_signal("died"):
		for child in instance.get_children():
			if child.has_signal("died"):
				signal_source = child
				break
	if signal_source.has_signal("died"):
		signal_source.died.connect(func(_e: Node) -> void: _on_enemy_died(key))

	_alive_counts[key] = _alive_counts.get(key, 0) + 1
	_total_alive += 1


func _on_enemy_died(key: Vector2i) -> void:
	_alive_counts[key] = maxi(0, _alive_counts.get(key, 0) - 1)
	_total_alive = maxi(0, _total_alive - 1)


# ── Debug ─────────────────────────────────────────────────────────────────────

## Returns a human-readable snapshot of current alive counts, useful in the
## Godot remote debugger or a temporary debug label.
func get_debug_info() -> String:
	var lines: Array[String] = []
	lines.append("t=%.1fs  alive=%d" % [time_elapsed, _total_alive])
	for ti in enemy_types.size():
		var type_cfg: EnemyTypeConfig = enemy_types[ti]
		for vi in type_cfg.variants.size():
			var k := Vector2i(ti, vi)
			var vi_cfg: EnemyVariantConfig = type_cfg.variants[vi]
			lines.append("  [%d][%d] %s: %d alive" % [ti, vi, vi_cfg.display_name, _alive_counts.get(k, 0)])
	return "\n".join(lines)

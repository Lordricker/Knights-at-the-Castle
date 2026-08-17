class_name EnemySpawner
extends Node2D

# enemy_spawner.gd — Rogue-loop enemy spawner driven by a lottery-pool system.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   Node2D            (this script)
#   ├── Marker2D  "LeftSpawnPoint"    — fallback spawn point, used only if no
#   │                                   EnemyTower has registered a spawn source yet
#   └── Marker2D  "RightSpawnPoint"   — fallback spawn point (see above)
#
# ── HOW IT WORKS ──────────────────────────────────────────────────────────────
#   1. A global timer counts up; elapsed minutes drive all curves.
#      X=1 on every curve = 1 minute.  X=curve_time_scale_minutes = end of run.
#   2. Each tick a lottery pool is built: per variant, sample pool_tickets_curve → N
#      tickets added for that variant.  Variants with 0 tickets at the current time
#      are absent from the pool (natural unlock mechanic).
#   3. One ticket is drawn at random.  If that variant is at/above its max_alive cap
#      (from max_alive_curve), all its tickets are stripped and a new draw happens.
#      This repeats until a valid variant is found or the pool is exhausted.
#   4. max_total_curve caps the global alive count before the lottery even starts.
#   5. spawn_rate_curve controls how many seconds between spawn attempts.
#
# ── SPAWN SOURCES ──────────────────────────────────────────────────────────────
#   Each active EnemyTower along the road registers itself as a spawn source
#   (add_spawn_source) with its own Marker2D + Path2D when activated, and hands
#   off to its next_towers / terminal spawn points (removing itself) when
#   destroyed. Every spawn picks a random source from the currently active set
#   and assigns that source's path to the spawned enemy directly, instead of
#   relying on a single global "walk_path" group lookup.
#
# ── EDITOR SETUP ──────────────────────────────────────────────────────────────
#   • Set curve_time_scale_minutes to your total run length (e.g. 10 for 10 minutes).
#   • Run the scene once after changing it — this updates every curve’s X axis so
#     X=1 = 1 min, X=5 = 5 min, X=curve_time_scale_minutes = end of run.
#   • Create EnemyTypeConfig resources and add them to enemy_types.
#   • Inside each EnemyTypeConfig, create EnemyVariantConfig resources.
#   • Assign a PackedScene and two Curve resources to every EnemyVariantConfig.
#   • Enemies are parented to enemy_container (defaults to this node’s parent).
#   • Each spawned enemy's walk path comes from whichever spawn source produced
#     it (see "SPAWN SOURCES" above) — no manual wiring needed here.

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Enemy Types")
## Outer array: one entry per sprite category (e.g. Knight, Archer, Warrior).
## Each EnemyTypeConfig holds an inner variants array.
@export var enemy_types: Array[EnemyTypeConfig] = []

@export_group("Global Spawn Curves")
## Seconds between spawn attempts over time.
## X = minutes into the run (X=1 → 1 min, X=5 → 5 min).  Y = seconds between spawns.
## Lower Y = faster spawns.  Minimum interval enforced: 0.1 s.
@export var spawn_rate_curve: Curve

## Maximum total enemies alive simultaneously before spawn attempts are skipped.
## X = minutes into the run (X=1 → 1 min, X=5 → 5 min).  Y = max alive count.
@export var max_total_curve: Curve

## Total run length in minutes.  Sets the X axis range of every curve so X=1 = 1 min.
## After changing this value, run the scene once to update the curve editors.
@export var curve_time_scale_minutes: float = 10.0

@export_group("Night Cycle (Breather)")
## One entry per night. Add a "New NightPeriod" resource per element — it has
## two Inspector fields: start_minute (minutes into the run) and
## duration_seconds. Spawning pauses entirely for that window — a breather
## from the rush.
## Typed as Array[Resource] (not Array[NightPeriod]) on purpose: this file
## must keep parsing even if the editor hasn't (re)registered NightPeriod's
## class_name yet, since that global-class scan is what kept breaking here.
@export var night_periods: Array[Resource] = []
## Seconds the screen tint takes to fade in before a night starts and fade back
## out after it ends. Purely visual — spawning still pauses exactly on the
## night_periods window regardless of this value.
@export var night_fade_seconds: float = 3.0

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

## Vector2i(type_index, variant_index) -> int  (alive count)
var _alive_counts: Dictionary = {}

var _total_alive: int = 0
## Monotonically increasing ID assigned to each spawned enemy.
var _next_id: int = 0

## FIFO queue of variants with a guaranteed next spawn.
## Entries are popped from the front before the lottery runs.
var _guaranteed_queue: Array[Vector2i] = []
## Vector2i(ti, vi) -> int: how many guaranteed_spawn_minutes entries have been queued so far.
var _guaranteed_next_index: Dictionary = {}
## spawn_id -> {ti, vi, node} for all currently alive enemies on host.
## Public so RunManager can read positions for state broadcasts.
var alive_enemy_map: Dictionary = {}

## Active spawn sources, one per currently-active EnemyTower (and any activated
## terminal spawn points). Each entry: {"marker": Marker2D, "path": Path2D}.
## Populated/emptied by EnemyTower.activate() / destroy() via add_spawn_source()
## and remove_spawn_source() — see the "SPAWN SOURCES" note above.
var _spawn_sources: Array[Dictionary] = []


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(&"enemy_spawner")
	if enemy_container == null:
		enemy_container = get_parent()

	# Pre-populate alive counts and guaranteed-spawn tracking for every configured variant.
	for ti in enemy_types.size():
		var type_cfg: EnemyTypeConfig = enemy_types[ti]
		for vi in type_cfg.variants.size():
			var key := Vector2i(ti, vi)
			_alive_counts[key] = 0
			_guaranteed_next_index[key] = 0

	# Apply curve_time_scale_minutes as the X axis max on every curve so
	# X=1 = 1 minute in the curve editor.  Re-run after changing the export.
	_apply_curve_domains()

	# Prime the timer so the first spawn fires after one full interval.
	_spawn_timer = _sample_spawn_interval(0.0)


func _process(delta: float) -> void:
	# Only the host runs the spawner; joiner receives enemies via reliable packets.
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	time_elapsed += delta
	_check_guaranteed_spawns()
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_attempt_spawn()
		_spawn_timer = _sample_spawn_interval(_elapsed_minutes())


# ── Guaranteed spawn tracking ─────────────────────────────────────────────────

## Each frame, check every variant's guaranteed_spawn_minutes list and enqueue
## any entries whose minute threshold has just been crossed.
func _check_guaranteed_spawns() -> void:
	var minutes := time_elapsed / 60.0
	for ti in enemy_types.size():
		var type_cfg: EnemyTypeConfig = enemy_types[ti]
		for vi in type_cfg.variants.size():
			var vi_cfg: EnemyVariantConfig = type_cfg.variants[vi]
			if vi_cfg == null or vi_cfg.guaranteed_spawn_minutes.is_empty():
				continue
			var key := Vector2i(ti, vi)
			var next_idx: int = _guaranteed_next_index.get(key, 0)
			while next_idx < vi_cfg.guaranteed_spawn_minutes.size():
				if minutes >= vi_cfg.guaranteed_spawn_minutes[next_idx]:
					_guaranteed_queue.append(key)
					next_idx += 1
				else:
					break
			_guaranteed_next_index[key] = next_idx


# ── Curve domain setup ─────────────────────────────────────────────────────────────

## Sets max_domain on every curve to curve_time_scale_minutes so X=1 = 1 minute.
func _apply_curve_domains() -> void:
	for curve in [spawn_rate_curve, max_total_curve]:
		if curve != null:
			curve.max_domain = curve_time_scale_minutes
	for type_cfg: EnemyTypeConfig in enemy_types:
		for vi_cfg: EnemyVariantConfig in type_cfg.variants:
			if vi_cfg == null:
				continue
			if vi_cfg.pool_tickets_curve != null:
				vi_cfg.pool_tickets_curve.max_domain = curve_time_scale_minutes
			if vi_cfg.max_alive_curve != null:
				vi_cfg.max_alive_curve.max_domain = curve_time_scale_minutes


# ── Curve helpers ─────────────────────────────────────────────────────────────

## Returns elapsed minutes, clamped to [0, curve_time_scale_minutes].
func _elapsed_minutes() -> float:
	return clampf(time_elapsed / 60.0, 0.0, curve_time_scale_minutes)


# ── Night cycle ───────────────────────────────────────────────────────────────

## True while `minutes` falls inside any configured night_periods window.
## Used to hard-pause spawning — no fade, so the breather starts/ends exactly
## on the configured timing regardless of the visual fade length.
func _is_night(minutes: float) -> bool:
	for period in night_periods:
		if not _night_valid(period):
			continue
		var start: float = float(period.get("start_minute"))
		var end: float = start + float(period.get("duration_seconds")) / 60.0
		if minutes >= start and minutes <= end:
			return true
	return false


## True if `period` has the fields a night_periods entry needs. Checked with
## the `in` operator (duck typing) rather than a static NightPeriod type, so
## this file keeps parsing even if the editor hasn't (re)registered
## NightPeriod's class_name yet — see the comment on night_periods above.
func _night_valid(period: Resource) -> bool:
	return period != null and "start_minute" in period and "duration_seconds" in period


## Returns 0..1 — how "night" the screen should look right now. Ramps up over
## night_fade_seconds before a night starts, holds at 1 for its duration, and
## ramps back down over night_fade_seconds after it ends. Read by
## night_overlay.gd to drive the screen-tint shader; both host and joiner call
## this from the same synced time_elapsed, so the fade matches on both peers.
func get_night_intensity() -> float:
	var t := time_elapsed / 60.0
	var fade_min := (night_fade_seconds / 60.0) if night_fade_seconds > 0.0 else 0.0001
	for period in night_periods:
		if not _night_valid(period):
			continue
		var start: float = float(period.get("start_minute"))
		var end: float = start + float(period.get("duration_seconds")) / 60.0
		if t < start - fade_min or t > end + fade_min:
			continue
		if t < start:
			return clampf((t - (start - fade_min)) / fade_min, 0.0, 1.0)
		if t <= end:
			return 1.0
		return clampf(1.0 - (t - end) / fade_min, 0.0, 1.0)
	return 0.0


func _sample_spawn_interval(minutes: float) -> float:
	if spawn_rate_curve == null:
		return 3.0
	return maxf(0.1, spawn_rate_curve.sample(minutes))


func _sample_max_total(minutes: float) -> int:
	if max_total_curve == null:
		return 20
	return roundi(max_total_curve.sample(minutes))


func _sample_curve_count(curve: Curve, minutes: float, default_value: int = 0, zero_before_first_point: bool = false) -> int:
	if curve == null:
		return default_value
	if zero_before_first_point and curve.point_count > 0 and minutes < curve.get_point_position(0).x:
		return 0
	return maxi(0, roundi(curve.sample(minutes)))


# ── Spawn sources ─────────────────────────────────────────────────────────────

## Called by EnemyTower.activate() to register its spawn marker + walk path as
## a valid spawn location. No-ops if either argument is null or already registered.
func add_spawn_source(marker: Marker2D, path: Path2D) -> void:
	if marker == null or path == null:
		return
	for src: Dictionary in _spawn_sources:
		if src["marker"] == marker:
			return
	_spawn_sources.append({"marker": marker, "path": path})


## Called by EnemyTower.destroy() to retire its own spawn marker once it falls.
func remove_spawn_source(marker: Marker2D) -> void:
	for i in range(_spawn_sources.size() - 1, -1, -1):
		if _spawn_sources[i]["marker"] == marker:
			_spawn_sources.remove_at(i)


# ── Spawn logic ───────────────────────────────────────────────────────────────

func _attempt_spawn() -> void:
	var t := _elapsed_minutes()

	# Night breather — no new spawns at all while inside a night_periods window.
	if _is_night(t):
		return

	# Global cap check — if capped, keep any guaranteed entries in the queue.
	if _total_alive >= _sample_max_total(t):
		return

	# Guaranteed queue takes priority over the lottery.
	if _guaranteed_queue.size() > 0:
		var guaranteed: Vector2i = _guaranteed_queue.pop_front()
		_spawn_variant(guaranteed)
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
			max_alive = _sample_curve_count(vi_cfg.max_alive_curve, t, 999, true)

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
			var tickets := _sample_curve_count(vi_cfg.pool_tickets_curve, t, 0, true)
			for _i in tickets:
				pool.append(Vector2i(ti, vi))
	return pool


func _spawn_variant(key: Vector2i) -> void:
	var vi_cfg: EnemyVariantConfig = enemy_types[key.x].variants[key.y]

	# Assign a deterministic name so both peers' nodes share the same path for RPC routing.
	var spawn_id := _next_id
	_next_id += 1

	var instance: Node = vi_cfg.scene.instantiate()
	instance.name = "En%d" % spawn_id
	enemy_container.add_child(instance)

	# Pick an active spawn source (a currently-standing tower or an opened-up
	# terminal spawn point) at random. Falls back to the legacy left/right
	# markers if no tower has registered a source yet.
	var spawn_path: Path2D = null
	if not _spawn_sources.is_empty():
		var source: Dictionary = _spawn_sources[randi() % _spawn_sources.size()]
		var spawn_marker: Marker2D = source["marker"]
		spawn_path = source["path"]
		instance.global_position = spawn_marker.global_position
	else:
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
	# Assign the walk path tied to this spawn source directly, rather than
	# relying on EnemyBase's fallback lookup of the first "walk_path" group member.
	if spawn_path != null and "walk_path" in signal_source:
		signal_source.walk_path = spawn_path
	if signal_source.has_signal("died"):
		var sid := spawn_id
		signal_source.died.connect(func(_e: Node) -> void: _on_enemy_died(key, sid))

	_alive_counts[key] = _alive_counts.get(key, 0) + 1
	_total_alive += 1
	# Store signal_source (the actual EnemyBase CharacterBody2D), not the wrapper Node2D.
	# The wrapper never moves — move_and_slide() moves the CharacterBody2D child.
	alive_enemy_map[spawn_id] = {"ti": key.x, "vi": key.y, "node": signal_source}

	# Propagate coin tier config to the enemy so it knows what to drop on death.
	if "coin_tier" in signal_source:
		signal_source.coin_tier = vi_cfg.coin_tier
	if "flow_kill_coin_tier" in signal_source:
		signal_source.flow_kill_coin_tier = vi_cfg.flow_kill_coin_tier

	# Notify joiner so it can instantiate a matching node.
	if GameManager.session_id != "" and GameManager.is_host:
		var e_spr := signal_source.get("animated_sprite") as AnimatedSprite2D
		WebRTCManager.send_reliable({
			"t":  "spawn",
			"id": spawn_id,
			"ti": key.x,
			"vi": key.y,
			"x":  instance.global_position.x,
			"y":  instance.global_position.y,
			"an": e_spr.animation if e_spr != null else "",
		})


func _on_enemy_died(key: Vector2i, spawn_id: int) -> void:
	_alive_counts[key] = maxi(0, _alive_counts.get(key, 0) - 1)
	_total_alive = maxi(0, _total_alive - 1)
	alive_enemy_map.erase(spawn_id)
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "despawn", "id": spawn_id})


# ── Joiner-side packet handlers (called by RunManager._on_packet_received) ────

## Host: send all currently alive enemies to the newly connected joiner.
## Called once from RunManager.spawn_peer_mid_game so the joiner's screen
## isn't empty for enemies that spawned before the connection was established.
func send_all_alive_to_joiner() -> void:
	print("[Spawner] Sending %d alive enemies to joiner." % alive_enemy_map.size())
	for spawn_id: int in alive_enemy_map:
		var info: Dictionary = alive_enemy_map[spawn_id]
		var node: Node = info.get("node") as Node
		if is_instance_valid(node):
			var e_spr := node.get("animated_sprite") as AnimatedSprite2D
			WebRTCManager.send_reliable({
				"t":  "spawn",
				"id": spawn_id,
				"ti": info["ti"],
				"vi": info["vi"],
				"x":  node.global_position.x,
				"y":  node.global_position.y,
				"an": e_spr.animation if e_spr != null else "",
			})


## Joiner: instantiate a mirrored enemy from a reliable spawn packet.
func on_spawn_packet(data: Dictionary) -> void:
	var ti: int = int(data.get("ti", -1))
	var vi: int = int(data.get("vi", -1))
	var spawn_id: int = int(data.get("id", -1))
	if ti < 0 or vi < 0 or spawn_id < 0:
		return
	if ti >= enemy_types.size():
		return
	var type_cfg: EnemyTypeConfig = enemy_types[ti]
	if vi >= type_cfg.variants.size():
		return
	var vi_cfg: EnemyVariantConfig = type_cfg.variants[vi]
	if vi_cfg == null or vi_cfg.scene == null:
		return
	var existing_name: String = "En%d" % spawn_id
	if enemy_container != null and enemy_container.has_node(existing_name):
		return
	var instance: Node = vi_cfg.scene.instantiate()
	instance.name = existing_name
	enemy_container.add_child(instance)
	var initial_pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	instance.global_position = initial_pos
	# Find the EnemyBase child (or root) so we can configure it.
	var signal_source: Node = instance
	if not instance.has_signal("died"):
		for child in instance.get_children():
			if child.has_signal("died"):
				signal_source = child
				break
	# Tag the physics body with its spawn ID so the joiner's melee hitboxes can identify
	# which enemy was struck and route damage packets correctly via "melee_hit".
	signal_source.set_meta(&"spawn_id", spawn_id)
	# Seed the network-sync position so EnemyBase._physics_process can lerp immediately.
	# Do NOT disable physics_process — EnemyBase already skips AI and lerps to
	# _net_target_pos when (session_id != "" and not is_host).
	if "_net_target_pos" in signal_source:
		signal_source._net_target_pos = initial_pos
		signal_source._net_synced = true
	if "coin_tier" in signal_source:
		signal_source.coin_tier = vi_cfg.coin_tier
	if "flow_kill_coin_tier" in signal_source:
		signal_source.flow_kill_coin_tier = vi_cfg.flow_kill_coin_tier
	# Apply the initial animation from the spawn packet so the enemy looks correct.
	var spawn_anim: String = data.get("an", "")
	if not spawn_anim.is_empty():
		var e_spr := signal_source.get("animated_sprite") as AnimatedSprite2D
		if e_spr != null:
			e_spr.play(spawn_anim)


## Joiner: remove a dead enemy node from the scene.
func on_despawn_packet(data: Dictionary) -> void:
	var spawn_id: int = int(data.get("id", -1))
	if spawn_id < 0:
		return
	var existing_name: String = "En%d" % spawn_id
	if enemy_container == null or not enemy_container.has_node(existing_name):
		return
	var root: Node = enemy_container.get_node(existing_name)
	# Find the EnemyBase child (or the root itself if the scene is flat).
	var enemy_node: Node = root
	if not root.has_method("die"):
		for child in root.get_children():
			if child.has_method("die"):
				enemy_node = child
				break
	# Call die() instead of queue_free() so the enemy hides visuals immediately
	# but defers the actual node free by ~2.5 s — the same as the host does.
	# This ensures any concurrent hit_fx sound packet has time to play out before
	# the AudioStreamPlayer2D children are freed.
	if enemy_node.has_method("die"):
		enemy_node.call("die")
	else:
		root.queue_free()


## Called by RunManager with the "e" section of a state snapshot.
## Lerps joiner enemy nodes toward their host positions.
func apply_enemy_state(e: Dictionary) -> void:
	for eid_str in e:
		var ed: Dictionary = e[eid_str]
		var enemy_name: String = "En%s" % eid_str
		if enemy_container == null or not enemy_container.has_node(enemy_name):
			continue
		var enemy_root: Node = enemy_container.get_node(enemy_name)
		# Scene root may be a Node2D wrapper; find the actual EnemyBase child.
		var enemy_node: Node = enemy_root
		if "_net_target_pos" not in enemy_root:
			for child in enemy_root.get_children():
				if "_net_target_pos" in child:
					enemy_node = child
					break
		var target := Vector2(float(ed.get("x", 0.0)), float(ed.get("y", 0.0)))
		if "_net_target_pos" in enemy_node:
			enemy_node._net_target_pos = target
			enemy_node._net_synced = true
		else:
			enemy_node.global_position = target
		# Sync animation. "a" key is only present when non-default (not "running").
		var e_spr := enemy_node.get("animated_sprite") as AnimatedSprite2D
		if e_spr != null:
			var anim: StringName = ed.get("a", &"running")
			if e_spr.animation != anim or not e_spr.is_playing():
				e_spr.play(anim)
		# Sync facing.
		if ed.has("f") and "facing" in enemy_node:
			var f := float(ed["f"])
			if enemy_node.get("facing") != f:
				enemy_node.set("facing", f)
				if enemy_node.has_method("_apply_facing"):
					enemy_node.call("_apply_facing")
		# Sync HP so health bar updates visually on joiner.
		if ed.has("hp") and "health" in enemy_node:
			var new_hp: float = float(ed["hp"])
			if enemy_node.health != new_hp:
				enemy_node.health = new_hp
				if enemy_node.has_signal("health_changed"):
					enemy_node.health_changed.emit(new_hp,
						enemy_node.max_health if "max_health" in enemy_node else 100.0)


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

class_name TutorialRunManager
extends Node

# tutorial_run_manager.gd — Drives the guided tutorial level (level/variants/tutorial.tscn).
#
# Enemies are spawned the normal way — EnemySpawner + the level's real spawn points/
# paths/towers — just driven by a small custom schedule
# (level/schedules/tutorial_spawn_schedule.tres) that only contains the two tutorial
# variants (WeakBlackKnight / StrongBlackKnight, both `tutorial_black_knight.gd`,
# which adds a `hit_landed(flow_success)` signal). This manager never instantiates an
# enemy itself — it just watches the "entities" group for tutorial enemies as
# EnemySpawner creates them, and connects to their signals.
#
# Always solo (GameManager.session_id == ""), so unlike run_manager.gd this carries
# none of the multiplayer packet/snapshot machinery. It runs one linear coroutine
# (_run_tutorial) that alternates between:
#   - a pause-and-explain beat (_show_panel): freezes the tree, shows a HUD panel with
#     instructions, waits for a click anywhere to dismiss, then unpauses.
#   - a gated task: unpaused gameplay that doesn't advance until the player actually
#     does the thing (lands a hit, buys an upgrade, blows up a tower, etc), detected via
#     signals (enemy_died_signal from tracked tutorial enemies, CharacterBase.
#     stat_pips_changed, EnemyTower.tower_destroyed) or, where nothing better exists,
#     polling a private counter/state (CastleInside._tnt_purchase_count, UnitHut._state)
#     rather than adding new signals to those shared files.
#
# The crit-teaching enemy is made invincible to non-crit hits (tutorial_black_knight.gd's
# crit_only flag, toggled by _set_crit_only_mode) rather than gated by hit-counting, so a
# lucky normal hit can't kill it out from under the lesson.

@export_group("Scene References")
## Castle node (castle.gd). Made effectively unkillable for the tutorial.
@export var castle: Node
## The EnemySpawner node — paused on tutorial end just like the real run.
@export var spawner: Node
## CastleInside node — blacksmith shop + TNT.
@export var castle_inside: Node
## The level's HUD instance — owns the tutorial explanation panel.
@export var hud: Node
## Where the Red Knight spawns / respawns.
@export var knight_spawn: Marker2D
## Both starting towers — like level1, either can be TNT'd to satisfy the
## "find a tower" gate, and both spawn enemies while active.
@export var initial_towers: Array[EnemyTower] = []

@export_group("Player")
@export var player_scene: PackedScene = preload("res://characters/Players/RedKnight.tscn")

@export_group("Tuning")
@export var castle_max_health: float = 999999.0
@export var respawn_delay: float = 2.0

var _player: CharacterBase = null
var _tough_enemy: Node = null
var _tracked_ids: Dictionary = {}
## While true, newly-tracked (and already-alive) non-boss enemies are set
## crit_only = true — see tutorial_black_knight.gd. Used only during the
## crit-teaching step so a normal hit can't kill it out from under the lesson.
var _crit_only_mode: bool = false
## Whichever of initial_towers actually got TNT'd first.
var _destroyed_tower: EnemyTower = null

signal enemy_died_signal
signal any_tower_destroyed


func _ready() -> void:
	add_to_group(&"run_manager")
	GameManager.change_state(GameManager.GameState.PLAYING)
	GameManager.reset_coins()
	GameManager.my_character = "red_knight"
	if castle != null and "max_health" in castle:
		castle.max_health = castle_max_health
		castle.health = castle.max_health
	for tower in initial_towers:
		if tower != null:
			tower.activate()
			tower.tower_destroyed.connect(_on_tower_destroyed)
	_set_spawning(false)
	_run_tutorial.call_deferred()


func _process(_delta: float) -> void:
	# Watch for newly-spawned tutorial enemies (EnemySpawner creates them, not us)
	# and hook their signals the moment they appear.
	for node in get_tree().get_nodes_in_group(&"entities"):
		var id: int = node.get_instance_id()
		if _tracked_ids.has(id) or not node.has_signal(&"hit_landed"):
			continue
		_tracked_ids[id] = true
		var is_boss: bool = "is_tutorial_boss" in node and bool(node.is_tutorial_boss)
		if is_boss:
			_tough_enemy = node
		elif "crit_only" in node:
			node.crit_only = _crit_only_mode
		node.died.connect(func(_e: Node) -> void: enemy_died_signal.emit())


# ── Tutorial script ───────────────────────────────────────────────────────────

func _run_tutorial() -> void:
	_spawn_player()

	_set_spawning(true)
	await _show_panel("Use an attack on the enemy\n J/LMB, K/RMB, or L/Space.\nClick anywhere to continue.")
	await enemy_died_signal
	_set_spawning(false)

	await _show_panel("Grab the coin before it disappears!\nCoins are shared between all players.")
	await GameManager.coin_balance_changed

	_set_crit_only_mode(true)
	_set_spawning(true)
	await _show_panel(
		"During an attack, stop the yellow in the green windows for a critical attack -" +
		"it executes immediately and lets you chain straight into your next attack. " +
		"Enemies killed by a crit drop more coin.\n" +
		"Hit the next enemy with a critical attack.")
	await enemy_died_signal
	_set_crit_only_mode(false)
	_set_spawning(false)

	await _show_panel(
		"Purchase an upgrade in the castle. The two options are a lottery, and " +
		"they refresh every time the hourglass flips.")
	await _player.stat_pips_changed

	hud.flash_stat_highlight()
	_arm_tough_enemy_spawn()
	_set_spawning(true)
	await _show_panel(
		"Health, Attack, and Speed can be upgraded. Food affects the green crit " +
		"window and can be refilled in the castle.\n" +
		"Try the next enemy.")
	await _player.died
	_set_spawning(false)
	_despawn_tough_enemy()

	hud.flash_stat_highlight()
	_set_spawning(true)
	await _show_panel(
		"Death removes a stat pip. Go ahead and attack a few more enemies")
	while GameManager.coin_balance < _tnt_cost():
		await enemy_died_signal
	_set_spawning(false)

	await _show_panel("Purchase a TNT from the shop.")
	var starting_tnt_count: int = castle_inside._tnt_purchase_count
	while castle_inside._tnt_purchase_count <= starting_tnt_count:
		await get_tree().process_frame

	await _show_panel("Find an enemy tower to blow up.")
	await any_tower_destroyed

	_set_spawning(true)
	await _show_panel(
		"Nice!\n With the tower gone, you can rebuild the nearby unit hut. Go ahead and work on building that.")
	var hut: UnitHut = _destroyed_tower.unit_hut as UnitHut
	while hut == null or hut._state != UnitHut.State.BUILT:
		await get_tree().process_frame
		if hut == null:
			hut = _destroyed_tower.unit_hut as UnitHut

	await _show_panel(
		"Each hut can house 3 units. Once all 3 are purchased you can upgrade " +
		"each one - check the Unit Hut help menu for more details on available units.\n You can also reposition the units with the flag.")

	await _show_panel("Tutorial complete!\nLet's see how long you can last in a real fight!")
	_set_spawning(false)
	get_tree().change_scene_to_file(GameManager.MAIN_MENU_SCENE)


# ── Panel helper ──────────────────────────────────────────────────────────────

func _show_panel(text: String) -> void:
	get_tree().paused = true
	AudioManager.set_forced_night(true)
	hud.show_tutorial_panel(text)
	await hud.tutorial_advance_button.pressed
	hud.hide_tutorial_panel()
	AudioManager.set_forced_night(false)
	get_tree().paused = false


# ── Player ────────────────────────────────────────────────────────────────────

func _spawn_player() -> void:
	var player_root: Node = player_scene.instantiate()
	get_parent().add_child(player_root)
	var body: Node = player_root.get_node("CharacterBody2D")
	body.global_position = knight_spawn.global_position
	body.add_to_group(&"players")
	body.died.connect(_on_player_died)
	_player = body


## Persistent — handles ANY player death during the tutorial, not just the scripted
## step-5 one, so an off-schedule encounter still respawns the player correctly.
func _on_player_died() -> void:
	_player.remove_random_stat_pip()
	await get_tree().create_timer(respawn_delay).timeout
	_player.revive(knight_spawn.global_position)


## Flips crit_only on every currently-alive non-boss tutorial enemy (see
## tutorial_black_knight.gd), and on every one _process() tracks from now on,
## until called again with false.
func _set_crit_only_mode(v: bool) -> void:
	_crit_only_mode = v
	for node in get_tree().get_nodes_in_group(&"entities"):
		var is_boss: bool = "is_tutorial_boss" in node and bool(node.is_tutorial_boss)
		if not is_boss and "crit_only" in node:
			node.crit_only = v


## Starts/stops EnemySpawner entirely so nothing trickles in outside of a step
## that actually needs a kill — the schedule's curves only control *what* spawns
## while it's running, not *when* it's allowed to run at all.
func _set_spawning(enabled: bool) -> void:
	if spawner != null:
		spawner.set_process(enabled)


## The Strong variant has no baked-in guaranteed_spawn_minutes (see
## tutorial_spawn_schedule.tres) — it's armed here, right before re-enabling the
## spawner for the "try the next enemy" step, so it fires almost immediately
## instead of at some fixed wall-clock minute that may fall in the wrong step.
## Index [0].variants[1] matches the schedule's [Weak, Strong] variant order.
func _arm_tough_enemy_spawn() -> void:
	if spawner == null or not ("schedule" in spawner) or spawner.schedule == null:
		return
	var tough_cfg: EnemyVariantConfig = spawner.schedule.enemy_types[0].variants[1]
	tough_cfg.guaranteed_spawn_minutes = [spawner.time_elapsed / 60.0]


func _on_tower_destroyed(tower: EnemyTower) -> void:
	if _destroyed_tower == null:
		_destroyed_tower = tower
	any_tower_destroyed.emit()


func _despawn_tough_enemy() -> void:
	if _tough_enemy != null and is_instance_valid(_tough_enemy):
		var root: Node = _tough_enemy.owner if _tough_enemy.owner != null else _tough_enemy
		root.queue_free()
	_tough_enemy = null


func _tnt_cost() -> int:
	if castle_inside == null or not ("tnt_costs" in castle_inside):
		return 4
	var costs: Array = castle_inside.tnt_costs
	if costs.is_empty():
		return 4
	var count: int = int(castle_inside._tnt_purchase_count)
	return costs[mini(count, costs.size() - 1)]

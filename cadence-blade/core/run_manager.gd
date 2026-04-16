class_name RunManager
extends Node

# run_manager.gd — Coordinates run-level events: player spawning, respawning,
# and game-over when the castle dies.
#
# ── SCENE PLACEMENT ───────────────────────────────────────────────────────────
#   Add a plain Node to your level scene and attach this script.
#   Wire the Castle node reference and the EnemySpawner node reference in the
#   Inspector (drag from the scene tree).
#   For players: drag .tscn files from the FileSystem dock into the
#   player_scenes slots — RunManager instantiates them at run start.
#
# ── HOW IT WORKS ──────────────────────────────────────────────────────────────
#   • On _ready(), each assigned player_scene is instantiated and placed at its
#     matching spawn_point, then tracked internally.
#   • Tracks elapsed run time (same curve_time_scale_minutes as the spawner).
#   • When the castle dies:
#       1. Stops the spawner.
#       2. Freezes all living players.
#       3. Tells GameManager the state is now GAME_OVER.
#       4. Shows the GameOverScreen with the run duration.
#   • When a player dies (and the run is still ongoing):
#       1. Samples respawn_delay_curve at the current run-time fraction.
#       2. After that delay, calls player.revive() at their indexed spawn point.
#
# ── SPAWN POINTS ──────────────────────────────────────────────────────────────
#   Add up to 3 Marker2D children to the RunManager node in the scene, then
#   drag them into spawn_points[0..2].  Index matches the player_scenes slot.
#   If a player's index has no spawn point, slot 0 is used as fallback.

# ── Scene References ──────────────────────────────────────────────────────────

@export_group("Scene References")
## The Castle node (castle.gd). Always present in the level scene; drag it here.
@export var castle: Node
## The EnemySpawner node. Will be paused when the run ends.
@export var spawner: Node
## CanvasLayer with game_over_screen.gd attached.
@export var game_over_screen: CanvasLayer

@export_group("Players")
## Drag up to 3 player .tscn files here from the FileSystem dock.
## RunManager instantiates them at run start and places them at the matching
## spawn_point. Leave a slot empty if fewer than 3 players are in the run.
@export var player_scenes: Array[PackedScene] = []

# ── Respawn ───────────────────────────────────────────────────────────────────

@export_group("Respawn")
## Seconds the player waits before respawning, mapped against run time.
## X = normalised run time (0 → 1), Y = delay in seconds.
## Rising curve = longer waits as the run gets harder.
@export var respawn_delay_curve: Curve
## Must match the curve_time_scale_minutes on the EnemySpawner so the
## time axis is consistent across both systems.
@export var curve_time_scale_minutes: float = 10.0
## One Marker2D per player slot (up to 3). Index matches player_scenes.
## Add Marker2D children to this node and drag them here.
@export var spawn_points: Array[Marker2D] = []

# ── Runtime state ─────────────────────────────────────────────────────────────

## Total seconds since the run started. Read-only from outside.
var time_elapsed: float = 0.0

## Instantiated player nodes tracked at runtime.
var _players: Array[Node] = []

var _game_over: bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	GameManager.change_state(GameManager.GameState.PLAYING)

	_spawn_players.call_deferred()

	# Resolve the Castle script node: if the assigned node has the signal use it
	# directly; otherwise search children (handles the case where the scene root
	# is a plain Node2D and castle.gd is on a child StaticBody2D).
	var castle_node: Node = _resolve_castle(castle)
	if castle_node != null:
		castle_node.died.connect(_on_castle_died)
		castle = castle_node  # keep the resolved reference for later use
	else:
		push_warning("RunManager: could not find a Castle node with a 'died' signal — game-over will never trigger.")


func _process(delta: float) -> void:
	if _game_over:
		return
	time_elapsed += delta


# ── Castle resolution ─────────────────────────────────────────────────────────

## Returns the node that actually has the Castle script (and its 'died' signal).
## Accepts either the Castle StaticBody2D directly or its parent Node2D.
func _resolve_castle(node: Node) -> Node:
	if node == null:
		return null
	if node.has_signal(&"died"):
		return node
	for child in node.get_children():
		if child.has_signal(&"died"):
			return child
	return null


## Returns the CharacterBase node from a spawned player scene.
## Handles the case where the scene root is a plain Node2D wrapper.
func _resolve_character(root: Node) -> Node:
	if root == null:
		return null
	if root.has_signal(&"died"):
		return root
	for child in root.get_children():
		if child.has_signal(&"died"):
			return child
	return null


# ── Player spawning ───────────────────────────────────────────────────────────

func _spawn_players() -> void:
	print("RunManager: _spawn_players called, %d scene(s) assigned" % player_scenes.size())
	for i in player_scenes.size():
		var scene: PackedScene = player_scenes[i]
		if scene == null:
			print("RunManager: player_scenes[%d] is null, skipping" % i)
			continue

		var player_root: Node = scene.instantiate()
		if player_root == null:
			push_warning("RunManager: player_scenes[%d] failed to instantiate." % i)
			continue

		# Add as a sibling inside the level scene (reliable regardless of current_scene).
		get_parent().add_child(player_root)

		var point: Marker2D = _get_spawn_point(i)

		# The scene root may be a wrapper Node2D; find the actual character node.
		var character: Node = _resolve_character(player_root)
		if character == null:
			push_warning("RunManager: player_scenes[%d] (%s) has no node with a 'died' signal." % [i, player_root.name])
			_players.append(player_root)
			player_root.add_to_group("players")
			print("RunManager: spawned player [%d] '%s' at %s (no character node found)" % [i, player_root.name, player_root.global_position])
			continue

		# Position the character node itself — it's what moves, not the wrapper.
		if point != null:
			character.global_position = point.global_position

		_players.append(player_root)
		# Add the moving node to the group so the camera tracks it correctly.
		character.add_to_group("players")
		character.died.connect(_on_player_died.bind(player_root))
		print("RunManager: spawned player [%d] '%s' at %s" % [i, player_root.name, character.global_position])


func _get_spawn_point(index: int) -> Marker2D:
	if spawn_points.is_empty():
		push_warning("RunManager: no spawn_points assigned.")
		return null
	return spawn_points[mini(index, spawn_points.size() - 1)]


# ── Helpers ───────────────────────────────────────────────────────────────────

func _normalized_time() -> float:
	return clamp(time_elapsed / (curve_time_scale_minutes * 60.0), 0.0, 1.0)


func _sample_respawn_delay() -> float:
	if respawn_delay_curve == null:
		return 3.0
	return maxf(0.5, respawn_delay_curve.sample_baked(_normalized_time()))


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_castle_died() -> void:
	if _game_over:
		return
	_game_over = true

	if spawner != null:
		spawner.set_process(false)

	for player in _players:
		if player != null and player.has_method(&"is_dead_check") == false:
			# Duck-type the is_dead check.
			var dead: bool = player.get(&"is_dead") if "is_dead" in player else false
			if not dead:
				player.set_physics_process(false)
				player.set_process(false)
				player.set_process_input(false)
				player.set_process_unhandled_input(false)

	GameManager.change_state(GameManager.GameState.GAME_OVER)

	if game_over_screen != null and game_over_screen.has_method(&"show_screen"):
		game_over_screen.show_screen(time_elapsed)
	elif game_over_screen == null:
		push_warning("RunManager: no GameOverScreen assigned.")


func _on_player_died(player: Node) -> void:
	if _game_over:
		return

	if spawn_points.is_empty():
		push_warning("RunManager: spawn_points is empty — player cannot respawn. Add Marker2D children and assign them in the Inspector.")
		return

	var delay := _sample_respawn_delay()
	print("RunManager: player '%s' died, respawning in %.1f seconds" % [player.name, delay])
	get_tree().create_timer(delay).timeout.connect(
		_respawn_player.bind(player),
		CONNECT_ONE_SHOT
	)


func _respawn_player(player: Node) -> void:
	if _game_over:
		return

	var idx: int = _players.find(player)
	var point: Marker2D = _get_spawn_point(idx if idx >= 0 else 0)
	if point == null:
		return

	var character: Node = _resolve_character(player)
	if character != null and character.has_method(&"revive"):
		character.revive(point.global_position)
		print("RunManager: revived player '%s' at %s" % [player.name, point.global_position])
	elif player.has_method(&"revive"):
		player.revive(point.global_position)
		print("RunManager: revived player '%s' at %s" % [player.name, point.global_position])
	else:
		push_warning("RunManager: player '%s' has no revive() method." % player.name)

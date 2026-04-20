class_name RunManager
extends Node

# run_manager.gd — Coordinates run-level events: player spawning, respawning,
# and game-over when the castle dies.
#
# ── OFFLINE (SOLO) ────────────────────────────────────────────────────────────
#   Works exactly as before. Wire player_scenes, castle, spawner, and
#   game_over_screen in the Inspector.
#
# ── MULTIPLAYER ───────────────────────────────────────────────────────────────
#   When GameManager.session_id is non-empty, spawning is driven by
#   GameManager.peer_characters (set during WebRTC signaling). Wire
#   red_knight_scene and green_archer_scene in the Inspector.
#   Both peers spawn all characters; each character reads input only for the
#   peer that owns it (CharacterBase.network_peer_id).
#
# ── SCENE PLACEMENT ───────────────────────────────────────────────────────────
#   Add a plain Node to your level scene and attach this script.
#   Wire all Inspector exports before running.

# ── Scene References ──────────────────────────────────────────────────────────

@export_group("Scene References")
## The Castle node (castle.gd). Always present in the level scene; drag it here.
@export var castle: Node
## The EnemySpawner node. Will be paused when the run ends.
@export var spawner: Node
## CanvasLayer with game_over_screen.gd attached.
@export var game_over_screen: CanvasLayer

@export_group("Players (Offline)")
## Drag up to 3 player .tscn files here for solo / local-multiplayer runs.
## Ignored when a network session is active (peer_characters drives spawning instead).
@export var player_scenes: Array[PackedScene] = []

@export_group("Players (Online — wire both)")
## PackedScene for the Red Knight character (used in multiplayer spawning).
@export var red_knight_scene: PackedScene
## PackedScene for the Green Archer character (used in multiplayer spawning).
@export var green_archer_scene: PackedScene

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
var _heartbeat_timer: float = 0.0
const _HEARTBEAT_INTERVAL: float = 5.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(&"run_manager")
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
	# Host pushes elapsed time to Firebase so the lobby list shows live duration.
	if GameManager.is_host and GameManager.session_id != "":
		_heartbeat_timer += delta
		if _heartbeat_timer >= _HEARTBEAT_INTERVAL:
			_heartbeat_timer = 0.0
			FirebaseClient.update_session(GameManager.session_id,
				{"elapsed_seconds": int(time_elapsed), "last_seen": int(Time.get_unix_time_from_system())},
				func(_c, _d): pass)


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
	# In a network session, peer_characters drives which scenes spawn and who owns them.
	if GameManager.session_id != "":
		_spawn_players_networked()
		return

	# Offline / solo: use the inspector-assigned player_scenes array as before.
	print("RunManager: offline spawn — %d scene(s) assigned" % player_scenes.size())
	for i in player_scenes.size():
		var scene: PackedScene = player_scenes[i]
		if scene == null:
			continue
		_instantiate_player(scene, i, 1)  # peer_id=1 (local, single authority)


## In multiplayer, both peers spawn ALL characters. The character whose
## network_peer_id matches this peer's multiplayer ID responds to input;
## the other character is driven by incoming sync_state RPCs.
func _spawn_players_networked() -> void:
	# Map character key → scene.
	var char_scenes: Dictionary = {}
	if red_knight_scene != null:
		char_scenes["red_knight"] = red_knight_scene
	if green_archer_scene != null:
		char_scenes["green_archer"] = green_archer_scene

	print("RunManager: networked spawn | my_peer=%d | peer_characters=%s | registered_scenes=%s" % [
		multiplayer.get_unique_id(), str(GameManager.peer_characters), str(char_scenes.keys())
	])
	if char_scenes.is_empty():
		push_error("RunManager: both online character scenes are null. Open the level scene, select RunManager, and wire 'Red Knight Scene' and 'Green Archer Scene' under 'Players (Online)' in the Inspector.")
		return

	# peer_characters is sorted by peer_id (1, 2) so spawn order is deterministic
	# on both peers, giving both instances the same node name/path for RPC routing.
	var sorted_peer_ids: Array = GameManager.peer_characters.keys()
	sorted_peer_ids.sort()

	var spawn_index: int = 0
	for peer_id in sorted_peer_ids:
		var char_key: String = GameManager.peer_characters[peer_id]
		if not char_scenes.has(char_key):
			push_warning("RunManager: no scene registered for character '%s'" % char_key)
			spawn_index += 1
			continue
		var player_root: Node = _instantiate_player(char_scenes[char_key], spawn_index, peer_id)
		if player_root != null:
			# Set RPC authority to the owning peer so @rpc("authority") works correctly.
			var character: Node = _resolve_character(player_root)
			if character != null:
				character.set_multiplayer_authority(peer_id)
		spawn_index += 1


## Called mid-run when a joiner connects after the host already started.
## Spawns the joiner's character into the live scene.
func spawn_peer_mid_game(peer_id: int, character_key: String) -> void:
	var char_scenes: Dictionary = {}
	if red_knight_scene != null:
		char_scenes["red_knight"] = red_knight_scene
	if green_archer_scene != null:
		char_scenes["green_archer"] = green_archer_scene

	if not char_scenes.has(character_key):
		push_warning("RunManager: no scene for mid-game character '%s'" % character_key)
		return

	# spawn_index = position in sorted peer list (always index 1 since host is 0)
	var sorted_peers: Array = GameManager.peer_characters.keys()
	sorted_peers.sort()
	var spawn_index: int = sorted_peers.find(peer_id)
	if spawn_index < 0:
		spawn_index = _players.size()

	var player_root: Node = _instantiate_player(char_scenes[character_key], spawn_index, peer_id)
	if player_root == null:
		return
	var character: Node = _resolve_character(player_root)
	if character != null:
		character.set_multiplayer_authority(peer_id)
	print("RunManager: mid-game spawn of peer %d (%s)" % [peer_id, character_key])


## Instantiates one player scene, positions it at spawn_index, and tracks it.
## peer_id is stored on the character for input isolation.
## Returns the spawned root node (or null on failure).
func _instantiate_player(scene: PackedScene, spawn_index: int, peer_id: int) -> Node:
	var player_root: Node = scene.instantiate()
	if player_root == null:
		push_warning("RunManager: failed to instantiate scene for spawn index %d" % spawn_index)
		return null

	get_parent().add_child(player_root)

	var point: Marker2D = _get_spawn_point(spawn_index)
	var character: Node = _resolve_character(player_root)

	if character == null:
		push_warning("RunManager: spawned scene at index %d has no CharacterBase node." % spawn_index)
		_players.append(player_root)
		player_root.add_to_group("players")
		return player_root

	if point != null:
		character.global_position = point.global_position

	# Tell the character which peer owns it (used for input isolation in multiplayer).
	if character.has_method("set_network_peer_id") or "network_peer_id" in character:
		character.network_peer_id = peer_id

	_players.append(player_root)
	character.add_to_group("players")
	character.died.connect(_on_player_died.bind(player_root))
	print("RunManager: spawned '%s' (peer %d) at %s" % [player_root.name, peer_id, character.global_position])
	return player_root


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
	# In multiplayer, only the host triggers game-over; it broadcasts to all peers.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	rpc("_rpc_game_over", time_elapsed)


@rpc("authority", "reliable", "call_local")
func _rpc_game_over(elapsed: float) -> void:
	if _game_over:
		return
	_game_over = true

	if spawner != null:
		spawner.set_process(false)

	for player in _players:
		if player != null:
			player.set_process_mode(Node.PROCESS_MODE_DISABLED)

	GameManager.change_state(GameManager.GameState.GAME_OVER)

	if game_over_screen != null and game_over_screen.has_method(&"show_screen"):
		game_over_screen.show_screen(elapsed)
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

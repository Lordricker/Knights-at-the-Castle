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
## Maps player slot (1 = host, 2 = joiner) to character key ("red_knight" etc.).
## Used so respawn always uses the correct spawn point for that character.
var _slot_char: Dictionary = {}
## On host: the joiner's CharacterBase node (receives input_override each frame).
var _joiner_char_node: Node = null
## State snapshot broadcast counter.
var _state_broadcast_frame: int = 0
const _STATE_BROADCAST_EVERY: int = 6  # ≈10 snapshots per second at 60 fps


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(&"run_manager")
	GameManager.change_state(GameManager.GameState.PLAYING)

	_spawn_players.call_deferred()

	var castle_node: Node = _resolve_castle(castle)
	if castle_node != null:
		castle_node.died.connect(_on_castle_died)
		castle = castle_node
	else:
		push_warning("RunManager: could not find a Castle node with a 'died' signal — game-over will never trigger.")

	# Wire WebRTC packet handler for multiplayer runs.
	if GameManager.session_id != "":
		WebRTCManager.packet_received.connect(_on_packet_received)


func _process(delta: float) -> void:
	if _game_over:
		return
	time_elapsed += delta
	if GameManager.is_host and GameManager.session_id != "":
		# Heartbeat: update Firebase so lobby shows live run duration.
		_heartbeat_timer += delta
		if _heartbeat_timer >= _HEARTBEAT_INTERVAL:
			_heartbeat_timer = 0.0
			FirebaseClient.update_session(GameManager.session_id,
				{"elapsed_seconds": int(time_elapsed), "last_seen": int(Time.get_unix_time_from_system())},
				func(_c, _d): pass)
		# State broadcast to joiner every N frames.
		_state_broadcast_frame += 1
		if _state_broadcast_frame >= _STATE_BROADCAST_EVERY:
			_state_broadcast_frame = 0
			_broadcast_state()
	elif not GameManager.is_host and GameManager.session_id != "":
		# Joiner sends input every frame so host can drive character 2.
		_send_input()


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
		_instantiate_player(scene, i)


## In multiplayer each peer spawns ONLY its own character now.
## The peer's character is spawned when a "hello" packet is received (P2P handshake).
## This avoids any Firebase timing race for character lookup.
func _spawn_players_networked() -> void:
	var char_scenes: Dictionary = _char_scene_map()
	if char_scenes.is_empty():
		push_error("RunManager: no character scenes wired in the Inspector.")
		return

	var own_char: String = GameManager.my_character
	var own_slot: int = 1 if GameManager.is_host else 2
	_slot_char[own_slot] = own_char

	if not char_scenes.has(own_char):
		push_error("RunManager: no scene for character '%s'" % own_char)
		return

	var player_root: Node = _instantiate_player(char_scenes[own_char], _char_spawn_index(own_char))
	if player_root == null:
		return

	var ch: Node = _resolve_character(player_root)
	if ch != null:
		ch.set("player_slot", own_slot)
		if not GameManager.is_host:
			# Joiner: physics disabled — positions come from host state snapshots.
			ch.set_physics_process(false)

	# Announce ourselves to the peer. On the joiner this reaches the host's live RunManager.
	# On the host the packet is sent before any peer is connected and silently dropped.
	WebRTCManager.send_reliable({"t": "hello", "char": own_char, "slot": own_slot})


## Spawn a peer's character: either the joiner's char (on host) or the host's display
## char (on joiner). slot 1 = host char, slot 2 = joiner char.
func _spawn_peer_char(char_key: String, slot: int) -> void:
	var char_scenes: Dictionary = _char_scene_map()
	if not char_scenes.has(char_key):
		push_warning("RunManager: no scene for character '%s'" % char_key)
		return
	_slot_char[slot] = char_key

	var player_root: Node = _instantiate_player(char_scenes[char_key], _char_spawn_index(char_key))
	if player_root == null:
		return

	var ch: Node = _resolve_character(player_root)
	if ch == null:
		return

	ch.set("player_slot", slot)

	if GameManager.is_host and slot == 2:
		# Host: joiner's character runs physics driven by input_override dict.
		ch.set("use_input_override", true)
		_joiner_char_node = ch
		print("RunManager: joiner char (%s) spawned as slot 2 with input override" % char_key)
		# Flush all alive enemies so joiner's screen populates immediately.
		if spawner != null and spawner.has_method("send_all_alive_to_joiner"):
			spawner.send_all_alive_to_joiner()
	else:
		# Joiner: host char display — no physics, positions driven by state snapshots.
		ch.set_physics_process(false)
		print("RunManager: peer char (%s) spawned as slot %d display" % [char_key, slot])


## Returns a dict mapping character key to PackedScene for all wired characters.
func _char_scene_map() -> Dictionary:
	var d: Dictionary = {}
	if red_knight_scene != null:   d["red_knight"]   = red_knight_scene
	if green_archer_scene != null: d["green_archer"] = green_archer_scene
	return d


## Maps character key to spawn_points index.
## Knight=0, Archer=1, Rogue=2 (matching the user-configured Marker2D order).
func _char_spawn_index(char_key: String) -> int:
	match char_key:
		"red_knight":   return 0
		"green_archer": return 1
		"rogue":        return 2
	return 0


## Instantiates one player scene, positions it at spawn_index, and tracks it.
## Returns the spawned root node (or null on failure).
func _instantiate_player(scene: PackedScene, spawn_index: int) -> Node:
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

	_players.append(player_root)
	character.add_to_group("players")
	character.died.connect(_on_player_died.bind(player_root))
	print("RunManager: spawned '%s' at %s" % [player_root.name, character.global_position])
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
	# Only the host can trigger game-over (it is the sole simulation authority).
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	# In multiplayer, broadcast game-over to the joiner.
	if GameManager.session_id != "":
		WebRTCManager.send_reliable({"t": "gameover", "elapsed": time_elapsed})
	_trigger_game_over(time_elapsed)


# ── Multiplayer packet handling ───────────────────────────────────────────────

## Handles all inbound WebRTC data-channel packets.
func _on_packet_received(data: Dictionary) -> void:
	var t: String = data.get("t", "")
	match t:
		"hello":
			_on_hello_packet(data)
		"hello_ack":
			_on_hello_ack_packet(data)
		"inp":
			_apply_p2_input(data)
		"spawn":
			if spawner != null and spawner.has_method("on_spawn_packet"):
				spawner.on_spawn_packet(data)
		"despawn":
			if spawner != null and spawner.has_method("on_despawn_packet"):
				spawner.on_despawn_packet(data)
		"state":
			_apply_state_snapshot(data)
		"gameover":
			_trigger_game_over(float(data.get("elapsed", time_elapsed)))


## Host receives "hello" from joiner — spawn the joiner's character and reply.
func _on_hello_packet(data: Dictionary) -> void:
	if not GameManager.is_host:
		# Shouldn't happen, but safe-guard.
		return
	var char_key: String = data.get("char", "")
	var slot: int = int(data.get("slot", 2))
	if char_key.is_empty():
		push_warning("RunManager: received hello packet with no char key")
		return
	print("RunManager HOST: got hello from joiner char=%s slot=%d" % [char_key, slot])
	_spawn_peer_char(char_key, slot)
	# Tell the joiner our character so they can spawn our display.
	WebRTCManager.send_reliable({"t": "hello_ack", "char": GameManager.my_character, "slot": 1})


## Joiner receives "hello_ack" from host — spawn the host's display character.
func _on_hello_ack_packet(data: Dictionary) -> void:
	if GameManager.is_host:
		return
	var char_key: String = data.get("char", "")
	var slot: int = int(data.get("slot", 1))
	if char_key.is_empty():
		push_warning("RunManager: received hello_ack packet with no char key")
		return
	print("RunManager JOINER: got hello_ack from host char=%s slot=%d" % [char_key, slot])
	_spawn_peer_char(char_key, slot)


## Host: apply received joiner input to the joiner's character input_override dict.
## Using a dict is more reliable than Input.action_press in HTML5 exports.
func _apply_p2_input(data: Dictionary) -> void:
	if _joiner_char_node == null:
		return
	_joiner_char_node.set("input_override", {
		"move_left":  bool(data.get("l",  false)),
		"move_right": bool(data.get("r",  false)),
		"move_up":    bool(data.get("u",  false)),
		"move_down":  bool(data.get("d",  false)),
		"face_lock":  bool(data.get("fl", false)),
		"action1":    bool(data.get("a1", false)),
		"action2":    bool(data.get("a2", false)),
		"action3":    bool(data.get("a3", false)),
	})


## Joiner sends its local input state to the host every _process() frame.
func _send_input() -> void:
	WebRTCManager.send_unreliable({
		"t":  "inp",
		"l":  Input.is_action_pressed("move_left"),
		"r":  Input.is_action_pressed("move_right"),
		"u":  Input.is_action_pressed("move_up"),
		"d":  Input.is_action_pressed("move_down"),
		"fl": Input.is_action_pressed("face_lock"),
		"a1": Input.is_action_pressed("action1"),
		"a2": Input.is_action_pressed("action2"),
		"a3": Input.is_action_pressed("action3"),
	})


## Host builds and sends a state snapshot to the joiner.
## Character positions are keyed by player_slot ("1" or "2") so ordering in _players
## does not need to match between host and joiner.
func _broadcast_state() -> void:
	var char_data: Dictionary = {}
	for player_root in _players:
		var ch: Node = _resolve_character(player_root)
		if ch == null:
			continue
		var slot: int = int(ch.get("player_slot")) if "player_slot" in ch else 1
		var anim_spr := ch.get("animated_sprite") as AnimatedSprite2D
		char_data[str(slot)] = {
			"x":  ch.global_position.x,
			"y":  ch.global_position.y,
			"f":  ch.get("facing") if "facing" in ch else 1.0,
			"hp": ch.health if "health" in ch else 0.0,
			"an": anim_spr.animation if anim_spr != null else "",
		}

	var enemy_data: Dictionary = {}
	if spawner != null and "alive_enemy_map" in spawner:
		for eid in spawner.alive_enemy_map:
			var info: Dictionary = spawner.alive_enemy_map[eid]
			var enemy: Node = info.get("node") as Node
			if is_instance_valid(enemy):
				enemy_data[str(eid)] = {
					"x":  enemy.global_position.x,
					"y":  enemy.global_position.y,
					"hp": enemy.health if "health" in enemy else 0.0,
				}

	WebRTCManager.send_unreliable({
		"t":        "state",
		"c":        char_data,
		"e":        enemy_data,
		"castle_hp": castle.health if "health" in castle else 0.0,
		"elapsed":  time_elapsed,
	})


## Joiner applies a state snapshot to local display nodes.
func _apply_state_snapshot(data: Dictionary) -> void:
	time_elapsed = float(data.get("elapsed", time_elapsed))

	# Update spawner's timer so difficulty curve stays in sync.
	if spawner != null and "time_elapsed" in spawner:
		spawner.time_elapsed = time_elapsed

	# Update character positions and facing.
	# char_data is keyed by player_slot string ("1" or "2") so ordering doesn't matter.
	var char_data: Dictionary = data.get("c", {})
	for player_root in _players:
		var ch: Node = _resolve_character(player_root)
		if ch == null:
			continue
		var slot_str: String = str(int(ch.get("player_slot")) if "player_slot" in ch else 1)
		if not char_data.has(slot_str):
			continue
		var cd: Dictionary = char_data[slot_str]
		ch.global_position = Vector2(float(cd.get("x", ch.global_position.x)),
									 float(cd.get("y", ch.global_position.y)))
		# Sync facing.
		if cd.has("f") and "facing" in ch:
			var f := float(cd["f"])
			if ch.get("facing") != f:
				ch.set("facing", f)
				if ch.has_method("_apply_facing"):
					ch.call("_apply_facing")
		# Sync animation — play only when it changes to avoid resetting mid-loop.
		if cd.has("an"):
			var spr := ch.get("animated_sprite") as AnimatedSprite2D
			var anim: StringName = cd["an"]
			if spr != null and not anim.is_empty() and spr.animation != anim:
				spr.play(anim)

	# Update castle HP.
	if castle != null and data.has("castle_hp") and "health" in castle:
		var new_hp: float = float(data["castle_hp"])
		if castle.health != new_hp:
			castle.health = new_hp
			if castle.has_signal("health_changed"):
				castle.emit_signal("health_changed", new_hp,
					castle.max_health if "max_health" in castle else 500.0)

	# Route enemy positions to spawner for lerp application.
	if spawner != null and spawner.has_method("apply_enemy_state"):
		spawner.apply_enemy_state(data.get("e", {}))


## Final common path for ending the run on both host and joiner.
func _trigger_game_over(elapsed: float) -> void:
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

	# Use the character's slot to look up which spawn point to use.
	var character: Node = _resolve_character(player)
	var slot: int = int(character.get("player_slot")) if character != null and "player_slot" in character else 1
	var char_key: String = _slot_char.get(slot, "")
	var spawn_idx: int = _char_spawn_index(char_key) if not char_key.is_empty() else 0
	var point: Marker2D = _get_spawn_point(spawn_idx)
	if point == null:
		return

	if character != null and character.has_method(&"revive"):
		character.revive(point.global_position)
		print("RunManager: revived player '%s' (slot %d) at %s" % [player.name, slot, point.global_position])
	elif player.has_method(&"revive"):
		player.revive(point.global_position)
		print("RunManager: revived player '%s' at %s" % [player.name, point.global_position])
	else:
		push_warning("RunManager: player '%s' has no revive() method." % player.name)

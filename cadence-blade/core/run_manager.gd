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
## The CastleInside node (castle_inside.gd). Needed to route upgrade network packets.
@export var castle_inside: Node

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
var _state_snapshot_timer: float = 0.0
const _STATE_SNAPSHOT_INTERVAL: float = 1.0 / 20.0
const _FLOW_STATE_SNAPSHOT_INTERVAL: float = 1.0 / 30.0
## Joiner: target positions received from state snapshots, keyed by player_slot int.
## Remote characters interpolate toward these; the locally owned joiner slot
## only uses them for server correction.
var _char_net_targets: Dictionary = {}
const _REMOTE_MOVE_SPEED: float = 600.0
const _OWNED_RECONCILE_BLEND: float = 12.0
const _OWNED_RECONCILE_SNAP_DISTANCE: float = 96.0
## Host: tracks per-slot flow active state from last frame to detect transitions.
## When flow goes true→false, a reliable "flow_done" packet is sent immediately.
var _prev_flow_states: Dictionary = {}
var _joiner_last_input_seq: int = -1
var _next_input_seq: int = 0
var _last_acked_input_seq: int = -1
var _pending_inputs: Array[Dictionary] = []
## Host: true while the joiner's character is standing in the monk healing zone.
var _joiner_in_monk_zone: bool = false
## Host: heal rate (HP/sec) to apply to the joiner puppet while in the monk zone.
var _joiner_heal_rate: float = 5.0


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
		# Auto-find CastleInside if not wired in Inspector.
		if castle_inside == null:
			castle_inside = _find_castle_inside()
		if castle_inside == null:
			push_warning("RunManager: castle_inside not assigned — upgrade packets will be ignored.")
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
		# Detect flow-state transitions per slot and broadcast "flow_done" immediately
		# so the joiner hides the bar without waiting for the next state snapshot.
		for _pr2 in _players:
			var _ch2: Node = _resolve_character(_pr2)
			if _ch2 == null:
				continue
			var _slot2: int = int(_ch2.get("player_slot")) if "player_slot" in _ch2 else 1
			var _flow_now: bool = bool(_ch2.get("_flow_active")) if "_flow_active" in _ch2 else false
			var _flow_prev: bool = _prev_flow_states.get(_slot2, false)
			if _flow_prev and not _flow_now:
				WebRTCManager.send_reliable({"t": "flow_done", "slot": _slot2})
			_prev_flow_states[_slot2] = _flow_now
		# Use a time-based snapshot cadence so network updates stay stable even if
		# the host render framerate fluctuates. Flow-active attacks get a faster rate.
		_state_snapshot_timer += delta
		var snapshot_interval: float = _FLOW_STATE_SNAPSHOT_INTERVAL if _any_flow_active() else _STATE_SNAPSHOT_INTERVAL
		while _state_snapshot_timer >= snapshot_interval:
			_state_snapshot_timer -= snapshot_interval
			_broadcast_state()
		# Apply monk healing to the joiner's puppet so the healed HP is included in
		# the next state snapshot (rather than the joiner healing locally and being
		# overwritten by the next snapshot). Emit health_changed so the host's
		# HP bar for the joiner's puppet redraws in real time.
		if _joiner_in_monk_zone and _joiner_char_node != null and is_instance_valid(_joiner_char_node):
			if "health" in _joiner_char_node and "max_health" in _joiner_char_node:
				var _jc_dead: bool = bool(_joiner_char_node.get("is_dead")) if "is_dead" in _joiner_char_node else false
				if not _jc_dead:
					var _jc_new_hp: float = minf(_joiner_char_node.health + _joiner_heal_rate * delta, _joiner_char_node.max_health)
					if _jc_new_hp != _joiner_char_node.health:
						_joiner_char_node.health = _jc_new_hp
						if _joiner_char_node.has_signal(&"health_changed"):
							_joiner_char_node.emit_signal(&"health_changed", _jc_new_hp, _joiner_char_node.max_health)
	elif not GameManager.is_host and GameManager.session_id != "":
		# Joiner sends own character's position and animation every frame.
		_send_joiner_pos()
		# Remote characters (host slot 1) move toward host snapshots.
		# Joiner's own character (slot 2) owns its position — no host correction applied.
		for player_root in _players:
			var ch: Node = _resolve_character(player_root)
			if ch == null:
				continue
			var slot: int = int(ch.get("player_slot")) if "player_slot" in ch else 1
			if _is_locally_owned_slot(slot):
				continue  # Joiner owns its own character's position entirely.
			if not _char_net_targets.has(slot):
				continue
			var target: Vector2 = _char_net_targets[slot]
			var dist: float = ch.global_position.distance_to(target)
			if dist > 300.0:
				ch.global_position = target  # teleport if too far off
			else:
				ch.global_position = ch.global_position.move_toward(target, _REMOTE_MOVE_SPEED * delta)


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


## Searches the scene tree for a CastleInside node (has on_upgrade_offers method).
## Uses a recursive search so CastleInside can be nested at any depth in the level.
func _find_castle_inside() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	for child in scene.find_children("*", "", true, false):
		if child.has_method("on_upgrade_offers"):
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
	# If a character was played previously (GameManager.my_character is set),
	# find the matching scene so restarts always respawn the same character.
	print("RunManager: offline spawn — %d scene(s) assigned" % player_scenes.size())
	var remembered: String = GameManager.my_character
	if remembered != "":
		# Find the player_scenes index that matches the remembered character key.
		var target_scene: PackedScene = null
		var target_idx: int = 0
		var scene_map: Dictionary = _char_scene_map()
		if scene_map.has(remembered):
			target_scene = scene_map[remembered]
		else:
			# Fall back: compare PackedScene resources against the player_scenes array.
			var key_order: Array[String] = ["red_knight", "green_archer"]
			for i in player_scenes.size():
				if i < key_order.size() and key_order[i] == remembered:
					target_scene = player_scenes[i]
					target_idx = i
					break
		if target_scene == null and not player_scenes.is_empty():
			# Could not identify scene — fall back to first slot.
			target_scene = player_scenes[0]
			target_idx = 0
		if target_scene != null:
			_slot_char[1] = remembered
			_instantiate_player(target_scene, _char_spawn_index(remembered))
			return
	# No remembered character — spawn all assigned scenes and record the first.
	var key_order_default: Array[String] = ["red_knight", "green_archer"]
	for i in player_scenes.size():
		var scene: PackedScene = player_scenes[i]
		if scene == null:
			continue
		_instantiate_player(scene, i)
		# Record the character key for the first spawned player so restarts remember it.
		if i < key_order_default.size() and GameManager.my_character == "":
			GameManager.my_character = key_order_default[i]
			_slot_char[1] = GameManager.my_character


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
		# Joiner runs the character fully locally — movement, attacks, and flow bars.
		# Position and attack results are sent to the host rather than derived from input.

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
		# Host: joiner's character is a position puppet.
		# Position is set directly from "jpos" packets; attacks are locked so only the joiner
		# side runs flow bars, then sends resolved hits via "flow_fire" / "melee_hit" packets.
		ch.set("attacks_locked", true)
		ch.set_physics_process(false)
		_joiner_char_node = ch
		print("RunManager: joiner char (%s) spawned as slot 2 position puppet" % char_key)
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


func _is_locally_owned_slot(slot: int) -> bool:
	return GameManager.session_id != "" and not GameManager.is_host and slot == 2


func _any_flow_active() -> bool:
	for player_root in _players:
		var ch: Node = _resolve_character(player_root)
		if ch != null and "_flow_active" in ch and bool(ch.get("_flow_active")):
			return true
	return false


func _trim_acked_inputs(ack_seq: int) -> void:
	while not _pending_inputs.is_empty():
		var first_seq: int = int(_pending_inputs[0].get("seq", -1))
		if first_seq > ack_seq:
			break
		_pending_inputs.remove_at(0)


func _is_locomotion_animation(anim: StringName) -> bool:
	return anim.is_empty() or anim == &"idle" or anim == &"running" or anim == &"heal"


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
		"jpos":
			# Joiner sent its position and animation — apply to the host puppet.
			if GameManager.is_host:
				_apply_joiner_pos(data)
		"flow_fire":
			# Joiner resolved a ranged attack — fire the real arrow on the host.
			_handle_flow_fire(data)
		"melee_hit":
			# Joiner's melee hitbox struck an enemy — apply damage on the host.
			_handle_melee_hit(data)
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
		"restart":
			# Host has restarted — joiner reloads to match.
			if not GameManager.is_host:
				get_tree().reload_current_scene()
		"coins_add":
			# Host collected a coin — add to all joiner-side players (shared pool) and remove display coin.
			if not GameManager.is_host:
				var v: int = int(data.get("v", 1))
				for player_root in _players:
					var ch: Node = _resolve_character(player_root)
					if ch != null and ch.has_method("add_coins"):
						ch.add_coins(v)
						break  # add once — HUD connects to first player only
				# Remove the joiner-side display coin.
				var coin_id: int = int(data.get("coin_id", -1))
				if coin_id >= 0:
					var scene := get_tree().current_scene
					if scene != null and scene.has_method("despawn_display_coin"):
						scene.call("despawn_display_coin", coin_id)
		"arrow":
			# Host fired an arrow — spawn a display-only arrow on joiner.
			if not GameManager.is_host:
				_spawn_display_arrow(data)
		"enemy_arrow":
			# Host enemy fired an arrow — spawn a display-only copy on joiner.
			if not GameManager.is_host:
				_spawn_display_enemy_arrow(data)
		"flow_done":
			# Host resolved a flow bar — update joiner display immediately.
			if not GameManager.is_host:
				_apply_flow_done(data)
		"coin_spawn":
			# Host spawned a coin — show it visually on joiner.
			if not GameManager.is_host:
				var scene := get_tree().current_scene
				if scene != null and scene.has_method("spawn_display_coin"):
					scene.call("spawn_display_coin", data)
		"upgrade_offers":
			# Host rolled new shop offers — joiner updates their displayed options.
			if not GameManager.is_host and castle_inside != null and castle_inside.has_method("on_upgrade_offers"):
				castle_inside.call("on_upgrade_offers", data)
		"upgrade_buy":
			# Joiner wants to buy an upgrade — host validates and applies.
			if GameManager.is_host and castle_inside != null and castle_inside.has_method("on_upgrade_buy"):
				castle_inside.call("on_upgrade_buy", data)
		"upgrade_applied":
			# Host applied an upgrade — joiner syncs coins and personal stats.
			if not GameManager.is_host and castle_inside != null and castle_inside.has_method("on_upgrade_applied"):
				castle_inside.call("on_upgrade_applied", data)
		"upgrade_denied":
			# Host rejected joiner's buy request (insufficient coins).
			if not GameManager.is_host and castle_inside != null and castle_inside.has_method("on_upgrade_denied"):
				castle_inside.call("on_upgrade_denied", data)
		"monk_zone":
			# Joiner entered or exited the monk healing zone — host tracks this and
			# applies the same healing rate to the joiner's puppet each frame so the
			# state snapshot reflects the healed HP (local joiner healing would be
			# overwritten by the snapshot otherwise).
			if GameManager.is_host:
				_joiner_in_monk_zone = int(data.get("in", 0)) == 1
				if _joiner_in_monk_zone and castle_inside != null and "heal_per_second" in castle_inside:
					_joiner_heal_rate = float(castle_inside.get("heal_per_second"))
		"request_upgrade_offers":
			# Joiner entered blacksmith zone with no cached offers — send current ones.
			if GameManager.is_host and castle_inside != null and castle_inside.has_method("on_request_upgrade_offers"):
				castle_inside.call("on_request_upgrade_offers")


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


## Host: apply received joiner position and animation to the puppet character.
func _apply_joiner_pos(data: Dictionary) -> void:
	if _joiner_char_node == null:
		return
	_joiner_char_node.global_position = Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var f: float = float(data.get("f", 1.0))
	if "facing" in _joiner_char_node and _joiner_char_node.get("facing") != f:
		_joiner_char_node.set("facing", f)
		if _joiner_char_node.has_method("_apply_facing"):
			_joiner_char_node.call("_apply_facing")
	var anim_spr := _joiner_char_node.get("animated_sprite") as AnimatedSprite2D
	if anim_spr != null:
		var anim: StringName = data.get("an", &"")
		var is_paused: bool = int(data.get("sp", 0)) == 1
		var target_frame: int = int(data.get("fr", 0))
		if not anim.is_empty() and anim_spr.animation != anim:
			anim_spr.play(anim)
		if is_paused:
			anim_spr.frame = target_frame
			anim_spr.pause()
		elif not anim_spr.is_playing():
			anim_spr.play()


## Joiner broadcasts its own character's world position and animation state every frame.
## The host applies this directly to the puppet node — no physics simulation on host side.
func _send_joiner_pos() -> void:
	for player_root in _players:
		var ch: Node = _resolve_character(player_root)
		if ch == null:
			continue
		var slot: int = int(ch.get("player_slot")) if "player_slot" in ch else 1
		if not _is_locally_owned_slot(slot):
			continue
		# Don't send position while dead — the host respawns the puppet at the spawn point
		# and jpos packets with the death position would overwrite it before the joiner
		# receives the updated state snapshot, causing the joiner to revive at the wrong spot.
		if "is_dead" in ch and bool(ch.get("is_dead")):
			break
		var anim_spr := ch.get("animated_sprite") as AnimatedSprite2D
		WebRTCManager.send_unreliable({
			"t":  "jpos",
			"x":  ch.global_position.x,
			"y":  ch.global_position.y,
			"f":  ch.get("facing") if "facing" in ch else 1.0,
			"an": anim_spr.animation if anim_spr != null else "",
			"fr": anim_spr.frame if anim_spr != null else 0,
			"sp": 1 if (anim_spr != null and not anim_spr.is_playing()) else 0,
		})
		break  # Only one locally-owned character per session.


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
		# Flow bar state: read from the bar node's internal progress if available.
		var flow_active: bool = bool(ch.get("_flow_active")) if "_flow_active" in ch else false
		var flow_progress: float = 0.0
		var flow_ws: float = 0.45  # window start default
		var flow_we: float = 0.60  # window end default
		var flow_missed: bool = false
		if flow_active:
			var fba: Node = ch.get("_flow_bar_api") as Node
			if fba != null:
				if "_progress" in fba:
					flow_progress = float(fba.get("_progress"))
				if "success_window_start" in fba:
					flow_ws = float(fba.get("success_window_start"))
				if "success_window_end" in fba:
					flow_we = float(fba.get("success_window_end"))
				# Detect missed state by checking if fill color is no longer the waiting color.
				if "_attempt_used" in fba and bool(fba.get("_attempt_used")):
					flow_missed = true
			elif "_flow_progress" in ch:
				flow_progress = float(ch.get("_flow_progress"))
		char_data[str(slot)] = {
			"x":  ch.global_position.x,
			"y":  ch.global_position.y,
			"f":  ch.get("facing") if "facing" in ch else 1.0,
			"hp": ch.health if "health" in ch else 0.0,
			"an": anim_spr.animation if anim_spr != null else "",
			"fr": anim_spr.frame if anim_spr != null else 0,
			"sp": 1 if (anim_spr != null and not anim_spr.is_playing()) else 0,
			"fl": 1 if flow_active else 0,
			"fp": flow_progress,
			"fws": flow_ws,
			"fwe": flow_we,
			"fm": 1 if flow_missed else 0,
		}

	var enemy_data: Dictionary = {}
	if spawner != null and "alive_enemy_map" in spawner:
		for eid in spawner.alive_enemy_map:
			var info: Dictionary = spawner.alive_enemy_map[eid]
			var enemy: Node = info.get("node") as Node
			if is_instance_valid(enemy):
				var ed: Dictionary = {
					"x":  enemy.global_position.x,
					"y":  enemy.global_position.y,
					"hp": enemy.health if "health" in enemy else 0.0,
					"f":  enemy.get("facing") if "facing" in enemy else 1.0,
				}
				# Only add animation key when non-default to keep packet small.
				# Absence of "a" means "running" on the joiner side.
				var e_spr := enemy.get("animated_sprite") as AnimatedSprite2D
				if e_spr != null and e_spr.animation != &"running" and e_spr.animation != &"":
					ed["a"] = e_spr.animation
				enemy_data[str(eid)] = ed

	WebRTCManager.send_unreliable({
		"t":        "state",
		"c":        char_data,
		"e":        enemy_data,
		"ack":      _joiner_last_input_seq,
		"castle_hp": castle.health if "health" in castle else 0.0,
		"elapsed":  time_elapsed,
	})


## Joiner applies a state snapshot to local display nodes.
func _apply_state_snapshot(data: Dictionary) -> void:
	time_elapsed = float(data.get("elapsed", time_elapsed))
	var ack_seq: int = int(data.get("ack", -1))
	if ack_seq > _last_acked_input_seq:
		_last_acked_input_seq = ack_seq
		_trim_acked_inputs(ack_seq)

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
		var slot_int: int = int(slot_str)
		var is_local: bool = _is_locally_owned_slot(slot_int)
		# Always store server position — used as revive anchor even for the locally-owned slot.
		# Position correction in _process is skipped for the joiner's own character.
		_char_net_targets[slot_int] = Vector2(
			float(cd.get("x", ch.global_position.x)),
			float(cd.get("y", ch.global_position.y)))
		# Sync HP — emit health_changed so both the sprite bar and any HUD bar update.
		if cd.has("hp") and "health" in ch:
			var new_hp: float = float(cd["hp"])
			var max_hp: float = ch.max_health if "max_health" in ch else 100.0
			if "is_dead" in ch and bool(ch.get("is_dead")) and new_hp > 0.0 and ch.has_method(&"revive"):
				ch.revive(_char_net_targets[int(slot_str)])
			elif "is_dead" in ch and not bool(ch.get("is_dead")) and new_hp <= 0.0 and ch.has_method(&"die"):
				ch.die()
			if ch.health != new_hp:
				ch.health = new_hp
				ch.health_changed.emit(new_hp, max_hp)
		# Joiner owns its own character's movement, animation, and flow bar.
		# Only HP is taken from the host (authoritative on damage and death).
		if is_local:
			continue
		# Sync facing.
		if cd.has("f") and "facing" in ch:
			var f := float(cd["f"])
			if ch.get("facing") != f:
				ch.set("facing", f)
				if ch.has_method("_apply_facing"):
					ch.call("_apply_facing")
		# Sync animation — play only when it changes to avoid resetting mid-loop.
		# Also sync the frame and paused state so attack windups display correctly.
		if cd.has("an"):
			var spr := ch.get("animated_sprite") as AnimatedSprite2D
			var anim: StringName = cd["an"]
			var target_frame: int = int(cd.get("fr", 0))
			var is_paused: bool = int(cd.get("sp", 0)) == 1
			var is_local_owned: bool = _is_locally_owned_slot(int(slot_str))
			if is_local_owned:
				if _is_locomotion_animation(anim):
					if ch.has_method("clear_network_animation_override"):
						ch.call("clear_network_animation_override")
				elif ch.has_method("set_network_animation_override"):
					ch.call("set_network_animation_override", anim)
			if spr != null and not anim.is_empty():
				if is_local_owned and _is_locomotion_animation(anim):
					pass
				else:
					var should_restart: bool = spr.animation != anim
					if not should_restart and not is_paused and not spr.is_playing():
						should_restart = true
					if should_restart:
						spr.play(anim)
					if is_paused:
						# Snap to the broadcasted frame then pause so the windup holds.
						spr.frame = target_frame
						spr.pause()
		# Sync flow bar visibility and fill progress.
		# flow_bar points to the FlowBar root Node2D (no script).
		# _flow_bar_api points to the FlowTimingBar child (has display_sync/stop_flow).
		var flow_active: bool = int(cd.get("fl", 0)) == 1
		var flow_progress: float = float(cd.get("fp", 0.0))
		var flow_ws: float = float(cd.get("fws", 0.45))
		var flow_we: float = float(cd.get("fwe", 0.60))
		var flow_missed: bool = int(cd.get("fm", 0)) == 1
		var fb_root: Node = ch.get("flow_bar") as Node
		var fba: Node = ch.get("_flow_bar_api") as Node
		if flow_active:
			if fb_root != null:
				fb_root.show()
			if fba != null and fba.has_method("display_sync"):
				fba.display_sync(flow_progress, flow_ws, flow_we, flow_missed)
		else:
			if fba != null and fba.has_method("stop_flow"):
				fba.stop_flow()
			if fb_root != null:
				fb_root.hide()

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
	if GameManager.session_id != "" and not GameManager.is_host:
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


## Joiner: spawn a visual-only enemy arrow from an "enemy_arrow" packet.
## No damage, no collision — purely visual.
func _spawn_display_enemy_arrow(data: Dictionary) -> void:
	# Try player characters first (archer player has arrow_scene).
	var scene: PackedScene
	for player_root in _players:
		var ch := _resolve_character(player_root)
		if ch != null and "arrow_scene" in ch:
			var found := ch.get("arrow_scene") as PackedScene
			if found != null:
				scene = found
				break
	# Fall back to spawner's alive enemy instances (one may be a black_archer).
	if scene == null and spawner != null and "alive_enemy_map" in spawner:
		for eid in spawner.alive_enemy_map:
			var info: Dictionary = spawner.alive_enemy_map[eid]
			var enemy: Node = info.get("node") as Node
			if is_instance_valid(enemy) and "arrow_scene" in enemy:
				var found := enemy.get("arrow_scene") as PackedScene
				if found != null:
					scene = found
					break
	if scene == null:
		return
	var arrow := scene.instantiate() as Arrow
	if arrow == null:
		return
	var pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var dir := Vector2(float(data.get("dx", 1.0)), float(data.get("dy", 0.0)))
	var spd: float = float(data.get("sp", 400.0))
	var lt: float = float(data.get("lt", 2.5))
	arrow.configure(pos, dir, spd, 0.0, 0.0)
	arrow.lifetime = lt
	# Keep detection mask so the arrow stops when it hits a player or the castle,
	# matching the host's visual behaviour.  Layer 0 so nothing targets this arrow.
	# Damage and knockback are both 0.0, so collision is purely cosmetic.
	arrow.collision_mask = 1
	arrow.collision_layer = 0
	get_tree().current_scene.call_deferred("add_child", arrow)


## Joiner: spawn a visual-only arrow from an "arrow" packet.
## Damage stays at 0, but collision remains active so non-piercing arrows stop on first enemy visually.
func _spawn_display_arrow(data: Dictionary) -> void:
	# Find the arrow scene from any spawned archer character (avoids needing a separate export).
	var scene: PackedScene
	for player_root in _players:
		var ch := _resolve_character(player_root)
		if ch != null and "arrow_scene" in ch:
			var found := ch.get("arrow_scene") as PackedScene
			if found != null:
				scene = found
				break
	if scene == null:
		return
	var arrow := scene.instantiate() as Arrow
	if arrow == null:
		return
	var pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var dir := Vector2(float(data.get("dx", 1.0)), float(data.get("dy", 0.0)))
	var spd: float = float(data.get("sp", 600.0))
	# Configure position/velocity before entering the tree; damage is 0 so no harm on hit.
	arrow.configure(pos, dir, spd, 0.0, 0.0)
	# Set pierce flag so it doesn't stop (display arrows have no collision anyway,
	# but setting it keeps behaviour consistent if collision mask is ever changed).
	if int(data.get("pi", 0)) == 1:
		arrow.pierce = true
	# Apply combo particle color so the joiner sees the same tint.
	var combo_hits: int = int(data.get("cc", 0))
	if combo_hits >= 2:
		arrow.set_combo_color(arrow.combo_color_2)
	elif combo_hits == 1:
		arrow.set_combo_color(arrow.combo_color_1)
	# Arrow._physics_process handles movement visually; lifetime timer auto-frees it.
	get_tree().current_scene.call_deferred("add_child", arrow)


## Joiner: immediately hide the flow bar when the host reports flow has resolved.
## Sent via reliable channel so it arrives even if a state snapshot is delayed.
func _apply_flow_done(data: Dictionary) -> void:
	var slot: int = int(data.get("slot", 0))
	for player_root in _players:
		var ch: Node = _resolve_character(player_root)
		if ch == null:
			continue
		var ch_slot: int = int(ch.get("player_slot")) if "player_slot" in ch else 1
		if ch_slot != slot:
			continue
		var fb_root: Node = ch.get("flow_bar") as Node
		var fba: Node = ch.get("_flow_bar_api") as Node
		if fba != null and fba.has_method("stop_flow"):
			fba.stop_flow()
		if fb_root != null:
			fb_root.hide()
		break


## Host: joiner resolved a ranged attack — fire the real damaging arrow.
## The joiner already rendered a local visual/tracking arrow so no display packet is sent back.
func _handle_flow_fire(data: Dictionary) -> void:
	if not GameManager.is_host or _joiner_char_node == null:
		return
	var scene := _joiner_char_node.get("arrow_scene") as PackedScene
	if scene == null:
		return
	var arrow := scene.instantiate() as Arrow
	if arrow == null:
		return
	var pos      := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var dir      := Vector2(float(data.get("dx", 1.0)), float(data.get("dy", 0.0)))
	var spd      : float = float(data.get("sp", 600.0))
	var dmg      : float = float(data.get("dmg", 0.0))
	var combo_hits: int  = int(data.get("cc", 0))
	var is_pierce: bool  = int(data.get("pi", 0)) == 1
	var flow_suc : bool  = int(data.get("s", 0)) == 1
	var kbf_key: String  = "pierce_knockback_force" if is_pierce else "arrow_knockback_force"
	var kbf: float = float(_joiner_char_node.get(kbf_key)) if kbf_key in _joiner_char_node else 200.0
	arrow.configure(pos, dir, spd, dmg, kbf, flow_suc)
	if is_pierce:
		arrow.pierce = true
	if combo_hits >= 2:
		arrow.set_combo_color(arrow.combo_color_2)
	elif combo_hits == 1:
		arrow.set_combo_color(arrow.combo_color_1)
	get_tree().current_scene.call_deferred("add_child", arrow)


## Host: joiner's melee hitbox struck an enemy — look it up by spawn_id and apply the hit.
func _handle_melee_hit(data: Dictionary) -> void:
	if not GameManager.is_host:
		return
	if spawner == null or not "alive_enemy_map" in spawner:
		return
	var eid: int = int(data.get("eid", -1))
	var enemy_map := spawner.alive_enemy_map as Dictionary
	if eid < 0 or not enemy_map.has(eid):
		return
	var enemy: Node = (enemy_map[eid] as Dictionary).get("node") as Node
	if not is_instance_valid(enemy):
		return
	var dmg : float = float(data.get("dmg", 0.0))
	var kbf : float = float(data.get("kbf", 0.0))
	var kb_src := Vector2(float(data.get("kbx", 0.0)), float(data.get("kby", 0.0)))
	var s : bool = int(data.get("s", 0)) == 1
	if enemy.has_method("take_damage"):
		enemy.take_damage(dmg, s)
	if enemy.has_method("apply_knockback"):
		enemy.apply_knockback(kb_src, kbf)

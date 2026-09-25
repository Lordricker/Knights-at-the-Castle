class_name EnemyTower
extends Node2D

## enemy_tower.gd
## A destructible enemy tower. Place in the level scene.
##
## Flow:
##   RunManager.activate_initial_towers() calls activate() on the starting towers.
##   When a player uses TNT inside the Area2D, call destroy() on this tower.
##   destroy() → plays destruction anim → calls unit_hut.unlock() → activates next_towers.
##
## Chaining:
##   Set next_towers to the towers that should become active when this one falls.
##   e.g. Tower A and Tower B start active. A's next_towers = [C, D]. B's = [E, F].
##
## Pathing / spawn points:
##   spawn_point + walk_path are this tower's own entry point onto the road —
##   registered with the EnemySpawner while the tower is active, so enemies
##   spawn there and walk that path toward the castle. On destroy(), this
##   tower's source is retired and next_towers each register their own
##   spawn_point/walk_path in turn. extra_spawn_points/extra_walk_paths (index-
##   matched) cover terminal spawn points beyond the last tower on a branch —
##   map-edge Marker2Ds with no tower guarding them, activated alongside (or
##   instead of, if next_towers is empty) any next_towers.

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Links")
## The UnitHut to unlock when this tower is destroyed.
@export var unit_hut: Node  # UnitHut
## Towers that become active when this tower is destroyed.
@export var next_towers: Array[Node] = []  # Array[EnemyTower]

@export_group("Scene Nodes")
## The tower's visual sprite. Assign in Inspector.
@export var tower_sprite: Node  # Sprite2D or AnimatedSprite2D
## Area2D the player must enter (while holding TNT) to detonate.
@export var interaction_area: Area2D

@export_group("Treasure")
## Chest spawned where this tower falls. A player who touches it gains one free
## random stat pip (see treasure_chest.gd). Defaults to treasureChest.tscn;
## set to null to suppress the drop for this tower.
@export var treasure_chest_scene: PackedScene = preload("res://level/treasureChest.tscn")
## World-space offset from the tower origin where the chest appears.
## Default drops it ~50 px down, roughly at the base of the tower.
@export var treasure_chest_offset: Vector2 = Vector2(0, 50)

@export_group("Pathing")
## Where enemies spawn while this tower is the active frontier. Defaults to
## the child node named "spawnpoint" if left unassigned.
@export var spawn_point: Marker2D
## The road segment (from spawn_point to the castle) enemies walk while this
## tower is the active frontier.
@export var walk_path: Path2D
## Terminal, tower-less spawn points revealed when this tower is destroyed
## (e.g. map-edge spawn points beyond the last tower on a branch). Index-matched
## with extra_walk_paths.
@export var extra_spawn_points: Array[Marker2D] = []
## Walk paths for extra_spawn_points, index-matched 1:1.
@export var extra_walk_paths: Array[Path2D] = []

# ── Runtime state ─────────────────────────────────────────────────────────────

var is_active:    bool = false
var is_destroyed: bool = false

signal tower_destroyed(tower: EnemyTower)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(&"enemy_towers")
	if spawn_point == null and has_node(^"spawnpoint"):
		spawn_point = get_node(^"spawnpoint")
	if interaction_area != null:
		interaction_area.monitoring   = false
		interaction_area.monitorable  = false
	# Tower destruction is host-authoritative (TNT only calls destroy() on the
	# host). The joiner falls its matching tower + unlocks its hut on this packet.
	if GameManager.session_id != "":
		WebRTCManager.packet_received.connect(_on_packet_received)

# ── Public API ────────────────────────────────────────────────────────────────

## Called by RunManager at round start, or by a preceding tower's destroy().
func activate() -> void:
	if is_active or is_destroyed:
		return
	is_active = true
	if interaction_area != null:
		interaction_area.monitoring  = true
		interaction_area.monitorable = true

	var spawner := _find_spawner()
	if spawner != null and spawner.has_method(&"add_spawn_source"):
		spawner.call(&"add_spawn_source", spawn_point, walk_path)


## Call this when the player uses TNT at this tower.
## Safe to call from any system — guards against double-destruction.
func destroy() -> void:
	if not is_active or is_destroyed:
		return
	is_destroyed = true
	is_active    = false

	# Disable interaction.
	if interaction_area != null:
		interaction_area.monitoring  = false
		interaction_area.monitorable = false

	# Hide the tower sprite.
	if tower_sprite != null:
		tower_sprite.visible = false

	# Spawn a DeathPoof via the level script.
	var level := _find_level()
	if level != null and level.has_method(&"on_entity_died"):
		level.call(&"on_entity_died", global_position, false)

	# Drop the reward chest where the tower stood.
	_spawn_treasure_chest()

	tower_destroyed.emit(self)

	# Unlock the associated unit hut.
	if unit_hut != null and unit_hut.has_method(&"unlock"):
		unit_hut.call(&"unlock")

	# Mirror the destruction on the joiner (sprite hide + poof + hut unlock).
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "tower_destroyed", "tower": str(name)})

	# Retire this tower's own spawn source and hand off to whatever is next
	# down the road — either more towers, terminal spawn points, or both.
	var spawner := _find_spawner()
	if spawner != null:
		if spawner.has_method(&"remove_spawn_source"):
			spawner.call(&"remove_spawn_source", spawn_point)
		if spawner.has_method(&"add_spawn_source"):
			for i in extra_spawn_points.size():
				var extra_point: Marker2D = extra_spawn_points[i]
				var extra_path: Path2D = extra_walk_paths[i] if i < extra_walk_paths.size() else null
				spawner.call(&"add_spawn_source", extra_point, extra_path)

	# Activate the next wave of towers.
	for tower in next_towers:
		if tower != null and tower.has_method(&"activate"):
			tower.call(&"activate")


## Joiner that connected AFTER this tower fell: adopt the destroyed state without
## any of the one-time theatre. Deliberately skips the death poof and the treasure
## chest — the poof would fire for an event minutes in the past, and the chest may
## already have been opened by the players who were here at the time.
func apply_destroyed_snapshot() -> void:
	if GameManager.is_host or is_destroyed:
		return
	is_destroyed = true
	is_active    = false
	if interaction_area != null:
		interaction_area.monitoring  = false
		interaction_area.monitorable = false
	if tower_sprite != null:
		tower_sprite.visible = false
	if unit_hut != null and unit_hut.has_method(&"unlock"):
		unit_hut.call(&"unlock")


## Joiner: the host destroyed a tower — play the same visual destruction and
## unlock this tower's hut. No spawn-source / next-tower hand-off (that is host
## simulation only) and no re-broadcast.
func _on_packet_received(data: Dictionary) -> void:
	if GameManager.is_host:
		return
	if str(data.get("t", "")) != "tower_destroyed":
		return
	if str(data.get("tower", "")) != str(name):
		return
	if is_destroyed:
		return
	is_destroyed = true
	is_active    = false
	if interaction_area != null:
		interaction_area.monitoring  = false
		interaction_area.monitorable = false
	if tower_sprite != null:
		tower_sprite.visible = false
	var level := _find_level()
	if level != null and level.has_method(&"on_entity_died"):
		level.call(&"on_entity_died", global_position, false)
	_spawn_treasure_chest()
	tower_destroyed.emit(self)
	if unit_hut != null and unit_hut.has_method(&"unlock"):
		unit_hut.call(&"unlock")


## Instances the reward chest at this tower's position. Both peers call this from
## their own destruction path (host in destroy(), joiner in _on_packet_received),
## naming the chest after the tower so treasure_chest.gd can correlate the two
## copies over the network.
func _spawn_treasure_chest() -> void:
	if treasure_chest_scene == null:
		return
	var chest := treasure_chest_scene.instantiate() as Node2D
	if chest == null:
		return
	chest.name = "TreasureChest_" + str(name)
	var parent: Node = _find_level()
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	parent.add_child(chest)
	chest.global_position = global_position + treasure_chest_offset


## Walks up the tree to find a Node with on_entity_died() (the level root).
func _find_level() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.has_method(&"on_entity_died"):
			return node
		node = node.get_parent()
	return null


## Finds the EnemySpawner via the "enemy_spawner" group.
func _find_spawner() -> Node:
	var spawners: Array[Node] = get_tree().get_nodes_in_group(&"enemy_spawner")
	return spawners[0] if spawners.size() > 0 else null

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

# ── Runtime state ─────────────────────────────────────────────────────────────

var is_active:    bool = false
var is_destroyed: bool = false

signal tower_destroyed(tower: EnemyTower)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(&"enemy_towers")
	if interaction_area != null:
		interaction_area.monitoring   = false
		interaction_area.monitorable  = false

# ── Public API ────────────────────────────────────────────────────────────────

## Called by RunManager at round start, or by a preceding tower's destroy().
func activate() -> void:
	if is_active or is_destroyed:
		return
	is_active = true
	if interaction_area != null:
		interaction_area.monitoring  = true
		interaction_area.monitorable = true


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

	tower_destroyed.emit(self)

	# Unlock the associated unit hut.
	if unit_hut != null and unit_hut.has_method(&"unlock"):
		unit_hut.call(&"unlock")

	# Activate the next wave of towers.
	for tower in next_towers:
		if tower != null and tower.has_method(&"activate"):
			tower.call(&"activate")


## Walks up the tree to find a Node with on_entity_died() (the level root).
func _find_level() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.has_method(&"on_entity_died"):
			return node
		node = node.get_parent()
	return null

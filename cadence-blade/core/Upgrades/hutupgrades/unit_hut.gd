class_name UnitHut
extends Node2D

## unit_hut.gd
## Placed in the level. Call unlock() when the associated tower is destroyed.
##
## States:
##   LOCKED    – Area2D disabled, sprite frame 0.  No interaction.
##   UNLOCKED  – Area2D enabled. Player enters → initialBuild button.
##   BUILT     – Sprite animates frames 1→2 and pauses. Player enters → startButtons.
##   COMPLETE  – All 3 unit slots filled. Player enters → lvlUpButtons.

enum State    { LOCKED, UNLOCKED, BUILT, COMPLETE }
enum UnitType { NONE = -1, WARRIOR = 0, ARCHER = 1, PRIEST = 2 }

# ── Exports ───────────────────────────────────────────────────────────────────

@export_group("Identity")
## Unique integer per hut instance — routes multiplayer packets to the correct hut.
@export var hut_id: int = 0

@export_group("Costs")
@export var build_cost:   int = 20
@export var warrior_cost: int = 20
@export var archer_cost:  int = 17
@export var priest_cost:  int = 17

@export_group("Unit Scenes")
## Five scenes per type, indexed by level (0 = lvl1 … 4 = lvl5).
@export var warrior_scenes: Array[PackedScene]
@export var archer_scenes:  Array[PackedScene]
@export var priest_scenes:  Array[PackedScene]

# ── Runtime state ─────────────────────────────────────────────────────────────

var _state:        State     = State.LOCKED
var _slot_types:   Array[int] = [UnitType.NONE, UnitType.NONE, UnitType.NONE]
var _slots_filled: int        = 0
var _player:       Node       = null  # CharacterBase currently inside Area2D
var _coins_display: Node      = null  # auto-found at runtime

# ── @onready refs ─────────────────────────────────────────────────────────────

@onready var _sprite:         AnimatedSprite2D = $AnimatedSprite2D
@onready var _area:           Area2D           = $Area2D
@onready var _initial_build:  Button           = $initialBuild
@onready var _start_buttons:  Control          = $buttons/startButtons
@onready var _lvl_up_buttons: Control          = $buttons/lvlUpButtons
@onready var _icons:          Control          = $icons
@onready var _spawn_point:    Marker2D         = $spawnPoint
@onready var _waypoint:       Node2D           = $waypoint

# Icon arrays indexed 0–2 (slot 0 = unit1, slot 1 = unit2, slot 2 = unit3)
@onready var _sword_icons: Array[TextureRect] = [
	$icons/unit1/swordIcon,
	$icons/unit2/swordIcon,
	$icons/unit3/swordIcon,
]
@onready var _bow_icons: Array[TextureRect] = [
	$icons/unit1/bowIcon,
	$icons/unit2/bowIcon,
	$icons/unit3/bowIcon,
]
@onready var _book_icons: Array[TextureRect] = [
	$icons/unit1/bookIcon,
	$icons/unit2/bookIcon,
	$icons/unit3/bookIcon,
]

# Upgrade tree nodes per slot [0=unit1, 1=unit2, 2=unit3]
@onready var _warrior_trees: Array[Control] = [
	$buttons/lvlUpButtons/unit1/WarriorUpgrades,
	$buttons/lvlUpButtons/unit2/WarriorUpgrades,
	$buttons/lvlUpButtons/unit3/WarriorUpgrades,
]
@onready var _archer_trees: Array[Control] = [
	$buttons/lvlUpButtons/unit1/ArcherUpgrades,
	$buttons/lvlUpButtons/unit2/ArcherUpgrades,
	$buttons/lvlUpButtons/unit3/ArcherUpgrades,
]
@onready var _priest_trees: Array[Control] = [
	$buttons/lvlUpButtons/unit1/PriestUpgrades,
	$buttons/lvlUpButtons/unit2/PriestUpgrades,
	$buttons/lvlUpButtons/unit3/PriestUpgrades,
]

# Destination markers indexed 0–2, matching slot indices
@onready var _dest_points: Array[Marker2D] = [
	$waypoint/point1,
	$waypoint/point2,
	$waypoint/point3,
]

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Initial visual / interaction state.
	_sprite.frame           = 0
	_area.monitoring        = false
	_area.monitorable       = false
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false
	_icons.visible          = false

	for i in 3:
		_sword_icons[i].visible   = false
		_bow_icons[i].visible     = false
		_book_icons[i].visible    = false
		_warrior_trees[i].visible = false
		_archer_trees[i].visible  = false
		_priest_trees[i].visible  = false

	# Wire button signals.
	_initial_build.pressed.connect(_on_initial_build_pressed)
	$buttons/startButtons/button1.pressed.connect(func() -> void: _request_purchase(UnitType.WARRIOR))
	$buttons/startButtons/button2.pressed.connect(func() -> void: _request_purchase(UnitType.ARCHER))
	$buttons/startButtons/button3.pressed.connect(func() -> void: _request_purchase(UnitType.PRIEST))

	# Wire Area2D signals.
	_area.body_entered.connect(_on_area_body_entered)
	_area.body_exited.connect(_on_area_body_exited)

	# Auto-find the HUD coins display (deferred so the full scene tree is ready).
	_find_coins_display.call_deferred()

	# In a multiplayer session, handle inbound packets directly.
	if GameManager.session_id != "":
		WebRTCManager.packet_received.connect(_on_packet_received)

# ── Public API ────────────────────────────────────────────────────────────────

## Call this when the associated tower is destroyed to activate the hut zone.
func unlock() -> void:
	if _state != State.LOCKED:
		return
	_state            = State.UNLOCKED
	_area.monitoring  = true
	_area.monitorable = true

# ── Area2D ────────────────────────────────────────────────────────────────────

func _on_area_body_entered(body: Node2D) -> void:
	if not body.has_method(&"add_coins"):
		return
	_player = body
	_update_shop_ui()


func _on_area_body_exited(body: Node2D) -> void:
	if body != _player:
		return
	_player                 = null
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false

# ── UI routing ────────────────────────────────────────────────────────────────

func _update_shop_ui() -> void:
	if _player == null:
		return
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false
	match _state:
		State.UNLOCKED:
			_initial_build.visible = true
		State.BUILT:
			_start_buttons.visible = true
		State.COMPLETE:
			_show_correct_upgrade_trees()
			_lvl_up_buttons.visible = true

# ── Initial build ─────────────────────────────────────────────────────────────

func _on_initial_build_pressed() -> void:
	_request_initial_build()


func _request_initial_build() -> void:
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({"t": "unit_build", "hut_id": hut_id})
	else:
		_try_initial_build(_player)


func _try_initial_build(buyer: Node) -> void:
	if buyer == null or not buyer.has_method(&"add_coins"):
		return
	if int(buyer.get("coins")) < build_cost:
		if GameManager.session_id != "" and GameManager.is_host:
			WebRTCManager.send_reliable({"t": "unit_denied", "hut_id": hut_id})
		else:
			_flash_deny()
		return

	# Deduct from all local players (shared coin pool).
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			node.add_coins(-build_cost)
			break  # shared pool — deduct once

	_state                 = State.BUILT
	_initial_build.visible = false
	_play_build_animation()

	# Broadcast to joiner.
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "unit_built", "hut_id": hut_id, "cost": build_cost})


func _play_build_animation() -> void:
	_sprite.animation_finished.connect(_on_build_anim_finished, CONNECT_ONE_SHOT)
	_sprite.play("default")
	_sprite.frame = 1  # start from frame 1, plays through to frame 2


func _on_build_anim_finished() -> void:
	_sprite.stop()
	_sprite.frame = 2  # hold permanently on frame 2
	_update_shop_ui()

# ── Unit slot purchases ───────────────────────────────────────────────────────

func _request_purchase(unit_type: UnitType) -> void:
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":         "unit_buy",
			"hut_id":    hut_id,
			"unit_type": unit_type,
		})
	else:
		_try_purchase(unit_type, _player)


func _try_purchase(unit_type: int, buyer: Node) -> void:
	if buyer == null or not buyer.has_method(&"add_coins"):
		return
	if _slots_filled >= 3:
		return
	var cost: int = _get_cost(unit_type)
	if int(buyer.get("coins")) < cost:
		if GameManager.session_id != "" and GameManager.is_host:
			WebRTCManager.send_reliable({"t": "unit_denied", "hut_id": hut_id})
		else:
			_flash_deny()
		return

	# Deduct from all local players (shared coin pool).
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			node.add_coins(-cost)
			break

	var slot_index: int  = _slots_filled
	_slot_types[slot_index] = unit_type
	_slots_filled           += 1
	_spawn_unit(unit_type, slot_index)
	_reveal_slot_icon(slot_index, unit_type)

	if _slots_filled == 3:
		_state = State.COMPLETE
		_update_shop_ui()

	# Broadcast to joiner.
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":          "unit_applied",
			"hut_id":     hut_id,
			"slot_index": slot_index,
			"unit_type":  unit_type,
			"cost":       cost,
		})


func _get_cost(unit_type: int) -> int:
	match unit_type:
		UnitType.WARRIOR: return warrior_cost
		UnitType.ARCHER:  return archer_cost
		UnitType.PRIEST:  return priest_cost
	return 0

# ── Spawn ─────────────────────────────────────────────────────────────────────

## Spawns the unit at `level` (0-based) for the given type into `slot_index`.
## level defaults to 0 (lvl1) for the initial slot purchase.
func _spawn_unit(unit_type: int, slot_index: int, level: int = 0) -> void:
	var scenes: Array[PackedScene] = _get_scenes_for_type(unit_type)
	if scenes.is_empty() or level >= scenes.size() or scenes[level] == null:
		push_warning("UnitHut [%d]: no scene for unit_type %d level %d — skipping spawn." % [hut_id, unit_type, level])
		return
	var unit := scenes[level].instantiate() as Node2D
	if unit == null:
		return
	unit.global_position = _spawn_point.global_position
	if "destination" in unit:
		unit.set("destination", _dest_points[slot_index])
	get_parent().add_child(unit)


func _get_scenes_for_type(unit_type: int) -> Array[PackedScene]:
	match unit_type:
		UnitType.WARRIOR: return warrior_scenes
		UnitType.ARCHER:  return archer_scenes
		UnitType.PRIEST:  return priest_scenes
	return []

# ── Icons ─────────────────────────────────────────────────────────────────────

func _reveal_slot_icon(slot_index: int, unit_type: int) -> void:
	_sword_icons[slot_index].visible = unit_type == UnitType.WARRIOR
	_bow_icons[slot_index].visible   = unit_type == UnitType.ARCHER
	_book_icons[slot_index].visible  = unit_type == UnitType.PRIEST
	_icons.visible = true


func _show_correct_upgrade_trees() -> void:
	for i in 3:
		_warrior_trees[i].visible = _slot_types[i] == UnitType.WARRIOR
		_archer_trees[i].visible  = _slot_types[i] == UnitType.ARCHER
		_priest_trees[i].visible  = _slot_types[i] == UnitType.PRIEST

# ── Helpers ───────────────────────────────────────────────────────────────────

func _flash_deny() -> void:
	if _coins_display != null:
		_coins_display.flash_insufficient()


func _find_coins_display() -> void:
	for node in get_tree().get_nodes_in_group(&"players"):
		# Walk up to the scene root, then search the whole tree for the HUD label.
		break
	# Scan the full scene tree for any node with flash_insufficient().
	var root := get_tree().current_scene
	if root == null:
		return
	for node in root.find_children("*", "", true, false):
		if node.has_method(&"flash_insufficient"):
			_coins_display = node
			return

# ── Multiplayer — inbound packets ─────────────────────────────────────────────

func _on_packet_received(data: Dictionary) -> void:
	if int(data.get("hut_id", -1)) != hut_id:
		return
	match data.get("t", "") as String:
		"unit_build":
			# Joiner requests initial build — host validates.
			if GameManager.is_host:
				_try_initial_build(_find_coin_authority())
		"unit_built":
			# Host confirmed build — joiner deducts coins and plays animation.
			if not GameManager.is_host:
				var cost: int = int(data.get("cost", build_cost))
				for node in get_tree().get_nodes_in_group(&"players"):
					if node.has_method(&"add_coins"):
						node.add_coins(-cost)
						break
				_state                 = State.BUILT
				_initial_build.visible = false
				_play_build_animation()
		"unit_buy":
			# Joiner requests a unit slot — host validates.
			if GameManager.is_host:
				var unit_type: int = int(data.get("unit_type", UnitType.NONE))
				_try_purchase(unit_type, _find_coin_authority())
		"unit_applied":
			# Host applied a unit purchase — joiner syncs.
			if not GameManager.is_host:
				var cost:       int = int(data.get("cost",       0))
				var slot_index: int = int(data.get("slot_index", 0))
				var unit_type:  int = int(data.get("unit_type",  UnitType.NONE))
				for node in get_tree().get_nodes_in_group(&"players"):
					if node.has_method(&"add_coins"):
						node.add_coins(-cost)
						break
				_slot_types[slot_index] = unit_type
				_slots_filled           += 1
				_spawn_unit(unit_type, slot_index)
				_reveal_slot_icon(slot_index, unit_type)
				if _slots_filled == 3:
					_state = State.COMPLETE
					_update_shop_ui()
		"unit_denied":
			# Host rejected a purchase — flash the coin display on joiner.
			if not GameManager.is_host:
				_flash_deny()

# ── Multiplayer — helpers ─────────────────────────────────────────────────────

## Returns a local player node to use as the coin authority (shared pool).
func _find_coin_authority() -> Node:
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			return node
	return null

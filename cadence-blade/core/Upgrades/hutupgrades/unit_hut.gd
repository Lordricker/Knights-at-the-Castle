class_name UnitHut
extends Node2D

const HutSlotTimerScript = preload("res://core/Upgrades/hutupgrades/hut_slot_timer.gd")
const WaypointFlagTexture = preload("res://assets/sprites/Unit Hut Sprites/WaypointFlag.png")

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

## Upgrade tier costs, index 0 = lvl2 … 3 = lvl5. Single source of truth —
## each upgrade button's cost Label is set from these at runtime.
@export_group("Upgrade Costs")
@export var warrior_upgrade_costs: Array[int] = [13, 18, 27, 27]
@export var archer_upgrade_costs:  Array[int] = [13, 18, 25, 25]
@export var priest_upgrade_costs:  Array[int] = [13, 18, 25, 25]

## Seconds a dead unit stays gone before it respawns for free at its slot.
@export_group("Respawn")
@export var respawn_seconds: float = 15.0

@export_group("Unit Scenes")
## Five scenes per type, indexed by level (0 = lvl1 … 4 = lvl5).
@export var warrior_scenes: Array[PackedScene]
@export var archer_scenes:  Array[PackedScene]
@export var priest_scenes:  Array[PackedScene]

@export_group("HUD")
## Node with coins_display.gd-style flash_insufficient() — same wiring as
## CastleInside.coins_display. Assign to the level's HUD node in the Inspector.
@export var coins_display: Node

# ── Runtime state ─────────────────────────────────────────────────────────────

var _state:        State     = State.LOCKED
var _slot_types:   Array[int] = [UnitType.NONE, UnitType.NONE, UnitType.NONE]
var _slots_filled: int        = 0
var _player:       Node       = null  # CharacterBase currently inside Area2D

## The currently-spawned unit instance per slot (scene root), so upgrades can free + respawn it.
var _slot_units: Array[Node2D] = [null, null, null]
## purchased[slot][target_level] — target_level 0 = lvl1 (implicit true once slot filled),
## 1 = lvl2, 2 = lvl3, 3 = lvl4, 4 = lvl5.
var _slot_purchased: Array = [
	[false, false, false, false, false],
	[false, false, false, false, false],
	[false, false, false, false, false],
]
## [slot_index][UnitType] -> Array[Button] indexed by target_level (index 0 unused).
var _upgrade_buttons: Array = [{}, {}, {}]
## Currently-active level per slot (0 = lvl1 … 4 = lvl5) — used to respawn at the right tier.
var _slot_levels: Array[int] = [0, 0, 0]
## Pie-countdown overlay per slot, created at runtime over the slot icon.
var _slot_timers: Array[Control] = [null, null, null]
## The active respawn-countdown tween per slot, if any (so a manual upgrade
## mid-countdown can cancel it instead of causing a duplicate spawn later).
var _respawn_tweens: Array[Tween] = [null, null, null]
## CanvasItem -> the deny-flash Tween currently running on it, so a repeated
## click restarts the flash instead of leaving two tweens fighting over modulate.
var _flash_tweens: Dictionary = {}
## True after WaypointButton is pressed, until the player's next world click
## consumes it and relocates this hut's waypoint.
var _awaiting_waypoint_click: bool = false
## The flag sprite following the cursor while a waypoint click is armed. Freed
## (and this cleared) once it settles at the clicked location.
var _waypoint_flag_preview: Sprite2D = null
## The player whose local attack input we suppressed while a waypoint placement
## is armed, so the click that drops the flag doesn't also swing a weapon. Kept
## so the exact same node gets re-enabled when the placement resolves.
var _waypoint_attack_suppressed: Node = null
## Bumped every time a placement is armed, so a stale re-enable timer from a
## previous placement doesn't unmute attacks during the current one.
var _waypoint_suppress_gen: int = 0
## Polygon2D from the "walk_area" group — used to snap a placed waypoint onto
## the walkable area (see EnemyNavigation). Lazily resolved since huts can be
## unlocked before the level's walk_area is guaranteed to be in the tree.
var walk_area: Polygon2D = null

# ── @onready refs ─────────────────────────────────────────────────────────────

@onready var _sprite:         AnimatedSprite2D = $AnimatedSprite2D
@onready var _area:           Area2D           = $Area2D
@onready var _initial_build:  Button           = $initialBuild
@onready var _start_buttons:  Control          = $buttons/startButtons
@onready var _lvl_up_buttons: Control          = $buttons/lvlUpButtons
@onready var _icons:          Control          = $icons
@onready var _spawn_point:    Marker2D         = $spawnPoint
@onready var _waypoint:       Node2D           = $waypoint
@onready var _waypoint_button: Button          = $WaypointButton

# Cost labels — kept in sync with the exported costs above so the numbers
# never have to be hand-edited in the scene when a cost changes.
@onready var _build_cost_label:   Label = $initialBuild/scroll/cost
@onready var _warrior_cost_label: Label = $buttons/startButtons/button1/cost
@onready var _archer_cost_label:  Label = $buttons/startButtons/button2/cost
@onready var _priest_cost_label:  Label = $buttons/startButtons/button3/cost

# Deny-flash targets — resolved once up front, same as CastleInside's
# option1_icon/option2_icon, instead of walking the tree at flash time.
@onready var _build_scroll:   CanvasItem = $initialBuild/scroll
@onready var _warrior_scroll: CanvasItem = $buttons/startButtons/button1/scroll
@onready var _archer_scroll:  CanvasItem = $buttons/startButtons/button2/scroll
@onready var _priest_scroll:  CanvasItem = $buttons/startButtons/button3/scroll

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
	# Mirrors EnemyTower's "enemy_towers" group so RunManager can enumerate every
	# hut when building the join-time world snapshot.
	add_to_group(&"unit_huts")
	_sync_cost_labels()

	# Initial visual / interaction state.
	_sprite.frame           = 0
	_area.monitoring        = false
	_area.monitorable       = false
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false
	_icons.visible          = false
	_waypoint_button.visible = false

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
	_waypoint_button.pressed.connect(_on_waypoint_button_pressed)

	# Fix button hit areas and unblock clicks through decorative scroll/icon children.
	_fix_button_children(_initial_build)
	_fix_button_children($buttons/startButtons/button1)
	_fix_button_children($buttons/startButtons/button2)
	_fix_button_children($buttons/startButtons/button3)
	# The slot-icons overlay (sword/bow/book, shown above the hut once a slot is
	# bought) visually overlaps the neighboring start/upgrade buttons and draws
	# on top of them — without this it silently eats clicks meant for those buttons.
	_fix_button_children(_icons)

	# Wire the upgrade-tier buttons (lvl2Button/buttonlvl3/4/5) per slot.
	for i in 3:
		_upgrade_buttons[i][UnitType.WARRIOR] = _wire_upgrade_tree(_warrior_trees[i], i)
		_upgrade_buttons[i][UnitType.ARCHER]  = _wire_upgrade_tree(_archer_trees[i], i)
		_upgrade_buttons[i][UnitType.PRIEST]  = _wire_upgrade_tree(_priest_trees[i], i)

	# Pie-countdown overlays, one per slot icon, created at runtime.
	for i in 3:
		_slot_timers[i] = _create_respawn_timer_overlay(i)

	# Wire Area2D signals.
	_area.body_entered.connect(_on_area_body_entered)
	_area.body_exited.connect(_on_area_body_exited)

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
	# Bodies already inside won't fire body_entered retroactively,
	# so check immediately after enabling monitoring.
	_check_overlapping_bodies.call_deferred()


# ── Join-time world resync ────────────────────────────────────────────────────

## Host: full current state of this hut, for a joiner that connected mid-run.
## Deliberately carries state, not events — replaying the original build/buy
## packets would also charge the late joiner for purchases it never made.
func build_snapshot() -> Dictionary:
	var waypoint_pos: Vector2 = _waypoint.global_position if _waypoint != null else Vector2.ZERO
	return {
		"hut_id":    hut_id,
		"state":     int(_state),
		"types":     _slot_types.duplicate(),
		"levels":    _slot_levels.duplicate(),
		"purchased": _slot_purchased.duplicate(true),
		"wx":        waypoint_pos.x,
		"wy":        waypoint_pos.y,
		"has_wp":    1 if _waypoint != null else 0,
	}


## Joiner: adopt a hut snapshot wholesale. Spawns each purchased unit at its
## current level. No coin deduction and no build animation — this is catch-up,
## not a purchase.
func apply_snapshot(d: Dictionary) -> void:
	if GameManager.is_host:
		return
	_state = int(d.get("state", int(State.LOCKED))) as State

	# Waypoint FIRST: _dest_points are children of _waypoint, so moving it after
	# spawning would leave the units standing at the old post.
	if int(d.get("has_wp", 0)) == 1 and _waypoint != null:
		# Set directly rather than via _apply_waypoint(): the host already snapped
		# this position to the navmesh when it was placed, and re-snapping here
		# shifts it again — the joiner's navmesh may not even be baked yet at join
		# time. _apply_waypoint would also kick units into a walk they don't need.
		_waypoint.global_position = Vector2(float(d.get("wx", 0.0)), float(d.get("wy", 0.0)))

	var types: Array = d.get("types", [])
	var levels: Array = d.get("levels", [])
	var purchased: Array = d.get("purchased", [])
	_slots_filled = 0
	for i in 3:
		var t: int = int(types[i]) if i < types.size() else int(UnitType.NONE)
		var lv: int = int(levels[i]) if i < levels.size() else 0
		_slot_types[i] = t
		_slot_levels[i] = lv
		if i < purchased.size() and purchased[i] is Array:
			for lvl_idx in mini((purchased[i] as Array).size(), _slot_purchased[i].size()):
				_slot_purchased[i][lvl_idx] = bool(purchased[i][lvl_idx])
		# Replace whatever is standing there with the correct unit at the right level.
		if _slot_units[i] != null and is_instance_valid(_slot_units[i]):
			_slot_units[i].queue_free()
			_slot_units[i] = null
		if t != int(UnitType.NONE):
			_slots_filled += 1
			_slot_units[i] = _spawn_unit(t, i, lv, true)
			_reveal_slot_icon(i, t)
			_update_upgrade_lock_ui(i)

	# The hut zone is only interactive once the tower fell; mirror that here rather
	# than calling unlock(), which early-returns for anything past LOCKED.
	if _state != State.LOCKED:
		_area.monitoring = true
		_area.monitorable = true
	if _state != State.LOCKED and _state != State.UNLOCKED:
		_initial_build.visible = false
		_mark_built_visuals()
	_update_shop_ui()


func _check_overlapping_bodies() -> void:
	for body in _area.get_overlapping_bodies():
		if body.has_method(&"add_coins"):
			_player = body
			_update_shop_ui()
			break

# ── Area2D ────────────────────────────────────────────────────────────────────

func _on_area_body_entered(body: Node2D) -> void:
	if not body.has_method(&"add_coins"):
		return
	_player = body
	if "attacks_locked" in body:
		body.attacks_locked = true
	_update_shop_ui()


func _on_area_body_exited(body: Node2D) -> void:
	if "attacks_locked" in body:
		body.attacks_locked = false
	if body != _player:
		return
	_player                 = null
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false
	_waypoint_button.visible = false

# ── UI routing ────────────────────────────────────────────────────────────────

func _update_shop_ui() -> void:
	if _player == null:
		return
	_initial_build.visible  = false
	_start_buttons.visible  = false
	_lvl_up_buttons.visible = false
	_waypoint_button.visible = false
	match _state:
		State.UNLOCKED:
			_initial_build.visible = true
		State.BUILT:
			_start_buttons.visible = true
		State.COMPLETE:
			_show_correct_upgrade_trees()
			_lvl_up_buttons.visible = true
	# The waypoint only matters once there's a unit to send somewhere.
	if (_state == State.BUILT or _state == State.COMPLETE) and _slots_filled > 0:
		_waypoint_button.visible = true

# ── Initial build ─────────────────────────────────────────────────────────────

func _on_initial_build_pressed() -> void:
	_request_initial_build()


func _request_initial_build() -> void:
	# Check affordability on the peer that pressed the button so the deny flash
	# always plays locally — the host used to only fire off a denial packet here
	# and show nothing at all on its own screen.
	if not _afford_check(build_cost, _build_scroll):
		return
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({"t": "unit_build", "hut_id": hut_id})
	else:
		_try_initial_build(_player)


func _try_initial_build(buyer: Node, from_remote: bool = false) -> void:
	if buyer == null or not buyer.has_method(&"add_coins"):
		return
	if int(buyer.get("coins")) < build_cost:
		# The presser already flashed via _afford_check; a remote request instead
		# needs the denial sent back so the joiner's screen responds.
		if from_remote:
			WebRTCManager.send_reliable({"t": "unit_denied", "hut_id": hut_id, "kind": "build"})
		else:
			_deny(_build_scroll)
		return

	# Deduct from all local players (shared coin pool).
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			node.add_coins(-build_cost)
			break  # shared pool — deduct once

	_state                 = State.BUILT
	_initial_build.visible = false
	_play_build_animation()
	# Show the shop immediately — don't wait for the animation to finish.
	_update_shop_ui()

	# Broadcast to joiner.
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({"t": "unit_built", "hut_id": hut_id, "cost": build_cost})


## The end state of the build animation, applied without playing it. Used by
## apply_snapshot() so a late joiner sees a finished hut rather than one that
## appears to be under construction the moment they arrive.
func _mark_built_visuals() -> void:
	_sprite.stop()
	_sprite.frame = 2


func _play_build_animation() -> void:
	_sprite.animation_finished.connect(_on_build_anim_finished, CONNECT_ONE_SHOT)
	_sprite.play("default")
	_sprite.frame = 1  # start from frame 1, plays through to frame 2


func _on_build_anim_finished() -> void:
	_sprite.stop()
	_sprite.frame = 2  # hold permanently on frame 2

# ── Unit slot purchases ───────────────────────────────────────────────────────

func _request_purchase(unit_type: UnitType) -> void:
	if not _afford_check(_get_cost(unit_type), _unit_flash_target(unit_type)):
		return
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":         "unit_buy",
			"hut_id":    hut_id,
			"unit_type": unit_type,
		})
	else:
		_try_purchase(unit_type, _player)


func _try_purchase(unit_type: int, buyer: Node, from_remote: bool = false) -> void:
	if buyer == null or not buyer.has_method(&"add_coins"):
		return
	if _slots_filled >= 3:
		return
	var cost: int = _get_cost(unit_type)
	if int(buyer.get("coins")) < cost:
		if from_remote:
			WebRTCManager.send_reliable({"t": "unit_denied", "hut_id": hut_id, "kind": "buy", "unit_type": unit_type})
		else:
			_deny(_unit_flash_target(unit_type))
		return

	# Deduct from all local players (shared coin pool).
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			node.add_coins(-cost)
			break

	var slot_index: int  = _slots_filled
	_slot_types[slot_index] = unit_type
	_slots_filled           += 1
	_slot_purchased[slot_index][0] = true
	_slot_levels[slot_index] = 0
	_slot_units[slot_index] = _spawn_unit(unit_type, slot_index)
	_reveal_slot_icon(slot_index, unit_type)

	if _slots_filled == 3:
		_state = State.COMPLETE
	# Refreshes on every purchase (not just the 3rd) so WaypointButton appears
	# the moment the first unit is bought, without needing to re-enter the Area2D.
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


## Pushes build_cost/warrior_cost/archer_cost/priest_cost into their on-screen
## Labels so the numbers never have to be hand-edited in the scene.
func _sync_cost_labels() -> void:
	_build_cost_label.text   = str(build_cost)
	_warrior_cost_label.text = str(warrior_cost)
	_archer_cost_label.text  = str(archer_cost)
	_priest_cost_label.text  = str(priest_cost)

# ── Spawn ─────────────────────────────────────────────────────────────────────

## Spawns the unit at `level` (0-based) for the given type into `slot_index`.
## level defaults to 0 (lvl1) for the initial slot purchase.
## Returns the instantiated scene root, or null if no scene exists for that level.
## at_post: place the unit at its destination immediately instead of walking it out
## of the hut. Used by apply_snapshot() so a mid-run joiner sees units already
## standing where they are on the host.
func _spawn_unit(unit_type: int, slot_index: int, level: int = 0, at_post: bool = false) -> Node2D:
	var scenes: Array[PackedScene] = _get_scenes_for_type(unit_type)
	if scenes.is_empty() or level >= scenes.size() or scenes[level] == null:
		push_warning("UnitHut [%d]: no scene for unit_type %d level %d — skipping spawn." % [hut_id, unit_type, level])
		return null
	var unit := scenes[level].instantiate() as Node2D
	if unit == null:
		return null

	# A fresh unit is spawning for this slot — cancel any in-flight respawn
	# countdown (e.g. the player upgraded mid-countdown) so it can't also fire
	# later and spawn a duplicate.
	if _respawn_tweens[slot_index] != null and is_instance_valid(_respawn_tweens[slot_index]):
		_respawn_tweens[slot_index].kill()
		_respawn_tweens[slot_index] = null
	if _slot_timers[slot_index] != null:
		_slot_timers[slot_index].visible = false

	unit.global_position = _spawn_point.global_position
	# The scene root is an unscripted wrapper (Node2D/BlackArcher) — the scripted
	# CharacterBody2D holding `destination` is a child of it.
	var body: Node = unit.find_child("CharacterBody2D", true, false)
	if body != null and "destination" in body:
		body.set("destination", _dest_points[slot_index])
	if body != null and body.has_signal(&"died"):
		body.died.connect(_on_slot_unit_died.bind(slot_index), CONNECT_ONE_SHOT)
	get_parent().add_child(unit)
	# After add_child so the body's @onready refs are resolved and global_position
	# is meaningful.
	if at_post and body != null and body.has_method(&"snap_to_post"):
		body.call(&"snap_to_post")
	return unit


## Creates a pie-countdown Control overlaid on slot_index's icon — same 500x500
## pre-scale box the sword/bow/book icons use, but at 25% their visual size
## (0.4 * 0.25 = 0.1 scale) and shifted up 20px so it doesn't fully cover the icon.
func _create_respawn_timer_overlay(slot_index: int) -> Control:
	var parent_node: Node = _icons.get_node(&"unit%d" % (slot_index + 1))
	var overlay := Control.new()
	overlay.set_script(HutSlotTimerScript)
	overlay.offset_left   = 0.0
	overlay.offset_top    = -20.0
	overlay.offset_right  = 500.0
	overlay.offset_bottom = 480.0
	overlay.scale = Vector2(0.1, 0.1)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	parent_node.add_child(overlay)
	return overlay


## Called when a slot's unit dies. Shows the pie countdown and respawns the
## same unit type/level at this slot once respawn_seconds has elapsed.
func _on_slot_unit_died(slot_index: int) -> void:
	var overlay: Control = _slot_timers[slot_index]
	if overlay != null:
		overlay.visible = true
		overlay.call(&"set_progress", 1.0)

	var tw := create_tween()
	_respawn_tweens[slot_index] = tw
	if overlay != null:
		tw.tween_method(Callable(overlay, &"set_progress"), 1.0, 0.0, respawn_seconds)
	else:
		tw.tween_interval(respawn_seconds)
	tw.finished.connect(func() -> void:
		_respawn_tweens[slot_index] = null
		if overlay != null:
			overlay.visible = false
		_slot_units[slot_index] = _spawn_unit(_slot_types[slot_index], slot_index, _slot_levels[slot_index])
	)


func _get_scenes_for_type(unit_type: int) -> Array[PackedScene]:
	match unit_type:
		UnitType.WARRIOR: return warrior_scenes
		UnitType.ARCHER:  return archer_scenes
		UnitType.PRIEST:  return priest_scenes
	return []

# ── Waypoint ──────────────────────────────────────────────────────────────────

func _on_waypoint_button_pressed() -> void:
	_awaiting_waypoint_click = true
	_spawn_waypoint_flag_preview()
	_waypoint_suppress_gen += 1
	_set_waypoint_attack_suppressed(true)


func _exit_tree() -> void:
	# Don't leave a player's attacks muted if the hut is torn down mid-placement.
	_set_waypoint_attack_suppressed(false)


## Deferred re-enable target: only clears the mute if no newer placement has been
## armed since this timer was scheduled (see _waypoint_suppress_gen).
func _release_waypoint_attack_suppressed(gen: int) -> void:
	if gen == _waypoint_suppress_gen:
		_set_waypoint_attack_suppressed(false)


## While a placement is armed, keep the interacting player's attack input muted
## so the click that drops the flag doesn't also trigger an attack. Idempotent.
func _set_waypoint_attack_suppressed(suppressed: bool) -> void:
	if suppressed:
		if _player != null and is_instance_valid(_player) and "disable_local_attack_input" in _player:
			_player.disable_local_attack_input = true
			_waypoint_attack_suppressed = _player
	else:
		if _waypoint_attack_suppressed != null and is_instance_valid(_waypoint_attack_suppressed) \
				and "disable_local_attack_input" in _waypoint_attack_suppressed:
			_waypoint_attack_suppressed.disable_local_attack_input = false
		_waypoint_attack_suppressed = null


## While a waypoint click is armed, the flag sprite tracks the cursor so the
## player can see where it'll land before confirming with a click.
func _process(_delta: float) -> void:
	if _awaiting_waypoint_click and _waypoint_flag_preview != null and is_instance_valid(_waypoint_flag_preview):
		_waypoint_flag_preview.global_position = get_global_mouse_position()


## Consumes the armed waypoint click. Left clicks that land on Control nodes
## (e.g. the shop buttons) are handled by the GUI first and never reach here.
func _unhandled_input(event: InputEvent) -> void:
	if not _awaiting_waypoint_click:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	_awaiting_waypoint_click = false
	# Re-enable attacks a beat later, not now: this same click is already latched
	# as "just pressed" for the physics tick that runs after this input frame, so
	# clearing the suppression synchronously would let it through as an attack.
	if is_inside_tree():
		get_tree().create_timer(0.15).timeout.connect(_release_waypoint_attack_suppressed.bind(_waypoint_suppress_gen))
	else:
		_set_waypoint_attack_suppressed(false)
	var click_pos: Vector2 = get_global_mouse_position()
	_apply_waypoint(click_pos)
	if GameManager.session_id != "":
		WebRTCManager.send_reliable({
			"t":      "unit_waypoint_set",
			"hut_id": hut_id,
			"x":      click_pos.x,
			"y":      click_pos.y,
		})


## Moves the shared waypoint node (carrying point1/point2/point3 with it),
## settles the flag visual at its final spot, and sends every currently-spawned
## unit back to its post. world_pos is first snapped onto walk_area's navmesh
## so a click that lands outside the walkable ground (e.g. on a wall or off
## into decoration) doesn't send units marching to an unreachable spot — the
## flag itself settles at the snapped point too, so what the player sees
## matches where units actually go.
func _apply_waypoint(world_pos: Vector2) -> void:
	if walk_area == null:
		walk_area = EnemyNavigation.find_walk_area(get_tree())
	if walk_area != null:
		world_pos = EnemyNavigation.snap_to_navmesh(walk_area, world_pos)
	_waypoint.global_position = world_pos
	_settle_waypoint_flag(world_pos)
	for unit in _slot_units:
		if unit == null or not is_instance_valid(unit):
			continue
		var body: Node = unit.find_child("CharacterBody2D", true, false)
		if body != null and body.has_method(&"return_to_post"):
			body.call(&"return_to_post")


## Spawns the WaypointFlag sprite at 0.2 scale, right where the cursor is now.
## _process() drags it along with the mouse until the placement click lands.
func _spawn_waypoint_flag_preview() -> void:
	if _waypoint_flag_preview != null and is_instance_valid(_waypoint_flag_preview):
		_waypoint_flag_preview.queue_free()
	var flag := Sprite2D.new()
	flag.texture = WaypointFlagTexture
	flag.scale = Vector2(0.2, 0.2)
	flag.global_position = get_global_mouse_position()
	get_tree().current_scene.add_child(flag)
	_waypoint_flag_preview = flag


## Stops the flag following the cursor and holds it at `world_pos` for 1 second,
## then fades it out over the next second. Mirrors FX/heal_number.gd's tween shape.
## Falls back to spawning a fresh flag when there's no preview to settle — the
## case for the peer that receives a remote unit_waypoint_set packet, who never
## armed a click of their own.
func _settle_waypoint_flag(world_pos: Vector2) -> void:
	var flag: Sprite2D = _waypoint_flag_preview
	_waypoint_flag_preview = null
	if flag == null or not is_instance_valid(flag):
		flag = Sprite2D.new()
		flag.texture = WaypointFlagTexture
		flag.scale = Vector2(0.2, 0.2)
		get_tree().current_scene.add_child(flag)
	flag.global_position = world_pos
	var tween := create_tween()
	tween.tween_interval(1.0)
	tween.tween_property(flag, "modulate:a", 0.0, 1.0)
	tween.tween_callback(flag.queue_free)

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
		_update_upgrade_lock_ui(i)

# ── Upgrade tiers ─────────────────────────────────────────────────────────────

## Wires lvl2Button/buttonlvl3/buttonlvl4/buttonlvl5 under `tree` to purchase
## requests for `slot_index`. Returns Array[Button] indexed by target_level
## (index 0 unused, 1..4 = lvl2..lvl5).
func _wire_upgrade_tree(tree: Control, slot_index: int) -> Array:
	var buttons: Array = [null, null, null, null, null]
	var names := ["lvl2Button", "buttonlvl3", "buttonlvl4", "buttonlvl5"]
	for i in names.size():
		var target_level: int = i + 1
		var btn: Button = tree.get_node_or_null(names[i]) as Button
		if btn == null:
			continue
		buttons[target_level] = btn
		btn.pressed.connect(func() -> void: _request_upgrade(slot_index, target_level))
		_fix_button_children(btn)
	return buttons


func _get_upgrade_button(slot_index: int, target_level: int) -> Button:
	var unit_type: int = _slot_types[slot_index]
	var arr: Array = _upgrade_buttons[slot_index].get(unit_type, [])
	if target_level >= 0 and target_level < arr.size():
		return arr[target_level] as Button
	return null


func _get_upgrade_costs_for_type(unit_type: int) -> Array[int]:
	match unit_type:
		UnitType.WARRIOR: return warrior_upgrade_costs
		UnitType.ARCHER:  return archer_upgrade_costs
		UnitType.PRIEST:  return priest_upgrade_costs
	return []


func _get_upgrade_cost(slot_index: int, target_level: int) -> int:
	var costs: Array[int] = _get_upgrade_costs_for_type(_slot_types[slot_index])
	var idx: int = target_level - 1
	if idx >= 0 and idx < costs.size():
		return costs[idx]
	return 0


func _request_upgrade(slot_index: int, target_level: int) -> void:
	if not _afford_check(_get_upgrade_cost(slot_index, target_level),
			_button_flash_target(_get_upgrade_button(slot_index, target_level))):
		return
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":            "unit_upgrade_buy",
			"hut_id":       hut_id,
			"slot_index":   slot_index,
			"target_level": target_level,
		})
	else:
		_try_upgrade(slot_index, target_level, _player)


func _try_upgrade(slot_index: int, target_level: int, buyer: Node, from_remote: bool = false) -> void:
	if buyer == null or not buyer.has_method(&"add_coins"):
		return
	if slot_index < 0 or slot_index > 2 or target_level < 1 or target_level > 4:
		return
	var unit_type: int = _slot_types[slot_index]
	if unit_type == UnitType.NONE:
		return  # empty slot

	var purchased: Array = _slot_purchased[slot_index]
	if purchased[target_level]:
		return  # already owned

	var prereq_met: bool
	match target_level:
		1: prereq_met = true
		2: prereq_met = purchased[1]
		_: prereq_met = purchased[2]  # 3 (lvl4) and 4 (lvl5) both require lvl3 owned
	if not prereq_met:
		return  # defensive; UI already disables the button

	var scenes: Array[PackedScene] = _get_scenes_for_type(unit_type)
	if scenes.is_empty() or target_level >= scenes.size() or scenes[target_level] == null:
		push_warning("UnitHut [%d]: no scene for slot %d level %d — no charge, no spawn." % [hut_id, slot_index, target_level])
		return

	var cost: int = _get_upgrade_cost(slot_index, target_level)
	if int(buyer.get("coins")) < cost:
		if from_remote:
			WebRTCManager.send_reliable({
				"t": "unit_denied", "hut_id": hut_id, "kind": "upgrade",
				"slot_index": slot_index, "target_level": target_level,
			})
		else:
			_deny(_button_flash_target(_get_upgrade_button(slot_index, target_level)))
		return

	# Deduct from all local players (shared coin pool).
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			node.add_coins(-cost)
			break

	purchased[target_level] = true
	if _slot_units[slot_index] != null and is_instance_valid(_slot_units[slot_index]):
		_slot_units[slot_index].queue_free()
	_slot_levels[slot_index] = target_level
	_slot_units[slot_index] = _spawn_unit(unit_type, slot_index, target_level)
	_update_upgrade_lock_ui(slot_index)

	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":            "unit_upgrade_applied",
			"hut_id":       hut_id,
			"slot_index":   slot_index,
			"target_level": target_level,
			"cost":         cost,
		})


## Refreshes disabled state + "chains" overlay visibility for slot_index's upgrade tree.
func _update_upgrade_lock_ui(slot_index: int) -> void:
	var unit_type: int = _slot_types[slot_index]
	if unit_type == UnitType.NONE:
		return
	var purchased: Array = _slot_purchased[slot_index]
	var lvl2: Button = _get_upgrade_button(slot_index, 1)
	var lvl3: Button = _get_upgrade_button(slot_index, 2)
	var lvl4: Button = _get_upgrade_button(slot_index, 3)
	var lvl5: Button = _get_upgrade_button(slot_index, 4)

	if lvl2 != null:
		lvl2.disabled = purchased[1]
		_set_cost_label(lvl2, _get_upgrade_cost(slot_index, 1))

	var lvl3_unlocked: bool = purchased[1]
	if lvl3 != null:
		lvl3.disabled = purchased[2] or not lvl3_unlocked
		_set_chain_visible(lvl3, not lvl3_unlocked)
		_set_cost_label(lvl3, _get_upgrade_cost(slot_index, 2))

	var lvl45_unlocked: bool = purchased[2]
	if lvl4 != null:
		lvl4.disabled = purchased[3] or not lvl45_unlocked
		_set_chain_visible(lvl4, not lvl45_unlocked)
		_set_cost_label(lvl4, _get_upgrade_cost(slot_index, 3))
	if lvl5 != null:
		lvl5.disabled = purchased[4] or not lvl45_unlocked
		_set_chain_visible(lvl5, not lvl45_unlocked)
		_set_cost_label(lvl5, _get_upgrade_cost(slot_index, 4))


func _set_chain_visible(btn: Button, chain_visible: bool) -> void:
	var chain: Node = btn.get_node_or_null("chains")
	if chain is CanvasItem:
		(chain as CanvasItem).visible = chain_visible


func _set_cost_label(btn: Button, cost: int) -> void:
	var label: Label = btn.get_node_or_null("cost") as Label
	if label != null:
		label.text = str(cost)

# ── Helpers ───────────────────────────────────────────────────────────────────

## True when the player at this hut can pay `cost`. On failure it plays the full
## deny response on `target`, so every hut button answers a click the same way
## the blacksmith shop does. Call this from the _request_* entry points — that
## way the peer that pressed the button always sees the feedback, whether it is
## the host, the joiner, or a solo player.
func _afford_check(cost: int, target: CanvasItem) -> bool:
	if _player == null or not _player.has_method(&"add_coins"):
		return false
	if int(_player.get("coins")) >= cost:
		return true
	_deny(target)
	return false


## The complete "can't afford it" response: HUD coin label juice plus a red
## flash on the button that was pressed. Mirrors CastleInside's pairing of
## coins_display.flash_insufficient() with _flash_deny_icon().
func _deny(target: CanvasItem) -> void:
	_flash_coins_deny()
	_flash_red(target)


## Flashes the HUD coin label red — same coins_display.flash_insufficient()
## wiring CastleInside uses for the blacksmith/TNT shop.
func _flash_coins_deny() -> void:
	if coins_display != null and coins_display.has_method(&"flash_insufficient"):
		coins_display.flash_insufficient()


## Briefly tints `target` red, then fades it back to white — a direct copy of
## CastleInside._flash_deny_icon(). A flash already running on the same target
## is killed first so rapid clicks restart it instead of leaving two tweens
## fighting over `modulate` (which lands it on a stale colour).
func _flash_red(target: CanvasItem) -> void:
	if target == null:
		return
	var running: Tween = _flash_tweens.get(target) as Tween
	if running != null and running.is_valid():
		running.kill()
	target.modulate = Color.RED
	var tween := create_tween()
	_flash_tweens[target] = tween
	tween.tween_property(target, "modulate", Color.WHITE, 0.35)


## The scroll CanvasItem to flash for a start-button unit type, or null when
## the type is UnitType.NONE or otherwise unrecognised.
func _unit_flash_target(unit_type: int) -> CanvasItem:
	match unit_type:
		UnitType.WARRIOR: return _warrior_scroll
		UnitType.ARCHER:  return _archer_scroll
		UnitType.PRIEST:  return _priest_scroll
	return null


## The scroll inside an upgrade-tier button, falling back to the button itself
## when it has no scroll child. Upgrade-tier buttons are indexed dynamically
## (3 slots × 3 unit types × 4 tiers), so unlike build/start buttons they aren't
## individually pre-wired as @onready refs.
func _button_flash_target(btn: Button) -> CanvasItem:
	if btn == null:
		return null
	var scroll: Node = btn.get_node_or_null(^"scroll")
	return (scroll as CanvasItem) if scroll is CanvasItem else btn


## Recursively sets all Control descendants of `ctrl` to MOUSE_FILTER_IGNORE
## so decorative children (scroll textures, icon images, labels) don't eat clicks.
func _fix_button_children(ctrl: Control) -> void:
	for child in ctrl.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
			_fix_button_children(child as Control)

# ── Multiplayer — inbound packets ─────────────────────────────────────────────

func _on_packet_received(data: Dictionary) -> void:
	if int(data.get("hut_id", -1)) != hut_id:
		return
	match data.get("t", "") as String:
		"unit_waypoint_set":
			# The other peer relocated the waypoint — mirror it locally, no
			# re-broadcast (that would ping-pong the packet forever).
			_apply_waypoint(Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0))))
		"unit_build":
			# Joiner requests initial build — host validates.
			if GameManager.is_host:
				_try_initial_build(_find_coin_authority(), true)
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
				_try_purchase(unit_type, _find_coin_authority(), true)
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
				_slot_purchased[slot_index][0] = true
				_slot_levels[slot_index] = 0
				_slot_units[slot_index] = _spawn_unit(unit_type, slot_index)
				_reveal_slot_icon(slot_index, unit_type)
				if _slots_filled == 3:
					_state = State.COMPLETE
				_update_shop_ui()
		"unit_upgrade_buy":
			# Joiner requests an upgrade tier — host validates.
			if GameManager.is_host:
				var slot_index: int  = int(data.get("slot_index",   -1))
				var target_level: int = int(data.get("target_level", -1))
				_try_upgrade(slot_index, target_level, _find_coin_authority(), true)
		"unit_upgrade_applied":
			# Host applied an upgrade purchase — joiner syncs.
			if not GameManager.is_host:
				var slot_index:   int = int(data.get("slot_index",   0))
				var target_level: int = int(data.get("target_level", 0))
				var cost:         int = int(data.get("cost",         0))
				for node in get_tree().get_nodes_in_group(&"players"):
					if node.has_method(&"add_coins"):
						node.add_coins(-cost)
						break
				_slot_purchased[slot_index][target_level] = true
				if _slot_units[slot_index] != null and is_instance_valid(_slot_units[slot_index]):
					_slot_units[slot_index].queue_free()
				_slot_levels[slot_index] = target_level
				_slot_units[slot_index] = _spawn_unit(_slot_types[slot_index], slot_index, target_level)
				_update_upgrade_lock_ui(slot_index)
		"unit_denied":
			# Host rejected a purchase — flash the coin display + matching button on joiner.
			if not GameManager.is_host:
				# _deny() still plays the coin juice when the target resolves to null.
				match data.get("kind", "") as String:
					"build":
						_deny(_build_scroll)
					"buy":
						_deny(_unit_flash_target(int(data.get("unit_type", -1))))
					"upgrade":
						_deny(_button_flash_target(_get_upgrade_button(
							int(data.get("slot_index", -1)), int(data.get("target_level", -1)))))

# ── Multiplayer — helpers ─────────────────────────────────────────────────────

## Returns a local player node to use as the coin authority (shared pool).
func _find_coin_authority() -> Node:
	for node in get_tree().get_nodes_in_group(&"players"):
		if node.has_method(&"add_coins"):
			return node
	return null

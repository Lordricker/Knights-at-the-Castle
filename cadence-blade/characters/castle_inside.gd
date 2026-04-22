class_name CastleInside
extends Node2D

# castle_inside.gd — Drives monk healing and blacksmith upgrade shop logic.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   Node2D                    (this script — root of the castle-interior node group)
#   ├── MonkZone              (Area2D) — assign to monk_zone
#   │   └── CollisionShape2D           set collision mask to player layer
#   ├── BlacksmithZone        (Area2D) — assign to blacksmith_zone
#   │   └── CollisionShape2D           set collision mask to player layer
#   ├── MonkNPC               (instance monk_npc.tscn) — drag AnimatedSprite2D child to monk_sprite
#   ├── BlacksmithNPC         (instance blacksmith_npc.tscn) — drag AnimatedSprite2D child to blacksmith_sprite
#   └── UpgradeUI             (Control, set to full-rect or anchor in screen space)
#       ├── Option1Panel      (Panel or VBoxContainer) — contains icon, name, cost
#       │   ├── UpgradeIcon1  (TextureRect)  → assign to option1_icon
#       │   ├── UpgradeName1  (Label)         → assign to option1_label
#       │   └── UpgradeCost1  (Label)         → assign to option1_cost_label
#       └── Option2Panel      (Panel or VBoxContainer)
#           ├── UpgradeIcon2  (TextureRect)  → assign to option2_icon
#           ├── UpgradeName2  (Label)         → assign to option2_label
#           └── UpgradeCost2  (Label)         → assign to option2_cost_label
#
# ── MONK ──────────────────────────────────────────────────────────────────────
#   When the player overlaps MonkZone:
#     • Player HP heals at heal_per_second.
#     • Monk sprite plays "Heal" animation.
#     • Player's animation is locked to "heal" (CharacterBase.healing_locked = true).
#   When the player leaves:
#     • healing_locked is cleared; monk returns to "Idle".
#
# ── BLACKSMITH ────────────────────────────────────────────────────────────────
#   When the player overlaps BlacksmithZone:
#     • Player attacks are disabled (CharacterBase.attacks_locked = true).
#     • Two upgrades are immediately drawn from the lottery pool and shown in UpgradeUI.
#     • Options refresh every refresh_interval seconds while the player stays inside.
#     • Press J (slash action) to buy option 1.
#     • Press K (thrust action) to buy option 2.
#   On successful purchase:
#     • Coins are deducted from the player.
#     • The chosen stat boost is applied immediately (persists all run).
#     • That offer slot is hidden (won't re-roll until the next refresh).
#   On insufficient coins:
#     • coins_display.flash_insufficient() is called to animate the HUD label.
#   When the player leaves the zone, attacks are re-enabled and the UI hides.
#
# ── UPGRADES LOTTERY ──────────────────────────────────────────────────────────
#   Works identically to EnemySpawner: each UpgradeConfig has a pool_tickets_curve.
#   At draw time the normalised run time (from run_manager.time_elapsed) is sampled.
#   Upgrades with 0 tickets at the current time are absent from the pool.
#   Two distinct upgrades are drawn (second draw excludes the first pick).
#
# ── RUN-MANAGER WIRING ───────────────────────────────────────────────────────
#   Assign run_manager so time_elapsed is readable. The node only needs to have
#   a float property called time_elapsed (RunManager satisfies this).

# ── Monk exports ──────────────────────────────────────────────────────────────

@export_group("Monk")
## HP healed per second while the player overlaps MonkZone.
@export var heal_per_second: float = 5.0
## Area2D covering the monk's healing radius. Assign in Inspector.
@export var monk_zone: Area2D
## The monk NPC's AnimatedSprite2D — plays "Heal" / "Idle" animations.
@export var monk_sprite: AnimatedSprite2D

# ── Blacksmith exports ────────────────────────────────────────────────────────

@export_group("Blacksmith")
## All upgrades available in the lottery pool. Add UpgradeConfig resources here.
@export var upgrades: Array[UpgradeConfig] = []
## What X = 1.0 on every ticket curve represents, in minutes.
## Should match EnemySpawner.curve_time_scale_minutes.
@export var curve_time_scale_minutes: float = 10.0
## Seconds before the two offered upgrades are re-rolled while the player is at the blacksmith.
@export var refresh_interval: float = 10.0
## Area2D covering the blacksmith's trade zone. Assign in Inspector.
@export var blacksmith_zone: Area2D
## The blacksmith NPC's AnimatedSprite2D.
@export var blacksmith_sprite: AnimatedSprite2D

# ── Upgrade UI exports ────────────────────────────────────────────────────────

@export_group("Upgrade UI")
## Root Control shown/hidden when player enters/leaves BlacksmithZone.
@export var upgrade_ui: Control
## The two TextureRects that display the upgrade sprite.
## The upgrade's icon texture carries all the player-facing info.
@export var option1_icon: TextureRect
@export var option2_icon: TextureRect

# ── HUD / scene reference exports ─────────────────────────────────────────────

@export_group("HUD")
## Node with coins_display.gd attached. Called when a purchase fails.
@export var coins_display: Node

@export_group("Scene References")
## RunManager node — must have a float property `time_elapsed`.
@export var run_manager: Node
## The Castle node in the level scene. Required for HealCastle and UpgradeCastle upgrades.
@export var castle: Castle

# ── Runtime state ─────────────────────────────────────────────────────────────

var _player: CharacterBase = null
var _player_in_monk_zone: bool = false
var _player_in_blacksmith_zone: bool = false

## Currently offered upgrades. Index 0 = J key, index 1 = K key.
## null means the slot is empty (purchased or unavailable).
var _offered: Array = [null, null]

var _refresh_timer: float = 0.0
## Reference count for active enemy-freeze effects. Enemies stay frozen until
## every outstanding timer has expired.
var _freeze_count: int = 0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Auto-find the Castle node if not assigned in the Inspector.
	if castle == null:
		for child in find_children("*", "", true, false):
			if child is Castle:
				castle = child as Castle
				break
		if castle == null:
			push_warning("CastleInside: no Castle node assigned or found. HEAL_CASTLE / UPGRADE_CASTLE upgrades will not work.")
	if monk_zone != null:
		monk_zone.body_entered.connect(_on_monk_zone_body_entered)
		monk_zone.body_exited.connect(_on_monk_zone_body_exited)
	if blacksmith_zone != null:
		blacksmith_zone.body_entered.connect(_on_blacksmith_zone_body_entered)
		blacksmith_zone.body_exited.connect(_on_blacksmith_zone_body_exited)
	if upgrade_ui != null:
		upgrade_ui.hide()


func _process(delta: float) -> void:
	_heal_player(delta)
	_handle_blacksmith_refresh(delta)
	_handle_upgrade_input()

# ── Player detection ──────────────────────────────────────────────────────────

## Returns the CharacterBase from body if it is one, otherwise null.
func _get_character(body: Node2D) -> CharacterBase:
	if body is CharacterBase:
		return body as CharacterBase
	return null

# ── Monk logic ────────────────────────────────────────────────────────────────

func _on_monk_zone_body_entered(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	_player = player
	_player_in_monk_zone = true
	player.healing_locked = true
	if monk_sprite != null:
		monk_sprite.play(&"Heal")


func _on_monk_zone_body_exited(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	_player_in_monk_zone = false
	player.healing_locked = false
	if monk_sprite != null:
		monk_sprite.play(&"Idle")
	_clear_player_if_unused()


func _heal_player(delta: float) -> void:
	if not _player_in_monk_zone or _player == null:
		return
	if _player.health >= _player.max_health:
		return
	_player.health = minf(_player.health + heal_per_second * delta, _player.max_health)
	_player.health_changed.emit(_player.health, _player.max_health)

# ── Blacksmith logic ──────────────────────────────────────────────────────────

func _on_blacksmith_zone_body_entered(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	_player = player
	_player_in_blacksmith_zone = true
	player.attacks_locked = true
	# Only roll fresh offers if there are none active (first visit or all slots purchased).
	# Re-entering the zone mid-timer keeps the existing offers and the running timer.
	if _offered[0] == null and _offered[1] == null:
		_roll_upgrades()
		_refresh_timer = refresh_interval
	_show_upgrade_ui(true)


func _on_blacksmith_zone_body_exited(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	_player_in_blacksmith_zone = false
	player.attacks_locked = false
	_show_upgrade_ui(false)
	_clear_player_if_unused()


func _handle_blacksmith_refresh(delta: float) -> void:
	# Count down whenever there are active offers, not only while in the zone.
	# This ensures the timer keeps running while the player is out fighting.
	if _offered[0] == null and _offered[1] == null:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = refresh_interval
		if _player_in_blacksmith_zone:
			# Player is present -- re-roll and display immediately.
			_roll_upgrades()
		else:
			# Player is away -- clear stale offers so next visit re-rolls fresh.
			_offered[0] = null
			_offered[1] = null


func _handle_upgrade_input() -> void:
	if not _player_in_blacksmith_zone or _player == null:
		return
	# action1 → buy left upgrade (slot 0).  action2 → buy right upgrade (slot 1).
	if Input.is_action_just_pressed(&"action1"):
		_try_purchase(0)
	elif Input.is_action_just_pressed(&"action2"):
		_try_purchase(1)


func _try_purchase(slot: int) -> void:
	var upgrade: UpgradeConfig = _offered[slot] as UpgradeConfig
	if upgrade == null:
		return
	if _player.coins < upgrade.cost:
		if coins_display != null and coins_display.has_method(&"flash_insufficient"):
			coins_display.flash_insufficient()
		_flash_deny_icon(slot)
		return
	_player.add_coins(-upgrade.cost)
	_apply_upgrade(upgrade)
	_flash_purchase_icon(slot)


func _apply_upgrade(upgrade: UpgradeConfig) -> void:
	match upgrade.stat_type:
		UpgradeConfig.StatType.ATTACK:
			_player.attack_bonus += upgrade.stat_amount
		UpgradeConfig.StatType.SPEED:
			_player.speed_bonus += upgrade.stat_amount
		UpgradeConfig.StatType.HEAL_CASTLE:
			if castle != null:
				castle.health = minf(castle.health + upgrade.stat_amount, castle.max_health)
				castle.health_changed.emit(castle.health, castle.max_health)
		UpgradeConfig.StatType.UPGRADE_CASTLE:
			if castle != null:
				castle.max_health += upgrade.stat_amount
				castle.health_changed.emit(castle.health, castle.max_health)
		UpgradeConfig.StatType.UPGRADE_HP:
			if _player != null:
				_player.max_health += upgrade.stat_amount
				_player.health_changed.emit(_player.health, _player.max_health)
		UpgradeConfig.StatType.RESET_FLOW:
			if _player != null:
				var elapsed: float = 0.0
				if run_manager != null and "time_elapsed" in run_manager:
					elapsed = float(run_manager.time_elapsed)
				_player.flow_time_offset = elapsed
		UpgradeConfig.StatType.FREEZE_ENEMIES:
			_freeze_enemies(upgrade.stat_amount)

# ── Lottery rolling ───────────────────────────────────────────────────────────

func _roll_upgrades() -> void:
	var t: float = _normalized_time()
	_offered[0] = _draw_one(t, [])
	_offered[1] = _draw_one(t, [_offered[0]])
	_update_ui_slot(0)
	_update_ui_slot(1)


func _normalized_time() -> float:
	if run_manager == null or not "time_elapsed" in run_manager:
		return 0.0
	return clampf(float(run_manager.time_elapsed) / (curve_time_scale_minutes * 60.0), 0.0, 1.0)


func _sample_lottery_tickets(curve: Curve, t: float, default_value: int = 1) -> int:
	if curve == null:
		return default_value
	if curve.point_count > 0 and t < curve.get_point_position(0).x:
		return 0
	return maxi(0, roundi(curve.sample_baked(t)))


## Draw one upgrade from the lottery pool, excluding any in the `exclude` array.
## Returns null if the pool is empty.
func _draw_one(t: float, exclude: Array) -> UpgradeConfig:
	var pool: Array[UpgradeConfig] = []
	for upgrade: UpgradeConfig in upgrades:
		if upgrade == null or upgrade in exclude:
			continue
		var tickets: int = 1
		if upgrade.pool_tickets_curve != null:
			tickets = _sample_lottery_tickets(upgrade.pool_tickets_curve, t)
		for _i in tickets:
			pool.append(upgrade)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]

# ── UI helpers ────────────────────────────────────────────────────────────────

func _show_upgrade_ui(show: bool) -> void:
	if upgrade_ui != null:
		upgrade_ui.visible = show


## Briefly tints the purchased icon green, then fades back to white and hides it.
func _flash_purchase_icon(slot: int) -> void:
	var icon_ref: TextureRect = option1_icon if slot == 0 else option2_icon
	if icon_ref == null:
		return
	icon_ref.modulate = Color(0.2, 1.0, 0.3, 1.0)
	var tween := create_tween()
	tween.tween_property(icon_ref, "modulate", Color.WHITE, 0.35)


## Briefly tints the icon red to signal the player cannot afford it.
func _flash_deny_icon(slot: int) -> void:
	var icon_ref: TextureRect = option1_icon if slot == 0 else option2_icon
	if icon_ref == null:
		return
	icon_ref.modulate = Color.RED
	var tween := create_tween()
	tween.tween_property(icon_ref, "modulate", Color.WHITE, 0.35)


func _update_ui_slot(slot: int) -> void:
	var upgrade: UpgradeConfig = _offered[slot] as UpgradeConfig
	var icon_ref: TextureRect = option1_icon if slot == 0 else option2_icon
	if icon_ref == null:
		return
	if upgrade == null:
		icon_ref.hide()
		return
	icon_ref.texture = upgrade.icon
	icon_ref.show()

# ── Cleanup ───────────────────────────────────────────────────────────────────

func _clear_player_if_unused() -> void:
	if not _player_in_monk_zone and not _player_in_blacksmith_zone:
		_player = null

# ── Freeze logic ──────────────────────────────────────────────────────────────

## Freeze all live enemies and pause the spawner for `duration` seconds.
## Uses a reference count so multiple purchases stack correctly: enemies stay
## frozen until every outstanding timer has expired.
func _freeze_enemies(duration: float) -> void:
	_freeze_count += 1
	for node in get_tree().get_nodes_in_group(&"entities"):
		if node is EnemyBase and not (node as EnemyBase).is_dead:
			(node as EnemyBase).is_frozen = true
	var spawner: Node = null
	if run_manager != null:
		spawner = run_manager.get("spawner") as Node
	if spawner != null:
		spawner.set_process(false)
	get_tree().create_timer(duration).timeout.connect(func():
		_freeze_count = maxi(0, _freeze_count - 1)
		if _freeze_count == 0:
			for node in get_tree().get_nodes_in_group(&"entities"):
				if node is EnemyBase and not (node as EnemyBase).is_dead:
					(node as EnemyBase).is_frozen = false
			if spawner != null and is_instance_valid(spawner):
				spawner.set_process(true)
	)

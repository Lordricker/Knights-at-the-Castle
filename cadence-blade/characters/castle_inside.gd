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
## Optional clickable buttons layered behind/over each upgrade icon.
## Connect their pressed signal here — wire them in the Inspector.
@export var option1_button: Button
@export var option2_button: Button
## Labels displaying the coin cost of each offered upgrade. Assign in Inspector.
@export var option1_cost_label: Label
@export var option2_cost_label: Label
## AnimatedSprite2D of the hourglass sitting by the blacksmith. Its 5-frame
## "default" loop is driven manually to mirror the shop refresh cycle: frame 0
## just after offers roll, last frame just before they re-roll. Each machine
## drives its own, so it is naturally player-specific.
@export var hourglass_sprite: AnimatedSprite2D

@export_group("TNT")
## PackedScene for the TNT item. Spawned at the player's position on purchase.
@export var tnt_scene: PackedScene
## Button always visible in the blacksmith zone — never rotated out like the lottery slots.
@export var tnt_button: Button
## Label showing the current escalating TNT cost.
@export var tnt_cost_label: Label
## Escalating coin costs per purchase. Last value is reused once exhausted.
@export var tnt_costs: Array[int] = [15, 20, 25, 30, 35]

# ── HUD / scene reference exports ─────────────────────────────────────────────

@export_group("HUD")
## Node with coins_display.gd attached. Called when a purchase fails.
@export var coins_display: Node

@export_group("Scene References")
## RunManager node — must have a float property `time_elapsed`.
@export var run_manager: Node
## The Castle node in the level scene. Required for HealCastle and UpgradeCastle upgrades.
@export var castle: Castle

@export_group("Tower Archers")
## The right-side TowerArcher node in the level. Drag from the scene tree.
@export var tower_archer_right: Node
## The left-side TowerArcher node in the level. Drag from the scene tree.
@export var tower_archer_left: Node

@export_group("Enemy Indicators")
## Exclamation point Sprite2D above the right scout (positive global X side).
@export var right_exclamation: Sprite2D
## Exclamation point Sprite2D above the left scout (negative global X side).
@export var left_exclamation: Sprite2D
## Tint for 1 enemy on that side.
@export var enemy_color_1: Color = Color(1.0, 0.8, 0.8)
## Tint for 2 enemies on that side.
@export var enemy_color_2: Color = Color(1.0, 0.5, 0.5)
## Tint for 3 enemies on that side.
@export var enemy_color_3: Color = Color(0.9, 0.2, 0.2)
## Tint for 4 enemies on that side.
@export var enemy_color_4: Color = Color(0.7, 0.05, 0.05)
## Tint for 5+ enemies on that side.
@export var enemy_color_5: Color = Color(0.4, 0.0, 0.0)

# ── Runtime state ─────────────────────────────────────────────────────────────

var _player: CharacterBase = null
var _player_in_monk_zone: bool = false
var _player_in_blacksmith_zone: bool = false

## Currently offered upgrades. Index 0 = J key, index 1 = K key.
## null means the slot is empty (purchased or unavailable).
var _offered: Array = [null, null]

var _refresh_timer: float = 0.0
## Tower archers are a PERMANENT purchase now — once bought the upgrade leaves the
## lottery pool for good (it used to re-enter the pool whenever the archer died).
var _tower_archer_bought: Dictionary = {"right": false, "left": false}
## Reference count for active enemy-freeze effects. Enemies stay frozen until
## every outstanding timer has expired.
var _freeze_count: int = 0
var _tnt_purchase_count: int = 0

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
	if option1_button != null:
		option1_button.pressed.connect(func() -> void: _request_purchase(0))
	if option2_button != null:
		option2_button.pressed.connect(func() -> void: _request_purchase(1))
	# Make each upgrade button fill its parent scroll TextureRect, then ensure
	# nothing in that parent swallows clicks before the button can receive them.
	_setup_shop_button(option1_button, option1_icon)
	_setup_shop_button(option2_button, option2_icon)
	# TNT: the parent TextureRect isn't exposed as an icon export, so resolve it
	# from the button itself.
	if tnt_button != null:
		_setup_shop_button(tnt_button, tnt_button.get_parent() as Control)
	if tnt_button != null:
		tnt_button.pressed.connect(_on_tnt_button_pressed)
	_update_tnt_cost_label()
	# The shop runs a continuous refresh cycle so the always-visible hourglass is
	# meaningful even before the first visit. Start it full.
	_refresh_timer = refresh_interval
	if hourglass_sprite != null:
		hourglass_sprite.stop()
	_update_hourglass()


func _process(delta: float) -> void:
	_heal_player(delta)
	_handle_blacksmith_refresh(delta)
	_update_enemy_indicators()

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
	# In multiplayer, only respond to the locally-owned character — not the peer's puppet.
	if not _is_local_player(player):
		return
	_player = player
	_player_in_monk_zone = true
	player.healing_locked = true
	if monk_sprite != null:
		monk_sprite.play(&"Heal")
	# Notify the host so it applies the same healing to the joiner's puppet.
	# Without this the host's state snapshot overwrites the joiner's locally healed HP.
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({"t": "monk_zone", "in": 1})


func _on_monk_zone_body_exited(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	if not _is_local_player(player):
		return
	_player_in_monk_zone = false
	player.healing_locked = false
	if monk_sprite != null:
		monk_sprite.play(&"Idle")
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({"t": "monk_zone", "in": 0})
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
	# In multiplayer, only respond to the locally-owned character — not the peer's puppet.
	if not _is_local_player(player):
		return
	_player = player
	_player_in_blacksmith_zone = true
	player.attacks_locked = true
	# Every machine rolls its own offers for its local player. Only roll fresh ones
	# if none are active (first visit or all slots purchased); re-entering mid-timer
	# keeps the existing offers and running timer. Always re-price the labels on
	# entry in case pip counts changed while away.
	if _offered[0] == null and _offered[1] == null:
		_roll_upgrades()
		_refresh_timer = refresh_interval
	else:
		_update_ui_slot(0)
		_update_ui_slot(1)
	_show_upgrade_ui(true)


func _on_blacksmith_zone_body_exited(body: Node2D) -> void:
	var player := _get_character(body)
	if player == null:
		return
	if not _is_local_player(player):
		return
	_player_in_blacksmith_zone = false
	player.attacks_locked = false
	_show_upgrade_ui(false)
	_clear_player_if_unused()


func _handle_blacksmith_refresh(delta: float) -> void:
	# The shop runs a continuous refresh cycle so the always-visible hourglass
	# stays meaningful between visits. Rolling only happens while the player is
	# actually at the blacksmith; away, any active offers are cleared so the next
	# visit re-rolls fresh.
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = refresh_interval
		if _player_in_blacksmith_zone:
			# Player is present -- re-roll and display immediately.
			_roll_upgrades()
		elif _offered[0] != null or _offered[1] != null:
			# Player is away -- clear stale offers so the next visit re-rolls fresh.
			_offered[0] = null
			_offered[1] = null
	_update_hourglass()


## Drives the hourglass AnimatedSprite2D so its 5-frame loop mirrors the refresh
## cycle: frame 0 right after offers roll, final frame just before they re-roll.
func _update_hourglass() -> void:
	if hourglass_sprite == null:
		return
	var frames: SpriteFrames = hourglass_sprite.sprite_frames
	if frames == null:
		return
	var anim: StringName = hourglass_sprite.animation
	var count: int = frames.get_frame_count(anim)
	if count <= 0:
		return
	# elapsed 0..1 through the interval (0 = just rolled, 1 = about to roll).
	var elapsed: float = 1.0 - clampf(_refresh_timer / maxf(refresh_interval, 0.001), 0.0, 1.0)
	var frame: int = clampi(int(elapsed * count), 0, count - 1)
	if hourglass_sprite.frame != frame:
		hourglass_sprite.frame = frame


## Initiates a purchase. In multiplayer the joiner sends a request to the host
## (who validates and applies). The host and solo player execute immediately.
func _request_purchase(slot: int) -> void:
	var upgrade: UpgradeConfig = _offered[slot] as UpgradeConfig
	if upgrade == null:
		return
	if GameManager.session_id != "" and not GameManager.is_host:
		# Maxed stat: no-op refund handled entirely locally — don't bother the host.
		if _is_maxed(upgrade, _local_character()):
			_flash_purchase_icon(slot)
			_roll_upgrades()
			_refresh_timer = refresh_interval
			return
		# Joiner: ask the host to validate and apply. Offers differ per machine,
		# so send the upgrade identity, not the local slot index.
		WebRTCManager.send_reliable({"t": "upgrade_buy", "upg": _upgrade_index(upgrade)})
	else:
		_try_purchase(slot, _player)


## Executes a validated purchase for `buyer`. In multiplayer (host path) this
## also broadcasts the result so the joiner can sync their state.
func _try_purchase(slot: int, buyer: CharacterBase) -> void:
	var upgrade: UpgradeConfig = _offered[slot] as UpgradeConfig
	if upgrade == null or buyer == null:
		return
	# Maxed stat pip: refresh the shop, keep the coins (no-op refund).
	if _is_maxed(upgrade, buyer):
		_flash_purchase_icon(slot)
		_roll_upgrades()
		_refresh_timer = refresh_interval
		return
	var cost: int = _offer_cost(upgrade, buyer)
	if buyer.coins < cost:
		if coins_display != null and coins_display.has_method(&"flash_insufficient"):
			coins_display.flash_insufficient()
		_flash_deny_icon(slot)
		return
	buyer.add_coins(-cost)
	_apply_upgrade_to_buyer(upgrade, buyer)
	_flash_purchase_icon(slot)
	_roll_upgrades()
	_refresh_timer = refresh_interval
	# In multiplayer, host broadcasts what happened so the joiner can sync.
	if GameManager.session_id != "" and GameManager.is_host:
		var buyer_slot: int = int(buyer.get("player_slot")) if "player_slot" in buyer else 1
		WebRTCManager.send_reliable({
			"t":          "upgrade_applied",
			"buyer_slot": buyer_slot,
			"stat_type":  upgrade.stat_type,
			"stat_amount": upgrade.stat_amount,
			"cost":       cost,
		})
		if upgrade.pip_category() != "":
			_broadcast_stat_pips(buyer)


## Applies the upgrade effect to `buyer` (personal stats) or to the game world
## (castle / enemies). Separated so both host-local and network-received purchases
## use the same logic.
func _apply_upgrade_to_buyer(upgrade: UpgradeConfig, buyer: CharacterBase) -> void:
	# Stat upgrades add a pip in their category (hp/attack/speed cap at MAX_PIPS;
	# "flow" refills to full). max_health / attack_bonus / speed_bonus and the flow
	# window size are all derived from stat_pips inside CharacterBase.
	var pip_category: String = upgrade.pip_category()
	if pip_category != "":
		buyer.add_stat_pip(pip_category)
		return
	match upgrade.stat_type:
		# ── Global (world) effects — host-authoritative only ──────────────────
		UpgradeConfig.StatType.HEAL_CASTLE:
			if castle != null:
				castle.health = minf(castle.health + upgrade.stat_amount, castle.max_health)
				castle.health_changed.emit(castle.health, castle.max_health)
		UpgradeConfig.StatType.UPGRADE_CASTLE:
			if castle != null:
				castle.max_health += upgrade.stat_amount
				castle.health_changed.emit(castle.health, castle.max_health)
		UpgradeConfig.StatType.FREEZE_ENEMIES:
			_freeze_enemies(upgrade.stat_amount)
		UpgradeConfig.StatType.TOWER_ARCHER_RIGHT:
			_activate_tower_archer(tower_archer_right)
		UpgradeConfig.StatType.TOWER_ARCHER_LEFT:
			_activate_tower_archer(tower_archer_left)

# ── Lottery rolling ───────────────────────────────────────────────────────────

func _roll_upgrades() -> void:
	# Each machine rolls its own offers now — the shop serves the LOCAL player and
	# prices against that player's own pip counts, so host and joiners see different
	# options and different costs. No cross-peer offer broadcast.
	var t: float = _normalized_time()
	_offered[0] = _draw_one(t, [])
	_offered[1] = _draw_one(t, [_offered[0]])
	_update_ui_slot(0)
	_update_ui_slot(1)


## Returns the index of `upgrade` in the upgrades array, or -1 if null / not found.
func _upgrade_index(upgrade: UpgradeConfig) -> int:
	if upgrade == null:
		return -1
	return upgrades.find(upgrade)


## The locally-owned player character (the one this machine's shop serves).
func _local_character() -> CharacterBase:
	if _player != null and is_instance_valid(_player):
		return _player
	for node in get_tree().get_nodes_in_group(&"players"):
		if node is CharacterBase and _is_local_player(node as CharacterBase):
			return node as CharacterBase
	return null


## Coin cost of `upgrade` for `buyer`. World upgrades use the flat resource cost;
## stat upgrades cost base + the number of pips already owned in that category.
func _offer_cost(upgrade: UpgradeConfig, buyer: CharacterBase) -> int:
	if upgrade == null:
		return 0
	var category: String = upgrade.pip_category()
	if category == "" or category == "flow" or buyer == null:
		return upgrade.cost
	return upgrade.cost + int(buyer.stat_pips.get(category, 0))


## True when `buyer` already has the maximum pips for `upgrade`'s category
## (hp/attack/speed only — "flow" always re-buyable as a refill).
func _is_maxed(upgrade: UpgradeConfig, buyer: CharacterBase) -> bool:
	if upgrade == null or buyer == null:
		return false
	var category: String = upgrade.pip_category()
	if category == "" or category == "flow":
		return false
	return int(buyer.stat_pips.get(category, 0)) >= CharacterBase.MAX_PIPS


## Broadcast one slot's pip snapshot so the owning peer (and puppets) stay in sync.
func _broadcast_stat_pips(buyer: CharacterBase) -> void:
	if GameManager.session_id == "" or not GameManager.is_host or buyer == null:
		return
	var slot: int = int(buyer.get("player_slot")) if "player_slot" in buyer else 1
	WebRTCManager.send_reliable({
		"t":    "stat_pips",
		"slot": slot,
		"pips": buyer.stat_pips.duplicate(),
	})


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
## Tower archer upgrades whose archer is already active are also excluded.
## Returns null if the pool is empty.
func _draw_one(t: float, exclude: Array) -> UpgradeConfig:
	var pool: Array[UpgradeConfig] = []
	var buyer: CharacterBase = _local_character()
	for upgrade: UpgradeConfig in upgrades:
		if upgrade == null or upgrade in exclude:
			continue
		# Skip tower archer upgrades once bought (permanent) or while still active.
		if upgrade.stat_type == UpgradeConfig.StatType.TOWER_ARCHER_RIGHT \
				and (_tower_archer_bought["right"] or _is_tower_archer_active(tower_archer_right)):
			continue
		if upgrade.stat_type == UpgradeConfig.StatType.TOWER_ARCHER_LEFT \
				and (_tower_archer_bought["left"] or _is_tower_archer_active(tower_archer_left)):
			continue
		# Skip stat upgrades the local player has already maxed — offering them
		# only yields a confusing no-op refund.
		if _is_maxed(upgrade, buyer):
			continue
		var tickets: int = 1
		if upgrade.pool_tickets_curve != null:
			tickets = _sample_lottery_tickets(upgrade.pool_tickets_curve, t)
		for _i in tickets:
			pool.append(upgrade)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


## Returns true when a tower archer wrapper node is currently active (not disabled).
func _is_tower_archer_active(archer: Node) -> bool:
	if archer == null:
		return false
	return archer.process_mode != Node.PROCESS_MODE_DISABLED

# ── UI helpers ────────────────────────────────────────────────────────────────

## Makes `btn` fill its `parent` Control and sets every non-button sibling
## Control in `parent` to MOUSE_FILTER_IGNORE so they don't swallow clicks.
func _setup_shop_button(btn: Button, parent: Control) -> void:
	if btn == null:
		return
	# Pass-through the parent itself (it's a decorative TextureRect/Control).
	if parent != null:
		parent.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Any sibling Controls (icon images, labels) must not intercept clicks.
		for child: Node in parent.get_children():
			if child is Control and child != btn:
				(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


func _show_upgrade_ui(show: bool) -> void:
	if upgrade_ui != null:
		upgrade_ui.visible = show
	if tnt_button != null:
		tnt_button.visible = show


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


## Briefly tints the TNT icon red to signal the player cannot afford it.
## Mirrors _flash_deny_icon — the TNT button's parent TextureRect is its icon.
func _flash_deny_tnt() -> void:
	if tnt_button == null:
		return
	var icon_ref := tnt_button.get_parent() as CanvasItem
	if icon_ref == null:
		return
	icon_ref.modulate = Color.RED
	var tween := create_tween()
	tween.tween_property(icon_ref, "modulate", Color.WHITE, 0.35)


func _update_ui_slot(slot: int) -> void:
	var upgrade: UpgradeConfig = _offered[slot] as UpgradeConfig
	var icon_ref: TextureRect = option1_icon if slot == 0 else option2_icon
	var cost_label: Label = option1_cost_label if slot == 0 else option2_cost_label
	if icon_ref == null:
		return
	if upgrade == null:
		icon_ref.hide()
		if cost_label != null:
			cost_label.hide()
		return
	icon_ref.texture = upgrade.icon
	icon_ref.show()
	if cost_label != null:
		var buyer: CharacterBase = _local_character()
		if _is_maxed(upgrade, buyer):
			cost_label.text = "MAX"
		else:
			cost_label.text = str(_offer_cost(upgrade, buyer))
		cost_label.show()

# ── Cleanup ───────────────────────────────────────────────────────────────────

func _clear_player_if_unused() -> void:
	if not _player_in_monk_zone and not _player_in_blacksmith_zone:
		_player = null


# ── Multiplayer helpers ───────────────────────────────────────────────────────

## Returns true when `player` is the locally-owned character for this peer.
## In solo play every character is local. Online, a peer owns the slot matching
## GameManager.my_slot (host = 1, joiners = 2/3); puppets are rejected.
func _is_local_player(player: CharacterBase) -> bool:
	if GameManager.session_id == "":
		return true
	var slot: int = int(player.get("player_slot")) if "player_slot" in player else 1
	return slot == GameManager.my_slot


## Returns the spawned character whose player_slot matches `slot`, or null.
## Used so TNT follows whoever actually bought it — the local player, or the
## on-screen puppet of the other peer.
func _character_for_slot(slot: int) -> CharacterBase:
	for node in get_tree().get_nodes_in_group(&"players"):
		if node is CharacterBase:
			var s: int = int(node.get("player_slot")) if "player_slot" in node else 1
			if s == slot:
				return node as CharacterBase
	return null


## Called by RunManager when an "upgrade_buy" packet arrives (host only).
## The joiner sends the upgrade IDENTITY (index into `upgrades`) because each
## machine rolls its own offers. The host validates against the shared coin pool,
## applies the effect to that slot's character/puppet, and broadcasts the result.
func on_upgrade_buy(data: Dictionary) -> void:
	if not GameManager.is_host:
		return
	var upg_idx: int = int(data.get("upg", -1))
	if upg_idx < 0 or upg_idx >= upgrades.size():
		return
	var upgrade: UpgradeConfig = upgrades[upg_idx] as UpgradeConfig
	if upgrade == null:
		return
	var buyer_slot: int = int(data.get("_from", 2))
	var buyer: CharacterBase = _character_for_slot(buyer_slot)
	if buyer == null:
		return
	# Maxed stat pip: tell the buyer to refresh their shop, no coin change.
	if _is_maxed(upgrade, buyer):
		WebRTCManager.send_reliable({"t": "upgrade_applied", "buyer_slot": buyer_slot, "noop": true})
		return
	var cost: int = _offer_cost(upgrade, buyer)
	if GameManager.coin_balance < cost:
		WebRTCManager.send_reliable({"t": "upgrade_denied", "buyer_slot": buyer_slot})
		return
	# Spend from the shared party pool (single value — deduct once).
	GameManager.add_coins(-cost)
	_apply_upgrade_to_buyer(upgrade, buyer)
	# Send the pip snapshot BEFORE upgrade_applied so the joiner has the new pip
	# counts when it re-rolls its shop and re-prices the labels.
	if upgrade.pip_category() != "":
		_broadcast_stat_pips(buyer)
	WebRTCManager.send_reliable({
		"t":          "upgrade_applied",
		"buyer_slot": buyer_slot,
		"stat_type":  upgrade.stat_type,
		"cost":       cost,
	})


## Called by RunManager when an "upgrade_applied" packet arrives (joiner only).
## Keeps the shared coin pool in sync and plays purchase feedback. The actual pip
## change arrives separately via a "stat_pips" packet; world effects (castle HP)
## arrive via the state snapshot; tower archers are re-activated locally here.
func on_upgrade_applied(data: Dictionary) -> void:
	if GameManager.is_host:
		return
	var buyer_slot: int = int(data.get("buyer_slot", GameManager.my_slot))
	var is_mine: bool = buyer_slot == GameManager.my_slot
	if bool(data.get("noop", false)):
		if is_mine:
			_flash_purchase_icon(0)
			_roll_upgrades()
			_refresh_timer = refresh_interval
		return
	var cost: int = int(data.get("cost", 0))
	GameManager.add_coins(-cost)  # shared pool — deduct once
	var stat_type: int = int(data.get("stat_type", -1))
	match stat_type:
		UpgradeConfig.StatType.TOWER_ARCHER_RIGHT:
			_activate_tower_archer(tower_archer_right)
		UpgradeConfig.StatType.TOWER_ARCHER_LEFT:
			_activate_tower_archer(tower_archer_left)
	if is_mine:
		_flash_purchase_icon(0)
		_roll_upgrades()
		_refresh_timer = refresh_interval


## Called by RunManager when an "upgrade_denied" packet arrives (joiner only).
func on_upgrade_denied(data: Dictionary) -> void:
	if GameManager.is_host:
		return
	if int(data.get("buyer_slot", GameManager.my_slot)) != GameManager.my_slot:
		return
	if coins_display != null and coins_display.has_method(&"flash_insufficient"):
		coins_display.flash_insufficient()
	_flash_deny_icon(0)
	_flash_deny_icon(1)

# ── TNT ───────────────────────────────────────────────────────────────────────

func _on_tnt_button_pressed() -> void:
	_request_tnt_purchase()


func _request_tnt_purchase() -> void:
	if GameManager.session_id != "" and not GameManager.is_host:
		WebRTCManager.send_reliable({"t": "tnt_buy"})
	else:
		_try_tnt_purchase(_player)


func _try_tnt_purchase(buyer: CharacterBase, from_remote: bool = false) -> void:
	if buyer == null:
		return
	var cost: int = _tnt_current_cost()
	if buyer.coins < cost:
		if from_remote:
			var bs: int = int(buyer.get("player_slot")) if "player_slot" in buyer else 2
			WebRTCManager.send_reliable_to(bs, {"t": "tnt_denied"})
		else:
			if coins_display != null and coins_display.has_method(&"flash_insufficient"):
				coins_display.flash_insufficient()
			_flash_deny_tnt()
		return
	GameManager.add_coins(-cost)  # shared party pool — spend once
	_tnt_purchase_count += 1
	_update_tnt_cost_label()
	_spawn_tnt(buyer)
	if GameManager.session_id != "" and GameManager.is_host:
		WebRTCManager.send_reliable({
			"t":          "tnt_applied",
			"cost":       cost,
			"buyer_slot": int(buyer.get("player_slot")) if "player_slot" in buyer else 1,
		})


func _tnt_current_cost() -> int:
	if tnt_costs.is_empty():
		return 15
	return tnt_costs[mini(_tnt_purchase_count, tnt_costs.size() - 1)]


func _update_tnt_cost_label() -> void:
	if tnt_cost_label != null:
		tnt_cost_label.text = str(_tnt_current_cost())


func _spawn_tnt(buyer: CharacterBase) -> void:
	if tnt_scene == null:
		push_warning("CastleInside: tnt_scene not assigned — TNT cannot be spawned.")
		return
	var tnt := tnt_scene.instantiate() as Node2D
	if tnt == null:
		return
	tnt.global_position = buyer.global_position
	if "owner_player" in tnt:
		tnt.set("owner_player", buyer)
	get_tree().current_scene.add_child(tnt)


## Called by RunManager when a "tnt_buy" packet arrives (host only).
## The TNT belongs to whichever joiner asked — it follows that joiner's puppet.
func on_tnt_buy(data: Dictionary) -> void:
	if not GameManager.is_host:
		return
	var buyer: CharacterBase = _character_for_slot(int(data.get("_from", 2)))
	if buyer == null:
		return
	_try_tnt_purchase(buyer, true)


## Called by RunManager when a "tnt_applied" packet arrives (joiner only).
func on_tnt_applied(data: Dictionary) -> void:
	if GameManager.is_host:
		return
	var cost: int = int(data.get("cost", 0))
	var buyer_slot: int = int(data.get("buyer_slot", 1))
	GameManager.add_coins(-cost)  # shared party pool — spend once
	_tnt_purchase_count += 1
	_update_tnt_cost_label()
	# Follow whoever bought it — the buyer's character or on-screen puppet.
	var follow: CharacterBase = _character_for_slot(buyer_slot)
	if follow == null:
		follow = _local_character()
	if follow != null:
		_spawn_tnt(follow)


## Called by RunManager when a "tnt_denied" packet arrives (joiner only).
func on_tnt_denied(_data: Dictionary) -> void:
	if GameManager.is_host:
		return
	if coins_display != null and coins_display.has_method(&"flash_insufficient"):
		coins_display.flash_insufficient()
	_flash_deny_tnt()

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


## Host: castle-interior state a mid-run joiner needs. Tower archers are permanent
## purchases, so a late joiner must be told about ones bought before they arrived.
func build_snapshot() -> Dictionary:
	return {
		"archer_right": 1 if bool(_tower_archer_bought["right"]) else 0,
		"archer_left":  1 if bool(_tower_archer_bought["left"]) else 0,
	}


## Joiner: adopt the castle-interior snapshot.
func apply_snapshot(d: Dictionary) -> void:
	if GameManager.is_host:
		return
	if int(d.get("archer_right", 0)) == 1:
		_activate_tower_archer(tower_archer_right)
	if int(d.get("archer_left", 0)) == 1:
		_activate_tower_archer(tower_archer_left)


## Enables a tower archer node that was placed disabled in the level.
## Resets health/state on the CharacterBody2D child, makes the wrapper visible,
## and re-enables processing.
func _activate_tower_archer(archer: Node) -> void:
	if archer == null:
		push_warning("CastleInside: tower archer node not assigned in Inspector.")
		return
	# Permanent purchase: the upgrade never returns to the lottery pool, even
	# after the archer dies and respawns.
	if archer == tower_archer_right:
		_tower_archer_bought["right"] = true
	elif archer == tower_archer_left:
		_tower_archer_bought["left"] = true
	# Find the CharacterBody2D child that carries tower_archer.gd.
	var body: Node = null
	for child in archer.get_children():
		if child is CharacterBody2D:
			body = child
			break
	if body != null:
		body.is_dead = false
		body.health = body.max_health
		body.shoot_state = 0  # ShootState.NONE
		body.set_physics_process(true)
		var spr: AnimatedSprite2D = body.find_child("AnimatedSprite2D") as AnimatedSprite2D
		if spr != null:
			spr.show()
			spr.play(&"idle")
		if body.health_bar != null:
			body.health_bar.show()
		body.health_changed.emit(body.health, body.max_health)
	archer.show()
	archer.process_mode = Node.PROCESS_MODE_INHERIT


# ── Enemy indicators ─────────────────────────────────────────────────────────

func _update_enemy_indicators() -> void:
	var left_count: int = 0
	var right_count: int = 0
	for node in get_tree().get_nodes_in_group(&"entities"):
		if node is EnemyBase and not (node as EnemyBase).is_dead:
			if node.global_position.x < 0.0:
				left_count += 1
			else:
				right_count += 1
	_apply_indicator(left_exclamation, left_count)
	_apply_indicator(right_exclamation, right_count)


func _apply_indicator(sprite: Sprite2D, count: int) -> void:
	if sprite == null:
		return
	if count == 0:
		sprite.hide()
		return
	sprite.show()
	var colors: Array[Color] = [enemy_color_1, enemy_color_2, enemy_color_3, enemy_color_4, enemy_color_5]
	sprite.modulate = colors[mini(count, 5) - 1]

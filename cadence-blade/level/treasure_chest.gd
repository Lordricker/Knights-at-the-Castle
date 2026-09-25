class_name TreasureChest
extends Node2D

## treasure_chest.gd — Reward chest dropped where an EnemyTower falls.
##
## EnemyTower.destroy() (and its joiner mirror) instances treasureChest.tscn at
## the tower's position and gives it a deterministic name ("TreasureChest_<tower>")
## so the host and joiner copies correlate over the network.
##
## A player who walks into the Hitbox Area2D "opens" the chest: one stat category
## is chosen at random (preferring one the player has not maxed), that player
## gains a FREE pip in it via CharacterBase.add_stat_pip(), the matching reward
## icon floats up `icon_rise_px`, holds for `hold_seconds`, then the whole chest
## frees itself.
##
## Multiplayer (host-authoritative, same shape as coins / blacksmith upgrades):
##   • solo / host — the toucher's machine rolls the category, applies the pip,
##     then broadcasts {"t":"chest_opened", "chest":<name>, "cat":<cat>}. Every
##     joiner plays the same open visual and frees its copy. The pip itself
##     reaches joiners through the normal "stat_pips" snapshot.
##   • joiner — sends {"t":"chest_open_req", "chest":<name>}; the host resolves
##     the requesting slot's character and rolls + applies + broadcasts as above.
##     The joiner's own copy waits for "chest_opened" before playing so the icon
##     it shows always matches the host's roll.

## Stat pip categories a chest can grant (CharacterBase.stat_pips keys).
const STAT_CATEGORIES: Array[String] = ["attack", "hp", "speed"]

## Maps each stat category to the reward-icon child node that depicts it.
## The icon art is what the player reads: sword = attack, heart = hp,
## speed lines = speed.
const ICON_NODES: Dictionary = {
	"attack": "upattack",
	"hp":     "uphealth",
	"speed":  "upspeed",
}

## Pixels the winning reward icon floats upward once the chest opens.
@export var icon_rise_px: float = 13.0
## Seconds the icon takes to float up.
@export var icon_rise_seconds: float = 0.25
## Seconds the opened chest lingers (icon raised) before it frees itself.
@export var hold_seconds: float = 1.0

@onready var _animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var _hitbox: Area2D = _find_hitbox()


## The player-detection Area2D. Named "Area2D" in the .tscn today; fall back to
## the first Area2D child so a rename in the editor doesn't break detection.
func _find_hitbox() -> Area2D:
	var direct := get_node_or_null(^"Area2D") as Area2D
	if direct != null:
		return direct
	for child in get_children():
		if child is Area2D:
			return child as Area2D
	return null

## True once the chest has been opened — guards against a second toucher and a
## late network request racing the local overlap.
var _opened: bool = false
## Joiner only: true once we have asked the host to open this chest, so repeated
## overlaps don't spam duplicate requests.
var _open_requested: bool = false
## Category whose icon is waiting for the lid to reach its open frame.
var _pending_icon_cat: String = ""
## True once the reward icon has been revealed (guards the frame_changed handler).
var _icon_revealed: bool = false
## When set to a STAT_CATEGORIES entry, _roll_category() always returns it instead
## of rolling. Used by the weasel, whose chest must contain the exact pip it stole.
var _forced_category: String = ""


## Pre-seed this chest to always grant `cat` (must be one of STAT_CATEGORIES).
## Called by weasle.gd right after the chest is spawned, on both peers.
func set_forced_category(cat: String) -> void:
	_forced_category = cat


func _ready() -> void:
	add_to_group(&"treasure_chests")
	if _animated_sprite != null:
		_animated_sprite.stop()
		_animated_sprite.frame = 0  # closed
	for cat: String in ICON_NODES:
		var icon := get_node_or_null(NodePath(ICON_NODES[cat])) as CanvasItem
		if icon != null:
			icon.hide()
	if _hitbox != null:
		_hitbox.body_entered.connect(_on_hitbox_body_entered)


func _on_hitbox_body_entered(body: Node2D) -> void:
	if _opened or _open_requested:
		return
	var player := body as CharacterBase
	if player == null or player.is_dead:
		return
	if not _is_local_player(player):
		return
	if GameManager.session_id == "" or GameManager.is_host:
		_open_as_host(player)
	else:
		_open_requested = true
		WebRTCManager.send_reliable({"t": "chest_open_req", "chest": str(name)})


## Solo / host: roll a category, grant the pip, broadcast, play the open visual.
func _open_as_host(player: CharacterBase) -> void:
	if _opened:
		return
	_opened = true
	var cat: String = _roll_category(player)
	if player != null:
		player.add_stat_pip(cat)
	if GameManager.session_id != "" and GameManager.is_host:
		var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
		if rm != null and rm.has_method(&"_broadcast_stat_pips_for"):
			rm.call(&"_broadcast_stat_pips_for", player)
		WebRTCManager.send_reliable({"t": "chest_opened", "chest": str(name), "cat": cat})
	_play_open(cat)


## Host: a joiner asked to open this chest. Resolve their character and open.
func on_open_request(from_slot: int) -> void:
	if _opened:
		return
	var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
	var player: CharacterBase = null
	if rm != null and rm.has_method(&"_character_for_slot"):
		player = rm.call(&"_character_for_slot", from_slot) as CharacterBase
	if player == null:
		return
	_open_as_host(player)


## Joiner: the host opened this chest — play the matching visual only. The pip
## itself arrives through the normal "stat_pips" snapshot.
func on_opened_remote(cat: String) -> void:
	if _opened:
		return
	_opened = true
	_play_open(cat)


## Pick a stat category, preferring ones `player` has not maxed. Falls back to
## any category when every stat is already full (visual reward only).
func _roll_category(player: CharacterBase) -> String:
	if _forced_category != "" and _forced_category in STAT_CATEGORIES:
		return _forced_category
	var candidates: Array[String] = []
	if player != null:
		for cat: String in STAT_CATEGORIES:
			if int(player.stat_pips.get(cat, 0)) < CharacterBase.MAX_PIPS:
				candidates.append(cat)
	if candidates.is_empty():
		candidates = STAT_CATEGORIES.duplicate()
	return candidates[randi() % candidates.size()]


func _play_open(cat: String) -> void:
	if _hitbox != null:
		_hitbox.set_deferred(&"monitoring", false)
	# The reward icon stays hidden until the lid sprite flips to its open frame
	# (frame 1). If there is no sprite to wait on, reveal it right away.
	_pending_icon_cat = cat
	if _animated_sprite != null and _animated_sprite.sprite_frames != null:
		_animated_sprite.frame = 0
		_animated_sprite.play(&"default")
		if _animated_sprite.frame >= 1:
			_reveal_icon(cat)
		else:
			_animated_sprite.frame_changed.connect(_on_lid_frame_changed)
	else:
		_reveal_icon(cat)


## Fires as the lid animation advances; reveals the reward once frame 1 (the
## open-lid frame) is showing.
func _on_lid_frame_changed() -> void:
	if _icon_revealed or _animated_sprite == null or _animated_sprite.frame < 1:
		return
	if _animated_sprite.frame_changed.is_connected(_on_lid_frame_changed):
		_animated_sprite.frame_changed.disconnect(_on_lid_frame_changed)
	_reveal_icon(_pending_icon_cat)


## Shows the winning icon, floats it up `icon_rise_px`, then frees the chest
## after it has held for `hold_seconds`.
func _reveal_icon(cat: String) -> void:
	if _icon_revealed:
		return
	_icon_revealed = true
	var icon := get_node_or_null(NodePath(ICON_NODES.get(cat, ""))) as CanvasItem
	if icon != null:
		icon.show()
		var start: Vector2 = icon.get(&"position")
		var tween := create_tween()
		tween.tween_property(icon, "position", start - Vector2(0.0, icon_rise_px), icon_rise_seconds)
	get_tree().create_timer(icon_rise_seconds + hold_seconds).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _is_local_player(player: CharacterBase) -> bool:
	if GameManager.session_id == "":
		return true
	var slot: int = int(player.get("player_slot")) if "player_slot" in player else 1
	return slot == GameManager.my_slot

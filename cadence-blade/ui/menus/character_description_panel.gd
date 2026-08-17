# character_description_panel.gd
# Attach this script to a Control node that acts as the character stat panel in
# the character selection screen.
#
# SETUP:
#   1. Add this script to a Control (e.g. a PanelContainer) in your scene.
#   2. Assign "character_scenes" in the Inspector — one PackedScene per character
#      in the same order as CHARACTER_KEYS: [RedKnight.tscn, GreenArcher.tscn, BlueRogue.tscn].
#   3. Drag your Label nodes into the matching stat label fields in each group.
#   4. The panel starts hidden. It shows and fills in stats when populate() is
#      called — main_menu.gd wires this automatically via session_entry.
#
# Stats are read by calling get_character_stats() on the instantiated scene.
# Each character script must implement that method (red_knight.gd / green_archer.gd do).
# The "display_name" export on CharacterBase lets you set a custom name per character.

extends Control

## Character keys in the same order as the character_scenes array below.
const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer", "rogue"]

# ── Character scenes ──────────────────────────────────────────────────────────

## PackedScenes for each character, in CHARACTER_KEYS order.
## e.g. slot 0 = RedKnight.tscn, slot 1 = GreenArcher.tscn.
@export var character_scenes: Array[PackedScene] = []

# ── Character header labels ────────────────────────────────────────────────────

@export_group("Character Header Labels")
## Displays the character's display name (set via the 'display_name' export on the character).
@export var character_name_label: Label
## Displays the character's max health value.
@export var character_health_label: Label
## Displays the character's base movement speed.
@export var character_speed_label: Label
## Displays the character's knockback resistance as a weight value.
@export var weight_label: Label
@export_group("")

# ── Action 1 (J) labels ───────────────────────────────────────────────────────

@export_group("Action 1 (J) Labels")
## Shows the action name, e.g. "Slash" or "Shoot".
@export var action1_name_label: Label
## Shows the base damage value.
@export var action1_damage_label: Label
## Shows the knockback force value.
@export var action1_knockback_label: Label
@export_group("")

# ── Action 2 (K) labels ───────────────────────────────────────────────────────

@export_group("Action 2 (K) Labels")
## Shows the action name, e.g. "Thrust" or "Pierce".
@export var action2_name_label: Label
## Shows the base damage value.
@export var action2_damage_label: Label
## Shows the knockback force value.
@export var action2_knockback_label: Label
@export_group("")

# ── Action 3 (L) labels ───────────────────────────────────────────────────────

@export_group("Action 3 (L) Labels")
## Shows the action name, e.g. "Spin" or "Kick".
@export var action3_name_label: Label
## Shows the base damage value.
@export var action3_damage_label: Label
## Shows the knockback force value.
@export var action3_knockback_label: Label
@export_group("")


# ── Public API ────────────────────────────────────────────────────────────────

## Show the panel and fill all stat labels from the selected character's scene.
## character_key must match one of the keys in CHARACTER_KEYS.
func populate(character_key: String) -> void:
	var idx: int = CHARACTER_KEYS.find(character_key)
	if idx < 0 or idx >= character_scenes.size() or character_scenes[idx] == null:
		push_warning("CharacterDescriptionPanel: no scene assigned for key '%s'" % character_key)
		show()
		return

	var root: Node = character_scenes[idx].instantiate()
	# The script may live on a child node rather than the scene root (e.g. a Node2D wrapper).
	var ch: Node = _find_stats_node(root)
	if ch == null:
		push_warning("CharacterDescriptionPanel: no get_character_stats() found in '%s' scene." % character_key)
		root.free()
		show()
		return

	_fill_from_stats(ch.get_character_stats(), character_key)
	root.free()
	show()


## Recursively searches the node tree for the first node that has get_character_stats().
func _find_stats_node(node: Node) -> Node:
	if node.has_method("get_character_stats"):
		return node
	for child in node.get_children():
		var found: Node = _find_stats_node(child)
		if found != null:
			return found
	return null


# ── Internals ────────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()


func _fill_from_stats(stats: Dictionary, fallback_key: String) -> void:
	var name_str: String = stats.get("display_name", "")
	if name_str.is_empty():
		name_str = fallback_key.replace("_", " ").capitalize()
	_set_label(character_name_label, name_str)
	_set_label(character_health_label, "HP  %s" % _fmt(stats.get("max_health", null)))
	_set_label(character_speed_label,  "Speed  %s" % _fmt(stats.get("move_speed", null)))
	_set_label(weight_label,           "Weight  %s" % _fmt(stats.get("knockback_friction", null)))

	_fill_action(stats.get("action1", {}),
			action1_name_label, action1_damage_label, action1_knockback_label)
	_fill_action(stats.get("action2", {}),
			action2_name_label, action2_damage_label, action2_knockback_label)
	_fill_action(stats.get("action3", {}),
			action3_name_label, action3_damage_label, action3_knockback_label)


func _fill_action(action: Dictionary, name_lbl: Label, dmg_lbl: Label, kb_lbl: Label) -> void:
	_set_label(name_lbl, action.get("name", "—"))
	_set_label(dmg_lbl,  _fmt(action.get("damage", null)))
	_set_label(kb_lbl,   _fmt(action.get("knockback", null)))


func _set_label(lbl: Label, text: String) -> void:
	if lbl != null:
		lbl.text = text


func _fmt(value: Variant) -> String:
	if value == null:
		return "—"
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return "%.0f" % float(value)
	return str(value)

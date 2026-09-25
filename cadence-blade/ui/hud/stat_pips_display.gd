class_name StatPipsDisplay
extends Control

# stat_pips_display.gd — Drives the HUD stat pip bars (HP / Attack / Speed / Flow).
#
# Scene layout this script expects (children of the node it is attached to):
#   GridContainer/
#     HP/pipcontainer/pip, pip2, pip3, pip4, pip5
#     Attack/pipcontainer/pip … pip5
#     Speed/pipcontainer/pip … pip5
#     Flow/pipcontainer/pip … pip5
#
# Each pip is a TextureRect showing pips.png (a white fill + dark outline). Filled
# pips are tinted to the category colour via `modulate` — which multiplies, so only
# the white section takes the colour and the dark outline stays dark. Empty pips
# get `empty_pip_modulate`.
#
# The bar binds to the LOCAL player's CharacterBase.stat_pips_changed signal.

## Tint applied to a filled HP pip.
@export var hp_pip_color: Color = Color(0.86, 0.12, 0.12)
## Tint applied to a filled Attack pip.
@export var attack_pip_color: Color = Color(1.0, 0.65, 0.15)
## Tint applied to a filled Speed pip.
@export var speed_pip_color: Color = Color(0.30, 0.65, 1.0)
## Tint applied to a filled Flow pip.
@export var flow_pip_color: Color = Color(1.0, 0.95, 0.35)
## Modulate applied to an empty (unfilled) pip in any category.
@export var empty_pip_modulate: Color = Color(0.25, 0.25, 0.25, 0.6)

## category key -> Array[TextureRect] (5 entries, index 0 = leftmost pip).
var _rows: Dictionary = {}
## category key -> filled Color
var _colors: Dictionary = {}
var _player: CharacterBase = null


func _ready() -> void:
	_colors = {
		"hp": hp_pip_color,
		"attack": attack_pip_color,
		"speed": speed_pip_color,
		"flow": flow_pip_color,
	}
	for pair in [["hp", "HP"], ["attack", "Attack"], ["speed", "Speed"], ["flow", "Flow"]]:
		var category: String = pair[0]
		var node_name: String = pair[1]
		var pips: Array[TextureRect] = []
		for i in range(1, 6):
			var pip_name: String = "pip" if i == 1 else "pip%d" % i
			var pip := get_node_or_null("GridContainer/%s/pipcontainer/%s" % [node_name, pip_name]) as TextureRect
			if pip != null:
				pips.append(pip)
		_rows[category] = pips
	# Paint an initial default state (HP/Attack/Speed empty, Flow full) until a
	# player connects.
	_paint({"hp": 0, "attack": 0, "speed": 0, "flow": CharacterBase.MAX_PIPS})


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_try_connect_player()


## Find the locally-owned player character and connect to its pip signal.
func _try_connect_player() -> void:
	for node in get_tree().get_nodes_in_group(&"players"):
		if node is CharacterBase and _is_local(node as CharacterBase):
			_player = node as CharacterBase
			if not _player.stat_pips_changed.is_connected(_on_stat_pips_changed):
				_player.stat_pips_changed.connect(_on_stat_pips_changed)
			_paint(_player.stat_pips)
			return


func _is_local(character: CharacterBase) -> bool:
	if GameManager.session_id == "":
		return true
	var slot: int = int(character.get("player_slot")) if "player_slot" in character else 1
	return slot == GameManager.my_slot


func _on_stat_pips_changed(stats: Dictionary) -> void:
	_paint(stats)


func _paint(stats: Dictionary) -> void:
	for category in _rows.keys():
		var filled: int = int(stats.get(category, 0))
		var color: Color = _colors.get(category, Color.WHITE)
		var pips: Array = _rows[category]
		for i in pips.size():
			(pips[i] as TextureRect).modulate = color if i < filled else empty_pip_modulate

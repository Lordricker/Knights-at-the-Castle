# detailed_stats_panel.gd
# Full character detail popup opened from the session screen's "Character Details"
# button. Each character has its own hand-authored container in the scene
# (Knight/Archer/Rogue) — this script only ever shows the one matching the
# currently selected character and hides the rest.

extends Control

@export var knight_container: Control
@export var archer_container: Control
@export var rogue_container:  Control
@export var close_button:     Button

var _pending_key: String = ""


func _ready() -> void:
	hide()
	if close_button:
		close_button.pressed.connect(close)


## Called whenever the selected character changes, even while the panel is closed,
## so the right container is ready by the time the button opens it.
func set_character(key: String) -> void:
	_pending_key = key
	if visible:
		_show_container(key)


func open() -> void:
	_show_container(_pending_key)
	show()


func close() -> void:
	hide()


func _show_container(key: String) -> void:
	var containers: Dictionary = {
		"red_knight":   knight_container,
		"green_archer": archer_container,
		"rogue":        rogue_container,
	}
	for k in containers:
		var c: Control = containers[k]
		if c:
			c.visible = (k == key)

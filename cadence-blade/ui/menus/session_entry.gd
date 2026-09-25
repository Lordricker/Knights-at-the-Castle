# session_entry.gd
# Controls a single SessionEntry widget. Used in two modes:
#
#   Host  (setup_as_host)  – PlayButton visible, JoinButton hidden,
#                            private toggle visible. Generates a fresh session ID.
#
#   Join  (setup_as_join)  – JoinButton visible, PlayButton hidden,
#                            private toggle hidden. Character covers shown for
#                            slots already taken in that live session.
#
# ── Inspector setup ──────────────────────────────────────────────────────────
# Assign the @export vars below.
# character_buttons and character_covers are wired via @onready ($NodeName)
# so they always resolve correctly even when the scene is dynamically loaded.
# ─────────────────────────────────────────────────────────────────────────────

extends Control

signal play_pressed(entry: Control)
signal join_pressed(entry: Control)

# One key per slot, in the same order as character_buttons / character_covers.
# Add a new entry here when adding a new character.
const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer", "rogue"]

# ── Inspector-assigned nodes ─────────────────────────────────────────────────
@export var play_button:      Button
@export var join_button:      Button
@export var private_toggle:   CheckButton
## When checked, PLAY starts an offline solo run (no Firebase, no WebRTC).
## Only meaningful in host mode; hidden by setup_as_join.
@export var solo_toggle:      CheckButton
@export var session_id_label: Label
@export var status_label:     Label

## Character select buttons — wired by node name, same order as CHARACTER_KEYS.
@onready var character_buttons: Array[Button]  = [$knightbutton, $archerbutton, $roguebutton]
## Covers shown over taken slots — each Cover is a child of its button, same order as CHARACTER_KEYS.
@onready var character_covers:  Array[Control] = [$knightbutton/KnightCover, $archerbutton/ArcherCover, $roguebutton/RogueCover]
## Optional: assign the CharacterDescriptionPanel node.
## It will be populated automatically when a character button is toggled on.
@export var description_panel: Control
## Optional: assign the "Character Details" button. Shown only while a
## character is selected, hidden otherwise.
@export var details_button: Button
## Optional: assign the DetailedStatsPanel node. Kept in sync with the
## current selection so it shows the right character as soon as it's opened.
@export var detailed_stats_panel: Control

# ── Runtime state ─────────────────────────────────────────────────────────────
var session_id:         String = ""
var selected_character: String = ""
var is_private:         bool   = false
## Read by main_menu.gd on play_pressed to route into GameManager.start_solo().
var is_solo:            bool   = false


func _ready() -> void:
	if play_button:
		play_button.pressed.connect(_on_play_pressed)
	if join_button:
		join_button.pressed.connect(_on_join_pressed)
	if private_toggle:
		private_toggle.toggled.connect(func(p: bool) -> void: is_private = p)
	if solo_toggle:
		solo_toggle.toggled.connect(_on_solo_toggled)
	for i in character_buttons.size():
		if character_buttons[i]:
			character_buttons[i].pressed.connect(_on_character_pressed.bind(i))


# ── Setup helpers ─────────────────────────────────────────────────────────────

func setup_as_host() -> void:
	if play_button:    play_button.show()
	if join_button:    join_button.hide()
	if private_toggle: private_toggle.show()
	if solo_toggle:    solo_toggle.show()
	for cov in character_covers:
		if cov: cov.hide()
	session_id = GameManager.generate_session_id()
	if session_id_label:
		session_id_label.text = session_id
	if status_label:
		status_label.text = ""
	_on_solo_toggled(solo_toggle.button_pressed if solo_toggle else false)


## Solo hides the session ID and the private toggle — neither means anything for
## an offline run.
func _on_solo_toggled(pressed: bool) -> void:
	is_solo = pressed
	if session_id_label:
		session_id_label.visible = not pressed
	if private_toggle:
		private_toggle.visible = not pressed


## taken_characters — array of character keys already claimed in this session.
## Slot i's cover is shown when CHARACTER_KEYS[i] is in that array.
func setup_as_join(sid: String, taken_characters: Array[String]) -> void:
	if play_button:    play_button.hide()
	if join_button:    join_button.show()
	if private_toggle: private_toggle.hide()
	if solo_toggle:    solo_toggle.hide()
	is_solo = false
	session_id = sid
	if session_id_label:
		session_id_label.text = sid
	if status_label:
		status_label.text = ""
	for i in character_buttons.size():
		var taken: bool = i < CHARACTER_KEYS.size() and CHARACTER_KEYS[i] in taken_characters
		if i < character_covers.size() and character_covers[i]:
			character_covers[i].visible = taken
		if character_buttons[i]:
			character_buttons[i].disabled = taken
			if taken:
				character_buttons[i].button_pressed = false


# ── Character selection ───────────────────────────────────────────────────────

func _on_character_pressed(index: int) -> void:
	if character_buttons[index].button_pressed:
		selected_character = CHARACTER_KEYS[index] if index < CHARACTER_KEYS.size() else ""
		for i in character_buttons.size():
			if i != index and character_buttons[i]:
				character_buttons[i].button_pressed = false
		_clear_status()
		if description_panel != null and description_panel.has_method("populate"):
			description_panel.populate(selected_character)
		if details_button != null:
			details_button.show()
		if detailed_stats_panel != null and detailed_stats_panel.has_method("set_character"):
			detailed_stats_panel.set_character(selected_character)
	else:
		selected_character = ""
		if description_panel != null:
			description_panel.hide()
		if details_button != null:
			details_button.hide()


# ── Action buttons ───────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	if selected_character.is_empty():
		_set_status("Select a character first!")
		return
	_set_status("Loading...")
	play_pressed.emit(self)


func _on_join_pressed() -> void:
	if selected_character.is_empty():
		_set_status("Select a character first!")
		return
	_set_status("Loading...")
	join_pressed.emit(self)


# ── Helpers ──────────────────────────────────────────────────────────────────

func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg


func _clear_status() -> void:
	if status_label:
		status_label.text = ""

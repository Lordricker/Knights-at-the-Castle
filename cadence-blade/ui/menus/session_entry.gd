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
# Assign the @export vars below. For character_buttons and character_covers,
# add entries in slot order: slot 0 = knight, slot 1 = archer, etc.
# The key at CHARACTER_KEYS[i] must match what Firebase stores for that slot.
# ─────────────────────────────────────────────────────────────────────────────

extends Control

signal play_pressed(entry: Control)
signal join_pressed(entry: Control)

# One key per slot, in the same order as character_buttons / character_covers.
# Add a new entry here when adding a new character.
const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer"]

# ── Inspector-assigned nodes ─────────────────────────────────────────────────
@export var play_button:      Button
@export var join_button:      Button
@export var private_toggle:   CheckButton
@export var session_id_label: Label
@export var status_label:     Label

## Slot 0 = knight button, slot 1 = archer button, etc.
@export var character_buttons: Array[Button] = []
## Slot 0 = knight cover, slot 1 = archer cover, etc.
@export var character_covers:  Array[Control] = []
## Optional: assign the CharacterDescriptionPanel node.
## It will be populated automatically when a character button is toggled on.
@export var description_panel: Control

# ── Runtime state ─────────────────────────────────────────────────────────────
var session_id:         String = ""
var selected_character: String = ""
var is_private:         bool   = false


func _ready() -> void:
	_ensure_char_nodes()
	if play_button:
		play_button.pressed.connect(_on_play_pressed)
	if join_button:
		join_button.pressed.connect(_on_join_pressed)
	if private_toggle:
		private_toggle.toggled.connect(func(p: bool) -> void: is_private = p)
	for i in character_buttons.size():
		if character_buttons[i]:
			character_buttons[i].pressed.connect(_on_character_pressed.bind(i))


## Ensures character_buttons and character_covers are populated.
## In Godot 4, typed-array node exports may not resolve NodePaths when the
## scene is loaded dynamically at runtime (load().instantiate()). This scans
## children as a reliable fallback — buttons with toggle_mode, ColorRects for covers.
func _ensure_char_nodes() -> void:
	var btns_ok: bool = character_buttons.size() == CHARACTER_KEYS.size() \
			and character_buttons[0] != null if character_buttons.size() > 0 else false
	var covs_ok: bool = character_covers.size() == CHARACTER_KEYS.size() \
			and character_covers[0] != null if character_covers.size() > 0 else false
	if btns_ok and covs_ok:
		return
	# Scan direct children: toggle Buttons (not CheckButton) → character_buttons;
	# ColorRects → character_covers. Scene order matches CHARACTER_KEYS order.
	var found_btns: Array[Button] = []
	var found_covs: Array[Control] = []
	for child in get_children():
		if child is Button and not (child is CheckButton) \
				and (child as Button).toggle_mode:
			found_btns.append(child as Button)
		elif child is ColorRect:
			found_covs.append(child as Control)
	if not btns_ok and found_btns.size() == CHARACTER_KEYS.size():
		character_buttons = found_btns
	if not covs_ok and found_covs.size() == CHARACTER_KEYS.size():
		character_covers = found_covs


# ── Setup helpers ─────────────────────────────────────────────────────────────

func setup_as_host() -> void:
	if play_button:    play_button.show()
	if join_button:    join_button.hide()
	if private_toggle: private_toggle.show()
	for cov in character_covers:
		if cov: cov.hide()
	session_id = GameManager.generate_session_id()
	if session_id_label:
		session_id_label.text = session_id
	if status_label:
		status_label.text = ""


## taken_characters — array of character keys already claimed in this session.
## Slot i's cover is shown when CHARACTER_KEYS[i] is in that array.
func setup_as_join(sid: String, taken_characters: Array[String]) -> void:
	# Re-run node discovery in case typed-array NodePath exports didn't resolve
	# when the scene was loaded dynamically via load().instantiate().
	_ensure_char_nodes()
	if play_button:    play_button.hide()
	if join_button:    join_button.show()
	if private_toggle: private_toggle.hide()
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
	else:
		selected_character = ""
		if description_panel != null:
			description_panel.hide()


# ── Action buttons ───────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	if selected_character.is_empty():
		_set_status("Select a character first!")
		return
	play_pressed.emit(self)


func _on_join_pressed() -> void:
	if selected_character.is_empty():
		_set_status("Select a character first!")
		return
	join_pressed.emit(self)


# ── Helpers ──────────────────────────────────────────────────────────────────

func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg


func _clear_status() -> void:
	if status_label:
		status_label.text = ""

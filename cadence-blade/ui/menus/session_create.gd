# session_create.gd
# Character select + session create screen.
#
# Flow:
#   1. User sees available characters (grayed out if somehow duplicated).
#   2. User selects a character portrait.
#   3. User sees a generated session ID and optional Private toggle.
#   4. Pressing START writes the session to Firebase and calls GameManager.begin_hosting().
#   5. A "Waiting for player..." status appears while WebRTC signaling runs.
#   6. GameManager._on_mesh_ready → _rpc_announce_character → _rpc_load_level
#      loads the game for both players automatically.
#
# To add character portrait images:
#   Replace the placeholder ColorRect buttons with TextureButton nodes pointing
#   to your portrait textures. See MULTIPLAYER_SETUP.md for details.

extends CanvasLayer

const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer"]
const CHARACTER_LABELS: Array[String] = ["Red Knight", "Green Archer"]
# Portrait placeholder colours (swap for TextureButton once you have art).
const CHARACTER_COLORS: Array[Color] = [
	Color(0.7, 0.1, 0.1),   # red
	Color(0.1, 0.55, 0.1),  # green
]

var _selected_character: String = ""
var _is_private: bool = false
var _session_id: String = ""
var _status_label: Label = null
var _start_btn: Button = null
var _char_buttons: Array[Button] = []
var _waiting: bool = false


func _ready() -> void:
	_session_id = GameManager.generate_session_id()

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.1, 1.0)
	root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "SELECT YOUR KNIGHT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	vbox.add_child(title)

	# Character portrait row.
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	vbox.add_child(hbox)

	for i in CHARACTER_KEYS.size():
		var btn := _make_portrait_button(CHARACTER_COLORS[i], CHARACTER_LABELS[i], i)
		_char_buttons.append(btn)
		hbox.add_child(btn)

	# Session ID display.
	var id_hbox := HBoxContainer.new()
	id_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	id_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(id_hbox)

	var id_lbl := Label.new()
	id_lbl.text = "Session ID:"
	id_lbl.add_theme_font_size_override("font_size", 18)
	id_hbox.add_child(id_lbl)

	var id_val := Label.new()
	id_val.text = _session_id
	id_val.add_theme_font_size_override("font_size", 24)
	id_val.modulate = Color(1.0, 0.85, 0.2)
	id_hbox.add_child(id_val)

	# Private toggle.
	var priv_hbox := HBoxContainer.new()
	priv_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	priv_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(priv_hbox)

	var priv_lbl := Label.new()
	priv_lbl.text = "Private session:"
	priv_lbl.add_theme_font_size_override("font_size", 16)
	priv_hbox.add_child(priv_lbl)

	var priv_check := CheckButton.new()
	priv_check.toggled.connect(_on_private_toggled)
	priv_hbox.add_child(priv_check)

	# Status label.
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.text = "Choose a character to begin."
	vbox.add_child(_status_label)

	# Start and Back buttons.
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	vbox.add_child(btn_row)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(130, 48)
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.pressed.connect(_on_back_pressed)
	btn_row.add_child(back_btn)

	_start_btn = Button.new()
	_start_btn.text = "START"
	_start_btn.custom_minimum_size = Vector2(200, 48)
	_start_btn.add_theme_font_size_override("font_size", 22)
	_start_btn.disabled = true
	_start_btn.pressed.connect(_on_start_pressed)
	btn_row.add_child(_start_btn)

	# Listen for connection failure.
	WebRTCManager.connection_failed.connect(_on_connection_failed)
	# Show live signaling steps in the status label while waiting for a joiner.
	WebRTCManager.debug_status.connect(func(msg: String) -> void:
		if _waiting:
			_status_label.text = msg)


func _make_portrait_button(color: Color, label: String, index: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(110, 130)
	btn.text = label
	btn.tooltip_text = label
	# Tint the button background as a portrait placeholder.
	btn.self_modulate = color
	btn.pressed.connect(_on_character_selected.bind(CHARACTER_KEYS[index], index))
	return btn


# ── Interaction ────────────────────────────────────────────────────────────────

func _on_private_toggled(pressed: bool) -> void:
	_is_private = pressed


func _on_character_selected(key: String, index: int) -> void:
	_selected_character = key
	_start_btn.disabled = false
	_status_label.text = "Ready as %s. Press START." % CHARACTER_LABELS[index]
	# Highlight selected, dim others.
	for i in _char_buttons.size():
		_char_buttons[i].modulate = Color(1, 1, 1, 1.0) if i == index else Color(1, 1, 1, 0.4)


func _on_start_pressed() -> void:
	if _selected_character.is_empty() or _waiting:
		return
	_waiting = true
	_start_btn.disabled = true
	_status_label.text = "Creating session..."

	GameManager.session_id = _session_id

	var session_data: Dictionary = {
		"is_private": _is_private,
		"status": "waiting",
		"elapsed_seconds": 0,
		"created_at": Time.get_unix_time_from_system(),
		"last_seen": Time.get_unix_time_from_system(),
		"players": {
			"1": {"character": _selected_character}
		}
	}

	FirebaseClient.create_session(_session_id, session_data,
		func(code: int, _data: Variant) -> void:
			if code != 200:
				_status_label.text = "Firebase error (code %d). Check your DB URL and rules." % code
				_waiting = false
				_start_btn.disabled = false
				return
			# Load the game immediately as solo. WebRTC host signaling runs in the
			# background -- when a joiner connects, game_manager._on_mesh_ready
			# spawns them into the already-running level.
			GameManager.begin_hosting(_selected_character)
			get_tree().change_scene_to_file(GameManager.GAME_LEVEL_SCENE)
	)


func _on_connection_failed(reason: String) -> void:
	_waiting = false
	_start_btn.disabled = (_selected_character.is_empty())
	_status_label.text = "Connection failed: %s" % reason
	# Remove the dangling Firebase session.
	if GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
		GameManager.session_id = ""


func _on_back_pressed() -> void:
	if GameManager.session_id != "":
		FirebaseClient.delete_session(GameManager.session_id, func(_c, _d): pass)
		GameManager.session_id = ""
	get_tree().change_scene_to_file("res://ui/menus/main_menu.tscn")

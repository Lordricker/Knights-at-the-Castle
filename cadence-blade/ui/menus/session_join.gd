# session_join.gd
# Lobby browser — shows active public sessions and lets the player join one.
#
# Flow:
#   1. Screen polls Firebase every POLL_INTERVAL seconds for active sessions.
#   2. Each non-private, non-in_game session appears as a row:
#        [HostPortrait] [OpenSlot?] | Session ID | Elapsed time | JOIN button
#   3. Pressing JOIN opens a character select panel (taken characters grayed out).
#   4. Selecting a character calls GameManager.begin_joining() which starts WebRTC.
#   5. GameManager._rpc_load_level fires on both peers when the mesh is ready.
#
# Manual join by ID:
#   The player can also type a session ID manually (useful for private sessions).

extends CanvasLayer

const CHARACTER_KEYS: Array[String] = ["red_knight", "green_archer"]
const CHARACTER_LABELS: Array[String] = ["Red Knight", "Green Archer"]
const CHARACTER_COLORS: Array[Color] = [Color(0.7, 0.1, 0.1), Color(0.1, 0.55, 0.1)]

const POLL_INTERVAL: float = 3.0

var _poll_timer: float = 0.0
var _session_list_vbox: VBoxContainer = null
var _status_label: Label = null
var _char_select_panel: Control = null
var _char_select_taken: Array[String] = []
var _joining_session_id: String = ""
var _waiting: bool = false
var _manual_id_field: LineEdit = null


func _ready() -> void:
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

	var outer_vbox := VBoxContainer.new()
	outer_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	outer_vbox.custom_minimum_size = Vector2(520, 0)
	outer_vbox.add_theme_constant_override("separation", 14)
	center.add_child(outer_vbox)

	var title := Label.new()
	title.text = "JOIN A SESSION"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	outer_vbox.add_child(title)

	# Status / refresh indicator.
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.text = "Loading sessions..."
	outer_vbox.add_child(_status_label)

	# Session list scroll area.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 260)
	outer_vbox.add_child(scroll)

	_session_list_vbox = VBoxContainer.new()
	_session_list_vbox.add_theme_constant_override("separation", 8)
	_session_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_session_list_vbox)

	# Manual ID entry row.
	var manual_hbox := HBoxContainer.new()
	manual_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	manual_hbox.add_theme_constant_override("separation", 10)
	outer_vbox.add_child(manual_hbox)

	var manual_lbl := Label.new()
	manual_lbl.text = "Enter ID:"
	manual_lbl.add_theme_font_size_override("font_size", 16)
	manual_hbox.add_child(manual_lbl)

	_manual_id_field = LineEdit.new()
	_manual_id_field.placeholder_text = "e.g. K7X2MQ"
	_manual_id_field.custom_minimum_size = Vector2(140, 38)
	_manual_id_field.max_length = 6
	_manual_id_field.add_theme_font_size_override("font_size", 18)
	manual_hbox.add_child(_manual_id_field)

	var manual_join_btn := Button.new()
	manual_join_btn.text = "JOIN"
	manual_join_btn.custom_minimum_size = Vector2(80, 38)
	manual_join_btn.pressed.connect(_on_manual_join_pressed)
	manual_hbox.add_child(manual_join_btn)

	# Back button.
	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(160, 46)
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.pressed.connect(_on_back_pressed)
	outer_vbox.add_child(back_btn)

	# Character select overlay (hidden until JOIN is pressed).
	_char_select_panel = _build_char_select_panel(root)
	_char_select_panel.hide()

	# WebRTC events.
	WebRTCManager.connection_failed.connect(_on_connection_failed)
	# Show live signaling steps in the status label while waiting to connect.
	WebRTCManager.debug_status.connect(func(msg: String) -> void:
		if _waiting:
			_status_label.text = msg)

	# Start polling immediately.
	_refresh_sessions()


func _process(delta: float) -> void:
	if _waiting:
		return
	_poll_timer += delta
	if _poll_timer >= POLL_INTERVAL:
		_poll_timer = 0.0
		_refresh_sessions()


# ── Session list ───────────────────────────────────────────────────────────────

func _refresh_sessions() -> void:
	FirebaseClient.get_sessions(_on_sessions_received)


func _on_sessions_received(_code: int, data: Variant) -> void:
	# Clear old rows.
	for child in _session_list_vbox.get_children():
		child.queue_free()

	if data == null or not (data is Dictionary) or data.is_empty():
		_status_label.text = "No active sessions. Be the first — press PLAY!"
		return

	var visible_count: int = 0
	var now: int = int(Time.get_unix_time_from_system())
	for session_id in data:
		var session: Variant = data[session_id]
		if not (session is Dictionary):
			continue
		if session.get("is_private", false):
			continue
		if session.get("status", "waiting") == "in_game":
			continue

		# Stale session: host hasn't sent a heartbeat in over 30 seconds.
		# Use last_seen if present, fall back to created_at for old sessions.
		var last_seen: int = int(session.get("last_seen", session.get("created_at", now)))
		if now - last_seen > 30:
			FirebaseClient.delete_session(session_id, func(_c, _d): pass)
			continue

		var players: Variant = session.get("players", {})
		var taken: Array[String] = GameManager.parse_taken_characters(players)
		# Session is full when all character slots are taken.
		if taken.size() >= CHARACTER_KEYS.size():
			continue

		_add_session_row(session_id, taken, session.get("elapsed_seconds", 0))
		visible_count += 1

	_status_label.text = (
		"%d session(s) available  •  refreshes every %.0fs" % [visible_count, POLL_INTERVAL]
		if visible_count > 0
		else "No open sessions. Check back soon or press PLAY to create one!"
	)


func _add_session_row(session_id: String, taken_chars: Array[String], elapsed: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Character portrait dots (filled = taken, hollow = open).
	for key in CHARACTER_KEYS:
		var idx: int = CHARACTER_KEYS.find(key)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(24, 24)
		dot.color = CHARACTER_COLORS[idx] if key in taken_chars else Color(0.3, 0.3, 0.3)
		dot.tooltip_text = (CHARACTER_LABELS[idx] + (" (taken)" if key in taken_chars else " (open)"))
		row.add_child(dot)

	# Session ID.
	var id_lbl := Label.new()
	id_lbl.text = session_id
	id_lbl.add_theme_font_size_override("font_size", 18)
	id_lbl.modulate = Color(1.0, 0.85, 0.2)
	id_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(id_lbl)

	# Elapsed time.
	var m: int = elapsed / 60
	var s: int = elapsed % 60
	var time_lbl := Label.new()
	time_lbl.text = "%d:%02d" % [m, s]
	time_lbl.add_theme_font_size_override("font_size", 16)
	row.add_child(time_lbl)

	# JOIN button.
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.custom_minimum_size = Vector2(80, 36)
	join_btn.pressed.connect(_on_join_row_pressed.bind(session_id, taken_chars))
	row.add_child(join_btn)

	_session_list_vbox.add_child(row)


# ── Character select overlay ───────────────────────────────────────────────────

func _build_char_select_panel(root: Control) -> Control:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "SELECT YOUR KNIGHT"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	vbox.add_child(lbl)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	vbox.add_child(hbox)

	for i in CHARACTER_KEYS.size():
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(110, 130)
		btn.text = CHARACTER_LABELS[i]
		btn.self_modulate = CHARACTER_COLORS[i]
		btn.name = "CharBtn_%d" % i
		btn.pressed.connect(_on_join_character_selected.bind(CHARACTER_KEYS[i]))
		hbox.add_child(btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(160, 44)
	cancel_btn.pressed.connect(func() -> void: _char_select_panel.hide())
	vbox.add_child(cancel_btn)

	root.add_child(panel)
	return panel


func _on_join_row_pressed(session_id: String, taken_chars: Array[String]) -> void:
	_joining_session_id = session_id
	_char_select_taken = taken_chars
	_update_char_select_buttons()
	_char_select_panel.show()


func _update_char_select_buttons() -> void:
	# Find the HBoxContainer inside the panel and update button states.
	var hbox: Node = _char_select_panel.get_node_or_null("CenterContainer/VBoxContainer/HBoxContainer")
	if hbox == null:
		return
	for i in CHARACTER_KEYS.size():
		var btn: Button = hbox.get_node_or_null("CharBtn_%d" % i) as Button
		if btn == null:
			continue
		var taken: bool = CHARACTER_KEYS[i] in _char_select_taken
		btn.disabled = taken
		btn.modulate = Color(0.5, 0.5, 0.5, 0.6) if taken else Color(1, 1, 1, 1.0)
		btn.tooltip_text = "Taken" if taken else ""


func _on_join_character_selected(character_key: String) -> void:
	_char_select_panel.hide()
	_waiting = true
	_status_label.text = "Connecting to session %s..." % _joining_session_id

	# Write our character claim to Firebase before initiating WebRTC.
	# peer_id 2 is always the joiner in a 2-player session.
	# PUT to the specific sub-path so we don't clobber the host's player entry.
	FirebaseClient.put_subpath(
		"/sessions/%s/players/2.json" % _joining_session_id,
		{"character": character_key},
		func(_code: int, _data: Variant) -> void:
			GameManager.begin_joining(_joining_session_id, character_key)
	)


func _on_manual_join_pressed() -> void:
	var id: String = _manual_id_field.text.strip_edges().to_upper()
	if id.length() != 6:
		_status_label.text = "Session ID must be exactly 6 characters."
		return
	# Fetch the session to find out who's in it.
	FirebaseClient.get_sessions(func(_code: int, data: Variant) -> void:
		if data == null or not data.has(id):
			_status_label.text = "Session '%s' not found or is private." % id
			return
		var session: Variant = data[id]
		var taken: Array[String] = GameManager.parse_taken_characters(session.get("players", {}))
		_on_join_row_pressed(id, taken)
	)


# ── Events ─────────────────────────────────────────────────────────────────────

func _on_connection_failed(reason: String) -> void:
	_waiting = false
	_status_label.text = "Connection failed: %s" % reason
	_joining_session_id = ""


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/menus/main_menu.tscn")

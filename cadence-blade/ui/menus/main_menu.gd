# main_menu.gd
# Programmatic main menu. All child nodes are built in _ready() from code
# so the .tscn file stays minimal and needs no visual editor work.
#
# Buttons:
#   PLAY  → session_create.tscn  (character select + create session)
#   JOIN  → session_join.tscn    (browse and join active sessions)
#   HELP  → shows a simple instructions overlay

extends CanvasLayer

var _help_panel: Control = null


func _ready() -> void:
	# Full-viewport container.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Dark semi-transparent background.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.1, 1.0)
	root.add_child(bg)

	# Centred column layout.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)

	# Title label.
	var title := Label.new()
	title.text = "CADENCE BLADE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	vbox.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(spacer)

	# Buttons.
	_add_menu_button(vbox, "PLAY", _on_play_pressed)
	_add_menu_button(vbox, "JOIN", _on_join_pressed)
	_add_menu_button(vbox, "HELP", _on_help_pressed)

	# Best time display.
	var best_label := Label.new()
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_label.add_theme_font_size_override("font_size", 14)
	if GameManager.best_time > 0.0:
		var m: int = int(GameManager.best_time) / 60
		var s: int = int(GameManager.best_time) % 60
		best_label.text = "Best: %d:%02d" % [m, s]
	vbox.add_child(best_label)

	# Help overlay (hidden by default).
	_help_panel = _build_help_panel(root)
	_help_panel.hide()


func _add_menu_button(parent: Control, label_text: String, callback: Callable) -> void:
	var btn := Button.new()
	btn.text = label_text
	btn.custom_minimum_size = Vector2(220, 52)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(callback)
	parent.add_child(btn)


func _build_help_panel(root: Control) -> Control:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	center.add_child(vbox)

	var help_text := Label.new()
	help_text.text = (
		"CADENCE BLADE\n\n"
		+ "Move:    WASD  (or on-screen joystick)\n"
		+ "Slash:   J\n"
		+ "Thrust:  K  (Red Knight only)\n"
		+ "Spin:    L  (Red Knight only)\n"
		+ "Shoot:   J  (Green Archer)\n"
		+ "Face lock: Shift\n\n"
		+ "Defend the castle from waves of enemies.\n"
		+ "Pick up coins and visit the blacksmith inside\n"
		+ "the castle to buy upgrades.\n\n"
		+ "MULTIPLAYER:\n"
		+ "PLAY — create a session and share the ID.\n"
		+ "JOIN — browse active sessions to jump into."
	)
	help_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_text.add_theme_font_size_override("font_size", 16)
	vbox.add_child(help_text)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(160, 44)
	close_btn.pressed.connect(func() -> void: panel.hide())
	vbox.add_child(close_btn)

	root.add_child(panel)
	return panel


# ── Button handlers ────────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/menus/session_create.tscn")


func _on_join_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/menus/session_join.tscn")


func _on_help_pressed() -> void:
	_help_panel.show()

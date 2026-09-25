@tool
extends Control

# spawn_designer.gd — In-editor visual editor for a SpawnScheduleConfig.
#
# HOW TO USE
#   1. Open tools/spawn_designer.tscn in the editor (it runs live as a @tool).
#   2. In the Inspector, drag a SpawnScheduleConfig .tres onto `schedule`
#      (e.g. res://level/schedules/level1_spawn_schedule.tres).
#   3. Edit on the graph; press Save to write the .tres back to disk.
#
# TABS
#   • Spawn Tickets — each variant's pool_tickets_curve, one line per variant.
#     Guaranteed-spawn minutes are the diamonds in the strip below the graph.
#   • Alive Caps    — each variant's max_alive_curve.
#   • Global        — spawn interval (seconds) + max total alive, dual Y axis.
# Night periods are shaded bands on every tab and are edited both on the graph
# (drag body / right edge) and in the Nights list.
#
# This tool mutates the Curve / NightPeriod sub-resources of `schedule` in place.
# Nothing is written until you press Save. "Reload from disk" discards edits.

const GraphScript := preload("res://tools/spawn_graph.gd")

@export var schedule: SpawnScheduleConfig:
	set(value):
		if schedule == value:
			return
		schedule = value
		_dirty = false
		if _built:
			_apply_domains()
			_rebuild()

# ── UI refs ──────────────────────────────────────────────────────────────────
var _built := false
var _dirty := false
var _mode := "tickets"
var _solo := ""

var _graph: Control
var _legend_box: VBoxContainer
var _nights_box: VBoxContainer
var _warnings: RichTextLabel
var _readout: Label
var _dirty_label: Label
var _tab_buttons: Dictionary = {}
var _run_spin: SpinBox

# Cached model for the active tab so the legend/readout can reference it.
var _series: Array = []
var _scrub_min := 0.0

# Type hue table (Warrior, Archer, Spearman, SheepDog, Dragon, Elite/other).
const _TYPE_HUES := [0.98, 0.34, 0.58, 0.13, 0.79, 0.07]


func _ready() -> void:
	if _built:
		return
	_build_ui()
	_built = true
	_apply_domains()
	_rebuild()


# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Bump every built-in control's font ~2x (the graph has its own FS constant).
	var t := Theme.new()
	t.default_font_size = 22
	theme = t
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# Top bar.
	var top := HBoxContainer.new()
	root.add_child(top)
	top.add_child(_label("Run length"))
	_run_spin = SpinBox.new()
	_run_spin.min_value = 1
	_run_spin.max_value = 60
	_run_spin.step = 0.5
	_run_spin.value = 20
	_run_spin.value_changed.connect(_on_run_length_changed)
	top.add_child(_run_spin)
	top.add_child(_label("min"))
	top.add_child(_spacer())
	for m in [["tickets", "Spawn Tickets"], ["caps", "Alive Caps"], ["global", "Global"]]:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.pressed.connect(_switch_mode.bind(m[0]))
		top.add_child(b)
		_tab_buttons[m[0]] = b
	top.add_child(_spacer())
	_dirty_label = _label("")
	_dirty_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	top.add_child(_dirty_label)
	var save_b := Button.new()
	save_b.text = "Save"
	save_b.pressed.connect(_save)
	top.add_child(save_b)
	var reload_b := Button.new()
	reload_b.text = "Reload from disk"
	reload_b.pressed.connect(_reload)
	top.add_child(reload_b)

	# Body split.
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = -400
	root.add_child(split)

	_graph = GraphScript.new()
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.data_changed.connect(_on_graph_changed)
	_graph.series_picked.connect(_on_series_picked)
	_graph.hovered_minute.connect(_on_hovered_minute)
	split.add_child(_graph)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(390, 0)
	side.add_theme_constant_override("separation", 3)
	split.add_child(side)

	side.add_child(_header("Layers"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 240)
	side.add_child(scroll)
	_legend_box = VBoxContainer.new()
	_legend_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_legend_box)

	side.add_child(HSeparator.new())
	side.add_child(_header("Nights"))
	_nights_box = VBoxContainer.new()
	side.add_child(_nights_box)
	var add_night := Button.new()
	add_night.text = "+ Night"
	add_night.pressed.connect(_add_night)
	side.add_child(add_night)

	side.add_child(HSeparator.new())
	side.add_child(_header("Warnings"))
	_warnings = RichTextLabel.new()
	_warnings.bbcode_enabled = true
	_warnings.fit_content = true
	_warnings.custom_minimum_size = Vector2(0, 140)
	_warnings.scroll_active = true
	side.add_child(_warnings)

	_readout = _label("")
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_readout)


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _header(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color(0.6, 0.75, 1.0))
	return l


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


# ── Model build ──────────────────────────────────────────────────────────────

func _rebuild() -> void:
	if not _built:
		return
	for id in _tab_buttons:
		_tab_buttons[id].button_pressed = id == _mode

	if schedule == null:
		_series = []
		_graph.set_model(_mode, [], [], [], 20.0, 10.0, 0.0)
		_readout.text = "Assign a SpawnScheduleConfig to `schedule` in the Inspector."
		_clear(_legend_box)
		_clear(_nights_box)
		_warnings.text = ""
		return

	_run_spin.set_value_no_signal(schedule.run_length_minutes)
	var run_len: float = schedule.run_length_minutes

	match _mode:
		"tickets": _series = _build_variant_series(true)
		"caps": _series = _build_variant_series(false)
		"global": _series = _build_global_series()

	# Visibility from solo.
	for s in _series:
		s["visible"] = _solo == "" or s["id"] == _solo

	var y_left := 10.0
	var y_right := 0.0
	if _mode == "global":
		y_left = _y_max([schedule.max_total_curve, schedule.solo_max_total_curve])
		y_right = _y_max([schedule.spawn_rate_curve])
	else:
		var curves: Array = []
		for s in _series:
			if s["curve"] != null:
				curves.append(s["curve"])
		y_left = _y_max(curves)

	var guaranteed := _build_guaranteed() if _mode == "tickets" else []
	_graph.set_model(_mode, _series, schedule.night_periods, guaranteed, run_len, y_left, y_right)
	_graph.set_selected_series(_solo)

	_rebuild_legend()
	_rebuild_nights()
	_recompute_warnings()
	_update_readout()


func _build_variant_series(tickets: bool) -> Array:
	var out: Array = []
	for ti in schedule.enemy_types.size():
		var t: EnemyTypeConfig = schedule.enemy_types[ti]
		if t == null:
			continue
		for vi in t.variants.size():
			var v: EnemyVariantConfig = t.variants[vi]
			if v == null:
				continue
			out.append({
				"id": "%d/%d" % [ti, vi],
				"label": "%s / %s" % [t.type_name, v.display_name],
				"color": _variant_color(ti, vi),
				"curve": v.pool_tickets_curve if tickets else v.max_alive_curve,
				"visible": true, "axis": 0, "y_is_int": true,
				"ti": ti, "vi": vi, "tickets": tickets,
			})
	return out


func _build_global_series() -> Array:
	return [
		{"id": "max_total", "label": "Max total alive", "color": Color(0.95, 0.6, 0.25),
			"curve": schedule.max_total_curve, "visible": true, "axis": 0, "y_is_int": true},
		{"id": "solo_max_total", "label": "Max total alive (solo)", "color": Color(0.95, 0.85, 0.35),
			"curve": schedule.solo_max_total_curve, "visible": true, "axis": 0, "y_is_int": true,
			"global_solo": true},
		{"id": "spawn_rate", "label": "Spawn interval (s)", "color": Color(0.3, 0.8, 0.95),
			"curve": schedule.spawn_rate_curve, "visible": true, "axis": 1, "y_is_int": false},
	]


func _build_guaranteed() -> Array:
	var out: Array = []
	for ti in schedule.enemy_types.size():
		var t: EnemyTypeConfig = schedule.enemy_types[ti]
		if t == null:
			continue
		for vi in t.variants.size():
			var v: EnemyVariantConfig = t.variants[vi]
			if v == null:
				continue
			out.append({
				"series_id": "%d/%d" % [ti, vi],
				"color": _variant_color(ti, vi),
				"arr": v.guaranteed_spawn_minutes,
			})
	return out


func _variant_color(ti: int, vi: int) -> Color:
	var hue: float = _TYPE_HUES[ti % _TYPE_HUES.size()]
	if vi == 0:
		return Color.from_hsv(hue, 0.55, 0.72)
	return Color.from_hsv(hue, 0.90, 1.0)


func _y_max(curves: Array) -> float:
	var m := 1.0
	for c in curves:
		if c == null:
			continue
		for i in c.point_count:
			m = maxf(m, c.get_point_position(i).y)
		# also catch overshoot from tangents
		for k in 21:
			m = maxf(m, c.sample(schedule.run_length_minutes * k / 20.0))
	return ceil(m * 1.12)


# ── Legend ───────────────────────────────────────────────────────────────────

func _rebuild_legend() -> void:
	_clear(_legend_box)
	for s in _series:
		var row := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = s["color"]
		sw.custom_minimum_size = Vector2(20, 20)
		row.add_child(sw)

		var cb := CheckBox.new()
		cb.text = s["label"]
		cb.button_pressed = s["visible"]
		cb.toggled.connect(func(on):
			s["visible"] = on
			_graph.queue_redraw())
		row.add_child(cb)
		row.add_child(_spacer())

		if s["curve"] == null:
			var mk := Button.new()
			mk.text = "+ curve"
			mk.tooltip_text = "Create a curve for this variant"
			mk.pressed.connect(_make_curve_for.bind(s))
			row.add_child(mk)
		else:
			var solo := Button.new()
			solo.text = "S"
			solo.toggle_mode = true
			solo.button_pressed = _solo == s["id"]
			solo.tooltip_text = "Solo this layer"
			solo.pressed.connect(func():
				_solo = "" if _solo == s["id"] else s["id"]
				_rebuild())
			row.add_child(solo)
		_legend_box.add_child(row)


func _make_curve_for(s: Dictionary) -> void:
	# The solo max-total line seeds from a copy of the multiplayer max-total curve
	# (or a gentle default) so you're editing a real starting shape, not a stub.
	if s.get("global_solo", false):
		var src := schedule.max_total_curve
		schedule.solo_max_total_curve = src.duplicate(true) if src != null else _default_curve(8.0, 4.0)
		_mark_dirty()
		_rebuild()
		return

	var c := _default_curve(5.0, 2.0)
	var v: EnemyVariantConfig = schedule.enemy_types[s["ti"]].variants[s["vi"]]
	if s.get("tickets", true):
		v.pool_tickets_curve = c
	else:
		v.max_alive_curve = c
	_mark_dirty()
	_rebuild()


func _default_curve(y_max: float, end_y: float) -> Curve:
	var c := Curve.new()
	c.min_domain = 0.0
	c.max_domain = schedule.run_length_minutes
	c.max_value = y_max
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(schedule.run_length_minutes, end_y))
	for i in c.point_count:
		c.set_point_left_mode(i, Curve.TANGENT_LINEAR)
		c.set_point_right_mode(i, Curve.TANGENT_LINEAR)
	return c


# ── Nights list ──────────────────────────────────────────────────────────────

func _rebuild_nights() -> void:
	_clear(_nights_box)
	for i in schedule.night_periods.size():
		var p: Resource = schedule.night_periods[i]
		if p == null:
			continue
		var row := HBoxContainer.new()
		var st := SpinBox.new()
		st.prefix = "@"
		st.min_value = 0
		st.max_value = 120
		st.step = 0.25
		st.value = float(p.get("start_minute"))
		st.tooltip_text = "Start minute"
		st.value_changed.connect(func(val):
			p.set("start_minute", val)
			_after_night_edit())
		row.add_child(st)
		var du := SpinBox.new()
		du.suffix = "s"
		du.min_value = 1
		du.max_value = 600
		du.step = 1
		du.value = float(p.get("duration_seconds"))
		du.tooltip_text = "Duration (seconds)"
		du.value_changed.connect(func(val):
			p.set("duration_seconds", val)
			_after_night_edit())
		row.add_child(du)
		var x := Button.new()
		x.text = "✕"
		x.pressed.connect(func():
			schedule.night_periods.remove_at(i)
			_mark_dirty()
			_rebuild())
		row.add_child(x)
		_nights_box.add_child(row)


func _add_night() -> void:
	var n := NightPeriod.new()
	var last_end := 1.0
	for p in schedule.night_periods:
		if p != null:
			last_end = maxf(last_end, float(p.get("start_minute")) + float(p.get("duration_seconds")) / 60.0)
	n.start_minute = minf(last_end + 1.0, schedule.run_length_minutes - 0.5)
	n.duration_seconds = 8.0
	schedule.night_periods.append(n)
	_mark_dirty()
	_rebuild()


func _after_night_edit() -> void:
	_mark_dirty()
	_graph.queue_redraw()
	_recompute_warnings()


# ── Signals from the graph ───────────────────────────────────────────────────

func _on_graph_changed() -> void:
	_mark_dirty()
	_recompute_warnings()
	_update_readout()
	# Night spinboxes may be stale after a band drag.
	_sync_night_spinboxes()


func _on_series_picked(sid: String) -> void:
	_update_readout()


func _on_hovered_minute(m: float) -> void:
	_scrub_min = m
	_update_readout()


func _sync_night_spinboxes() -> void:
	var i := 0
	for row in _nights_box.get_children():
		if i >= schedule.night_periods.size():
			break
		var p: Resource = schedule.night_periods[i]
		var spins := row.get_children().filter(func(c): return c is SpinBox)
		if spins.size() >= 2 and p != null:
			spins[0].set_value_no_signal(float(p.get("start_minute")))
			spins[1].set_value_no_signal(float(p.get("duration_seconds")))
		i += 1


# ── Readout strip ────────────────────────────────────────────────────────────

func _update_readout() -> void:
	if schedule == null:
		return
	var parts: Array = []
	for s in _series:
		if not s.get("visible", true) or s["curve"] == null:
			continue
		parts.append("%s %s" % [s["label"].split("/")[-1].strip_edges(),
			_trim(s["curve"].sample(_scrub_min))])
	var night := ""
	for p in schedule.night_periods:
		if p == null:
			continue
		var st: float = float(p.get("start_minute"))
		if _scrub_min >= st and _scrub_min <= st + float(p.get("duration_seconds")) / 60.0:
			night = "  [NIGHT]"
	_readout.text = "@ %s%s   %s" % [_mmss(_scrub_min), night, "  ·  ".join(parts)]


# ── Warnings ─────────────────────────────────────────────────────────────────

func _recompute_warnings() -> void:
	if schedule == null:
		return
	var w: Array = []
	var run_len: float = schedule.run_length_minutes

	for ti in schedule.enemy_types.size():
		var t: EnemyTypeConfig = schedule.enemy_types[ti]
		if t == null:
			continue
		for v: EnemyVariantConfig in t.variants:
			if v == null:
				continue
			var nm := "%s / %s" % [t.type_name, v.display_name]
			var has_guar := not v.guaranteed_spawn_minutes.is_empty()
			var pc := v.pool_tickets_curve
			if pc == null:
				if not has_guar:
					w.append("%s has no pool curve and no guaranteed spawns — never spawns." % nm)
			else:
				var zero_all := true
				for k in 41:
					if pc.sample(run_len * k / 40.0) >= 0.5:
						zero_all = false
						break
				if zero_all and not has_guar:
					w.append("%s pool is 0 for the whole run and has no guaranteed spawns — never spawns." % nm)
				elif pc.point_count > 0:
					var last := pc.get_point_position(pc.point_count - 1)
					if last.x < run_len - 0.01 and pc.sample(run_len) < 0.5 and not has_guar:
						w.append("%s pool ends at 0 (%s) — stops appearing after that." % [nm, _mmss(last.x)])
			_check_points_past_end(w, nm + " pool", pc, run_len)
			_check_points_past_end(w, nm + " cap", v.max_alive_curve, run_len)
			for gm in v.guaranteed_spawn_minutes:
				if gm > run_len:
					w.append("%s guaranteed spawn at %s is past the run length." % [nm, _mmss(gm)])

	for pair in [["Global max-total", schedule.max_total_curve],
			["Solo max-total", schedule.solo_max_total_curve]]:
		var mt: Curve = pair[1]
		if mt == null:
			continue
		var lo := 999.0
		var lo_m := 0.0
		for k in 81:
			var mm := run_len * k / 80.0
			var s := mt.sample(mm)
			if s < lo:
				lo = s
				lo_m = mm
		if lo < 1.0:
			w.append("%s drops below 1 around %s — spawning stalls there." % [pair[0], _mmss(lo_m)])
	var sr := schedule.spawn_rate_curve
	if sr != null:
		for k in 81:
			if sr.sample(run_len * k / 80.0) > 12.0:
				w.append("Spawn interval spikes above 12 s around %s." % _mmss(run_len * k / 80.0))
				break

	var sorted_nights: Array = []
	for p in schedule.night_periods:
		if p != null:
			sorted_nights.append(p)
	sorted_nights.sort_custom(func(a, b): return float(a.get("start_minute")) < float(b.get("start_minute")))
	for i in sorted_nights.size():
		var p: Resource = sorted_nights[i]
		var st: float = float(p.get("start_minute"))
		var en: float = st + float(p.get("duration_seconds")) / 60.0
		if st >= run_len:
			w.append("Night at %s never triggers (after run end)." % _mmss(st))
		elif en > run_len + 0.01:
			w.append("Night at %s runs past the end of the run." % _mmss(st))
		if i + 1 < sorted_nights.size():
			var nx: float = float(sorted_nights[i + 1].get("start_minute"))
			if nx < en - 0.01:
				w.append("Nights at %s and %s overlap." % [_mmss(st), _mmss(nx)])

	if w.is_empty():
		_warnings.text = "[color=#7bd88f]No issues.[/color]"
	else:
		_warnings.text = "[color=#ffb347]" + "\n".join(w.map(func(x): return "• " + x)) + "[/color]"


func _check_points_past_end(w: Array, name: String, c: Curve, run_len: float) -> void:
	if c == null:
		return
	for i in c.point_count:
		if c.get_point_position(i).x > run_len + 0.01:
			w.append("%s has a point at %s, past the run length." % [name, _mmss(c.get_point_position(i).x)])
			return


# ── Actions ──────────────────────────────────────────────────────────────────

func _switch_mode(m: String) -> void:
	_mode = m
	_rebuild()


func _on_run_length_changed(v: float) -> void:
	if schedule == null:
		return
	schedule.run_length_minutes = v
	_apply_domains()
	_mark_dirty()
	_rebuild()


func _apply_domains() -> void:
	if schedule == null:
		return
	var rl: float = schedule.run_length_minutes
	for c in [schedule.spawn_rate_curve, schedule.max_total_curve, schedule.solo_max_total_curve]:
		if c != null:
			c.min_domain = 0.0
			c.max_domain = rl
	for t in schedule.enemy_types:
		if t == null:
			continue
		for v in t.variants:
			if v == null:
				continue
			for c in [v.pool_tickets_curve, v.max_alive_curve]:
				if c != null:
					c.min_domain = 0.0
					c.max_domain = rl


func _save() -> void:
	if schedule == null or schedule.resource_path.is_empty():
		_flash_dirty("no .tres path — assign a saved resource")
		return
	_apply_domains()
	var err := ResourceSaver.save(schedule, schedule.resource_path)
	if err == OK:
		_dirty = false
		_dirty_label.text = "saved ✓"
	else:
		_dirty_label.text = "SAVE FAILED (%s)" % error_string(err)


func _reload() -> void:
	if schedule == null or schedule.resource_path.is_empty():
		return
	var p := schedule.resource_path
	var fresh: Resource = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
	schedule = fresh
	_dirty = false
	_dirty_label.text = ""
	_apply_domains()
	_rebuild()


func _mark_dirty() -> void:
	_dirty = true
	_dirty_label.text = "● unsaved"


func _flash_dirty(msg: String) -> void:
	_dirty_label.text = msg


# ── Small helpers ────────────────────────────────────────────────────────────

func _clear(node: Node) -> void:
	for c in node.get_children():
		c.queue_free()


func _mmss(minutes: float) -> String:
	var total := int(round(minutes * 60.0))
	return "%d:%02d" % [total / 60, total % 60]


func _trim(v) -> String:
	var f := float(v)
	return str(int(round(f))) if is_equal_approx(f, round(f)) else "%.2f" % f

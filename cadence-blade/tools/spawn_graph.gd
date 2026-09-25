@tool
extends Control

# spawn_graph.gd — The drawable/editable graph area of the Spawn Designer.
#
# Owns NO data of its own: spawn_designer.gd calls set_model() with a list of
# "series" (each wrapping one real Curve sub-resource of the schedule), the
# shared night_periods, and — on the tickets tab — the guaranteed-spawn minute
# arrays. Every edit here mutates those resources in place and emits
# `data_changed`; the parent handles the dirty flag, warnings and saving.
#
# Interaction:
#   • drag a point           → move it (snapped: X to 15 s, Y to int on int axes;
#                               hold Shift to disable snap)
#   • click a line            → select that layer   • double-click a line → insert a point
#   • right-click / Delete     → remove the selected point (a curve keeps ≥1)
#   • drag a night band body   → move its start; drag its right edge → its length
#   • drag a guaranteed ◆      → move that spawn time; double-click the strip with a
#                                layer selected → add one; right-click ◆ → delete
#   • mouse wheel              → zoom about the cursor      • Shift+wheel → zoom X only
#   • hold middle mouse + drag → pan            • double middle-click → reset view
#   • hover a line             → tooltip with its identity + value under the cursor
#   • the vertical scrubber follows the cursor; the parent shows per-series values

signal data_changed
signal series_picked(series_id: String)
signal hovered_minute(minute: float)

const FS := 20               # drawn-text font size (axis labels, tooltips, …)
const M_LEFT := 74.0
const M_RIGHT := 78.0
const M_TOP := 20.0
const M_BOT := 52.0          # x-axis labels
const HIT_PX := 12.0
const EDGE_PX := 8.0
const GUAR_STRIP := 36.0     # px height of the guaranteed-marker strip (tickets)
const ZOOM_STEP := 0.85

# ── Model (set by parent) ─────────────────────────────────────────────────────
var mode: String = "tickets"                # "tickets" | "caps" | "global"
var run_length: float = 20.0
var y_max_left: float = 10.0
var y_max_right: float = 0.0                 # 0 → single axis; >0 → dual (global)
## series entry: { id, label, color, curve:Curve, visible:bool, axis:int, y_is_int:bool }
var series: Array = []
var nights: Array = []                       # NightPeriod resources (shared)
## guaranteed entry: { series_id, color, arr:Array[float] }  (arr is a live ref)
var guaranteed: Array = []
var selected_series_id: String = ""

# ── View (data-space window; y is in LEFT-axis units) ────────────────────────
var _view: Rect2 = Rect2(0, 0, 20, 11)

# ── Interaction state ────────────────────────────────────────────────────────
var _sel_point: Vector2i = Vector2i(-1, -1)  # (series index, point index)
var _drag: Dictionary = {}
var _pan: Dictionary = {}
var _hover_series: String = ""
var _hover_text: String = ""
var _mouse_pos: Vector2 = Vector2.ZERO
var _scrub_min: float = -1.0

var _font: Font
var _font_size := FS


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(480, 300)
	_font = ThemeDB.fallback_font


func set_model(p_mode: String, p_series: Array, p_nights: Array, p_guaranteed: Array,
		p_run_length: float, p_y_left: float, p_y_right: float) -> void:
	var mode_changed := p_mode != mode
	mode = p_mode
	series = p_series
	nights = p_nights
	guaranteed = p_guaranteed
	run_length = maxf(1.0, p_run_length)
	y_max_left = maxf(1.0, p_y_left)
	y_max_right = p_y_right
	_sel_point = Vector2i(-1, -1)
	_drag = {}
	_pan = {}
	if mode_changed or not _view_is_sane():
		_reset_view()
	queue_redraw()


func set_selected_series(id: String) -> void:
	selected_series_id = id
	queue_redraw()


func reset_view() -> void:
	_reset_view()
	queue_redraw()


func _reset_view() -> void:
	_view = Rect2(0.0, -0.05 * y_max_left, run_length, 1.12 * y_max_left)


func _view_is_sane() -> bool:
	return _view.size.x > 0.0 and _view.size.y > 0.0 \
		and _view.position.x < run_length and _view.end.x > 0.0


# ── Coordinate transforms ────────────────────────────────────────────────────

func _plot_rect() -> Rect2:
	var bot := M_BOT + (GUAR_STRIP if mode == "tickets" else 0.0)
	return Rect2(M_LEFT, M_TOP, maxf(10.0, size.x - M_LEFT - M_RIGHT),
			maxf(10.0, size.y - M_TOP - bot))


## Right-axis value → equivalent left-axis value (so one _view covers both).
func _to_left_units(value: float, axis: int) -> float:
	if axis == 1 and y_max_right > 0.0:
		return value / y_max_right * y_max_left
	return value


func _from_left_units(eq: float, axis: int) -> float:
	if axis == 1 and y_max_right > 0.0:
		return eq / y_max_left * y_max_right
	return eq


func _to_px(minute: float, value: float, axis := 0) -> Vector2:
	var r := _plot_rect()
	var eq := _to_left_units(value, axis)
	var x := r.position.x + (minute - _view.position.x) / _view.size.x * r.size.x
	var y := r.position.y + r.size.y - (eq - _view.position.y) / _view.size.y * r.size.y
	return Vector2(x, y)


func _minute_at(px_x: float) -> float:
	var r := _plot_rect()
	return _view.position.x + (px_x - r.position.x) / r.size.x * _view.size.x


func _value_at(px_y: float, axis := 0) -> float:
	var r := _plot_rect()
	var eq := _view.position.y + (r.position.y + r.size.y - px_y) / r.size.y * _view.size.y
	return maxf(0.0, _from_left_units(eq, axis))


# ── Sampling helpers ─────────────────────────────────────────────────────────

func _sample_polyline(curve: Curve, axis: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if curve == null:
		return pts
	var x0: float = maxf(0.0, _view.position.x)
	var x1: float = minf(run_length, _view.end.x)
	if x1 <= x0:
		x0 = 0.0
		x1 = run_length
	var steps := 160
	# Flat lead-in / lead-out so the visible line matches Curve.sample beyond the ends.
	pts.append(_to_px(_view.position.x, curve.sample(x0), axis))
	for i in steps + 1:
		var m: float = x0 + (x1 - x0) * float(i) / float(steps)
		pts.append(_to_px(m, curve.sample(m), axis))
	pts.append(_to_px(_view.end.x, curve.sample(x1), axis))
	return pts


# ── Drawing ──────────────────────────────────────────────────────────────────

func _draw() -> void:
	var r := _plot_rect()
	draw_rect(r, Color(0.10, 0.11, 0.13), true)

	_draw_grid(r)
	_draw_nights(r)

	var order: Array = []
	for si in series.size():
		order.append(si)
	order.sort_custom(func(a, b): return _line_priority(a) < _line_priority(b))
	for si in order:
		_draw_series(si, r)

	if mode == "tickets":
		_draw_guaranteed(r)

	_draw_scrubber(r)
	_draw_axes(r)
	_draw_tooltip()


func _line_priority(si: int) -> int:
	var s: Dictionary = series[si]
	if not s.get("visible", true):
		return -1
	if s["id"] == _hover_series:
		return 3
	if s["id"] == selected_series_id:
		return 2
	return 1


## "Nice" 1 / 2 / 5 · 10ⁿ step covering `span` in about `target` divisions.
func _nice_step(span: float, target: int) -> float:
	var raw: float = span / float(maxi(1, target))
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var n: float = raw / mag
	if n >= 5.0:
		return 5.0 * mag
	if n >= 2.0:
		return 2.0 * mag
	return maxf(mag, 0.0001)


func _draw_grid(r: Rect2) -> void:
	var minor := Color(1, 1, 1, 0.05)
	var axis_c := Color(1, 1, 1, 0.16)
	var xs := _nice_step(_view.size.x, 10)
	var x: float = ceilf(_view.position.x / xs) * xs
	while x < _view.end.x:
		var px := _to_px(x, 0.0).x
		draw_line(Vector2(px, r.position.y), Vector2(px, r.position.y + r.size.y),
				axis_c if is_equal_approx(fmod(x, xs * 5.0), 0.0) else minor, 1.0)
		x += xs
	var ys := _nice_step(_view.size.y, 6)
	var yv: float = ceilf(_view.position.y / ys) * ys
	while yv < _view.end.y:
		var py := _to_px(0.0, yv).y
		draw_line(Vector2(r.position.x, py), Vector2(r.position.x + r.size.x, py), minor, 1.0)
		yv += ys


func _draw_nights(r: Rect2) -> void:
	for p in nights:
		if p == null:
			continue
		var start: float = float(p.get("start_minute"))
		var dur_min: float = float(p.get("duration_seconds")) / 60.0
		var x0: float = clampf(_to_px(start, 0.0).x, r.position.x, r.position.x + r.size.x)
		var x1: float = clampf(_to_px(start + dur_min, 0.0).x, r.position.x, r.position.x + r.size.x)
		if x1 <= x0 + 0.5 and (start + dur_min < _view.position.x or start > _view.end.x):
			continue
		draw_rect(Rect2(x0, r.position.y, maxf(1.0, x1 - x0), r.size.y),
				Color(0.30, 0.40, 0.75, 0.16), true)
		draw_line(Vector2(x1, r.position.y), Vector2(x1, r.position.y + r.size.y),
				Color(0.55, 0.65, 0.95, 0.5), 1.0)
		draw_string(_font, Vector2(x0 + 4, r.position.y + FS),
				"%s (%ss)" % [_fmt_mmss(start), _trim(p.get("duration_seconds"))],
				HORIZONTAL_ALIGNMENT_LEFT, -1, FS - 3, Color(0.75, 0.82, 1.0, 0.8))


func _draw_series(si: int, r: Rect2) -> void:
	var s: Dictionary = series[si]
	if not s.get("visible", true):
		return
	var curve: Curve = s["curve"]
	var col: Color = s["color"]
	var is_hi: bool = s["id"] == _hover_series or s["id"] == selected_series_id
	if _hover_series != "" and not is_hi:
		col = Color(col, 0.30)
	var width := 3.5 if is_hi else 2.0

	if curve == null:
		return

	var poly := _sample_polyline(curve, s.get("axis", 0))
	if poly.size() >= 2:
		draw_polyline(poly, col, width, true)

	for pi in curve.point_count:
		var pp := curve.get_point_position(pi)
		var px := _to_px(pp.x, pp.y, s.get("axis", 0))
		if px.x < r.position.x - 6 or px.x > r.position.x + r.size.x + 6:
			continue
		var selp := _sel_point == Vector2i(si, pi)
		draw_circle(px, 7.0 if selp else 5.0, col)
		if selp:
			draw_arc(px, 10.0, 0.0, TAU, 24, Color.WHITE, 2.0)


func _draw_guaranteed(r: Rect2) -> void:
	var strip_y := r.position.y + r.size.y + GUAR_STRIP * 0.55
	draw_line(Vector2(r.position.x, strip_y - GUAR_STRIP * 0.4),
			Vector2(r.position.x + r.size.x, strip_y - GUAR_STRIP * 0.4), Color(1, 1, 1, 0.12), 1.0)
	draw_string(_font, Vector2(4, strip_y + 5), "guar.", HORIZONTAL_ALIGNMENT_LEFT, -1,
			FS - 4, Color(1, 1, 1, 0.4))
	for g in guaranteed:
		var arr: Array = g["arr"]
		var col: Color = g["color"]
		var dim: bool = _hover_series != "" and g["series_id"] != _hover_series \
			and g["series_id"] != selected_series_id
		for idx in arr.size():
			var cx := _to_px(float(arr[idx]), 0.0).x
			if cx < r.position.x - 6 or cx > r.position.x + r.size.x + 6:
				continue
			var d := 7.0
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx, strip_y - d), Vector2(cx + d, strip_y),
				Vector2(cx, strip_y + d), Vector2(cx - d, strip_y)]),
				Color(col, 0.35 if dim else 1.0))


func _draw_scrubber(r: Rect2) -> void:
	if _scrub_min < _view.position.x or _scrub_min > _view.end.x:
		return
	var x := _to_px(_scrub_min, 0.0).x
	draw_line(Vector2(x, r.position.y), Vector2(x, r.position.y + r.size.y),
			Color(1, 1, 1, 0.35), 1.0)
	for s in series:
		if not s.get("visible", true) or s["curve"] == null:
			continue
		draw_circle(_to_px(_scrub_min, s["curve"].sample(clampf(_scrub_min, 0.0, run_length)),
				s.get("axis", 0)), 4.5, s["color"])


func _draw_axes(r: Rect2) -> void:
	var c := Color(1, 1, 1, 0.55)
	draw_rect(r, Color(1, 1, 1, 0.2), false, 1.0)

	var xs := _nice_step(_view.size.x, 10)
	var x: float = ceilf(_view.position.x / xs) * xs
	while x < _view.end.x:
		var px := _to_px(x, 0.0).x
		var lbl := _fmt_mmss(x) if xs < 1.0 else str(int(round(x)))
		draw_string(_font, Vector2(px - FS, r.position.y + r.size.y + FS + 2), lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FS, c)
		x += xs
	draw_string(_font, Vector2(r.position.x + r.size.x * 0.5 - FS, size.y - 4), "minutes",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FS - 3, Color(1, 1, 1, 0.4))

	var ys := _nice_step(_view.size.y, 6)
	var yv: float = ceilf(_view.position.y / ys) * ys
	while yv < _view.end.y:
		var py := _to_px(0.0, yv).y
		draw_string(_font, Vector2(4, py + FS * 0.35), _trim(yv), HORIZONTAL_ALIGNMENT_LEFT, -1,
				FS, c)
		if y_max_right > 0.0:
			draw_string(_font, Vector2(r.position.x + r.size.x + 6, py + FS * 0.35),
					_trim(_from_left_units(yv, 1)), HORIZONTAL_ALIGNMENT_LEFT, -1,
					FS, Color(1, 1, 1, 0.4))
		yv += ys


func _draw_tooltip() -> void:
	if _hover_text == "":
		return
	var pad := Vector2(9, 6)
	var ts := _font.get_string_size(_hover_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS)
	var box_pos := _mouse_pos + Vector2(12, -8)
	box_pos.x = minf(box_pos.x, size.x - ts.x - pad.x * 2 - 2)
	box_pos.y = maxf(box_pos.y, 2)
	draw_rect(Rect2(box_pos, ts + pad * 2), Color(0, 0, 0, 0.85), true)
	draw_rect(Rect2(box_pos, ts + pad * 2), Color(1, 1, 1, 0.2), false, 1.0)
	draw_string(_font, box_pos + Vector2(pad.x, pad.y + ts.y - 3), _hover_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FS, Color.WHITE)


# ── Input ────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom(ZOOM_STEP, event.position, event.shift_pressed)
				return
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom(1.0 / ZOOM_STEP, event.position, event.shift_pressed)
				return
			MOUSE_BUTTON_MIDDLE:
				if event.pressed and event.double_click:
					reset_view()
				elif event.pressed:
					_pan = {"mouse": event.position, "view_pos": _view.position}
				else:
					_pan = {}
				return
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_on_left_press(event)
				else:
					_drag = {}
				return
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_on_right_press(event.position)
				return
		return

	if event is InputEventMouseMotion:
		_mouse_pos = event.position
		if not _pan.is_empty():
			var r := _plot_rect()
			var d: Vector2 = event.position - _pan["mouse"]
			_view.position = _pan["view_pos"] - Vector2(
				d.x / r.size.x * _view.size.x, -d.y / r.size.y * _view.size.y)
			queue_redraw()
		elif not _drag.is_empty():
			_apply_drag(event.position, event.shift_pressed)
		else:
			_update_hover(event.position)
			_scrub_min = _minute_at(event.position.x)
			hovered_minute.emit(_scrub_min)
			queue_redraw()
		return

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_DELETE:
			_delete_selected_point()
		elif event.keycode == KEY_F:
			reset_view()


func _zoom(factor: float, at: Vector2, x_only: bool) -> void:
	var anchor := Vector2(_minute_at(at.x),
			_view.position.y + (_plot_rect().position.y + _plot_rect().size.y - at.y)
			/ _plot_rect().size.y * _view.size.y)
	var new_w: float = clampf(_view.size.x * factor, 0.4, run_length * 2.0)
	var new_h: float = _view.size.y if x_only else clampf(_view.size.y * factor, 1.0, y_max_left * 4.0)
	_view.position.x = anchor.x - (anchor.x - _view.position.x) * (new_w / _view.size.x)
	if not x_only:
		_view.position.y = anchor.y - (anchor.y - _view.position.y) * (new_h / _view.size.y)
	_view.size = Vector2(new_w, new_h)
	queue_redraw()


func _on_left_press(event: InputEventMouseButton) -> void:
	var pos: Vector2 = event.position

	var hit := _point_at(pos)
	if hit.x >= 0:
		_sel_point = hit
		selected_series_id = series[hit.x]["id"]
		series_picked.emit(selected_series_id)
		_drag = {"kind": "point", "si": hit.x, "pi": hit.y}
		queue_redraw()
		return

	var gh := _guaranteed_at(pos)
	if not gh.is_empty():
		_drag = {"kind": "guar", "g": gh["g"], "idx": gh["idx"]}
		return

	var nh := _night_at(pos)
	if not nh.is_empty():
		_drag = nh
		return

	var sid := _line_at(pos)
	if sid != "":
		if event.double_click:
			_insert_point(sid, pos)
		else:
			_sel_point = Vector2i(-1, -1)
			selected_series_id = sid
			series_picked.emit(sid)
			queue_redraw()
		return

	if event.double_click and mode == "tickets" and _in_guaranteed_strip(pos.y) \
			and selected_series_id != "":
		_add_guaranteed(selected_series_id, _minute_at(pos.x))
		return

	_sel_point = Vector2i(-1, -1)
	_scrub_min = _minute_at(pos.x)
	queue_redraw()


func _on_right_press(pos: Vector2) -> void:
	var gh := _guaranteed_at(pos)
	if not gh.is_empty():
		var arr: Array = gh["g"]["arr"]
		arr.remove_at(gh["idx"])
		data_changed.emit()
		queue_redraw()
		return
	var hit := _point_at(pos)
	if hit.x >= 0:
		_sel_point = hit
		_delete_selected_point()


# ── Drag application ─────────────────────────────────────────────────────────

func _apply_drag(pos: Vector2, no_snap: bool) -> void:
	match _drag.get("kind", ""):
		"point":
			var s: Dictionary = series[_drag["si"]]
			var curve: Curve = s["curve"]
			var m := _minute_at(pos.x)
			var v := _value_at(pos.y, s.get("axis", 0))
			if not no_snap:
				m = round(m / 0.25) * 0.25
				if s.get("y_is_int", false):
					v = round(v)
			m = clampf(m, 0.0, run_length)
			v = maxf(0.0, v)
			var new_i := curve.set_point_offset(_drag["pi"], m)
			curve.set_point_value(new_i, v)
			_drag["pi"] = new_i
			_sel_point = Vector2i(_drag["si"], new_i)
			_hover_text = "%s · %s @ %s" % [s["label"], _trim(v), _fmt_mmss(m)]
		"guar":
			var arr: Array = _drag["g"]["arr"]
			var mm := _minute_at(pos.x)
			if not no_snap:
				mm = round(mm / 0.25) * 0.25
			arr[_drag["idx"]] = clampf(mm, 0.0, run_length)
		"night_start":
			var p = _drag["p"]
			var span: float = float(p.get("duration_seconds")) / 60.0
			var ns: float = _minute_at(pos.x) - float(_drag["grab_off"])
			p.set("start_minute", clampf(ns, 0.0, maxf(0.0, run_length - span)))
		"night_dur":
			var pd = _drag["p"]
			var secs := (_minute_at(pos.x) - float(pd.get("start_minute"))) * 60.0
			pd.set("duration_seconds", clampf(secs, 1.0, 600.0))
	data_changed.emit()
	queue_redraw()


# ── Hit testing ──────────────────────────────────────────────────────────────

func _point_at(pos: Vector2) -> Vector2i:
	for si in range(series.size() - 1, -1, -1):
		var s: Dictionary = series[si]
		if not s.get("visible", true) or s["curve"] == null:
			continue
		var curve: Curve = s["curve"]
		for pi in curve.point_count:
			var pp := curve.get_point_position(pi)
			if _to_px(pp.x, pp.y, s.get("axis", 0)).distance_to(pos) <= HIT_PX:
				return Vector2i(si, pi)
	return Vector2i(-1, -1)


func _line_at(pos: Vector2) -> String:
	var best := ""
	var best_d := HIT_PX
	for s in series:
		if not s.get("visible", true) or s["curve"] == null:
			continue
		var poly := _sample_polyline(s["curve"], s.get("axis", 0))
		for i in poly.size() - 1:
			var d := _dist_to_seg(pos, poly[i], poly[i + 1])
			if d < best_d:
				best_d = d
				best = s["id"]
	return best


func _guaranteed_at(pos: Vector2) -> Dictionary:
	if mode != "tickets" or not _in_guaranteed_strip(pos.y):
		return {}
	var r := _plot_rect()
	var strip_y := r.position.y + r.size.y + GUAR_STRIP * 0.55
	for g in guaranteed:
		var arr: Array = g["arr"]
		for idx in arr.size():
			if Vector2(_to_px(float(arr[idx]), 0.0).x, strip_y).distance_to(pos) <= HIT_PX + 2.0:
				return {"g": g, "idx": idx}
	return {}


func _night_at(pos: Vector2) -> Dictionary:
	var r := _plot_rect()
	if pos.y < r.position.y or pos.y > r.position.y + r.size.y:
		return {}
	for p in nights:
		if p == null:
			continue
		var start: float = float(p.get("start_minute"))
		var x0 := _to_px(start, 0.0).x
		var x1 := _to_px(start + float(p.get("duration_seconds")) / 60.0, 0.0).x
		if absf(pos.x - x1) <= EDGE_PX:
			return {"kind": "night_dur", "p": p}
		if pos.x >= x0 and pos.x <= x1:
			return {"kind": "night_start", "p": p, "grab_off": _minute_at(pos.x) - start}
	return {}


func _in_guaranteed_strip(py: float) -> bool:
	var r := _plot_rect()
	return py >= r.position.y + r.size.y + 6.0 and py <= r.position.y + r.size.y + GUAR_STRIP + 18.0


func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() == 0.0 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# ── Hover ────────────────────────────────────────────────────────────────────

func _update_hover(pos: Vector2) -> void:
	var sid := _line_at(pos)
	_hover_series = sid
	if sid == "":
		_hover_text = ""
		return
	for s in series:
		if s["id"] == sid:
			var m: float = clampf(_minute_at(pos.x), 0.0, run_length)
			var v: float = s["curve"].sample(m) if s["curve"] != null else 0.0
			var unit := ""
			if mode == "tickets":
				unit = " tickets"
			elif mode == "caps":
				unit = " max alive"
			elif s["id"] == "spawn_rate":
				unit = " s"
			_hover_text = "%s · %s%s @ %s" % [s["label"], _trim(v), unit, _fmt_mmss(m)]
			return


# ── Edits ────────────────────────────────────────────────────────────────────

func _insert_point(sid: String, pos: Vector2) -> void:
	for si in series.size():
		var s: Dictionary = series[si]
		if s["id"] != sid or s["curve"] == null:
			continue
		var curve: Curve = s["curve"]
		var m := clampf(_minute_at(pos.x), 0.0, run_length)
		m = round(m / 0.25) * 0.25
		var v := curve.sample(m)
		if s.get("y_is_int", false):
			v = round(v)
		var i := curve.add_point(Vector2(m, v))
		curve.set_point_left_mode(i, Curve.TANGENT_LINEAR)
		curve.set_point_right_mode(i, Curve.TANGENT_LINEAR)
		_sel_point = Vector2i(si, i)
		selected_series_id = sid
		data_changed.emit()
		queue_redraw()
		return


func _delete_selected_point() -> void:
	if _sel_point.x < 0:
		return
	var s: Dictionary = series[_sel_point.x]
	var curve: Curve = s["curve"]
	if curve == null or curve.point_count <= 1:
		return
	curve.remove_point(_sel_point.y)
	_sel_point = Vector2i(-1, -1)
	data_changed.emit()
	queue_redraw()


func _add_guaranteed(sid: String, minute: float) -> void:
	for g in guaranteed:
		if g["series_id"] == sid:
			g["arr"].append(clampf(round(minute / 0.25) * 0.25, 0.0, run_length))
			g["arr"].sort()
			data_changed.emit()
			queue_redraw()
			return


# ── Formatting ───────────────────────────────────────────────────────────────

func _fmt_mmss(minutes: float) -> String:
	var total := int(round(minutes * 60.0))
	return "%d:%02d" % [total / 60, total % 60]


func _trim(v) -> String:
	var f := float(v)
	return str(int(round(f))) if is_equal_approx(f, round(f)) else "%.2f" % f

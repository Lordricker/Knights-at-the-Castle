extends Control

# hut_slot_timer.gd — Simple hand-drawn pie countdown, overlaid on a hut's
# slot icon while that unit is dead and waiting to respawn.
#
# Created and owned entirely by unit_hut.gd (not placed in any .tscn) — sized
# to match the 500x500 (pre-scale) box the sword/bow/book icons already use,
# so it visually overlays them exactly.
#
# progress = 1.0 -> full gray disc with the light-gray wedge covering the
# whole circle (just died). Counts down to 0.0 (respawn imminent).

@export var box_size: float = 500.0
@export var base_color: Color = Color(0.4, 0.4, 0.4, 0.85)
@export var progress_color: Color = Color(0.85, 0.85, 0.85, 0.9)

var progress: float = 0.0


func set_progress(p: float) -> void:
	progress = clampf(p, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	if progress <= 0.0:
		return
	var center := Vector2(box_size, box_size) * 0.5
	var radius := box_size * 0.45
	draw_circle(center, radius, base_color)
	if progress >= 1.0:
		draw_circle(center, radius, progress_color)
		return
	var steps := 32
	var end_angle := TAU * progress
	var points := PackedVector2Array([center])
	for i in steps + 1:
		var a := -PI / 2.0 + (end_angle * i / steps)
		points.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_colored_polygon(points, progress_color)

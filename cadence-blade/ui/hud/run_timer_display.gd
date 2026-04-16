extends Label

# run_timer_display.gd — HUD label that shows elapsed run time in M:SS format.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   CanvasLayer
#   └── Label  (this script)
#
# ── HOW TO USE ────────────────────────────────────────────────────────────────
#   1. Add a Label node to your HUD CanvasLayer.
#   2. Attach this script to it.
#   3. Drag the RunManager node into the `run_manager` export slot in the Inspector.
#   The label updates every frame, displaying 0:00 → N:SS.


## The RunManager node — must have a float property `time_elapsed`.
@export var run_manager: Node


func _process(_delta: float) -> void:
	if run_manager == null or not "time_elapsed" in run_manager:
		return
	var total_seconds: int = int(run_manager.time_elapsed)
	var minutes: int = total_seconds / 60
	var seconds: int = total_seconds % 60
	text = "%d:%02d" % [minutes, seconds]

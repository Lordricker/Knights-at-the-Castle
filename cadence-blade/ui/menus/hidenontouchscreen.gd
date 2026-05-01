# HideOnNonTouchscreen
# Attach this script directly to any Control node.
# On touchscreen devices (mobile/tablet) the node stays visible permanently.
# On non-touch devices (desktop) the node blinks twice so the player can see
# which buttons map to the on-screen controls, then fades out over 2 seconds.
extends Control

func _ready() -> void:
	if DisplayServer.is_touchscreen_available():
		return  # Mobile/tablet — stay visible always.
	_blink_then_fade()


func _blink_then_fade() -> void:
	modulate.a = 1.0
	show()
	var tween := create_tween()
	# Two quick blinks so the player notices the controls.
	tween.tween_property(self, "modulate:a", 0.0, 0.15)
	tween.tween_property(self, "modulate:a", 1.0, 0.15)
	tween.tween_property(self, "modulate:a", 0.0, 0.15)
	tween.tween_property(self, "modulate:a", 1.0, 0.15)
	# Brief pause so the player can read the layout.
	tween.tween_interval(0.5)
	# Fade out over 2 seconds, then hide so it no longer blocks input.
	tween.tween_property(self, "modulate:a", 0.0, 2.0)
	tween.tween_callback(hide)

# HideOnNonTouchscreen
# Attach this script directly to any Control node.
# The node (and all its children) will be automatically hidden
# on devices that do not have a touchscreen — e.g. desktop browsers.
# On mobile phones and tablets it stays visible.
extends Control

func _ready() -> void:
	if not DisplayServer.is_touchscreen_available():
		hide()

# details_button_glint.gd
# Attached to a clipping wrapper Control inside DetailsButton. Slides the "Bar"
# ColorRect across the button once as soon as the button becomes visible
# (i.e. as soon as a character is selected), then repeats on a timer for as
# long as the button stays visible.

extends Control

@export var bar: ColorRect
@export var sweep_duration: float = 0.6
@export var repeat_interval: float = 5.0

var _timer: Timer
var _owner_button: Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	if bar:
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.hide()

	_timer = Timer.new()
	_timer.wait_time = repeat_interval
	_timer.timeout.connect(_play_sweep)
	add_child(_timer)

	_owner_button = get_parent() as Control
	if _owner_button:
		_owner_button.visibility_changed.connect(_on_owner_visibility_changed)
		_on_owner_visibility_changed()


func _on_owner_visibility_changed() -> void:
	if _owner_button.visible:
		_play_sweep()
		_timer.start()
	else:
		_timer.stop()
		if bar:
			bar.hide()


func _play_sweep() -> void:
	if bar == null:
		return
	bar.position.x = -bar.size.x
	bar.show()
	var tween := create_tween()
	tween.tween_property(bar, "position:x", size.x, sweep_duration)
	tween.tween_callback(bar.hide)

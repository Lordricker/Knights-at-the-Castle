extends Node2D

# sprite_pace.gd — Attach to any Node2D (Sprite2D, AnimatedSprite2D, …). Slides
# right `distance` pixels, flips the x scale, slides back the same distance,
# flips again, and repeats forever.

## Pixels to travel each direction.
@export var distance: float = 100.0
## Seconds to cover `distance`.
@export var move_time: float = 1.0

var _start_x: float


func _ready() -> void:
	_start_x = position.x
	_pace()


func _pace() -> void:
	var tween := create_tween().set_loops()
	tween.tween_property(self, "position:x", _start_x + distance, move_time)
	tween.tween_callback(_flip)
	tween.tween_property(self, "position:x", _start_x, move_time)
	tween.tween_callback(_flip)


func _flip() -> void:
	scale.x = -scale.x

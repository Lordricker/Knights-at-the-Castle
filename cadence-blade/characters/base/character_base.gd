class_name CharacterBase
extends CharacterBody2D

# CharacterBase — shared base class for all playable characters.
# This is a 2.5D top-down game: no gravity.
# X = horizontal movement along the lane.
# Y = set by LaneSystem to represent depth (do not drive Y directly).

@export var move_speed: float = 200.0
@export var current_lane: int = 1

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var is_dead: bool = false

signal died()


func _ready() -> void:
	LaneSystem.move_entity_to_lane(self, current_lane)


func _physics_process(_delta: float) -> void:
	if is_dead:
		return
	_handle_movement()
	move_and_slide()


## Override in subclass to handle input and set velocity.
func _handle_movement() -> void:
	pass


## Call when the character runs out of health.
func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()


## Switch to an adjacent lane. direction: -1 = back lane, 1 = forward lane.
func change_lane(direction: int) -> void:
	LaneSystem.move_entity_to_lane(self, current_lane + direction)
	current_lane = get_meta("lane")

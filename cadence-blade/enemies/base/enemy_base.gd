class_name EnemyBase
extends CharacterBody2D

# EnemyBase — shared base class for all enemy types.
# No gravity — this is a 2.5D top-down game.

@export var max_health: float = 100.0
@export var move_speed: float = 80.0
@export var current_lane: int = 1
@export var attack_damage: float = 10.0
@export var attack_range: float = 60.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var health: float = max_health
var is_dead: bool = false
var target: Node2D = null

signal died(enemy: EnemyBase)
signal health_changed(new_health: float, max_hp: float)


func _ready() -> void:
	health = max_health
	LaneSystem.move_entity_to_lane(self, current_lane)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_handle_ai(delta)
	move_and_slide()


## Override in subclasses to implement movement and attack AI.
func _handle_ai(_delta: float) -> void:
	pass


func take_damage(amount: float) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit(self)



func _ready() -> void:
	health = max_health
	LaneSystem.move_entity_to_lane(self, current_lane)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_apply_gravity(delta)
	_handle_ai(delta)
	move_and_slide()


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += GRAVITY * delta


## Override in subclasses to implement movement and attack AI.
func _handle_ai(_delta: float) -> void:
	pass


func take_damage(amount: float) -> void:
	if is_dead:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit(self)

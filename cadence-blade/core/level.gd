extends Node2D

# level.gd — the single reusable level scene.
# Swap visual variants by loading a different environment resource at runtime.
# Call set_variant("day") / set_variant("night") / set_variant("dusk").
# Add day_environment.tres / night_environment.tres / dusk_environment.tres
# to res://level/variants/ once your Environment resources are ready.

const VARIANT_PATHS: Dictionary = {
	"day":   "res://level/variants/day_environment.tres",
	"night": "res://level/variants/night_environment.tres",
	"dusk":  "res://level/variants/dusk_environment.tres",
}

## Drag the DeathPoof scene (res://FX/DeathPoof.tscn) here in the Inspector.
@export var death_poof_scene: PackedScene
## Coin scene to spawn when enemies die (res://core/coin.tscn).
## Leave empty to disable coin drops.
@export var coin_scene: PackedScene = preload("res://core/coin.tscn")

@onready var world_environment: WorldEnvironment = $WorldEnvironment

signal variant_changed(variant_name: String)


func _ready() -> void:
	set_variant(GameManager.current_level_variant)


## Called by any entity (CharacterBase or EnemyBase) when it dies.
## Spawns a death poof at the given world position.
## spawn_coin is false for player deaths (CharacterBase passes false explicitly);
## EnemyBase uses the default of true so every enemy drops a coin.
func on_entity_died(world_position: Vector2, spawn_coin: bool = true) -> void:
	if death_poof_scene == null:
		return
	var poof: Node2D = death_poof_scene.instantiate() as Node2D
	if poof == null:
		return
	add_child(poof)
	poof.global_position = world_position
	# Play every child that supports play/restart/emitting.
	for child in poof.find_children("*"):
		if child.has_method("restart"):
			child.restart()
		if child.has_method("play"):
			child.play()
		if "emitting" in child:
			child.emitting = true
	# Remove the poof after 5 seconds.
	get_tree().create_timer(5.0).timeout.connect(poof.queue_free, CONNECT_ONE_SHOT)

	if spawn_coin and coin_scene != null:
		var coin: Node2D = coin_scene.instantiate() as Node2D
		if coin != null:
			add_child(coin)
			coin.global_position = world_position


## Switch the level's visual look. variant_name must be "day", "night", or "dusk".
func set_variant(variant_name: String) -> void:
	if not VARIANT_PATHS.has(variant_name):
		push_error("Level: unknown variant '%s'" % variant_name)
		return
	var env: Environment = load(VARIANT_PATHS[variant_name])
	if env == null:
		push_warning("Level: variant file not found for '%s' — create the .tres first." % variant_name)
		return
	world_environment.environment = env
	GameManager.set_level_variant(variant_name)
	variant_changed.emit(variant_name)

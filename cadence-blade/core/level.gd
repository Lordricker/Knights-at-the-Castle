extends Node2D

# level.gd — the single reusable level scene.
# Swap visual variants by loading a different environment resource at runtime.
# Call set_variant("day") / set_variant("night") / set_variant("dusk").
# Add day_environment.tres / night_environment.tres / dusk_environment.tres
# to res://level/variants/ once your Environment resources are ready.

# Variant system disabled until WorldEnvironment node and .tres assets are created.
#const VARIANT_PATHS: Dictionary = {
#	"day":   "res://level/variants/day_environment.tres",
#	"night": "res://level/variants/night_environment.tres",
#	"dusk":  "res://level/variants/dusk_environment.tres",
#}

## Drag the DeathPoof scene (res://FX/DeathPoof.tscn) here in the Inspector.
@export var death_poof_scene: PackedScene
## Coin scenes for each tier — assign in the Inspector.
@export var coin_scene: PackedScene = preload("res://core/coin.tscn")    ## Tier 1
@export var coin2_scene: PackedScene = preload("res://core/coin2.tscn")   ## Tier 2
@export var coin4_scene: PackedScene = preload("res://core/coin4.tscn")   ## Tier 3

#@onready var world_environment: WorldEnvironment = $WorldEnvironment

#signal variant_changed(variant_name: String)


func _ready() -> void:
	pass  # set_variant disabled until variant assets exist
	#set_variant(GameManager.current_level_variant)


## Called by any entity (CharacterBase or EnemyBase) when it dies.
## Spawns a death poof at the given world position.
## spawn_coin is false for player deaths; EnemyBase passes true.
## coin_tier: 0=none, 1=coin_scene, 2=coin2_scene, 3=coin4_scene.
func on_entity_died(world_position: Vector2, spawn_coin: bool = true, coin_tier: int = 1) -> void:
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

	if spawn_coin and coin_tier > 0:
		var scene_to_use: PackedScene
		match coin_tier:
			2: scene_to_use = coin2_scene
			3: scene_to_use = coin4_scene
			_: scene_to_use = coin_scene
		if scene_to_use != null:
			var coin: Node2D = scene_to_use.instantiate() as Node2D
			if coin != null:
				add_child(coin)
				coin.global_position = world_position


# set_variant() disabled until WorldEnvironment node and .tres assets are created.
#func set_variant(variant_name: String) -> void:
#	if not VARIANT_PATHS.has(variant_name):
#		push_error("Level: unknown variant '%s'" % variant_name)
#		return
#	var env: Environment = load(VARIANT_PATHS[variant_name])
#	if env == null:
#		push_warning("Level: variant file not found for '%s' — create the .tres first." % variant_name)
#		return
#	world_environment.environment = env
#	GameManager.set_level_variant(variant_name)
#	variant_changed.emit(variant_name)

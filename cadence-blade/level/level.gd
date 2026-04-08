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

@onready var world_environment: WorldEnvironment = $WorldEnvironment

signal variant_changed(variant_name: String)


func _ready() -> void:
	set_variant(GameManager.current_level_variant)


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

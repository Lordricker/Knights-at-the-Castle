extends ColorRect

# night_overlay.gd — Full-screen ColorRect that reads SCREEN_TEXTURE and
# applies a desaturate + blue-tint + darken pass, driven by EnemySpawner's
# get_night_intensity(). Lives as the first child of HUD/Control so later HUD
# elements (timer, coins, buttons) draw on top and stay legible.

const _SHADER := preload("res://assets/shaders/night_overlay.gdshader")

@export_group("Night Look")
## How much color is pulled toward greyscale at full night (0 = none, 1 = fully grey).
@export_range(0.0, 1.0) var desaturation: float = 0.3
## How much the frame darkens at full night (0 = no darkening, 1 = black).
@export_range(0.0, 1.0) var darken: float = 0.22
## Tint color mixed in at full night.
@export var night_tint: Color = Color(0.12, 0.16, 0.35)

var _spawner: Node = null
var _mat: ShaderMaterial


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = _SHADER
	material = _mat


func _process(_delta: float) -> void:
	if _spawner == null or not is_instance_valid(_spawner):
		var found := get_tree().get_first_node_in_group(&"enemy_spawner")
		_spawner = found
	_mat.set_shader_parameter(&"desaturation", desaturation)
	_mat.set_shader_parameter(&"darken", darken)
	_mat.set_shader_parameter(&"night_tint", Vector3(night_tint.r, night_tint.g, night_tint.b))
	if _spawner == null or not _spawner.has_method(&"get_night_intensity"):
		return
	_mat.set_shader_parameter(&"intensity", _spawner.get_night_intensity())

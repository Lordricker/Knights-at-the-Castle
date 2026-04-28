extends Sprite2D

@export var camera_path: NodePath
@export var parallax_factor: float = 0.5

var _camera: Camera2D
var _last_camera_pos: Vector2

func _ready():
	if camera_path != NodePath():
		_camera = get_node(camera_path) as Camera2D
	else:
		_camera = get_viewport().get_camera_2d()
	if _camera:
		_last_camera_pos = _camera.global_position

func _process(_delta):
	if not _camera:
		return
	var camera_delta = _camera.global_position - _last_camera_pos
	position += camera_delta * parallax_factor
	_last_camera_pos = _camera.global_position

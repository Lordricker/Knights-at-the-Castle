extends Camera2D

# level_camera.gd -- Follows all active players in the "players" group.
#
# Single player: smoothly tracks that player at the default zoom.
# Multiple players: centers on their midpoint and zooms out just enough to
# keep everyone in frame (with configurable margin padding).
#
# SETUP:
#   Add a Camera2D to the level scene root, attach this script, and set the
#   Inspector exports to match your art resolution and feel.
#   Make sure RunManager adds each spawned player to the "players" group
#   (it does this automatically after this script is in place).

@export_group("Zoom")
## Zoom level used when only one player is active. Matches what was on RedKnight.
@export var single_player_zoom: float = 2.0
## Maximum zoom-out allowed when players spread far apart (lower = further out).
@export var min_zoom: float = 0.5
## Extra world-space pixels of padding added around the player bounding box.
@export var zoom_margin: float = 200.0
@export_group("Framing")
## Shifts the camera target upward by this many world-space pixels, placing the player lower on screen.
@export var vertical_offset: float = 0.0
@export_group("Smoothing")
## Position smoothing used on the joiner so host corrections do not become camera jitter.
@export var joiner_position_smooth_speed: float = 10.0
## Zoom smoothing used on the joiner to avoid abrupt framing changes during corrections.
@export var joiner_zoom_smooth_speed: float = 8.0

var _camera_initialized: bool = false


func _process(delta: float) -> void:
	var players: Array[Node] = []
	for node in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(node):
			continue
		# Skip dead players. The dead flag may live on the root or a child (wrapped scenes).
		var dead: bool = false
		if "is_dead" in node:
			dead = node.is_dead
		else:
			for child in node.get_children():
				if "is_dead" in child:
					dead = child.is_dead
					break
		if dead:
			continue
		players.append(node)

	if players.is_empty():
		return

	var target_center: Vector2 = _calc_center(players)
	var target_zoom_val: float = _calc_zoom(players)
	var target_zoom := Vector2(target_zoom_val, target_zoom_val)
	var smooth_joiner_camera: bool = GameManager.session_id != "" and not GameManager.is_host

	if not _camera_initialized:
		global_position = target_center
		zoom = target_zoom
		_camera_initialized = true
	elif smooth_joiner_camera:
		global_position = global_position.lerp(target_center, minf(joiner_position_smooth_speed * delta, 1.0))
		zoom = zoom.lerp(target_zoom, minf(joiner_zoom_smooth_speed * delta, 1.0))
	else:
		global_position = target_center
		zoom = target_zoom

	# Round after smoothing to keep the pixel-art camera crisp.
	global_position = global_position.round()


func _calc_center(players: Array[Node]) -> Vector2:
	var sum := Vector2.ZERO
	for p in players:
		sum += (p as Node2D).global_position
	return sum / float(players.size()) - Vector2(0.0, vertical_offset)


func _calc_zoom(players: Array[Node]) -> float:
	if players.size() == 1:
		return single_player_zoom

	var min_pos: Vector2 = (players[0] as Node2D).global_position
	var max_pos: Vector2 = min_pos

	for p in players:
		var pos: Vector2 = (p as Node2D).global_position
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.y)
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.y)

	var span := max_pos - min_pos + Vector2(zoom_margin * 2.0, zoom_margin * 2.0)
	var vp := get_viewport_rect().size

	# Pick the axis that needs more zoom-out so both axes fit.
	var zoom_fit: float = minf(vp.x / span.x, vp.y / span.y)
	return clampf(zoom_fit, min_zoom, single_player_zoom)

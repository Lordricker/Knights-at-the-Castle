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
@export_group("Shake")
## Max world-space pixel offset applied at full trauma (trauma = 1.0).
@export var shake_max_offset: float = 16.0
## How fast trauma decays per second (1.0 = fully decays in ~1 second).
@export var shake_decay: float = 2.5

var _camera_initialized: bool = false
## 0..1 "trauma" driving the shake offset; decays each frame. See add_shake().
var _shake_trauma: float = 0.0


func _ready() -> void:
	# Read player positions after RunManager has interpolated the remote puppets this
	# frame. Scene order happens to give this today, but players are added at runtime,
	# so state it explicitly rather than depending on that.
	process_priority = 100


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
	var online: bool = GameManager.session_id != ""
	# Position smoothing stays joiner-only. On the host it would put the camera behind
	# the host's own authoritative character, which is a real feel regression in a
	# timing game — and with remote puppets now interpolated, target_center is already
	# smooth, so there is nothing left for it to fix.
	var smooth_position: bool = online and not GameManager.is_host

	if not _camera_initialized:
		global_position = target_center
		zoom = target_zoom
		_camera_initialized = true
	else:
		if smooth_position:
			global_position = global_position.lerp(target_center, minf(joiner_position_smooth_speed * delta, 1.0))
		else:
			global_position = target_center
		# Zoom is smoothed on both sides of an online session: it is a function of the
		# player bounding box, so any residual remote-position noise would otherwise
		# modulate the scale of the entire screen.
		if online:
			zoom = zoom.lerp(target_zoom, minf(joiner_zoom_smooth_speed * delta, 1.0))
		else:
			zoom = target_zoom

	global_position += _calc_shake_offset(delta)

	# Round after smoothing to keep the pixel-art camera crisp.
	global_position = global_position.round()


## Adds trauma (clamped to 1.0) that decays over time, driving a per-frame shake offset.
## Call from combat code, e.g. a flow-attack crit landing: camera.add_shake(0.6).
func add_shake(amount: float) -> void:
	_shake_trauma = clampf(_shake_trauma + amount, 0.0, 1.0)


## Returns this frame's random shake offset and advances trauma decay.
func _calc_shake_offset(delta: float) -> Vector2:
	if _shake_trauma <= 0.0:
		return Vector2.ZERO
	var falloff := _shake_trauma * _shake_trauma
	var shake_offset := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake_max_offset * falloff
	_shake_trauma = maxf(0.0, _shake_trauma - shake_decay * delta)
	return shake_offset


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
	# Quantise so small changes in player separation cannot modulate the scale of the
	# whole screen. 1/16 steps are invisible at these zoom levels, while continuous
	# zoom turns any residual remote-position noise into full-screen breathing.
	return snappedf(clampf(zoom_fit, min_zoom, single_player_zoom), 0.0625)

extends Node2D

## tnt.gd — Attach to the TNT.tscn root Node2D.
##
## Spawned by CastleInside when the player purchases TNT at the blacksmith.
## Lerps toward the owner player until its Area2D overlaps an EnemyTower's
## interaction Area2D, then calls tower.destroy() and frees itself.
##
## Set `owner_player` before adding to the scene tree (CastleInside does this).

## Lerp weight per second — higher = tighter follow.
@export var lerp_speed: float = 8.0
## Pixel offset from the player's position where the TNT hovers.
@export var follow_offset: Vector2 = Vector2(20, -55)

## Assigned by CastleInside before the node enters the scene tree.
var owner_player: Node = null

## How long after a tower dies it still counts as a valid match — covers the
## joiner's cosmetic TNT copy (see the loop below) without leaving a tower's
## old footprint as a permanent TNT sink long after it fell.
const DESTROYED_GRACE_MSEC: int = 3000

@onready var _area:       Area2D          = $Area2D
@onready var _sprite:     TextureRect     = $TextureRect
@onready var _particles1: CPUParticles2D  = $CPUParticles2D
@onready var _particles2: CPUParticles2D  = $CPUParticles2D2

var _exploded: bool = false

func _ready() -> void:
	# No area_entered signal needed — we poll overlapping areas each frame
	# to avoid collision layer mismatches on default project settings.
	pass


func _process(delta: float) -> void:
	if _exploded:
		return
	if owner_player == null or not is_instance_valid(owner_player):
		return
	var target: Vector2 = owner_player.global_position + follow_offset
	global_position = global_position.lerp(target, lerp_speed * delta)

	# Check if our Area2D is overlapping any relevant enemy tower's interaction area.
	# "Relevant" = active, OR destroyed within the last DESTROYED_GRACE_MSEC (not
	# "never activated" and not "destroyed ages ago"). The plain is_active check
	# used to skip an already-destroyed tower — which breaks the joiner's cosmetic
	# TNT copy: it lerps toward the buyer's position over real time, and the host's
	# authoritative "tower_destroyed" packet (sent the instant the host's own TNT
	# reaches the tower) routinely arrives before this copy finishes its travel,
	# flipping is_active false first. Matching a *freshly* destroyed tower too
	# means it still gets matched, so this TNT explodes instead of hovering
	# forever. The grace window keeps that fix from turning every tower's old,
	# long-dead footprint into a permanent trap that silently consumes real TNT
	# wandering nearby. A tower that was never activated on this peer still has
	# both flags false and is correctly skipped.
	for tower in get_tree().get_nodes_in_group(&"enemy_towers"):
		if not tower.has_method(&"destroy"):
			continue
		if not tower.get("is_active"):
			if not tower.get("is_destroyed"):
				continue
			var destroyed_at: int = int(tower.get("destroyed_at_msec"))
			if destroyed_at < 0 or Time.get_ticks_msec() - destroyed_at > DESTROYED_GRACE_MSEC:
				continue
		var t_area: Area2D = tower.get("interaction_area") as Area2D
		if t_area == null:
			continue
		# Simple distance check using the collision shape extents.
		var shape_node := t_area.get_child(0) as CollisionShape2D
		if shape_node == null:
			continue
		var half_size: Vector2 = Vector2.ZERO
		if shape_node.shape is RectangleShape2D:
			half_size = (shape_node.shape as RectangleShape2D).size * 0.5
		elif shape_node.shape is CircleShape2D:
			var r: float = (shape_node.shape as CircleShape2D).radius
			half_size = Vector2(r, r)
		# Transform TNT world position into the shape node's local space
		# so the CollisionShape2D's own position offset is accounted for.
		var local_pos: Vector2 = shape_node.to_local(global_position)
		if abs(local_pos.x) <= half_size.x and abs(local_pos.y) <= half_size.y:
			if GameManager.session_id == "" or GameManager.is_host:
				tower.call(&"destroy")
			_explode()
			return


func _explode() -> void:
	_exploded        = true
	_sprite.visible  = false
	# Let the existing fuse particles finish their current cycle, then stop.
	_particles1.one_shot = true
	_particles2.one_shot = true
	# Free after the longest particle lifetime so sparks finish playing.
	var lifetime: float = maxf(_particles1.lifetime, _particles2.lifetime)
	get_tree().create_timer(lifetime + 0.1).timeout.connect(queue_free)

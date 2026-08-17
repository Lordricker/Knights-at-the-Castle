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

	# Check if our Area2D is overlapping any active enemy tower's interaction area.
	for tower in get_tree().get_nodes_in_group(&"enemy_towers"):
		if not tower.has_method(&"destroy"):
			continue
		if not tower.get("is_active"):
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

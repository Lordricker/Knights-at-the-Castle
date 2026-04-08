extends Node

# LaneSystem — manages 2.5D vertical lane logic
# Register in: Project > Project Settings > Autoload > Name: "LaneSystem"

# Number of lanes on screen. Adjust to taste.
const LANE_COUNT: int = 4

# World-space Y position for each lane (tweak to match your level art).
# Lane 0 = furthest back, Lane 3 = closest to camera.
var lane_positions: Array[float] = [100.0, 175.0, 250.0, 325.0]

# Scale applied to characters per lane to simulate depth (front lane = larger).
var lane_scales: Array[float] = [0.6, 0.75, 0.9, 1.0]

signal entity_changed_lane(entity: Node, old_lane: int, new_lane: int)


func _ready() -> void:
	pass


## Returns the Y world position for a given lane index.
func get_lane_y(lane: int) -> float:
	lane = clampi(lane, 0, LANE_COUNT - 1)
	return lane_positions[lane]


## Returns the scale for a given lane index.
func get_lane_scale(lane: int) -> float:
	lane = clampi(lane, 0, LANE_COUNT - 1)
	return lane_scales[lane]


## Moves an entity to a new lane, updating its Y position and scale.
func move_entity_to_lane(entity: Node2D, new_lane: int) -> void:
	var old_lane: int = entity.get_meta("lane", 0)
	new_lane = clampi(new_lane, 0, LANE_COUNT - 1)
	entity.set_meta("lane", new_lane)
	entity.position.y = get_lane_y(new_lane)
	entity.scale = Vector2.ONE * get_lane_scale(new_lane)
	entity_changed_lane.emit(entity, old_lane, new_lane)

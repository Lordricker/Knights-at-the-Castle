class_name EnemyNavigation
extends RefCounted

# EnemyNavigation — shared helper for enemies that are constrained to a
# "walk_area" Polygon2D (see EnemyBase/sheepdog) instead of a walk_path lane.
#
# A straight line from such an enemy to the player will frequently cross
# outside the polygon whenever the walk_area is concave (e.g. a winding
# path), causing the enemy to shove into the boundary and get stuck.
# get_or_create_nav_region() bakes that same polygon into a NavigationPolygon
# once and caches it as a child of the Polygon2D, so any enemy can pair it
# with a NavigationAgent2D and pathfind through the area instead of beelining.

## agent_radius should roughly match half the widest dimension of the
## enemy's collision box. Baking the navmesh eroded by that much keeps the
## path centerline clear of concave corners, so the enemy's own body doesn't
## clip the wall and fight its own walk_area clamp to a standstill.
static func get_or_create_nav_region(walk_area: Polygon2D, agent_radius: float = 16.0) -> NavigationRegion2D:
	var existing := walk_area.get_node_or_null("GeneratedNavRegion") as NavigationRegion2D
	if existing != null:
		return existing

	var region := NavigationRegion2D.new()
	region.name = "GeneratedNavRegion"
	walk_area.add_child(region)

	var nav_poly := NavigationPolygon.new()
	nav_poly.agent_radius = agent_radius
	var source_geometry := NavigationMeshSourceGeometryData2D.new()
	source_geometry.add_traversable_outline(walk_area.polygon)
	NavigationServer2D.bake_from_source_geometry_data(nav_poly, source_geometry)
	region.navigation_polygon = nav_poly

	return region


## Returns the first "walk_area" group member in the tree, or null if none
## has been added yet (e.g. this level has no walk_area at all).
static func find_walk_area(tree: SceneTree) -> Polygon2D:
	var areas: Array[Node] = tree.get_nodes_in_group("walk_area")
	return areas[0] as Polygon2D if areas.size() > 0 else null


## walk_area.polygon is in the Polygon2D's local space — this returns the
## same points transformed into global space, for containment/geometry
## checks against global_position.
static func world_polygon(walk_area: Polygon2D) -> PackedVector2Array:
	var xform: Transform2D = walk_area.global_transform
	var world_poly := PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)
	return world_poly


## True once `global_pos` has crossed into walk_area's boundary.
static func is_inside(walk_area: Polygon2D, global_pos: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(global_pos, world_polygon(walk_area))


## Nearest point to `global_pos` that actually lies on walk_area's baked
## navmesh — used to snap a player-placed waypoint (which can land anywhere
## clickable, including outside the walkable ground) onto the area before
## units are sent to it.
static func snap_to_navmesh(walk_area: Polygon2D, global_pos: Vector2) -> Vector2:
	var region := get_or_create_nav_region(walk_area)
	var map: RID = region.get_navigation_map()
	# The map only has valid query data after its first sync pass (one physics
	# frame after the region's polygon is assigned) — querying before that
	# would silently hand back (0, 0). Falling back to the raw click keeps the
	# old (unsnapped) behavior for that one-frame window instead of teleporting
	# the flag to the map origin.
	if NavigationServer2D.map_get_iteration_id(map) == 0:
		return global_pos
	return NavigationServer2D.map_get_closest_point(map, global_pos)

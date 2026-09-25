extends EnemyBase

# weasle.gd — Enemy: Weasel.
#
# The weasel travels UNDERGROUND (invulnerable, no steal hurtbox) and chases the
# nearest living player exactly like the sheepdog. When a player enters its
# detection zone it EMERGES (appear animation + a burst of dirt particles), then
# LUNGES forward like the sheepdog's bash. A lunge that connects deals
# `lunge_damage` (+ knockback) and STEALS one random non-empty stat pip
# (hp / attack / speed) from that player:
#   • hp     → doubles the weasel's own max health
#   • speed  → the weasel runs faster
#   • attack → faster lunge + a bigger detection zone (harder to corner)
# The stolen stat's icon floats above the weasel for the rest of its life.
#
# Once it is carrying a pip the weasel FLEES forever — running directly away from
# any player in its detection zone, idling when nobody is near — and never
# re-burrows (it is vulnerable the whole time). If it lunges and there was
# nothing to steal (player had no pips) it stays aggressive and keeps lunging.
#
# On death it drops a treasureChest.tscn — like EnemyTower — pre-seeded with the
# stat category it stole.
#
# MULTIPLAYER: host-authoritative, same shape as sheepdog.gd. The host runs the
# AI; joiners interpolate position and mirror the animation from the state
# snapshot. Particles are animation-driven so they play identically on both
# peers with no extra packets. Two small extras are synced: the stolen-pip icon
# (a reliable "weasel"/"stole" packet) and the dropped chest (both peers spawn
# a deterministically-named copy in die(), like EnemyTower).
#
# SCENE STRUCTURE (Weasle.tscn):
#   Node2D  (scene root, y_sort_enabled)
#   └── CharacterBody2D  (this script, collision_layer = 2)
#       ├── CollisionShape2D        ← body_box
#       ├── NavigationAgent2D
#       └── Pivot  (facing_pivot)
#           ├── AnimatedSprite2D    (groundrunning / appear / attack / running / idle)
#           ├── hurtbox   (Area2D — the steal box, active during the lunge)
#           ├── DetectionZone (Area2D — players entering trigger the emerge / flee)
#           ├── HPBar
#           ├── upattack / upspeed / uphealth  (TextureRect stat icons, hidden until a steal)
#           ├── appearparticles       (CPUParticles2D, one-shot burst on emerge)
#           └── undergroundparticles  (CPUParticles2D, runs while burrowed)

# ── Inspector-configurable stats ──────────────────────────────────────────────

@export_group("Lunge")
## Pixels/sec the weasel lunges horizontally during the active lunge window.
@export var lunge_speed: float = 300.0
## Total length of one lunge, in seconds.
@export var lunge_duration: float = 0.4
## Start / end (seconds into the lunge) of the window where the steal hurtbox is
## live and the horizontal lunge speed is applied.
@export var lunge_active_start: float = 0.05
@export var lunge_active_end: float = 0.3
## Damage dealt to a player the lunge connects with (in addition to stealing a pip).
@export var lunge_damage: float = 10.0
## Knockback force applied to a player the lunge connects with.
@export var lunge_knockback: float = 120.0
## Weapon type reported to the player the lunge hits.
@export var steal_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.CLAW
## Seconds the "burrow" dig-back-in animation plays before the weasel is fully
## underground again (only when it dives back down without having stolen a pip).
@export var burrow_duration: float = 0.35

@export_group("Steal buffs")
## Stolen hp pip → max_health is multiplied by this.
@export var hp_steal_health_mult: float = 2.0
## Stolen speed pip → move_speed is multiplied by this.
@export var speed_steal_move_mult: float = 1.6
## Stolen attack pip → lunge_speed is multiplied by this…
@export var attack_steal_lunge_mult: float = 1.5
## …and the detection zone rectangle is multiplied by this.
@export var attack_steal_detect_mult: float = 1.4

@export_group("Scene nodes")
## Drag the main CollisionShape2D here for the polygon boundary constraint.
@export var body_box: CollisionShape2D
## The Area2D that steals a pip when it overlaps a player during the lunge.
@export var steal_hurtbox: Area2D
## One-shot dirt burst played the instant the weasel emerges.
@export var appear_particles: CPUParticles2D
## Continuous dirt trail played while the weasel is burrowed.
@export var underground_particles: CPUParticles2D

@export_group("Chest drop")
## Chest spawned where the weasel dies, containing the stat it stole. Set null to
## suppress the drop.
@export var treasure_chest_scene: PackedScene = preload("res://level/treasureChest.tscn")
## World-space offset from the weasel where the chest appears.
@export var treasure_chest_offset: Vector2 = Vector2(0, 4)

# ── Internal state ─────────────────────────────────────────────────────────────

enum State { BURROWED, BURROWING, EMERGING, LUNGING, FLEEING, IDLE }

var _state: State = State.BURROWED
## "" until a pip is stolen, then "hp" / "attack" / "speed".
var _stolen_stat: String = ""
## Guards a second steal in the same (or any later) lunge — first hit only.
var _steal_done: bool = false
## True while the weasel cannot be hit (burrowed).
var _invulnerable: bool = true
## Captured collision layer used above ground (0 while burrowed).
var _ground_layer: int = 2
## Lunge timer (seconds elapsed in the current lunge).
var _lunge_time: float = 0.0
var _lunge_active: bool = false
## One damage application per lunge — reset in _begin_lunge().
var _lunge_hit_done: bool = false
## Timer for the BURROWING dig-back-in animation.
var _burrow_time: float = 0.0
## One-shot guard so the emerge dirt burst fires exactly once per emerge.
var _appear_fx_done: bool = false
var _chest_dropped: bool = false

## Polygon2D from the "walk_area" group — constrains movement like the players.
var walk_area: Polygon2D = null
## Baked once so the weasel paths around the (often concave) boundary.
var nav_region: NavigationRegion2D = null

## Maps a stolen stat category to its icon child node name.
const ICON_NODES: Dictionary = {
	"attack": "upattack",
	"hp":     "uphealth",
	"speed":  "upspeed",
}

@onready var nav_agent: NavigationAgent2D = find_child("NavigationAgent2D") as NavigationAgent2D


func _ready() -> void:
	super()
	add_to_group(&"weasels")
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)

	if detection_zone != null:
		detection_zone.monitoring = true
	_set_hurtbox(false)
	if steal_hurtbox != null:
		steal_hurtbox.body_entered.connect(_on_steal_overlap)
		steal_hurtbox.area_entered.connect(_on_steal_overlap)

	# Hide the stat icons until something is actually stolen.
	for cat: String in ICON_NODES:
		var icon := _icon_for(cat)
		if icon != null:
			icon.hide()

	if underground_particles != null:
		underground_particles.emitting = false

	_ground_layer = get_collision_layer()
	if _ground_layer == 0:
		_ground_layer = 2
	_enter_burrowed()


# ── Physics (walk_area constraint, mirrors sheepdog.gd) ───────────────────────

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if is_frozen:
		velocity = Vector2.ZERO
		knockback_velocity = Vector2.ZERO
		return

	# Joiner: no local AI — mirror the host's position from the network buffer.
	if apply_net_position():
		return

	if walk_area == null:
		var areas: Array[Node] = get_tree().get_nodes_in_group("walk_area")
		if areas.size() > 0:
			walk_area = areas[0] as Polygon2D
	if walk_area != null and nav_region == null:
		nav_region = EnemyNavigation.get_or_create_nav_region(walk_area, 16.0)

	_handle_ai(delta)
	velocity += knockback_velocity
	move_and_slide()
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)

	# Lunge is applied after move_and_slide so the polygon constraint can clamp it.
	if _lunge_active:
		global_position.x += facing * lunge_speed * delta

	if walk_area != null:
		_constrain_to_walk_area()


func _process(_delta: float) -> void:
	# Animation-driven, so it also runs correctly on the joiner (which plays the
	# host's animation via the state snapshot).
	if animated_sprite == null:
		return
	# Re-arm the emerge burst once the appear animation is over (covers the
	# joiner, which never runs the state-machine enter functions).
	if _appear_fx_done and animated_sprite.animation != &"appear":
		_appear_fx_done = false
	var burrowed: bool = animated_sprite.animation == &"groundrunning" \
		or animated_sprite.animation == &"burrow"
	if underground_particles != null:
		var want: bool = (not is_dead) and burrowed
		if underground_particles.emitting != want:
			underground_particles.emitting = want
	# Hide the HP bar while the weasel is underground (it can't be hit there).
	if health_bar != null:
		var show_bar: bool = (not is_dead) and not burrowed
		if health_bar.visible != show_bar:
			health_bar.visible = show_bar


# ── AI ─────────────────────────────────────────────────────────────────────────

func _handle_ai(delta: float) -> void:
	match _state:
		State.BURROWED:
			_ai_burrowed()
		State.BURROWING:
			_ai_burrowing(delta)
		State.EMERGING:
			velocity = Vector2.ZERO
		State.LUNGING:
			_ai_lunging(delta)
		State.FLEEING:
			_ai_fleeing()
		State.IDLE:
			_ai_idle()


func _ai_burrowed() -> void:
	if _get_targets_in_range().size() > 0:
		_enter_emerging()
		return
	var nearest := _get_nearest_player()
	if nearest == null:
		target = null
		velocity = Vector2.ZERO
		return
	target = nearest
	var dir: Vector2
	if nav_agent != null and nav_region != null:
		nav_agent.target_position = nearest.global_position
		dir = (nav_agent.get_next_path_position() - global_position).normalized()
	else:
		dir = (nearest.global_position - global_position).normalized()
	velocity = dir * move_speed
	_set_facing(1.0 if dir.x >= 0.0 else -1.0)


func _ai_lunging(delta: float) -> void:
	_lunge_time += delta
	var active: bool = _lunge_time >= lunge_active_start and _lunge_time <= lunge_active_end
	if active != _lunge_active:
		_lunge_active = active
		_set_hurtbox(active and not _steal_done)
	velocity = Vector2.ZERO  # horizontal lunge is applied in _physics_process
	if _lunge_time >= lunge_duration:
		_end_lunge()


func _ai_burrowing(delta: float) -> void:
	velocity = Vector2.ZERO
	_burrow_time += delta
	if _burrow_time >= burrow_duration:
		_enter_burrowed()


func _ai_fleeing() -> void:
	var in_range := _get_targets_in_range()
	if in_range.is_empty():
		_enter_idle()
		return
	var nearest := _nearest_of(in_range)
	if nearest == null:
		_enter_idle()
		return
	var dir := (global_position - nearest.global_position).normalized()
	velocity = dir * move_speed
	if animated_sprite.animation != &"running":
		animated_sprite.play(&"running")
	_set_facing(1.0 if dir.x >= 0.0 else -1.0)


func _ai_idle() -> void:
	velocity = Vector2.ZERO
	if _get_targets_in_range().size() > 0:
		_enter_fleeing()
		return
	if animated_sprite.animation != &"idle":
		animated_sprite.play(&"idle")


func _is_attacking() -> bool:
	return _state == State.EMERGING or _state == State.LUNGING or _state == State.BURROWING


# ── State transitions ─────────────────────────────────────────────────────────

func _enter_burrowed() -> void:
	_state = State.BURROWED
	_invulnerable = true
	_lunge_active = false
	_appear_fx_done = false
	_set_hurtbox(false)
	set_collision_layer(0)
	if health_bar != null:
		health_bar.hide()
	if animated_sprite.animation != &"groundrunning":
		animated_sprite.play(&"groundrunning")


## Transient dive-back-in: plays the "burrow" animation for burrow_duration, then
## _enter_burrowed(). Used when a lunge ends with no pip stolen and the player has
## left attack range.
func _enter_burrowing() -> void:
	_state = State.BURROWING
	_invulnerable = true
	_lunge_active = false
	_burrow_time = 0.0
	velocity = Vector2.ZERO
	_set_hurtbox(false)
	set_collision_layer(0)
	if health_bar != null:
		health_bar.hide()
	if animated_sprite.animation != &"burrow":
		animated_sprite.play(&"burrow")


func _enter_emerging() -> void:
	_state = State.EMERGING
	_invulnerable = false
	set_collision_layer(_ground_layer)
	velocity = Vector2.ZERO
	if target != null:
		_set_facing(1.0 if target.global_position.x >= global_position.x else -1.0)
	_appear_fx_done = false
	animated_sprite.stop()
	animated_sprite.play(&"appear")
	_play_appear_fx()


func _begin_lunge() -> void:
	_state = State.LUNGING
	_lunge_time = 0.0
	_lunge_active = false
	_lunge_hit_done = false
	if target != null and is_instance_valid(target):
		_set_facing(1.0 if target.global_position.x >= global_position.x else -1.0)
	animated_sprite.stop()
	animated_sprite.play(&"attack")


func _end_lunge() -> void:
	_lunge_active = false
	_set_hurtbox(false)
	if _stolen_stat != "":
		_enter_fleeing()
	elif _get_targets_in_range().size() > 0:
		_begin_lunge()          # still aggressive — nothing was stolen, keep lunging
	else:
		_enter_burrowing()      # player left range — play the dig-back-in animation


func _enter_fleeing() -> void:
	_state = State.FLEEING
	_invulnerable = false
	_set_hurtbox(false)
	set_collision_layer(_ground_layer)
	animated_sprite.play(&"running")


func _enter_idle() -> void:
	_state = State.IDLE
	velocity = Vector2.ZERO
	animated_sprite.play(&"idle")


func _on_animation_finished() -> void:
	if _state == State.EMERGING and animated_sprite.animation == &"appear":
		_begin_lunge()


func _on_frame_changed() -> void:
	# Emerge dirt burst — fire once when the appear animation shows its first
	# frame. Guarded so it works whether this fires on the host (from our own
	# play()) or on the joiner (from the state-snapshot animation).
	if animated_sprite.animation == &"appear" and animated_sprite.frame == 0:
		_play_appear_fx()


func _play_appear_fx() -> void:
	if _appear_fx_done:
		return
	_appear_fx_done = true
	if appear_particles != null:
		appear_particles.restart()
		appear_particles.emitting = true


# ── Steal ─────────────────────────────────────────────────────────────────────

func _on_steal_overlap(node: Node) -> void:
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	var player: Node = node
	if node is Area2D:
		player = node.get_parent()
	while player != null and not player.is_in_group(&"KillCharacter"):
		player = player.get_parent()
	if player == null or bool(player.get(&"is_dead")):
		return

	# Deal lunge damage + knockback once per lunge, whether or not there is a pip
	# to take. The hit is host-authoritative; the joiner sees it via the state
	# snapshot (player hp / position).
	if not _lunge_hit_done:
		_lunge_hit_done = true
		if lunge_damage > 0.0 and player.has_method(&"take_damage"):
			player.take_damage(lunge_damage, false, steal_weapon_type)
		if lunge_knockback > 0.0 and player.has_method(&"apply_knockback"):
			player.apply_knockback(global_position, lunge_knockback)

	if _steal_done or _stolen_stat != "":
		return
	_try_steal(player)


func _try_steal(player: Node) -> void:
	if player == null or not player.has_method(&"remove_random_stat_pip"):
		return
	_steal_done = true
	_set_hurtbox(false)
	var cat: String = player.remove_random_stat_pip()
	if cat == "":
		# Nothing to take — stay aggressive, allow further lunges to try again.
		_steal_done = false
		return
	_stolen_stat = cat
	_apply_weasel_buff(cat)
	_show_stolen_icon(cat)

	if GameManager.session_id != "" and GameManager.is_host:
		var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
		if rm != null and rm.has_method(&"_broadcast_stat_pips_for"):
			rm.call(&"_broadcast_stat_pips_for", player)
		WebRTCManager.send_reliable({
			"t": "weasel", "sub": "stole",
			"name": str(owner.name) if owner != null else str(name),
			"cat": cat,
		})


## Joiner: the host's weasel stole `cat` — mirror the buff + icon.
func on_stole_remote(cat: String) -> void:
	if _stolen_stat != "" or not cat in ICON_NODES:
		return
	_stolen_stat = cat
	_apply_weasel_buff(cat)
	_show_stolen_icon(cat)


func _apply_weasel_buff(cat: String) -> void:
	match cat:
		"hp":
			max_health *= hp_steal_health_mult
			health = max_health
			health_changed.emit(health, max_health)
		"speed":
			move_speed *= speed_steal_move_mult
		"attack":
			lunge_speed *= attack_steal_lunge_mult
			if detection_zone != null:
				for c in detection_zone.get_children():
					var cs := c as CollisionShape2D
					if cs != null and cs.shape is RectangleShape2D:
						var rect := cs.shape.duplicate() as RectangleShape2D
						rect.size *= attack_steal_detect_mult
						cs.shape = rect


func _show_stolen_icon(cat: String) -> void:
	for other: String in ICON_NODES:
		var icon := _icon_for(other)
		if icon != null:
			icon.visible = (other == cat)


## Hides every stat icon — called from die() so the stolen-stat marker vanishes
## the instant the weasel is killed (host and joiner both run die()).
func _hide_stolen_icons() -> void:
	for cat: String in ICON_NODES:
		var icon := _icon_for(cat)
		if icon != null:
			icon.hide()


func _icon_for(cat: String) -> CanvasItem:
	var pivot: Node = facing_pivot if facing_pivot != null else self
	return pivot.get_node_or_null(NodePath(ICON_NODES.get(cat, ""))) as CanvasItem


# ── Damage / death ────────────────────────────────────────────────────────────

func take_damage(amount: float, flow_success: bool = false,
		weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if _invulnerable:
		return
	super(amount, flow_success, weapon_type)


func die(flow_success: bool = false) -> void:
	if is_dead:
		return
	_lunge_active = false
	_set_hurtbox(false)
	_hide_stolen_icons()
	_spawn_stolen_chest()
	super(flow_success)


## Drops a treasureChest.tscn carrying the stolen stat — mirrors EnemyTower. Runs
## on host (normal death) and joiner (EnemySpawner.on_despawn_packet → die()); the
## deterministic name keeps the two copies correlated for RunManager open-routing.
func _spawn_stolen_chest() -> void:
	if _chest_dropped or _stolen_stat == "" or treasure_chest_scene == null:
		return
	_chest_dropped = true
	var chest := treasure_chest_scene.instantiate() as Node2D
	if chest == null:
		return
	var base_name: String = str(owner.name) if owner != null else str(name)
	chest.name = "WeaselChest_" + base_name
	var parent: Node = _find_level()
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		return
	parent.add_child(chest)
	chest.global_position = global_position + treasure_chest_offset
	if chest.has_method(&"set_forced_category"):
		chest.call(&"set_forced_category", _stolen_stat)


func _find_level() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node.has_method(&"on_entity_died"):
			return node
		node = node.get_parent()
	return null


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_hurtbox(enabled: bool) -> void:
	if steal_hurtbox == null:
		return
	steal_hurtbox.set_deferred(&"monitoring", enabled)
	steal_hurtbox.set_deferred(&"monitorable", enabled)


## Only players (KillCharacter group) in the detection zone — never the castle.
func _get_targets_in_range() -> Array:
	if detection_zone == null:
		return []
	var results: Array = []
	for body in detection_zone.get_overlapping_bodies():
		if body.is_in_group(&"KillCharacter") and not body.get("is_dead"):
			results.append(body)
	return results


func _nearest_of(nodes: Array) -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	for n in nodes:
		var nb := n as Node2D
		if nb == null:
			continue
		var d := global_position.distance_squared_to(nb.global_position)
		if d < best_dist:
			best_dist = d
			best = nb
	return best


func _get_nearest_player() -> Node2D:
	return _nearest_of(get_tree().get_nodes_in_group("KillCharacter").filter(
		func(p: Node) -> bool: return p is Node2D and not p.get("is_dead")))


# ── Walk area polygon constraint (mirrors sheepdog.gd / CharacterBase) ────────

func _constrain_to_walk_area() -> void:
	var xform: Transform2D = walk_area.global_transform
	var world_poly: PackedVector2Array = PackedVector2Array()
	for p in walk_area.polygon:
		world_poly.append(xform * p)

	var test_points: Array[Vector2] = _get_shape_test_points()

	var total_offset: Vector2 = Vector2.ZERO
	for tp in test_points:
		if Geometry2D.is_point_in_polygon(tp, world_poly):
			continue
		var best: Vector2 = tp
		var best_dist: float = INF
		for i in range(world_poly.size()):
			var a: Vector2 = world_poly[i]
			var b: Vector2 = world_poly[(i + 1) % world_poly.size()]
			var closest: Vector2 = _nearest_point_on_segment(tp, a, b)
			var d: float = tp.distance_squared_to(closest)
			if d < best_dist:
				best_dist = d
				best = closest
		var offset: Vector2 = best - tp
		if offset.length_squared() > total_offset.length_squared():
			total_offset = offset

	if total_offset != Vector2.ZERO:
		global_position += total_offset
		# Cancel only the into-wall component so the along-wall component
		# survives -- knockback and movement slide along the edge instead
		# of stopping dead.
		var wall_normal: Vector2 = total_offset.normalized()
		velocity -= wall_normal * minf(velocity.dot(wall_normal), 0.0)
		knockback_velocity -= wall_normal * minf(knockback_velocity.dot(wall_normal), 0.0)


func _get_shape_test_points() -> Array[Vector2]:
	if body_box == null or body_box.shape == null:
		return [global_position]
	var center: Vector2 = body_box.global_position
	if body_box.shape is RectangleShape2D:
		var half: Vector2 = (body_box.shape as RectangleShape2D).size / 2.0
		return [
			center + Vector2(-half.x, -half.y),
			center + Vector2( half.x, -half.y),
			center + Vector2( half.x,  half.y),
			center + Vector2(-half.x,  half.y),
		]
	elif body_box.shape is CapsuleShape2D:
		var cap: CapsuleShape2D = body_box.shape as CapsuleShape2D
		return [
			center + Vector2(0, -cap.height / 2.0),
			center + Vector2(0,  cap.height / 2.0),
			center + Vector2(-cap.radius, 0),
			center + Vector2( cap.radius, 0),
		]
	return [center]


func _nearest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq == 0.0:
		return a
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t

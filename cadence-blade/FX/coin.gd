extends Area2D

# coin.gd — Collectible coin dropped by enemies on death.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   Area2D             (this script — root)
#   ├── Sprite2D       — assign your coin texture here
#   └── CollisionShape2D — small circle, set collision layer to match player layer
#
# Save as res://FX/Coin.tscn and assign to level.gd's coin_scene export.
# The Area2D collision mask must include the player's physics layer so that
# body_entered fires when the CharacterBody2D (player) overlaps.
#
# ── BEHAVIOUR ─────────────────────────────────────────────────────────────────
#   When any CharacterBase (player) overlaps the coin:
#     • add_coins(1) is called on the player → emits coins_changed signal.
#     • The coin queues itself for deletion.
#   Hut priests fetch coins instead of touching them: they find live coins via
#   the "coins" group and call try_collect() on arrival.
#   After `lifetime` seconds the coin auto-despawns if uncollected.

## Seconds before the coin auto-despawns if the player never picks it up.
@export var lifetime: float = 15.0
## How many coins this pickup is worth.
@export var coin_value: int = 1
## When true, non-looping coin animations hold on the final frame.
@export var freeze_on_last_frame: bool = true
## Sound played when a player collects this coin.
@export var pickup_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var pickup_sound_volume_db: float = 0.0
## Speed the coin pops away from its drop point at, in a random direction.
@export var pop_speed: float = 20.0

@onready var animated_sprite: AnimatedSprite2D = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
var _pickup_audio: AudioStreamPlayer2D = null
## Set the moment collection starts, so a second collector (or a priest racing
## a player) can't bank the same coin twice during the pickup-sound delay.
var _collected: bool = false
## Random per-spawn pop velocity; zeroed out once the spawn animation ends.
var _velocity: Vector2 = Vector2.ZERO
## Lazily fetched — the level's walkable-area boundary, if any (see EnemyNavigation).
var _walk_area: Polygon2D = null


func _ready() -> void:
	if pickup_sound != null:
		_pickup_audio = AudioStreamPlayer2D.new()
		_pickup_audio.stream = pickup_sound
		_pickup_audio.volume_db = pickup_sound_volume_db
		_pickup_audio.bus = &"SFX"
		add_child(_pickup_audio)
	add_to_group(&"coins")  # so hut priests can find coins to fetch
	body_entered.connect(_on_body_entered)
	_velocity = Vector2.RIGHT.rotated(randf_range(0.0, TAU)) * pop_speed
	if animated_sprite != null:
		animated_sprite.animation_finished.connect(_on_animation_finished)
		if not animated_sprite.is_playing():
			animated_sprite.play(&"default")
	get_tree().create_timer(lifetime).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _process(delta: float) -> void:
	if _velocity == Vector2.ZERO:
		return
	if _walk_area == null:
		_walk_area = EnemyNavigation.find_walk_area(get_tree())
	global_position += _velocity * delta
	if _walk_area != null and not EnemyNavigation.is_inside(_walk_area, global_position):
		_bounce_off_walk_area()


## Pushes the coin back onto the walk_area boundary and reflects its pop
## velocity off the edge it hit, so it bounces along the path instead of
## flying past the level's walkable bounds.
func _bounce_off_walk_area() -> void:
	var world_poly: PackedVector2Array = EnemyNavigation.world_polygon(_walk_area)
	var best_point: Vector2 = global_position
	var best_dist: float = INF
	var best_normal: Vector2 = Vector2.ZERO
	for i in range(world_poly.size()):
		var a: Vector2 = world_poly[i]
		var b: Vector2 = world_poly[(i + 1) % world_poly.size()]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(global_position, a, b)
		var d: float = global_position.distance_squared_to(closest)
		if d < best_dist:
			best_dist = d
			best_point = closest
			var edge: Vector2 = (b - a).normalized()
			best_normal = Vector2(-edge.y, edge.x)
	global_position = best_point
	if best_normal != Vector2.ZERO:
		_velocity = _velocity.bounce(best_normal)


func _on_body_entered(body: Node2D) -> void:
	if body is CharacterBase:
		try_collect()


## Banks this coin for the shared player pool and despawns it. Safe to call from
## anything that reaches the coin (player overlap, priest fetch); repeat calls
## and joiner-side calls are ignored. Returns true if this call banked the coin.
func try_collect() -> bool:
	if _collected:
		return false
	# Guard: joiner should not collect coins directly — host is authoritative.
	if GameManager.session_id != "" and not GameManager.is_host:
		return false
	# Add coins to every local player so the pool is shared.
	_distribute_coins()
	# Tell the joiner to add the same amount and remove their display coin.
	if GameManager.session_id != "":
		var coin_id: int = int(get_meta(&"coin_id", -1))
		WebRTCManager.send_reliable({"t": "coins_add", "v": coin_value, "coin_id": coin_id})
	_collect()
	return true


## True while this coin is still on the ground and worth walking to.
func is_available() -> bool:
	return not _collected


func _distribute_coins() -> void:
	# Coins are a single shared party pool (GameManager.coin_balance) — add once.
	GameManager.add_coins(coin_value)


func _collect() -> void:
	# Also covers the joiner's despawn_display_coin() path, which calls straight
	# in here, so is_available() is honest on both sides.
	_collected = true
	# Hide visuals immediately so the coin looks gone.
	if animated_sprite != null:
		animated_sprite.hide()
	set_deferred(&"monitoring", false)
	set_deferred(&"monitorable", false)
	if _pickup_audio != null and _pickup_audio.stream != null:
		_pickup_audio.global_position = global_position
		_pickup_audio.play()
		# Free the node once the sound finishes; fall back to a short timer.
		var dur: float = _pickup_audio.stream.get_length() + 0.05
		get_tree().create_timer(dur).timeout.connect(queue_free, CONNECT_ONE_SHOT)
	else:
		queue_free()


func _on_animation_finished() -> void:
	_velocity = Vector2.ZERO
	if not freeze_on_last_frame or animated_sprite == null:
		return
	if animated_sprite.sprite_frames == null:
		return
	var anim: StringName = animated_sprite.animation
	if animated_sprite.sprite_frames.get_animation_loop(anim):
		return
	var frame_count: int = animated_sprite.sprite_frames.get_frame_count(anim)
	if frame_count <= 0:
		return
	animated_sprite.pause()
	animated_sprite.frame = frame_count - 1

class_name Castle
extends StaticBody2D

# castle.gd — The castle: takes damage from enemies, fades when the player enters.
#
# SCENE STRUCTURE:
#   StaticBody2D          (this script — the root IS the attackable body)
#   ├── CollisionShape2D               (body shape for enemy detection & hit signals)
#   ├── Sprite2D "CastleSprite"        (main castle art — assign to castle_sprite)
#   ├── Node2D   "HPBar"               (attach horizontal_health_bar.gd — assign to health_bar)
#   └── Area2D   "InsideZone"          (doorway interior trigger — assign to inside_zone)
#       └── CollisionShape2D
#
# ENEMIES:
#   The castle is in the "Kill" group, so any enemy using EnemyBase._get_targets_in_range()
#   will detect and attack it. When the slash hitbox fires body_entered, has_method("take_damage")
#   returns true and damage flows through. The castle has no apply_knockback(), so enemies
#   skip that call safely — the castle never moves.
#
# FADE BEHAVIOUR:
#   While the player overlaps inside_zone AND their Y (in castle-local space) is
#   less than y_fade_threshold, castle_sprite fades to transparent.
#   Stepping back out fades it to fully opaque.  Tune y_fade_threshold so that it
#   sits at the doorway floor — anything above that line is "inside".


# ── Health ────────────────────────────────────────────────────────────────────

@export_group("Health")
@export var max_health: float = 500.0
## Drag a Node2D with horizontal_health_bar.gd attached here.
@export var health_bar: Node2D
## HP restored per minute while the castle is alive. Set to 0 to disable regen.
@export var regen_per_minute: float = 10.0

# ── Fade ──────────────────────────────────────────────────────────────────────

@export_group("Death")
## Optional AnimationPlayer on the castle that plays a "death" animation
## when the castle HP reaches zero.  Leave blank until you create the animation.
@export var death_animation_player: AnimationPlayer

@export_group("Fade")
## The Sprite2D whose opacity is modulated (the main castle sprite on top).
@export var castle_sprite: Sprite2D
## Area2D covering the castle interior / doorway.
## The player must overlap this zone AND satisfy the Y check to trigger the fade.
@export var inside_zone: Area2D
## Castle-local Y threshold for the "inside" check.
## In Godot screen space Y increases downward, so "above the doorway" means
## the player's local Y is LESS THAN this value.
## Position the inside_zone in the scene then read off its local Y to pick a good value.
@export var y_fade_threshold: float = -50.0
## Fade speed in units of opacity per second  (1.0 = full fade in one second).
@export var fade_speed: float = 4.0

# ── Runtime ───────────────────────────────────────────────────────────────────

var health: float = 0.0
var _health_bar_api: Node = null
var _died_emitted: bool = false

signal health_changed(new_health: float, max_hp: float)
signal died()


func _ready() -> void:
	health = max_health
	add_to_group(&"Kill")
	_health_bar_api = _resolve_bar_api(health_bar)
	health_changed.connect(_on_health_changed)
	_on_health_changed(health, max_health)


func _process(delta: float) -> void:
	if castle_sprite == null or inside_zone == null:
		return
	var target_alpha := 0.0 if _player_is_inside() else 1.0
	var c := castle_sprite.modulate
	c.a = move_toward(c.a, target_alpha, fade_speed * delta)
	castle_sprite.modulate = c
	_regen_health(delta)


func _regen_health(delta: float) -> void:
	# Regen is host-authoritative in multiplayer (castle HP is broadcast via state snapshot).
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	if regen_per_minute <= 0.0 or health <= 0.0 or health >= max_health:
		return
	health = minf(health + regen_per_minute / 60.0 * delta, max_health)
	health_changed.emit(health, max_health)


# ── Inside check ──────────────────────────────────────────────────────────────

func _player_is_inside() -> bool:
	for body in inside_zone.get_overlapping_bodies():
		# CharacterBase is the base class for all playable characters.
		# EnemyBase characters won't trigger the fade.
		if body is CharacterBase:
			if to_local(body.global_position).y < y_fade_threshold:
				return true
	return false


# ── Damage ────────────────────────────────────────────────────────────────────

func take_damage(amount: float) -> void:
	# Castle health is host-authoritative. Joiner enemies have physics disabled so
	# this should only fire on the host, but guard defensively.
	if GameManager.session_id != "" and not GameManager.is_host:
		return
	if health <= 0.0:
		return
	health = maxf(0.0, health - amount)
	health_changed.emit(health, max_health)
	# Health is broadcast to joiner via the state snapshot (run_manager._broadcast_state).
	if health == 0.0:
		_on_died()



func _on_died() -> void:
	if _died_emitted:
		return
	_died_emitted = true
	# Play the death animation if one has been assigned in the Inspector.
	if death_animation_player != null:
		death_animation_player.play(&"death")
	# Gameplay consequences (game over, respawn stoppage, etc.) are handled
	# by RunManager listening to this signal.
	died.emit()


# ── Internals ─────────────────────────────────────────────────────────────────

func _on_health_changed(new_hp: float, max_hp: float) -> void:
	if _health_bar_api != null:
		_health_bar_api.set_health(new_hp, max_hp)


func _resolve_bar_api(bar: Node) -> Node:
	if bar == null:
		return null
	if bar.has_method(&"set_health"):
		return bar
	return null

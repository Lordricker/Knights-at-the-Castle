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
#   After `lifetime` seconds the coin auto-despawns if uncollected.

## Seconds before the coin auto-despawns if the player never picks it up.
@export var lifetime: float = 15.0
## How many coins this pickup is worth.
@export var coin_value: int = 1
## When true, non-looping coin animations hold on the final frame.
@export var freeze_on_last_frame: bool = true

@onready var animated_sprite: AnimatedSprite2D = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	if animated_sprite != null:
		animated_sprite.animation_finished.connect(_on_animation_finished)
		if not animated_sprite.is_playing():
			animated_sprite.play(&"default")
	get_tree().create_timer(lifetime).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _on_body_entered(body: Node2D) -> void:
	if body is CharacterBase:
		(body as CharacterBase).add_coins(coin_value)
		queue_free()


func _on_animation_finished() -> void:
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

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


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	get_tree().create_timer(lifetime).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _on_body_entered(body: Node2D) -> void:
	if body is CharacterBase:
		(body as CharacterBase).add_coins(1)
		queue_free()

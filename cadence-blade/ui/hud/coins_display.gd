extends Label

# coins_display.gd — HUD label showing the player's current coin count.
#
# ── SCENE STRUCTURE ───────────────────────────────────────────────────────────
#   CanvasLayer
#   └── Label  (this script)
#
# ── HOW TO USE ────────────────────────────────────────────────────────────────
#   1. Add a Label node to your HUD CanvasLayer.
#   2. Attach this script to it.
#   3. The script auto-finds the first player in the "players" group and
#      connects to their coins_changed signal.
#   4. Assign this node to CastleInside's coins_display export so flash_insufficient()
#      can be called when a purchase attempt fails.
#
# ── INSUFFICIENT FUNDS ANIMATION ─────────────────────────────────────────────
#   flash_insufficient() sets the label red instantly, tweens the scale from 1→1.35→1,
#   then fades the colour back to white.  The pivot is centred each frame so the
#   label grows from its centre regardless of anchor position.

var _connected: bool = false


func _ready() -> void:
	text = "Coins: 0"
	_try_connect_player()


func _process(_delta: float) -> void:
	# Retry every frame until the player enters the scene tree.
	if not _connected:
		_try_connect_player()


func _try_connect_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group(&"players")
	for p: Node in players:
		if p.has_signal(&"coins_changed"):
			p.coins_changed.connect(_on_coins_changed)
			# Read current value immediately if the property exists.
			if "coins" in p:
				_on_coins_changed(int(p.coins))
			_connected = true
			return


func _on_coins_changed(new_coins: int) -> void:
	text = "Coins: %d" % new_coins


## Called by CastleInside when the player cannot afford an upgrade.
## Flashes the label red and briefly enlarges it, then returns to normal.
func flash_insufficient() -> void:
	# Centre the scale pivot so the label grows outwards from its own centre.
	pivot_offset = size / 2.0
	modulate = Color.RED
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2(1.35, 1.35), 0.12).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.2).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "modulate", Color.WHITE, 0.15)

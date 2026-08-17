class_name DamageNumber
extends Label

## Floating damage number popup.
## Spawn via DamageNumber.spawn_at() — do not add to the scene manually.

func setup(amount: float) -> void:
	text = str(roundi(amount))
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_theme_font_size_override("font_size", 18)
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	add_theme_constant_override("outline_size", 3)
	# Draw above all world/castle art regardless of tree order (level z_index tops out at 4).
	z_index = 4096
	z_as_relative = false


func start_animation() -> void:
	# Jump up 55px decelerating to a stop, then fade out.
	var target_y := position.y - 40.0
	var pos_tween := create_tween()
	pos_tween.tween_property(self, "position:y", target_y, 0.6) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var fade_tween := create_tween()
	fade_tween.tween_interval(0.45)
	fade_tween.tween_property(self, "modulate:a", 0.0, 0.25)
	fade_tween.tween_callback(queue_free)


## Instantiate and animate a damage number at the given world position.
## Pass the scene root (or any persistent parent) as `parent`.
static func spawn_at(parent: Node, world_pos: Vector2, amount: float) -> void:
	var dn := DamageNumber.new()
	dn.setup(amount)
	parent.add_child(dn)
	dn.global_position = world_pos + Vector2(randf_range(-8.0, 8.0), -40.0)
	dn.start_animation()

class_name PodiumPlace
extends Control

# podium_place.gd — One spot on the game-over podium: a player's kill count plus an
# idle-animated copy of their character.
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Attach to a Control placed on the podium. Give it two children and wire the exports:
#     • kills_label      — Label, filled with "Kills - N"
#     • character_sprite — AnimatedSprite2D. Position / scale / flip it in the editor;
#                          only its frames are assigned at runtime, so it draws nothing
#                          in the editor until the game-over screen runs.

@export var kills_label: Label
@export var character_sprite: AnimatedSprite2D
## Animation played on character_sprite.
@export var idle_animation: StringName = &"idle"


## Fill this spot in and show it. character_scene is the PackedScene of the player's
## character (a null scene just leaves the sprite empty).
func show_entry(kills: int, character_scene: PackedScene) -> void:
	if kills_label != null:
		kills_label.text = "Kills - %d" % kills
	_show_character(character_scene)
	show()


func _show_character(character_scene: PackedScene) -> void:
	if character_sprite == null:
		return
	character_sprite.hide()
	if character_scene == null:
		return
	# Borrow the frames from the real player scene so art changes are picked up
	# automatically. Never added to the tree, so no _ready / gameplay code runs.
	var root: Node = character_scene.instantiate()
	var source := root.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
	if source != null and source.sprite_frames != null \
			and source.sprite_frames.has_animation(idle_animation):
		character_sprite.sprite_frames = source.sprite_frames
		character_sprite.centered = source.centered
		# Each character scene parks its sprite at a different spot relative to the
		# character origin (the rogue's is far off-centre). Keep that as a draw offset
		# so all three characters sit consistently around this node's position.
		character_sprite.offset = source.offset + source.position
		character_sprite.show()
		character_sprite.play(idle_animation)
	root.free()

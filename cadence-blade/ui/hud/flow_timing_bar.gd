class_name FlowTimingBar
extends Node2D

# flow_timing_bar.gd — Masked timing bar for the attack pause window mechanic.
#
# HOW TO USE:
#   1. Add a Node2D to the player scene. Name it "FlowBar". Attach this script.
#   2. Add a Sprite2D as a child. Assign your white fill-area mask PNG as its texture.
#      Same idea as the health bar: WHITE = fill visible, TRANSPARENT = blocked.
#   3. In the Inspector, drag that Sprite2D into the "Fill Window" slot.
#   4. Place your container frame art separately however you like.
#
# HOW MASKING WORKS:
#   The script sets clip_children = CLIP_CHILDREN_ONLY on the fill_window sprite.
#   All fill drawing is clipped to the non-transparent pixels of your PNG shape.
#   The white PNG itself is invisible — only the color fill shows through.
#
# FLOW LIFECYCLE:
#   start_flow()        → show fill, reset, yellow fill begins rising
#   advance(delta, dur) → call every physics frame; returns true when bar reaches top
#   try_attempt()       → call once on button press; returns SUCCESS / MISS / NONE
#   mark_missed()       → call when bar auto-completes; fill turns grey
#   stop_flow()         → hide fill, reset state

enum AttemptResult {
	NONE,    ## Button not pressed, or one attempt already used.
	SUCCESS, ## Pressed inside the green zone — execute immediately, full damage.
	MISS,    ## Pressed outside the green zone — bar keeps filling, reduced damage on finish.
}

@export_group("Fill Window")
## Drag your white fill-area mask Sprite2D here.
@export var fill_window: Sprite2D

@export_group("Success Window")
## Normalized position (0 = bottom, 1 = top) where the green zone starts.
@export_range(0.0, 1.0, 0.01) var success_window_start: float = 0.45
## Normalized position (0 = bottom, 1 = top) where the green zone ends.
@export_range(0.0, 1.0, 0.01) var success_window_end: float = 0.60
## How much wider the invisible hit detection zone is compared to the visible green zone,
## expressed as a fraction of the zone's width. 0.1 = 10% wider (5% added to each edge).
@export_range(0.0, 0.5, 0.01) var hit_window_expand: float = 0.1

@export_group("Colors")
## Fill color while the player hasn't pressed yet.
@export var waiting_fill_color: Color = Color(0.95, 0.85, 0.2, 1.0)
## Fill color after pressing outside the zone (miss).
@export var missed_fill_color: Color = Color(0.5, 0.5, 0.5, 1.0)
## Fill color shown briefly on a successful press.
@export var success_fill_color: Color = Color(0.3, 1.0, 0.45, 1.0)
## Color of the success zone band.
@export var success_zone_color: Color = Color(0.2, 0.95, 0.25, 0.55)
@export var background_color: Color = Color(0.06, 0.06, 0.06, 0.75)

@export_group("Behaviour")
## Hide the fill visuals when no attack is in the pause state.
@export var hide_when_inactive: bool = true

var _active: bool = false
var _progress: float = 0.0
var _attempt_used: bool = false
var _current_fill_color: Color
var _draw_node: Node2D


func _ready() -> void:
	_current_fill_color = waiting_fill_color
	if fill_window == null:
		push_error(name + ": fill_window is not assigned in the Inspector.")
		return
	fill_window.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_draw_node = Node2D.new()
	fill_window.add_child(_draw_node)
	_draw_node.draw.connect(_on_draw_fill)
	if hide_when_inactive:
		fill_window.hide()
	_redraw()


# ── Public API ─────────────────────────────────────────────────────────────────

## Show the fill and start a fresh flow sequence.
func start_flow() -> void:
	_active = true
	_progress = 0.0
	_attempt_used = false
	_current_fill_color = waiting_fill_color
	if fill_window != null:
		fill_window.show()
	_redraw()


## Hide the fill and reset all state. Call after the attack fully resolves.
func stop_flow() -> void:
	_active = false
	_progress = 0.0
	_attempt_used = false
	_current_fill_color = waiting_fill_color
	if hide_when_inactive and fill_window != null:
		fill_window.hide()
	_redraw()


## Advance the fill. Call every physics frame while active.
## Returns true once the bar has reached the top.
func advance(delta: float, fill_duration: float) -> bool:
	if not _active:
		return false
	_progress = clampf(_progress + delta / maxf(fill_duration, 0.001), 0.0, 1.0)
	_redraw()
	return _progress >= 1.0


## Call once when the player presses the attack button during the pause.
## Only one attempt is allowed per flow sequence — subsequent presses return NONE.
func try_attempt() -> AttemptResult:
	if not _active or _attempt_used:
		return AttemptResult.NONE
	_attempt_used = true
	var zone_half := (success_window_end - success_window_start) * 0.5
	var zone_center := (success_window_start + success_window_end) * 0.5
	var detect_half := zone_half * (1.0 + hit_window_expand)
	if _progress >= zone_center - detect_half and _progress <= zone_center + detect_half:
		_current_fill_color = success_fill_color
		_redraw()
		return AttemptResult.SUCCESS
	# Pressed outside — turn grey. Bar keeps filling until auto-resolve.
	_current_fill_color = missed_fill_color
	_redraw()
	return AttemptResult.MISS


## Called when the bar reaches the top with no prior success. Turns fill grey.
func mark_missed() -> void:
	_current_fill_color = missed_fill_color
	_redraw()


## Joiner display-only sync. Shows the bar and sets visual progress without
## running the timing loop or consuming an attempt. Call every state snapshot.
## ws/we: normalized window start/end (-1 = keep current). missed: show grey fill.
func display_sync(progress: float, ws: float = -1.0, we: float = -1.0, missed: bool = false) -> void:
	_active = true
	_progress = clampf(progress, 0.0, 1.0)
	if ws >= 0.0:
		success_window_start = ws
	if we >= 0.0:
		success_window_end = we
	if missed:
		_current_fill_color = missed_fill_color
	else:
		# Only reset to yellow if the bar hasn't been marked missed yet.
		if _current_fill_color != missed_fill_color:
			_current_fill_color = waiting_fill_color
	if fill_window != null:
		fill_window.show()
	_redraw()


# ── Internal ───────────────────────────────────────────────────────────────────

func _redraw() -> void:
	if _draw_node != null:
		_draw_node.queue_redraw()


# Returns the fill_window sprite's bounds in its own local space,
# accounting for the centered flag and offset property.
func _get_local_bounds() -> Rect2:
	if fill_window == null or fill_window.texture == null:
		return Rect2(Vector2(-10.0, -30.0), Vector2(20.0, 30.0))
	var sz := fill_window.texture.get_size()
	var off := fill_window.offset
	if fill_window.centered:
		return Rect2(-sz * 0.5 + off, sz)
	return Rect2(off, sz)


func _on_draw_fill() -> void:
	var b := _get_local_bounds()
	var left := b.position.x
	var top_y := b.position.y   # visually highest point (lowest Y in 2D)
	var bot_y := b.end.y        # visually lowest point (highest Y in 2D)
	var tw := b.size.x
	var th := b.size.y

	# Background — fills the entire window area.
	_draw_node.draw_rect(b, background_color)

	# Success zone — fixed band at the configured normalized height.
	# Value v (0=bottom, 1=top) maps to local y: bot_y - v * th
	if success_window_end > success_window_start:
		var zone_top_y := bot_y - success_window_end * th
		var zone_h := (success_window_end - success_window_start) * th
		_draw_node.draw_rect(
			Rect2(Vector2(left, zone_top_y), Vector2(tw, zone_h)),
			success_zone_color
		)

	# Fill — rises from the visual bottom upward.
	var filled_h := th * _progress
	if filled_h > 0.0:
		_draw_node.draw_rect(
			Rect2(Vector2(left, bot_y - filled_h), Vector2(tw, filled_h)),
			_current_fill_color
		)

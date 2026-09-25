# loading_label.gd
# Attach to a Label. Any text ending in one or more "." animates its trailing
# dots, looping ".", "..", "..." on a fixed cadence. Text with no trailing dots
# is shown verbatim. Callers just assign `.text` as usual — e.g. "Loading..."
# or "Connecting..." animate, "Session is full." does not.

extends Label

## Seconds each dot count stays on screen before advancing.
const CYCLE_SECONDS: float = 0.4

var _base: String = ""          # text with the trailing dots stripped off
var _animating: bool = false
var _dot_count: int = 1
var _timer: float = 0.0
var _last_written: String = ""  # the last value THIS script assigned to `text`


func _process(delta: float) -> void:
	# Pick up any change to `text` made from outside this script.
	if text != _last_written:
		_adopt(text)

	if not _animating:
		return

	_timer += delta
	if _timer < CYCLE_SECONDS:
		return
	_timer = 0.0
	_dot_count = _dot_count % 3 + 1
	_render()


## Parse a freshly-assigned text value and decide whether to animate it.
func _adopt(new_text: String) -> void:
	var stripped: String = new_text
	while stripped.ends_with("."):
		stripped = stripped.substr(0, stripped.length() - 1)

	if stripped.length() < new_text.length() and stripped.strip_edges() != "":
		_base = stripped
		_animating = true
		_dot_count = 1
		_timer = 0.0
		_render()
	else:
		_animating = false
		_last_written = new_text


func _render() -> void:
	_last_written = _base + ".".repeat(_dot_count)
	text = _last_written

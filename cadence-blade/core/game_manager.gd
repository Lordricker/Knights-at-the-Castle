extends Node

# GameManager — global game state autoload
# Register in: Project > Project Settings > Autoload > Name: "GameManager"

enum GameState {
	MENU,
	PLAYING,
	PAUSED,
	GAME_OVER,
}

var current_state: GameState = GameState.MENU
var active_players: Array = []
var current_level_variant: String = "day"  # "day", "night", "dusk"

signal state_changed(new_state: GameState)

# ── High score ─────────────────────────────────────────────────────────────────
# Best survival time in seconds. Higher = better.
# Stored in localStorage on web builds; ConfigFile on desktop.

var best_time: float = 0.0

const _HS_KEY: String = "cadence_blade_best_time"


func _ready() -> void:
	_load_best_time()


func change_state(new_state: GameState) -> void:
	current_state = new_state
	state_changed.emit(new_state)


func set_level_variant(variant: String) -> void:
	current_level_variant = variant


## Submit a completed run time. Persists if it beats the existing best.
## Returns true when a new high score is set.
func submit_time(t: float) -> bool:
	if t <= best_time:
		return false
	best_time = t
	_save_best_time()
	return true


func _load_best_time() -> void:
	if OS.has_feature("web"):
		var val = JavaScriptBridge.eval(
			"(function(){ var v = localStorage.getItem('%s'); return v !== null ? v : ''; })()" % _HS_KEY
		)
		if typeof(val) == TYPE_STRING and val != "":
			best_time = float(val)
	else:
		var cfg := ConfigFile.new()
		if cfg.load("user://highscore.cfg") == OK:
			best_time = cfg.get_value("score", "best_time", 0.0)


func _save_best_time() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.setItem('%s', '%s');" % [_HS_KEY, str(best_time)])
	else:
		var cfg := ConfigFile.new()
		cfg.set_value("score", "best_time", best_time)
		cfg.save("user://highscore.cfg")

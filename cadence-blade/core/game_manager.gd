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


func _ready() -> void:
	pass


func change_state(new_state: GameState) -> void:
	current_state = new_state
	state_changed.emit(new_state)


func set_level_variant(variant: String) -> void:
	current_level_variant = variant

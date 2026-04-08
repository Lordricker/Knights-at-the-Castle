extends Node

# AudioManager — global music and SFX autoload
# Register in: Project > Project Settings > Autoload > Name: "AudioManager"

@onready var _music_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _sfx_player: AudioStreamPlayer = AudioStreamPlayer.new()

var music_volume_db: float = 0.0
var sfx_volume_db: float = 0.0


func _ready() -> void:
	add_child(_music_player)
	add_child(_sfx_player)
	_music_player.bus = "Music"
	_sfx_player.bus = "SFX"


## Play a music track. Pass a preloaded AudioStream resource.
func play_music(stream: AudioStream, fade_in: bool = false) -> void:
	_music_player.stream = stream
	_music_player.volume_db = music_volume_db
	_music_player.play()


## Stop currently playing music.
func stop_music() -> void:
	_music_player.stop()


## Play a one-shot SFX. Pass a preloaded AudioStream resource.
func play_sfx(stream: AudioStream) -> void:
	_sfx_player.stream = stream
	_sfx_player.volume_db = sfx_volume_db
	_sfx_player.play()


func set_music_volume(linear: float) -> void:
	music_volume_db = linear_to_db(clampf(linear, 0.0, 1.0))
	_music_player.volume_db = music_volume_db


func set_sfx_volume(linear: float) -> void:
	sfx_volume_db = linear_to_db(clampf(linear, 0.0, 1.0))

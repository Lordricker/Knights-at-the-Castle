extends Node

# AudioManager — global music and SFX autoload
# Register in: Project > Project Settings > Autoload > Name: "AudioManager"
#
# Volume is controlled by writing to the AudioServer bus so every
# AudioStreamPlayer / AudioStreamPlayer2D on that bus is affected — whether
# triggered locally or by a network packet on the joiner.

@onready var _music_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _sfx_player: AudioStreamPlayer = AudioStreamPlayer.new()

## Linear 0-1 values; persisted by the autoload across scene reloads.
var music_volume_linear: float = 1.0
var sfx_volume_linear: float = 0.6


func _ready() -> void:
	add_child(_music_player)
	add_child(_sfx_player)
	_music_player.bus = &"Music"
	_sfx_player.bus = &"SFX"
	# Apply defaults to AudioServer so the buses start at full volume.
	set_music_volume(music_volume_linear)
	set_sfx_volume(sfx_volume_linear)


## Play a music track. Pass a preloaded AudioStream resource.
func play_music(stream: AudioStream, fade_in: bool = false) -> void:
	_music_player.stream = stream
	_music_player.play()


## Stop currently playing music.
func stop_music() -> void:
	_music_player.stop()


## Play a one-shot SFX. Pass a preloaded AudioStream resource.
func play_sfx(stream: AudioStream) -> void:
	_sfx_player.stream = stream
	_sfx_player.play()


## Set music volume from a 0-1 linear value (e.g. from an HSlider).
## Drives the entire Music bus so all tracks are affected.
func set_music_volume(linear: float) -> void:
	music_volume_linear = clampf(linear, 0.0, 1.0)
	var idx := AudioServer.get_bus_index(&"Music")
	if idx >= 0:
		if music_volume_linear <= 0.0:
			AudioServer.set_bus_mute(idx, true)
		else:
			AudioServer.set_bus_mute(idx, false)
			AudioServer.set_bus_volume_db(idx, linear_to_db(music_volume_linear))


## Set SFX volume from a 0-1 linear value (e.g. from an HSlider).
## Drives the entire SFX bus so every AudioStreamPlayer2D is affected,
## including sounds triggered by network packets on the joiner.
func set_sfx_volume(linear: float) -> void:
	sfx_volume_linear = clampf(linear, 0.0, 1.0)
	var idx := AudioServer.get_bus_index(&"SFX")
	if idx >= 0:
		if sfx_volume_linear <= 0.0:
			AudioServer.set_bus_mute(idx, true)
		else:
			AudioServer.set_bus_mute(idx, false)
			AudioServer.set_bus_volume_db(idx, linear_to_db(sfx_volume_linear))

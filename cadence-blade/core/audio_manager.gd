extends Node

# AudioManager — global music and SFX autoload
# Register in: Project > Project Settings > Autoload > Name: "AudioManager"
#
# Volume is controlled by writing to the AudioServer bus so every
# AudioStreamPlayer / AudioStreamPlayer2D on that bus is affected — whether
# triggered locally or by a network packet on the joiner.
#
# Music has three independent players (menu / day / night) rather than one
# shared player. During gameplay, day and night both play continuously and
# are crossfaded via per-player volume_db driven by EnemySpawner's
# get_night_intensity() — the same 0..1 ramp that fades the screen tint — so
# the music transition matches the visual one and neither track ever stops
# or restarts, just fades under/over the other. See _process() below, which
# mirrors the polling pattern night_overlay.gd uses to read the night state.

const MENU_MUSIC: AudioStream = preload("res://assets/audio/music/Solar Fractals.mp3")
## Fixed attenuation applied only to the menu track, on top of the Music
## slider — the menu music reads as too loud relative to gameplay music.
const MENU_MUSIC_VOLUME_LINEAR: float = 0.5
const DAY_MUSIC: AudioStream = preload("res://assets/audio/music/Thunderdome.mp3")
const NIGHT_MUSIC: AudioStream = preload("res://assets/audio/music/Lunar Fractals.mp3")
## Fixed attenuation applied to the night track's "fully faded in" volume —
## Lunar Fractals reads as too loud relative to the day track at full crossfade.
const NIGHT_MUSIC_VOLUME_LINEAR: float = 0.5

## volume_db floor for the "faded out" side of the crossfade. -40dB reads as
## silent without relying on -INF (which linear_to_db(0) would produce).
const _SILENT_DB: float = -40.0

@onready var _menu_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _day_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _night_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _sfx_player: AudioStreamPlayer = AudioStreamPlayer.new()

## Linear 0-1 values; persisted by the autoload across scene reloads.
var music_volume_linear: float = 0.6
var sfx_volume_linear: float = 0.6

## Explicit on/off toggle (e.g. the main menu MUSIC/SFX buttons), independent
## of the slider level so un-muting restores the previous volume rather than
## jumping to 100%.
var music_muted: bool = false
var sfx_muted: bool = false

var _spawner: Node = null

## When true, _process()'s normal day/night crossfade is skipped and the night
## track is forced to full volume instead (e.g. while a tutorial panel is up).
var _forced_night: bool = false


func _ready() -> void:
	# Music (and set_forced_night) must keep working while the tree is paused —
	# e.g. a tutorial explanation panel, or the solo pause menu — otherwise Godot's
	# default PAUSABLE process_mode silences these players the instant paused=true,
	# regardless of volume_db.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for p in [_menu_player, _day_player, _night_player]:
		add_child(p)
		p.bus = &"Music"
	add_child(_sfx_player)
	_sfx_player.bus = &"SFX"

	_menu_player.stream = MENU_MUSIC
	_menu_player.volume_db = linear_to_db(MENU_MUSIC_VOLUME_LINEAR)
	_day_player.stream = DAY_MUSIC
	_night_player.stream = NIGHT_MUSIC
	for stream in [MENU_MUSIC, DAY_MUSIC, NIGHT_MUSIC]:
		if stream is AudioStreamMP3:
			stream.loop = true

	set_music_volume(music_volume_linear)
	set_sfx_volume(sfx_volume_linear)


func _process(_delta: float) -> void:
	# Only relevant once gameplay music is running.
	if not _day_player.playing and not _night_player.playing:
		return
	if _forced_night:
		_day_player.volume_db = _SILENT_DB
		_night_player.volume_db = linear_to_db(NIGHT_MUSIC_VOLUME_LINEAR)
		return
	if _spawner == null or not is_instance_valid(_spawner):
		_spawner = get_tree().get_first_node_in_group(&"enemy_spawner")
	if _spawner == null or not _spawner.has_method(&"get_night_intensity"):
		return
	var intensity: float = _spawner.get_night_intensity()
	_day_player.volume_db = lerpf(0.0, _SILENT_DB, intensity)
	_night_player.volume_db = lerpf(_SILENT_DB, linear_to_db(NIGHT_MUSIC_VOLUME_LINEAR), intensity)


## Forces the night track to full volume (and day to silent) regardless of the
## real day/night cycle — e.g. while a tutorial explanation panel is up. Pass
## false to hand control back to the normal crossfade next frame.
func set_forced_night(enabled: bool) -> void:
	_forced_night = enabled
	if enabled:
		_day_player.volume_db = _SILENT_DB
		_night_player.volume_db = linear_to_db(NIGHT_MUSIC_VOLUME_LINEAR)


## Start (or resume) the main menu theme. Stops gameplay music.
func play_menu_music() -> void:
	stop_gameplay_music()
	if _menu_player.stream and not _menu_player.playing:
		_menu_player.play()


## Start the day/night gameplay music from the beginning of a run. Both
## tracks play continuously from here on — only their volume crossfades —
## so neither ever restarts partway through a run.
func start_gameplay_music() -> void:
	_menu_player.stop()
	if _day_player.stream:
		_day_player.volume_db = 0.0
		_day_player.play()
	if _night_player.stream:
		_night_player.volume_db = _SILENT_DB
		_night_player.play()


## Stop day/night gameplay music entirely (e.g. leaving to the main menu).
func stop_gameplay_music() -> void:
	_day_player.stop()
	_night_player.stop()


## Play a one-shot SFX. Pass a preloaded AudioStream resource.
func play_sfx(stream: AudioStream, volume_db: float = 0.0) -> void:
	_sfx_player.stream = stream
	_sfx_player.volume_db = volume_db
	_sfx_player.play()


## Set music volume from a 0-1 linear value (e.g. from an HSlider).
## Drives the entire Music bus so all tracks are affected.
func set_music_volume(linear: float) -> void:
	music_volume_linear = clampf(linear, 0.0, 1.0)
	_apply_music_bus_state()


## Set SFX volume from a 0-1 linear value (e.g. from an HSlider).
## Drives the entire SFX bus so every AudioStreamPlayer2D is affected,
## including sounds triggered by network packets on the joiner.
func set_sfx_volume(linear: float) -> void:
	sfx_volume_linear = clampf(linear, 0.0, 1.0)
	_apply_sfx_bus_state()


## Explicitly mute/unmute music (e.g. the main menu MUSIC button), independent
## of music_volume_linear — unmuting restores whatever level was set before.
func set_music_muted(muted: bool) -> void:
	music_muted = muted
	_apply_music_bus_state()


## Explicitly mute/unmute SFX (e.g. the main menu SFX button), independent
## of sfx_volume_linear — unmuting restores whatever level was set before.
func set_sfx_muted(muted: bool) -> void:
	sfx_muted = muted
	_apply_sfx_bus_state()


func _apply_music_bus_state() -> void:
	var idx := AudioServer.get_bus_index(&"Music")
	if idx < 0:
		return
	var silent := music_muted or music_volume_linear <= 0.0
	AudioServer.set_bus_mute(idx, silent)
	if not silent:
		AudioServer.set_bus_volume_db(idx, linear_to_db(music_volume_linear))


func _apply_sfx_bus_state() -> void:
	var idx := AudioServer.get_bus_index(&"SFX")
	if idx < 0:
		return
	var silent := sfx_muted or sfx_volume_linear <= 0.0
	AudioServer.set_bus_mute(idx, silent)
	if not silent:
		AudioServer.set_bus_volume_db(idx, linear_to_db(sfx_volume_linear))

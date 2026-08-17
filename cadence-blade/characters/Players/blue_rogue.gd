extends CharacterBase

# blue_rogue.gd — playable Blue Rogue character.
#
# INPUT ACTIONS (Project > Project Settings > Input Map):
#   "move_right" → D     "move_left" → A
#   "move_up"    → W     "move_down" → S
#   "slash"      → J     "smash"     → K     "dash" → L
#
# ANIMATIONS (AnimatedSprite2D SpriteFrames):
#   "idle" — loop ON
#   "run"  — loop ON
#   "slash" — loop OFF
#   "smash" — loop OFF
#   "dash"  — loop OFF
#
# SCENE STRUCTURE:
#   CharacterBody2D  (this script)
#   ├── AnimatedSprite2D
#   ├── CollisionShape2D
#   ├── SlashHitbox  (Area2D — single flow check)
#   │   └── CollisionShape2D
#   ├── DashHitbox   (Area2D — double flow check, stationary)
#   │   └── CollisionShape2D
#   ├── SmashHitbox  (Area2D — single flow check, steps forward mid-swing)
#   │   └── CollisionShape2D
#   ├── HealthBar    (Node2D — attach ui/hud/vertical_health_bar.gd)
#   └── FlowBar      (Node2D — attach ui/hud/flow_timing_bar.gd)

# ── Constants ─────────────────────────────────────────────────────────────────

const DASH_FLOW_CHECK_COUNT: int = 2

# ── Attack state machine ───────────────────────────────────────────────────────

enum AttackState {
	NONE,
	SLASH_WINDUP,
	SLASH_PAUSED,
	SLASH_FINISH,
	SMASH_WINDUP,
	SMASH_PAUSED,
	SMASH_FINISH,
	DASH_WINDUP,
	DASH_PAUSED,
	DASH_FINISH,
}

var attack_state: AttackState = AttackState.NONE
var _slash_effect_pending_hide: bool = false
var _dash_flow_checks_completed: int = 0
# True once the smash hitbox has stepped forward for the current swing.
var _smash_advanced: bool = false


# ── Slash Attack ──────────────────────────────────────────────────────────────

@export_group("Slash Attack")
## Base damage dealt by a slash attack.
@export var slash_damage: float = 30.0
## Knockback force applied to enemies hit by a slash.
@export var slash_knockback_force: float = 400.0
## Animation frame indices during which the slash hitbox is active.
@export var slash_hitbox_frames: Array[int] = [4, 8]
## Animation frame at which the slash pauses to await the flow check.
@export var slash_pause_frame: int = 2
## Seconds for the flow bar to fill during the slash pause.
@export var slash_flow_fill_duration: float = 0.45
## Damage multiplier when the slash bar auto-resolves (missed timing).
@export var slash_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var slash_flow_window_center: float = 0.5
## Half-width of the green zone. Window spans [center - half, center + half].
@export_range(0.0, 0.5, 0.01) var slash_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each slash.
@export_range(0.0, 0.5, 0.01) var slash_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time (x=0 fresh, x=1 tired).
## Overrides the fixed half-size above when assigned.
@export var slash_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var slash_flow_window_curve_max_time: float = 60.0
## Sound played when a slash begins.
@export var slash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var slash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the slash swing sound.
@export var slash_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the slash.
@export var slash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD

# ── Smash Attack ──────────────────────────────────────────────────────────────

@export_group("Smash Attack")
## Base damage dealt by a smash attack.
@export var smash_damage: float = 45.0
## Knockback force applied to enemies hit by a smash.
@export var smash_knockback_force: float = 400.0
## Animation frame indices during which the smash hitbox is active.
@export var smash_hitbox_frames: Array[int] = [5, 6]
## Animation frame at which the smash pauses to await the flow check.
@export var smash_pause_frame: int = 3
## Animation frame at which the smash hitbox steps forward.
@export var smash_advance_frame: int = 5
## Pixels the smash hitbox steps forward at smash_advance_frame.
@export var smash_advance_distance: float = 20.0
## Animation frame indices during which the root z_index is boosted (so the jump-in
## doesn't clip behind the castle).
@export var smash_z_boost_frames: Array[int] = [3, 4, 5]
## Amount added to the root node's z_index during smash_z_boost_frames.
@export var smash_z_index_boost: int = 5
## Seconds for the flow bar to fill during the smash pause.
@export var smash_flow_fill_duration: float = 0.45
## Damage multiplier when the smash bar auto-resolves (missed timing).
@export var smash_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var smash_flow_window_center: float = 0.5
## Half-width of the green zone.
@export_range(0.0, 0.5, 0.01) var smash_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each smash.
@export_range(0.0, 0.5, 0.01) var smash_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var smash_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var smash_flow_window_curve_max_time: float = 60.0
## Sound played when a smash begins.
@export var smash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var smash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the smash swing sound.
@export var smash_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the smash.
@export var smash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD

# ── Dash Attack ───────────────────────────────────────────────────────────────

@export_group("Dash Attack")
## Base damage dealt by a dash attack.
@export var dash_damage: float = 40.0
## Knockback force applied to enemies hit by a dash.
@export var dash_knockback_force: float = 500.0
## Animation frame indices during which the dash hitbox is active.
@export var dash_hitbox_frames: Array[int] = [5, 6]
## Animation frame at which the dash pauses to await each flow check.
@export var dash_pause_frame: int = 3
## Seconds for the flow bar to fill during each dash pause.
@export var dash_flow_fill_duration: float = 0.45
## Damage multiplier when the dash bar auto-resolves (missed timing).
@export var dash_flow_miss_multiplier: float = 0.6
## Center of the green zone (0 = bottom of bar, 1 = top).
@export_range(0.0, 1.0, 0.01) var dash_flow_window_center: float = 0.5
## Half-width of the green zone.
@export_range(0.0, 0.5, 0.01) var dash_flow_window_half_size: float = 0.075
## Max random shift applied to the window center each dash check.
@export_range(0.0, 0.5, 0.01) var dash_flow_window_random_range: float = 0.05
## Optional Curve: Y = window half-size at normalized run time.
@export var dash_flow_window_size_curve: Curve
## Run duration in seconds that maps to x=1 on the size curve.
@export var dash_flow_window_curve_max_time: float = 60.0
## Sound played when a dash begins.
@export var dash_swing_sound: AudioStream
@export_range(-40.0, 6.0, 0.1) var dash_swing_sound_volume_db: float = 0.0
## Animation frame indices that trigger the dash swing sound.
@export var dash_swing_sound_frames: Array[int] = []
## Weapon type reported to enemies hit by the dash.
@export var dash_weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
@export_group("")

# ── Hitbox nodes ──────────────────────────────────────────────────────────────

@onready var slash_hitbox: Area2D = find_child("SlashHitbox") as Area2D
@onready var smash_hitbox: Area2D = find_child("SmashHitbox") as Area2D
@onready var dash_hitbox: Area2D = find_child("DashHitbox") as Area2D
@onready var slash_effect_root: Node2D = _find_slash_effect_root()
@onready var slash_effect_sprite: Sprite2D = _find_slash_effect_sprite()
@onready var slash_effect_particles_down: CPUParticles2D = _find_slash_effect_particles("ParticalsDown")
@onready var slash_effect_particles_up: CPUParticles2D = _find_slash_effect_particles("ParticalsUp")
## The scene root (parent of this CharacterBody2D) — z_index lives here, not on this node.
@onready var root_node: Node2D = get_parent() as Node2D

var _slash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _smash_hitbox_right_pos: Vector2 = Vector2.ZERO
var _dash_hitbox_right_pos: Vector2 = Vector2.ZERO

var _current_attack_damage_multiplier: float = 1.0
## Root z_index before any smash boost, captured once in _ready().
var _root_z_index_base: int = 0
# True from 2 frames after any attack's pause frame until the attack ends —
# player takes no damage or knockback (i-frames for the attack's commitment window).
var _attack_invincible: bool = false

var _slash_swing_audio: AudioStreamPlayer2D = null
var _smash_swing_audio: AudioStreamPlayer2D = null
var _dash_swing_audio: AudioStreamPlayer2D = null


func _ready() -> void:
	super()
	if animated_sprite == null:
		return
	if root_node != null:
		_root_z_index_base = root_node.z_index
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_frame_changed)
	animated_sprite.play("idle")
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(smash_hitbox, false)
	_set_hitbox(dash_hitbox, false)
	_initialize_slash_effect()
	if slash_hitbox != null:
		slash_hitbox.body_entered.connect(_on_slash_hit_body)
	if smash_hitbox != null:
		smash_hitbox.body_entered.connect(_on_smash_hit_body)
	if dash_hitbox != null:
		dash_hitbox.body_entered.connect(_on_dash_hit_body)
	_slash_swing_audio = _make_sfx_player(slash_swing_sound, slash_swing_sound_volume_db)
	_smash_swing_audio = _make_sfx_player(smash_swing_sound, smash_swing_sound_volume_db)
	_dash_swing_audio = _make_sfx_player(dash_swing_sound, dash_swing_sound_volume_db)


# ── Movement ───────────────────────────────────────────────────────────────────

func _handle_movement() -> void:
	var in_pause: bool = (attack_state == AttackState.SLASH_PAUSED
						or attack_state == AttackState.SMASH_PAUSED
						or attack_state == AttackState.DASH_PAUSED)
	var in_finish: bool = (attack_state == AttackState.SLASH_FINISH
						or attack_state == AttackState.SMASH_FINISH
						or attack_state == AttackState.DASH_FINISH)
	# Dash's motion is baked into the sprite frames, so facing must not flip mid-swing
	# (locked for the whole attack — frame 0 is instantaneous anyway).
	var dash_facing_locked: bool = (attack_state == AttackState.DASH_WINDUP
						or attack_state == AttackState.DASH_PAUSED
						or attack_state == AttackState.DASH_FINISH)

	var speed_mult: float = 0.3 if (in_pause or in_finish) else 1.0

	var dir_x: float = _get_axis("move_left", "move_right")
	var dir_y: float = _get_axis("move_up", "move_down")

	var effective_speed: float = move_speed + speed_bonus
	velocity.x = dir_x * effective_speed * speed_mult
	velocity.y = dir_y * effective_speed * speed_mult

	if not _action_pressed("face_lock") and not dash_facing_locked:
		if dir_x > 0.0:
			_set_facing(1.0)
		elif dir_x < 0.0:
			_set_facing(-1.0)

	_update_animation(dir_x, dir_y)
	_handle_attack_input()


func _update_animation(dir_x: float, dir_y: float) -> void:
	if has_network_animation_override():
		return
	if attack_state != AttackState.NONE:
		return
	if healing_locked:
		if animated_sprite.animation != "heal":
			animated_sprite.play(&"heal")
		return
	if dir_x != 0.0 or dir_y != 0.0:
		if animated_sprite.animation != "run":
			animated_sprite.play("run")
	else:
		if animated_sprite.animation != "idle":
			animated_sprite.play("idle")


# ── Attack input ───────────────────────────────────────────────────────────────

func _handle_attack_input() -> void:
	match attack_state:
		AttackState.NONE:
			if not attacks_locked:
				if _action_just_pressed("action1"):
					_begin_attack(AttackState.SLASH_WINDUP)
					var _sh := _sample_window_half(slash_flow_window_size_curve,
							slash_flow_window_half_size, slash_flow_window_curve_max_time)
					_start_flow(&"slash",
						func(mult: float):
							_current_attack_damage_multiplier = mult
							_finish_attack("slash", slash_pause_frame, AttackState.SLASH_FINISH),
						slash_flow_fill_duration, slash_flow_miss_multiplier,
						slash_flow_window_center, _sh, slash_flow_window_random_range)
					_play_attack_animation("slash")
				elif _action_just_pressed("action2"):
					_begin_attack(AttackState.SMASH_WINDUP)
					_smash_advanced = false
					var _sm := _sample_window_half(smash_flow_window_size_curve,
							smash_flow_window_half_size, smash_flow_window_curve_max_time)
					_start_flow(&"smash",
						func(mult: float):
							_current_attack_damage_multiplier = mult
							_finish_attack("smash", smash_pause_frame, AttackState.SMASH_FINISH),
						smash_flow_fill_duration, smash_flow_miss_multiplier,
						smash_flow_window_center, _sm, smash_flow_window_random_range)
					_play_attack_animation("smash")
				elif _action_just_pressed("action3"):
					_begin_attack(AttackState.DASH_WINDUP)
					_start_dash_flow_check()
					_play_attack_animation("dash")

		AttackState.SLASH_WINDUP:
			_handle_flow_attempt(&"action1")

		AttackState.SLASH_PAUSED:
			_handle_flow_attempt(&"action1")

		AttackState.SMASH_WINDUP:
			_handle_flow_attempt(&"action2")

		AttackState.SMASH_PAUSED:
			_handle_flow_attempt(&"action2")

		AttackState.DASH_WINDUP:
			_handle_flow_attempt(&"action3")

		AttackState.DASH_PAUSED:
			_handle_flow_attempt(&"action3")


## Returns a stats dictionary consumed by character_description_panel.gd.
## Call get_character_stats() on the instantiated scene to read current Inspector values.
func get_character_stats() -> Dictionary:
	return {
		"display_name": display_name,
		"max_health":   max_health,
		"move_speed":   move_speed,
		"knockback_friction": knockback_friction,
		"action1": {"name": "[ J ] Slash",  "damage": slash_damage, "knockback": slash_knockback_force},
		"action2": {"name": "[ K ] Smash",  "damage": smash_damage, "knockback": smash_knockback_force},
		"action3": {"name": "[ L ] Dash",   "damage": dash_damage,  "knockback": dash_knockback_force},
	}


## Disable hitboxes and reset attack state immediately on death,
## so a mid-animation attack cannot keep dealing damage after the poof.
func die() -> void:
	attack_state = AttackState.NONE
	_dash_flow_checks_completed = 0
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_reset_smash_advance()
	_reset_smash_z_boost()
	_attack_invincible = false
	_stop_flow()
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(smash_hitbox, false)
	_set_hitbox(dash_hitbox, false)
	_set_slash_effect_sprite(false)
	super()


## Reset all attack state on respawn so the player does not resume mid-swing.
func revive(at: Vector2) -> void:
	attack_state = AttackState.NONE
	_dash_flow_checks_completed = 0
	_slash_effect_pending_hide = false
	_current_attack_damage_multiplier = 1.0
	_reset_smash_advance()
	_reset_smash_z_boost()
	_attack_invincible = false
	_stop_flow()
	_set_hitbox(slash_hitbox, false)
	_set_hitbox(smash_hitbox, false)
	_set_hitbox(dash_hitbox, false)
	_set_slash_effect_sprite(false)
	super(at)


## Block incoming damage during an attack's i-frame window.
func take_damage(amount: float, flow_success: bool = false, weapon_type: WeaponType.WeaponType = WeaponType.WeaponType.SWORD) -> void:
	if _attack_invincible:
		return
	super(amount, flow_success, weapon_type)


## Block incoming knockback during an attack's i-frame window.
func apply_knockback(source_position: Vector2, force: float) -> void:
	if _attack_invincible:
		return
	super(source_position, force)


## Sets attack state and clears any previous flow, but does NOT start the animation yet.
## Callers must call _start_flow() (or _start_dash_flow_check()) first, THEN
## _play_attack_animation() — starting the sprite before the flow is initialized can let
## AnimatedSprite2D's immediate/synchronous "frame_changed" emission (fired the instant
## play() switches to a new animation) reach a pause-frame check while _flow_active is
## still false, which _start_flow() then clobbers back to unresolved forever.
func _begin_attack(next_state: AttackState) -> void:
	attack_state = next_state
	_current_attack_damage_multiplier = 1.0
	_dash_flow_checks_completed = 0
	_stop_flow()


## Starts the attack animation. Call only after _start_flow()/_start_dash_flow_check()
## so flow state is already valid if play() synchronously fires frame_changed.
func _play_attack_animation(anim_name: String) -> void:
	animated_sprite.play(anim_name)
	animated_sprite.frame = 0


func _start_dash_flow_check(allow_immediate: bool = false) -> void:
	var _half := _sample_window_half(dash_flow_window_size_curve,
			dash_flow_window_half_size, dash_flow_window_curve_max_time)
	_start_flow(&"dash",
		func(mult: float):
			_current_attack_damage_multiplier = minf(_current_attack_damage_multiplier, mult)
			_dash_flow_checks_completed += 1
			if _dash_flow_checks_completed < DASH_FLOW_CHECK_COUNT:
				attack_state = AttackState.DASH_PAUSED
				animated_sprite.frame = dash_pause_frame
				animated_sprite.pause()
				call_deferred("_start_dash_flow_check", true)
				return
			_finish_attack("dash", dash_pause_frame, AttackState.DASH_FINISH),
		dash_flow_fill_duration, dash_flow_miss_multiplier,
		dash_flow_window_center, _half, dash_flow_window_random_range)

	if allow_immediate:
		_flow_can_resolve = true


func _finish_attack(anim_name: String, resume_frame: int, next_state: AttackState) -> void:
	attack_state = next_state
	# Resume the animation from the pause frame.
	# Calling play() on the already-current animation resumes without resetting
	# the frame in Godot 4 (same animation name = no reset). As a safety net
	# we also force the frame immediately after.
	animated_sprite.play(anim_name)
	animated_sprite.frame = resume_frame


# ── AnimatedSprite2D signal handlers ──────────────────────────────────────────

func _on_frame_changed() -> void:
	var f: int = animated_sprite.frame
	# Remote puppet fallback: when this character is the host's slot viewed on the
	# joiner, attack_state is always NONE (input is never processed here).
	# Infer the attack from animation name so swing sounds still play.
	if attack_state == AttackState.NONE:
		match animated_sprite.animation:
			&"slash":
				if f in slash_swing_sound_frames:
					_play_sfx(_slash_swing_audio)
			&"smash":
				if f in smash_swing_sound_frames:
					_play_sfx(_smash_swing_audio)
			&"dash":
				if f in dash_swing_sound_frames:
					_play_sfx(_dash_swing_audio)
	else:
		# I-frames: 2 frames after the active attack's pause frame, for the rest of the swing.
		var pause_frame := _current_attack_pause_frame()
		if pause_frame >= 0 and f >= pause_frame + 2:
			_attack_invincible = true
	match attack_state:
		AttackState.SLASH_WINDUP:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)
			if f >= slash_pause_frame:
				attack_state = AttackState.SLASH_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.SLASH_PAUSED:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)

		AttackState.SLASH_FINISH:
			_set_hitbox(slash_hitbox, f in slash_hitbox_frames)
			_flush_slash_effect_sprite()
			if f in slash_swing_sound_frames:
				_play_sfx(_slash_swing_audio)

		AttackState.SMASH_WINDUP:
			_set_hitbox(smash_hitbox, f in smash_hitbox_frames)
			_advance_smash_hitbox(f)
			_apply_smash_z_boost(f)
			if f in smash_swing_sound_frames:
				_play_sfx(_smash_swing_audio)
			if f >= smash_pause_frame:
				attack_state = AttackState.SMASH_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.SMASH_PAUSED:
			_set_hitbox(smash_hitbox, f in smash_hitbox_frames)
			_advance_smash_hitbox(f)
			_apply_smash_z_boost(f)
			if f in smash_swing_sound_frames:
				_play_sfx(_smash_swing_audio)

		AttackState.SMASH_FINISH:
			_set_hitbox(smash_hitbox, f in smash_hitbox_frames)
			_advance_smash_hitbox(f)
			_apply_smash_z_boost(f)
			if f in smash_swing_sound_frames:
				_play_sfx(_smash_swing_audio)

		AttackState.DASH_WINDUP:
			# Hitbox frames are past the pause point, so they only fire in DASH_FINISH.
			if f in dash_swing_sound_frames:
				_play_sfx(_dash_swing_audio)
			if f >= dash_pause_frame:
				attack_state = AttackState.DASH_PAUSED
				if not _flow_set_can_resolve():
					animated_sprite.pause()
					_flow_can_resolve = true

		AttackState.DASH_PAUSED:
			if f in dash_swing_sound_frames:
				_play_sfx(_dash_swing_audio)
			# waiting for flow input; hitbox not active until DASH_FINISH

		AttackState.DASH_FINISH:
			if f in dash_swing_sound_frames:
				_play_sfx(_dash_swing_audio)
			_set_hitbox(dash_hitbox, f in dash_hitbox_frames)


func _on_animation_finished() -> void:
	match attack_state:
		AttackState.SLASH_FINISH, AttackState.SMASH_FINISH, AttackState.DASH_FINISH:
			attack_state = AttackState.NONE
			_dash_flow_checks_completed = 0
			_current_attack_damage_multiplier = 1.0
			_reset_smash_advance()
			_reset_smash_z_boost()
			_attack_invincible = false
			_stop_flow()
			_set_hitbox(slash_hitbox, false)
			_set_hitbox(smash_hitbox, false)
			_set_hitbox(dash_hitbox, false)
			_slash_effect_pending_hide = false
			_set_slash_effect_sprite(false)
			animated_sprite.play("idle")


## Called when any active hitbox touches an enemy body.
func _on_slash_hit_body(body: Node2D) -> void:
	_apply_hit_body(body)
	_sync_slash_effect_facing()
	_set_slash_effect_sprite(true)
	_slash_effect_pending_hide = true
	_restart_slash_particles(slash_effect_particles_down)
	_restart_slash_particles(slash_effect_particles_up)


func _on_smash_hit_body(body: Node2D) -> void:
	_apply_hit_body(body)


func _on_dash_hit_body(body: Node2D) -> void:
	_apply_hit_body(body)


func _apply_hit_body(body: Node2D) -> void:
	var flow_success: bool = _current_attack_damage_multiplier >= 1.0
	var kforce: float
	var wtype: WeaponType.WeaponType
	match attack_state:
		AttackState.SMASH_WINDUP, AttackState.SMASH_PAUSED, AttackState.SMASH_FINISH:
			kforce = smash_knockback_force
			wtype = smash_weapon_type
		AttackState.DASH_WINDUP, AttackState.DASH_PAUSED, AttackState.DASH_FINISH:
			kforce = dash_knockback_force
			wtype = dash_weapon_type
		_:
			kforce = slash_knockback_force
			wtype = slash_weapon_type
	if body.has_method("take_damage"):
		body.take_damage(_get_current_attack_damage(), flow_success, wtype)
	if body.has_method("apply_knockback"):
		body.apply_knockback(global_position, kforce)
	# Joiner: enemy take_damage returns early locally — forward the hit to the host.
	if GameManager.session_id != "" and not GameManager.is_host:
		var eid: int = int(body.get_meta(&"spawn_id", -1))
		if eid >= 0:
			WebRTCManager.send_reliable({
				"t":   "melee_hit",
				"eid": eid,
				"dmg": _get_current_attack_damage(),
				"kbf": kforce,
				"kbx": global_position.x,
				"kby": global_position.y,
				"s":   1 if flow_success else 0,
				"wt":  int(wtype),
			})


## Steps the smash hitbox forward once per swing at smash_advance_frame.
func _advance_smash_hitbox(f: int) -> void:
	if _smash_advanced or f != smash_advance_frame:
		return
	if smash_hitbox != null:
		smash_hitbox.position.x += smash_advance_distance
	_smash_advanced = true


## Restores the smash hitbox to its captured right-facing position.
func _reset_smash_advance() -> void:
	_smash_advanced = false
	if smash_hitbox != null:
		smash_hitbox.position = _smash_hitbox_right_pos


## Raises the root node's z_index during smash_z_boost_frames so the jump-in doesn't
## clip behind tall scenery (e.g. the castle), restoring it outside those frames.
func _apply_smash_z_boost(f: int) -> void:
	if root_node == null:
		return
	root_node.z_index = _root_z_index_base + (smash_z_index_boost if f in smash_z_boost_frames else 0)


## Immediately restores the root node's z_index to its base value.
func _reset_smash_z_boost() -> void:
	if root_node != null:
		root_node.z_index = _root_z_index_base


## Enable or disable an Area2D hitbox.
## Always deferred so this is safe to call from body_entered / frame_changed signals.
func _set_hitbox(box: Area2D, enabled: bool) -> void:
	if not is_instance_valid(box):
		return
	box.set_deferred(&"monitoring", enabled)
	box.set_deferred(&"monitorable", enabled)


func _initialize_slash_effect() -> void:
	_sync_slash_effect_facing()
	if slash_effect_sprite != null:
		slash_effect_sprite.z_as_relative = false
		slash_effect_sprite.z_index = 100
		slash_effect_sprite.hide()
	if slash_effect_particles_down != null:
		slash_effect_particles_down.emitting = false
	if slash_effect_particles_up != null:
		slash_effect_particles_up.emitting = false


func _set_slash_effect_sprite(show_it: bool) -> void:
	if slash_effect_sprite != null:
		slash_effect_sprite.visible = show_it


## Called each animation frame tick during a slash. Hides the sprite one
## animation frame after contact was made, keeping it at animation speed.
func _flush_slash_effect_sprite() -> void:
	if _slash_effect_pending_hide:
		_slash_effect_pending_hide = false
		_set_slash_effect_sprite(false)


func _restart_slash_particles(particles: CPUParticles2D) -> void:
	if particles == null:
		return
	particles.emitting = false
	particles.restart()
	particles.emitting = true


func _find_slash_effect_root() -> Node2D:
	var effect: Node = get_node_or_null("slashEffect")
	if effect == null:
		effect = get_node_or_null("../slashEffect")
	if effect == null:
		effect = find_child("slashEffect", true, false)
	return effect as Node2D


func _find_slash_effect_sprite() -> Sprite2D:
	if slash_effect_root == null:
		return null
	return slash_effect_root.get_node_or_null("SlashEffect") as Sprite2D


func _find_slash_effect_particles(node_name: String) -> CPUParticles2D:
	if slash_effect_root == null:
		return null
	return slash_effect_root.get_node_or_null(node_name) as CPUParticles2D


func _capture_right_facing_transforms() -> void:
	super()
	if slash_hitbox != null:
		_slash_hitbox_right_pos = slash_hitbox.position
	if smash_hitbox != null:
		_smash_hitbox_right_pos = smash_hitbox.position
	if dash_hitbox != null:
		_dash_hitbox_right_pos = dash_hitbox.position


# ── Flow timing ────────────────────────────────────────────────────────────────
# _start_flow, _stop_flow, _update_flow, _handle_flow_attempt are all
# inherited from CharacterBase. Each _start_flow call passes a Callable that
# captures the attack-specific resume logic.


## Returns the correct base damage for the current attack scaled by the timing multiplier.
func _get_current_attack_damage() -> float:
	var base: float
	match attack_state:
		AttackState.SLASH_WINDUP, AttackState.SLASH_PAUSED, AttackState.SLASH_FINISH:
			base = slash_damage
		AttackState.SMASH_WINDUP, AttackState.SMASH_PAUSED, AttackState.SMASH_FINISH:
			base = smash_damage
		AttackState.DASH_WINDUP, AttackState.DASH_PAUSED, AttackState.DASH_FINISH:
			base = dash_damage
		_:
			base = slash_damage
	# attack_bonus from blacksmith upgrades is added flat before the timing multiplier.
	return (base + attack_bonus) * _current_attack_damage_multiplier


## Returns the pause frame for whichever attack is currently active, or -1 if none.
func _current_attack_pause_frame() -> int:
	match attack_state:
		AttackState.SLASH_WINDUP, AttackState.SLASH_PAUSED, AttackState.SLASH_FINISH:
			return slash_pause_frame
		AttackState.SMASH_WINDUP, AttackState.SMASH_PAUSED, AttackState.SMASH_FINISH:
			return smash_pause_frame
		AttackState.DASH_WINDUP, AttackState.DASH_PAUSED, AttackState.DASH_FINISH:
			return dash_pause_frame
		_:
			return -1


func _sync_slash_effect_facing() -> void:
	if slash_effect_root == null:
		return
	if facing_pivot != null and facing_pivot.is_ancestor_of(slash_effect_root):
		return
	var effect_scale: Vector2 = slash_effect_root.scale
	effect_scale.x = absf(effect_scale.x) * facing
	slash_effect_root.scale = effect_scale


# ── Flow window helpers ────────────────────────────────────────────────────────

## Returns the effective elapsed run time used to sample flow window size curves.
## Subtracts flow_time_offset so a +Flow upgrade resets the curve to the start.
func _get_run_elapsed() -> float:
	var rm: Node = get_tree().get_first_node_in_group(&"run_manager")
	if rm != null and "time_elapsed" in rm:
		return maxf(0.0, float(rm.time_elapsed) - flow_time_offset)
	return 0.0


## Returns the window half-size for this attack frame, sampling the curve when
## one is assigned. curve_max_time is the run duration (seconds) that maps to x=1.
func _sample_window_half(curve: Curve, default_half: float, curve_max_time: float) -> float:
	if curve == null:
		return default_half
	var t := clampf(_get_run_elapsed() / maxf(curve_max_time, 1.0), 0.0, 1.0)
	var half := curve.sample_baked(t)
	# Clamp to [0, default_half]: prevents negative values (curve extrapolating
	# past the last key with a downward tangent) and positive bounce-back
	# (upward tangent causing the window to re-grow past its start size).
	# Snap sub-resolution residuals to exactly zero so the window fully closes
	# when the curve reaches its minimum.
	half = clampf(half, 0.0, default_half)
	return 0.0 if half < 0.005 else half


## Apply the facing variable to the sprite and all hitbox positions.
func _apply_facing() -> void:
	if animated_sprite == null:
		return
	super()  # handles pivot scale or sprite flip_h + health_bar mirroring
	if facing_pivot != null:
		_sync_slash_effect_facing()
		return
	# No pivot: additionally mirror rogue-specific nodes.
	if slash_hitbox != null:
		slash_hitbox.position = Vector2(_slash_hitbox_right_pos.x * facing, _slash_hitbox_right_pos.y)
	if smash_hitbox != null and not _smash_advanced:
		smash_hitbox.position = Vector2(_smash_hitbox_right_pos.x * facing, _smash_hitbox_right_pos.y)
	if dash_hitbox != null:
		dash_hitbox.position = Vector2(_dash_hitbox_right_pos.x * facing, _dash_hitbox_right_pos.y)
	_sync_slash_effect_facing()

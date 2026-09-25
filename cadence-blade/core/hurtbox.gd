class_name HurtBox
extends Area2D

## HurtBox — an Area2D that receives incoming hits and routes them to the owning entity.
##
## USAGE:
##   1. Attach this script to an Area2D child of a CharacterBody2D (or any node with take_damage).
##   2. Give it a CollisionShape2D so it has physical extent.
##   3. Set damage_multiplier (e.g. 2.0 for a head-shot zone, 1.0 for the body).
##   4. Drag it into the parent entity's "hurtboxes" array for inspector visibility.
##
## The box auto-discovers its owning entity by walking up the scene tree to the
## first ancestor that has a take_damage() method. No manual signal wiring needed.

## Multiplier applied to all incoming damage.
## 1.0 = normal, 2.0 = double (head shot), 0.5 = armoured zone, etc.
@export var damage_multiplier: float = 1.0

## Physics layers this box reacts to. 0 = auto (default): a hurtbox owned by an
## EnemyBase reacts only to player attacks; any other owner (players) reacts to
## everything. Set an explicit mask here to override the auto behavior.
@export_flags_2d_physics var hittable_by_layers: int = 0

## Player attack layers: melee hitboxes = layer 5 (16), projectiles = layer 6 (32).
const PLAYER_ATTACK_LAYERS: int = (1 << 4) | (1 << 5)

## Resolved in _ready(). The CharacterBody2D (or other node) that owns this hitbox.
var _entity: Node = null

## Meta key on the owning entity: { attack_area_instance_id: true } for attacks
## currently claimed by one of its hurtboxes. Shared by every hurtbox on the
## entity so a single swing/projectile damages only the first box it overlaps.
const _CLAIMS_META := &"_hurtbox_attack_claims"


func _ready() -> void:
	monitoring = true
	monitorable = false   # hurtboxes are passive — nothing needs to detect them outwardly
	collision_layer = 0   # not on any outward layer

	# Walk up the tree to find the entity this box belongs to.
	var p: Node = get_parent()
	while p != null:
		if p.has_method("take_damage"):
			_entity = p
			break
		p = p.get_parent()

	# Which incoming areas may damage us.
	if hittable_by_layers != 0:
		collision_mask = hittable_by_layers
	elif _entity is EnemyBase:
		# Enemies are only ever hurt by the player side -- never by other enemies'
		# attack hitboxes (which sit on layer 1).
		collision_mask = PLAYER_ATTACK_LAYERS
	else:
		# Players: detect every incoming area (enemy melee zones, arrows, fireballs).
		collision_mask = 0xFFFF_FFFF

	area_entered.connect(_on_area_entered)
	area_exited.connect(_on_area_exited)


func _on_area_exited(area: Area2D) -> void:
	# Release the claim so the attack can hit this entity again on its next swing
	# (persistent melee hitboxes toggle monitorable between swings).
	if _entity != null and is_instance_valid(_entity):
		var claims: Dictionary = _entity.get_meta(_CLAIMS_META, {})
		claims.erase(area.get_instance_id())


func _on_area_entered(area: Area2D) -> void:
	if _entity == null or not is_instance_valid(_entity):
		return

	# A corpse mid death-animation still has live hurtboxes — don't let it soak hits.
	if bool(_entity.get(&"is_dead")):
		return

	# Skip areas that belong to this entity (e.g. its own attack hitboxes or child nodes).
	if _entity.is_ancestor_of(area):
		return

	# Skip this entity's own projectiles (e.g. dragon's fireball has a shooter field).
	var shooter = area.get("shooter")
	if shooter != null and shooter is Node:
		if shooter == _entity or _entity.is_ancestor_of(shooter):
			return

	# One attack contact damages only ONE of the entity's hurtboxes: if a sibling
	# box already claimed this exact attack area, ignore it here.
	var claims: Dictionary = _entity.get_meta(_CLAIMS_META, {})
	if not _entity.has_meta(_CLAIMS_META):
		_entity.set_meta(_CLAIMS_META, claims)
	var aid: int = area.get_instance_id()
	if claims.has(aid):
		return

	var result := _read_damage_and_type(area)
	var dmg: float = result[0]
	if dmg <= 0.0:
		return
	var wtype: WeaponType.WeaponType = result[1] as WeaponType.WeaponType
	var attacker: Node = result[2] as Node

	claims[aid] = true

	# Carry the flow-success flag through so hurtbox hits (e.g. the dragon's
	# head/body boxes) still crit — body_entered on plain enemies already does.
	# Projectiles (arrows) carry the flag on the area itself; melee hitboxes carry
	# no such state, so fall back to asking the attacker directly.
	var flow_success: bool = false
	if area.has_method(&"get_flow_success"):
		flow_success = bool(area.call(&"get_flow_success"))
	elif &"_flow_success" in area:
		flow_success = bool(area.get(&"_flow_success"))
	elif attacker != null and attacker.has_method(&"_get_current_flow_success"):
		flow_success = bool(attacker.call(&"_get_current_flow_success"))

	EnemyBase.player_hit(_entity, _attacker_slot(area, attacker), dmg * damage_multiplier, flow_success, wtype)
	_forward_hit_to_host(dmg * damage_multiplier, wtype, flow_success, attacker)

	# Prevent body_entered from double-damaging in the same physics step.
	if "consumed" in area:
		area.consumed = true
	# Mark as hit so the missed signal is not emitted, and advance shooter combos.
	if "_hit_any" in area:
		area._hit_any = true
	if area.has_signal(&"enemy_hit"):
		area.emit_signal(&"enemy_hit")

	# Only free projectiles (arrows, fireballs) — never free persistent melee hitboxes
	# that are children of the attacker character.
	var is_projectile: bool = area.has_method("get_damage") or area.get("shooter") != null
	if is_projectile and is_instance_valid(area):
		area.queue_free()


## Player slot behind an incoming hit, or 0 when a player didn't make it (hut units,
## tower archers, enemy attacks). A player's arrow carries its own shooter_slot; a melee
## hitbox hangs off the attacking character. Decides who is credited if the hit kills.
func _attacker_slot(area: Area2D, attacker: Node) -> int:
	if "shooter_slot" in area:
		return int(area.get("shooter_slot"))
	if attacker is CharacterBase:
		return (attacker as CharacterBase).player_slot
	return 0


## Joiner: route a hurtbox-delivered hit to the host.
##
## The local take_damage() above returns early on a joiner (the host owns enemy HP), and
## enemies whose damage arrives ONLY through hurtboxes — the dragon and skeleton knight,
## whose CharacterBody2D carries no shape of its own — have no body_entered path to
## report the hit the way plain enemies do. Without this they are simply unhittable for
## anyone but the host.
func _forward_hit_to_host(dmg: float, wtype: WeaponType.WeaponType, flow_success: bool,
		attacker: Node) -> void:
	if GameManager.session_id == "" or GameManager.is_host:
		return
	if _entity == null or not (_entity is EnemyBase):
		return
	var eid: int = int(_entity.get_meta(&"spawn_id", -1))
	if eid < 0:
		return
	# Knockback force and origin live on the attacking character, not on the hitbox.
	var kbf: float = 0.0
	var src: Vector2 = area_origin_fallback(attacker)
	if attacker != null:
		if attacker.has_method("_get_current_knockback_force"):
			kbf = float(attacker.call("_get_current_knockback_force"))
		elif "attack_knockback_force" in attacker:
			kbf = float(attacker.get("attack_knockback_force"))
	WebRTCManager.send_reliable({
		"t":   "melee_hit",
		"eid": eid,
		"dmg": dmg,
		"kbf": kbf,
		"kbx": src.x,
		"kby": src.y,
		"s":   1 if flow_success else 0,
		"wt":  int(wtype),
	})


## Knockback origin: the attacking character's position, falling back to this box.
func area_origin_fallback(attacker: Node) -> Vector2:
	if attacker is Node2D:
		return (attacker as Node2D).global_position
	return global_position


## Resolves damage, weapon_type and the attacking node from an incoming area in one pass.
## Returns [dmg: float, wtype: WeaponType.WeaponType, attacker: Node].
## For projectiles the values sit on the area itself.
## For melee hitboxes they sit on an ancestor of the area (the attacker character).
func _read_damage_and_type(area: Area2D) -> Array:
	# Projectile with get_damage() accessor (e.g. Arrow). weapon_type is also on the area.
	if area.has_method("get_damage"):
		var wt: WeaponType.WeaponType = WeaponType.WeaponType.ARROW
		if "weapon_type" in area:
			wt = area.weapon_type as WeaponType.WeaponType
		return [float(area.call("get_damage")), wt, area.get("shooter")]

	# Projectile with a direct damage property (e.g. Fireball). weapon_type also on the area.
	if "damage" in area:
		var d = area.get("damage")
		var wt: WeaponType.WeaponType = WeaponType.WeaponType.FIREBALL
		if "weapon_type" in area:
			wt = area.weapon_type as WeaponType.WeaponType
		return [float(d) if d != null else 0.0, wt, area.get("shooter")]

	# Melee hitbox: damage AND weapon_type both live on the attacker node, not the area.
	# Walk up the parent chain to find them.
	var dmg := 0.0
	var wtype: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
	var attacker: Node = null
	var node: Node = area.get_parent()
	while node != null and node != _entity:
		if node.has_method("_get_current_attack_damage"):
			dmg = float(node.call("_get_current_attack_damage"))
		if dmg == 0.0 and "attack_damage" in node:
			dmg = float(node.get("attack_damage"))
		if node.has_method("_get_current_weapon_type"):
			wtype = node.call("_get_current_weapon_type") as WeaponType.WeaponType
		elif "weapon_type" in node:
			wtype = node.get("weapon_type") as WeaponType.WeaponType
		if dmg > 0.0:
			attacker = node
			break
		node = node.get_parent()
	return [dmg, wtype, attacker]

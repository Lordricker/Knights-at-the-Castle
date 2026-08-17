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

## Resolved in _ready(). The CharacterBody2D (or other node) that owns this hitbox.
var _entity: Node = null


func _ready() -> void:
	monitoring = true
	monitorable = false   # hurtboxes are passive — nothing needs to detect them outwardly
	collision_layer = 0   # not on any outward layer
	collision_mask = 0xFFFF_FFFF  # detect every incoming area (arrows, fireballs, melee zones)

	# Walk up the tree to find the entity this box belongs to.
	var p: Node = get_parent()
	while p != null:
		if p.has_method("take_damage"):
			_entity = p
			break
		p = p.get_parent()

	area_entered.connect(_on_area_entered)


func _on_area_entered(area: Area2D) -> void:
	if _entity == null or not is_instance_valid(_entity):
		return

	# Skip areas that belong to this entity (e.g. its own attack hitboxes or child nodes).
	if _entity.is_ancestor_of(area):
		return

	# Skip this entity's own projectiles (e.g. dragon's fireball has a shooter field).
	var shooter = area.get("shooter")
	if shooter != null and shooter is Node:
		if shooter == _entity or _entity.is_ancestor_of(shooter):
			return

	var result := _read_damage_and_type(area)
	var dmg: float = result[0]
	if dmg <= 0.0:
		return
	var wtype: WeaponType.WeaponType = result[1] as WeaponType.WeaponType

	_entity.take_damage(dmg * damage_multiplier, false, wtype)

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


## Resolves both damage and weapon_type from an incoming area in one pass.
## Returns [dmg: float, wtype: WeaponType.WeaponType].
## For projectiles the values sit on the area itself.
## For melee hitboxes they sit on an ancestor of the area (the attacker character).
func _read_damage_and_type(area: Area2D) -> Array:
	# Projectile with get_damage() accessor (e.g. Arrow). weapon_type is also on the area.
	if area.has_method("get_damage"):
		var wt: WeaponType.WeaponType = WeaponType.WeaponType.ARROW
		if "weapon_type" in area:
			wt = area.weapon_type as WeaponType.WeaponType
		return [float(area.call("get_damage")), wt]

	# Projectile with a direct damage property (e.g. Fireball). weapon_type also on the area.
	if "damage" in area:
		var d = area.get("damage")
		var wt: WeaponType.WeaponType = WeaponType.WeaponType.FIREBALL
		if "weapon_type" in area:
			wt = area.weapon_type as WeaponType.WeaponType
		return [float(d) if d != null else 0.0, wt]

	# Melee hitbox: damage AND weapon_type both live on the attacker node, not the area.
	# Walk up the parent chain to find them.
	var dmg := 0.0
	var wtype: WeaponType.WeaponType = WeaponType.WeaponType.SWORD
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
			break
		node = node.get_parent()
	return [dmg, wtype]

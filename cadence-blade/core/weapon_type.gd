class_name WeaponType

## Identifies the type of weapon that dealt damage.
## Used by enemies and players to play the correct hit sound.
enum WeaponType {
	SWORD,    ## Sword, spear, or any bladed melee weapon
	ARROW,    ## Arrow or bolt
	HAMMER,   ## Blunt hammer or maul
	CLAW,     ## Natural weapon (dragon claw, animal attack, etc.)
	FIREBALL, ## Magical fire projectile
}

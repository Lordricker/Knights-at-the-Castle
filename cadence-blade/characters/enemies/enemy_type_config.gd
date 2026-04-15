class_name EnemyTypeConfig
extends Resource

# enemy_type_config.gd — Groups a set of EnemyVariantConfig resources under
# one named type (e.g. "Knight", "Archer", "Warrior").
#
# Add one EnemyTypeConfig per sprite category to the spawner's enemy_types
# array.  Each entry's variants array then holds the colour/difficulty
# variants for that type.

@export_group("Identity")
## Human-readable name for this enemy category (no runtime effect).
@export var type_name: String = "Enemy Type"

@export_group("Variants")
## Ordered list of variants for this type, from weakest to strongest.
## Each entry is an EnemyVariantConfig resource configured in the Inspector.
@export var variants: Array[EnemyVariantConfig] = []

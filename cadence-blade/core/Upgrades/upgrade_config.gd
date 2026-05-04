class_name UpgradeConfig
extends Resource

# upgrade_config.gd — Inspector-configurable data for a single blacksmith upgrade.
#
# ── HOW TO USE ────────────────────────────────────────────────────────────────
#   1. Right-click in the FileSystem dock → New Resource → UpgradeConfig.
#   2. Add the resource to CastleInside's `upgrades` array in the Inspector.
#   3. Assign a pool_tickets_curve so the upgrade appears in the lottery over time.
#      X = normalised run time [0–1] where 1.0 = castle_inside.curve_time_scale_minutes.
#      Y = ticket count (rounded to int). 0 tickets = upgrade never appears.
#
# ── EXAMPLE CURVE ─────────────────────────────────────────────────────────────
#   +5 Attack: flat Y=5 across the whole curve (always available).
#   +5 Speed:  Y=0 for first 20 % of run, then ramp to Y=8 (unlocks mid-run).

enum StatType {
	ATTACK,          ## Adds stat_amount to the player's attack_bonus (flat damage added per hit).
	SPEED,           ## Adds stat_amount to the player's speed_bonus (flat move_speed increase).
	HEAL_CASTLE,     ## Restores stat_amount HP to the castle (capped at its current max).
	UPGRADE_CASTLE,  ## Increases the castle's max HP by stat_amount.
	UPGRADE_HP,      ## Increases the player's max HP by stat_amount.
	RESET_FLOW,      ## Resets the player's flow window size curves back to the start of the run.
	FREEZE_ENEMIES,  ## Freezes all enemies and pauses spawning for stat_amount seconds.
}

@export_group("Identity")
## Shown as the upgrade name in the blacksmith UI panel.
@export var display_name: String = "Upgrade"
## Sprite displayed in the offer panel. Assign a Texture2D from the FileSystem dock.
@export var icon: Texture2D

@export_group("Purchase")
## Coin cost to buy this upgrade. Checked against CharacterBase.coins at purchase time.
@export var cost: int = 10

@export_group("Effect")
## Which player stat to boost when purchased.
@export var stat_type: StatType = StatType.ATTACK
## Flat amount added to the chosen stat on purchase (stacks across multiple purchases).
@export var stat_amount: float = 5.0

@export_group("Lottery Pool")
## How many tickets this upgrade contributes to the draw pool over time.
## X = normalised run time, Y = ticket count (rounded to int, minimum 0).
## A flat Curve with Y = 5 means always 5 tickets throughout the run.
@export var pool_tickets_curve: Curve

# ── Helpers ───────────────────────────────────────────────────────────────────

## Returns true if this upgrade applies only to the individual player who bought it
## (ATTACK, SPEED, UPGRADE_HP, RESET_FLOW). False for shared world effects
## (HEAL_CASTLE, UPGRADE_CASTLE, FREEZE_ENEMIES) which the host applies for everyone.
func is_personal() -> bool:
	return stat_type in [StatType.ATTACK, StatType.SPEED, StatType.UPGRADE_HP, StatType.RESET_FLOW]

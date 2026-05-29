# Knights at the Castle — Design Document

**Engine:** Godot 4.6.2 | **Language:** GDScript  
**Status:** Planning phase — no implementation yet  
**Last updated:** May 27, 2026

---

## Table of Contents

1. [Game Overview](#1-game-overview)
2. [Phase 1 — Enemy Tower Expansion](#2-phase-1--enemy-tower-expansion)
3. [Phase 2 — Unit Huts](#3-phase-2--unit-huts)
4. [Phase 3 — Unit AI & Waypoints](#4-phase-3--unit-ai--waypoints)
5. [Phase 4 — Unit Upgrade Tree](#5-phase-4--unit-upgrade-tree)
6. [Phase 5 — Multiplayer Sync](#6-phase-5--multiplayer-sync)
7. [Open Questions](#7-open-questions)
8. [Out of Scope](#8-out-of-scope)

---

## 1. Game Overview

Action-defense hybrid game. Players defend a castle from waves of enemies while actively fighting on the map. Features flow-timing attack system, run-based coin economy, and upgrades purchasable from the blacksmith inside the castle. Supports solo and 2-player co-op via WebRTC.

**Roadmap goal:** Expand the single-screen map into a multi-zone battlefield. Players destroy enemy towers to push the front line outward, unlocking unit huts where they can purchase and station allied units to hold captured territory.

---

## 2. Phase 1 — Enemy Tower Expansion

### 2.1 Overview

The existing `EnemyTower 1–6` sprites in `level1.tscn` become destroyable objectives. Destroying a tower:
- Triggers kingdom expansion visuals on the map
- Shifts/splits the enemy spawn points for that zone
- Unlocks the corresponding Unit Hut (see Phase 2)

Towers are NOT directly attackable through normal combat. Instead, a player must purchase a **TNT charge** from the castle's blacksmith, carry it across the map, and plant it at the tower base.

---

### 2.2 TNT Charge (Blacksmith Shop Item)

The TNT is a **fixed purchase slot** in the blacksmith shop — always visible, always available. It does NOT enter the random upgrade lottery. It sits alongside the two random upgrade slots as a permanent third option.

#### Purchase
- Displayed in the shop UI with a TNT icon and a coin cost label
- Cost scales per purchase: `base_cost + (towers_already_destroyed × cost_increment)`
  - Example: 100 → 150 → 200 → 250 → 300 → 350 coins (tunable)
  - Rationale: later towers are deeper into enemy territory; higher cost reflects greater effort and reward
- Only one TNT can be active in the run at a time — button greys out if one is already carried or placed

#### Carrying State
When a player purchases a TNT:
- Player enters **"carrying" state** — a TNT sprite visually attaches to the character
- **Movement speed reduced** (tunable, e.g., 60–70% of normal speed) — carrying heavy explosives is cumbersome
- **Attacks disabled** — both hands are occupied; player cannot slash, shoot, or kick while carrying
- HUD shows a small "CARRYING TNT" indicator
- Player is still hittable and takes damage normally

#### Delivery & Detonation
- Each EnemyTower node has a **PlantZone** (Area2D) — a small collision area at the tower's base
- When the carrying player overlaps a PlantZone, an action prompt appears: **"Plant [J]"**
- Pressing the action button:
  1. Plays a short planting animation on the player
  2. Plays a fuse-lit animation/sound on the tower
  3. Short countdown timer (e.g., 2 seconds) with a visual fuse countdown on screen
  4. Tower destroyed — plays destruction animation, rubble sprite takes over
  5. Player exits carrying state; attacks re-enabled

#### Drop on Death
- If the carrying player **dies** before planting, the TNT drops as a world pickup at the player's death position
- The dropped TNT can be walked over by either player to pick it back up (re-enters carrying state)
- The TNT does NOT explode when dropped or when an enemy walks over it
- If the run ends (castle destroyed) with a TNT on the ground, it is simply lost

#### Multiplayer Notes
- Either player can purchase and carry the TNT
- Only one TNT active at a time across both players
- Joiner carrying: joiner sends position normally; when planting, joiner sends `"plant_tnt"` packet with tower_id; host validates proximity, authorizes destruction, broadcasts `"tower_destroyed"` to both
- Host carrying: host handles everything locally, broadcasts `"tower_destroyed"` on detonation
- Dropped TNT position is synced so either player can pick it up

---

### 2.3 Kingdom Expansion Visuals

When a tower is destroyed, the following happen simultaneously (no loading, all in-scene):

| Effect | Implementation |
|---|---|
| Tower sprite → rubble | Toggle visibility of two pre-placed sprites (intact / rubble) on the EnemyTower node |
| Flag/banner spawns at tower location | Instantiate a simple AnimatedSprite2D scene (friendly banner waving) |
| Ground color changes in that zone | Pre-placed Polygon2D with a neutral tint; Tween its `modulate` to a warmer/friendly color |
| Enemy spawn point moves | Spawner removes that tower's spawn point from active pool; adds a new point further back (details in 2.4) |
| Unit hut unlocks | Calls `linked_hut.unlock()` on the companion Unit Hut node (details in Phase 2) |

---

### 2.4 Enemy Spawn Point Changes

Current spawner has `LeftSpawnPoint` and `RightSpawnPoint`. After towers are introduced, the spawn system becomes zone-aware:

- Each EnemyTower owns 1–2 `SpawnMarker2D` nodes positioned in front of it
- `enemy_spawner.gd` maintains a list of **active spawn points** — at run start, all tower spawn points are active
- When `tower_destroyed(tower_id)` fires: the spawner removes that tower's markers from its active pool
- Optionally: a new spawn point further back in enemy territory is added (the front line shifts)
- This means as the player pushes forward, enemies spawn further away from the castle, reducing pressure on the home base — a tangible reward for tower destruction

---

## 3. Phase 2 — Unit Huts

### 3.1 Overview

Each enemy tower has a paired **Unit Hut** that starts as a ruined structure. When the linked tower is destroyed, the hut animates from ruins to an active building. Players can approach an active hut to purchase and manage up to **3 allied units** stationed there.

### 3.2 Hut States

| State | Visual | Interaction |
|---|---|---|
| Locked (tower intact) | Ruined/damaged sprite | None — no interaction zone active |
| Unlocked (tower destroyed) | Intact hut sprite | Player can enter purchase zone |

On unlock: play a rebuild animation (Tween or AnimationPlayer) transitioning from ruined to active sprite. A visual indicator (smoke, dust, sparkle) accompanies the rebuild.

### 3.3 Interaction Zone

- Area2D `body_entered` / `body_exited` on the hut — same pattern as the castle blacksmith zone
- On enter: show `UnitShopUI`, lock player attacks (`attacks_locked = true`)
- On exit: hide `UnitShopUI`, unlock attacks

### 3.4 Unit Shop UI

Three slot panels displayed when player is in the hut zone.

**Empty slot shows:**
- Four unit type buttons: Sword / Spear / Bow / Healer
- Coin cost per unit type
- Brief stat summary (HP, damage type, role)

**Occupied slot shows:**
- Unit icon and type name
- Unit's current HP bar (live, updates in real time)
- Current upgrade tier badge (e.g., "Tier 0 / Tier 1 / Tier 2")
- Upgrade button(s) — see Phase 4

**Controls:**
- J / K / L to select slot 1 / 2 / 3
- Directional input to select unit type within a slot (or mouse click)
- Confirm to purchase / upgrade — deducts coins from buyer

### 3.5 Hut Capacity Rules
- Maximum 3 units per hut
- Each unit occupies exactly one slot
- Units can be different types — e.g., one Sword + one Bow + one Healer in the same hut
- Selling/removing a unit is a future consideration (out of scope for this phase)

---

## 4. Phase 3 — Unit AI & Waypoints

### 4.1 Overview

Purchased units are allied characters that patrol a corridor defined by a **per-hut Path2D**. The player sets a waypoint flag along that path; the unit walks to the flag, idles there, and automatically attacks any enemy that enters its detection range.

On death, the unit hides, waits through a **respawn timer**, then reappears at the hut and walks back out to the waypoint.

### 4.2 Per-Hut Path2D

Each Unit Hut in `level1.tscn` has a dedicated `Path2D` node that defines the patrol corridor available to units of that hut. The path:
- Starts at the hut's position
- Extends toward enemy territory (following the cleared zone)
- Does NOT need to match the enemy walk path — it can branch or run parallel

Units travel along this path using `PathFollow2D` with a `progress_ratio` value of `[0.0, 1.0]`. The waypoint is simply a saved `progress_ratio` — no coordinate math needed.

### 4.3 Waypoint Placement

**Design decision: waypoints are bounded to the hut's Path2D — no arbitrary radius limit.**

Rationale: the path itself physically cannot go somewhere the player hasn't cleared. It's a natural, thematic boundary. There's no need for a Incursion-style radius cap; the path handles it implicitly.

**Waypoint placement flow:**
1. Player presses "Set Waypoint" button in the Unit Shop UI for a given slot
2. Player exits UI, entering **waypoint placement mode** for that slot
3. A flag sprite appears on the map — it snaps in real time to the nearest point along that hut's Path2D relative to the player's current position
4. Player walks to the desired location (flag follows along the path)
5. Press J to confirm — `waypoint_ratio` is saved for that unit slot, flag is placed permanently at that position
6. Unit immediately starts walking toward the new waypoint

**Waypoint visual:** A small banner/flag at the waypoint position, colored per unit slot (slot 1 = blue, slot 2 = green, slot 3 = yellow, for example).

### 4.4 Unit Base Behavior

All four unit types share this base loop:

```
IDLE at hut
  → Walk along Path2D toward waypoint_ratio
  → IDLE/PATROL at waypoint
      → If enemy enters DetectionZone:
          → ATTACK enemy (unit-type-specific attack)
          → If no more enemies in range: return to PATROL
  → On death:
      → Hide unit
      → Start respawn timer (fixed duration, e.g., 15s — tunable)
      → On timer expire: show unit at hut position (progress_ratio = 0)
      → Walk back to waypoint
```

**Key design note on waypoint distance:** If the player sets a waypoint at the far end of the path and the unit dies frequently, the unit spends most of its time walking. This is the player's own strategic cost — no cap needed because the path distance is the natural punishment. Players will learn to place waypoints at positions where the unit can survive.

### 4.5 Unit Types

#### Sword Unit
- **Role:** Front-line melee fighter
- **HP:** 150
- **Damage:** Moderate (e.g., 20–25 per swing)
- **Attack:** Short-range melee hitbox, single target
- **Speed:** Moderate
- **Special (see Phase 4 upgrades)**

#### Spear Unit
- **Role:** Melee skirmisher with reach advantage
- **HP:** 100
- **Damage:** Moderate (e.g., 15–20 per thrust)
- **Attack:** Longer reach than sword; can hit multiple enemies in a narrow cone
- **Speed:** Moderate

#### Bow Unit
- **Role:** Ranged support
- **HP:** 75
- **Damage:** Low-moderate (e.g., 15 per arrow)
- **Attack:** Fires `arrow.tscn` projectiles — reuses existing arrow system
- **Speed:** Moderate; should maintain distance from melee enemies
- **Note:** Will target enemies at longer range than melee units

#### Healer Unit
- **Role:** Support
- **HP:** 100
- **Damage:** Very low (weak melee fallback if no allies nearby)
- **Attack:** Heals the lowest-HP allied unit within range every N seconds (not targeting enemies unless no allies to heal)
- **Speed:** Moderate

### 4.6 Combat Group Integration

Units need to interact with the existing targeting system:
- Units should be in the `"Kill"` group so enemies in range will target and attack them — they draw fire, which is part of their strategic value
- Enemies already attack anything in the `"Kill"` group; no enemy AI changes needed for basic unit combat
- Units' `DetectionZone` watches for nodes in the `"enemies"` group (same as `tower_archer.gd`)

---

## 5. Phase 4 — Unit Upgrade Tree

### 5.1 Overview

Each unit slot can be upgraded in the Unit Shop UI. The upgrade tree has two tiers:

```
[Tier 0 — Base unit]
       ↓
[Tier 1 — One common upgrade (shared for that unit type)]
       ↓ ↓
[Tier 2A]  [Tier 2B]  ← player chooses one branch
```

Inspired by Incursion's upgrade branching. Tier 2 upgrades give the unit a distinct identity — same base unit can end up very different depending on branch choice.

### 5.2 Upgrade Trees Per Unit Type

#### Sword Unit
| Tier | Name | Effect |
|---|---|---|
| Tier 1 | Sharpened Blade | +damage |
| Tier 2A | Cleave | Melee attacks hit all enemies in a small AOE radius |
| Tier 2B | Vampiric Edge | Sword attacks heal the unit for a portion of damage dealt |

#### Spear Unit
| Tier | Name | Effect |
|---|---|---|
| Tier 1 | Extended Haft | +attack range; wider cone |
| Tier 2A | Skewer | Attacks pierce through multiple enemies in a line |
| Tier 2B | Weighted Tip | Attacks apply a slow debuff to hit enemies for a short duration |

#### Bow Unit
| Tier | Name | Effect |
|---|---|---|
| Tier 1 | Faster Nocking | Reduced attack interval (+fire rate) |
| Tier 2A | Volley | Fires 3 arrows in a spread per shot |
| Tier 2B | Poison Tip | Arrows apply a damage-over-time poison debuff |

#### Healer Unit
| Tier | Name | Effect |
|---|---|---|
| Tier 1 | Wider Blessing | Increased heal radius; heals more HP per tick |
| Tier 2A | Revive Aura | Passively revives the nearest dead unit in range with partial HP (overrides respawn timer) |
| Tier 2B | Wrath Aura | Emits a constant low-damage aura around the healer that damages nearby enemies |

### 5.3 Cost Structure (Placeholder — Tunable)
| Tier | Cost |
|---|---|
| Purchase (Tier 0) | 75–100 coins depending on unit type |
| Upgrade to Tier 1 | 150 coins |
| Upgrade to Tier 2 (either branch) | 250 coins |

### 5.4 Upgrade UI Flow

**Slot panel states in Unit Shop UI:**

1. **Tier 0 (freshly purchased):** Single "Upgrade →" button below the unit card. Shows Tier 1 upgrade name, effect, and cost.
2. **Tier 1 (after first upgrade):** Two branch buttons side-by-side showing Tier 2A and 2B options with names, descriptions, icons, and costs. Player picks one.
3. **Tier 2 (fully upgraded):** Branch choice is locked in. Shows the chosen upgrade's name with a "MAX" badge. No further upgrades.

---

## 6. Phase 5 — Multiplayer Sync

All new features follow the existing multiplayer rules: **host is authoritative** on all game state. Joiners send requests; host validates and broadcasts results.

### 6.1 New Packet Types

| Packet | Direction | Channel | Description |
|---|---|---|---|
| `"tnt_purchase"` | Joiner → Host | Reliable | Joiner requests TNT purchase |
| `"tnt_carrying"` | Host → Joiner | Reliable | Confirms TNT is now carried by player (slot) |
| `"tnt_dropped"` | Host → Joiner | Reliable | TNT dropped at position; shows pickup |
| `"tnt_picked_up"` | Host → Joiner | Reliable | TNT picked up by player |
| `"tnt_planted"` | Joiner → Host | Reliable | Joiner requests planting at tower_id |
| `"tower_destroyed"` | Host → Joiner | Reliable | Tower destroyed; joiner triggers visuals + hut unlock |
| `"unit_purchase"` | Joiner → Host | Reliable | Joiner requests unit purchase at hut_id / slot_id |
| `"unit_spawn"` | Host → Joiner | Reliable | Confirms unit spawned; joiner creates display-only copy |
| `"unit_state"` | Host → Joiner | Unreliable | Unit positions + HP per frame (piggybacked on state snapshot) |
| `"unit_death"` | Host → Joiner | Reliable | Unit died; joiner hides unit |
| `"unit_respawn"` | Host → Joiner | Reliable | Unit respawned; joiner shows unit at hut |
| `"waypoint_set"` | Joiner → Host | Reliable | Joiner requests waypoint change (hut_id, slot_id, ratio) |
| `"waypoint_confirmed"` | Host → Joiner | Reliable | Host validates and confirms new waypoint_ratio |
| `"unit_upgrade"` | Joiner → Host | Reliable | Joiner requests upgrade (hut_id, slot_id, tier, branch) |
| `"unit_upgrade_applied"` | Host → Joiner | Reliable | Host confirms upgrade; joiner updates unit display |

### 6.2 Authority Breakdown

| System | Host | Joiner |
|---|---|---|
| TNT purchase validation | ✓ authoritative | Sends request |
| TNT carry/plant/drop | ✓ authoritative | Visual state only |
| Tower destruction + visuals | ✓ authoritative | Receives packet, plays visuals |
| Hut unlock | ✓ authoritative | Receives with tower_destroyed |
| Unit AI (movement, combat) | ✓ all physics | Display-only copy |
| Unit positions | ✓ broadcasts | Interpolates received positions |
| Unit purchase/upgrade | ✓ authoritative | Sends request |
| Waypoint validation | ✓ clamps to [0.0, 1.0] | Sends desired ratio |

---

## 7. Open Questions

The following design decisions are unresolved and should be answered before implementation begins.

### 7.1 Enemy Tower Attackability (Phase 1)
The current design says towers are destroyed only by TNT. However: should enemies defend towers actively? Considerations:
- Do enemies already near a tower attack players who approach?
  - Current enemy AI targets the `"Kill"` group when in range — if the player enters that range while carrying TNT, enemies will attack them. No change needed; the TNT run naturally becomes a gauntlet.
- Should towers themselves do anything offensive? (e.g., shoot arrows until destroyed?)
  - An enemy-controlled tower archer would add drama to the TNT run. Could be a later addition.

### 7.2 Hut Count and Placement (Phase 2)
- All 6 huts exist from run start as ruins, OR
- Some huts only appear visually after earlier towers fall (controlled reveal)?
- Where physically on the map are the 6 huts placed relative to the 6 towers?

### 7.3 TNT Drop Behavior (Phase 1)
- Should there be a visual countdown / pressure mechanic once TNT is planted (players need to run away) or does it detonate instantly with no player danger?

### 7.4 Unit Aggro & Player Strategy (Phase 3)
- Can players draw enemy aggro toward a unit hut on purpose? (Tank the units while players deal damage elsewhere?)
- Should units hold position if all nearby enemies die, or should they push forward toward the tower/enemy territory automatically?
  - Current design: units idle at waypoint and never advance beyond it. Player must manually update the waypoint to push further.

### 7.5 Healer's Revive Aura (Phase 4 — Tier 2A)
- Does "revive" mean the unit comes back immediately at partial HP (skipping the respawn timer), or does it only work on units that are dead and waiting for the timer?
- How far does the aura reach? Fixed radius or upgradeable?

### 7.6 Upgrade Tree Visual Representation in UI (Phase 4)
- Is the tree shown graphically (connected node diagram) or as flat sequential buttons?
- Should un-purchased tiers be greyed out / visible so players can plan ahead?

### 7.7 Coin Economy Balance
With 6 towers requiring escalating TNT costs (100–350 coins) plus unit purchases (75–100 each) plus upgrades (150 + 250 each), plus the existing blacksmith upgrades — the run economy will need significant rebalancing. This should be addressed before Phase 2 implementation.

---

## 8. Out of Scope (This Phase)

The following are acknowledged ideas but explicitly excluded from this planning phase:

- Unit voice lines or sound effects
- Unit portraits / character art for shop UI
- HUD unit status bar (showing all active allied units' HP in a strip)
- Enemies specifically pathing to destroy Unit Huts
- Selling / recalling a purchased unit for a coin refund
- Enemy tower archer (tower that fires back before being destroyed)
- Environmental effects triggered by the TNT (explosion particles, screen shake) — noted as nice-to-have but not blocking

---

## 9. File Map (Implementation Reference)

> Not for implementation yet — for planning reference only.

| New File | Purpose |
|---|---|
| `characters/enemy_tower.gd` | HP, hurtbox, PlantZone, destruction signal |
| `characters/unit_hut.gd` | Two visual states, unlock(), interaction zone |
| `characters/units/unit_base.gd` + `.tscn` | Shared AI, Path2D movement, respawn |
| `characters/units/unit_sword.gd/tscn` | Sword unit specifics |
| `characters/units/unit_spear.gd/tscn` | Spear unit specifics |
| `characters/units/unit_bow.gd/tscn` | Bow unit (fires arrow.tscn) |
| `characters/units/unit_healer.gd/tscn` | Healer unit specifics |
| `core/unit_slot_data.gd` | Resource: type, tier, branch, node ref |
| `core/Upgrades/units/unit_upgrade_config.gd` | Upgrade resource definition |
| `core/Upgrades/units/*.tres` | Per-unit upgrade data resources |
| `ui/hud/unit_shop_ui.gd` + `.tscn` | Unit purchase and upgrade UI |

| Modified File | What Changes |
|---|---|
| `level/enemy_spawner.gd` | Tower-linked spawn point array + `_on_tower_destroyed()` |
| `characters/castle_inside.gd` | Add TNT as fixed purchase slot alongside random upgrades |
| `core/upgrade_config.gd` | Add TNT type, carrying state handling |
| `core/run_manager.gd` | New packet handlers for all Phase 5 packets |
| `level/variants/level1.tscn` | Add scripts/hurtboxes to EnemyTowers, add UnitHut scenes, add per-hut Path2Ds, add ground tint Polygons |

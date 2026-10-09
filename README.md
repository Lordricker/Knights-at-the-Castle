# Cadence Blade

A pixel-art action-defense game. Defend your castle from waves of enemies while fighting them head-on across the map, using a rhythm-based "flow timing" attack system. Play solo or with a friend in 2-player online co-op.

![Gameplay](Art/gameplay.gif)
<!-- Move "can you last 8 minutes3.gif" into Art/ and rename it gameplay.gif -->

**Play it:** [itch.io](https://lordricker.itch.io/cadence-blade) · Steam (coming soon)

## Features

- Flow-timing combat: attacks land harder when chained in rhythm
- Run-based coin economy with upgrades bought from the castle blacksmith
- Randomized upgrade offers each run
- 2-player online co-op over WebRTC, with a host-authoritative network model
- Hand-made pixel art and original music

## Tech

| | |
|---|---|
| Engine | Godot 4.6.2 |
| Language | GDScript |
| Networking | WebRTC peer-to-peer, host authoritative |
| Platforms | Windows (Steam), web/desktop builds on itch.io |

## Running the project

1. Install [Godot 4.6.2](https://godotengine.org/download).
2. Clone the repo:
   ```
   git clone https://github.com/Lordricker/Knights-at-the-Castle.git
   ```
3. Open Godot, choose **Import**, and select `cadence-blade/project.godot`.
4. Press **F5** to run.

## Project structure

```
cadence-blade/
├── characters/   Player, enemies, towers, and their scripts
├── core/         Run manager, upgrade system, shared data resources
├── level/        Levels and the enemy spawner
└── ui/           HUD and shop interfaces
Art/              Sprites and source art
Music/            Soundtrack
DESIGN_DOC.md     Design plan for upcoming features
```

## Roadmap

Upcoming work is planned in [DESIGN_DOC.md](DESIGN_DOC.md), including destroyable enemy towers, unit huts with allied AI units, and a branching unit upgrade tree.

## Releases

Builds are tagged in Git and published under [Releases](https://github.com/Lordricker/Knights-at-the-Castle/releases). See the release notes for changes in each version.

## Author

Ben Keith, solo developer · [itch.io](https://lordricker.itch.io)

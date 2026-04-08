# Copilot Instructions — Knights at the Castle

## Project Overview
This is a 2D game project built with the **Godot 4 game engine** (version 4.6.2), developed in GDScript.

## Documentation Reference
When answering questions or writing code for this project, always reference the official Godot 4 documentation:
- **Primary docs**: https://docs.godotengine.org/en/stable/
- Use the stable branch docs, which corresponds to Godot 4.x

When providing code examples, explanations, or architecture advice:
1. Base all suggestions on Godot 4 APIs (not Godot 3).
2. Prefer GDScript unless the user explicitly asks for C# or C++.
3. Link to or cite relevant Godot docs pages when helpful.
4. Use Godot 4 node names, signals, and lifecycle methods (`_ready`, `_process`, `_physics_process`, etc.).
5. Prefer the Godot 4 resource/scene system (`.tscn`, `.tres`) for asset references.

## Project Structure
- `cadence-blade/` — Main Godot project folder (contains `project.godot`)
- `CharacterSprites/` — Sprite sheets for characters (e.g., RedKnightSpriteSheet.png)
- `Animation/` — Animation source files
- `KritaFiles/` — Source art files (.kra)

## Coding Conventions
- Engine: Godot 4.6.2
- Primary language: GDScript
- Scene files: `.tscn`
- Resource files: `.tres`

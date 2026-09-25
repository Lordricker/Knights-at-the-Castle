# Cadence Blade — Multiplayer Setup Guide

This document covers every manual step required to get online multiplayer working.
The code has already been written; follow these steps in order.

---

## Overview of What Was Added

| File | Change |
|---|---|
| `core/firebase_client.gd` | **NEW** — Firebase REST API wrapper (session list, signaling) |
| `core/webrtc_manager.gd` | **NEW** — WebRTC P2P connection manager |
| `ui/menus/main_menu.gd/.tscn` | **NEW** — Main menu (Play / Join / Help) |
| `ui/menus/session_create.gd/.tscn` | **NEW** — Character select + create session |
| `ui/menus/session_join.gd/.tscn` | **NEW** — Lobby browser + join session |
| `core/game_manager.gd` | **MODIFIED** — Session state, peer tracking, RPC level load |
| `core/run_manager.gd` | **MODIFIED** — Network-aware spawning, host-only heartbeat, RPC game-over |
| `characters/character_base.gd` | **MODIFIED** — `network_peer_id`, input isolation, position sync RPC |
| `level/enemy_spawner.gd` | **MODIFIED** — Host-only guard (`is_server()` check) |
| `characters/castle.gd` | **MODIFIED** — Host-authoritative health, `_rpc_sync_health` broadcast |
| `project.godot` | **MODIFIED** — New autoloads, main scene → main_menu.tscn |

---

## Step 1 — Create a Firebase Project

1. Go to [console.firebase.google.com](https://console.firebase.google.com) and sign in.
2. Click **Add project**, name it (e.g. `cadence-blade`), disable Google Analytics if prompted.
3. In the left sidebar go to **Build → Realtime Database**.
4. Click **Create Database** → choose a region → start in **test mode** for now.
5. Copy your database URL — it looks like:
   ```
   https://cadence-blade-default-rtdb.firebaseio.com
   ```

---

## Step 2 — Configure the Firebase URL in Code

Open `cadence-blade/core/firebase_client.gd` and replace the placeholder:

```gdscript
# Line 18 — replace with your actual URL:
const FIREBASE_DB_URL: String = "https://cadence-blade-default-rtdb.firebaseio.com"
```

No trailing slash.

---

## Step 3 — Set Firebase Security Rules

In the Firebase console → Realtime Database → **Rules** tab, paste:

```json
{
  "rules": {
    "sessions": {
      ".read": true,
      "$sessionId": {
        ".write": true
      }
    },
    "signaling": {
      "$sessionId": {
        ".read": true,
        ".write": true
      }
    }
  }
}
```

Click **Publish**. These rules allow the game to read/write sessions and signaling
data. They are intentionally simple for a game with no user accounts. You can
tighten them later if needed.

---

## Step 4 — Wire the Level Scene (RunManager Inspector)

Open your main level scene (e.g. `level/variants/level1.tscn`) and find the
**RunManager** node:

1. In the **Players (Online — wire both)** group, drag:
   - `characters/Players/RedKnight.tscn` → **Red Knight Scene**
   - `characters/Players/GreenArcher.tscn` → **Green Archer Scene**

2. The existing **Players (Offline)** `player_scenes` array still works for solo
   testing — leave it as-is or clear it if you only want online play.

> **Why both?** In multiplayer both peers spawn both character scenes. The character
> whose `network_peer_id` matches the local peer ID reads input; the other is
> driven by network sync RPCs.

---

## Step 5 — Set the Main Scene

The game now boots into the main menu. This was already set in `project.godot`,
but verify it in the editor:

1. **Project → Project Settings → Application → Run → Main Scene**
2. Set it to `res://ui/menus/main_menu.tscn`

---

## Step 6 — Add Character Portraits (Optional but Recommended)

The character select screens use coloured placeholder buttons. To use real portraits:

1. Export a portrait image for each character (e.g. `assets/sprites/UI/portrait_red_knight.png`
   and `portrait_green_archer.png`). Suggested size: 110 × 130 px.

2. In `session_create.gd` and `session_join.gd`, replace the `Button` portrait nodes
   with `TextureButton` nodes loaded from your portrait images:
   ```gdscript
   # Instead of:
   var btn := Button.new()
   btn.self_modulate = COLOR

   # Use:
   var btn := TextureButton.new()
   btn.texture_normal = load("res://assets/sprites/UI/portrait_red_knight.png")
   ```

---

## Step 7 — Test Multiplayer Locally (Two Browser Tabs)

Because WebRTC requires a browser, you **must** export to HTML5 and test in a browser.
Desktop runs from the Godot editor will not have WebRTC available.

### Export to HTML5

1. **Project → Export → Add → Web (Runnable)**
2. Make sure **Export Path** ends in `.html` (e.g. `export/index.html`).
3. Click **Export Project**.

### Serve Locally

WebRTC requires `https://` or `localhost`. The easiest local server:

```bash
# Python 3 (run from the export folder):
python -m http.server 8080
```

Then open two tabs: `http://localhost:8080/index.html`

- **Tab 1**: Click PLAY → select Red Knight → note the session ID → click START
- **Tab 2**: Click JOIN → the session appears → click JOIN → select Green Archer

Both tabs should load the game level with both characters visible.

### Required HTTP Headers for WebRTC

Some browsers require these headers for full WebRTC functionality. If you serve
locally with Python's built-in server these aren't needed, but for production
hosting add them:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Popular hosts like **itch.io** handle this automatically when you enable
"SharedArrayBuffer". GitHub Pages does **not** support this by default.

---

## Step 8 — Hosting the Game Online

Recommended free/cheap options:

| Host | Notes |
|---|---|
| **itch.io** | Upload your HTML5 export as a zip. Enable SharedArrayBuffer in settings. Free. |
| **Netlify** | Drag-and-drop deploy. Add response headers via `netlify.toml`. Free tier. |
| **GitHub Pages** | Requires a custom `_headers` file (Cloudflare proxy trick). More complex. |

For itch.io (simplest):
1. Zip the contents of your export folder (not the folder itself).
2. Upload on itch.io → set Kind to **HTML** → enable **SharedArrayBuffer**.

---

## Step 9 — Mobile Virtual Controls

Mobile browser users need on-screen buttons. This is a **separate feature** to
implement after multiplayer is working. Suggested approach:

- Use `TouchScreenButton` nodes or regular `Button` nodes in a HUD `CanvasLayer`.
- In each button's `pressed` signal, call `Input.action_press("move_left")` etc.
- In each button's `released` signal, call `Input.action_release("move_left")` etc.
- For the joystick, use a custom drag gesture on a `Control` node or the
  Godot asset library plugin **Virtual Joystick** by MarcoFazioRandom.

---

## Architecture Reference

```
Browser A (host, peer ID 1)          Firebase RTDB            Browser B (joiner, peer ID 2)
         |                                  |                           |
   PLAY → session_create               sessions/                  JOIN → session_join
         |--- create_session --------→ {sessionId}                     |--- poll sessions
         |                                  |←------ session list -----+
         |                           signaling/                        |--- write "offer"
         |←--- poll "offer" ---------- {sessionId} -------------------+
         |--- write "answer" -------→           ←---- poll "answer" --+
         |--- write "ice_host" ----→            ←--- write "ice_joiner"|
         |←--- poll "ice_joiner" --+
         |                                                             |
         +======== WebRTC P2P mesh established (mesh_ready) ==========+
         |                                                             |
   _rpc_announce_character --------→ (direct P2P)  ←---- announce ----+
   _rpc_load_level ----------------→ (direct P2P, all peers load game)
         |                                                             |
         +====== Game runs P2P — Firebase idle ========================+
```

**What Firebase handles:** Session registration, lobby listing, WebRTC signaling
(SDP offer/answer + ICE candidates). This happens only at connect time.

**What WebRTC P2P handles:** All gameplay — character positions, actions,
castle health, game-over. Firebase is not involved during gameplay.

---

## Known Limitations & Future Work

| Limitation | Impact | Fix |
|---|---|---|
| Enemy positions not synced | Clients see their own copy of enemies; can't see the host's enemies | Add `MultiplayerSpawner` + `MultiplayerSynchronizer` on enemy scenes |
| Enemy health not synced | Both peers can kill the same enemy independently | Host-authoritative enemy health + `rpc_take_damage` on `EnemyBase` |
| No relay fallback (by choice) | Players whose network blocks a direct connection can't play at all — historically ~10–30% on mobile/corporate networks | Only worth fixing with a relay that has real bandwidth; see below |
| Relay unavailable over TCP/TLS on desktop | Players whose network blocks UDP can't connect from the Steam build (browsers are fine) | Limitation of libjuice in the WebRTC GDExtension; no workaround in-game |
| Session max 3 players | Star topology: host (slot 1) + up to 2 joiners (slots 2/3), one per character. `WebRTCManager` keeps a `PeerLink` per joiner slot; joiners never connect to each other. Signaling namespace is per slot: `/signaling/{sid}/{slot}/...`. A dropped joiner frees its slot for a replacement (fresh character = wiped upgrades). | Full mesh / N>3 would need per-joiner link generalization beyond `HOST_SLOTS` |
| No session rejoin | Refreshing the browser exits the session | Implement session state save/restore via localStorage |

### Relay (TURN) — deliberately off

**Runs are peer-to-peer, hosted on a player's PC.** All gameplay traffic — the 20 Hz
state stream, 60 Hz positions, hits, purchases — goes directly between players and
never through a server. Firebase only carries the handshake.

STUN gets most players connected directly. A player whose network blocks that would
need a TURN relay, which carries *every packet of the run* and so costs real
bandwidth. Measured at level-1 peak (3 players, 19 enemies): a state packet is
~1.8 KB at 20 Hz per joiner, so one relayed 10-minute trio run moves ~24 MB, billed
~48 MB as ingress+egress. Metered's free tier is 500 MB/month — about ten sessions.

So `IceConfig.ICE_ENDPOINT` is empty and there is no relay. Players who can't connect
directly get a clear message suggesting a phone hotspot, and that's accepted.

**Never hardcode a relay credential in `webrtc_manager.gd`.** One used to live there;
it shipped inside every build, the repo is public, so it had to be treated as leaked.
If you ever add a relay with real bandwidth (self-hosted coturn, or a paid plan), use
`services/turn-credentials/` — a Cloudflare Worker that keeps the provider's secret
key server-side and hands the game a short-lived credential. Set `ICE_ENDPOINT` to its
URL and everything else already works.

Reducing the state-packet size (round positions to whole pixels, drop the constant
flow-window fields, send only enemies that changed) would cut the per-run cost by well
over half, and is worth doing before ever paying for relay bandwidth.

### Syncing Enemies Properly (Future)

To fully sync enemies between peers:

1. Add a `MultiplayerSpawner` node to the level, child of the enemy container.
   - Set its **Spawn Path** to the enemy container node.
   - Register all enemy scenes in the **Auto Spawn List**.
2. Enemy spawning on the host automatically replicates to clients.
3. Add a `MultiplayerSynchronizer` to your enemy base scene.
   - Sync `global_position`, `velocity`, and `health` properties.
4. Guard `take_damage()` in `EnemyBase` with `if not multiplayer.is_server(): return`.
5. Broadcast enemy death via `@rpc("authority", "reliable", "call_local")`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Sessions don't appear in lobby | Wrong `FIREBASE_DB_URL` or rules not published |
| "Firebase error (code 401)" | Database rules are still "locked mode" — set to test mode |
| "WebRTCPeerConnection not available" | Testing in the Godot editor (desktop) — use HTML5 export |
| Connection times out after 40s | NAT firewall/mobile network — add TURN server |
| Both characters appear but don't move | `network_peer_id` not set — check RunManager has both scenes wired |
| Castle health desyncs | Enemy spawner running on both peers — check `is_server()` guard in `enemy_spawner.gd` |
| Game-over fires only on host | `_rpc_game_over` call — ensure RunManager node is the same name on both peers so RPC routes correctly |

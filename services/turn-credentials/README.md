# TURN credential service

> **Not deployed, and not needed right now.** The game runs peer-to-peer with no relay:
> `IceConfig.ICE_ENDPOINT` is empty. A single relayed 10-minute trio run costs ~48 MB of
> Metered's 500 MB/month free tier, so a relay would cover about ten sessions — not
> enough to depend on. This worker is kept ready for the day there's a relay with real
> bandwidth behind it (self-hosted coturn, or a paid plan).
>
> **Still do step 1 below:** the old credential is public and must be deleted.

A Cloudflare Worker that hands the game a **short-lived** Metered relay credential.

The game used to carry a permanent relay username/password in
`cadence-blade/core/webrtc_manager.gd`. That shipped inside every build and sat in a
public git repo, so anyone could extract it and spend the relay quota. Now the Metered
**secret key** lives only in this worker, and the game fetches a credential at runtime
from `GET /ice`.

```
Game (Steam or web)  ──GET /ice──▶  this worker  ──POST──▶  Metered API
                     ◀─iceServers─                ◀─user/pass─
```

If the worker is unreachable the game runs **STUN-only**: direct connections still
work, only players who need a relay fail, and hosting is never blocked.

---

## Deploy it (when a relay is worth having)

### 1. Delete the leaked credential first

In the Metered dashboard, delete the credential whose username is
`28a7d695fb2888e9055f8a30`. That pair is public — it is in this repo's git history and
inside every build shipped so far, so anyone can use it to spend the 500 MB.

Delete rather than rotate: nothing uses it any more. Only create a replacement if and
when you deploy this worker.

### 2. Get your Metered secret key and credential URL

This worker mints its own credential pairs, so it needs the account-level **secret
key**, *not* a TURN username/password. A username/password never belongs in this repo
or in the game — that is the leak this whole service exists to avoid.

In the Metered dashboard, find your **secret key** and your TURN app's
create-credential endpoint. It looks like one of:

```
https://<appname>.metered.live/api/v2/turn/project/<projectId>/credential
https://mla2.metered.live/api/v1/turn/credential
```

Either works — the worker just POSTs to whatever you give it, adding `?secretKey=…`.
Check it by hand before deploying (this prints a username/password if it is right):

```bash
curl -s -X POST "<YOUR_CREDENTIAL_URL>?secretKey=<YOUR_SECRET_KEY>" \
  -H 'content-type: application/json' -d '{"expiryInSeconds":3600,"label":"test"}'
```

### 3. Create the KV namespace

Needs a free Cloudflare account. No card.

```bash
cd services/turn-credentials
npm install
npx wrangler login
npx wrangler kv namespace create TURN_KV     # older wrangler: kv:namespace create
```

Paste the printed `id` into `wrangler.toml`, replacing `PASTE_KV_NAMESPACE_ID_HERE`.

### 4. Set the secrets

These are stored by Cloudflare, not in the repo:

```bash
npx wrangler secret put METERED_CREDENTIAL_URL
npx wrangler secret put METERED_SECRET_KEY
```

### 5. Deploy and test

```bash
npx wrangler deploy
curl -s https://cadence-blade-turn.<your-subdomain>.workers.dev/ice | head -c 400
```

You want `"turn": true` and five `iceServers` entries. If you see `"turn": false`
the reply includes an `error` field saying why; `npx wrangler tail` shows live logs.

> The very first request mints the first credential, and Metered needs up to ~2
> minutes to propagate it. Relay may not work for that first couple of minutes.

### 6. Point the game at it

In `cadence-blade/core/ice_config.gd`:

```gdscript
const ICE_ENDPOINT: String = "https://cadence-blade-turn.<your-subdomain>.workers.dev/ice"
```

Then re-export (`steam/build_demo.sh`) and redeploy the web build. On boot the game
logs `[ICE] 5 servers, relay available`, or a line explaining why it fell back.

---

## How rotation works

Two Metered behaviours shape it: a new credential takes **up to ~2 minutes to
propagate**, and an expiring credential **stops working instantly, cutting live
calls**. So the worker never mints per request.

- One credential is shared by every player for `ROTATE_AFTER_SECONDS` (6h).
- It is minted with a much longer `CRED_EXPIRY_SECONDS` (24h) lifetime.
- While a freshly minted credential is still propagating (`PROPAGATION_SECONDS`,
  150s) the worker keeps serving the previous one.
- So a credential handed out is always already live, with **≥18h left** — it can
  never expire in the middle of a run.
- If Metered is down, the last good credential keeps being served rather than
  dropping every player to STUN.

Because everyone gets the same credential within a window, the reply is edge-cached
(`EDGE_CACHE_SECONDS`, 300s). Metered gets ~4 calls a day and KV ~4 writes a day,
far inside the free tiers.

Run the tests for this logic (no account or network needed):

```bash
npm test
```

## What this does and does not protect

**Does:** the long-lived secret key never ships in a build, so a credential pulled out
of the game dies on its own within a day, and you can rotate everything by running
`npx wrangler deploy` — no game patch, and old builds pick it up too.

**Does not:** the game has no accounts, so `/ice` has to be callable by anyone. A
determined person can call it and get the current credential, same as any WebRTC game.
What that costs them is a credential that expires, on an endpoint you can revoke.

If you see relay abuse:

1. Rotate the Metered credential (step 1) — old ones die immediately.
2. Add a rate-limiting rule in the Cloudflare dashboard (**Security → WAF → Rate
   limiting rules**; the free plan includes one). Something like 10 requests per
   minute per IP on this route is generous for real players, since the game fetches
   once per launch.
3. Watch usage on Metered and set a usage alert if they offer one.

## Config reference

| Where | Name | Meaning |
|---|---|---|
| secret | `METERED_CREDENTIAL_URL` | POST endpoint that mints a credential |
| secret | `METERED_SECRET_KEY` | Metered secret key, sent as `?secretKey=` |
| var | `TURN_HOST` | Relay hostname put into the TURN URLs |
| var | `STUN_URL` | STUN entry included in every reply |
| var | `CRED_EXPIRY_SECONDS` | Credential lifetime requested from Metered |
| var | `ROTATE_AFTER_SECONDS` | How long one credential is handed out |
| var | `PROPAGATION_SECONDS` | Grace period before serving a new credential |
| var | `EDGE_CACHE_SECONDS` | Edge-cache lifetime of the `/ice` reply |

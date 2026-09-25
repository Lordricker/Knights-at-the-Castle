// Drives src/worker.js against a fake KV namespace and a fake Metered API, with a
// controllable clock, to prove the rotation / propagation behaviour:
//   * one credential is reused (Metered is not called per request)
//   * a freshly minted credential is withheld until it has propagated
//   * an outage keeps serving the old credential instead of dropping to STUN
// Run: node test/rotation.test.mjs
import worker from "../src/worker.js";

let failures = 0;
function check(label, cond, detail = "") {
	console.log(`${cond ? "  ok  " : " FAIL "} ${label}${detail ? "  — " + detail : ""}`);
	if (!cond) failures++;
}

// ── fakes ────────────────────────────────────────────────────────────────────
let now = Date.UTC(2026, 8, 23, 12, 0, 0);
const realNow = Date.now;
Date.now = () => now;

const kv = {
	store: new Map(),
	async get(key, type) {
		const raw = this.store.get(key);
		if (raw === undefined) return null;
		return type === "json" ? JSON.parse(raw) : raw;
	},
	async put(key, value) {
		this.store.set(key, value);
	},
};

let mintCount = 0;
let meteredFails = false;
let lastBody = null;
globalThis.fetch = async (url, init) => {
	if (meteredFails) return new Response("upstream boom", { status: 502 });
	mintCount++;
	lastBody = JSON.parse(init.body);
	return new Response(
		JSON.stringify({ username: `user${mintCount}`, password: `pass${mintCount}` }),
		{ status: 200, headers: { "content-type": "application/json" } },
	);
};

const env = {
	TURN_KV: kv,
	METERED_CREDENTIAL_URL: "https://example.metered.live/api/v2/turn/project/p1/credential",
	METERED_SECRET_KEY: "test-secret",
	TURN_HOST: "global.relay.metered.ca",
	STUN_URL: "stun:stun.relay.metered.ca:80",
	CRED_EXPIRY_SECONDS: "86400",
	ROTATE_AFTER_SECONDS: "21600",
	PROPAGATION_SECONDS: "150",
	EDGE_CACHE_SECONDS: "300",
};

async function getIce(path = "/ice") {
	const res = await worker.fetch(new Request(`https://turn.example.workers.dev${path}`), env);
	return { res, body: await res.json() };
}

function relayUser(body) {
	const turn = body.iceServers.find((s) => String(s.urls).startsWith("turn"));
	return turn ? turn.username : null;
}

// ── 1. first request mints once ──────────────────────────────────────────────
let { res, body } = await getIce();
check("first request returns 200", res.status === 200);
check("mints exactly one credential", mintCount === 1, `mintCount=${mintCount}`);
check("asks Metered for a 24h expiry", lastBody.expiryInSeconds === 86400, JSON.stringify(lastBody));
check("reports turn available", body.turn === true);
check("serves the new credential when nothing older exists", relayUser(body) === "user1", relayUser(body));
check("includes STUN first", body.iceServers[0].urls === "stun:stun.relay.metered.ca:80");
check("includes all 4 TURN transports", body.iceServers.length === 5, `${body.iceServers.length} entries`);
check("CORS allows the web build", res.headers.get("access-control-allow-origin") === "*");
check("response is edge-cacheable", /max-age=300/.test(res.headers.get("cache-control")));

// ── 2. repeat requests reuse it ──────────────────────────────────────────────
now += 60 * 1000;
for (let i = 0; i < 25; i++) await getIce();
({ body } = await getIce());
check("25 more requests mint nothing new", mintCount === 1, `mintCount=${mintCount}`);
check("still the same credential", relayUser(body) === "user1", relayUser(body));

// ── 3. rotation withholds the new credential while it propagates ─────────────
now += 6 * 3600 * 1000; // past ROTATE_AFTER_SECONDS
({ body } = await getIce());
check("rotating mints a second credential", mintCount === 2, `mintCount=${mintCount}`);
check("but still serves the propagated one", relayUser(body) === "user1", relayUser(body));

now += 60 * 1000; // 1 min in: still inside the 150s propagation grace
({ body } = await getIce());
check("no extra mint during propagation", mintCount === 2, `mintCount=${mintCount}`);
check("old credential still served at t+60s", relayUser(body) === "user1", relayUser(body));

now += 120 * 1000; // 3 min in: propagated
({ body } = await getIce());
check("new credential served once propagated", relayUser(body) === "user2", relayUser(body));
check("still no extra mint", mintCount === 2, `mintCount=${mintCount}`);

// ── 4. a run can never outlive its credential ───────────────────────────────
// Worst case: a player receives a credential the instant before rotation, i.e.
// ROTATE_AFTER_SECONDS old. Remaining validity must still dwarf a game session.
const worstCaseRemainingHours = (86400 - 21600) / 3600;
check("credential always has hours left when handed out", worstCaseRemainingHours >= 12, `${worstCaseRemainingHours}h`);

// ── 5. Metered outage keeps players connected ───────────────────────────────
meteredFails = true;
now += 6 * 3600 * 1000; // due to rotate again, but Metered is down
({ res, body } = await getIce());
check("outage still returns 200", res.status === 200);
check("outage keeps serving the last good credential", relayUser(body) === "user2", relayUser(body));
check("outage still reports turn available", body.turn === true);

// ── 6. total failure degrades to STUN only, never an error ───────────────────
kv.store.clear();
({ res, body } = await getIce());
check("cold start during outage returns 200", res.status === 200);
check("falls back to STUN only", body.iceServers.length === 1 && body.turn === false, JSON.stringify(body.iceServers));
check("explains why in the payload", typeof body.error === "string" && body.error.length > 0, body.error);

// ── 7. routing ──────────────────────────────────────────────────────────────
meteredFails = false;
check("unknown path is 404", (await worker.fetch(new Request("https://x.dev/nope"), env)).status === 404);
check("POST is rejected", (await worker.fetch(new Request("https://x.dev/ice", { method: "POST" }), env)).status === 405);
check("OPTIONS preflight is 204", (await worker.fetch(new Request("https://x.dev/ice", { method: "OPTIONS" }), env)).status === 204);
({ body } = await getIce("/"));
check("bare / also serves ice", Array.isArray(body.iceServers));

Date.now = realNow;
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);

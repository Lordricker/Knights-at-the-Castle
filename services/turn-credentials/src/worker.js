/**
 * Cadence Blade — TURN credential service.
 *
 * The game used to ship a permanent Metered relay username/password inside every
 * build. This worker replaces that: the Metered *secret key* lives only here, and
 * the game fetches a short-lived relay credential at runtime from GET /ice.
 *
 * Two Metered behaviours drive the design:
 *   1. A new credential takes up to ~2 minutes to propagate across their network.
 *   2. When a credential expires it stops working immediately, cutting live calls.
 * So we never mint per request. One credential is shared by everyone for
 * ROTATE_AFTER_SECONDS, minted with a much longer CRED_EXPIRY_SECONDS lifetime,
 * and while a freshly minted one is still propagating we keep serving the
 * previous one. A player therefore always receives a credential that is already
 * live and has hours of validity left — it can never expire mid-run.
 *
 * Everyone gets the same credential during a window, so the response is safe to
 * cache at the edge; that keeps KV reads (and Metered calls) tiny.
 */

const DEFAULTS = {
	TURN_HOST: "global.relay.metered.ca",
	STUN_URL: "stun:stun.relay.metered.ca:80",
	/// How long a minted credential stays valid at Metered.
	CRED_EXPIRY_SECONDS: 86400,
	/// How long one credential is handed out before we mint the next.
	ROTATE_AFTER_SECONDS: 21600,
	/// Grace period during which a just-minted credential is not served yet.
	PROPAGATION_SECONDS: 150,
	/// Edge-cache lifetime of the /ice response.
	EDGE_CACHE_SECONDS: 300,
};

const KV_KEY = "state";

function conf(env, key) {
	const raw = env[key];
	if (raw === undefined || raw === null || raw === "") return DEFAULTS[key];
	if (typeof DEFAULTS[key] === "number") {
		const n = Number(raw);
		return Number.isFinite(n) && n > 0 ? n : DEFAULTS[key];
	}
	return raw;
}

/** Build the ICE list the game expects. Mirrors the URL set the game shipped before. */
function buildIceServers(env, cred) {
	const stun = { urls: conf(env, "STUN_URL") };
	if (!cred) return [stun];
	const host = conf(env, "TURN_HOST");
	const username = cred.username;
	const credential = cred.password;
	return [
		stun,
		{ urls: `turn:${host}:80`, username, credential },
		{ urls: `turn:${host}:80?transport=tcp`, username, credential },
		{ urls: `turn:${host}:443`, username, credential },
		{ urls: `turns:${host}:443?transport=tcp`, username, credential },
	];
}

/** Ask Metered for a new expiring credential. */
async function mintCredential(env) {
	if (!env.METERED_CREDENTIAL_URL || !env.METERED_SECRET_KEY) {
		throw new Error("METERED_CREDENTIAL_URL / METERED_SECRET_KEY not configured");
	}
	const url = new URL(env.METERED_CREDENTIAL_URL);
	url.searchParams.set("secretKey", env.METERED_SECRET_KEY);

	const res = await fetch(url.toString(), {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({
			expiryInSeconds: conf(env, "CRED_EXPIRY_SECONDS"),
			label: `cadence-blade-${new Date().toISOString().slice(0, 16)}`,
		}),
	});
	if (!res.ok) {
		throw new Error(`Metered returned HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
	}
	const body = await res.json();
	if (!body || !body.username || !body.password) {
		throw new Error("Metered response had no username/password");
	}
	return { username: body.username, password: body.password, createdAt: Date.now() };
}

/**
 * The credential to hand out right now, minting and rotating as needed.
 * Returns null only when we have nothing usable at all (then: STUN only).
 */
async function currentCredential(env) {
	const now = Date.now();
	const rotateMs = conf(env, "ROTATE_AFTER_SECONDS") * 1000;
	const propagationMs = conf(env, "PROPAGATION_SECONDS") * 1000;
	const expiryMs = conf(env, "CRED_EXPIRY_SECONDS") * 1000;

	const state = (await env.TURN_KV.get(KV_KEY, "json")) || {};
	const current = state.current || null;
	const previous = state.previous || null;

	if (current && now - current.createdAt < rotateMs) {
		// Still inside this credential's window. If it was minted moments ago it may
		// not have propagated yet, so prefer the one it replaced.
		if (now - current.createdAt < propagationMs && previous) return previous;
		return current;
	}

	// Time to rotate (or nothing stored yet).
	let fresh;
	try {
		fresh = await mintCredential(env);
	} catch (err) {
		// Minting failed. An aged-out credential is still valid at Metered until its
		// own expiry, so keep using it rather than dropping every player to STUN.
		if (current && now - current.createdAt < expiryMs) return current;
		throw err;
	}
	await env.TURN_KV.put(KV_KEY, JSON.stringify({ current: fresh, previous: current }));
	// The new one needs to propagate; serve the outgoing credential until it has.
	if (current && now - current.createdAt < expiryMs) return current;
	return fresh;
}

const CORS = {
	// The web build runs from a browser origin, so it needs this. Nothing secret is
	// exposed by allowing any origin: the credential is the same for every player.
	"access-control-allow-origin": "*",
	"access-control-allow-methods": "GET, OPTIONS",
	"access-control-max-age": "86400",
};

export default {
	async fetch(request, env) {
		if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
		if (request.method !== "GET" && request.method !== "HEAD") {
			return new Response("Method not allowed", { status: 405, headers: CORS });
		}
		const path = new URL(request.url).pathname.replace(/\/+$/, "");
		if (path !== "" && path !== "/ice") {
			return new Response("Not found", { status: 404, headers: CORS });
		}

		let cred = null;
		let error = null;
		try {
			cred = await currentCredential(env);
		} catch (err) {
			error = String(err && err.message ? err.message : err);
			console.error("TURN credential unavailable:", error);
		}

		// 200 even on failure: the game can still connect directly over STUN, and a
		// hard error would only turn a degraded state into a broken one.
		const body = {
			iceServers: buildIceServers(env, cred),
			turn: cred !== null,
			ttl: conf(env, "ROTATE_AFTER_SECONDS"),
		};
		if (error) body.error = error;

		return new Response(JSON.stringify(body), {
			headers: {
				...CORS,
				"content-type": "application/json; charset=utf-8",
				"cache-control": `public, max-age=${conf(env, "EDGE_CACHE_SECONDS")}`,
			},
		});
	},
};

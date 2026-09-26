#!/usr/bin/env node
/**
 * A DockAI server with invented data, for the simulator UI tests.
 *
 * Answers every tRPC procedure and REST route the apps call from the same
 * fixtures the web dashboard's design gate uses (ci/fixtures.mjs, a copy of
 * apps/web/audit/fixtures.mjs kept identical by a test in the monorepo), plus
 * the few device routes only the apps call. Nothing here is real: no token
 * is checked and nothing leaves the runner.
 *
 * Writes what it saw to ci/out/: every request, and every procedure the apps
 * called that has no fixture — a screen showing an error in a screenshot is
 * usually one of those.
 *
 *   node ci/mock-server.mjs            # listens on 127.0.0.1:8787
 */
import { createServer } from "node:http";
import { mkdirSync, appendFileSync, writeFileSync } from "node:fs";
import { makeApi } from "./fixtures.mjs";

const PORT = Number(process.env.PORT ?? 8787);
const OUT = new URL("./out/", import.meta.url);
mkdirSync(OUT, { recursive: true });
const missing = new Set();
const api = makeApi("default", {}, { missing, stateful: true });

/** Routes only the iOS and watch apps call. */
const deviceRoutes = {
  "GET /api/devices/push-config": () => ({ mode: "direct" }),
  "POST /api/devices/apns-token": () => ({ ok: true }),
  "POST /api/devices/action": (b) => ({ message: b?.kind === "permission" ? (b.allow ? "Allowed" : "Denied") : "Sent." }),
  "POST /api/devices/pair": () => ({ token: "dka_test", server: `http://127.0.0.1:${PORT}`, deviceId: "dev_test" }),
};

const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
    const key = `${req.method} ${url.pathname}`;
    appendFileSync(new URL("requests.log", OUT), `${new Date().toISOString()} ${key}${url.search ? " " + decodeURIComponent(url.search).slice(0, 200) : ""}\n`);
    if (deviceRoutes[key]) {
      let parsed = null;
      try { parsed = body ? JSON.parse(body) : null; } catch {}
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(deviceRoutes[key](parsed)));
      return;
    }
    const r = api.respond({ method: req.method, url: url.pathname + url.search, body });
    if ("hang" in r) return; // never answers, as a slow server would
    res.writeHead(r.status, { "content-type": r.contentType });
    if (r.contentType === "text/event-stream") { res.write(r.body); return; } // held open
    res.end(r.body);
    writeFileSync(new URL("missing.json", OUT), JSON.stringify([...missing].sort(), null, 2));
  });
});
server.listen(PORT, "127.0.0.1", () => console.log(`[mock-server] http://127.0.0.1:${PORT}`));

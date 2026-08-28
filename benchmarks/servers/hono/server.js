// Hono (on Bun) empty-200 HTTP server.
// Spawned by the benchmarks package: bun server.js  (PORT env overrides).
// Requires hono: npm install  in this directory.
// Bun picks up the default export { port, fetch } as its server config.
import { Hono } from "hono";

const app = new Hono();

app.get("/", (c) => c.body(null, 200));

export default {
	port: Number(process.env.PORT || 8098),
	fetch: app.fetch,
};

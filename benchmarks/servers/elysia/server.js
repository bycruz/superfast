// Elysia (Bun) empty-200 HTTP server.
// Spawned by the benchmarks package: bun server.js  (PORT env overrides).
// Requires elysia: npm install  in this directory.
import { Elysia } from "elysia";

const port = Number(process.env.PORT || 8097);

new Elysia()
  .get("/", () => "")
  .listen(port);

console.error(`elysia listening on 127.0.0.1:${port}`);

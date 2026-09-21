// Bun empty-200 HTTP server via Bun.serve (comparable to superfast's bench).
// Spawned by the benchmarks package: bun server.js  (PORT env overrides).
const port = Number(process.env.PORT || 8092);
const hostname = process.env.HOST || "127.0.0.1";

Bun.serve({
  port,
  hostname,
  fetch() {
    return new Response();
  },
});

console.error(`bun listening on ${hostname}:${port}`);

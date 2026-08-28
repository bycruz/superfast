// Node.js empty-200 HTTP server (comparable to superfast's bench server).
// Spawned by the benchmarks package: node server.js  (PORT env overrides).
const http = require("http");

const port = Number(process.env.PORT || 8091);
const host = process.env.HOST || "127.0.0.1";

const server = http.createServer((req, res) => {
  // Content-Length: 0 avoids node's chunked encoding so the response is a
  // plain empty 200, the same shape superfast produces.
  res.writeHead(200, { "Content-Length": "0" });
  res.end();
});

server.listen(port, host, () => {
  console.error(`node listening on ${host}:${port}`);
});

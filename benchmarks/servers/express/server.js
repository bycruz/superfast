// Express empty-200 HTTP server.
// Spawned by the benchmarks package: node server.js  (PORT env overrides).
// Requires express: npm install  in this directory.
const express = require("express");

const port = Number(process.env.PORT || 8096);
const host = process.env.HOST || "127.0.0.1";

const app = express();

app.get("/", (req, res) => {
  res.set("Content-Length", "0");
  res.status(200).end();
});

app.listen(port, host, () => {
  console.error(`express listening on ${host}:${port}`);
});

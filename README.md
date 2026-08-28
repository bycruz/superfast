# superfast

An incredibly fast HTTP server for LuaJIT on Linux, built on io_uring.

```
lde test  →  27 tests green
wrk -t2 -c64  →  ~150-200k req/s hello-world keep-alive (single core)
```

## Benchmark vs just-js & node

Empty-200 keep-alive, wrk, both servers pinned to the same core (i7-9700F,
loopback). The machine's `powersave` governor makes absolute numbers drift
with thermal state, so interleave runs and compare the ratio:

| server | req/s (wrk -t2 -c64) | vs just-js |
|---|---|---|
| just-js (epoll + picohttpparser) | ~242k | 1.0× |
| **superfast (io_uring + LuaJIT)** | **~231k** | **~0.96×** |
| node (libuv) | ~34k | ~0.14× |

Reproduce: `lde ./bench/server.lua` then `wrk -t2 -c64 -d10s http://127.0.0.1:8080/`.
just-js's `http/mini.js` is the comparison server. Numbers are medians of
interleaved runs (the machine's `powersave` governor drifts with thermal
state); superfast occasionally wins individual pairs.

The hot path was profiled (`perf`) and rebuilt around it:

- The request parser scans a single growable FFI buffer (allocated once per
  connection) with libc `memmem`/`memchr`/`memcmp` on pointers + offsets —
  no Lua strings or tables are created for buffering or parsing.
- The `req` object is **pooled and lazy**: `method`/`path`/`query`/`headers`/
  `body` materialize from the buffer only on first access and are only valid
  while the handler runs (handlers must be synchronous; don't retain `req`).
  The parser's own needs (content-length, connection, transfer-encoding) are
  read straight from the buffer with byte compares.
- Response heads are cached per second, so an empty-200 response costs zero
  allocations. A handler that ignores `req` allocates nothing at all.
- Evolution: pattern matching was ~30% of CPU → plain scans → pooled lazy
  objects; GC + allocation dropped from ~55% to a few percent of server CPU.

## What's inside

| Module | What it is |
|---|---|
| `superfast` | High-level HTTP server: `serve({ port, handler })` |
| `superfast.uring` | io_uring bindings (vendored liburing, camelCase Lua API) |
| `superfast.httpParser` | Streaming HTTP/1.x request parser (pipelining + keep-alive aware) |
| `superfast.ssl` | OpenSSL bindings + async memory-BIO TLS sessions |

- **io_uring**: `IORING_SETUP_DEFER_TASKRUN | SINGLE_ISSUER | COOP_TASKRUN`
  when the kernel supports them, provided buffers (`IOSQE_BUFFER_SELECT`) for
  the receive path (zero per-connection allocations), and responses sent
  straight from the Lua string with the reference pinned until the send CQE
  lands.
- **TLS**: OpenSSL rides on memory BIOs, so the handshake and record layer
  are fully async over the same io_uring ops — OpenSSL never touches the fd.
  The bindings load the **system** OpenSSL (`libssl`/`libcrypto`); only the
  liburing native dependency is built by `build.lua`.
- Linux only for now. Non-Linux errors out in `build.lua`.

## Quick start

```lua
local superfast = require("superfast")

superfast.serve({
	port    = 8080,
	handler = function(req)
		if req.path == "/" then
			return 200, { ["Content-Type"] = "text/html" }, "<h1>hello</h1>"
		end
		return 404, { ["Content-Type"] = "text/plain" }, "not found"
	end,
})
```

Handlers return `status, headers, body` (or a table `{ status=, headers=, body= }`).
`req` has `method`, `path`, `query`, `version`, `headers` (lower-cased keys),
`body`, and `keepAlive`. `Connection: close` on a request closes after the
response; otherwise connections are kept alive.

### TLS

```lua
superfast.serve({
	port = 8443,
	certFile = "cert.pem",
	keyFile  = "key.pem",
	handler  = handler,
})
```

### Raw bindings

```lua
local uring = require("superfast").uring
local ring  = uring.Ring.new(1024, { aggressive = true })

local sqe = ring:getSqe()
ring:prepAccept(sqe, listenFd, 0)
ring:sqeSetData(sqe, 0)
ring:submit()
local cqe = ring:waitCqe()
-- ring:cqeRes(cqe), ring:cqeData(cqe), ring:cqeBid(cqe) ...
```

See `examples/foo/` for a complete package that depends on superfast and
serves some dumb HTML:

```
cd examples/foo && lde run    # http://localhost:8080
```

## Benchmark suite (Justfile)

`just bench` load-tests five HTTP servers with the same empty-200 keep-alive
workload and prints req/s, latency, errors and memory:

| server | runtime |
|---|---|
| `node` | Node.js `http` (`bench/servers/node.js`) |
| `bun` | `Bun.serve` (`bench/servers/bun.js`) |
| `superfast` | LuaJIT + io_uring (`bench/server.lua`) |
| `python` | stdlib `http.server`/`ThreadingHTTPServer` (`bench/servers/python.py`) |
| `lapis` | Lua + Lapis CLI on OpenResty (`bench/servers/lapis/`) |

```
just deps          # build wrk, install lapis (luarocks), build OpenResty (first run)
just bench         # all five, comparison table
just bench-node    # one server
just DUR=5 bench   # shorter run
just PIN=2 bench   # pin every server to CPU 2 (single-core comparison)
```

Memory columns: `rss` = resident set size of the whole process tree at the end
of the run; `peak` = highest single-process RSS (VmHWM) during the run.

Lapis runs under OpenResty with `num_workers = 1` (see
`bench/servers/lapis/config.lua`) so it is a single-worker server like
superfast. The machine's `powersave` governor drifts with thermal state, so
re-run and compare ratios rather than absolute numbers.

## Design notes

- One io_uring ring per server; sockets are kept blocking so `recv`/`accept`
  park in the kernel instead of returning `-EAGAIN` (which would need
  poll-based re-arming).
- At most one fd operation in flight per connection (`recv` XOR `send` XOR
  `close`), which makes teardown race-free.
- Receive uses provided buffers: the kernel picks a buffer from a registered
  pool and reports its id on the CQE; buffers are re-provided after use.
- liburing's `io_uring_peek_cqe()` *blocks* when the CQ is empty in 2.9, so
  the ring bindings read the CQ head/tail directly for a true non-blocking
  peek.

## Layout

```
build.lua            vendored liburing (download + compile → liburing.so)
src/init.lua         public API (serve, Server, module aliases)
src/io_uring.lua     io_uring bindings
src/http_parser.lua  streaming request parser
src/openssl.lua      OpenSSL bindings (system libs) + TLS session
src/server.lua       event loop + connection state machine
bench/server.lua     hello-world benchmark server (wrk)
tests/               io_uring / parser / server / TLS integration tests
examples/foo/        example lde package (dumb HTML server)
```

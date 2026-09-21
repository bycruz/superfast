# superfast architecture

An HTTP/1.1 server for LuaJIT on Linux. One process, one io_uring ring, blocking
sockets (so `recv`/`accept` park in the kernel instead of spinning on `-EAGAIN`).

## Modules

| module | role |
|---|---|
| `src/init.lua` | public API: `serve()`, `Server`, module aliases |
| `src/io_uring.lua` | io_uring bindings over liburing; owns SQE/CQE plumbing |
| `src/http_parser.lua` | streaming request parser (pipelining, keep-alive) |
| `src/server.lua` | event loop and per-connection state machine |
| `src/openssl.lua` | OpenSSL bindings; async TLS over memory BIOs |

## Event loop

```
loop:
  serveCq()          -- reap every completion already in the CQ (no syscall)
  submitAndWait(1)   -- one io_uring_enter: submit queued SQEs + block for one
```

One syscall per iteration. `serveCq` counts the ready CQEs once and reaps them in
a counted loop, so it never touches the kernel; every completion it processes
queues SQEs (recv re-arm, buffer return, response), which the following
`submit_and_wait` submits before blocking. Under saturation that is roughly one
`io_uring_enter` per five to six requests; at light load it replaces the usual
submit-then-wait pair with a single call.

Completions are routed by the `user_data` value attached at submission:
`0` listener, `2^53-1` buffer-pool provide, otherwise the connection id.
`Server:dispatch` reads `cqe.user_data` and `cqe.res` straight out of the CQ
entry (no liburing call per completion).

**Invariant:** at most one fd operation is in flight per connection —
`recv` XOR `send` XOR `close`. Teardown therefore has no races: a connection in
`INFLIGHT_CLOSE` ignores stray completions, ids are never reused, and
`Server.conns[id]` is cleared only in `onClosed`.

## Receive buffers

The kernel writes into a pool of provided buffers (`IOSQE_BUFFER_SELECT`); the
chosen buffer's id arrives in the high 16 bits of `cqe.flags`. A used buffer is
handed back with one `PROVIDE_BUFFERS` SQE after the request in it has been
parsed. If the pool runs dry the recv completes with `-ENOBUFS`: the pool grows
(64 buffers at a time up to `maxBuffers`) and the recv is re-armed instead of
dropping the connection. The read path allocates no Lua objects.

## Parser

Bytes accumulate in one growable FFI buffer per connection and are scanned with
`memmem`/`memchr`/`memcmp` on pointers and offsets — no Lua strings are created
for buffering or scanning. All per-message state lives in the `parser_state`
struct, so the hot path does direct memory access.

`req` is pooled per parser and lazy: `method`, `path`, `query`, `headers` and
`body` materialize on first access and are cached. **Lifetime contract:** `req`
(and `req.headers`) is only valid while the handler runs; handlers must be
synchronous and must not retain it. Materialized string values are copies and
are safe to keep.

## Response path

```
handler -> buildResponse -> queueOut -> issueSend -> prep_send
```

The response head is cached per second keyed by (status line, keep-alive,
body length) — it embeds `Date` — so a repeated empty-200 response costs no
allocations. The per-connection queue is a cursor-indexed array, not
`table.remove`. `prep_send` takes the Lua string directly: the string stays
reachable as `conn.curOut` until the send completion lands, so there is no copy
and no per-response pointer cast. Sends pass `MSG_NOSIGNAL`, because io_uring
runs the send in the caller's task context and a reset socket would otherwise
raise `SIGPIPE`.

## Startup: why there is a warmup

LuaJIT compiles a path once its hot counters trip, and *which* traces exist
depends on the shape of the traffic: a request that arrives alone, one batched
behind others, and an eight-deep pipeline take different paths through the
parser and the loop. A server that only ever sees one shape can end up running
the others in the interpreter.

**Why it does not compile on its own.** LuaJIT records a trace from a hot loop
(56 iterations) and aborts the recording when the path it is following hits
something it cannot continue. A bytecode PC that aborts often enough is
**blacklisted permanently** — it is never compiled again in that process. Under
real load the hot loops see a different shape almost every iteration (one
request per buffer, then six; one completion per drain, then twelve; partial
sends; pipelined requests), and each unfamiliar shape aborts the recording:
`lde run --jit` under load reports *"loop unroll limit reached"*, *"inner loop in
root trace"* and then *"blacklisted"* for the parse loops
(`http_parser.lua:335`, `:385`, `:387`). From that point the parser runs in the
interpreter for the rest of the process: 35 traces exist instead of ~100, user
CPU per request is 1.45-3.4 us instead of ~0.5, and ~1.3M loop iterations of
load do not bring it back — the counters were never the problem, the recording
is.

**What is not the cause.** Syscalls. `ffi.C.*` calls are legal inside a trace
(they become calls the compiler cannot inline, which is why *"trace too long"*
also appears), and a warmup that only runs the parser in-process — no socket, no
`io_uring_enter`, no packets — fixes the throughput just as well as one that
drives real round trips. Measured on this code: no warmup 1.45 us user/req;
parser-only warmup 0.47; socket-only warmup 0.47; both 0.49. Either kind is
sufficient; what they share is many iterations of a *repetitive* path, which is
what lets the recorder finish.

`Server:warmupTraces` therefore, before accepting traffic:

- drives real round trips through the server's own event loop (lone requests,
  pairs, and eight-deep pipelines) against a **private throwaway listener**; the
  real listener is bound but only armed afterwards, so warmup traffic can never
  reach a client and early clients simply wait in the backlog;
- lowers `hotloop`/`hotexit` to 2 for the duration (restored afterwards) so a
  few dozen round trips compile the paths instead of hundreds;
- pumps the loop a bounded number of times per round rather than waiting for a
  byte-exact answer, so an unusual handler cannot stall startup.

Cost is ~25 ms with the default 64 rounds; `warmup = false` skips it, and a
number sets the round count. There is no way to force LuaJIT to compile a
function — the counters are the only trigger — so warming the path is the
supported approach.

## Types

`src/` is annotated with LuaCATS and checked with lua-language-server
(`3.19`, LuaJIT runtime from `.luarc.json`): `--check=src` reports no problems.
FFI values are typed by classes extending `ffi.cdata*` in the `superfast.raw.*`
namespace (`Buffer`, `Sqe`, `Cqe`, `Timespec`, `IoUring`, `ParserState`,
`ConnState`), with `superfast.raw.Ptr` as the untyped escape hatch. The language
server cannot see types declared inside `ffi.cdef`; one file-scoped
`---@diagnostic disable: undefined-doc-class` covers its failure to resolve
`ffi.cdata*` parents during a workspace-wide check.

## Testing and benchmarks

```
lde test                      # io_uring, parser, server and TLS integration tests
cd benchmarks && lde run      # comparison suite (see README for methodology)
cd examples/foo && PORT=8080 lde run
```

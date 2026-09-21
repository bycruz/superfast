# superfast

An incredibly fast HTTP server for LuaJIT on Linux, built on io_uring.

> [!WARNING]
> Currently, only Linux is supported.

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

A handler returns either the three values above or a single response table:

```lua
handler = function(req)
	return { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = "hi" }
end
```

### TLS

```lua
superfast.serve({
	port = 8443,
	certFile = "cert.pem",
	keyFile  = "key.pem",
	handler  = handler,
})
```

## Benchmarks

Empty-200 keep-alive (`wrk -t2 -c64 -d6s`), server pinned to one core and wrk to
two others, median of 3 interleaved trials, i7-9700F loopback:

| server | runtime | req/s | cores | us CPU/req | req/s per CPU-second | p50 | p99 |
|---|---|---|---|---|---|---|---|
| **superfast** | LuaJIT + io_uring | **241,556** | 0.68 | **2.81** | **356,103** | 236us | 1.44ms |
| just-js | v8 + epoll | 227,954 | 0.64 | 2.82 | 354,045 | 261us | 678us |
| bun | `Bun.serve` | 146,069 | 0.74 | 5.04 | 198,284 | 420us | 811us |
| elysia | Bun + Elysia | 137,272 | 0.74 | 5.40 | 185,214 | 444us | 0.99ms |
| hono | Bun + Hono | 119,564 | 0.76 | 6.33 | 158,014 | 517us | 0.98ms |
| node | `http` (libuv) | 28,329 | 0.90 | 31.7 | 31,536 | 2.20ms | 3.15ms |
| python | stdlib `http.server` | 16,002 | 0.94 | 58.2 | 17,173 | 2.74ms | 1.08s |
| express | Node + Express | 8,465 | 0.96 | 113.6 | 8,802 | 6.75ms | 201ms |

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

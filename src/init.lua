-- superfast: an io_uring HTTP server for LuaJIT (Linux).
--
-- Usage:
--   local superfast = require("superfast")
--
--   superfast.serve({
--     port    = 8080,
--     handler = function(req)
--       if req.path == "/" then
--         return 200, { ["Content-Type"] = "text/html" }, "<h1>hello</h1>"
--       end
--       return 404, { ["Content-Type"] = "text/plain" }, "not found"
--     end,
--   })
--
-- The lower-level bindings are also exported so the pieces can be composed:
--   superfast.uring      — io_uring bindings (liburing)
--   superfast.httpParser — streaming HTTP/1.x request parser
--   superfast.ssl        — OpenSSL bindings + async memory-BIO TLS sessions

-- ── public types ────────────────────────────────────────────────────────────

--- Response in table form; `status` defaults to 200 and `body` to "".
---@class superfast.Response
---@field status integer? HTTP status code
---@field headers table<string, string>? response headers
---@field body string? response body

--- A request handler. Return either `status, headers, body` or a single
--- `superfast.Response`. `req` (and `req.headers`) is only valid while the
--- handler runs: handlers must be synchronous and must not retain it.
---@alias superfast.Handler
---| fun(req: superfast.http.Request): integer?, table<string, string>?, string?
---| fun(req: superfast.http.Request): superfast.Response?

---@alias superfast.HandlerResult integer|superfast.Response|string|nil
local Server = require("superfast.server")

-- ── live servers ────────────────────────────────────────────────────────────

-- Servers listening in this process, keyed by "host:port". A hot-reloading
-- driver re-runs the entry file on every reload, so serve() is called again for
-- a port that is already bound; adopting the live server swaps the handler and
-- keeps the connections instead of binding a second listener. Held on _G so a
-- reload of this module cannot reset it.
---@type table<string, superfast.Server>
local liveServers = rawget(_G, "__superfast_live_servers") or {}
rawset(_G, "__superfast_live_servers", liveServers)

--- Create, listen, and run this server until the process is killed.
---
--- Under `lde run --hot` a second call for a served address reuses the live
--- server: only the handler is replaced, so connections survive the reload.
---@param opts superfast.Options
---@return superfast.Server?, string?
local function serve(opts)
	opts = opts or {}
	if not opts.handler then return nil, "Server requires a handler" end

	local port = opts.port or 8080
	local reuse = opts.reuse
	if reuse == nil then reuse = rawget(package, "hot") ~= nil end
	-- port 0 means "any free port": those never collide, so they never reuse
	local key = (reuse and port ~= 0) and ((opts.host or "0.0.0.0") .. ":" .. port) or nil

	if key then
		local live = liveServers[key]
		if live then
			live:setHandler(opts.handler)
			live:run()
			return live, nil
		end
	end

	local server, err = Server:new(opts)
	if not server then return nil, err end
	local ok, bound = server:listen()
	if not ok then return nil, bound end
	if key then
		liveServers[key] = server
		server.onClose = function() liveServers[key] = nil end
	end
	server:run()
	return server, nil
end

--- The public module table.
---@class superfast
---@field version string
---@field Server superfast.Server
---@field uring superfast.uring
---@field httpParser superfast.http.Parser
---@field ssl superfast.ssl?
---@field serve fun(opts: superfast.Options): superfast.Server?, string?

---@type superfast
local superfast = {
	version    = "0.1.0",
	Server     = Server,
	uring      = require("superfast.io_uring"),
	httpParser = require("superfast.http_parser"),
	ssl        = (function()
		local ok, m = pcall(require, "superfast.openssl")
		return ok and m or nil
	end)(),
	serve      = serve,
}

--- Options for `superfast.serve` and `superfast.Server:new`.
---@class superfast.Options
---@field handler superfast.Handler request handler (required)
---@field port integer? listen port; 0 picks a free port (default 8080)
---@field host string? listen address (default "0.0.0.0")
---@field backlog integer? listen backlog (default 1024)
---@field entries integer? io_uring submission queue depth (default 2048)
---@field bufferCount integer? receive buffers provided up front (default 256)
---@field maxBuffers integer? ceiling for the auto-growing pool (default 2048)
---@field bufferSize integer? bytes per receive buffer (default 16384)
---@field warmup boolean|integer? warmup round trips before serving (default 64, false disables)
---@field warmupHandler superfast.Handler? handler used for warmup traffic
---@field reuse boolean? adopt the live server for this address instead of binding a second listener (default: true under `lde run --hot`)
---@field certFile string? TLS certificate (enables TLS with keyFile)
---@field keyFile string? TLS private key


return superfast

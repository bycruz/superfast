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

local Server = require("superfast.server")

local superfast = {
	version    = "0.1.0",
	Server     = Server,
	uring      = require("superfast.io_uring"),
	httpParser = require("superfast.http_parser"),
	ssl        = (function()
		local ok, m = pcall(require, "superfast.openssl")
		return ok and m or nil
	end)(),
}

--- Create, listen, and run a server until the process is killed.
---@param opts table see superfast.Server:new
---@return superfast.Server|nil, string?
function superfast.serve(opts)
	local server, err = Server:new(opts)
	if not server then return nil, err end
	local ok, port = server:listen()
	if not ok then return nil, port end
	server:run()
	return server
end

return superfast

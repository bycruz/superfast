-- End-to-end server tests: drive a real io_uring server from a raw socket
-- client in the same process, stepping the event loop between client recvs.
-- Includes a full TLS handshake + request over the vendored OpenSSL bindings.

local test = require("lde-test")
local ffi = require("ffi")
local superfast = require("superfast")
local client = require("tests.lib.client")

local ssl = superfast.ssl

--- Start a server on an ephemeral port.
---@param handler function
---@param opts table?
---@return superfast.Server, integer port
local function startServer(handler, opts)
	opts = opts or {}
	opts.port = 0
	opts.handler = handler
	local srv, err = superfast.Server:new(opts)
	test.truthy(srv)
	if not srv then return nil, err end
	local ok, port = srv:listen()
	test.truthy(ok)
	if not ok then return nil, port end
	return srv, port
end

--- Run fn() after each server step until it returns truthy or 5s elapse.
---@param server superfast.Server
---@param fn fun(): any
---@return any
local function pump(server, fn)
	local deadline = os.time() + 5
	while os.time() < deadline do
		server:step(5)
		local r = fn()
		if r then return r end
	end
	return nil, "timed out"
end

--- Read one full HTTP response (headers + Content-Length body) from fd.
---@param server superfast.Server
---@param fd integer
---@return string|nil, string? response, leftover
local function readResponse(server, fd)
	local buf = ""
	local deadline = os.time() + 5
	while os.time() < deadline do
		server:step(5)
		local chunk = client.recvSome(fd, 8192)
		if chunk then
			buf = buf .. chunk
			local headEnd = buf:find("\r\n\r\n", 1, true)
			if headEnd then
				local cl = buf:match("Content%-Length: (%d+)")
				if cl then
					local total = headEnd + 3 + tonumber(cl)
					if #buf >= total then
						return buf:sub(1, total), buf:sub(total + 1)
					end
				end
			end
		end
	end
	return nil, "no response in time, got: " .. buf
end

local function defaultHandler(req)
	if req.path == "/" then
		return 200, { ["Content-Type"] = "text/html" }, "<h1>superfast</h1>"
	elseif req.path == "/echo" then
		return 200, { ["Content-Type"] = "text/plain" }, req.body
	end
	return 404, { ["Content-Type"] = "text/plain" }, "not found"
end

test.it("serves a GET with 200 and the body", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)
	assert(client.sendAll(fd, "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))

	local resp = assert(readResponse(server, fd))
	test.includes(resp, "HTTP/1.1 200 OK")
	test.includes(resp, "Content-Type: text/html")
	test.includes(resp, "<h1>superfast</h1>")

	client.close(fd)
	server:close()
end)

test.it("returns 404 for unknown paths", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)
	assert(client.sendAll(fd, "GET /nope HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))

	local resp = assert(readResponse(server, fd))
	test.includes(resp, "HTTP/1.1 404 Not Found")
	test.includes(resp, "not found")

	client.close(fd)
	server:close()
end)

test.it("echoes a POST body", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)
	assert(client.sendAll(fd, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world"))

	local resp = assert(readResponse(server, fd))
	test.includes(resp, "HTTP/1.1 200 OK")
	test.includes(resp, "hello world")

	client.close(fd)
	server:close()
end)

test.it("supports keep-alive: two requests on one connection", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)

	assert(client.sendAll(fd, "GET / HTTP/1.1\r\nHost: t\r\n\r\n"))
	local resp1 = assert(readResponse(server, fd))
	test.includes(resp1, "<h1>superfast</h1>")

	assert(client.sendAll(fd, "GET /nope HTTP/1.1\r\nHost: t\r\n\r\n"))
	local resp2 = assert(readResponse(server, fd))
	test.includes(resp2, "HTTP/1.1 404 Not Found")

	assert(client.sendAll(fd, "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
	local resp3 = assert(readResponse(server, fd))
	test.includes(resp3, "<h1>superfast</h1>")

	client.close(fd)
	server:close()
end)

test.it("handles pipelined requests in one write", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)

	local reqs = "GET / HTTP/1.1\r\nHost: t\r\n\r\nGET /nope HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
	assert(client.sendAll(fd, reqs))

	local resp1, leftover = assert(readResponse(server, fd))
	test.includes(resp1, "<h1>superfast</h1>")

	-- the second response may already be buffered in `leftover`
	local buf = leftover
	local deadline = os.time() + 5
	while not buf:find("404 Not Found", 1, true) and os.time() < deadline do
		server:step(5)
		local chunk = client.recvSome(fd, 8192)
		if chunk then buf = buf .. chunk end
	end
	test.includes(buf, "HTTP/1.1 404 Not Found")

	client.close(fd)
	server:close()
end)

test.it("returns 400 for a malformed request", function()
	local server, port = startServer(defaultHandler)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)
	assert(client.sendAll(fd, "GARBAGE\r\n\r\n"))

	local resp = assert(readResponse(server, fd))
	test.includes(resp, "HTTP/1.1 400 Bad Request")

	client.close(fd)
	server:close()
end)

test.it("a handler error becomes a 500", function()
	local server, port = startServer(function() error("boom") end)
	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)
	assert(client.sendAll(fd, "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))

	local resp = assert(readResponse(server, fd))
	test.includes(resp, "HTTP/1.1 500 Internal Server Error")

	client.close(fd)
	server:close()
end)

test.it("handles many concurrent connections", function()
	local server, port = startServer(defaultHandler)

	local fds = {}
	for i = 1, 50 do
		local fd = assert(client.connect("127.0.0.1", port))
		client.setNonBlocking(fd)
		fds[#fds + 1] = fd
		assert(client.sendAll(fd, "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
	end

	for i, fd in ipairs(fds) do
		local resp = assert(readResponse(server, fd))
		test.includes(resp, "<h1>superfast</h1>")
		client.close(fd)
	end

	server:close()
end)

-- ── TLS ─────────────────────────────────────────────────────────────────────

test.skipIf(ssl == nil)("serves HTTPS with a self-signed cert", function()
	-- mint a throwaway cert with the system openssl CLI
	local dir = "/tmp/superfast-test-" .. tostring(os.time())
	assert(os.execute('mkdir -p "' .. dir .. '"'))
	local ok = os.execute('openssl req -x509 -newkey rsa:2048 -nodes -days 1 '
		.. '-keyout "' .. dir .. '/key.pem" -out "' .. dir .. '/cert.pem" '
		.. '-subj "/CN=localhost" >/dev/null 2>&1')
	test.truthy(ok == 0 or ok == true)

	local server, port = startServer(defaultHandler, {
		certFile = dir .. "/cert.pem",
		keyFile = dir .. "/key.pem",
	})

	local fd = assert(client.connect("127.0.0.1", port))
	client.setNonBlocking(fd)

	-- client-side TLS session (no verification; self-signed)
	local ctx = assert(ssl.Context.client())
	local sess = ssl.Session.newClient(ctx)

	-- drive the handshake: step the server loop while shuffling ciphertext
	local deadline = os.time() + 5
	local done = false
	while os.time() < deadline and not done do
		local st = sess:handshake()
		local out = sess:drain()
		if #out > 0 then assert(client.sendAll(fd, out)) end
		if st == "done" then done = true break end
		server:step(5)
		local chunk = client.recvSome(fd, 8192)
		if chunk then sess:feed(chunk) end
	end
	test.truthy(done, "TLS handshake did not complete")

	-- send an encrypted request
	assert(sess:encrypt("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
	assert(client.sendAll(fd, sess:drain()))

	-- read the encrypted response, decrypting as it arrives
	local plain = ""
	deadline = os.time() + 5
	while os.time() < deadline do
		server:step(5)
		local chunk = client.recvSome(fd, 8192)
		if chunk then
			sess:feed(chunk)
			local p, eof = sess:decrypt()
			plain = plain .. p
			if eof or plain:find("</h1>", 1, true) then break end
		end
	end

	test.includes(plain, "HTTP/1.1 200 OK")
	test.includes(plain, "<h1>superfast</h1>")

	client.close(fd)
	server:close()
	os.execute('rm -rf "' .. dir .. '"')
end)

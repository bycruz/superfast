-- superfast server: an io_uring-driven HTTP/1.1 server for LuaJIT.
--
-- Design notes:
--   * One io_uring ring per server; sockets are kept blocking so recv/accept
--     park in the kernel instead of spinning on -EAGAIN.
--   * Receive uses provided buffers (IOSQE_BUFFER_SELECT): the kernel picks
--     a buffer from a registered pool and reports its id on the CQE, so no
--     per-connection allocation happens in the read path.
--   * At most one fd operation is in flight per connection (recv XOR send
--     XOR close), which makes connection teardown race-free.
--   * Responses are sent straight from the Lua string with the reference kept
--     alive until the send CQE lands — no per-connection send buffer copy.
--   * TLS rides on memory BIOs: ciphertext flows socket <-> OpenSSL without
--     OpenSSL ever touching the fd, so the handshake and record layer are
--     fully async over the same io_uring ops.

local ffi = require("ffi")
local uring = require("superfast.io_uring")
local Parser = require("superfast.http_parser")
local sslmod  -- loaded lazily, only when TLS is configured

-- libc socket API + sockaddr types are declared by superfast.io_uring

ffi.cdef [[
  /* hot per-connection state: direct FFI field access instead of table ops */
  typedef struct {
    int32_t fd;
    int32_t inflight;          /* 0 none, 1 recv, 2 send, 3 close */
    int32_t phase;             /* 0 http, 1 handshake */
    int32_t outLen;            /* responses queued */
    int32_t curOff;            /* bytes of curOut already sent */
    int32_t curOutLen;         /* length of the string being sent */
    int32_t closeAfterSend;
    int32_t continueHandshake;
  } conn_state;
]]

local INFLIGHT_NONE   = 0
local INFLIGHT_RECV   = 1
local INFLIGHT_SEND   = 2
local INFLIGHT_CLOSE  = 3
local PHASE_HTTP      = 0
local PHASE_HANDSHAKE = 1

-- socket constants (Linux)
local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_REUSEADDR = 2
local SO_REUSEPORT = 15

-- user_data ids
local ID_LISTENER = 0
local ID_PROVIDE  = 9007199254740991 -- 2^53-1; conn ids live below this

-- status line reasons
local REASONS = {
	[200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content",
	[301] = "Moved Permanently", [302] = "Found", [304] = "Not Modified",
	[400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
	[405] = "Method Not Allowed", [408] = "Request Timeout",
	[413] = "Payload Too Large", [414] = "URI Too Long",
	[431] = "Request Header Fields Too Large",
	[500] = "Internal Server Error", [501] = "Not Implemented",
	[503] = "Service Unavailable", [505] = "HTTP Version Not Supported",
}

-- cached Date header (one allocation per second, not per response)
local dateHdr = "Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
local dateSec = 0
local function httpDateHeader()
	local sec = os.time()
	if sec ~= dateSec then
		dateSec = sec
		dateHdr = "Date: " .. os.date("!%a, %d %b %Y %H:%M:%S GMT") .. "\r\n"
	end
	return dateHdr
end

local KEEP_ALIVE_HDR = "Connection: keep-alive\r\n"
local CLOSE_HDR      = "Connection: close\r\n"

-- status line cache (bounded by the distinct status codes in REASONS)
local statusLineCache = {}
---@param status integer
---@return string
local function statusLine(status)
	local s = statusLineCache[status]
	if not s then
		s = "HTTP/1.1 " .. status .. " " .. (REASONS[status] or "OK")
		statusLineCache[status] = s
	end
	return s
end

-- Full response-head cache: keyed by (status line, connection, body length)
-- and valid for one second because the head embeds the Date header. A hot
-- single-entry fast path makes the common workload (same shape every
-- request) cost zero allocations per response.
local responseCache = {}
local responseCacheDate = ""
local hotSL, hotClose, hotLen, hotHead
---@param sl string status line
---@param closeConn boolean
---@param bodyLen integer
---@return string
local function responseHead(sl, closeConn, bodyLen)
	if hotSL == sl and hotClose == closeConn and hotLen == bodyLen then
		return hotHead
	end
	local date = httpDateHeader()
	if responseCacheDate ~= date then
		responseCacheDate = date
		responseCache = {}
	end
	local key = sl .. "\0" .. (closeConn and "c" or "k") .. "\0" .. bodyLen
	local head = responseCache[key]
	if not head then
		head = sl .. "\r\n" .. date .. (closeConn and CLOSE_HDR or KEEP_ALIVE_HDR)
			.. "Content-Length: " .. bodyLen .. "\r\n\r\n"
		responseCache[key] = head
	end
	hotSL, hotClose, hotLen, hotHead = sl, closeConn, bodyLen, head
	return head
end

---@class superfast.Server
---@field ring uring.Ring
---@field listenFd integer
---@field handler function
---@field conns table<integer, table>
---@field nextId integer
---@field buffers table<integer, cdata>
---@field bufferCount integer
---@field bufferSize integer
---@field providePending integer
---@field tls ssl.Context|nil
---@field running boolean
local Server = {}
Server.__index = Server

---@param opts table
---  - `port`: integer (default 8080)
---  - `host`: string (default "0.0.0.0")
---  - `handler`: fun(req: httpParser.Request): table|(integer, table?, string?) — required
---  - `backlog`: integer (default 1024)
---  - `bufferCount`: integer provided recv buffers (default 256)
---  - `bufferSize`: integer bytes per buffer (default 16384)
---  - `entries`: integer io_uring SQ depth (default 2048)
---  - `certFile` / `keyFile`: enable TLS
---@return superfast.Server|nil, string?
function Server:new(opts)
	opts = opts or {}
	if not opts.handler then return nil, "Server requires a handler" end

	local tlsCtx
	if opts.certFile then
		if not sslmod then sslmod = require("superfast.openssl") end
		local ctx, ctxErr = sslmod.Context.new(opts.certFile, opts.keyFile)
		if not ctx then return nil, ctxErr end
		tlsCtx = ctx
	end

	-- handlers that declare no parameters provably cannot touch req (unless
	-- vararg — they could read `...`), so we can skip passing it entirely
	local info = debug.getinfo(opts.handler, "u")
	local takesReq = not (info.nparams == 0 and not info.isvararg)

	return setmetatable({
		port           = opts.port or 8080,
		host           = opts.host or "0.0.0.0",
		handler        = opts.handler,
		handlerTakesReq = takesReq,
		backlog        = opts.backlog or 1024,
		bufferCount    = opts.bufferCount or 256,
		bufferSize     = opts.bufferSize or 16384,
		entries        = opts.entries or 2048,
		tlsCtx         = tlsCtx,
		ring           = nil,
		listenFd       = -1,
		conns          = {},
		nextId         = 1,
		buffers        = {},
		providePending = 0,
		running        = false,
	}, Server)
end

-- ── setup ───────────────────────────────────────────────────────────────────

--- Create the listening socket. Returns ok, err or ok, port.
---@return boolean, string?|integer?
function Server:listen()
	local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then return false, "socket() failed" end

	-- reuseaddr + reuseport: instant restart, and multi-process accept spreading
	local one = ffi.new("int[1]", 1)
	ffi.C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one, ffi.sizeof("int"))
	ffi.C.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, one, ffi.sizeof("int"))

	local addr = ffi.new("sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port = ffi.C.htons(self.port)
	if self.host == "0.0.0.0" or self.host == "*" then
		addr.sin_addr = 0
	else
		local ip = ffi.new("unsigned int[1]")
		local ok = ffi.C.inet_pton(AF_INET, self.host, ip)
		if ok ~= 1 then
			ffi.C.close(fd)
			return false, "bad host: " .. self.host
		end
		addr.sin_addr = ip[0]
	end

	if ffi.C.bind(fd, ffi.cast("sockaddr *", addr), ffi.sizeof("sockaddr_in")) ~= 0 then
		ffi.C.close(fd)
		return false, "bind() failed on " .. self.host .. ":" .. self.port
	end
	if ffi.C.listen(fd, self.backlog) ~= 0 then
		ffi.C.close(fd)
		return false, "listen() failed"
	end
	self.listenFd = fd

	-- resolve the actual port (useful when port = 0)
	local len = ffi.new("socklen_t[1]", ffi.sizeof("sockaddr_in"))
	local got = ffi.new("sockaddr_in")
	ffi.C.getsockname(fd, ffi.cast("sockaddr *", got), len)
	self.port = ffi.C.ntohs(got.sin_port)

	-- io_uring ring (defer_taskrun + single issuer when the kernel allows)
	self.ring = uring.Ring.new(self.entries, { aggressive = true })
	if not self.ring then
		ffi.C.close(fd)
		return false, "io_uring_queue_init failed"
	end

	if not self:initBuffers() then
		ffi.C.close(fd)
		return false, "buffer pool setup failed"
	end

	self.running = true
	self:armAccept()
	return true, self.port
end

--- Allocate and provide the receive buffer pool.
---@return boolean
function Server:initBuffers()
	local sqe
	for i = 0, self.bufferCount - 1 do
		self.buffers[i] = ffi.new("char[?]", self.bufferSize)
		sqe = self:sqe()
		self.ring:prepProvideBuffers(sqe, self.buffers[i], self.bufferSize, 1, 0, i)
		self.ring:sqeSetData(sqe, ID_PROVIDE)
		self.providePending = self.providePending + 1
	end
	self.ring:submitAndWait(self.providePending)
	self.providePending = 0
	return true
end

--- Get an SQE, flushing the ring if it is momentarily full.
---@return io_uring_sqe
function Server:sqe()
	for _ = 1, 4 do
		local sqe = self.ring:getSqe()
		if sqe then return sqe end
		self.ring:submit()
	end
	error("io_uring SQ full")
end

---@param conn table
function Server:armRecv(conn)
	local sqe = self:sqe()
	self.ring:prepRecv(sqe, conn.st.fd, nil, 0, 0)
	self.ring:sqeSetFlags(sqe, uring.SqeFlag.BUFFER_SELECT)
	self.ring:sqeSetBufGroup(sqe, 0)
	self.ring:sqeSetData(sqe, conn.id)
	conn.st.inflight = INFLIGHT_RECV
end

function Server:armAccept()
	local sqe = self:sqe()
	self.ring:prepAccept(sqe, self.listenFd, 0)
	self.ring:sqeSetData(sqe, ID_LISTENER)
end

--- Return a used recv buffer to the pool.
---@param bid integer
function Server:reProvide(bid)
	local sqe = self:sqe()
	self.ring:prepProvideBuffers(sqe, self.buffers[bid], self.bufferSize, 1, 0, bid)
	self.ring:sqeSetData(sqe, ID_PROVIDE)
end

-- ── event loop ──────────────────────────────────────────────────────────────

--- Run the event loop until Server:stop().
function Server:run()
	self.running = true
	while self.running do
		self:step(nil)
	end
end

---@param running boolean
function Server:stop()
	self.running = false
end

--- One loop iteration: submit queued work, wait for a completion, drain every
--- completion that is already ready.
---@param timeoutMs number|nil
---@return integer events handled
---@return string? err when timing out
function Server:step(timeoutMs)
	self.ring:submit()
	local cqe, err
	if timeoutMs then
		cqe, err = self.ring:waitCqeTimeout(timeoutMs)
	else
		cqe, err = self.ring:waitCqe()
	end
	if not cqe then return 0, err end

	local n = 0
	repeat
		self:dispatch(cqe)
		n = n + 1
		cqe = self.ring:peekCqe()
	until cqe == nil
	return n, nil
end

---@param cqe io_uring_cqe
function Server:dispatch(cqe)
	local id = self.ring:cqeData(cqe)
	local res = self.ring:cqeRes(cqe)

	if id == ID_LISTENER then
		self:onAccept(res)
	elseif id == ID_PROVIDE then
		self.providePending = self.providePending - 1
	else
		local conn = self.conns[id]
		if conn then
			local inflight = conn.st.inflight
			if inflight == INFLIGHT_RECV then
				self:onRecv(conn, cqe, res)
			elseif inflight == INFLIGHT_SEND then
				self:onSend(conn, cqe, res)
			elseif inflight == INFLIGHT_CLOSE then
				self:onClosed(conn, res)
			end
		end
	end
	self.ring:cqeSeen(cqe)
end

---@param res integer
function Server:onAccept(res)
	if res >= 0 then
		local st = ffi.new("conn_state")
		st.fd = res
		st.phase = self.tlsCtx and PHASE_HANDSHAKE or PHASE_HTTP
		local conn = {
			id       = self.nextId,
			st       = st,
			tls      = self.tlsCtx and sslmod.Session.new(self.tlsCtx) or nil,
			outQueue = {},
			curOut   = nil,
		}
		-- parser attached after the table exists so the callback closure
		-- captures the local `conn` (not the outer nil) — see Lua scoping
		conn.parser = Parser:new({
			onMessageComplete = function(req) self:onRequest(conn, req) end,
		})
		self.nextId = self.nextId + 1
		self.conns[conn.id] = conn
		self:armRecv(conn)
	end
	-- re-arm regardless (errors like EMFILE are transient)
	self:armAccept()
end

-- ── connection handling ─────────────────────────────────────────────────────

---@param conn table
---@param cqe io_uring_cqe
---@param res integer bytes received
function Server:onRecv(conn, cqe, res)
	if res > 0 then
		local bid = self.ring:cqeBid(cqe)
		local buf = self.buffers[bid]

		-- parse straight from the recv buffer (the parser copies into its own
		-- scratch buffer); the TLS path feeds ciphertext without copying too
		if conn.tls then
			conn.tls:feedPtr(buf, res)
			self:driveTls(conn)
		else
			self:afterFeed(conn, conn.parser:feedPtr(buf, res))
		end
		self:reProvide(bid)
	else
		-- res == 0: clean EOF; res < 0: ECONNRESET & friends
		self:closeConn(conn)
	end
end

--- Drive the TLS state machine after new ciphertext arrives.
---@param conn table
function Server:driveTls(conn)
	local st = conn.st
	if st.phase == PHASE_HANDSHAKE then
		local handshake, err = conn.tls:handshake()
		local out = conn.tls:drain()
		if #out > 0 then
			conn.outQueue[#conn.outQueue + 1] = out
			st.outLen = st.outLen + 1
			st.continueHandshake = 1
			self:issueSend(conn)
			return
		end
		if handshake == "done" then
			st.phase = PHASE_HTTP
			local plain, eof = conn.tls:decrypt()
			if eof then
				self:closeConn(conn)
				return
			end
			if plain ~= "" then
				self:afterFeed(conn, conn.parser:feed(plain))
			else
				self:armRecv(conn)
			end
		elseif handshake == "wantRead" then
			self:armRecv(conn)
		elseif handshake == "wantWrite" then
			-- produced no bytes but wants to write — shouldn't happen with mem BIOs
			self:armRecv(conn)
		else
			self:closeConn(conn)
		end
	else
		local plain, eof = conn.tls:decrypt()
		if eof then
			self:closeConn(conn)
			return
		end
		if plain ~= "" then
			self:afterFeed(conn, conn.parser:feed(plain))
		else
			self:armRecv(conn)
		end
	end
end

--- Map a parser error message to an HTTP status.
local STATUS_BY_ERR = {
	["request headers too large"]        = 431,
	["request body too large"]          = 413,
	["transfer-encoding not supported"] = 501,
}

--- React after feeding plaintext to the parser: on parse errors send an error
--- response; otherwise send any queued responses or re-arm the read side.
---@param conn table
---@param ok boolean|nil
---@param err string?
function Server:afterFeed(conn, ok, err)
	if not ok then
		self:sendError(conn, STATUS_BY_ERR[err] or 400, err)
		return
	end
	if conn.st.outLen > 0 then
		self:issueSend(conn)
	else
		self:armRecv(conn)
	end
end

--- A complete HTTP request arrived; build and queue the response.
---@param conn table
---@param req httpParser.Request
function Server:onRequest(conn, req)
	self:handleRequest(conn, req)
end

---@param conn table
---@param cqe io_uring_cqe
---@param res integer bytes sent
function Server:onSend(conn, cqe, res)
	local st = conn.st
	if res < 0 then
		self:closeConn(conn)
		return
	end
	st.curOff = st.curOff + res
	if st.curOff < st.curOutLen then
		-- more of this string to send
		local sqe = self:sqe()
		self.ring:prepSend(sqe, st.fd, ffi.cast("const char *", conn.curOut) + st.curOff, st.curOutLen - st.curOff)
		self.ring:sqeSetData(sqe, conn.id)
		-- inflight stays SEND
		return
	end
	conn.curOut = nil
	st.inflight = INFLIGHT_NONE -- the send op is complete; allow rearm/close
	if st.continueHandshake ~= 0 then
		st.continueHandshake = 0
		self:driveTls(conn)
		return
	end
	self:issueSend(conn)
end

--- Pop the next queued response and send it; if nothing is queued, re-arm the
--- read side or close, depending on the connection lifecycle flags.
---@param conn table
function Server:issueSend(conn)
	local st = conn.st
	if st.inflight == INFLIGHT_SEND then return end
	if st.outLen == 0 then
		if st.closeAfterSend ~= 0 then
			self:closeConn(conn)
		else
			self:armRecv(conn)
		end
		return
	end
	conn.curOut = table.remove(conn.outQueue, 1)
	st.outLen = st.outLen - 1
	st.curOff = 0
	st.curOutLen = #conn.curOut
	local sqe = self:sqe()
	self.ring:prepSend(sqe, st.fd, ffi.cast("const char *", conn.curOut), st.curOutLen)
	self.ring:sqeSetData(sqe, conn.id)
	st.inflight = INFLIGHT_SEND
end

---@param conn table
function Server:closeConn(conn)
	local st = conn.st
	if st.inflight == INFLIGHT_CLOSE then return end
	st.inflight = INFLIGHT_CLOSE
	local sqe = self:sqe()
	self.ring:prepClose(sqe, st.fd)
	self.ring:sqeSetData(sqe, conn.id)
end

---@param conn table
---@param res integer
function Server:onClosed(conn, res)
	self.conns[conn.id] = nil
	if conn.tls then conn.tls:free() end
	conn.parser = nil
	conn.outQueue = nil
	conn.curOut = nil
end

-- ── responses ───────────────────────────────────────────────────────────────

--- Normalize handler output into (statusLine, headers, body). Handlers may
--- return `status, headers, body` or a single table { status=, headers=, body= }.
---@param a any
---@param b any
---@param c any
---@return string statusLine
---@return table|nil headers
---@return string body
local function normalizeResponse(a, b, c)
	local status, headers, body
	if type(a) == "table" then
		status, headers, body = a.status or 200, a.headers, a.body
	else
		status, headers, body = a, b, c
	end
	body = body or ""
	if type(status) == "number" then
		return statusLine(status), headers, body
	end
	return "HTTP/1.1 " .. status, headers, body
end

--- Build the full response bytes.
---@param keepAlive boolean whether the request keeps the connection alive
---@param a any
---@param b any
---@param c any
---@return string
---@return boolean closeConn
function Server:buildResponse(keepAlive, a, b, c)
	local sl, headers, body = normalizeResponse(a, b, c)

	local closeConn = not keepAlive
	if headers and headers.Connection then
		if headers.Connection:lower():find("close", 1, true) then closeConn = true
		elseif headers.Connection:lower():find("keep-alive", 1, true) then closeConn = false end
	end

	-- collect any custom headers (fast path below when there are none)
	local extra
	if headers then
		for k, v in pairs(headers) do
			if k ~= "Connection" and k ~= "Content-Length" then
				extra = extra or {}
				extra[#extra + 1] = k .. ": " .. v .. "\r\n"
			end
		end
	end

	if not extra then
		local head = responseHead(sl, closeConn, #body)
		if body == "" then return head, closeConn end
		return head .. body, closeConn
	end

	local parts = {
		sl .. "\r\n",
		httpDateHeader(),
		closeConn and CLOSE_HDR or KEEP_ALIVE_HDR,
		"Content-Length: " .. #body .. "\r\n",
	}
	for _, h in ipairs(extra) do parts[#parts + 1] = h end
	parts[#parts + 1] = "\r\n"
	parts[#parts + 1] = body
	return table.concat(parts), closeConn
end

--- Handle a complete request: invoke the user handler, queue the response.
---@param conn table
---@param req httpParser.Request
function Server:handleRequest(conn, req)
	local ok, r1, r2, r3
	if self.handlerTakesReq then
		ok, r1, r2, r3 = pcall(self.handler, req)
	else
		-- handler declares no parameters: it provably cannot use req
		ok, r1, r2, r3 = pcall(self.handler)
	end
	if not ok then
		self:sendError(conn, 500, r1)
		return
	end

	local keepAlive = conn.parser.s.msgKeepAlive ~= 0
	local bytes, closeConn = self:buildResponse(keepAlive, r1, r2, r3)
	if closeConn then conn.st.closeAfterSend = 1 end

	if conn.tls then
		local ok2, err2 = conn.tls:encrypt(bytes)
		if not ok2 then
			self:closeConn(conn)
			return
		end
		bytes = conn.tls:drain()
	end
	conn.outQueue[#conn.outQueue + 1] = bytes
	conn.st.outLen = conn.st.outLen + 1
end

--- Queue a plain-text error response and close after it is sent.
---@param conn table
---@param status integer
---@param msg string
function Server:sendError(conn, status, msg)
	local reason = REASONS[status] or "Error"
	local body = reason .. "\n"
	local bytes = table.concat({
		"HTTP/1.1 " .. status .. " " .. reason .. "\r\n",
		httpDateHeader(),
		CLOSE_HDR,
		"Content-Type: text/plain\r\n",
		"Content-Length: " .. #body .. "\r\n",
		"\r\n",
		body,
	})
	if conn.tls then
		local ok, err = conn.tls:encrypt(bytes)
		if not ok then
			self:closeConn(conn)
			return
		end
		bytes = conn.tls:drain()
	end
	conn.outQueue[#conn.outQueue + 1] = bytes
	conn.st.closeAfterSend = 1
	conn.st.outLen = conn.st.outLen + 1
	self:issueSend(conn)
end

--- Shut down the server: close listener + ring, mark all conns dead.
function Server:close()
	self.running = false
	if self.listenFd >= 0 then
		ffi.C.close(self.listenFd)
		self.listenFd = -1
	end
	if self.ring then
		for _, conn in pairs(self.conns) do
			ffi.C.close(conn.st.fd)
			if conn.tls then conn.tls:free() end
		end
		self.conns = {}
		self.ring = nil
	end
	if self.tlsCtx then
		self.tlsCtx:free()
		self.tlsCtx = nil
	end
end

return Server

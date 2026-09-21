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
local bit = require("bit")
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

-- errno values the recv path reacts to
local ENOBUFS = 105

-- fcntl / send / recv flags used by the warmup path
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048
local MSG_DONTWAIT = 64
local MSG_NOSIGNAL = 16384
local EAGAIN = 11
local EINTR = 4
-- Warmup waits only ever have to cover one round trip of a throwaway connection
-- on loopback; a full millisecond per idle step made startup cost tens of
-- milliseconds that the first real client pays for.
local WARMUP_STEP_MS = 0.1

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
---@field ring superfast.uring.Ring?
---@field listenFd integer
---@field handler superfast.Handler|fun(): superfast.HandlerResult
---@field handlerTakesReq boolean
---@field port integer
---@field host string
---@field backlog integer
---@field entries integer
---@field bufferCount integer
---@field maxBuffers integer
---@field bufferSize integer
---@field warmup boolean|integer?
---@field warmupHandler superfast.Handler?
---@field conns table<integer, table>
---@field nextId integer
---@field nextBid integer
---@field buffers table<integer, superfast.raw.Buffer>
---@field providePending integer
---@field buffersInKernel integer
---@field tlsCtx superfast.ssl.Context?
---@field running boolean
local Server = {}
Server.__index = Server

---@param opts superfast.Options
---@return superfast.Server?, string?
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

	local entries = opts.entries or 2048
	local bufferCount = opts.bufferCount or 256
	-- one provided buffer per queued SQE must fit in the ring
	if bufferCount > entries - 32 then bufferCount = entries - 32 end

	local server = setmetatable({
		port           = opts.port or 8080,
		host           = opts.host or "0.0.0.0",
		handler        = opts.handler,
		handlerTakesReq = takesReq,
		backlog        = opts.backlog or 1024,
		bufferCount    = bufferCount,
		maxBuffers     = opts.maxBuffers or 2048,
		bufferSize     = opts.bufferSize or 16384,
		entries        = entries,
		warmup         = opts.warmup,
		warmupHandler  = opts.warmupHandler,
		tlsCtx         = tlsCtx,
		ring           = nil,
		listenFd       = -1,
		conns          = {},
		nextId         = 1,
		buffers        = {},
		nextBid        = 0,
		providePending = 0,
		buffersInKernel = 0,
		running        = false,
	}, Server)
	return server, nil
end

-- ── setup ───────────────────────────────────────────────────────────────────

--- Create the listening socket. Returns ok, err or ok, port.
---@return boolean, string|integer?
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

	-- Warmup: LuaJIT compiles by hot counters, and which shapes get compiled
	-- depends on how requests arrive, so throughput would otherwise vary with
	-- load. Runs against a private throwaway listener; the real listener is
	-- only armed afterwards. See docs/ARCHITECTURE.md.
	if self.warmup ~= false then
		local rounds = self.warmup
		if type(rounds) ~= "number" then rounds = 64 end
		self:warmupOnPrivateListener(rounds)
	end

	self.running = true
	self:armAccept()
	return true, self.port
end

--- Warm up against a throwaway listener so warmup traffic cannot mix with
--- client traffic.
---@param rounds integer
function Server:warmupOnPrivateListener(rounds)
	local wfd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if wfd < 0 then return end
	local addr = ffi.new("sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port = 0
	addr.sin_addr = 0x0100007f -- 127.0.0.1
	if ffi.C.bind(wfd, ffi.cast("sockaddr *", addr), ffi.sizeof("sockaddr_in")) ~= 0
		or ffi.C.listen(wfd, 64) ~= 0 then
		ffi.C.close(wfd)
		return
	end
	local len = ffi.new("socklen_t[1]", ffi.sizeof("sockaddr_in"))
	ffi.C.getsockname(wfd, ffi.cast("sockaddr *", addr), len)
	local warmPort = ffi.C.ntohs(addr.sin_port)

	local realFd = self.listenFd
	self.listenFd = wfd            -- accepts land on the throwaway listener
	self:armAccept()
	self:warmupTraces(rounds, warmPort)
	self.listenFd = realFd
	ffi.C.close(wfd)
	-- reap the completions the closed warmup listener leaves behind
	for _ = 1, 8 do self:step(WARMUP_STEP_MS) end
end

--- Compile the parse/response path without a socket: drives the real
--- onRequest -> handler -> response chain against a detached connection.
---@param rounds integer
function Server:warmupParser(rounds)
	local conn = {
		id      = 0,
		st      = ffi.new("conn_state") --[[@as superfast.raw.ConnState]],
		outQ    = {},
		outHead = 1,
		outTail = 1,
	}
	local parser = Parser:new({ onMessageComplete = Server.onParserMessage })
	parser.owner = conn
	parser.server = self
	conn.parser = parser

	local shapes = {
		"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: superfast/warmup\r\nAccept: */*\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
		"GET / HTTP/1.0\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
		"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc",
	}
	for i = 1, rounds do
		local s = shapes[(i % 5) + 1]
		parser:feed(s)      -- one request per feed: the unbatched path
		conn.outQ, conn.outHead, conn.outTail = {}, 1, 1
		conn.st.outLen = 0
		parser:feed(s .. s) -- two requests in one buffer: the batched path
		conn.outQ, conn.outHead, conn.outTail = {}, 1, 1
		conn.st.outLen = 0
	end
	-- materialize every lazy field once, so the metamethod paths compile too
	local req = parser.req
	if req then
		local _ = req.method
		_ = req.path
		_ = req.query
		_ = req.version
		_ = req.keepAlive
		_ = req.headers
		_ = req.body
	end
	self:buildResponse(true, 200, nil, "")
	self:buildResponse(true, 404, { ["Content-Type"] = "text/plain" }, "not found")
end

--- Connect a non-blocking client socket back to this server's listener.
---@param self superfast.Server
---@param port integer
---@return integer fd or -1
local function warmupConnect(self, port)
	local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then return -1 end
	local addr = ffi.new("sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port = ffi.C.htons(port)
	addr.sin_addr = 0x0100007f -- 127.0.0.1 (little-endian host order)
	if ffi.C.connect(fd, ffi.cast("sockaddr *", addr), ffi.sizeof("sockaddr_in")) ~= 0 then
		ffi.C.close(fd)
		return -1
	end
	ffi.C.fcntl(fd, F_SETFL, bit.bor(ffi.C.fcntl(fd, F_GETFL, 0), O_NONBLOCK))
	return fd
end

--- One warmup round trip: send, pump the loop a bounded number of times, drain.
--- Never waits for an exact byte count, so an unusual handler cannot stall it.
---@param self superfast.Server
---@param fd integer
---@param payload string
---@param rbuf superfast.raw.Buffer
---@param steps integer how many loop iterations to run for this round
---@return boolean alive false when the connection died (caller reconnects)
local function warmupExchange(self, fd, payload, rbuf, steps)
	local ptr = ffi.cast("const char *", payload)
	local sent = 0
	local spins = 0
	while sent < #payload and spins < 64 do
		local n = ffi.C.send(fd, ptr + sent, #payload - sent, bit.bor(MSG_DONTWAIT, MSG_NOSIGNAL))
		if n > 0 then
			sent = sent + n
		else
			local e = ffi.errno()
			if e ~= EAGAIN and e ~= EINTR then return false end
			spins = spins + 1
			self:step(WARMUP_STEP_MS) -- peer not reading yet: wait a little
		end
	end

	-- pump the loop: every step submits what the previous one queued, so stop as
	-- soon as a step finds nothing left to do (the round's work is finished)
	local idle = 0
	for _ = 1, steps do
		local n = self:step(WARMUP_STEP_MS)
		if n == 0 then
			idle = idle + 1
			-- a single empty step just means the kernel has not posted the
			-- completions for the last submission yet; only stop once several
			-- steps in a row come up empty
			if idle >= 3 then break end
		else
			idle = 0
		end
	end

	-- drain the client side so the socket buffer cannot fill up
	for _ = 1, 64 do
		local n = ffi.C.recv(fd, rbuf, 16384, MSG_DONTWAIT)
		if n > 0 then
			-- keep draining
		elseif n == 0 then
			return false
		else
			local e = ffi.errno()
			if e == EAGAIN or e == EINTR then break end
			return false
		end
	end
	return true
end

--- Drive real HTTP round trips through the event loop: accept, recv, dispatch,
--- response sending and close, for lone requests and pipelines.
---@param rounds integer
---@param port integer port to drive the round trips against
function Server:warmupTraces(rounds, port)
	if self.tlsCtx then return end -- keep the warmup path plain HTTP

	local rounds = math.max(rounds, 16)
	self:warmupParser(rounds)

	-- With the default hotloop threshold (56) a warmup has to push hundreds of
	-- requests through before anything compiles. Lower it for the warmup only,
	-- so a couple of dozen round trips are enough, then put it back.
	local jit = require("jit")
	local eager = pcall(jit.opt.start, "hotloop=2", "hotexit=2")

	-- Warm the socket path with the internal 200 handler: the user handler is
	-- not invoked here at all (no start-up side effects, no risk of a handler
	-- that errors or closes the connection derailing the warmup).
	local realHandler = self.handler
	if not self.warmupHandler then
		self.handler = function() return 200, nil, "" end
	end

	local one = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: superfast/warmup\r\n\r\n"
	local rbuf = ffi.new("char[?]", 16384)
	local fd = -1
	local connects = 0

	-- Cycle through the shapes real traffic produces: a lone request, a pair and
	-- an 8-deep pipeline. The burst rounds make the loop drain several
	-- completions per iteration and hand the parser a buffer holding several
	-- requests, which is what saturated traffic looks like.
	for i = 1, rounds do
		if fd < 0 then
			if connects >= 4 then break end -- listener unreachable: give up quietly
			connects = connects + 1
			fd = warmupConnect(self, port)
			if fd < 0 then break end
		end
		local burst = 1
		if i % 4 == 2 then burst = 2 elseif i % 4 == 0 then burst = 8 end
		local payload = string.rep(one, burst)
		if not warmupExchange(self, fd, payload, rbuf, burst + 6) then
			-- the handler closed the connection (Connection: close, an error
			-- response, …): start a fresh one and keep warming
			ffi.C.close(fd)
			fd = -1
		end
	end
	if fd >= 0 then ffi.C.close(fd) end

	if self.warmupHandler == nil then self.handler = realHandler end

	-- let the server reap the warmup connection(s) before real traffic starts
	for _ = 1, 16 do
		if self:step(WARMUP_STEP_MS) == 0 then break end
	end

	if eager then pcall(jit.opt.start, "hotloop=56", "hotexit=10") end
end

--- Allocate and provide the initial receive buffer pool.
---@return boolean
function Server:initBuffers()
	local n = self.bufferCount
	for i = 0, n - 1 do
		self.buffers[i] = ffi.new("char[?]", self.bufferSize)
		local sqe = self:sqe()
		self.ring:prepProvideBuffers(sqe, self.buffers[i], self.bufferSize, 1, 0, i)
		self.ring:sqeSetData(sqe, ID_PROVIDE)
		self.providePending = self.providePending + 1
	end
	self.nextBid = n

	-- wait for every provide to land before arming the first recv, so the
	-- pool accounting (buffersInKernel) is exact from the start
	local pending = self.providePending
	self.ring:submitAndWait(pending)
	local seen = 0
	while seen < pending do
		local cqe = self.ring:waitCqe()
		if cqe == nil then return false end
		seen = seen + 1
		self.ring:cqeSeen(cqe)
	end
	self.providePending = 0
	self.buffersInKernel = n
	return true
end

--- Get an SQE. The SQ is sized far above what one batch queues, so a full
--- ring means SQEs leaked somewhere; flush once and fail loudly if that did
--- not help.
---@return superfast.raw.Sqe
function Server:sqe()
	local sqe = self.ring:getSqe()
	if sqe ~= nil then return sqe end
	self.ring:submit()
	sqe = self.ring:getSqe()
	if sqe == nil then error("io_uring SQ full") end
	return sqe
end

---@param conn table
function Server:armRecv(conn)
	if conn.st.inflight ~= INFLIGHT_NONE then return end
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

--- Add `count` more buffers to the provided-buffer pool (used when the pool
--- runs dry, i.e. there are more concurrent recvs than buffers).
---@param count integer
---@return integer added
function Server:growBuffers(count)
	local added = 0
	local nextId = self.nextBid
	while added < count and nextId < self.maxBuffers do
		local buf = ffi.new("char[?]", self.bufferSize) --[[@as superfast.raw.Buffer]]
		self.buffers[nextId] = buf
		local sqe = self:sqe()
		self.ring:prepProvideBuffers(sqe, buf, self.bufferSize, 1, 0, nextId)
		self.ring:sqeSetData(sqe, ID_PROVIDE)
		self.providePending = self.providePending + 1
		nextId = nextId + 1
		added = added + 1
	end
	self.nextBid = nextId
	return added
end

--- Queue a response. Plain array with head/tail cursors: no shifting, and the
--- cursors reset to 1 when it drains, so depth-1 queues never grow the table.
---@param conn table
---@param bytes string
local function queueOut(conn, bytes)
	local t = conn.outTail
	conn.outQ[t] = bytes
	conn.outTail = t + 1
	conn.st.outLen = conn.st.outLen + 1
end

--- Pop the next queued response (nil when the queue is empty).
---@param conn table
---@return string?
local function popOut(conn)
	local h = conn.outHead
	local bytes = conn.outQ[h]
	if bytes == nil then return nil end
	conn.outQ[h] = nil
	h = h + 1
	if h == conn.outTail then h, conn.outTail = 1, 1 end
	conn.outHead = h
	conn.st.outLen = conn.st.outLen - 1
	return bytes
end

-- ── event loop ──────────────────────────────────────────────────────────────

--- Run the event loop until Server:stop().
---
--- One `io_uring_enter` per iteration: every completion that is already done
--- is reaped first (no syscall), then a single submit-and-wait pushes the
--- SQEs those completions queued (recv re-arms, buffer returns, responses)
--- and blocks until the next completion is available. When work is already
--- pending the wait returns immediately, so nothing is wasted.
function Server:run()
	self.running = true
	while self.running do
		self:serveCq()
		self.ring:submitAndWait(1)
	end
end

function Server:stop()
	self.running = false
end

--- Reap and dispatch every completion that is already available. Returns the
--- number handled; the CQ head is advanced as each one is consumed.
---@return integer
function Server:serveCq()
	local ring = self.ring --[[@as superfast.uring.Ring]]
	local n = ring:cqReadyCount()
	if n == 0 then return 0 end
	for _ = 1, n do
		local cqe = ring:peekCqe()          -- reads the live head (non-nil here)
		if cqe == nil then break end
		self:dispatch(cqe)
		ring:cqeSeen(cqe)                   -- advances it
	end
	return n
end

--- One loop iteration: reap what is ready, then submit + wait.
---@param timeoutMs number|nil blocking wait when nil, otherwise a deadline
---@return integer events handled
---@return string? err when timing out
function Server:step(timeoutMs)
	local n = self:serveCq()
	if timeoutMs then
		local ok, err = self.ring:submitAndWaitTimeout(timeoutMs)
		if not ok and n == 0 then return 0, err end
	else
		self.ring:submitAndWait(1)
	end
	return n + self:serveCq(), nil
end

---@param cqe superfast.raw.Cqe
function Server:dispatch(cqe)
	-- read the completion straight out of the CQ entry: the user data is the
	-- 64-bit id we attached at submission, so no liburing call is needed here
	local id = tonumber(cqe.user_data)
	local res = cqe.res

	if id == ID_LISTENER then
		self:onAccept(res)
	elseif id == ID_PROVIDE then
		self.providePending = self.providePending - 1
		self.buffersInKernel = self.buffersInKernel + 1
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
			outQ     = {},
			outHead  = 1,
			outTail  = 1,
			curOut   = nil,
		}
		-- One shared parser callback for every connection: the parser carries
		-- its owner, so no closure is created per accept (a per-accept FNEW
		-- aborts JIT traces).
		local parser = Parser:new({ onMessageComplete = Server.onParserMessage })
		parser.owner = conn
		parser.server = self
		conn.parser = parser
		self.nextId = self.nextId + 1
		self.conns[conn.id] = conn
		-- keep the pool ahead of the connection count instead of letting a
		-- recv find an empty pool later
		if self.buffersInKernel < 4 and self.nextBid < self.maxBuffers then
			self:growBuffers(math.min(64, self.maxBuffers - self.nextBid))
		end
		self:armRecv(conn)
	end
	-- re-arm regardless (errors like EMFILE are transient)
	self:armAccept()
end

--- Shared onMessageComplete: the connection is the parser's owner.
---@param req superfast.http.Request
function Server.onParserMessage(req)
	local p = req.__parser
	p.server:onRequest(p.owner, req)
end

-- ── connection handling ─────────────────────────────────────────────────────

---@param conn table
---@param cqe superfast.raw.Cqe
---@param res integer bytes received
function Server:onRecv(conn, cqe, res)
	if res > 0 then
		local bid = bit.rshift(tonumber(cqe.flags), 16)
		self.buffersInKernel = self.buffersInKernel - 1
		local buf = self.buffers[bid]
		if conn.tls then
			conn.tls:feedPtr(buf, res)
			self:driveTls(conn)
		else
			self:afterFeed(conn, conn.parser:feedPtr(buf, res))
		end
		self:reProvide(bid)
	elseif res == -ENOBUFS then
		-- no provided buffer was available to receive into: grow the pool and
		-- retry instead of dropping the connection
		if self:growBuffers(64) == 0 then
			self:closeConn(conn)
			return
		end
		self:armRecv(conn)
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
			queueOut(conn, out)
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
---@param req superfast.http.Request
function Server:onRequest(conn, req)
	self:handleRequest(conn, req)
end

---@param conn table
---@param cqe superfast.raw.Cqe
---@param res integer bytes sent
function Server:onSend(conn, cqe, res)
	local st = conn.st
	if res < 0 then
		self:closeConn(conn)
		return
	end
	st.curOff = st.curOff + res
	if st.curOff < st.curOutLen then
		-- partial send: queue the rest, the send stays in flight
		local sqe = self:sqe()
		local out = conn.curOut --[[@as string]]
		self.ring:prepSend(sqe, st.fd, ffi.cast("const char *", out) + st.curOff, st.curOutLen - st.curOff, MSG_NOSIGNAL)
		self.ring:sqeSetData(sqe, conn.id)
		return
	end
	conn.curOut = nil
	st.inflight = INFLIGHT_NONE -- the send completed: rearm or close is allowed
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
	local out = popOut(conn)
	if out == nil then return end -- queue drained (defensive: outLen said otherwise)
	conn.curOut = out
	st.curOff = 0
	st.curOutLen = #out
	local sqe = self:sqe()
	-- MSG_NOSIGNAL: a send on a reset socket must not raise SIGPIPE and kill
	-- the process (io_uring runs the send in our own task context).
	-- The Lua string is passed straight through (LuaJIT hands the C call its
	-- bytes) and stays reachable as conn.curOut until the send CQE lands — no
	-- pointer cast, so no per-response cdata allocation.
	self.ring:prepSend(sqe, st.fd, out, st.curOutLen, MSG_NOSIGNAL)
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
	conn.outQ = nil
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
---@param req superfast.http.Request
function Server:handleRequest(conn, req)
	local ok, r1, r2, r3
	if self.handlerTakesReq then
		ok, r1, r2, r3 = pcall(self.handler, req)
	else
		-- handler declares no parameters: it provably cannot use req
		ok, r1, r2, r3 = pcall(self.handler)
	end
	if not ok then
		self:sendError(conn, 500, tostring(r1))
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
	queueOut(conn, bytes)
end

--- Queue a plain-text error response and close after it is sent.
---@param conn table
---@param status integer
---@param msg string?
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
	queueOut(conn, bytes)
	conn.st.closeAfterSend = 1
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

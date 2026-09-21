-- Streaming HTTP/1.x request parser: pipelining and keep-alive aware.
-- Architecture and the `req` lifetime contract: docs/ARCHITECTURE.md.

local ffi = require("ffi")

ffi.cdef [[
  char *memmem(const void *haystack, size_t haystack_len, const void *needle, size_t needle_len);
  char *memchr(const void *s, int c, size_t n);
  int memcmp(const void *s1, const void *s2, size_t n);

  typedef struct {
    int32_t fbufLen;
    int32_t state;           /* 0 = headers, 1 = body, 2 = complete */
    int32_t msgConsumed;     /* bytes of the current message already parsed */
    int32_t msgBodyOff;      /* body start offset in fbuf (-1 = none) */
    int32_t msgBodyLen;
    int32_t msgMethodOff;
    int32_t msgMethodLen;
    int32_t msgPathOff;      /* -1 = empty path ("/") */
    int32_t msgPathLen;
    int32_t msgQueryOff;     /* -1 = no query */
    int32_t msgQueryLen;
    int32_t msgHeadLen;
    int32_t msgContentLength; /* -1 = none */
    int32_t msgKeepAlive;    /* 0/1 */
    int32_t bodyTotal;
    int32_t reqDirty;        /* pooled req has materialized fields */
  } parser_state;
]]

-- Needles are passed to the FFI calls as Lua strings (not pre-cast pointers):
-- referencing them inside the parser functions keeps them alive as upvalues,
-- and LuaJIT converts them to const char* for the duration of each call.
local CRLFCRLF = "\r\n\r\n"
local LF2      = "\n\n"
local HTTP11   = "HTTP/1.1"
local HTTP10   = "HTTP/1.0"

-- parser_state.state values
local ST_HEADERS = 0
local ST_BODY    = 1
local ST_COMPLETE = 2

-- byte values used by the scanner
local CR = 13
local SP = 32
local TAB = 9
local COLON = 58
local QUESTION = 63
local COMMA = 44

---@class superfast.http.Request
---@field method string lazily materialized
---@field path string lazily materialized
---@field query string lazily materialized
---@field version string
---@field headers table<string,string>|nil lazily materialized
---@field keepAlive boolean
---@field body string lazily materialized
---@field __parser superfast.http.Parser owning parser (internal)

--- Callbacks and limits for `httpParser.Parser:new`.
---@class superfast.http.ParserOptions
---@field onHeadersComplete fun(req: superfast.http.Request)? called once the request line and headers are parsed
---@field onBody fun(chunk: string)? called for each body chunk (only when set)
---@field onMessageComplete fun(req: superfast.http.Request)? called when a full message is available
---@field maxHeaderSize integer? header block limit in bytes (default 65536)
---@field maxBodySize integer? body limit in bytes (default 16777216)
---@field bufferSize integer? initial accumulation buffer size (default 65536)

---@class superfast.http.Parser
---@field owner table? connection owning this parser (server sets it)
---@field server superfast.Server? server that created this parser
---@field fbuf superfast.raw.Buffer growable accumulation buffer
---@field fbufCap integer
---@field s superfast.raw.ParserState hot state (FFI struct)
---@field msgVersion string HTTP minor version of the current message
---@field req superfast.http.Request pooled request object
---@field maxHeaderSize integer
---@field maxBodySize integer

local Parser = {}
Parser.__index = Parser

--- Case-insensitive compare of buffer[off .. off+len-1] against a lowercase
--- string.
---@param buf superfast.raw.Buffer
---@param off integer
---@param len integer
---@param s string lowercase needle
---@return boolean
local function nameEq(buf, off, len, s)
	if len ~= #s then return false end
	for i = 0, len - 1 do
		local b = buf[off + i]
		if b >= 65 and b <= 90 then b = b + 32 end
		if b ~= s:byte(i + 1) then return false end
	end
	return true
end

--- Does the header value in buffer[off .. off+len) contain `token` (lowercase)
--- as a comma-separated token?
---@param buf superfast.raw.Buffer
---@param off integer
---@param len integer
---@param token string lowercase needle
---@return boolean
local function valueHasToken(buf, off, len, token)
	local tlen = #token
	local ve = off + len
	local i = off
	while i < ve do
		local b = buf[i]
		if b == COMMA or b == SP or b == TAB then
			i = i + 1
		else
			local start = i
			while i < ve and buf[i] ~= COMMA do i = i + 1 end
			if i - start == tlen then
				local match = true
				for j = 0, tlen - 1 do
					local c = buf[start + j]
					if c >= 65 and c <= 90 then c = c + 32 end
					if c ~= token:byte(j + 1) then match = false break end
				end
				if match then return true end
			end
		end
	end
	return false
end

-- ── lazy request object ─────────────────────────────────────────────────────

---@param req superfast.http.Request
---@param k string
---@param ptr superfast.raw.Buffer
---@param len integer
local function materialize(req, k, ptr, len)
	rawset(req, k, ffi.string(ptr, len))
	req.__parser.s.reqDirty = 1
	return req[k]
end

--- Materialize the full headers table from the buffered head.
---@param req superfast.http.Request
---@param p superfast.http.Parser
---@return table<string,string>
local function buildHeaders(req, p)
	local s = p.s
	local buf = p.fbuf
	local headEnd = buf + s.msgHeadLen
	local headers = {}

	local lineEnd = ffi.C.memchr(buf, CR, s.msgHeadLen)
	local h = lineEnd
	if h == nil then h = headEnd end
	h = h + 2 -- skip the request line + CRLF
	while h < headEnd do
		local nl = ffi.C.memchr(h, CR, headEnd - h)
		local he = nl
		if he == nil then he = headEnd end
		local colon = ffi.C.memchr(h, COLON, he - h)
		if colon ~= nil then
			local name = ffi.string(h, colon - h)
			local vs = colon + 1
			local ve = he
			while vs < ve do
				local b = vs[0]
				if b ~= SP and b ~= TAB then break end
				vs = vs + 1
			end
			headers[name:lower()] = ffi.string(vs, ve - vs)
		end
		if nl == nil then break end
		h = nl + 2
	end

	rawset(req, "headers", headers)
	s.reqDirty = 1
	return headers
end

local reqMeta = {}
reqMeta.__index = function(req, k)
	local s = req.__parser.s
	if k == "method" then
		return rawget(req, k) or materialize(req, k, req.__parser.fbuf + s.msgMethodOff, s.msgMethodLen)
	elseif k == "path" then
		if s.msgPathOff < 0 then return "/" end
		return rawget(req, k) or materialize(req, k, req.__parser.fbuf + s.msgPathOff, s.msgPathLen)
	elseif k == "query" then
		if s.msgQueryOff < 0 then return "" end
		return rawget(req, k) or materialize(req, k, req.__parser.fbuf + s.msgQueryOff, s.msgQueryLen)
	elseif k == "version" then
		return req.__parser.msgVersion
	elseif k == "keepAlive" then
		return s.msgKeepAlive ~= 0
	elseif k == "headers" then
		return rawget(req, k) or buildHeaders(req, req.__parser)
	elseif k == "body" then
		if s.msgBodyLen > 0 then
			return rawget(req, k) or materialize(req, k, req.__parser.fbuf + s.msgBodyOff, s.msgBodyLen)
		end
		return ""
	end
	return nil
end

-- ── parser state machine ────────────────────────────────────────────────────

---@param opts superfast.http.ParserOptions?
---@return superfast.http.Parser
function Parser:new(opts)
	opts = opts or {}
	local cap = opts.bufferSize or 65536
	local p = {
		fbuf          = ffi.new("char[?]", cap) --[[@as superfast.raw.Buffer]],
		fbufCap       = cap,
		s             = ffi.new("parser_state") --[[@as superfast.raw.ParserState]],
		msgVersion    = "1.1",
		maxHeaderSize = opts.maxHeaderSize or 65536,
		maxBodySize   = opts.maxBodySize or 16777216,
		onHeaders     = opts.onHeadersComplete,
		onBody        = opts.onBody,
		onComplete    = opts.onMessageComplete,
	}
	local s = p.s
	s.msgContentLength = -1
	s.msgQueryOff = -1
	s.msgPathOff = -1
	s.msgBodyOff = -1
	p.req = setmetatable({ __parser = p }, reqMeta)
	return setmetatable(p, Parser)
end

---@return superfast.http.Parser
function Parser:reset()
	local s = self.s
	s.fbufLen = 0
	s.state = ST_HEADERS
	s.msgConsumed = 0
	s.msgBodyLen = 0
	s.msgContentLength = -1
	s.bodyTotal = 0
	return self
end

--- Append n bytes from ptr into the accumulation buffer, growing it on demand.
---@param self superfast.http.Parser
---@param ptr string|superfast.raw.Ptr
---@param n integer
local function append(self, ptr, n)
	local s = self.s
	local need = s.fbufLen + n
	if need > self.fbufCap then
		local newCap = math.max(self.fbufCap * 2, need)
		local newBuf = ffi.new("char[?]", newCap) --[[@as superfast.raw.Buffer]]
		ffi.copy(newBuf, self.fbuf, s.fbufLen)
		self.fbuf = newBuf
		self.fbufCap = newCap
	end
	ffi.copy(self.fbuf + s.fbufLen, ptr, n)
	s.fbufLen = need
end

--- Drop the first n bytes, shifting any leftover to the front of the buffer.
---@param self superfast.http.Parser
---@param n integer
local function consume(self, n)
	local s = self.s
	s.fbufLen = s.fbufLen - n
	if s.fbufLen > 0 then
		ffi.copy(self.fbuf, self.fbuf + n, s.fbufLen)
	end
end

--- Scan the buffered head, recording lazy ranges + the fields the parser
--- itself needs. Returns an error string or nil.
---@param p superfast.http.Parser
---@param headLen integer
---@return string|nil
local function parseHead(p, headLen)
	local s = p.s
	local buf = p.fbuf
	local headEnd = buf + headLen

	-- request line: METHOD SP TARGET SP HTTP/x.y (terminated by CRLF)
	-- note: NULL cdata pointers are truthy in LuaJIT — test with == nil
	local lineEnd = ffi.C.memchr(buf, CR, headLen)
	local le = lineEnd
	if le == nil then le = headEnd end
	local sp1 = ffi.C.memchr(buf, SP, le - buf)
	local sp2
	if sp1 ~= nil and le - sp1 > 1 then
		sp2 = ffi.C.memchr(sp1 + 1, SP, le - sp1 - 1)
	end
	if sp1 == nil or sp2 == nil then return "malformed request line" end

	local vlen = le - sp2 - 1
	local minor
	if vlen == 8 and ffi.C.memcmp(sp2 + 1, HTTP11, 8) == 0 then
		minor = "1.1"
	elseif vlen == 8 and ffi.C.memcmp(sp2 + 1, HTTP10, 8) == 0 then
		minor = "1.0"
	else
		return "unsupported http version"
	end

	-- record request-line ranges for lazy materialization
	s.msgMethodOff = 0
	s.msgMethodLen = sp1 - buf
	s.msgHeadLen = headLen

	local tStart = sp1 + 1
	local tEnd = sp2
	local q = ffi.C.memchr(tStart, QUESTION, tEnd - tStart)
	if q ~= nil then
		s.msgPathOff = tStart - buf
		s.msgPathLen = q - tStart
		s.msgQueryOff = q + 1 - buf
		s.msgQueryLen = tEnd - q - 1
	else
		s.msgPathOff = tStart - buf
		s.msgPathLen = tEnd - tStart
		s.msgQueryOff = -1
	end
	if s.msgPathLen == 0 then s.msgPathOff = -1 end

	-- scan headers for the fields the parser itself needs
	local contentLength = -1
	local keepAlive = minor == "1.1" and 1 or 0
	local h = le + 2
	while h < headEnd do
		local nl = ffi.C.memchr(h, CR, headEnd - h)
		local he = nl
		if he == nil then he = headEnd end
		local colon = ffi.C.memchr(h, COLON, he - h)
		if colon ~= nil then
			local nameLen = colon - h
			local vs = colon + 1
			local ve = he
			while vs < ve do
				local b = vs[0]
				if b ~= SP and b ~= TAB then break end
				vs = vs + 1
			end
			local off = h - buf
			if nameEq(buf, off, nameLen, "content-length") then
				local n = 0
				local digits = 0
				for i = vs - buf, ve - buf - 1 do
					local b = buf[i]
					if b < 48 or b > 57 then break end
					n = n * 10 + (b - 48)
					digits = digits + 1
				end
				if digits > 0 then contentLength = n end
			elseif nameEq(buf, off, nameLen, "connection") then
				local vlen2 = ve - vs
				if valueHasToken(buf, vs - buf, vlen2, "close") then
					keepAlive = 0
				elseif minor == "1.0" and valueHasToken(buf, vs - buf, vlen2, "keep-alive") then
					keepAlive = 1
				end
			elseif nameEq(buf, off, nameLen, "transfer-encoding") then
				return "transfer-encoding not supported"
			end
		end
		if nl == nil then break end
		h = nl + 2
	end

	s.msgContentLength = contentLength
	s.msgKeepAlive = keepAlive
	p.msgVersion = minor
	return nil
end

--- Process everything buffered so far, firing callbacks for every complete
--- message (pipelining loop). The buffer is only compacted after each
--- callback returns, so callbacks can lazily materialize fields from it.
---@return boolean|nil, string?
function Parser:parse()
	local s = self.s
	while true do
		if s.state == ST_HEADERS then
			if s.fbufLen == 0 then return true end

			local term = ffi.C.memmem(self.fbuf, s.fbufLen, CRLFCRLF, 4)
			local termLen = 4
			if term == nil then
				local alt = ffi.C.memmem(self.fbuf, s.fbufLen, LF2, 2)
				if alt ~= nil then term, termLen = alt, 2 end
			end
			if term == nil then
				if s.fbufLen > self.maxHeaderSize then
					return nil, "request headers too large"
				end
				return true -- need more data
			end

			local headLen = term - self.fbuf
			if headLen > self.maxHeaderSize then
				return nil, "request headers too large"
			end

			-- reset the pooled request object if it has materialized fields
			if s.reqDirty ~= 0 then
				local req = self.req
				for k in pairs(req) do
					if k ~= "__parser" then req[k] = nil end
				end
				s.reqDirty = 0
			end

			local err = parseHead(self, headLen)
			if err ~= nil then return nil, err end

			s.msgConsumed = headLen + termLen
			s.msgBodyLen = 0
			s.msgBodyOff = -1
			s.bodyTotal = 0
			if s.msgContentLength >= 0 then
				s.state = ST_BODY
			else
				s.state = ST_COMPLETE
			end
			if self.onHeaders then self.onHeaders(self.req) end
		end

		if s.state == ST_BODY then
			if s.msgContentLength <= 0 then
				s.state = ST_COMPLETE
			else
				local available = s.fbufLen - s.msgConsumed
				if available <= 0 then return true end
				local take = math.min(available, s.msgContentLength)
				s.bodyTotal = s.bodyTotal + take
				if s.bodyTotal > self.maxBodySize then
					return nil, "request body too large"
				end
				if self.onBody then
					self.onBody(ffi.string(self.fbuf + s.msgConsumed, take))
				end
				s.msgBodyLen = s.msgBodyLen + take
				s.msgConsumed = s.msgConsumed + take
				s.msgContentLength = s.msgContentLength - take
				if s.msgContentLength == 0 then s.state = ST_COMPLETE end
			end
		end

		if s.state == ST_COMPLETE then
			s.msgBodyOff = s.msgConsumed - s.msgBodyLen
			if self.onComplete then self.onComplete(self.req) end
			-- the callback has consumed the message; compact the buffer now
			consume(self, s.msgConsumed)
			s.state = ST_HEADERS
			s.msgConsumed = 0
			s.msgBodyLen = 0
			if s.fbufLen == 0 then return true end
		end
	end
end

--- Feed bytes from a cdata buffer (e.g. a recv buffer) — no copy.
---@param ptr superfast.raw.Buffer char*
---@param n integer
---@return boolean|nil, string?
function Parser:feedPtr(ptr, n)
	if n == 0 then return true end
	append(self, ptr, n)
	return self:parse()
end

--- Feed a Lua string of received bytes.
---@param chunk string
---@return boolean|nil, string?
function Parser:feed(chunk)
	if chunk == "" then return true end
	append(self, chunk, #chunk)
	return self:parse()
end

--- The parser module: the `Parser` class itself.
---@type superfast.http.Parser
local httpParser = Parser

return httpParser

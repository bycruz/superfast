-- tests/lib/client.lua — minimal blocking socket client for server tests.
--
-- Uses the shared libc socket API declared by superfast.io_uring, so this
-- module must be required after `require("superfast")`.

local ffi = require("ffi")

ffi.cdef [[
  long recv(int sockfd, void *buf, size_t len, int flags);
  long send(int sockfd, const void *buf, size_t len, int flags);
  unsigned int inet_addr(const char *cp);
]]

local C = ffi.C

local AF_INET = 2
local SOCK_STREAM = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

local client = {}

--- Connect to host:port. Returns fd or nil, err.
---@param host string
---@param port integer
---@return integer|nil, string?
function client.connect(host, port)
	local fd = C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then return nil, "socket() failed" end

	local addr = ffi.new("sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port = C.htons(port)
	addr.sin_addr = C.inet_addr(host)
	if addr.sin_addr == 0xFFFFFFFF then
		C.close(fd)
		return nil, "bad host: " .. host
	end

	if C.connect(fd, ffi.cast("sockaddr *", addr), ffi.sizeof("sockaddr_in")) ~= 0 then
		C.close(fd)
		return nil, "connect() failed"
	end
	return fd, nil
end

--- Blocking send of the whole string.
---@param fd integer
---@param data string
---@return boolean, string?
function client.sendAll(fd, data)
	local ptr = ffi.cast("const char *", data)
	local off = 0
	while off < #data do
		local n = C.send(fd, ptr + off, #data - off, 0)
		if n < 0 then return false, "send() failed" end
		off = off + n
	end
	return true, nil
end

--- Non-blocking recv: returns data or nil when nothing is available.
---@param fd integer
---@param len integer?
---@return string|nil
function client.recvSome(fd, len)
	local buf = ffi.new("char[?]", len or 4096)
	local n = C.recv(fd, buf, len or 4096, 0)
	if n <= 0 then return nil end
	return ffi.string(buf, n)
end

--- Set the fd non-blocking.
---@param fd integer
function client.setNonBlocking(fd)
	local fl = C.fcntl(fd, F_GETFL, 0)
	C.fcntl(fd, F_SETFL, bit.bor(fl, O_NONBLOCK))
end

---@param fd integer
function client.close(fd)
	C.close(fd)
end

return client

-- benchmarks: HTTP server comparison suite.
--
--   cd benchmarks && lde run            run every server
--   SERVERS=node,bun lde run            run a subset
--   DUR=5 lde run                       shorter wrk run (default 10s)
--   THREADS=4 CONNS=128 lde run         different wrk load
--   PIN=2 lde run                       pin every server to one CPU
--
-- Each benchmark: spawn the server (process library), wait until its port
-- answers, load-test it with wrk (built by build.lua), sample the process
-- tree's memory, then tear the tree down. Results print as an ANSI table.

local process = require("process")
local colors = require("benchmarks.colors")
local ffi = require("ffi")

ffi.cdef [[
  typedef unsigned int socklen_t;
  struct sockaddr { unsigned short sa_family; char sa_data[14]; };
  typedef struct sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int   sin_addr;
    char sin_zero[8];
  } sockaddr_in;
  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int close(int fd);
  unsigned short htons(unsigned short hostshort);
  int kill(int pid, int sig);
  int usleep(unsigned int usec);
]]

-- ── config (env) ────────────────────────────────────────────────────────────
local DUR      = tonumber(os.getenv("DUR")) or 10
local THREADS  = tonumber(os.getenv("THREADS")) or 2
local CONNS    = tonumber(os.getenv("CONNS")) or 64
local PIN      = os.getenv("PIN")
local PORT_BASE = tonumber(os.getenv("PORT_BASE")) or 8091
local OPENRESTY_PREFIX = os.getenv("OPENRESTY_PREFIX") or (os.getenv("HOME") .. "/openresty")

-- package root (benchmarks/): this file lives at <root>/src/init.lua
local srcPath = debug.getinfo(1, "S").source:sub(2)
local ROOT = (srcPath:match("^(.*[/\\])src[/\\]init%.lua$")) or "./"
local WRK = ROOT .. "target/benchmarks/wrk/wrk"

-- ── small helpers ───────────────────────────────────────────────────────────
local AF_INET, SOCK_STREAM = 2, 1
local SIGTERM, SIGKILL = 15, 9

--- One TCP connect attempt to 127.0.0.1:port; true when the port answers.
local function tcpProbe(port)
	local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then return false end
	local addr = ffi.new("sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port = ffi.C.htons(port)
	addr.sin_addr = 0x0100007f -- 127.0.0.1 (little-endian host order)
	local ok = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof("sockaddr_in")) == 0
	ffi.C.close(fd)
	return ok
end

--- Poll a port for up to timeoutSec seconds. Every poll also drains the
--- spawned child's pipes (so a chatty server can't deadlock on a full pipe)
--- and returns early if the child exited.
---@param child process.Child
---@param port integer
---@param timeoutSec number
---@return boolean ready
---@return number? exitCode
local function waitReady(child, port, timeoutSec)
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		if tcpProbe(port) then return true, nil end
		local code = child:poll()
		if code ~= nil then return false, code end
		ffi.C.usleep(100000)
	end
	return false, nil
end

--- Pids listening on a TCP port (any address). Uses /proc/net/tcp (listener
--- inode) + /proc/<pid>/fd symlinks to map inode -> pid.
local function portPids(port)
	local want = string.format(":%04X", port)
	local inodes = {}
	local f = io.open("/proc/net/tcp")
	if f then
		for line in f:lines() do
			local la, st, inode = line:match("^%s*%d+:%s*(%S+)%s+%S+%s+(%x+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%d+%s+(%d+)")
			if la and la:match(want .. "$") and st == "0A" and inode then
				inodes[inode] = true
			end
		end
		f:close()
	end
	local pids = {}
	if next(inodes) then
		local ls = io.popen("ls -l /proc/[0-9]*/fd 2>/dev/null")
		for line in ls:lines() do
			local pid, inode = line:match("/proc/(%d+)/fd/%d+ %-> socket:%[(%d+)%]")
			if pid and inodes[inode] then pids[#pids + 1] = tonumber(pid) end
		end
		ls:close()
	end
	return pids
end

--- pid -> ppid map for every process.
local function procTable()
	local t = {}
	local f = io.popen("ps -eo pid=,ppid=")
	for line in f:lines() do
		local pid, ppid = line:match("^%s*(%d+)%s+(%d+)%s*$")
		if pid then t[tonumber(pid)] = tonumber(ppid) end
	end
	f:close()
	return t
end

--- All descendant pids of root, including root itself.
local function descendants(root)
	local kids = {}
	for pid, ppid in pairs(procTable()) do
		kids[ppid] = kids[ppid] or {}
		kids[ppid][#kids[ppid] + 1] = pid
	end
	local out, stack = { root }, { root }
	while #stack > 0 do
		local p = table.remove(stack)
		for _, c in ipairs(kids[p] or {}) do
			out[#out + 1] = c
			stack[#stack + 1] = c
		end
	end
	return out
end

--- Memory of a process tree: "rss peak" in MB. rss is the sum of VmRSS across
--- the tree, peak the largest single-process VmHWM (high-water mark).
local function treeMem(root)
	local rss, peak = 0, 0
	for _, pid in ipairs(descendants(root)) do
		local f = io.open("/proc/" .. pid .. "/status")
		if f then
			for line in f:lines() do
				local r = line:match("^VmRSS:%s+(%d+)")
				if r then rss = rss + tonumber(r) end
				local h = line:match("^VmHWM:%s+(%d+)")
				if h and tonumber(h) > peak then peak = tonumber(h) end
			end
			f:close()
		end
	end
	return math.floor(rss / 1024), math.floor(peak / 1024)
end

--- SIGTERM then SIGKILL a process tree; then clear any listener left on port.
local function killTree(root, port)
	for _, pid in ipairs(descendants(root)) do ffi.C.kill(pid, SIGTERM) end
	ffi.C.usleep(200000)
	for _, pid in ipairs(descendants(root)) do ffi.C.kill(pid, SIGKILL) end
	if port then
		for _, pid in ipairs(portPids(port)) do ffi.C.kill(pid, SIGKILL) end
	end
end

--- Find an executable on PATH (returns its path or nil).
local function findBin(name)
	local path = os.getenv("PATH") or ""
	for dir in path:gmatch("[^:]+") do
		local p = dir .. "/" .. name
		local f = io.open(p, "r")
		if f then f:close() return p end
	end
	return nil
end

--- Spawn a server binary, optionally under taskset when PIN is set.
local function spawnServer(bin, argv, opts)
	if PIN then
		return process.spawn("taskset", { "-c", PIN, bin, unpack(argv) }, opts)
	end
	return process.spawn(bin, argv, opts)
end

--- Parse wrk's stdout into (reqs, p50, p99, errors).
local function parseWrk(out)
	local reqs, p50, p99, errors = nil, "--", "--", 0
	for line in out:gmatch("[^\r\n]+") do
		local r = line:match("Requests/sec:%s+([%d%.]+)")
		if r then reqs = tonumber(r) end
		local p = line:match("^%s*50%%%s+([%S]+)")
		if p then p50 = p end
		p = line:match("^%s*99%%%s+([%S]+)")
		if p then p99 = p end
		local e1, e2, e3, e4 = line:match("Socket errors: connect (%d+), read (%d+), write (%d+), timeout (%d+)")
		if e1 then errors = tonumber(e1) + tonumber(e2) + tonumber(e3) + tonumber(e4) end
	end
	return reqs, p50, p99, errors
end

-- ── the servers ─────────────────────────────────────────────────────────────
local servers = {
	{
		name = "node", port = PORT_BASE + 0,
		check = function() return findBin("node") end,
		start = function(port)
			return spawnServer("node", { "server.js" }, {
				cwd = ROOT .. "servers/node",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "bun", port = PORT_BASE + 1,
		check = function() return findBin("bun") end,
		start = function(port)
			return spawnServer("bun", { "server.js" }, {
				cwd = ROOT .. "servers/bun",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "superfast", port = PORT_BASE + 2,
		check = function() return findBin("lde") end,
		start = function(port)
			return spawnServer("lde", { "run" }, {
				cwd = ROOT .. "servers/superfast",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "python", port = PORT_BASE + 3,
		check = function() return findBin("python3") end,
		start = function(port)
			return spawnServer("python3", { "server.py" }, {
				cwd = ROOT .. "servers/python",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "lapis", port = PORT_BASE + 4,
		check = function()
			if not findBin("lapis") then return nil end
			local nginx = io.open(OPENRESTY_PREFIX .. "/nginx/sbin/nginx")
			if nginx then nginx:close() return true end
			return nil
		end,
		start = function(port)
			-- The lapis CLI (e.g. installed via `lde install rocks:lapis`) runs
			-- under `lde x`, whose sandbox package.path does not resolve
			-- ./config.lua, so the generated nginx.conf would fall back to
			-- defaults (code_cache off, no lua paths). The config compiler
			-- checks LAPIS_* env vars first (lapis/cmd/nginx/config.lua
			-- wrap_environment), so pass everything explicitly.
			local rocks = OPENRESTY_PREFIX .. "/luajit-rocks"
			local rockLib = rocks .. "/lib"
			if io.open(rocks .. "/lib64/lua/5.1") then rockLib = rocks .. "/lib64" end
			local luaPath = OPENRESTY_PREFIX .. "/lualib/?.lua;" .. OPENRESTY_PREFIX .. "/lualib/?/init.lua;"
				.. rocks .. "/share/lua/5.1/?.lua;" .. rocks .. "/share/lua/5.1/?/init.lua;;"
			local luaCPath = OPENRESTY_PREFIX .. "/lualib/?.so;" .. rockLib .. "/lua/5.1/?.so;;"
			return spawnServer("lapis", { "server" }, {
				cwd = ROOT .. "servers/lapis",
				env = {
					LAPIS_PORT = tostring(port),
					LAPIS_CODE_CACHE = "on",
					LAPIS_NUM_WORKERS = "1",
					LAPIS_PACKAGE_PATH = luaPath,
					LAPIS_PACKAGE_CPATH = luaCPath,
					LAPIS_OPENRESTY = OPENRESTY_PREFIX .. "/nginx/sbin/nginx",
					OPENRESTY_PREFIX = OPENRESTY_PREFIX,
				},
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "express", port = PORT_BASE + 5,
		check = function()
			if not findBin("node") then return nil end
			local f = io.open(ROOT .. "servers/express/node_modules/express/package.json")
			if f then f:close() return true end
			return nil
		end,
		start = function(port)
			return spawnServer("node", { "server.js" }, {
				cwd = ROOT .. "servers/express",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "elysia", port = PORT_BASE + 6,
		check = function()
			if not findBin("bun") then return nil end
			local f = io.open(ROOT .. "servers/elysia/node_modules/elysia/package.json")
			if f then f:close() return true end
			return nil
		end,
		start = function(port)
			return spawnServer("bun", { "server.js" }, {
				cwd = ROOT .. "servers/elysia",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "hono", port = PORT_BASE + 7,
		check = function()
			if not findBin("bun") then return nil end
			local f = io.open(ROOT .. "servers/hono/node_modules/hono/package.json")
			if f then f:close() return true end
			return nil
		end,
		start = function(port)
			return spawnServer("bun", { "server.js" }, {
				cwd = ROOT .. "servers/hono",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	},
	{
		name = "just-js", port = PORT_BASE + 8,
		check = function() return findBin("lde") end,
		start = function(port)
			return spawnServer("lde", { "run" }, {
				cwd = ROOT .. "servers/just-js",
				env = { PORT = tostring(port) },
				stdout = "null", stderr = "pipe",
			})
		end,
	}
}

-- ── run one server ──────────────────────────────────────────────────────────
---@return table result { reqs?, p50?, p99?, errors?, rss?, peak?, skipped? }
local function runServer(srv)
	local skip = function(msg) return { skipped = msg } end

	-- free the port from any stale listener (a previous crashed run)
	for _, p in ipairs(portPids(srv.port)) do ffi.C.kill(p, SIGKILL) end

	if not srv.check() then return skip("not installed") end

	local child, err = srv.start(srv.port)
	if not child then return skip("spawn failed: " .. tostring(err)) end

	local ready, exitCode = waitReady(child, srv.port, 90)
	if not ready then
		local _, so, se = child:wait()
		killTree(child.pid, srv.port)
		local detail = (se or so or ""):gsub("[\r\n]+", " "):sub(1, 120)
		return skip("failed to start" .. (exitCode and (" (exit " .. exitCode .. ")") or "")
			.. (detail ~= "" and (": " .. detail) or ""))
	end

	local url = "http://127.0.0.1:" .. srv.port .. "/"
	-- Run wrk async and poll both children: drains the server's stderr pipe
	-- during the load (a chatty server would otherwise block on a full pipe
	-- and collapse its throughput).
	local wrkChild, werr = process.spawn(WRK, {
		"-t" .. THREADS, "-c" .. CONNS, "-d" .. DUR .. "s", "--latency", url,
	}, { stdout = "pipe", stderr = "pipe" })
	if not wrkChild then
		killTree(child.pid, srv.port)
		return skip("wrk spawn failed: " .. tostring(werr))
	end
	local wcode
	while true do
		wcode = wrkChild:poll()
		child:poll()
		if wcode ~= nil then break end
		ffi.C.usleep(20000)
	end
	local _, out, errout = wrkChild:wait()

	local reqs, p50, p99, errors = parseWrk(out or "")
	if not reqs then
		killTree(child.pid, srv.port)
		local _, _, se = child:wait()
		local detail = (errout or se or ""):gsub("[\r\n]+", " "):sub(1, 120)
		return skip("wrk failed" .. (detail ~= "" and (": " .. detail) or ""))
	end

	local rss, peak = treeMem(child.pid)
	killTree(child.pid, srv.port)
	child:wait() -- reap

	return { reqs = reqs, p50 = p50, p99 = p99, errors = errors, rss = rss, peak = peak }
end

-- ── the table ───────────────────────────────────────────────────────────────
local function comma(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse()):gsub("^,", "")
end

local function render(results)
	local headers = { "server", "req/s", "p50", "p99", "errors", "rss(MB)", "peak(MB)" }
	local rows = {} -- { ok = bool, cells = string[], skipMsg = string? }
	local best = 0
	for _, srv in ipairs(servers) do
		local r = results[srv.name]
		if r and r.reqs then
			if r.reqs > best then best = r.reqs end
			rows[#rows + 1] = {
				ok = true,
				cells = { srv.name, comma(r.reqs), r.p50, r.p99, tostring(r.errors), tostring(r.rss), tostring(r.peak) },
			}
		else
			rows[#rows + 1] = {
				ok = false,
				cells = { srv.name, "--", "--", "--", "--", "--", "--" },
				skipMsg = (r and r.skipped) or "unknown error",
			}
		end
	end

	-- column widths from plain text (ANSI codes would corrupt alignment)
	local widths = {}
	for i, h in ipairs(headers) do widths[i] = #h end
	for _, row in ipairs(rows) do
		for i, c in ipairs(row.cells) do
			if #c > widths[i] then widths[i] = #c end
		end
	end
	local pad = function(i, c)
		if i == 1 then return string.format("%-" .. widths[i] .. "s", c) end
		return string.format("%" .. widths[i] .. "s", c)
	end

	local out = {}
	out[#out + 1] = colors.paint("bold", colors.paint("cyan", table.concat({
		pad(1, headers[1]), pad(2, headers[2]), pad(3, headers[3]), pad(4, headers[4]),
		pad(5, headers[5]), pad(6, headers[6]), pad(7, headers[7]),
	}, "  ")))
	out[#out + 1] = colors.paint("dim", string.rep("-", 68))
	for _, row in ipairs(rows) do
		local joined = table.concat({ pad(1, row.cells[1]), pad(2, row.cells[2]), pad(3, row.cells[3]),
			pad(4, row.cells[4]), pad(5, row.cells[5]), pad(6, row.cells[6]), pad(7, row.cells[7]) }, "  ")
		if not row.ok then
			out[#out + 1] = colors.paint("yellow", joined) .. colors.paint("dim", "  (" .. row.skipMsg .. ")")
		elseif row.cells[1] == "superfast" then
			out[#out + 1] = colors.paint("cyan", joined)
		elseif tonumber((row.cells[2]:gsub(",", ""))) == best then
			out[#out + 1] = colors.paint("green", joined)
		else
			out[#out + 1] = joined
		end
	end
	return table.concat(out, "\n")
end

-- ── main ────────────────────────────────────────────────────────────────────
local filter
do
	local f = os.getenv("SERVERS")
	if f then
		filter = {}
		for name in f:gmatch("[^,]+") do filter[name:match("^%s*(.-)%s*$")] = true end
	end
end

print(colors.format("{bold}{cyan}superfast benchmark{reset}  wrk -t" .. THREADS .. " -c" .. CONNS .. " -d" .. DUR .. "s"))
if PIN then
	print(colors.format("{dim}servers pinned to CPU {yellow}" .. PIN .. "{reset}"))
else
	print(colors.format("{dim}servers unpinned ({yellow}PIN=2{reset}{dim} for a single-core fight){reset}"))
end
print()

local results = {}
for _, srv in ipairs(servers) do
	if filter and not filter[srv.name] then
		results[srv.name] = { skipped = "excluded" }
	else
		io.write(colors.format("{dim}› benchmarking {cyan}" .. srv.name .. "{reset} ... "))
		io.flush()
		local r = runServer(srv)
		results[srv.name] = r
		if r.skipped then
			print(colors.paint("yellow", "skipped (" .. r.skipped .. ")"))
		else
			print(colors.paint("green", "done"))
		end
	end
end

print()
print(render(results))
print()
print(colors.format("{dim}rss  = resident set size of the whole process tree at end of run"))
print(colors.format("{dim}peak = highest single-process RSS (VmHWM) during the run"))
print(colors.format("{dim}machine note: the powersave governor drifts with thermals; re-run and compare ratios."))

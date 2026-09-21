-- benchmarks: HTTP server comparison suite.
--
--   cd benchmarks && lde run          every server, 3 interleaved trials
--   SERVERS=node,bun lde run          subset
--   DUR=5 TRIALS=5 lde run            longer runs, more trials
--   THREADS=4 CONNS=128 lde run       different load
--   UNPINNED=1 lde run                nothing pinned (old behaviour)
--   SRV_PIN=2 WRK_PIN=3,4 lde run     explicit pinning
--
-- Fair-comparison guards (see docs/ARCHITECTURE.md and README):
--   * server pinned to one core, wrk to others, so they cannot collide
--   * warmup pass plus N interleaved trials, reported as a median and spread
--   * per-server CPU sampled from /proc: cores used, us/req, req/s per core
--   * stale listeners detected and refused, idle neighbours SIGSTOPped
--   * per-core busy time attributed, unexplained busy time warned about

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
local DUR      = tonumber(os.getenv("DUR")) or 5
local TRIALS   = tonumber(os.getenv("TRIALS")) or 3
local WARMUP   = tonumber(os.getenv("WARMUP")) or 3
local THREADS  = tonumber(os.getenv("THREADS")) or 2
local CONNS    = tonumber(os.getenv("CONNS")) or 64
local PIN      = os.getenv("PIN")
local UNPINNED = os.getenv("UNPINNED") == "1"
local NOISE    = os.getenv("NOISE") ~= "0"
local PORT_BASE = tonumber(os.getenv("PORT_BASE")) or 8091
local OPENRESTY_PREFIX = os.getenv("OPENRESTY_PREFIX") or (os.getenv("HOME") .. "/openresty")

-- Fair default: server on its own core, wrk on two others. Both sides are
-- pinned so neither the scheduler nor a stray background process can move
-- them around mid-run.
local SRV_PIN = os.getenv("SRV_PIN") or (UNPINNED and nil or PIN or "6")
local WRK_PIN = os.getenv("WRK_PIN") or (UNPINNED and nil or "1,2")

-- package root (benchmarks/): this file lives at <root>/src/init.lua
local srcPath = debug.getinfo(1, "S").source:sub(2)
local ROOT = (srcPath:match("^(.*[/\\])src[/\\]init%.lua$")) or "./"
local WRK = ROOT .. "target/benchmarks/wrk/wrk"

-- ── small helpers ───────────────────────────────────────────────────────────
local AF_INET, SOCK_STREAM = 2, 1
local SIGTERM, SIGKILL = 15, 9
local SIGCONT, SIGSTOP = 18, 19

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
--- inode) + /proc/<pid>/fd symlinks to map inode -> pid. Column positions are
--- read by index instead of a fixed pattern: kernels add fields to this file
--- over time, and an off-by-one here silently fails to find stale listeners
--- (which then keep serving the port while a fresh server fails to bind).
local function portPids(port)
	local want = string.format(":%04X", port)
	local inodes = {}
	local f = io.open("/proc/net/tcp")
	if f then
		for line in f:lines() do
			local col = {}
			for tok in line:gmatch("%S+") do col[#col + 1] = tok end
			-- sl local rem st tx:rx tr:tm retrnsmt uid timeout inode ...
			if col[4] == "0A" and col[2] and col[2]:sub(-5) == want and col[10] then
				inodes[col[10]] = true
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

local CLK_TCK = tonumber(io.popen("getconf CLK_TCK"):read("*l")) or 100

--- CPU time (utime+stime, in ticks) and thread count of a process tree.
---@return integer ticks
---@return integer threads
local function treeCpu(root)
	local ticks, threads = 0, 0
	for _, pid in ipairs(descendants(root)) do
		local f = io.open("/proc/" .. pid .. "/stat")
		if f then
			local line = f:read("*l")
			f:close()
			local rest = line and line:match("%)%s+(.*)")
			if rest then
				local i, ut, st = 0, 0, 0
				for v in rest:gmatch("%S+") do
					i = i + 1
					if i == 12 then ut = tonumber(v) elseif i == 13 then st = tonumber(v) end
				end
				ticks = ticks + ut + st
			end
		end
		local st = io.open("/proc/" .. pid .. "/status")
		if st then
			for line in st:lines() do
				local n = line:match("^Threads:%s+(%d+)")
				if n then threads = threads + tonumber(n) break end
			end
			st:close()
		end
	end
	return ticks, threads
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

--- Suspend or resume a whole process tree. Used to keep the servers that are
--- not currently under test from running anything at all: even an idle node/bun
--- process has timers and GC threads, and sharing the pinned core with them cost
--- the server under test a measurable ~7%.
---@param root integer
---@param sig integer SIGSTOP or SIGCONT
local function signalTree(root, sig)
	for _, pid in ipairs(descendants(root)) do ffi.C.kill(pid, sig) end
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

--- Spawn a server binary, optionally under taskset when a CPU list is given.
---@param bin string
---@param argv string[]
---@param opts table
---@param cpus string? taskset CPU list
local function spawnServer(bin, argv, opts, cpus)
	if cpus then
		return process.spawn("taskset", { "-c", cpus, bin, unpack(argv) }, opts)
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

-- ── per-core interference check ─────────────────────────────────────────────
--- Busy percentage of every CPU since the last call (from /proc/stat).
local function cpuBusySnapshot()
	local t = {}
	local f = io.open("/proc/stat")
	if not f then return t end
	for line in f:lines() do
		local cpu, vals = line:match("^(cpu%d+)%s+(.+)$")
		if cpu then
			local tot, idle, i = 0, 0, 0
			for v in vals:gmatch("%d+") do
				v = tonumber(v); tot = tot + v; i = i + 1
				if i == 4 or i == 5 then idle = idle + v end
			end
			t[cpu] = { tot = tot, idle = idle }
		end
	end
	f:close()
	return t
end

--- Busy% per cpu id between two snapshots, as a table.
local function cpuBusyBetween(a, b)
	local out = {}
	for cpu, av in pairs(a) do
		local bv = b[cpu]
		if bv then
			local dt = bv.tot - av.tot
			if dt > 0 then out[cpu] = 100 * (dt - (bv.idle - av.idle)) / dt end
		end
	end
	return out
end

--- Number of CPUs in a comma-separated list.
local function countCpus(cpuList)
	local n = 0
	for _ in (cpuList or ""):gmatch("[^,]+") do n = n + 1 end
	return n
end

--- Highest busy% across a comma-separated CPU list.
local function worstBusy(busy, cpuList)
	local worst = 0
	for c in (cpuList or ""):gmatch("[^,]+") do
		local v = busy["cpu" .. c]
		if v and v > worst then worst = v end
	end
	return worst
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
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
			}, SRV_PIN)
		end,
	}
}

-- ── running one server ──────────────────────────────────────────────────────

--- Start a server and wait for its port. Returns the child or a skip reason.
local function bootServer(srv)
	for _, p in ipairs(portPids(srv.port)) do ffi.C.kill(p, SIGKILL) end
	if not srv.check() then return nil, "not installed" end
	local child, err = srv.start(srv.port)
	if not child then return nil, "spawn failed: " .. tostring(err) end
	local ready, exitCode = waitReady(child, srv.port, 120)
	if ready then
		-- Make sure the thing answering on this port is the server we just
		-- started: if a stale instance from an earlier run still owns it, the
		-- numbers below would describe that process instead.
		local owners = portPids(srv.port)
		local mine = {}
		for _, pid in ipairs(descendants(child.pid)) do mine[pid] = true end
		local foreign = {}
		for _, pid in ipairs(owners) do
			if not mine[pid] then foreign[#foreign + 1] = pid end
		end
		if #foreign > 0 then
			killTree(child.pid, nil)
			child:wait()
			for _, pid in ipairs(foreign) do ffi.C.kill(pid, SIGKILL) end
			ffi.C.usleep(300000)
			return nil, "port " .. srv.port .. " was served by pid(s) " .. table.concat(foreign, ",")
				.. " (stale listener killed, re-run)"
		end
	end
	if not ready then
		local _, so, se = child:wait()
		killTree(child.pid, srv.port)
		local detail = (se or so or ""):gsub("[\r\n]+", " "):sub(1, 120)
		return nil, "failed to start" .. (exitCode and (" (exit " .. exitCode .. ")") or "")
			.. (detail ~= "" and (": " .. detail) or "")
	end
	return child, nil
end

--- Run one wrk pass, returning reqs, p50, p99, errors and the wrk process CPU.
---@return table|nil result, string? err
local function wrkPass(port, duration)
	local url = "http://127.0.0.1:" .. port .. "/"
	local argv = { "-t" .. THREADS, "-c" .. CONNS, "-d" .. duration .. "s", "--latency", url }
	local wcmd = WRK
	local wargv = argv
	if WRK_PIN then
		wargv = { "-c", WRK_PIN, WRK, unpack(argv) }
		wcmd = "taskset"
	end
	local child, werr = process.spawn(wcmd, wargv, { stdout = "pipe", stderr = "pipe" })
	if not child then return nil, "wrk spawn failed: " .. tostring(werr) end
	-- wrk's CPU has to be sampled while it is still alive: a finished process
	-- has no /proc entry left to read, which would report 0 and hide the fact
	-- that the load generator — not the server — was the bottleneck.
	local first = treeCpu(child.pid)
	local peak = first
	while child:poll() == nil do
		local t = treeCpu(child.pid)
		if t > peak then peak = t end
		ffi.C.usleep(20000)
	end
	local before, after = first, peak
	local _, out, errout = child:wait()
	local reqs, p50, p99, errors = parseWrk(out or "")
	if not reqs then
		return nil, "wrk failed" .. ((errout or ""):gsub("[\r\n]+", " "):sub(1, 100))
	end
	return {
		reqs = reqs, p50 = p50, p99 = p99, errors = errors,
		wrkCores = (after - before) / CLK_TCK / duration,
	}
end

--- Run `fn` with every other live server suspended.
local function exclusively(live, entry, fn)
	for _, other in ipairs(live) do
		if other ~= entry then signalTree(other.child.pid, SIGSTOP) end
	end
	local ok, a, b = pcall(fn)
	for _, other in ipairs(live) do
		if other ~= entry then signalTree(other.child.pid, SIGCONT) end
	end
	if not ok then error(a) end
	return a, b
end

--- One measured pass: wrk for DUR seconds with the server's CPU accounted.
---@return table|nil trial, string? err
local function measuredPass(srv, child)
	local busyBefore = cpuBusySnapshot()
	local cpu0 = treeCpu(child.pid)
	local r, err = wrkPass(srv.port, DUR)
	local cpu1 = treeCpu(child.pid)
	local busyAfter = cpuBusySnapshot()
	if not r then return nil, err end
	r.cores = (cpu1 - cpu0) / CLK_TCK / DUR
	r.usPerReq = (r.cores * 1e6) / r.reqs
	r.perCore = r.cores > 0 and (r.reqs / r.cores) or 0
	-- Interference = busy time on our own pinned cores that is NOT us. Our own
	-- share is approximated from the CPU we measured for the server and wrk.
	local busy = cpuBusyBetween(busyBefore, busyAfter)
	local ownSrv = math.min(100, countCpus(SRV_PIN) > 0 and (r.cores / countCpus(SRV_PIN)) * 100 or 0)
	local ownWrk = math.min(100, countCpus(WRK_PIN) > 0 and (r.wrkCores / countCpus(WRK_PIN)) * 100 or 0)
	r.noise = math.max(0, math.max(
		worstBusy(busy, SRV_PIN or "") - ownSrv,
		worstBusy(busy, WRK_PIN or "") - ownWrk))
	return r, nil
end

--- Median of a numeric field over the trials.
local function median(trials, field)
	local v = {}
	for _, t in ipairs(trials) do v[#v + 1] = t[field] end
	table.sort(v)
	return v[math.floor(#v / 2) + 1]
end

--- Collapse the trials of one server into a result row.
local function aggregate(trials, child)
	local rss, peak = treeMem(child.pid)
	local out = {
		reqs = median(trials, "reqs"),
		cores = median(trials, "cores"),
		usPerReq = median(trials, "usPerReq"),
		perCore = median(trials, "perCore"),
		p50 = median(trials, "p50"),
		p99 = median(trials, "p99"),
		wrkCores = median(trials, "wrkCores"),
		noise = 0,
		errors = 0,
		best = trials[1].reqs,
		worst = trials[1].reqs,
		trials = {},
		rss = rss, peak = peak,
	}
	for i, t in ipairs(trials) do
		out.trials[i] = t.reqs
		out.errors = out.errors + t.errors
		if t.reqs > out.best then out.best = t.reqs end
		if t.reqs < out.worst then out.worst = t.reqs end
		if t.noise > out.noise then out.noise = t.noise end
	end
	return out
end

-- ── the table ───────────────────────────────────────────────────────────────
local function comma(n)
	local s = tostring(math.floor(n))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse()):gsub("^,", "")
end

local function render(results)
	local headers = { "server", "req/s (median)", "spread", "cores", "us/req", "req/s per core", "p50", "p99", "errors", "rss(MB)" }
	local rows = {}
	local best, bestNorm = 0, 0
	for _, srv in ipairs(servers) do
		local r = results[srv.name]
		if r and r.reqs then
			if r.reqs > best then best = r.reqs end
			if r.perCore > bestNorm then bestNorm = r.perCore end
			rows[#rows + 1] = {
				ok = true,
				cells = {
					srv.name, comma(r.reqs),
					string.format("%.0f-%.0f", r.reqs, r.best),
					string.format("%.2f", r.cores),
					string.format("%.2f", r.usPerReq),
					comma(r.perCore),
					r.p50, r.p99, tostring(r.errors), tostring(r.rss),
				},
			}
		elseif not r or r.skipped ~= "excluded" then
			rows[#rows + 1] = {
				ok = false,
				cells = { srv.name, "--", "--", "--", "--", "--", "--", "--", "--", "--" },
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
	local line = function(cells)
		local parts = {}
		for i, c in ipairs(cells) do parts[i] = pad(i, c) end
		return table.concat(parts, "  ")
	end

	local out = {}
	out[#out + 1] = colors.paint("bold", colors.paint("cyan", line(headers)))
	out[#out + 1] = colors.paint("dim", string.rep("-", 96))
	for _, row in ipairs(rows) do
		local joined = line(row.cells)
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

print(colors.format("{bold}{cyan}superfast benchmark{reset}  wrk -t" .. THREADS .. " -c" .. CONNS
	.. " -d" .. DUR .. "s x" .. TRIALS .. " trials"))
if SRV_PIN or WRK_PIN then
	print(colors.format("{dim}servers pinned to {yellow}" .. tostring(SRV_PIN or "-")
		.. "{reset}{dim}, wrk pinned to {yellow}" .. tostring(WRK_PIN or "-") .. "{reset}"))
else
	print(colors.format("{dim}nothing pinned ({yellow}UNPINNED=1{reset}{dim}) — expect scheduler noise"))
end

local results = {}
local live = {}
for _, srv in ipairs(servers) do
	if filter and not filter[srv.name] then
		results[srv.name] = { skipped = "excluded" }
	else
		io.write(colors.format("{dim}> starting {cyan}" .. srv.name .. "{reset} ... "))
		io.flush()
		local child, skip = bootServer(srv)
		if not child then
			results[srv.name] = { skipped = skip }
			print(colors.paint("yellow", "skipped (" .. skip .. ")"))
		else
			wrkPass(srv.port, WARMUP) -- JIT / connection / page-cache warmup, unmeasured
			live[#live + 1] = { srv = srv, child = child }
			print(colors.paint("green", "up"))
		end
	end
end

-- Interleaved rounds: every server gets trial N before any gets N+1, so
-- thermal drift and background load land on all of them equally.
local trials = {}
for round = 1, TRIALS do
	local order = {}
	for i = 1, #live do order[i] = live[(i + round - 2) % #live + 1] end -- rotate start
	for _, entry in ipairs(order) do
		local srv = entry.srv
		io.write(colors.format("{dim}  round " .. round .. "/" .. TRIALS .. " {cyan}" .. srv.name .. "{reset} ... "))
		io.flush()
		local r, err = exclusively(live, entry, function() return measuredPass(srv, entry.child) end)
		if not r then
			print(colors.paint("yellow", "failed: " .. tostring(err)))
			entry.failed = true
			results[srv.name] = { skipped = err }
		else
			trials[srv.name] = trials[srv.name] or {}
			table.insert(trials[srv.name], r)
			print(colors.format("{dim}" .. comma(r.reqs) .. " req/s, " .. string.format("%.2f", r.cores) .. " cores{reset}"))
		end
	end
end

for _, entry in ipairs(live) do
	local srv, child = entry.srv, entry.child
	local t = trials[srv.name]
	if t and #t == TRIALS then
		results[srv.name] = aggregate(t, child)
	end
	killTree(child.pid, srv.port)
	child:wait()
end

print()
print(render(results))
print()
print(colors.format("{dim}req/s    = median of " .. TRIALS .. " interleaved trials (spread = worst-best)"))
print(colors.format("{dim}cores    = CPU cores the server process tree actually consumed (utime+stime)"))
print(colors.format("{dim}us/req   = CPU microseconds per request, all cores included"))
print(colors.format("{dim}per core = req/s divided by cores used — the machine-noise-proof score"))
print(colors.format("{dim}rss      = resident set size of the whole process tree at end of run"))

-- interference report: if a pinned core was busy with something else, the
-- numbers above are optimistic for whoever held it
local noisy = {}
for name, r in pairs(results) do
	if r.noise and NOISE and r.noise > 40 then noisy[#noisy + 1] = name .. " (" .. string.format("%.0f%%", r.noise) .. ")" end
end
if #noisy > 0 then
	print(colors.paint("yellow", "warning") .. colors.paint("dim",
		": pinned cores saw busy time that was neither the server nor wrk (background load or"
		.. " interrupt processing) during " .. table.concat(noisy, ", ") .. " - close background apps for tighter numbers"))
end

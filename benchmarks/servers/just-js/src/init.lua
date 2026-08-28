-- Runs the just-js http/mini.js bench server (build.lua built the runtime).
-- The benchmarks package spawns this with `lde run`; PORT env overrides.
local process = require("process")

local srcPath = debug.getinfo(1, "S").source:sub(2)
local root = (srcPath:match("^(.*[/\\])src[/\\]init%.lua$")) or "./"
local out = root .. "target/just-js"
local justBin = out .. "/just"
local justHome = out .. "/just-src"
local port = os.getenv("PORT") or "8099"

-- the http module is loaded with dlopen("http.so"), so its dir must be on
-- LD_LIBRARY_PATH (see build.lua)
local child, err = process.spawn(justBin, { "http/mini.js" }, {
	cwd = root,
	env = {
		PORT = port,
		JUST_HOME = justHome,
		JUST_TARGET = justHome,
		LD_LIBRARY_PATH = justHome .. "/modules/http",
	},
	stdout = "null",
	stderr = "pipe",
})
if not child then error("failed to spawn just: " .. tostring(err)) end

-- block in the foreground; the benchmarks runner tears the tree down
local code = child:wait()
os.exit(code or 1)

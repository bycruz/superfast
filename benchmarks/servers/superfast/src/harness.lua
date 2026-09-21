-- Profiling/JIT-diagnostics harness: runs the bench workload for DUR seconds,
-- then exits naturally so `lde run --jit` / `lde run --profile` can print
-- their end-of-run reports. Uses Server:step(timeoutMs) instead of the
-- blocking run() so the loop can observe the deadline; under load the timeout
-- never expires (completions arrive continuously), so the hot path is
-- identical to the real server.
--
--   PORT=8093 DUR=20 lde run --jit harness.lua
--   PORT=8093 DUR=20 lde run --profile --json=profile.json harness.lua

local superfast = require("superfast")

local port = tonumber(os.getenv("PORT")) or 8093
local dur = tonumber(os.getenv("DUR")) or 15

local server, err = superfast.Server:new({
	port = port,
	handler = function() return 200, nil, "" end,
})
if not server then error(err) end
local ok, got = server:listen()
if not ok then error(tostring(got)) end

-- os.time() is wall-clock; os.clock() is CPU time and the server spends most
-- of its life blocked in the kernel waiting for CQEs.
local deadline = os.time() + dur
while os.time() < deadline do
	server:step(50)
end
server:close()
print("harness done after", dur, "s")

-- Bench server for superfast: empty 200 on every request.
-- Run with: lde run   (the benchmarks package spawns this; PORT env overrides)
--
-- Env knobs (benchmark comparisons only, defaults are the library defaults):
--   PORT      listen port
--   SF_WARMUP=n  pre-serve JIT warmup round trips ("off" disables it)
--   BUFFERS   provided-buffer pool size
local superfast = require("superfast")

local port = tonumber(os.getenv("PORT")) or 8093
local warmupEnv = os.getenv("SF_WARMUP")
local warmup = nil
if warmupEnv == "off" then
	warmup = false
elseif warmupEnv then
	warmup = tonumber(warmupEnv)
end
local buffers = tonumber(os.getenv("BUFFERS"))

-- return multi-values (status, headers, body) so the handler allocates nothing
local handler = function()
	return 200, nil, ""
end

superfast.serve({
	port        = port,
	handler     = handler,
	warmup      = warmup,
	bufferCount = buffers,
})

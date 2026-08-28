-- Bench server for superfast: empty 200 on every request.
-- Run with: lde run   (the benchmarks package spawns this; PORT env overrides)
local superfast = require("superfast")

local port = tonumber(os.getenv("PORT")) or 8093

-- return multi-values (status, headers, body) so the handler allocates nothing
local handler = function()
	return 200, nil, ""
end

superfast.serve({
	port    = port,
	handler = handler,
})

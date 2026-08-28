-- Tiny ANSI color helper for the benchmarks table output.
-- Self-contained (no dependency): colors are just escape sequences, and we
-- honor NO_COLOR / non-TTY output like the lde ansi library does.
local M = {}

local colors = {
	reset  = "\27[0m",
	bold   = "\27[1m",
	dim    = "\27[2m",
	red    = "\27[31m",
	green  = "\27[32m",
	yellow = "\27[33m",
	blue   = "\27[34m",
	magenta= "\27[35m",
	cyan   = "\27[36m",
	white  = "\27[37m",
}

local enabled = true
if os.getenv("NO_COLOR") and os.getenv("NO_COLOR") ~= "0" then
	enabled = false
end
-- disable when stdout is not a TTY (piped output stays clean)
if enabled then
	local ok, isTTY = pcall(function()
		local ffi = require("ffi")
		ffi.cdef "int isatty(int fd);"
		return ffi.C.isatty(1) ~= 0
	end)
	if ok and not isTTY then enabled = false end
end

---@param name string
---@param s string
---@return string
function M.paint(name, s)
	if not enabled then return s end
	return (colors[name] or "") .. s .. colors.reset
end

---@param f string format with {color} placeholders
---@param ... any
---@return string
function M.format(f, ...)
	return M.paint("reset", string.format(f:gsub("{(%w+)}", function(c) return colors[c] or "" end), ...))
end

return M

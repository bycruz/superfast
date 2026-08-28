-- foo: example superfast server — serves some dumb HTML over io_uring.
--
-- Run: lde run   (listens on PORT env var, default 8080)

local superfast = require("superfast")

local port = tonumber(os.getenv("PORT")) or 8080

local HTML = [==[
<!doctype html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<title>superfast</title>
	<style>
		body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #222; }
		h1 { font-size: 2.2rem; margin-bottom: .25rem; }
		code { background: #f4f4f4; padding: .1rem .3rem; border-radius: 4px; }
		.meta { color: #777; }
	</style>
</head>
<body>
	<h1>hello from superfast ⚡</h1>
	<p class="meta">served by LuaJIT + io_uring on <code>%s</code></p>
	<ul>
		<li><a href="/">/</a> — this page</li>
		<li><a href="/hello">/hello</a> — JSON greeting</li>
		<li><a href="/nope">/nope</a> — 404</li>
	</ul>
</body>
</html>
]==]

local function htmlPage()
	return string.format(HTML, os.date("!%Y-%m-%d %H:%M:%S UTC"))
end

superfast.serve({
	port = port,
	handler = function(req)
		if req.path == "/" then
			return 200, { ["Content-Type"] = "text/html" }, htmlPage()
		elseif req.path == "/hello" then
			return 200, { ["Content-Type"] = "application/json" },
				'{"message": "hello from superfast", "path": "' .. req.path .. '"}'
		end
		return 404, { ["Content-Type"] = "text/plain" }, "not found: " .. req.path
	end,
})

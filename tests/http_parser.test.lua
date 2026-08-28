-- HTTP parser tests: streaming feeds, bodies, pipelining, keep-alive rules,
-- and malformed input.

local test = require("lde-test")
local Parser = require("superfast").httpParser

--- Snapshot a request inside the parser callback: the parser pools the req
--- object (it is only valid while the callback runs), so tests copy the fields
--- they want to assert on — exactly like a real handler would.
---@param req httpParser.Request
---@return table
local function snapshot(req)
	return {
		method    = req.method,
		path      = req.path,
		query     = req.query,
		version   = req.version,
		headers   = req.headers, -- materialized table; safe to retain
		keepAlive = req.keepAlive,
		body      = req.body,
	}
end

--- Feed chunks and collect all parser events.
---@param chunks string[]
---@param opts table?
---@return table { headers: table[], bodies: string[], completes: table[] }
---@return boolean, string? ok, err
local function parseChunks(chunks, opts)
	local events = { headers = {}, bodies = {}, completes = {} }
	local p = Parser:new({
		maxHeaderSize = 8192,
		onHeadersComplete = function(req) events.headers[#events.headers + 1] = snapshot(req) end,
		onBody = function(c) events.bodies[#events.bodies + 1] = c end,
		onMessageComplete = function(req) events.completes[#events.completes + 1] = snapshot(req) end,
	})
	for i, chunk in ipairs(chunks) do
		local ok, err = p:feed(chunk)
		if not ok then return events, false, err end
	end
	return events, true, nil
end

test.it("parses a simple GET", function()
	local events, ok = parseChunks({ "GET /index.html?page=2 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: t\r\n\r\n" })
	test.truthy(ok)
	test.equal(1, #events.completes)
	local req = events.completes[1]
	test.equal("GET", req.method)
	test.equal("/index.html", req.path)
	test.equal("page=2", req.query)
	test.equal("1.1", req.version)
	test.equal("example.com", req.headers["host"])
	test.equal("t", req.headers["user-agent"])
	test.equal("", req.body)
	test.truthy(req.keepAlive)
end)

test.it("handles a request split across many small feeds", function()
	local parts = {
		"GET /a", "b/c HTTP/", "1.1\r\nHos", "t: x\r\n", "Accept: */*\r\n\r",
		"\n",
	}
	local events, ok = parseChunks(parts)
	test.truthy(ok)
	test.equal(1, #events.completes)
	test.equal("/ab/c", events.completes[1].path)
	test.equal("x", events.completes[1].headers["host"])
end)

test.it("parses a POST body split across chunks", function()
	local events, ok = parseChunks({
		"POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello",
		" world",
	})
	test.truthy(ok)
	test.equal(1, #events.completes)
	local req = events.completes[1]
	test.equal("POST", req.method)
	test.equal("hello world", req.body)
	test.equal("hello", events.bodies[1])
	test.equal(" world", events.bodies[2])
end)

test.it("parses two pipelined requests from one buffer", function()
	local events, ok = parseChunks({
		"GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n",
	})
	test.truthy(ok)
	test.equal(2, #events.completes)
	test.equal("/a", events.completes[1].path)
	test.equal("/b", events.completes[2].path)
end)

test.it("handles pipelined requests with bodies", function()
	local reqs = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
		.. "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"
	local events, ok = parseChunks({ reqs })
	test.truthy(ok)
	test.equal(2, #events.completes)
	test.equal("abc", events.completes[1].body)
	test.equal("/b", events.completes[2].path)
end)

test.it("Connection: close disables keep-alive on HTTP/1.1", function()
	local events, ok = parseChunks({ "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" })
	test.truthy(ok)
	test.falsy(events.completes[1].keepAlive)
end)

test.it("HTTP/1.0 defaults to close, keep-alive re-enables it", function()
	local a, ok1 = parseChunks({ "GET / HTTP/1.0\r\n\r\n" })
	test.truthy(ok1)
	test.falsy(a.completes[1].keepAlive)

	local b, ok2 = parseChunks({ "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n" })
	test.truthy(ok2)
	test.truthy(b.completes[1].keepAlive)
end)

test.it("rejects a malformed request line", function()
	local events, ok, err = parseChunks({ "NOTHTTP\r\n\r\n" })
	test.falsy(ok)
	test.truthy(err)
end)

test.it("rejects transfer-encoding requests", function()
	local events, ok, err = parseChunks({ "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" })
	test.falsy(ok)
	test.includes(err, "transfer-encoding")
end)

test.it("enforces the header size limit", function()
	local big = string.rep("A", 9000)
	local events, ok, err = parseChunks({ "GET / HTTP/1.1\r\nX-Big: " .. big .. "\r\n\r\n" })
	test.falsy(ok)
	test.includes(err, "too large")
end)

test.it("Content-Length: 0 completes immediately", function()
	local events, ok = parseChunks({ "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n" })
	test.truthy(ok)
	test.equal(1, #events.completes)
	test.equal("", events.completes[1].body)
end)

test.it("a request ending exactly at the buffer boundary", function()
	local events, ok = parseChunks({ "GET / HTTP/1.1\r\nHost: x\r\n\r\n" })
	test.truthy(ok)
	test.equal(1, #events.completes)
end)

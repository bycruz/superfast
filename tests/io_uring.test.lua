-- Low-level io_uring binding tests: op round-trips, timeouts, socketpair
-- data movement, and provided-buffer recv.

local test = require("lde-test")
local ffi = require("ffi")
local uring = require("superfast").uring

ffi.cdef "int socketpair(int domain, int type, int protocol, int sv[2]);"

local AF_UNIX = 1
local SOCK_STREAM = 1

test.it("reports a liburing version", function()
	local major = tonumber(uring.Ring.version():match("^(%d+)"))
	test.truthy(major)
	test.greaterEqual(major, 2)
end)

test.it("round-trips a nop op with 64-bit user data", function()
	local ring = uring.Ring.new(64)
	local sqe = ring:getSqe()
	test.truthy(sqe)
	ring:prepNop(sqe)
	ring:sqeSetData(sqe, 12345)
	ring:submit()
	local cqe = ring:waitCqe()
	test.truthy(cqe)
	test.equal(0, ring:cqeRes(cqe))
	test.equal(12345, ring:cqeData(cqe))
	ring:cqeSeen(cqe)
end)

test.it("peekCqe returns nil when nothing is ready", function()
	local ring = uring.Ring.new(64)
	test.falsy(ring:peekCqe())
end)

test.it("a timeout op completes with -ETIME", function()
	local ring = uring.Ring.new(64)
	local sqe = ring:getSqe()
	ring:prepTimeout(sqe, 0.01, 0, 0)
	ring:submit()
	local cqe = ring:waitCqe()
	test.truthy(cqe)
	test.equal(-62, ring:cqeRes(cqe)) -- -ETIME
	ring:cqeSeen(cqe)
end)

test.it("moves data between socketpair ends with prepRecv/prepSend", function()
	local sv = ffi.new("int[2]")
	test.equal(0, ffi.C.socketpair(AF_UNIX, SOCK_STREAM, 0, sv))

	local ring = uring.Ring.new(64)
	local recvBuf = ffi.new("char[64]")

	local sqe = ring:getSqe()
	ring:prepRecv(sqe, sv[0], recvBuf, 64, 0)
	ring:sqeSetData(sqe, 7)
	local sqe2 = ring:getSqe()
	ring:prepSend(sqe2, sv[1], ffi.cast("const char *", "hello uring"), 11, 0)
	ring:sqeSetData(sqe2, 8)
	ring:submit()

	local cqe = ring:waitCqe()
	test.equal(11, ring:cqeRes(cqe)) -- the send landed
	ring:cqeSeen(cqe)

	cqe = ring:waitCqe()
	test.equal(11, ring:cqeRes(cqe))
	test.equal(7, ring:cqeData(cqe))
	ring:cqeSeen(cqe)
	test.equal("hello uring", ffi.string(recvBuf, 11))

	ffi.C.close(sv[0])
	ffi.C.close(sv[1])
end)

test.it("recv with provided buffers selects a buffer id", function()
	local sv = ffi.new("int[2]")
	test.equal(0, ffi.C.socketpair(AF_UNIX, SOCK_STREAM, 0, sv))

	local ring = uring.Ring.new(128)
	local PROVIDE = 9007199254740991

	local b0 = ffi.new("char[64]")
	local b1 = ffi.new("char[64]")
	local sqe = ring:getSqe()
	ring:prepProvideBuffers(sqe, b0, 64, 1, 0, 0)
	ring:sqeSetData(sqe, PROVIDE)
	local sqe2 = ring:getSqe()
	ring:prepProvideBuffers(sqe2, b1, 64, 1, 0, 1)
	ring:sqeSetData(sqe2, PROVIDE)
	ring:submit()

	local provided = 0
	while provided < 2 do
		local cqe = ring:waitCqe()
		test.greaterEqual(0, ring:cqeRes(cqe)) -- 0 = success on this kernel
		ring:cqeSeen(cqe)
		provided = provided + 1
	end

	-- recv with IOSQE_BUFFER_SELECT: the kernel picks b0 or b1
	local sqe3 = ring:getSqe()
	ring:prepRecv(sqe3, sv[0], nil, 0, 0)
	ring:sqeSetFlags(sqe3, uring.SqeFlag.BUFFER_SELECT)
	ring:sqeSetBufGroup(sqe3, 0)
	ring:sqeSetData(sqe3, 99)
	local sqe4 = ring:getSqe()
	ring:prepSend(sqe4, sv[1], ffi.cast("const char *", "zzz"), 3, 0)
	ring:sqeSetData(sqe4, 100)
	ring:submit()

	local cqe = ring:waitCqe()
	test.equal(3, ring:cqeRes(cqe))
	ring:cqeSeen(cqe)

	cqe = ring:waitCqe()
	test.equal(3, ring:cqeRes(cqe))
	test.equal(99, ring:cqeData(cqe))
	test.truthy(ring:cqeHasBuffer(cqe))
	local bid = ring:cqeBid(cqe)
	test.truthy(bid == 0 or bid == 1)
	local buf = bid == 0 and b0 or b1
	test.equal("zzz", ffi.string(buf, 3))
	ring:cqeSeen(cqe)

	ffi.C.close(sv[0])
	ffi.C.close(sv[1])
end)

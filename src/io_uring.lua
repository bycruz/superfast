-- io_uring bindings for LuaJIT, backed by the vendored liburing-ffi export.
--
-- Every function is a real C symbol in liburing.so (liburing's `ffi.c`
-- compiles all of its inline helpers into an FFI-consumable shared object),
-- so this module never touches io_uring struct layouts — rings, SQEs and
-- CQEs are all opaque.
--
-- The Lua API is camelCase; the raw liburing symbols are exposed on the
-- returned module as `lib` for advanced use.

local ffi = require("ffi")

ffi.cdef [[
  /* Full io_uring layout from liburing 2.9 (x86_64): needed so the ring
     storage can be allocated and finalized. liburing functions handle all
     ring mechanics; these structs are only ever read by liburing itself. */
  typedef struct io_uring_sqe io_uring_sqe;
  typedef struct io_uring_cqe {
    uint64_t user_data;
    int32_t  res;
    uint32_t flags;
  } io_uring_cqe;

  struct io_uring_sq {
    unsigned *khead;
    unsigned *ktail;
    unsigned *kring_mask;
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *kdropped;
    unsigned *array;
    io_uring_sqe *sqes;
    unsigned sqe_head;
    unsigned sqe_tail;
    size_t ring_sz;
    void *ring_ptr;
    unsigned ring_mask;
    unsigned ring_entries;
    unsigned pad[2];
  };

  struct io_uring_cq {
    unsigned *khead;
    unsigned *ktail;
    unsigned *kring_mask;
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *koverflow;
    io_uring_cqe *cqes;
    size_t ring_sz;
    void *ring_ptr;
    unsigned ring_mask;
    unsigned ring_entries;
    unsigned pad[2];
  };

  struct io_uring {
    struct io_uring_sq sq;
    struct io_uring_cq cq;
    unsigned flags;
    int ring_fd;
    unsigned features;
    int enter_ring_fd;
    uint8_t int_flags;
    uint8_t pad[3];
    unsigned pad2;
  };
  typedef struct io_uring io_uring;

  typedef struct __kernel_timespec {
    int64_t tv_sec;
    int64_t tv_nsec;
  } __kernel_timespec;

  /* shared libc / socket types (base module: other modules reuse these) */
  typedef unsigned int socklen_t;
  typedef unsigned int useconds_t;
  struct sockaddr { unsigned short sa_family; char sa_data[14]; };
  typedef struct sockaddr sockaddr;
  typedef struct sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int   sin_addr;
    char sin_zero[8];
  } sockaddr_in;

  /* libc socket API used by the server and the test suite */
  int socket(int domain, int type, int protocol);
  int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int listen(int sockfd, int backlog);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int close(int fd);
  int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
  int getsockname(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
  int inet_pton(int af, const char *src, void *dst);
  unsigned short htons(unsigned short hostshort);
  unsigned short ntohs(unsigned short netshort);
  int usleep(useconds_t usec);
  int fcntl(int fd, int cmd, int arg);

  int io_uring_queue_init(unsigned entries, io_uring *ring, unsigned flags);
  void io_uring_queue_exit(io_uring *ring);

  io_uring_sqe *io_uring_get_sqe(io_uring *ring);
  int io_uring_submit(io_uring *ring);
  int io_uring_submit_and_wait(io_uring *ring, unsigned wait_nr);
  int io_uring_submit_and_get_events(io_uring *ring);

  int io_uring_wait_cqe(io_uring *ring, io_uring_cqe **cqe_ptr);
  int io_uring_wait_cqe_timeout(io_uring *ring, io_uring_cqe **cqe_ptr,
                                const __kernel_timespec *ts);
  int io_uring_peek_cqe(io_uring *ring, io_uring_cqe **cqe_ptr);
  void io_uring_cqe_seen(io_uring *ring, io_uring_cqe *cqe);
  int io_uring_cq_ready(io_uring *ring);
  int io_uring_sq_ready(io_uring *ring);

  void io_uring_sqe_set_data(io_uring_sqe *sqe, void *data);
  void io_uring_sqe_set_data64(io_uring_sqe *sqe, uint64_t data);
  void *io_uring_cqe_get_data(io_uring_cqe *cqe);
  uint64_t io_uring_cqe_get_data64(io_uring_cqe *cqe);
  void io_uring_sqe_set_flags(io_uring_sqe *sqe, unsigned flags);
  void io_uring_sqe_set_buf_group(io_uring_sqe *sqe, unsigned buf_group);

  void io_uring_prep_accept(io_uring_sqe *sqe, int fd, struct sockaddr *addr,
                            socklen_t *addrlen, int flags);
  void io_uring_prep_recv(io_uring_sqe *sqe, int fd, void *buf, size_t len, int flags);
  void io_uring_prep_send(io_uring_sqe *sqe, int fd, const void *buf, size_t len, int flags);
  void io_uring_prep_close(io_uring_sqe *sqe, int fd);
  void io_uring_prep_shutdown(io_uring_sqe *sqe, int fd, int how);
  void io_uring_prep_provide_buffers(io_uring_sqe *sqe, void *addr, size_t len,
                                     unsigned nr, int buf_group, unsigned bid);
  void io_uring_prep_timeout(io_uring_sqe *sqe, const __kernel_timespec *ts,
                             unsigned count, unsigned flags);
  void io_uring_prep_nop(io_uring_sqe *sqe);
  void io_uring_prep_cancel(io_uring_sqe *sqe, void *user_data, int flags);
  void io_uring_prep_cancel64(io_uring_sqe *sqe, uint64_t user_data, int flags);
  void io_uring_prep_async_cancel(io_uring_sqe *sqe, void *user_data, int flags);

  int io_uring_register_buffers(io_uring *ring, const struct iovec *iovecs, unsigned nr_iovecs);
  int io_uring_unregister_buffers(io_uring *ring);
  int io_uring_register_eventfd(io_uring *ring, int fd);
  int io_uring_register_eventfd_async(io_uring *ring, int fd);
  int io_uring_register_ring_fd(io_uring *ring);
  int io_uring_unregister_ring_fd(io_uring *ring);

  int io_uring_major_version(void);
  int io_uring_minor_version(void);

  char *strerror(int errnum);
]]

local lib = ffi.load(debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "liburing.so")

-- ── constants ───────────────────────────────────────────────────────────────

--- io_uring_setup flags.
local SetupFlag = {
	IOPOLL          = 1,
	SQPOLL          = 2,
	SQ_AFF          = 4,
	CQSIZE          = 8,
	CLAMP           = 16,
	ATTACH_WQ       = 32,
	R_DISABLED      = 64,
	SUBMIT_ALL      = 128,
	COOP_TASKRUN    = 256,
	TASKRUN_FLAG    = 512,
	SQE128          = 1024,
	CQE32           = 2048,
	SINGLE_ISSUER   = 4096,
	DEFER_TASKRUN   = 8192,
}

--- Per-SQE flags (IOSQE_*).
local SqeFlag = {
	FIXED_FILE      = 1,
	IO_DRAIN        = 2,
	IO_LINK         = 4,
	IO_HARDLINK     = 8,
	ASYNC           = 16,
	BUFFER_SELECT   = 32,
	CQE_SKIP_SUCCESS = 64,
}

--- IORING_CQE_F_* completion flags.
local CqeFlag = {
	BUFFER = 1,      -- cqe->flags carries a buffer id in the upper 16 bits
	MORE   = 2,
}

local SHUT_RD = 0
local SHUT_WR = 1
local SHUT_RDWR = 2

-- ── Ring ────────────────────────────────────────────────────────────────────

local ring_t = ffi.typeof("io_uring[1]")

---@class uring.Ring
---@field ring io_uring[1]
---@field entries integer
---@field flags integer
local Ring = {}
Ring.__index = Ring

local errnoString = function(ret)
	if ret >= 0 then return nil end
	return ffi.string(ffi.C.strerror(-ret))
end

--- Feature-probe: try progressively fewer optimizations until the kernel
--- accepts the setup. Returns the io_uring storage and the flags used.
---@param entries integer
---@param aggressive boolean
---@return io_uring[1], integer|nil, string?
local function initRing(entries, aggressive)
	local ring = ring_t()
	local flags = 0
	if aggressive then
		flags = SetupFlag.DEFER_TASKRUN | SetupFlag.SINGLE_ISSUER | SetupFlag.COOP_TASKRUN
	end

	while true do
		local ret = lib.io_uring_queue_init(entries, ring, flags)
		if ret == 0 then return ring, flags end
		if flags == SetupFlag.DEFER_TASKRUN | SetupFlag.SINGLE_ISSUER | SetupFlag.COOP_TASKRUN then
			flags = SetupFlag.SINGLE_ISSUER | SetupFlag.COOP_TASKRUN
		elseif flags == SetupFlag.SINGLE_ISSUER | SetupFlag.COOP_TASKRUN then
			flags = SetupFlag.COOP_TASKRUN
		elseif flags == SetupFlag.COOP_TASKRUN then
			flags = 0
		else
			return nil, 0, errnoString(ret) or ("io_uring_queue_init failed (" .. tostring(ret) .. ")")
		end
	end
end

--- Create a new io_uring instance.
---@param entries integer? submission queue depth (default 1024)
---@param opts table? { aggressive = boolean? } — aggressive enables
---        IORING_SETUP_DEFER_TASKRUN|SINGLE_ISSUER|COOP_TASKRUN when the
---        kernel supports them (probed automatically).
---@return uring.Ring|nil, string?
function Ring.new(entries, opts)
	entries = entries or 1024
	opts = opts or {}
	local ring, flags = initRing(entries, opts.aggressive ~= false)

	-- pooled scratch cdata: waitCqe/waitCqeTimeout run once per event-loop
	-- iteration, so allocating the out-slot + timespec per call is pure churn
	local cqeOut = ffi.new("io_uring_cqe *[1]")
	local ts = ffi.new("__kernel_timespec")

	return setmetatable({
		ring = ring, entries = entries, flags = flags or 0,
		cqeOut = cqeOut, ts = ts,
	}, Ring)
end

--- Convenience alias: uring.new(entries, opts).
local function new(entries, opts)
	return Ring.new(entries, opts)
end

---@return string "major.minor"
function Ring.version()
	return lib.io_uring_major_version() .. "." .. lib.io_uring_minor_version()
end

--- Fetch a submission queue entry, or nil if the SQ is full.
---@return io_uring_sqe|nil
function Ring:getSqe()
	return lib.io_uring_get_sqe(self.ring)
end

--- Attach 64-bit user data to an SQE (the value surfaced on its CQE).
---@param sqe io_uring_sqe
---@param data integer
function Ring:sqeSetData(sqe, data)
	lib.io_uring_sqe_set_data64(sqe, data)
end

--- Attach opaque pointer user data to an SQE.
---@param sqe io_uring_sqe
---@param data void*
function Ring:sqeSetPtr(sqe, data)
	lib.io_uring_sqe_set_data(sqe, data)
end

---@param sqe io_uring_sqe
---@param flags integer IOSQE_* bits
function Ring:sqeSetFlags(sqe, flags)
	lib.io_uring_sqe_set_flags(sqe, flags)
end

---@param sqe io_uring_sqe
---@param group integer buffer group id for IOSQE_BUFFER_SELECT
function Ring:sqeSetBufGroup(sqe, group)
	lib.io_uring_sqe_set_buf_group(sqe, group)
end

-- ── prep helpers ────────────────────────────────────────────────────────────

---@param sqe io_uring_sqe
---@param fd integer listening socket
---@param flags integer? accept flags (0)
function Ring:prepAccept(sqe, fd, flags)
	lib.io_uring_prep_accept(sqe, fd, nil, nil, flags or 0)
end

---@param sqe io_uring_sqe
---@param fd integer
---@param buf void*|nil buffer (ignored when IOSQE_BUFFER_SELECT is set)
---@param len integer|nil
---@param flags integer? MSG_* flags
function Ring:prepRecv(sqe, fd, buf, len, flags)
	lib.io_uring_prep_recv(sqe, fd, buf, len or 0, flags or 0)
end

---@param sqe io_uring_sqe
---@param fd integer
---@param buf void*
---@param len integer
---@param flags integer? MSG_* flags
function Ring:prepSend(sqe, fd, buf, len, flags)
	lib.io_uring_prep_send(sqe, fd, buf, len, flags or 0)
end

---@param sqe io_uring_sqe
---@param fd integer
function Ring:prepClose(sqe, fd)
	lib.io_uring_prep_close(sqe, fd)
end

---@param sqe io_uring_sqe
---@param fd integer
---@param how integer SHUT_RD / SHUT_WR / SHUT_RDWR
function Ring:prepShutdown(sqe, fd, how)
	lib.io_uring_prep_shutdown(sqe, fd, how)
end

--- Add a buffer back into the provided-buffer pool.
---@param sqe io_uring_sqe
---@param addr void*
---@param len integer buffer size
---@param count integer buffers to add
---@param group integer buffer group id
---@param bid integer first buffer id
function Ring:prepProvideBuffers(sqe, addr, len, count, group, bid)
	lib.io_uring_prep_provide_buffers(sqe, addr, len, count, group, bid)
end

---@param sqe io_uring_sqe
---@param seconds number
---@param count integer? number of completions to wait for
---@param flags integer?
function Ring:prepTimeout(sqe, seconds, count, flags)
	local ts = ffi.new("__kernel_timespec")
	ts.tv_sec = math.floor(seconds)
	ts.tv_nsec = math.floor((seconds % 1) * 1e9)
	lib.io_uring_prep_timeout(sqe, ts, count or 0, flags or 0)
end

---@param sqe io_uring_sqe
function Ring:prepNop(sqe)
	lib.io_uring_prep_nop(sqe)
end

--- Cancel the request carrying the given 64-bit user data.
---@param sqe io_uring_sqe
---@param userData integer
function Ring:prepCancel64(sqe, userData)
	lib.io_uring_prep_cancel64(sqe, userData, 0)
end

-- ── submission / completion ─────────────────────────────────────────────────

--- Submit all queued SQEs. Returns number submitted.
---@return integer
function Ring:submit()
	return lib.io_uring_submit(self.ring)
end

--- Submit and wait for `n` completions.
---@param n integer
---@return integer
function Ring:submitAndWait(n)
	return lib.io_uring_submit_and_wait(self.ring, n)
end

--- Block until the next completion arrives.
---@return io_uring_cqe|nil, string? error
function Ring:waitCqe()
	local ret = lib.io_uring_wait_cqe(self.ring, self.cqeOut)
	if ret ~= 0 then return nil, errnoString(ret) end
	return self.cqeOut[0], nil
end

--- Block until the next completion, or `ms` milliseconds elapse.
---@param ms number
---@return io_uring_cqe|nil, string? (nil when timed out)
function Ring:waitCqeTimeout(ms)
	local ts = self.ts
	ts.tv_sec = math.floor(ms / 1000)
	ts.tv_nsec = math.floor((ms % 1000) * 1e6)
	local ret = lib.io_uring_wait_cqe_timeout(self.ring, self.cqeOut, ts)
	if ret ~= 0 then return nil, errnoString(ret) end
	return self.cqeOut[0], nil
end

--- Non-blocking: return the next completion if one is ready.
---
--- Reads the CQ ring directly: liburing's io_uring_peek_cqe() falls back to
--- a *blocking* wait when the queue is empty, which would stall the event
--- loop. The CQ head is advanced by cqeSeen(); tail is written by the kernel.
---@return io_uring_cqe|nil
function Ring:peekCqe()
	local cq = self.ring[0].cq
	local head = cq.khead[0]
	local tail = cq.ktail[0]
	if head == tail then return nil end
	return cq.cqes[bit.band(head, cq.ring_mask)]
end

---@param cqe io_uring_cqe
function Ring:cqeSeen(cqe)
	lib.io_uring_cqe_seen(self.ring, cqe)
end

---@param cqe io_uring_cqe
---@return integer completion result (bytes, fd, or -errno)
function Ring:cqeRes(cqe)
	return tonumber(cqe.res)
end

---@param cqe io_uring_cqe
---@return integer raw completion flags (IORING_CQE_F_* plus buffer id bits)
function Ring:cqeFlags(cqe)
	return tonumber(cqe.flags)
end

---@param cqe io_uring_cqe
---@return integer the 64-bit user data attached at submission
function Ring:cqeData(cqe)
	return tonumber(lib.io_uring_cqe_get_data64(cqe))
end

--- Buffer id selected by the kernel for a recv submitted with IOSQE_BUFFER_SELECT.
---@param cqe io_uring_cqe
---@return integer
function Ring:cqeBid(cqe)
	return math.floor(tonumber(cqe.flags) / 65536)
end

---@param cqe io_uring_cqe
---@return boolean whether a buffer id is present in the completion flags
function Ring:cqeHasBuffer(cqe)
	return bit.band(tonumber(cqe.flags), CqeFlag.BUFFER) ~= 0
end

--- Number of completions ready to be consumed.
---@return integer
function Ring:cqReady()
	return lib.io_uring_cq_ready(self.ring)
end

--- Number of SQEs currently queued but not yet submitted.
---@return integer
function Ring:sqReady()
	return lib.io_uring_sq_ready(self.ring)
end

-- ── registration ────────────────────────────────────────────────────────────

--- Pin a set of buffers (iovec array) for IORING_OP_*_FIXED operations.
---@param iovecs cdata struct iovec[]
---@return boolean, string?
function Ring:registerBuffers(iovecs)
	local ret = lib.io_uring_register_buffers(self.ring, iovecs, #iovecs)
	if ret ~= 0 then return false, errnoString(ret) end
	return true, nil
end

---@return boolean, string?
function Ring:unregisterBuffers()
	local ret = lib.io_uring_unregister_buffers(self.ring)
	if ret ~= 0 then return false, errnoString(ret) end
	return true, nil
end

---@param fd integer eventfd
---@param async boolean?
---@return boolean, string?
function Ring:registerEventFd(fd, async)
	local ret = async and lib.io_uring_register_eventfd_async(self.ring, fd)
		or lib.io_uring_register_eventfd(self.ring, fd)
	if ret ~= 0 then return false, errnoString(ret) end
	return true, nil
end

-- ── exports ─────────────────────────────────────────────────────────────────

local uring = {}

uring.Ring        = Ring
uring.new         = new
uring.lib         = lib
uring.SetupFlag   = SetupFlag
uring.SqeFlag     = SqeFlag
uring.CqeFlag     = CqeFlag
uring.SHUT_RD     = SHUT_RD
uring.SHUT_WR     = SHUT_WR
uring.SHUT_RDWR   = SHUT_RDWR

return uring

-- io_uring bindings for LuaJIT, backed by the vendored liburing-ffi export:
-- every helper is a real C symbol, so ring/SQE/CQE layouts stay opaque.
-- The Lua API is camelCase; raw symbols are exposed as `lib`.

local ffi = require("ffi")
local bit = require("bit")

-- The ffi library's types are only resolved per file, so a workspace-wide
-- check reports `ffi.cdata*` parents as unknown; disable that one diagnostic
-- for the declaration block below.
---@diagnostic disable: undefined-doc-class

-- ── FFI types ───────────────────────────────────────────────────────────────
-- The language server cannot see the types declared in the ffi.cdef above, so
-- the ones used in annotations are declared here as classes extending
-- `ffi.cdata*`; their fields mirror the C structs. `superfast.raw.Ptr` is the
-- untyped escape hatch for opaque handles.

---@class superfast.raw.Ptr: ffi.cdata*
--- byte buffer (char[] / void* / char*)
---@class superfast.raw.Buffer: ffi.cdata*, superfast.raw.Ptr
--- submission queue entry (io_uring_sqe)
---@class superfast.raw.Sqe: ffi.cdata*
--- completion queue entry (io_uring_cqe)
---@class superfast.raw.Cqe: ffi.cdata*
---@field user_data integer
---@field res integer
---@field flags integer
--- kernel timespec (__kernel_timespec)
---@class superfast.raw.Timespec: ffi.cdata*
---@field tv_sec integer
---@field tv_nsec integer
--- io_uring ring storage
---@class superfast.raw.IoUring: ffi.cdata*
--- parser_state: the parser's per-message hot state
---@class superfast.raw.ParserState: ffi.cdata*
---@field fbufLen integer
---@field state integer
---@field msgConsumed integer
---@field msgBodyOff integer
---@field msgBodyLen integer
---@field msgMethodOff integer
---@field msgMethodLen integer
---@field msgPathOff integer
---@field msgPathLen integer
---@field msgQueryOff integer
---@field msgQueryLen integer
---@field msgHeadLen integer
---@field msgContentLength integer
---@field msgKeepAlive integer
---@field bodyTotal integer
---@field reqDirty integer
--- conn_state: the server's per-connection state
---@class superfast.raw.ConnState: ffi.cdata*
---@field fd integer
---@field inflight integer
---@field phase integer
---@field outLen integer
---@field curOff integer
---@field curOutLen integer
---@field closeAfterSend integer
---@field continueHandshake integer

--- C int results: always present, never nil.
---@param v any
---@return integer
local function toint(v)
	return tonumber(v) or 0
end

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
  typedef long ssize_t;
  ssize_t send(int sockfd, const void *buf, size_t len, int flags);
  ssize_t recv(int sockfd, void *buf, size_t len, int flags);

  int io_uring_queue_init(unsigned entries, io_uring *ring, unsigned flags);
  void io_uring_queue_exit(io_uring *ring);

  io_uring_sqe *io_uring_get_sqe(io_uring *ring);
  int io_uring_submit(io_uring *ring);
  int io_uring_submit_and_wait(io_uring *ring, unsigned wait_nr);
  int io_uring_submit_and_get_events(io_uring *ring);

  int io_uring_wait_cqe(io_uring *ring, io_uring_cqe **cqe_ptr);
  int io_uring_wait_cqe_timeout(io_uring *ring, io_uring_cqe **cqe_ptr,
                                const __kernel_timespec *ts);
  int io_uring_submit_and_wait_timeout(io_uring *ring, io_uring_cqe **cqe_ptr,
                                       unsigned wait_nr, __kernel_timespec *ts,
                                       void *sigmask);
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

  /* libc memory API used for the SQE stride fix-up */
  void *mmap(void *addr, size_t length, int prot, int flags, int fd, int64_t offset);
  void *memset(void *s, int c, size_t n);

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

--- Options accepted by `uring.Ring.new`.
---@class superfast.uring.RingOptions
---@field aggressive boolean? enable DEFER_TASKRUN|SINGLE_ISSUER|COOP_TASKRUN when supported (default true)

---@class superfast.uring.Ring
---@field ring superfast.raw.IoUring
---@field entries integer
---@field flags integer
---@field features integer
---@field cqeOut superfast.raw.Ptr
---@field ts superfast.raw.Timespec
---@field cqHead superfast.raw.Ptr
---@field cqTail superfast.raw.Ptr
---@field cqMask integer
---@field cqes superfast.raw.Ptr
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
---@return superfast.raw.IoUring?, integer?, string?
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
---@param opts superfast.uring.RingOptions? ring options
---@return superfast.uring.Ring?, string?
function Ring.new(entries, opts)
	entries = entries or 1024
	opts = opts or {}
	local ring, flags, err = initRing(entries, opts.aggressive ~= false)
	if not ring then return nil, err end

	-- pooled scratch cdata: waitCqe/waitCqeTimeout run once per event-loop
	-- iteration, so allocating the out-slot + timespec per call is pure churn
	local cqeOut = ffi.new("io_uring_cqe *[1]")
	local ts = ffi.new("__kernel_timespec") --[[@as superfast.raw.Timespec]]

	-- Cache the CQ pointers: the event loop reads the head on every completion.
	local cq = ring[0].cq

	local obj = setmetatable({
		ring = ring, entries = entries, flags = flags or 0,
		cqeOut = cqeOut, ts = ts,
		cqHead = cq.khead,
		cqTail = cq.ktail,
		cqMask = cq.ring_mask,
		cqes = cq.cqes,
		features = tonumber(ring[0].features),
	}, Ring)
	return obj, nil
end

--- Convenience alias: `uring.new(entries, opts)`.
---@param entries integer? submission queue depth (default 1024)
---@param opts superfast.uring.RingOptions?
---@return superfast.uring.Ring?, string?
local function new(entries, opts)
	return Ring.new(entries, opts)
end

---@return string "major.minor"
function Ring.version()
	return lib.io_uring_major_version() .. "." .. lib.io_uring_minor_version()
end

--- Fetch a submission queue entry, or nil if the SQ is full.
--- liburing resets the slot's flags/ioprio/personality/addr3 on the way out,
--- which matters: a slot recycled from a recv would otherwise still carry
--- IOSQE_BUFFER_SELECT, and the next send on it fails with -ENOBUFS.
---@return superfast.raw.Sqe?
function Ring:getSqe()
	return lib.io_uring_get_sqe(self.ring)
end

--- Attach 64-bit user data to an SQE (the value surfaced on its CQE).
---@param sqe superfast.raw.Sqe
---@param data integer
function Ring:sqeSetData(sqe, data)
	lib.io_uring_sqe_set_data64(sqe, data)
end

--- Attach opaque pointer user data to an SQE.
---@param sqe superfast.raw.Sqe
---@param data superfast.raw.Ptr
function Ring:sqeSetPtr(sqe, data)
	lib.io_uring_sqe_set_data(sqe, data)
end

---@param sqe superfast.raw.Sqe
---@param flags integer IOSQE_* bits
function Ring:sqeSetFlags(sqe, flags)
	lib.io_uring_sqe_set_flags(sqe, flags)
end

---@param sqe superfast.raw.Sqe
---@param group integer buffer group id for IOSQE_BUFFER_SELECT
function Ring:sqeSetBufGroup(sqe, group)
	lib.io_uring_sqe_set_buf_group(sqe, group)
end

-- ── prep helpers ────────────────────────────────────────────────────────────

---@param sqe superfast.raw.Sqe
---@param fd integer listening socket
---@param flags integer? accept flags (0)
function Ring:prepAccept(sqe, fd, flags)
	lib.io_uring_prep_accept(sqe, fd, nil, nil, flags or 0)
end

---@param sqe superfast.raw.Sqe
---@param fd integer
---@param buf superfast.raw.Ptr|string|nil buffer (ignored when IOSQE_BUFFER_SELECT is set)
---@param len integer|nil
---@param flags integer? MSG_* flags
function Ring:prepRecv(sqe, fd, buf, len, flags)
	lib.io_uring_prep_recv(sqe, fd, buf, len or 0, flags or 0)
end


---@param sqe superfast.raw.Sqe
---@param fd integer
---@param buf superfast.raw.Ptr|string
---@param len integer
---@param flags integer? MSG_* flags
function Ring:prepSend(sqe, fd, buf, len, flags)
	lib.io_uring_prep_send(sqe, fd, buf, len, flags or 0)
end

---@param sqe superfast.raw.Sqe
---@param fd integer
function Ring:prepClose(sqe, fd)
	lib.io_uring_prep_close(sqe, fd)
end

---@param sqe superfast.raw.Sqe
---@param fd integer
---@param how integer SHUT_RD / SHUT_WR / SHUT_RDWR
function Ring:prepShutdown(sqe, fd, how)
	lib.io_uring_prep_shutdown(sqe, fd, how)
end

--- Add a buffer back into the provided-buffer pool.
---@param sqe superfast.raw.Sqe
---@param addr superfast.raw.Ptr|string
---@param len integer buffer size
---@param count integer buffers to add
---@param group integer buffer group id
---@param bid integer first buffer id
function Ring:prepProvideBuffers(sqe, addr, len, count, group, bid)
	lib.io_uring_prep_provide_buffers(sqe, addr, len, count, group, bid)
end

---@param sqe superfast.raw.Sqe
---@param seconds number
---@param count integer? number of completions to wait for
---@param flags integer?
function Ring:prepTimeout(sqe, seconds, count, flags)
	local ts = ffi.new("__kernel_timespec") --[[@as superfast.raw.Timespec]]
	ts.tv_sec = math.floor(seconds)
	ts.tv_nsec = math.floor((seconds % 1) * 1e9)
	lib.io_uring_prep_timeout(sqe, ts, count or 0, flags or 0)
end

---@param sqe superfast.raw.Sqe
function Ring:prepNop(sqe)
	lib.io_uring_prep_nop(sqe)
end

--- Cancel the request carrying the given 64-bit user data.
---@param sqe superfast.raw.Sqe
---@param userData integer
function Ring:prepCancel64(sqe, userData)
	lib.io_uring_prep_cancel64(sqe, userData, 0)
end

-- ── submission / completion ─────────────────────────────────────────────────

--- Submit all queued SQEs. Returns number submitted.
---@return number
function Ring:submit()
	return toint(lib.io_uring_submit(self.ring))
end

--- Block until the next completion arrives.
---@return superfast.raw.Cqe?, string? error
function Ring:waitCqe()
	local ret = lib.io_uring_wait_cqe(self.ring, self.cqeOut)
	if ret ~= 0 then return nil, errnoString(ret) end
	return self.cqeOut[0], nil
end

--- Submit every queued SQE and block until one completion is available.
--- This is the whole event loop's syscall budget: one `io_uring_enter` per
--- batch instead of a separate submit + wait pair. When completions are
--- already waiting the kernel returns immediately, so it degrades to a plain
--- submit.
---@param n integer? completions to wait for (default 1)
---@return integer
function Ring:submitAndWait(n)
	return toint(lib.io_uring_submit_and_wait(self.ring, n or 1))
end

--- Submit queued SQEs and wait for a completion, giving up after `ms`.
---@param ms number
---@param n integer? completions to wait for (default 1)
---@return boolean ok (false on timeout/error)
---@return string? err
function Ring:submitAndWaitTimeout(ms, n)
	local ts = self.ts
	ts.tv_sec = math.floor(ms / 1000)
	ts.tv_nsec = math.floor((ms % 1000) * 1e6)
	local ret = lib.io_uring_submit_and_wait_timeout(self.ring, self.cqeOut, n or 1, ts, nil)
	if ret < 0 then return false, errnoString(ret) end
	return true, nil
end

--- Number of completions ready to be reaped, without touching the kernel.
--- The CQ head is advanced by cqeSeen() as entries are consumed.
---@return number
function Ring:cqReadyCount()
	return toint(self.cqTail[0] - self.cqHead[0])
end

--- The completion at an absolute CQ ring index (masked here).
--- Beware: cqeSeen() advances the CQ head, so an index derived from a *moving*
--- head skips every other completion. Read the head once per batch (peekCqe
--- does exactly that) or pass an absolute index.
---@param idx integer
---@return superfast.raw.Cqe
function Ring:cqeAt(idx)
	return self.cqes[idx & self.cqMask]
end

--- Block until the next completion, or `ms` milliseconds elapse.
---@param ms number
---@return superfast.raw.Cqe?, string? (nil when timed out)
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
---@return superfast.raw.Cqe?
function Ring:peekCqe()
	local head = self.cqHead[0]
	if head == self.cqTail[0] then return nil end
	return self.cqes[bit.band(head, self.cqMask)]
end

---@param cqe superfast.raw.Cqe
function Ring:cqeSeen(cqe)
	lib.io_uring_cqe_seen(self.ring, cqe)
end

---@param cqe superfast.raw.Cqe
---@return number completion result (bytes, fd, or -errno)
function Ring:cqeRes(cqe)
	return toint(cqe.res)
end

---@param cqe superfast.raw.Cqe
---@return number raw completion flags (IORING_CQE_F_* plus buffer id bits)
function Ring:cqeFlags(cqe)
	return toint(cqe.flags)
end

---@param cqe superfast.raw.Cqe
---@return integer the 64-bit user data attached at submission
function Ring:cqeData(cqe)
	return toint(lib.io_uring_cqe_get_data64(cqe))
end

--- Buffer id selected by the kernel for a recv submitted with IOSQE_BUFFER_SELECT.
---@param cqe superfast.raw.Cqe
---@return integer
function Ring:cqeBid(cqe)
	return bit.rshift(toint(cqe.flags), 16)
end

---@param cqe superfast.raw.Cqe
---@return boolean whether a buffer id is present in the completion flags
function Ring:cqeHasBuffer(cqe)
	return bit.band(toint(cqe.flags), CqeFlag.BUFFER) ~= 0
end

--- Number of completions ready to be consumed.
---@return number
function Ring:cqReady()
	return toint(lib.io_uring_cq_ready(self.ring))
end

--- Number of SQEs currently queued but not yet submitted.
---@return number
function Ring:sqReady()
	return toint(lib.io_uring_sq_ready(self.ring))
end

-- ── registration ────────────────────────────────────────────────────────────

--- Pin a set of buffers (iovec array) for IORING_OP_*_FIXED operations.
---@param iovecs superfast.raw.Ptr
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

--- The bindings module: `Ring` plus the raw liburing table.
---@class superfast.uring
---@field Ring superfast.uring.Ring
---@field new fun(entries: integer?, opts: superfast.uring.RingOptions?): superfast.uring.Ring?, string?
---@field lib table<string, function>
---@field SetupFlag table<string, integer>
---@field SqeFlag table<string, integer>
---@field CqeFlag table<string, integer>
---@field SHUT_RD integer
---@field SHUT_WR integer
---@field SHUT_RDWR integer

---@type superfast.uring
local uring = {
	Ring       = Ring,
	new        = new,
	lib        = lib,
	SetupFlag  = SetupFlag,
	SqeFlag    = SqeFlag,
	CqeFlag    = CqeFlag,
	SHUT_RD    = SHUT_RD,
	SHUT_WR    = SHUT_WR,
	SHUT_RDWR  = SHUT_RDWR,
}

return uring

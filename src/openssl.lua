-- OpenSSL bindings for LuaJIT (system libssl/libcrypto). Sessions use memory
-- BIOs, so TLS never touches a socket: feed()/decrypt() take ciphertext in,
-- encrypt()/drain() produce it out, all driven by the same ring.
-- The Lua API is camelCase; raw symbols stay reachable as `lib`.

local ffi = require("ffi")
local bit = require("bit")

---@class BIO opaque OpenSSL BIO handle
---@class SSL opaque OpenSSL SSL handle
---@class SSL_CTX opaque OpenSSL context handle

ffi.cdef [[
  typedef struct ssl_st SSL;
  typedef struct ssl_ctx_st SSL_CTX;
  typedef struct bio_st BIO;
  typedef struct bio_method_st BIO_METHOD;
  typedef struct ssl_method_st SSL_METHOD;

  const SSL_METHOD *TLS_method(void);
  const SSL_METHOD *TLS_server_method(void);
  const SSL_METHOD *TLS_client_method(void);

  SSL_CTX *SSL_CTX_new(const SSL_METHOD *method);
  void SSL_CTX_free(SSL_CTX *ctx);
  int SSL_CTX_use_certificate_chain_file(SSL_CTX *ctx, const char *file);
  int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
  int SSL_CTX_check_private_key(const SSL_CTX *ctx);
  long SSL_CTX_set_mode(SSL_CTX *ctx, long mode);
  long SSL_CTX_set_options(SSL_CTX *ctx, long options);
  long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);
  int SSL_CTX_set_cipher_list(SSL_CTX *ctx, const char *str);

  SSL *SSL_new(SSL_CTX *ctx);
  void SSL_free(SSL *ssl);
  void SSL_set_bio(SSL *ssl, BIO *rbio, BIO *wbio);
  void SSL_set_accept_state(SSL *ssl);
  void SSL_set_connect_state(SSL *ssl);
  int SSL_do_handshake(SSL *ssl);
  int SSL_is_init_finished(const SSL *ssl);
  int SSL_read(SSL *ssl, void *buf, int num);
  int SSL_write(SSL *ssl, const void *buf, int num);
  int SSL_pending(const SSL *ssl);
  int SSL_get_error(const SSL *ssl, int ret);
  int SSL_shutdown(SSL *ssl);

  BIO *BIO_new(const BIO_METHOD *type);
  const BIO_METHOD *BIO_s_mem(void);
  int BIO_read(BIO *b, void *buf, int len);
  int BIO_write(BIO *b, const void *data, int len);
  long BIO_ctrl_pending(BIO *b);
  long BIO_ctrl(BIO *b, int cmd, long larg, void *parg);

  unsigned long ERR_get_error(void);
  void ERR_error_string_n(unsigned long e, char *buf, size_t len);
  const char *OpenSSL_version(int t);
]]

-- libcrypto must be resident first: libssl's DT_NEEDED libcrypto.so.3 then
-- resolves against the already-loaded copy regardless of the search path.
-- These are the SYSTEM OpenSSL shared libraries — superfast vendors the
-- bindings, not the library.
local function loadSystem(soname)
	local ok, lib = pcall(ffi.load, soname)
	if not ok then
		error("superfast.ssl: system OpenSSL not found (" .. soname .. "): " .. tostring(lib)
			.. " — install openssl or run the HTTP server without TLS", 0)
	end
	return lib
end

local crypto = loadSystem("crypto")
local lib = loadSystem("ssl")

-- ── constants ───────────────────────────────────────────────────────────────

local SSL_ERROR_NONE           = 0
local SSL_ERROR_SSL            = 1
local SSL_ERROR_WANT_READ      = 2
local SSL_ERROR_WANT_WRITE     = 3
local SSL_ERROR_ZERO_RETURN    = 6

local SSL_MODE_ENABLE_PARTIAL_WRITE = 1
local SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 2
local SSL_MODE_AUTO_RETRY            = 4
local SSL_MODE_RELEASE_BUFFERS       = 8

local SSL_OP_NO_COMPRESSION      = 0x00020000
local SSL_OP_NO_SSLv2            = 0x01000000
local SSL_OP_NO_SSLv3            = 0x02000000
local SSL_OP_CIPHER_SERVER_PREFERENCE = 0x00400000
local SSL_OP_NO_TICKET           = 0x00004000
local SSL_OP_NO_TLSv1            = 0x04000000
local SSL_OP_NO_TLSv1_1          = 0x10000000

local TLS1_2_VERSION = 0x0303
local TLS1_3_VERSION = 0x0304

-- SSL_CTRL_* for SSL_CTX_ctrl (set_mode/set_options/set_min_proto_version
-- are header macros in OpenSSL, so go through the ctrl function directly)
local SSL_CTRL_OPTIONS               = 32
local SSL_CTRL_MODE                  = 33
local SSL_CTRL_SET_MIN_PROTO_VERSION = 123
local SSL_CTRL_SET_MAX_PROTO_VERSION = 124

-- ── error strings ───────────────────────────────────────────────────────────

local errBuf = ffi.new("char[256]")

--- Last error from the calling thread's OpenSSL error queue.
---@return string
local function errString()
	local code = lib.ERR_get_error()
	if code == 0 then return "unknown error" end
	lib.ERR_error_string_n(code, errBuf, 256)
	return ffi.string(errBuf)
end

-- ── Context ─────────────────────────────────────────────────────────────────

---@class superfast.ssl.Context
---@field ctx SSL_CTX
local Context = {}
Context.__index = Context

--- Create a client TLS context (no cert/key; used by the test suite to
--- speak TLS to a server without verifying it).
---@return superfast.ssl.Context|nil, string?
function Context.client()
	local ctx = lib.SSL_CTX_new(lib.TLS_client_method())
	if ctx == nil then return nil, "SSL_CTX_new failed" end
	lib.SSL_CTX_ctrl(ctx, SSL_CTRL_OPTIONS, bit.bor(SSL_OP_NO_SSLv2, SSL_OP_NO_SSLv3), nil)
	local obj = setmetatable({ ctx = ctx }, Context)
	return obj, nil
end

--- Create a server TLS context and load the certificate chain + private key.
---@param certFile string PEM certificate chain
---@param keyFile string PEM private key
---@return superfast.ssl.Context|nil, string?
function Context.new(certFile, keyFile)
	local ctx = lib.SSL_CTX_new(lib.TLS_server_method())
	if ctx == nil then return nil, "SSL_CTX_new failed" end

	local ret = lib.SSL_CTX_use_certificate_chain_file(ctx, certFile)
	if ret ~= 1 then
		lib.SSL_CTX_free(ctx)
		return nil, "SSL_CTX_use_certificate_chain_file failed: " .. errString()
	end

	-- SSL_FILETYPE_PEM = 1
	ret = lib.SSL_CTX_use_PrivateKey_file(ctx, keyFile, 1)
	if ret ~= 1 then
		lib.SSL_CTX_free(ctx)
		return nil, "SSL_CTX_use_PrivateKey_file failed: " .. errString()
	end

	if lib.SSL_CTX_check_private_key(ctx) ~= 1 then
		lib.SSL_CTX_free(ctx)
		return nil, "private key does not match certificate"
	end

	-- harden: modern TLS only, no compression, no tickets, server ciphers
	-- harden: modern TLS only, no compression, no tickets, server ciphers
	lib.SSL_CTX_ctrl(ctx, SSL_CTRL_OPTIONS, bit.bor(
		SSL_OP_NO_SSLv2, SSL_OP_NO_SSLv3, SSL_OP_NO_TLSv1, SSL_OP_NO_TLSv1_1,
		SSL_OP_NO_COMPRESSION, SSL_OP_CIPHER_SERVER_PREFERENCE), nil)
	lib.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)
	lib.SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, bit.bor(SSL_MODE_AUTO_RETRY, SSL_MODE_RELEASE_BUFFERS), nil)

	local obj = setmetatable({ ctx = ctx }, Context)
	return obj, nil
end

--- Free the context.
function Context:free()
	if self.ctx then
		lib.SSL_CTX_free(self.ctx)
		self.ctx = nil
	end
end

-- ── Session ─────────────────────────────────────────────────────────────────

local readBuf = ffi.new("char[65536]")
local plainBuf = ffi.new("char[65536]")

---@class superfast.ssl.Session
---@field ssl SSL
---@field rbio BIO incoming encrypted bytes from the peer
---@field wbio BIO outgoing encrypted bytes waiting to be sent
---@field eof boolean
local Session = {}
Session.__index = Session

---@param ctx superfast.ssl.Context
---@param isClient boolean
---@return superfast.ssl.Session
local function newSession(ctx, isClient)
	local ssl = lib.SSL_new(ctx.ctx)
	local rbio = crypto.BIO_new(crypto.BIO_s_mem())
	local wbio = crypto.BIO_new(crypto.BIO_s_mem())
	lib.SSL_set_bio(ssl, rbio, wbio) -- SSL owns both BIOs from here on
	if isClient then
		lib.SSL_set_connect_state(ssl)
	else
		lib.SSL_set_accept_state(ssl)
	end

	return setmetatable({ ssl = ssl, rbio = rbio, wbio = wbio, eof = false }, Session)
end

--- Wrap a fresh SSL object with memory BIOs, in server (accept) mode.
---@param ctx superfast.ssl.Context
---@return superfast.ssl.Session
function Session.new(ctx)
	return newSession(ctx, false)
end

--- Same, but in client (connect) mode.
---@param ctx superfast.ssl.Context
---@return superfast.ssl.Session
function Session.newClient(ctx)
	return newSession(ctx, true)
end

function Session:free()
	if self.ssl then
		lib.SSL_free(self.ssl)
		self.ssl = nil
	end
end

--- Feed encrypted bytes received from the peer into the read BIO.
---@param data string
---@return boolean|nil, string?
function Session:feed(data)
	if data == "" then return true end
	local n = crypto.BIO_write(self.rbio, data, #data)
	if n ~= #data then return nil, "BIO_write failed" end
	return true, nil
end

--- Feed encrypted bytes from a cdata buffer (e.g. a recv buffer) — no copy.
---@param ptr superfast.raw.Buffer char*
---@param len integer
---@return boolean|nil, string?
function Session:feedPtr(ptr, len)
	if len == 0 then return true end
	local n = crypto.BIO_write(self.rbio, ptr, len)
	if n ~= len then return nil, "BIO_write failed" end
	return true, nil
end

--- Pull all encrypted bytes the SSL layer has produced so far (to be sent to
--- the peer), resetting the write BIO.
---@return string
function Session:drain()
	local pending = tonumber(crypto.BIO_ctrl_pending(self.wbio))
	if pending == 0 then return "" end
	local n = crypto.BIO_read(self.wbio, readBuf, pending)
	crypto.BIO_ctrl(self.wbio, 1, 0, nil) -- BIO_CTRL_RESET (BIO_reset is stripped from RHEL/Fedora libcrypto)
	return ffi.string(readBuf, n)
end

--- Drive the handshake. Returns one of:
---   "done", "wantRead" (need more peer bytes), "wantWrite" (drain() has
---   more bytes to send, then call handshake() again), or nil + error.
---@return string|nil, string?
function Session:handshake()
	local ret = lib.SSL_do_handshake(self.ssl)
	if lib.SSL_is_init_finished(self.ssl) ~= 0 then return "done" end
	local err = lib.SSL_get_error(self.ssl, ret)
	if err == SSL_ERROR_WANT_READ then return "wantRead" end
	if err == SSL_ERROR_WANT_WRITE then return "wantWrite" end
	return nil, self:errorString()
end

--- Decrypt as much as possible into a Lua string.
---@return string plaintext
---@return boolean eof peer sent close_notify
function Session:decrypt()
	local out = {}
	while true do
		local ret = lib.SSL_read(self.ssl, plainBuf, 65536)
		if ret > 0 then
			out[#out + 1] = ffi.string(plainBuf, ret)
			if ret < 65536 then break end
		elseif ret == 0 then
			self.eof = true
			break
		else
			local err = lib.SSL_get_error(self.ssl, ret)
			if err == SSL_ERROR_ZERO_RETURN then
				self.eof = true
			end
			break -- WANT_READ / WANT_WRITE / SSL error: nothing more right now
		end
	end
	return table.concat(out), self.eof
end

--- Encrypt a plaintext message; ciphertext is available via drain().
---@param plain string
---@return boolean|nil, string?
function Session:encrypt(plain)
	if plain == "" then return true end
	local ret = lib.SSL_write(self.ssl, plain, #plain)
	if ret ~= #plain then
		return nil, self:errorString()
	end
	return true, nil
end

--- How many encrypted bytes from the peer are still unprocessed.
---@return integer
function Session:pendingEncrypted()
	return tonumber(crypto.BIO_ctrl_pending(self.rbio)) or 0
end

--- Send close_notify; returns the ciphertext to transmit before closing.
---@return string
function Session:shutdown()
	lib.SSL_shutdown(self.ssl)
	return self:drain()
end

---@return string
function Session:errorString()
	return errString()
end

-- ── exports ─────────────────────────────────────────────────────────────────

--- The OpenSSL bindings module.
---@class superfast.ssl
---@field Context superfast.ssl.Context
---@field Session superfast.ssl.Session
---@field lib table<string, function>
---@field version fun(): string
---@field SSL_ERROR_WANT_READ integer
---@field SSL_ERROR_WANT_WRITE integer

---@type superfast.ssl
local ssl = {
	Context              = Context,
	Session              = Session,
	lib                  = lib,
	version              = function() return ffi.string(lib.OpenSSL_version(0)) end,
	SSL_ERROR_WANT_READ  = SSL_ERROR_WANT_READ,
	SSL_ERROR_WANT_WRITE = SSL_ERROR_WANT_WRITE,
}

return ssl

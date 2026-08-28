-- build.lua — vendored native dependency for superfast (Linux only).
--
-- Downloads and builds liburing 2.9 → liburing.so (the liburing-ffi export:
-- every io_uring helper exposed as a real C symbol, so LuaJIT can call it
-- without struct layouts).
--
-- OpenSSL is NOT compiled here: superfast ships vendored FFI bindings that
-- load the system's libssl/libcrypto at runtime (openssl is present on
-- essentially every Linux system).

local build = require("lde-build")

assert(jit.os == "Linux", "superfast is Linux-only for now")

local outDir = build.outDir

local uringTag     = "liburing-2.9"
local uringTarball = uringTag .. ".tar.gz"
local uringUrl     = "https://github.com/axboe/liburing/archive/refs/tags/" .. uringTarball

if not build:exists("liburing.so") then
	build:write(uringTarball, build:fetch(uringUrl))
	build:extract(uringTarball, ".")
	build:move("liburing-" .. uringTag, "liburing")

	-- configure generates config-host.h (version + feature detection); make
	-- produces both liburing.so and the ffi-export liburing-ffi.so.
	build:sh('cd "' .. outDir .. '/liburing" && ./configure')
	build:sh('make -C "' .. outDir .. '/liburing" -j$(nproc) >/dev/null 2>&1 || (echo "liburing build failed:"; make -C "' .. outDir .. '/liburing" 2>&1 | tail -n 30; exit 1)')
	build:sh('ls "' .. outDir .. '/liburing/src/liburing-ffi.so"*')
	build:copy("liburing/src/liburing-ffi.so.2.9", "liburing.so")
end

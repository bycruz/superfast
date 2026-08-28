-- benchmarks/build.lua — builds the wrk load generator into target/wrk/wrk.
--
-- wrk (https://github.com/wg/wrk) is the load generator every benchmark run
-- uses; it has no release tarballs, so we fetch the master source archive and
-- `make` it here (same pattern as superfast's vendored liburing build).

local build = require("lde-build")

assert(jit.os == "Linux", "the benchmarks suite is Linux-only for now")

local wrkDir = build.outDir .. "/wrk"

if not build:exists("wrk/wrk") then
	build:write("wrk.tar.gz", build:fetch("https://github.com/wg/wrk/archive/refs/heads/master.tar.gz"))
	build:extract("wrk.tar.gz", ".")
	build:move("wrk-master", "wrk")
	build:sh('make -C "' .. wrkDir .. '" -j$(nproc) >/dev/null')
end

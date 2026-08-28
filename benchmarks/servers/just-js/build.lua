-- just-js bench server: builds the just-js runtime (v8) into target/just-js/.
--
-- just-js ships no release binaries for current versions, so we fetch the
-- source tarball and run `make runtime` (dynamic link — the static target
-- needs glibc-static/libstdc++-static which many distros don't install).
-- The Makefile itself downloads the prebuilt v8 monolith + headers + modules,
-- so no v8 source build is needed; compile takes a few minutes on first run.
-- The http module (used by http/mini.js) is not part of the core runtime, so
-- it is built as a shared library and loaded via LD_LIBRARY_PATH.

local build = require("lde-build")

assert(jit.os == "Linux", "just-js is Linux-only")

local outDir = build.outDir

if not build:exists("just") then
	build:write("just.tar.gz", build:fetch("https://github.com/just-js/just/archive/current.tar.gz"))
	build:extract("just.tar.gz", ".")
	build:move("just-current", "just-src")
	build:sh('make -C "' .. outDir .. '/just-src" runtime')
	build:sh('make -C "' .. outDir .. '/just-src" MODULE=http module')
	build:copy("just-src/just", "just")
end

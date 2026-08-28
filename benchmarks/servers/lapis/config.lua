-- Lapis configuration for the benchmark.
-- port is overridden with LAPIS_PORT by benchmark.sh; num_workers/code_cache
-- are what matter for perf. package_path/cpath point OpenResty's embedded
-- LuaJIT at the luarocks tree built for it (bench/tools/install-lapis-luajit.sh).
local config = require("lapis.config")

-- nginx strips most env vars in workers, so os.getenv can return nil here;
-- the compiled nginx.conf (interpolated by the lapis CLI) carries the real
-- paths, this file only needs to not crash when loaded at request time.
local prefix = os.getenv("OPENRESTY_PREFIX") or ((os.getenv("HOME") or "") .. "/openresty")
local rocks = prefix .. "/luajit-rocks"
-- luarocks may install C modules under lib/ or lib64/ depending on the distro
-- (os.execute returns 0 in Lua 5.1, true in 5.4 — accept both)
local rock_lib = rocks .. "/lib"
local ok = os.execute("test -d " .. rocks .. "/lib64/lua/5.1")
if ok == 0 or ok == true then
  rock_lib = rocks .. "/lib64"
end

config("development", {
  port = 8095,
  num_workers = 1,
  code_cache = "on",
  package_path = prefix .. "/lualib/?.lua;" .. prefix .. "/lualib/?/init.lua;"
    .. rocks .. "/share/lua/5.1/?.lua;" .. rocks .. "/share/lua/5.1/?/init.lua;;",
  package_cpath = prefix .. "/lualib/?.so;" .. rock_lib .. "/lua/5.1/?.so;;",
})

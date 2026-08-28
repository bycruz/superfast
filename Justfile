set shell := ["bash", "-uc"]

# ─────────────────────────────────────────────────────────────────────────────
# superfast benchmark suite
#
#   just deps   build benchmark tooling (wrk load generator, lapis rock,
#               OpenResty for the lapis server) — first run only
#   just bench  run all five servers and print a comparison table
#   just bench-node / bench-bun / bench-superfast / bench-python / bench-lapis
#
# Tuning (override on the command line, e.g. `just bench DUR=5 PIN=2`):
#   DUR=10      wrk duration in seconds
#   THREADS=2   wrk threads
#   CONNS=64    wrk connections
#   PIN=        CPU to pin every server to (e.g. PIN=2); empty = unpinned.
#               Superfast is single-core by design; node/bun/python use what
#               they get. PIN gives an apples-to-apples single-core fight.
#   OPENRESTY_PREFIX=$HOME/openresty   OpenResty install root (lapis)
#
# Output columns: req/s, latency p50/p99, socket errors, RSS (MB, whole
# process tree at end of run), peak RSS (MB, high-water mark of any one
# process in the tree).
# ─────────────────────────────────────────────────────────────────────────────

DUR := "10"
THREADS := "2"
CONNS := "64"
PIN := ""
OPENRESTY_PREFIX := env("OPENRESTY_PREFIX", "$HOME/openresty")
WRK := "bench/.tools/wrk/wrk"

# Build benchmark tooling (wrk, lapis, OpenResty) if missing.
deps:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -x "{{WRK}}" ]; then
		echo "→ building wrk (load generator) ..."
		mkdir -p bench/.tools/wrk
		rm -rf bench/.tools/wrk-src
		git clone --depth 1 https://github.com/wg/wrk.git bench/.tools/wrk-src >/dev/null 2>&1
		make -C bench/.tools/wrk-src -j"$(nproc)" >/dev/null
		cp bench/.tools/wrk-src/wrk "{{WRK}}"
		chmod +x "{{WRK}}"
	fi
	if ! command -v lapis >/dev/null 2>&1 && [ ! -x "$HOME/.luarocks/bin/lapis" ]; then
		echo "→ installing lapis (luarocks --local) ..."
		luarocks install --local lapis
	fi
	if [ ! -x "{{OPENRESTY_PREFIX}}/nginx/sbin/nginx" ]; then
		echo "→ building OpenResty into {{OPENRESTY_PREFIX}} (a few minutes, first run only) ..."
		bench/tools/install-openresty.sh "{{OPENRESTY_PREFIX}}"
	fi
	if [ ! -x "{{OPENRESTY_PREFIX}}/luajit-rocks/bin/lapis" ]; then
		echo "→ installing lapis rock for OpenResty's LuaJIT ..."
		bench/tools/install-lapis-luajit.sh "{{OPENRESTY_PREFIX}}"
	fi
	echo "deps ok: wrk ✓  lapis ✓  openresty ✓"

# Run the full benchmark suite.
bench: deps
	#!/usr/bin/env bash
	set -uo pipefail
	ROWS=()
	FAILED=()
	for srv in node bun superfast python lapis; do
		echo "› benchmarking $srv (wrk -t{{THREADS}} -c{{CONNS}} -d{{DUR}}s) ..." >&2
		line=$(DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" \
			PIN="{{PIN}}" OPENRESTY_PREFIX="{{OPENRESTY_PREFIX}}" \
			bench/benchmark.sh "$srv" 2>/dev/null)
		if [ $? -ne 0 ] || [ -z "$line" ]; then
			FAILED+=("$srv")
		else
			ROWS+=("$line")
		fi
	done
	echo
	echo "superfast benchmark — wrk -t{{THREADS}} -c{{CONNS}} -d{{DUR}}s"
	[ -n "{{PIN}}" ] && echo "servers pinned to CPU {{PIN}}" || echo "servers unpinned (PIN=<cpu> for a single-core fight)"
	echo
	printf '%-10s %12s %8s %8s %7s %9s %9s\n' \
		"server" "req/s" "p50" "p99" "errors" "rss(MB)" "peak(MB)"
	printf '%s\n' "--------------------------------------------------------------"
	printf '%s\n' "${ROWS[@]}" | column -t
	if [ "${#FAILED[@]}" -gt 0 ]; then
		echo
		echo "failed: ${FAILED[*]} — check /tmp/superfast-bench-<name>.log"
	fi
	echo
	echo "rss  = resident set size of the whole process tree at end of run"
	echo "peak = highest single-process RSS (VmHWM) seen during the run"

# Individual servers.
bench-node: deps
	DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" PIN="{{PIN}}" bench/benchmark.sh node

bench-bun: deps
	DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" PIN="{{PIN}}" bench/benchmark.sh bun

bench-superfast: deps
	DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" PIN="{{PIN}}" bench/benchmark.sh superfast

bench-python: deps
	DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" PIN="{{PIN}}" bench/benchmark.sh python

bench-lapis: deps
	DUR="{{DUR}}" THREADS="{{THREADS}}" CONNS="{{CONNS}}" PIN="{{PIN}}" OPENRESTY_PREFIX="{{OPENRESTY_PREFIX}}" bench/benchmark.sh lapis

#!/bin/bash
# Precompile every .lua under $1 to LuaJIT bytecode in place.
#
# iOS' LuaJIT runs interpreter-only (the iOS sandbox forbids W^X), so
# the source-parsing phase dominates cold launch. Replacing every .lua
# in the bundle with bytecode (same filename, same path) lets
# luaL_loadfile skip lexing/parsing entirely — it just memcpys the
# bytecode into the VM. Roughly 10-30x faster per file load; meaningful
# on a tree of ~600 files.
#
# Bytecode produced by `luajit -b` is portable across architectures with
# the same LuaJIT version, so we use the macOS host luajit (built from
# the same base/ submodule commit as the iOS one) to compile.

set -euo pipefail

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <app-asset-dir>" >&2
    exit 1
fi

TARGET_DIR="$1"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Locate a host luajit. Prefer the one we built ourselves (same LuaJIT
# version + features as the iOS target), then fall back to PATH.
HOST_LUAJIT=""
HOST_LUAJIT_SHARE=""
for machine in arm64-apple-darwin25.0.0 arm64-apple-darwin24.0.0 \
               x86_64-apple-darwin25.0.0 x86_64-apple-darwin24.0.0; do
    cand="${REPO_ROOT}/base/build/${machine}/luajit"
    share="${REPO_ROOT}/base/build/${machine}/staging/share/luajit-2.1"
    if [ -x "$cand" ] && [ -d "$share" ]; then
        HOST_LUAJIT="$cand"
        HOST_LUAJIT_SHARE="$share"
        break
    fi
done
if [ -z "${HOST_LUAJIT}" ]; then
    if command -v luajit >/dev/null 2>&1; then
        HOST_LUAJIT="$(command -v luajit)"
        # Hope its jit/ dir is discoverable via default package.path.
    else
        echo "[precompile-lua] no host luajit found; skipping precompile." >&2
        echo "[precompile-lua] run \`make TARGET=macos base\` to build one." >&2
        exit 0
    fi
fi

echo "[precompile-lua] using host luajit: ${HOST_LUAJIT}"

# Files we deliberately skip:
#   defaults.persistent.lua — user-editable settings, KOReader writes
#     this back as text.
#   defaults.lua — read both as require() and as text in some flows.
#   userpatch/*.lua — explicitly intended to be human-editable patches.
#   anything matching *.persistent.lua — settings convention.
#   ev_replay.py — not lua, but `find` won't pick it up anyway.
SKIP_REGEX='/(defaults\.lua|defaults\.persistent\.lua|.*\.persistent\.lua|userpatch/[^/]+\.lua)$'

before_bytes=$(find "$TARGET_DIR" -type f -name '*.lua' \
    | xargs -I{} stat -f '%z' {} 2>/dev/null | awk '{s+=$1} END {print s+0}')

count_total=0
count_skipped=0
count_failed=0
count_compiled=0

# Use a temp file in the same directory as the source so the rename is
# atomic and on the same filesystem.
while IFS= read -r -d '' src; do
    count_total=$((count_total + 1))
    if [[ "$src" =~ $SKIP_REGEX ]]; then
        count_skipped=$((count_skipped + 1))
        continue
    fi
    tmp="${src}.bc.tmp"
    if LUA_PATH="${HOST_LUAJIT_SHARE}/?.lua;;" \
        "${HOST_LUAJIT}" -b "$src" "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$src"
        count_compiled=$((count_compiled + 1))
    else
        rm -f "$tmp"
        count_failed=$((count_failed + 1))
        echo "[precompile-lua] WARN failed to compile: ${src#$TARGET_DIR/}" >&2
    fi
done < <(find "$TARGET_DIR" -type f -name '*.lua' -print0)

after_bytes=$(find "$TARGET_DIR" -type f -name '*.lua' \
    | xargs -I{} stat -f '%z' {} 2>/dev/null | awk '{s+=$1} END {print s+0}')

echo "[precompile-lua] compiled ${count_compiled}/${count_total} (skipped ${count_skipped}, failed ${count_failed})"
echo "[precompile-lua] size: $(numfmt --to=iec-i --suffix=B ${before_bytes} 2>/dev/null || echo "${before_bytes}B") -> $(numfmt --to=iec-i --suffix=B ${after_bytes} 2>/dev/null || echo "${after_bytes}B")"

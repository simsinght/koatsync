#!/bin/sh
# Runs the off-device tests. Needs luajit plus luasocket, luasec and rapidjson
# installed in ../../.luarocks (see README).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
# With KOREADER set to a KOReader install (e.g. /Applications/KOReader.app/Contents/koreader),
# runs the space crypto spec, or the spaces round trip with `spaces`, on that install's own
# luajit, rocks and libcrypto (found through its ffi.loadlib, as on a device).
if [ -n "$KOREADER" ]; then
    export LUA_PATH="$HERE/../?.lua;$HERE/?.lua;$KOREADER/common/?.lua;$KOREADER/?.lua"
    export LUA_CPATH="$KOREADER/common/?.so"
    SPEC=spacecrypto_spec.lua
    if [ "$1" = "spaces" ]; then
        set -a; . "$ROOT/.env"; set +a
        SPEC=spaces_integration.lua
    fi
    cd "$KOREADER"
    exec ./luajit -e 'local ffi = require("ffi"); ffi.log = function() end; require("ffi/loadlib")' "$HERE/$SPEC"
fi
LJ=$(brew --prefix luajit 2>/dev/null || echo /usr)
eval "$(luarocks --lua-version 5.1 --lua-dir "$LJ" --tree "$ROOT/.luarocks" path)"
export LUA_PATH="$HERE/../?.lua;$HERE/?.lua;$LUA_PATH"
cd "$HERE"
if [ "$1" = "integration" ]; then
    set -a; . "$ROOT/.env"; set +a
    exec luajit integration.lua
fi
if [ "$1" = "spaces" ]; then
    set -a; . "$ROOT/.env"; set +a
    exec luajit spaces_integration.lua
fi
luajit harness.lua && luajit plugin_spec.lua && luajit spacecrypto_spec.lua && luajit anchor_spec.lua && luajit others_spec.lua && luajit popuplayout_spec.lua && luajit privacy_spec.lua

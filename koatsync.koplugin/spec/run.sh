#!/bin/sh
# Runs the off-device tests. Needs luajit plus luasocket, luasec and rapidjson
# installed in ../../.luarocks (see README).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LJ=$(brew --prefix luajit 2>/dev/null || echo /usr)
eval "$(luarocks --lua-version 5.1 --lua-dir "$LJ" --tree "$ROOT/.luarocks" path)"
export LUA_PATH="$HERE/../?.lua;$HERE/?.lua;$LUA_PATH"
cd "$HERE"
if [ "$1" = "integration" ]; then
    set -a; . "$ROOT/.env"; set +a
    exec luajit integration.lua
fi
luajit harness.lua && luajit plugin_spec.lua

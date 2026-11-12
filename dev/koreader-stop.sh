#!/bin/sh
# Stops KOReader instances started by dev/koreader.sh.
#
#   dev/koreader-stop.sh          # every profile under .koreader/
#   dev/koreader-stop.sh a ui     # only these profiles
#   dev/koreader-stop.sh --list   # show what is running, stop nothing
#
# Only touches processes whose book path is inside this repo's .koreader/
# folder, so a KOReader you opened normally is left alone.
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$repo/.koreader
list=0
[ "$1" = "--list" ] && { list=1; shift; }
found=0
ps -axo pid=,command= | grep "[M]acOS/koreader $root/" | while read -r pid cmd; do
  profile=${cmd#*"$root/"}; profile=${profile%%/*}
  if [ $# -gt 0 ]; then
    keep=1; for p in "$@"; do [ "$p" = "$profile" ] && keep=0; done
    [ $keep -eq 1 ] && continue
  fi
  if [ $list -eq 1 ]; then echo "running: $profile (pid $pid)"; else kill "$pid" && echo "stopped: $profile (pid $pid)"; fi
done

#!/bin/sh
# Runs the macOS KOReader build against a throwaway profile with this repo's
# plugin linked in. Each profile is a separate "reader": own settings, own
# sign-in, own books.
#
#   dev/koreader.sh                 # profile "a"
#   dev/koreader.sh b               # a second reader, e.g. another club member
#   dev/koreader.sh b path/to.epub  # open that book directly
#
# KOATSYNC_DEV=1 also links dev/patches/*.lua into the profile's patches/
# (helpers for the HTTP inspector: run a Lua script, inject taps). Without it,
# those links are removed again.
#
# Profiles live in .koreader/<name> (gitignored). To add ZenOS or any other
# plugin to a profile, drop its .koplugin folder into .koreader/<name>/plugins.
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
app=${KOREADER_APP:-/Applications/KOReader.app}
profile=$repo/.koreader/${1:-a}
target=${2:-$profile/books}
case $target in /*) ;; *) target=$(pwd)/$target ;; esac
mkdir -p "$profile/plugins" "$profile/books" "$profile/patches"
# First run: keep the library (and ZenOS's book scan) inside the profile.
[ -f "$profile/settings.reader.lua" ] || printf 'return {\n    ["home_dir"] = "%s/books",\n}\n' "$profile" > "$profile/settings.reader.lua"
ln -sfn "$repo/koatsync.koplugin" "$profile/plugins/koatsync.koplugin"
for p in "$repo"/dev/patches/*.lua; do
    [ -e "$p" ] || continue
    if [ "${KOATSYNC_DEV:-0}" = 1 ]; then
        ln -sfn "$p" "$profile/patches/$(basename "$p")"
    else
        rm -f "$profile/patches/$(basename "$p")"
    fi
done
cd "$app/Contents/koreader"
KO_HOME=$profile exec "$app/Contents/MacOS/koreader" "$target"

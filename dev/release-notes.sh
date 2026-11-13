#!/bin/sh
# Prints one release's notes from CHANGELOG.md: the lines between its "## vX.Y.Z" heading
# and the next "## v" heading, without the heading and without leading/trailing blank lines.
#
#   dev/release-notes.sh v0.3.5     # the notes for v0.3.5
#   dev/release-notes.sh --list     # every version that has a section, newest first
#
# Fails (exit 1, message on stderr) when the version has no section or the section is empty,
# so the release workflow stops before publishing anything.
# KOATSYNC_CHANGELOG overrides the file (default: CHANGELOG.md at the repo root).
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
changelog=${KOATSYNC_CHANGELOG:-$repo/CHANGELOG.md}
[ -f "$changelog" ] || { echo "no changelog at $changelog" >&2; exit 1; }

case ${1-} in
    --list)
        awk '/^## v[0-9]/ { print $2 }' "$changelog"
        exit 0 ;;
    v[0-9]*.*[0-9]) version=$1 ;;
    *) echo "usage: $0 vX.Y.Z | --list" >&2; exit 2 ;;
esac

awk -v want="$version" '
    /^## v[0-9]/ {
        if (found) exit
        if ($2 == want) { found = 1; next }
    }
    found { lines[++n] = $0 }
    END {
        if (!found) { print "CHANGELOG.md has no \"## " want "\" section" > "/dev/stderr"; exit 1 }
        first = 1; while (first <= n && lines[first] ~ /^[ \t]*$/) first++
        last = n; while (last >= first && lines[last] ~ /^[ \t]*$/) last--
        if (first > last) { print "CHANGELOG.md section \"## " want "\" is empty" > "/dev/stderr"; exit 1 }
        for (i = first; i <= last; i++) print lines[i]
    }
' "$changelog"

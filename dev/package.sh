#!/bin/sh
# Builds the release files for koatsync.koplugin:
#
#   dist/koatsync.koplugin.zip   the plugin, as koatsync.koplugin/ at the zip's top level
#   dist/manifest.json           a one-package ZenPM source manifest pointing at that zip
#
#   dev/package.sh               # version from koatsync.koplugin/_meta.lua
#   dev/package.sh --tag v0.2.0  # also fail unless the tag is "v" + that version
#
# The version lives only in _meta.lua. ZenPM records the release tag (minus a leading
# "v") as the installed version and compares it with the newest release's tag, so the
# tag must match _meta.lua; --tag enforces that in CI.
#
# Everything in koatsync.koplugin/ ships except spec/, dotfiles and editor/OS junk.
# The zip is reproducible: sorted entries, fixed timestamps, fixed permissions.
#
# KOATSYNC_GITHUB_REPO (default simsinght/koatsync) sets the GitHub owner/repo that
# the manifest's download URLs point at; the release workflow passes its own.
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
plugin=$repo/koatsync.koplugin
out=${KOATSYNC_DIST:-$repo/dist}
gh_repo=${KOATSYNC_GITHUB_REPO:-simsinght/koatsync}
tag=
while [ $# -gt 0 ]; do
    case $1 in
        --tag) tag=$2; shift 2 ;;
        --tag=*) tag=${1#--tag=}; shift ;;
        *) echo "usage: $0 [--tag vX.Y.Z]" >&2; exit 2 ;;
    esac
done

version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin/_meta.lua" | head -n 1)
case $version in
    ''|*[!0-9.]*|.*|*.|*..*) echo "_meta.lua: version must be X.Y.Z digits, got '$version'" >&2; exit 1 ;;
esac
if [ "$(echo "$version" | tr -cd . | wc -c | tr -d ' ')" != 2 ]; then
    echo "_meta.lua: version must be X.Y.Z, got '$version'" >&2; exit 1
fi
if [ -n "$tag" ] && [ "$tag" != "v$version" ]; then
    echo "tag $tag does not match _meta.lua version $version (expected v$version)" >&2; exit 1
fi

mkdir -p "$out"
python3 -I - "$plugin" "$out" "$version" "$gh_repo" <<'PY'
import json, os, re, sys, zipfile

plugin, out, version, gh_repo = sys.argv[1:5]
root = "koatsync.koplugin"
asset = root + ".zip"
skip_dirs = {"spec"}
skip_files = {".DS_Store", "Thumbs.db"}

files = []
for dirpath, dirnames, filenames in os.walk(plugin):
    rel_dir = os.path.relpath(dirpath, plugin)
    dirnames[:] = sorted(d for d in dirnames
                         if not d.startswith(".") and not (rel_dir == "." and d in skip_dirs))
    for name in filenames:
        if name.startswith(".") or name in skip_files or name.endswith((".swp", "~", ".local", ".orig", ".rej")):
            continue
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            sys.exit("refusing to package symlink: " + path)  # ZenPM rejects symlinks in zips
        files.append(os.path.normpath(os.path.join(rel_dir, name)))
files.sort()
for required in ("_meta.lua", "main.lua"):
    if required not in files:
        sys.exit("missing " + required)

def entry(name, mode):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3  # Unix, so the mode below is honoured
    info.external_attr = mode << 16
    return info

zip_path = os.path.join(out, asset)
tmp = zip_path + ".tmp"
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    d = entry(root + "/", 0o40755)
    d.external_attr |= 0x10  # MS-DOS directory flag
    z.writestr(d, b"")
    dirs_done = set()
    for rel in files:
        parts = rel.split(os.sep)
        for i in range(1, len(parts)):
            sub = "/".join(parts[:i])
            if sub not in dirs_done:
                dirs_done.add(sub)
                d = entry(root + "/" + sub + "/", 0o40755)
                d.external_attr |= 0x10
                z.writestr(d, b"")
        with open(os.path.join(plugin, rel), "rb") as fh:
            z.writestr(entry(root + "/" + "/".join(parts), 0o100644), fh.read(), zipfile.ZIP_DEFLATED)
os.replace(tmp, zip_path)
size = os.path.getsize(zip_path)

with open(os.path.join(plugin, "_meta.lua"), encoding="utf-8") as fh:
    meta = fh.read()
m = re.search(r"description\s*=\s*_\(\[\[(.*?)\]\]\)", meta, re.S)
description = " ".join(m.group(1).split()) if m else "Syncs your highlights and notes to your own AT Protocol PDS."

base = "https://github.com/" + gh_repo
manifest = {
    "schema_version": "1",
    "repo": {
        "id": "koatsync",
        "name": "koatsync",
        "url": base + "/releases/latest/download/",
    },
    "packages": [{
        "id": "koatsync",
        "name": "koatsync",
        "version": version,
        "description": description,
        "author": gh_repo.split("/")[0],
        "category": "productivity",
        "platforms": ["koreader"],
        "dependencies": [],
        "source": base,
        "source_type": "release",
        "source_asset": asset,
        "size": str(size),
        "assets": [{
            "arch": "any",
            "asset": asset,
            "url": base + "/releases/download/v" + version + "/" + asset,
            "size": str(size),
        }],
    }],
}
with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")

print("%s (%d bytes, %d files, version %s)" % (zip_path, size, len(files), version))
for rel in files:
    print("  " + root + "/" + rel.replace(os.sep, "/"))
print(os.path.join(out, "manifest.json"))
PY

# koatsync

A [KOReader](https://koreader.rocks/) plugin that mirrors your highlights and notes to your own
[AT Protocol](https://atproto.com/) PDS, as `at.stim.reading.book` and `at.stim.reading.highlight`
records. Your sidecar files stay the source of truth; the PDS is a durable, queryable copy that any
appview can index.

Status: early. Works against a self-hosted PDS; not yet published to any plugin store.

## What it does

- Every highlight and note becomes one record on your PDS, linked to a book record with title,
  authors, ISBN when the file declares one, and the file's KOReader hash.
- Records carry the highlight's position (crengine xpointers or PDF coordinates), chapter, page,
  colour and style, so they can be restored into KOReader later.
- Syncs are diffs: each book keeps a ledger of what the PDS holds. Edits update records, deletions
  delete them, and running a sync twice sends nothing the second time.
- Nothing turns Wi-Fi on by itself. Automatic syncs only run when the radio is already up; otherwise
  the book is flagged and sent later.

## Install

Copy `koatsync.koplugin` into KOReader's `plugins` directory and restart KOReader.

| Device | Plugins directory |
| --- | --- |
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |
| Android | `koreader/plugins/` under internal storage |
| Desktop | `koreader/plugins/` next to the program |

Needs KOReader 2025.04 or newer (for the Export Highlights integration).

## Sign in

**Tools → koatsync → Sign in to your PDS…** asks for your handle, an app password, and optionally
your PDS URL. Leave the URL blank if your handle resolves publicly; fill it in for a self-hosted PDS
whose handles have no DNS of their own.

To skip typing on the device, put a `koatsync_login.txt` in the KOReader folder over USB:

```
handle=you.example.com
password=your-app-password
pds=https://pds.example.com   # optional
```

then choose **Tools → koatsync → Sign in from file…**. The file is deleted once the sign-in succeeds.

The app password is stored in KOReader's settings directory in plain text, the same way KOReader's own
progress sync stores its password. Use an app password, never your account password.

## Syncing

- **Automatic**: on by default. About ten seconds after you stop editing a highlight or note, the
  book is synced if Wi-Fi is on.
- **On close**: a book with unsent changes is synced when you close it, if Wi-Fi is on.
- **When Wi-Fi connects**: pending books go out shortly after the device comes online.
- **Manual**: **Sync this book now** and **Sync pending books** in the menu, also available as
  dispatcher actions (`koatsync: sync this book`, `koatsync: sync pending books`,
  `koatsync: toggle automatic sync`) for gestures.
- **Bulk backfill**: enable **koatsync (PDS)** under **Tools → Export highlights → Choose formats**,
  then export from the file browser to push many books at once.

## ZenOS

The plugin follows what [ZenOS](https://github.com/xZenLabs/zen-os) looks for:

- Its menu is a submenu, so **Add → Plugin Menu** in Controls, Navbar and Launcher can open it.
- Its dispatcher actions can be bound to Controls, Navbar and Launcher buttons, and to gestures.
- While books are waiting to sync it shows `↑n` as a ZenOS status-bar item (`koatsync pending`),
  which you can place under Zen Settings.

It deliberately adds no button to the text-selection menu: ZenOS hides unknown selection buttons by
default, and the automatic mirror makes one unnecessary.

## Data model

Lexicons are in `lexicons/`. In short:

- `at.stim.reading.book`: title, authors, identifiers (isbn13/isbn10/asin/openLibrary/fileHash/
  fileName), language, format, pages, optional status and progress, timestamps.
- `at.stim.reading.highlight`: book (at-uri), text, note, chapter, color, style, locator
  (`koreader-xpointer` or `koreader-pdf` start/end plus page and page label), optional prefix/suffix
  context, tags, generator, timestamps.

Position locators only make sense against the same file bytes, which is why the book record carries
KOReader's partial MD5 of the file.

## Development

Off-device tests run on LuaJIT with the same libraries KOReader bundles:

```sh
brew install luajit luarocks
LJ=$(brew --prefix luajit)
luarocks --lua-version 5.1 --lua-dir "$LJ" --tree ./.luarocks install luasocket
luarocks --lua-version 5.1 --lua-dir "$LJ" --tree ./.luarocks install luasec OPENSSL_DIR=$(brew --prefix openssl@3)
luarocks --lua-version 5.1 --lua-dir "$LJ" --tree ./.luarocks install rapidjson
koatsync.koplugin/spec/run.sh              # unit + stubbed plugin scenarios
koatsync.koplugin/spec/run.sh integration  # live round trip against the PDS in .env
```

The integration run needs a `.env` with `ATP_PDS`, `ATP_HANDLE`, `ATP_DID` and `ATP_PASSWORD`.
It creates and deletes its own records.

Module map:

- `atproto.lua`: XRPC client (session, renewal, identity resolution, records, applyWrites).
- `records.lua`: pure mapping between KOReader annotations and records, both directions.
- `sync.lua`: diff a book's annotations against its ledger and push in batches.
- `store.lua`: plugin settings and per-book sidecar state.
- `exporter.lua`: target for KOReader's Export Highlights.
- `main.lua`: menus, dispatcher actions, events, ZenOS hooks.

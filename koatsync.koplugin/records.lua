--[[--
Pure mapping between KOReader's data and at.stim.reading.* records.

Nothing here touches the screen, the network or the filesystem, so it runs the
same on a device and in the test harness.

@module koplugin.koatsync.records
]]

local bit = require("bit")

local Records = {}

Records.BOOK = "at.stim.reading.book"
Records.HIGHLIGHT = "at.stim.reading.highlight"

--- Annotation field set (to true) on highlights the reader keeps out of their club; see privacy.lua.
Records.PRIVATE_FIELD = "koatsync_private"

-- Time -------------------------------------------------------------------------

--[[--
KOReader stamps annotations with local time as "YYYY-MM-DD HH:MM:SS". `os.time`
reads that table as local time, so the result is UTC and DST-correct.
]]
function Records.toIso(ko_datetime)
    if type(ko_datetime) ~= "string" then return nil end
    local y, mo, d, h, mi, s = ko_datetime:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                       hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }
    if not t then return nil end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

--- The inverse, for pulling records back into a sidecar.
function Records.fromIso(iso)
    if type(iso) ~= "string" then return nil end
    local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    -- Interpret as UTC: build a UTC epoch by correcting for the local offset.
    local as_local = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                              hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }
    local utc_table = os.date("!*t", as_local)
    utc_table.isdst = os.date("*t", as_local).isdst
    local offset = as_local - os.time(utc_table)
    return os.date("%Y-%m-%d %H:%M:%S", as_local + offset)
end

function Records.nowIso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Fingerprints -----------------------------------------------------------------

--- FNV-1a over a string; enough to notice that an annotation changed.
local function fnv1a(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619)
    end
    return string.format("%08x", bit.band(h, 0xffffffff))
end

local function posKey(pos)
    if type(pos) == "table" then
        return string.format("%s:%s:%s", tostring(pos.page), tostring(pos.x), tostring(pos.y))
    end
    return tostring(pos)
end

--[[--
Everything about an annotation that would change the record. The private flag
is only appended when set, so shared annotations keep the fingerprints already
in their ledgers and a flip either way reads as an update.
]]
function Records.fingerprint(a)
    local parts = {
        a.text or "", a.note or "", a.chapter or "", a.color or "", a.drawer or "",
        posKey(a.pos0), posKey(a.pos1), tostring(a.pageno), a.pageref or "",
    }
    if a[Records.PRIVATE_FIELD] == true then parts[#parts + 1] = "private" end
    return fnv1a(table.concat(parts, "\1"))
end

-- Books ------------------------------------------------------------------------

local function isbnChecksumOk(digits)
    if #digits == 13 then
        local sum = 0
        for i = 1, 13 do
            local d = tonumber(digits:sub(i, i))
            if not d then return false end
            sum = sum + d * ((i % 2 == 1) and 1 or 3)
        end
        return sum % 10 == 0
    elseif #digits == 10 then
        local sum = 0
        for i = 1, 10 do
            local c = digits:sub(i, i)
            local d = (c == "X" and i == 10) and 10 or tonumber(c)
            if not d then return false end
            sum = sum + d * (11 - i)
        end
        return sum % 11 == 0
    end
    return false
end

--- First checksum-valid ISBN in any of the given strings; 13-digit preferred.
function Records.findISBN(...)
    local ten
    for i = 1, select("#", ...) do
        local text = select(i, ...)
        if type(text) == "string" and #text > 0 then
            for run in text:gmatch("[%dXx][%dXx%s%-]*[%dXx]") do
                local digits = run:gsub("[%s%-]", ""):upper()
                local n = #digits
                if n >= 13 then
                    for start = 1, n - 12 do
                        local c = digits:sub(start, start + 12)
                        if (c:sub(1, 3) == "978" or c:sub(1, 3) == "979") and isbnChecksumOk(c) then
                            return c
                        end
                    end
                end
                if not ten and n >= 10 then
                    for start = 1, n - 9 do
                        local c = digits:sub(start, start + 9)
                        if isbnChecksumOk(c) then ten = c; break end
                    end
                end
            end
        end
    end
    return ten
end

local function splitAuthors(authors)
    if type(authors) ~= "string" or authors == "" then return nil end
    local out = {}
    for line in authors:gmatch("[^\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then out[#out + 1] = line end
    end
    return #out > 0 and out or nil
end

local function fileFormat(file)
    if type(file) ~= "string" then return nil end
    local ext = file:match("%.([%w]+)$")
    return ext and ext:lower() or nil
end

--[[--
Builds a book record.

@param info { file, props = doc_props, pages, md5, existing = previous record value }
]]
function Records.bookRecord(info)
    local props = info.props or {}
    local existing = info.existing or {}
    local isbn = Records.findISBN(props.identifiers, props.keywords, props.description,
        info.file and info.file:match("([^/]+)$"))
    local identifiers = {}
    for k, v in pairs(existing.identifiers or {}) do identifiers[k] = v end
    if isbn then
        if #isbn == 13 then identifiers.isbn13 = isbn else identifiers.isbn10 = isbn end
    end
    if info.md5 then identifiers.fileHash = info.md5 end
    if info.file then identifiers.fileName = info.file:match("([^/]+)$") end

    local title = props.title
    if not title or title == "" then
        title = info.file and info.file:match("([^/]+)%.[%w]+$") or "Untitled"
    end
    local rec = {
        ["$type"] = Records.BOOK,
        title = title,
        authors = splitAuthors(props.authors) or existing.authors,
        identifiers = next(identifiers) and identifiers or nil,
        language = props.language or existing.language,
        format = fileFormat(info.file) or existing.format,
        pages = info.pages or existing.pages,
        status = existing.status,
        progress = existing.progress,
        startedAt = existing.startedAt,
        finishedAt = existing.finishedAt,
        createdAt = existing.createdAt or Records.nowIso(),
        updatedAt = Records.nowIso(),
    }
    return rec
end

-- Highlights -------------------------------------------------------------------

local function encodePdfPos(pos)
    if type(pos) ~= "table" then return tostring(pos) end
    return string.format("%s:%s:%s", tostring(pos.page or ""), tostring(pos.x or ""), tostring(pos.y or ""))
end

function Records.decodePdfPos(s)
    local page, x, y = tostring(s):match("^([^:]*):([^:]*):([^:]*)$")
    if not page then return nil end
    return { page = tonumber(page), x = tonumber(x), y = tonumber(y) }
end

--- Page bookmarks and image-only highlights carry nothing worth syncing.
function Records.isSyncable(a)
    return type(a) == "table" and a.drawer ~= nil and type(a.text) == "string" and a.text ~= ""
end

--[[--
Builds a highlight record from a KOReader annotation.

@param a annotation table from the sidecar
@param book_uri at-uri of the book record
@param opts { generator = {name, version, device}, context = {prefix, suffix}, existing = previous record value }
]]
function Records.highlightRecord(a, book_uri, opts)
    opts = opts or {}
    local existing = opts.existing or {}
    local locator
    if a.pos0 ~= nil and a.pos1 ~= nil then
        local is_pdf = type(a.pos0) == "table"
        locator = {
            format = is_pdf and "koreader-pdf" or "koreader-xpointer",
            start = is_pdf and encodePdfPos(a.pos0) or tostring(a.pos0),
            ["end"] = is_pdf and encodePdfPos(a.pos1) or tostring(a.pos1),
            page = tonumber(a.pageno) or (is_pdf and tonumber(a.page)) or nil,
            pageLabel = a.pageref and tostring(a.pageref) or nil,
        }
    end
    local created = Records.toIso(a.datetime) or existing.createdAt or Records.nowIso()
    local updated = a.datetime_updated and Records.toIso(a.datetime_updated) or nil
    if existing.createdAt and not updated then updated = Records.nowIso() end
    return {
        ["$type"] = Records.HIGHLIGHT,
        book = book_uri,
        text = a.text,
        note = (a.note and a.note ~= "") and a.note or nil,
        chapter = (a.chapter and a.chapter ~= "") and a.chapter or nil,
        color = a.color,
        style = a.drawer,
        locator = locator,
        context = opts.context,
        tags = existing.tags,
        generator = opts.generator,
        createdAt = created,
        updatedAt = updated,
    }
end

--- The inverse, for a future pull: a sidecar annotation from a record.
function Records.annotationFromRecord(rec)
    local a = {
        text = rec.text,
        note = rec.note,
        chapter = rec.chapter,
        color = rec.color,
        drawer = rec.style or "lighten",
        datetime = Records.fromIso(rec.createdAt),
        datetime_updated = rec.updatedAt and Records.fromIso(rec.updatedAt) or nil,
    }
    local loc = rec.locator
    if loc then
        if loc.format == "koreader-pdf" then
            a.pos0 = Records.decodePdfPos(loc.start)
            a.pos1 = Records.decodePdfPos(loc["end"])
            a.page = a.pos0 and a.pos0.page or loc.page
        else
            a.pos0, a.pos1, a.page = loc.start, loc["end"], loc.start
        end
        a.pageno = loc.page
        a.pageref = loc.pageLabel
    end
    return a
end

return Records

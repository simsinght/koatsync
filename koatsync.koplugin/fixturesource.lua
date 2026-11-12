--[[--
Where other readers' highlights come from, for now: a JSON file per book.

Any source offers one method, so a network source (an appview query, or the
club members' repos read directly) can replace this one without touching the
rest:

    source:fetch(book) -> entries | nil, err

`book` is { file, md5, title, authors }. Each entry is

    { author = { did, handle, displayName }, uri, cid, bookFileHash,
      record = <at.stim.reading.highlight value> }

This source looks in `dir` for, in order, `<md5>.json`, then
`<title>.json` (lower-cased, anything but letters and digits as `-`), so one
fixture can serve every edition of a book. The file holds a JSON array of
entries, or an object with an `entries` array.

@module koplugin.koatsync.fixturesource
]]

local FixtureSource = {}
FixtureSource.__index = FixtureSource

--- `opts`: { dir, decode = function(json_string) -> value }
function FixtureSource.new(opts)
    return setmetatable({ dir = opts.dir, decode = opts.decode }, FixtureSource)
end

function FixtureSource.slug(title)
    if type(title) ~= "string" then return nil end
    local s = title:lower():gsub("[^%w\128-\255]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return s ~= "" and s or nil
end

function FixtureSource:candidatePaths(book)
    local out = {}
    if book.md5 then out[#out + 1] = self.dir .. "/" .. book.md5 .. ".json" end
    local slug = FixtureSource.slug(book.title)
    if slug then out[#out + 1] = self.dir .. "/" .. slug .. ".json" end
    return out
end

local function valid(e)
    return type(e) == "table" and type(e.record) == "table" and type(e.record.text) == "string"
        and type(e.author) == "table" and type(e.author.did) == "string"
end

function FixtureSource:fetch(book)
    for _, path in ipairs(self:candidatePaths(book)) do
        local f = io.open(path, "rb")
        if f then
            local raw = f:read("*a")
            f:close()
            local ok, data = pcall(self.decode, raw)
            if not ok or type(data) ~= "table" then
                return nil, "could not parse " .. path
            end
            local list = data.entries or data
            local entries = {}
            for _, e in ipairs(list) do
                if valid(e) then entries[#entries + 1] = e end
            end
            return entries, nil, path
        end
    end
    return {}
end

return FixtureSource

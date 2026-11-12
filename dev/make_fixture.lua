--[[
Dev-only: builds the book-club fixture from the book open in KOReader, the way
koatsync would have written those highlights (records.lua, 15 words of context
via getSelectedWordContext). Run through the inspector with the dev patch:

  curl 'http://127.0.0.1:8182/koreader/globals/KoatsyncDev/run/"/abs/path/dev/make_fixture.lua"'

Passages are for Project Gutenberg's Pride and Prejudice (#1342). Writes
<KO_HOME>/koatsync/others/pride-and-prejudice.json and returns a summary.
]]
local ui = ...
local DataStorage = require("datastorage")
local rapidjson = require("rapidjson")
local util = require("util")

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
local Records = dofile(here .. "/../koatsync.koplugin/records.lua")

local doc = ui.document
local md5 = ui.doc_settings:readSetting("partial_md5_checksum")

local people = {
    alice = { did = "did:plc:k5bn2xq4alicem7c3lubd", handle = "alice.bookclub.example", displayName = "Alice Moreau" },
    ben = { did = "did:plc:7wq3benokaforv2cy4hzqe", handle = "ben.bookclub.example", displayName = "Ben Okafor" },
    chloe = { did = "did:plc:ty2mchloedurand6wk4fga", handle = "chloe.bookclub.example", displayName = "Chloé Durand" },
}

-- who, find (exact text in this edition), find_end (end of a longer passage),
-- ctx (pick the hit whose preceding text contains this), alter (replace the
-- record's text: a passage that should not be found anywhere)
local specs = {
    { who = "alice", find = "IT is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
      note = "Still the best opening line.", kind = "full sentence (drop cap)" },
    { who = "ben", find = "a single man in possession of a good fortune", kind = "overlaps another person's" },
    { who = "ben", find = "However little known the feelings or views of such a man may be on his first entering a neighbourhood", kind = "sentence fragment" },
    { who = "chloe", find = "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”",
      note = "Mrs Bennet in one line.", kind = "quotes" },
    { who = "alice", find = "replied Elizabeth", ctx = "very true,”", note = "Pride vs vanity again", kind = "short repeated phrase (18x)" },
    { who = "chloe", find = "Mr. Darcy", ctx = "But the wife of", kind = "short repeated phrase, punctuation" },
    { who = "ben", find = "And there are other circumstances which I am not at liberty—which it is not worth while to relate; but his lies about the whole Pemberley family are endless.",
      note = "She almost tells them.", kind = "em dash" },
    { who = "chloe", find = "“Neither duty, nor honour, nor gratitude,” replied Elizabeth, “has any possible claim on me, in the present instance.",
      kind = "quotes, word differs in other edition (has/have)" },
    { who = "alice", find = "“In vain have I struggled.", find_end = "doubted, and was silent.", note = "The proposal!", kind = "multi-paragraph" },
    { who = "ben", find = "“Your plan is a good one,” replied Elizabeth, “where nothing", find_end = "make her understand his character.”",
      kind = "long paragraph (~120 words)" },
    { who = "chloe", find = "Mr. Bennet was so odd a mixture of quick parts", find_end = "its solace was visiting and news.",
      note = "Poor Mr Bennet.", kind = "long, several edition differences" },
    { who = "alice", find = "“In vain have I struggled.", find_end = "admire and love you.”",
      alter = "“In vain have I struggled. The badgers of Netherfield held their annual parliament beneath the old oak, and nobody came.”",
      kind = "deliberately altered (should be unplaced)" },
}

local function find(pattern, ctx, after)
    local res = doc:findAllText(pattern, true, 15, 5000, false, 0x00FF) or {}
    for _, r in ipairs(res) do
        local ok = true
        if ctx and not (r.prev_text or ""):find(ctx, 1, true) then ok = false end
        if after and doc:compareXPointers(after, r.start) ~= 1 then ok = false end
        if ok then return r end
    end
end

local entries, summary = {}, {}
for i, s in ipairs(specs) do
    local hit = find(s.find, s.ctx)
    if not hit then
        summary[#summary + 1] = { i = i, error = "not found: " .. s.find }
    else
        local pos0, pos1 = hit.start, hit["end"]
        if s.find_end then
            local e = find(s.find_end, nil, pos0)
            pos1 = e and e["end"] or pos1
        end
        local text = util.cleanupSelectedText(doc:getTextFromXPointers(pos0, pos1))
        local prefix, suffix = doc:getSelectedWordContext(text, 15, pos0, pos1, false)
        local a = {
            text = text, note = s.note, drawer = "lighten", color = "yellow",
            pos0 = pos0, pos1 = pos1, page = pos0,
            pageno = doc:getPageFromXPointer(pos0),
            chapter = ui.toc:getTocTitleByPage(pos0),
            datetime = os.date("%Y-%m-%d %H:%M:%S", os.time() - (100 - i) * 3600),
        }
        local author = people[s.who]
        local rec = Records.highlightRecord(a, "at://" .. author.did .. "/at.stim.reading.book/3lpgbook", {
            context = { prefix = prefix, suffix = suffix },
            generator = { name = "koatsync", version = "0.1.0", device = "Kobo Clara 2E" },
        })
        if s.alter then rec.text = s.alter end
        entries[#entries + 1] = {
            author = author,
            uri = string.format("at://%s/at.stim.reading.highlight/3lpg%04d", author.did, i),
            cid = string.format("bafyreifakecid%04d", i),
            bookFileHash = md5,
            record = rec,
        }
        summary[#summary + 1] = { i = i, who = s.who, kind = s.kind, text = rec.text:sub(1, 70), prefix = prefix, suffix = suffix }
    end
end

local dir = DataStorage:getDataDir() .. "/koatsync/others"
util.makePath(dir)
local path = dir .. "/pride-and-prejudice.json"
local f = assert(io.open(path, "w"))
f:write(rapidjson.encode({ book = { title = "Pride and Prejudice", fileHash = md5, source = doc.file }, entries = entries }, { pretty = true }))
f:close()
return { path = path, md5 = md5, count = #entries, summary = summary }

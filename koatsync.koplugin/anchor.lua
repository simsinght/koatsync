--[[--
Re-anchoring a quoted passage in a document that may be a different edition
of the book it was highlighted in.

Everything here is pure Lua over a small document interface, so it runs in the
test harness against a fake document. `Anchor.creAdapter` wraps a KOReader
CreDocument in that interface.

Why it works the way it does (measured on KOReader 2026.07, crengine):

* `findAllText` scans the whole book on every call (about 100-200 ms for a
  novel on a laptop, so seconds on an e-reader), and regex mode is 5-10x slower
  still. So each highlight gets as few scans as possible: usually one.
* A plain search matches across inline nodes, folds ' and ’, folds the dash
  family into each other, collapses spaces and ignores soft hyphens and other
  format characters; it does NOT fold “ ” into ", -- into —, or match across
  paragraphs. So search patterns are only ever plain runs of words separated by
  single spaces: no quotes, dashes or other punctuation, never two paragraphs.
* From one anchor hit, the rest of the passage is found by walking word by word
  through the document (cheap, no scan) and aligning words, which tolerates
  punctuation and small wording changes between editions.

Document interface (`doc`):

  doc:findAll(pattern)     -> list of { start, stop, before, after } (xpointers,
                              plus a few words of context each side)
  doc:text(xp0, xp1)       -> text between two xpointers
  doc:nextWordEnd(xp)      -> xpointer or nil
  doc:prevWordStart(xp)    -> xpointer or nil
  doc:prevChar(xp), doc:nextChar(xp) -> xpointer or nil (optional)
  doc:isValid(xp0, xp1)    -> boolean (both xpointers resolve, in order)

@module koplugin.koatsync.anchor
]]

local Anchor = {}

--- Bump to invalidate every cached placement.
Anchor.VERSION = 2

Anchor.MIN_ANCHOR_WORDS = 3
Anchor.MAX_ANCHOR_WORDS = 6
Anchor.MAX_ATTEMPTS = 3      -- document scans per passage, at most
Anchor.MIN_SIMILARITY = 0.8  -- word-level LCS ratio to accept a placement
Anchor.CONTEXT_WORDS = 15

-- Normalisation ---------------------------------------------------------------

local REPLACE = {
    -- quotes and primes
    ["\u{2018}"] = "'", ["\u{2019}"] = "'", ["\u{201A}"] = "'", ["\u{201B}"] = "'",
    ["\u{2032}"] = "'", ["\u{02BC}"] = "'", ["\u{0060}"] = "'", ["\u{00B4}"] = "'",
    ["\u{201C}"] = '"', ["\u{201D}"] = '"', ["\u{201E}"] = '"', ["\u{201F}"] = '"',
    ["\u{2033}"] = '"', ["\u{00AB}"] = '"', ["\u{00BB}"] = '"',
    ["\u{2039}"] = '"', ["\u{203A}"] = '"',
    -- dashes
    ["\u{2010}"] = "-", ["\u{2011}"] = "-", ["\u{2012}"] = "-", ["\u{2013}"] = "-",
    ["\u{2014}"] = "-", ["\u{2015}"] = "-", ["\u{2212}"] = "-", ["\u{2E3A}"] = "-",
    ["\u{2E3B}"] = "-",
    -- ellipsis
    ["\u{2026}"] = "...",
    -- spaces
    ["\u{00A0}"] = " ", ["\u{2002}"] = " ", ["\u{2003}"] = " ", ["\u{2004}"] = " ",
    ["\u{2005}"] = " ", ["\u{2006}"] = " ", ["\u{2007}"] = " ", ["\u{2008}"] = " ",
    ["\u{2009}"] = " ", ["\u{200A}"] = " ", ["\u{202F}"] = " ", ["\u{205F}"] = " ",
    ["\u{3000}"] = " ", ["\t"] = " ", ["\r"] = "",
    -- invisible: soft hyphen, zero-width space/joiners, word joiner, BOM
    ["\u{00AD}"] = "", ["\u{200B}"] = "", ["\u{200C}"] = "", ["\u{200D}"] = "",
    ["\u{2060}"] = "", ["\u{FEFF}"] = "",
    -- ligatures
    ["\u{FB00}"] = "ff", ["\u{FB01}"] = "fi", ["\u{FB02}"] = "fl",
    ["\u{FB03}"] = "ffi", ["\u{FB04}"] = "ffl", ["\u{FB05}"] = "st", ["\u{FB06}"] = "st",
}

--[[--
Folds typographic variants to plain ASCII punctuation, drops invisible
characters, and collapses runs of spaces (newlines are kept: they are paragraph
breaks). Letters are left alone.
]]
function Anchor.normalize(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[\192-\247][\128-\191]*", function(ch) return REPLACE[ch] end)
    s = s:gsub("[\t\r]", function(ch) return REPLACE[ch] end)
    s = s:gsub(" *\n[ \n]*", "\n"):gsub("  +", " ")
    return s
end

--[[--
Splits text into lower-cased words. A word is a run of letters, digits and
inner apostrophes (non-ASCII bytes count as letters); everything else,
hyphens included, separates words.

@treturn table words
@treturn table seps, seps[i] = the normalised text between word i-1 and word i
  (seps[1] is what precedes the first word)
]]
function Anchor.words(s)
    s = Anchor.normalize(s)
    local words, seps = {}, {}
    local pos, n = 1, #s
    while pos <= n do
        local ws, we = s:find("[%w\128-\255']+", pos)
        if not ws then break end
        local w = s:sub(ws, we)
        -- apostrophes at the edges are quotes, not part of the word
        local lead = w:match("^'*")
        local trail = w:match("'*$")
        local core = w:sub(#lead + 1, #w - #trail)
        if core ~= "" then
            seps[#words + 1] = s:sub(pos, ws - 1 + #lead)
            words[#words + 1] = core:lower()
            pos = we - #trail + 1
        else
            pos = we + 1
        end
    end
    return words, seps
end

-- Similarity ------------------------------------------------------------------

--- Length of the longest common subsequence of two word lists.
function Anchor.lcs(a, b)
    local n, m = #a, #b
    if n == 0 or m == 0 then return 0 end
    local prev, cur = {}, {}
    for j = 0, m do prev[j] = 0 end
    for i = 1, n do
        cur[0] = 0
        local ai = a[i]
        for j = 1, m do
            if ai == b[j] then
                cur[j] = prev[j - 1] + 1
            else
                local u, l = prev[j], cur[j - 1]
                cur[j] = u > l and u or l
            end
        end
        prev, cur = cur, prev
    end
    return prev[m]
end

--- LCS over the longer of the two lists: 1 means the same words in order.
function Anchor.similarity(a, b)
    local longest = math.max(#a, #b)
    if longest == 0 then return 1 end
    return Anchor.lcs(a, b) / longest
end

local function slice(t, i, j)
    local out = {}
    for k = math.max(i, 1), math.min(j, #t) do out[#out + 1] = t[k] end
    return out
end

local function concat(a, b)
    local out = {}
    for _, v in ipairs(a) do out[#out + 1] = v end
    for _, v in ipairs(b) do out[#out + 1] = v end
    return out
end

-- Anchors ---------------------------------------------------------------------

--[[--
Candidate search patterns for a passage: windows of consecutive words joined by
single spaces only, so that punctuation differences between editions cannot
break the match. Ordered first window, last window, then the middle.

@treturn table list of { first, last, pattern } in word indexes of `words`
]]
function Anchor.candidates(words, seps, text)
    local n = #words
    -- the passage itself as a pattern, when it has no punctuation crengine
    -- would not fold: quotes, dashes, paragraph breaks
    local literal
    if text then
        local t = Anchor.normalize(text):lower()
        t = t:gsub("^[^%w\128-\255]+", ""):gsub("[^%w\128-\255]+$", "")
        if t ~= "" and not t:find("[\"%-\n]") then literal = t end
    end
    if n == 0 then return {} end
    -- runs of words whose separators are a single plain space
    local runs, rs = {}, 1
    for i = 2, n + 1 do
        if i > n or seps[i] ~= " " then
            runs[#runs + 1] = { rs, i - 1 }
            rs = i
        end
    end
    local min_len = math.min(Anchor.MIN_ANCHOR_WORDS, n)
    local windows = {}
    for _, r in ipairs(runs) do
        local len = r[2] - r[1] + 1
        if len >= min_len then
            local w = math.min(len, Anchor.MAX_ANCHOR_WORDS)
            -- the run's head and tail windows; long runs also give middles
            local starts = { r[1] }
            if len > w then starts[#starts + 1] = r[2] - w + 1 end
            if len > 3 * w then starts[#starts + 1] = r[1] + math.floor((len - w) / 2) end
            for _, s in ipairs(starts) do windows[#windows + 1] = { s, s + w - 1 } end
        end
    end
    if #windows == 0 then
        -- No plain run long enough (punctuation every word or two, as in
        -- "Mr. Darcy"): search the short passage as written, minus quotes and
        -- dashes, then fall back to its longest plain run.
        local out = {}
        if literal and n <= 2 * Anchor.MAX_ANCHOR_WORDS then
            out[1] = { first = 1, last = n, pattern = literal }
        end
        table.sort(runs, function(a, b) return (a[2] - a[1]) > (b[2] - b[1]) end)
        local r = runs[1]
        local last = math.min(r[2], r[1] + Anchor.MAX_ANCHOR_WORDS - 1)
        out[#out + 1] = { first = r[1], last = last, pattern = table.concat(slice(words, r[1], last), " ") }
        return out
    end
    table.sort(windows, function(a, b) return a[1] < b[1] end)
    -- first, last, then the rest from the middle outwards
    local order = { windows[1], windows[#windows] }
    local rest = slice(windows, 2, #windows - 1)
    local mid = (n + 1) / 2
    table.sort(rest, function(a, b)
        return math.abs((a[1] + a[2]) / 2 - mid) < math.abs((b[1] + b[2]) / 2 - mid)
    end)
    for _, w in ipairs(rest) do order[#order + 1] = w end
    local out, seen = {}, {}
    for _, w in ipairs(order) do
        local key = w[1] .. ":" .. w[2]
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { first = w[1], last = w[2], pattern = table.concat(slice(words, w[1], w[2]), " ") }
        end
    end
    return out
end

--[[--
How well a hit's surroundings agree with what the record says surrounds the
anchor. 0..2: one part for the words before, one for the words after.
]]
function Anchor.contextScore(expect_before, expect_after, hit)
    local n = Anchor.CONTEXT_WORDS
    local before = Anchor.words(hit.before or "")
    local after = Anchor.words(hit.after or "")
    local eb = slice(expect_before, #expect_before - n + 1, #expect_before)
    local ea = slice(expect_after, 1, n)
    before = slice(before, #before - n + 1, #before)
    after = slice(after, 1, n)
    local sb = #eb > 0 and Anchor.lcs(eb, before) / #eb or 0
    local sa = #ea > 0 and Anchor.lcs(ea, after) / #ea or 0
    return sb + sa
end

--[[--
Position (1-based, in `hay`) where `needle` (a short word list) occurs nearest
to `expected`, or nil.
]]
local function nearestOccurrence(hay, needle, expected)
    local best, best_d
    for i = 1, #hay - #needle + 1 do
        local ok = true
        for k = 1, #needle do
            if hay[i + k - 1] ~= needle[k] then ok = false; break end
        end
        if ok then
            local d = math.abs(i - expected)
            if not best_d or d < best_d then best, best_d = i, d end
        end
    end
    return best
end

--[[--
Walks `steps` words from `xp` in one direction and returns the xpointer that
covers exactly `want` words, as counted by `Anchor.words`, of the text between
`xp` and it. Walking stops as soon as the word count would exceed `want`, so a
word crengine splits in two (Bingley + ’s) is taken whole.
]]
local function walkToCount(doc, xp, forward, want)
    if want <= 0 then return xp end
    local function between(other)
        if forward then return doc:text(xp, other) end
        return doc:text(other, xp)
    end
    local cur, last_good = xp, nil
    -- Words never shrink as we walk, so a linear walk is fine; passages are
    -- short and each step is a cheap DOM move.
    local guard = want * 3 + 20
    while guard > 0 do
        guard = guard - 1
        local nxt = forward and doc:nextWordEnd(cur) or doc:prevWordStart(cur)
        if not nxt or nxt == cur then break end
        local count = #(Anchor.words(between(nxt)))
        if count > want then break end
        if count == want then last_good = nxt end
        cur = nxt
    end
    return last_good
end

--[[--
Grows a hit on an anchor (words first..last of the passage) to cover the whole
passage, by walking outwards and aligning the passage's first and last words
against the document's.
]]
local function extend(doc, words, cand, hit)
    local n = #words
    local pos0, pos1 = hit.start, hit.stop
    local need_before = cand.first - 1
    local need_after = n - cand.last
    if need_before > 0 then
        -- Look a bit further back than needed, then find where the passage's
        -- opening words sit in the document's text.
        local far = hit.start
        for _ = 1, need_before + 10 do
            local p = doc:prevWordStart(far)
            if not p or p == far then break end
            far = p
        end
        local dwords = Anchor.words(doc:text(far, hit.start))
        local head = slice(words, 1, math.min(2, need_before))
        local at = nearestOccurrence(dwords, head, #dwords - need_before + 1)
            or nearestOccurrence(dwords, { words[1] }, #dwords - need_before + 1)
        local want = at and (#dwords - at + 1) or need_before
        pos0 = walkToCount(doc, hit.start, false, want) or pos0
    end
    if need_after > 0 then
        local far = hit.stop
        for _ = 1, need_after + 10 do
            local p = doc:nextWordEnd(far)
            if not p or p == far then break end
            far = p
        end
        local dwords = Anchor.words(doc:text(hit.stop, far))
        local k = math.min(2, need_after)
        local tail = slice(words, n - k + 1, n)
        local at = nearestOccurrence(dwords, tail, need_after - k + 1)
        local want
        if at then
            want = at + k - 1
        else
            at = nearestOccurrence(dwords, { words[n] }, need_after)
            want = at or need_after
        end
        pos1 = walkToCount(doc, hit.stop, true, want) or pos1
    end
    return pos0, pos1
end

--[[--
Word walking stops at word edges, so a passage that began with an opening quote
or ended with a full stop loses them. Takes back the punctuation the record has
at either end, one character at a time, while the document agrees.
]]
local function widen(doc, text, pos0, pos1)
    if not (doc.prevChar and doc.nextChar) then return pos0, pos1 end
    local norm = Anchor.normalize(text)
    local lead = norm:match("^[^%w\128-\255]*"):gsub("%s", "")
    local trail = norm:match("[^%w\128-\255]*$"):gsub("%s", "")
    for i = #lead, 1, -1 do
        local p = doc:prevChar(pos0)
        if not p or Anchor.normalize(doc:text(p, pos0)):gsub("%s", "") ~= lead:sub(i, i) then break end
        pos0 = p
    end
    for i = 1, #trail do
        local q = doc:nextChar(pos1)
        if not q or Anchor.normalize(doc:text(pos1, q)):gsub("%s", "") ~= trail:sub(i, i) then break end
        pos1 = q
    end
    return pos0, pos1
end

--[[--
Places one highlight record in `doc`.

@param rec the at.stim.reading.highlight record value
@param doc document interface (see module doc)
@param opts { same_file = true when the local file hash equals the record's }
@treturn table { status = "placed", pos0, pos1, method = "xpointer"|"search",
  similarity, ambiguous, hits, scans } or { status = "unplaced", reason, scans,
  similarity (best seen) }
]]
function Anchor.locate(rec, doc, opts)
    opts = opts or {}
    local words, seps = Anchor.words(rec.text)
    if #words == 0 then return { status = "unplaced", reason = "no words in passage", scans = 0 } end

    -- Same file: trust the stored xpointers, after a cheap check that they
    -- still hold the passage (a crengine DOM change could move them).
    local loc = rec.locator
    if opts.same_file and loc and loc.format == "koreader-xpointer"
            and loc.start and loc["end"] and doc:isValid(loc.start, loc["end"]) then
        local sim = Anchor.similarity(words, Anchor.words(doc:text(loc.start, loc["end"])))
        if sim >= Anchor.MIN_SIMILARITY then
            return { status = "placed", pos0 = loc.start, pos1 = loc["end"], method = "xpointer",
                     similarity = sim, scans = 0 }
        end
    end
    local ctx = rec.context or {}
    local prefix = Anchor.words(ctx.prefix or "")
    local suffix = Anchor.words(ctx.suffix or "")

    local scans, best_sim = 0, nil
    local found_any = false
    for _, cand in ipairs(Anchor.candidates(words, seps, rec.text)) do
        if scans >= Anchor.MAX_ATTEMPTS then break end
        scans = scans + 1
        local hits = doc:findAll(cand.pattern) or {}
        if #hits > 0 then
            found_any = true
            local expect_before = concat(prefix, slice(words, 1, cand.first - 1))
            local expect_after = concat(slice(words, cand.last + 1, #words), suffix)
            for _, h in ipairs(hits) do
                h.score = Anchor.contextScore(expect_before, expect_after, h)
            end
            table.sort(hits, function(a, b) return a.score > b.score end)
            -- Try the best-scoring hits; a near-tie is reported as ambiguous.
            for i = 1, math.min(#hits, 3) do
                local h = hits[i]
                local pos0, pos1 = extend(doc, words, cand, h)
                local got = Anchor.words(doc:text(pos0, pos1))
                local sim = Anchor.similarity(words, got)
                if not best_sim or sim > best_sim then best_sim = sim end
                if sim >= Anchor.MIN_SIMILARITY then
                    local ambiguous = #hits > 1 and i == 1 and (hits[1].score - hits[2].score) < 0.1 or nil
                    pos0, pos1 = widen(doc, rec.text, pos0, pos1)
                    return {
                        status = "placed", pos0 = pos0, pos1 = pos1, method = "search",
                        similarity = sim, ambiguous = ambiguous, hits = #hits, scans = scans,
                        anchor = cand.pattern,
                    }
                end
            end
        end
    end
    return {
        status = "unplaced",
        reason = found_any and "only partial matches" or "passage not found",
        similarity = best_sim, scans = scans,
    }
end

-- crengine adapter ------------------------------------------------------------

-- crengine search flags (see readersearch.lua): MATCH_ACROSS_TEXT_NODES,
-- COLLAPSE_CONSECUTIVE_SPACES, IGNORE_FORMAT_CONTROL_CHARS, FOLD_APOSTROPHES,
-- FOLD_HYPHENS, MATCH_WHOLE_WORDS. The Unicode normalisation flags are left out:
-- patterns are plain words, and they make every scan noticeably slower.
Anchor.CRE_SEARCH_FLAGS = 0x0001 + 0x0002 + 0x0010 + 0x0040 + 0x0080 + 0x1000

--- Wraps a CreDocument in the interface `Anchor.locate` expects.
function Anchor.creAdapter(document, max_hits)
    local a = {}
    function a:findAll(pattern)
        local res = document:findAllText(pattern, true, Anchor.CONTEXT_WORDS, max_hits or 1000, false, Anchor.CRE_SEARCH_FLAGS)
        local out = {}
        for i, r in ipairs(res or {}) do
            out[i] = { start = r.start, stop = r["end"], before = r.prev_text, after = r.next_text }
        end
        return out
    end
    function a:text(xp0, xp1) return document:getTextFromXPointers(xp0, xp1) or "" end
    function a:nextWordEnd(xp) return document:getNextVisibleWordEnd(xp) end
    function a:prevWordStart(xp) return document:getPrevVisibleWordStart(xp) end
    function a:prevChar(xp) return document:getPrevVisibleChar(xp) end
    function a:nextChar(xp) return document:getNextVisibleChar(xp) end
    function a:isValid(xp0, xp1)
        local ok, cmp = pcall(document.compareXPointers, document, xp0, xp1)
        return ok and cmp ~= nil and cmp >= 0
    end
    return a
end

return Anchor

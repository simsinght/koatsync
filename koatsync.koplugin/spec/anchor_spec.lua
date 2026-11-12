-- Re-anchoring against a fake document. Run with ./run.sh
local Anchor = require("anchor")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

--[[
A stand-in for crengine over a plain string. XPointers are byte offsets
(start inclusive, stop exclusive). Search behaves like crengine's with the
flags anchor.lua uses: case-insensitive, whole words, ’ and ' folded, never
across a paragraph break ("\n"). Word walking treats ’s as its own word, as
crengine does.
]]
local function fakeDoc(text)
    -- folded copy with a map back to byte offsets in `text`
    local folded, map = {}, {}
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        local len = 1
        if c:byte() >= 0xC0 then
            len = c:byte() >= 0xF0 and 4 or c:byte() >= 0xE0 and 3 or 2
        end
        local ch = text:sub(i, i + len - 1)
        local f = ch == "’" and "'" or ch:lower()
        for k = 1, #f do folded[#folded + 1] = f:sub(k, k); map[#map + 1] = i end
        i = i + len
    end
    map[#map + 1] = #text + 1
    folded = table.concat(folded)
    local doc = { scans = 0 }
    -- typographic punctuation is multi-byte; everything else non-ASCII is a letter
    local PUNCT = { ["’"] = true, ["‘"] = true, ["“"] = true, ["”"] = true, ["—"] = true, ["…"] = true }
    local function charAt(p)
        local b = text:byte(p)
        if not b then return "" end
        if b >= 0x80 then
            while p > 1 and b < 0xC0 do p = p - 1; b = text:byte(p) end
            local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
            return text:sub(p, p + len - 1)
        end
        return text:sub(p, p)
    end
    local function isWordAt(p)
        local ch = charAt(p)
        if ch == "" or PUNCT[ch] then return false end
        return ch:match("^[%w\128-\255]") ~= nil
    end
    function doc:findAll(pattern)
        self.scans = self.scans + 1
        local out, from = {}, 1
        while true do
            local s, e = folded:find(pattern, from, true)
            if not s then break end
            local okb = s == 1 or not folded:sub(s - 1, s - 1):match("[%w']")
            local oka = e == #folded or not folded:sub(e + 1, e + 1):match("[%w]")
            if okb and oka then
                local bs, be = map[s], map[e + 1]
                out[#out + 1] = {
                    start = bs, stop = be,
                    before = text:sub(math.max(1, bs - 120), bs - 1),
                    after = text:sub(be, be + 119),
                }
            end
            from = s + 1
        end
        return out
    end
    function doc:text(a, b) return text:sub(a, b - 1) end
    -- a word: letters/digits; "’s" after a word is a word of its own
    function doc:nextWordEnd(xp)
        local p = xp
        while p <= #text and not isWordAt(p) do p = p + 1 end
        if p > #text then return nil end
        while p <= #text and isWordAt(p) do p = p + 1 end
        return p
    end
    function doc:prevWordStart(xp)
        local p = xp - 1
        while p >= 1 and not isWordAt(p) do p = p - 1 end
        if p < 1 then return nil end
        while p > 1 and isWordAt(p - 1) do p = p - 1 end
        return p
    end
    function doc:nextChar(xp)
        if xp > #text then return nil end
        local b = text:byte(xp)
        return xp + (b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1)
    end
    function doc:prevChar(xp)
        if xp <= 1 then return nil end
        local p = xp - 1
        while p > 1 and text:byte(p) >= 0x80 and text:byte(p) < 0xC0 do p = p - 1 end
        return p
    end
    function doc:isValid(a, b) return type(a) == "number" and type(b) == "number" and a <= b end
    return doc
end

-- normalisation ----------------------------------------------------------------
check("normalize quotes", Anchor.normalize("“Hi,” she’s") == "\"Hi,\" she's", Anchor.normalize("“Hi,” she’s"))
check("normalize dash/ellipsis", Anchor.normalize("a—b… c") == "a-b... c")
check("normalize invisible", Anchor.normalize("astonish\u{AD}ment\u{FEFF}—x") == "astonishment-x")
check("normalize spaces", Anchor.normalize("a \u{00A0}  b\n \n c") == "a b\nc", Anchor.normalize("a \u{00A0}  b\n \n c"))
check("normalize ligature", Anchor.normalize("\u{FB01}ne") == "fine")

local w, seps = Anchor.words("“Your plan is a good one,” replied Elizabeth’s—friend")
check("words", table.concat(w, "|") == "your|plan|is|a|good|one|replied|elizabeth's|friend", table.concat(w, "|"))
check("seps", seps[2] == " " and seps[7] == ",\" " and seps[9] == "-", seps[7])
check("hyphen splits", table.concat(Anchor.words("three-and-twenty"), " ") == "three and twenty")
check("edge apostrophes", table.concat(Anchor.words("‘’Tis said’"), " ") == "tis said")

check("lcs", Anchor.lcs({ "a", "b", "c", "d" }, { "a", "c", "d", "e" }) == 3)
check("similarity", math.abs(Anchor.similarity({ "a", "b" }, { "a", "b", "c", "d" }) - 0.5) < 1e-9)

-- candidates -------------------------------------------------------------------
local cw, cs = Anchor.words("“Your plan is a good one,” replied Elizabeth, “where nothing is in question but the desire of being well married.”")
local cands = Anchor.candidates(cw, cs)
check("first candidate", cands[1].pattern == "your plan is a good one", cands[1].pattern)
check("second candidate is the tail", cands[2].pattern == "the desire of being well married", cands[2] and cands[2].pattern)
local sw, ss = Anchor.words("replied Elizabeth")
local sc = Anchor.candidates(sw, ss)
check("short passage", #sc == 1 and sc[1].pattern == "replied elizabeth")
local pw, ps = Anchor.words("“No,” said he; “yes—no!”")
check("all-punctuation passage still gets a candidate", #Anchor.candidates(pw, ps) >= 1)

-- a book -----------------------------------------------------------------------
local book = table.concat({
    "Chapter 1",
    "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
    "“That is very true,” replied Elizabeth, “and I could easily forgive his pride, if he had not mortified mine.”",
    "“I suspected as much,” replied Elizabeth. “But how did he account for it?”",
    "“In vain have I struggled. It will not do. My feelings will not be repressed. You must allow me to tell you how ardently I admire and love you.”",
    "Elizabeth’s astonishment was beyond expression. She stared, coloured, doubted, and was silent.",
    "“Neither duty, nor honour, nor gratitude,” replied Elizabeth, “have any possible claim on me, in the present instance.”",
    "Mr. Bennet was so odd a mixture of quick parts, sarcastic humour, reserve, and caprice, that the experience of three and twenty years had been insufficient to make his wife understand his character.",
    "“Indeed,” replied Elizabeth, “I am heartily sorry for him.”",
}, "\n")

local function rec(text, prefix, suffix)
    return { text = text, context = { prefix = prefix, suffix = suffix } }
end
local function placedText(doc, r)
    return r.status == "placed" and doc:text(r.pos0, r.pos1) or nil
end

-- repeated short phrase, disambiguated by context
local d = fakeDoc(book)
local r = Anchor.locate(rec("replied Elizabeth", "you have heard the rest. “I suspected as much,”", ". “But how did he account for it?”"), d)
check("repeated phrase placed", r.status == "placed", r.reason)
check("repeated phrase picks the right one", r.status == "placed" and book:sub(1, r.pos0 - 1):match("I suspected as much,” $") ~= nil)
check("repeated phrase one scan", r.scans == 1 and r.hits == 4, r.scans)

-- full sentence; the source edition had a comma the target lacks
d = fakeDoc(book)
r = Anchor.locate(rec("It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."), d)
check("sentence placed", r.status == "placed", r.reason)
check("sentence span", placedText(d, r) == "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.", placedText(d, r))

-- straight quotes and -- in the record, curly quotes and a word change in the book
d = fakeDoc(book)
r = Anchor.locate(rec("\"Neither duty, nor honour, nor gratitude,\" replied Elizabeth, \"has any possible claim on me, in the present instance.\""), d)
check("quotes/word change placed", r.status == "placed", r.reason)
check("quotes/word change span", placedText(d, r) == "“Neither duty, nor honour, nor gratitude,” replied Elizabeth, “have any possible claim on me, in the present instance.”", placedText(d, r))
check("quotes/word change similarity < 1", r.similarity and r.similarity < 1 and r.similarity >= Anchor.MIN_SIMILARITY, r.similarity)

-- multi-paragraph
d = fakeDoc(book)
r = Anchor.locate(rec("You must allow me to tell you how ardently I admire and love you.”\nElizabeth’s astonishment was beyond expression."), d)
check("multi-paragraph placed", r.status == "placed", r.reason)
check("multi-paragraph span", placedText(d, r) == "You must allow me to tell you how ardently I admire and love you.”\nElizabeth’s astonishment was beyond expression.", placedText(d, r))

-- hyphenation and a spelling change
d = fakeDoc(book)
r = Anchor.locate(rec("the experience of three-and-twenty years had been insufficient to make his wife understand his character. Her mind was less difficult to develope."), d)
check("trailing text missing in target still placed or reported",
    r.status == "unplaced" or (r.similarity or 0) >= Anchor.MIN_SIMILARITY)
r = Anchor.locate(rec("the experience of three-and-twenty years had been insufficient to make his wife understand his character."), d)
check("hyphenated words placed", r.status == "placed" and placedText(d, r) == "the experience of three and twenty years had been insufficient to make his wife understand his character.", placedText(d, r))

-- possessive at the end: the whole word, not just "Elizabeth"
r = Anchor.locate(rec("and love you.” Elizabeth’s"), d)
check("possessive end", placedText(d, r) == "and love you.”\nElizabeth’s", placedText(d, r))

-- altered in the middle: anchors match, the words between do not
d = fakeDoc(book)
r = Anchor.locate(rec("In vain have I struggled. The badgers of Netherfield held their annual parliament beneath the oak. I admire and love you."), d)
check("altered passage unplaced", r.status == "unplaced", r.status)
check("altered passage reason", r.reason == "only partial matches", r.reason)
check("altered passage bounded scans", r.scans <= Anchor.MAX_ATTEMPTS, r.scans)

-- not in the book at all
d = fakeDoc(book)
r = Anchor.locate(rec("The badgers of Netherfield held their annual parliament."), d)
check("missing passage unplaced", r.status == "unplaced" and r.reason == "passage not found", r.reason)

-- same file: trust the locator
d = fakeDoc(book)
local s0 = book:find("It is a truth", 1, true)
r = Anchor.locate({ text = "It is a truth", locator = { format = "koreader-xpointer", start = s0, ["end"] = s0 + 13 } }, d, { same_file = true })
check("same file uses xpointers", r.status == "placed" and r.method == "xpointer" and r.pos0 == s0 and d.scans == 0, r.method)
r = Anchor.locate({ text = "The badgers of Netherfield held their annual parliament", locator = { format = "koreader-xpointer", start = s0, ["end"] = s0 + 60 } }, d, { same_file = true })
check("same file but text differs: searched, unplaced", r.status == "unplaced" and r.scans > 0)
r = Anchor.locate({ text = "replied Elizabeth, “and I could", locator = { format = "koreader-xpointer", start = "bad", ["end"] = 9 } }, d, { same_file = true })
check("same file with broken xpointers falls back to search", r.status == "placed" and r.method == "search")

-- punctuation every word: the passage itself is the pattern
d = fakeDoc(book .. "\nThe wife of Mr. Darcy must have such sources. Mr Darcy smiled.")
r = Anchor.locate(rec("Mr. Darcy", "misfortunes,” replied Elizabeth. “But the wife of", "must have such sources"), d)
check("Mr. Darcy placed", r.status == "placed" and r.anchor == "mr. darcy" and d:text(r.pos0, r.pos1) == "Mr. Darcy", r.anchor)

print(string.format("anchor: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

-- Book lexicon – data: one lexicon per book.
-- Every book has a folder <koreader>/lexicon/Books/<Author - Title>/ (German: Bücher/)
-- with a Markdown file lexicon.md and the pictures of its cards.
-- The Markdown file is the only storage, so the cards can be edited on a PC.

local _ = require("gettext")
local T = require("ffi/util").template
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = {}

-- ---- switch and language -------------------------------------------------------------

local plugin

function M.configure(value)
    plugin = value
end

--- The lexicon is on (ZenOS setting "Book lexicon").
function M.enabled()
    return plugin ~= nil and type(plugin.config) == "table" and type(plugin.config.features) == "table"
        and plugin.config.features.book_lexicon == true
end

-- German KOReader: the folder of the book lexicons is called "Bücher" (kept for existing lexicons).
local function german()
    local gs = rawget(_G, "G_reader_settings")
    local l = gs and gs:readSetting("language")
    return type(l) == "string" and l:sub(1, 2) == "de"
end


-- ---- kinds of cards -------------------------------------------------------------------

-- in the order of the lists: people, objects, groups, places, other
M.KINDS = { "Person", "Object", "Group", "Place", "Other" }
local KIND_RANK = { Person = 1, Object = 2, Group = 3, Place = 4, Other = 5 }
-- labels are built on demand, so they follow the current UI language
local function kind_texts()
    return { Person = _("Person"), Object = _("Object"), Group = _("Group"), Place = _("Place"), Other = _("Other") }
end
local function kind_plurals()
    return { Person = _("People"), Object = _("Objects"), Group = _("Groups"), Place = _("Places"), Other = _("Other") }
end
-- words accepted after "Kind:" in the file
local KIND_WORDS = {
    person = "Person", people = "Person", figur = "Person", character = "Person",
    object = "Object", gegenstand = "Object", item = "Object", thing = "Object",
    group = "Group", gruppe = "Group", faction = "Group", fraktion = "Group",
    place = "Place", ort = "Place", location = "Place",
    other = "Other", sonstiges = "Other", andere = "Other",
}

function M.kindRank(card) return KIND_RANK[card.kind] or 5 end
function M.kindText(k) local t = kind_texts() return t[k] or t.Other end
function M.kindPlural(k) local t = kind_plurals() return t[k] or t.Other end

-- ---- roles of people ("Role: Main" on a card; the file keeps the English word) ------------

M.ROLES = { "Narrator", "Main", "Supporting", "Antagonist" }
local ROLE_WORDS = {
    narrator = "Narrator", ["erzähler"] = "Narrator", main = "Main", hauptfigur = "Main",
    supporting = "Supporting", nebenfigur = "Supporting", side = "Supporting",
    antagonist = "Antagonist", gegenspieler = "Antagonist",
}

function M.isRoleKey(k) local l = tostring(k or ""):lower() return l == "role" or l == "rolle" end

--- One of M.ROLES for a known role word (English or German), else the text as written.
function M.roleKey(v)
    v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return ROLE_WORDS[v:lower()] or v
end

function M.roleText(v)
    local t = { Narrator = _("Narrator"), Main = _("Main"), Supporting = _("Supporting"), Antagonist = _("Antagonist") }
    v = M.roleKey(v)
    return t[v] or v
end

function M.roleOf(card)
    for _i, f in ipairs(card.facts or {}) do
        if M.isRoleKey(f.k) then return M.roleKey(f.v) end
    end
end

--- A fact as shown on a card ("Role: Main" in the reader's language).
function M.factText(f)
    if M.isRoleKey(f.k) then return T(_("Role: %1"), M.roleText(f.v)) end
    return f.k .. ": " .. f.v
end

-- ---- settings (kept in KOReader's settings) ---------------------------------------------

-- relation types: { name, name on the other card }
local DEFAULT_TYPES = {
    { "Family", "Family" }, { "Friend", "Friend" }, { "Enemy", "Enemy" },
    { "Partner", "Partner" }, { "Member of", "Has member" },
}
-- display names of the standard relation types (own types are shown as typed)
local function type_texts()
    return { ["Family"] = _("Family"), ["Friend"] = _("Friend"), ["Enemy"] = _("Enemy"), ["Partner"] = _("Partner"),
        ["Member of"] = _("Member of"), ["Has member"] = _("Has member") }
end
-- the kinds a relation type usually points to (they come first in the card choice)
local REL_KINDS = {
    ["Family"] = { Person = true }, ["Friend"] = { Person = true }, ["Partner"] = { Person = true },
    ["Has member"] = { Person = true }, ["Enemy"] = { Person = true, Group = true },
    ["Member of"] = { Group = true },
}

function M.settings()
    if M._settings then return M._settings end
    local gs = rawget(_G, "G_reader_settings")
    local t = gs and gs:readSetting("book_lexicon")
    if type(t) ~= "table" then t = {} end
    M._settings = t
    if type(t.rel_types) ~= "table" or #t.rel_types == 0 then M.resetRelTypes() end
    return t
end

function M.saveSettings()
    local gs = rawget(_G, "G_reader_settings")
    if gs and M._settings then gs:saveSetting("book_lexicon", M._settings) end
end

function M.setting(key, default)
    local v = M.settings()[key]
    if v == nil then return default end
    return v
end

function M.setSetting(key, value)
    M.settings()[key] = value
    M.saveSettings()
end

function M.relTypes() return M.settings().rel_types end

function M.resetRelTypes()
    local list = {}
    for _i, p in ipairs(DEFAULT_TYPES) do list[#list + 1] = { p[1], p[2] } end
    M.settings().rel_types = list
    M.saveSettings()
end

--- { kind = true } for a relation type, or nil (own types: no preference)
function M.relKinds(t) return t and REL_KINDS[t] or nil end

--- Display text of a relation type (the standard names are translated).
function M.relText(t)
    return type_texts()[t] or t
end

--- The type the other card gets.
function M.counterpart(t)
    for _i, p in ipairs(M.relTypes()) do
        if p[1] == t then return p[2] end
        if p[2] == t then return p[1] end
    end
    return t
end

-- ---- files and folders --------------------------------------------------------------------

local function isDir(p) return lfs.attributes(p, "mode") == "directory" end
local function isFile(p) return lfs.attributes(p, "mode") == "file" end

function M.root() return require("datastorage"):getDataDir() .. "/lexicon" end

--- The folder of all book lexicons ("Books", or "Bücher" when that one exists or KOReader speaks German).
local function booksDir()
    local root = M.root()
    for _i, n in ipairs({ "Books", "Bücher" }) do
        if isDir(root .. "/" .. n) then return root .. "/" .. n end
    end
    return root .. "/" .. (german() and "Bücher" or "Books")
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Text without soft hyphens.
function M.clean(s) return (tostring(s or ""):gsub("\194\173", "")) end

function M.safeName(s)
    s = M.clean(s):gsub("[/\\:%*%?\"<>|]", "_")
    s = trim(s):gsub("%.+$", "")
    return s ~= "" and s or "_"
end

-- ---- Markdown -------------------------------------------------------------------------------
--   ## Name
--   Kind: Person
--   Also: Other name, Nickname
--   Picture: name.jpg
--   Rank: Sergeant          (facts)
--   → Friend: Other name    (relations)
--   - a note — *p. 12*
--   - > a quote from the book — *p. 27*

local RESERVED = {
    kind = "kind", art = "kind",
    also = "also", auch = "also", ["other names"] = "also", ["weitere namen"] = "also", aliases = "also",
    picture = "picture", bild = "picture", image = "picture",
}

--- "→ Enemy: Orks" (what follows the name in [ ] or { } is kept as it is)
local function parseRel(line)
    local rest = line:match("^→%s*(.*)$") or line:match("^%->%s*(.*)$")
    if not rest then return nil end
    local extra = ""
    rest = rest:gsub("%s*([%[{].*)$", function(e) extra = " " .. e return "" end)
    local typ, target = rest:match("^(.-):%s*(.+)$")
    typ, target = trim(typ), trim(target)
    if typ == "" or target == "" then return nil end
    return { type = typ, target = target, extra = extra ~= "" and extra or nil }
end

function M.parse(text)
    local cards, title = {}, nil
    local card, note
    local function finishNote()
        if note then
            local body, src = note.text:match("^(.-)%s+—%s+%*([^*]+)%*%s*$")
            if body then note.text, note.src = body, src end
            note.text = trim(note.text)
            note = nil
        end
    end
    text = tostring(text or ""):gsub("\r\n", "\n")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local h2 = line:match("^##%s+(.-)%s*$")
        local h1 = not h2 and line:match("^#%s+(.-)%s*$")
        if h2 then
            finishNote()
            card = { name = M.clean(h2), also = {}, kind = "Other", facts = {}, notes = {}, rels = {} }
            cards[#cards + 1] = card
        elseif h1 then
            finishNote()
            if not card then title = M.clean(h1) end
        elseif card then
            local item = line:match("^[-*]%s+(.*)$")
            local rel = not item and parseRel(line)
            if rel then
                finishNote()
                card.rels[#card.rels + 1] = rel
            elseif item then
                finishNote()
                -- "- 📌 …" (a pinned note written elsewhere) keeps its pin
                local pinned = item:match("^📌%s*(.*)$")
                if pinned then item = pinned end
                local quote = item:match("^>%s*(.*)$")
                note = { text = quote or item, passage = quote ~= nil, pin = pinned and true or nil }
                card.notes[#card.notes + 1] = note
            elseif note and line:match("^%s%s+%S") then
                note.text = note.text .. "\n" .. trim(line)
            elseif line:match("^%s*$") or line:match("^%s*<!%-%-") then
                finishNote()
            else
                finishNote()
                local key, val = line:match("^([^:]+):%s*(.*)$")
                local r = key and #key <= 32 and RESERVED[trim(key):lower()]
                -- "Art: Planet" is a fact; only a real kind ("Art: Person") sets the kind
                if r == "kind" and not KIND_WORDS[trim(val):lower()] then r = nil end
                if r == "kind" then
                    card.kind = KIND_WORDS[trim(val):lower()]
                elseif r == "also" then
                    for a in val:gmatch("[^,;]+") do
                        if trim(a) ~= "" then card.also[#card.also + 1] = trim(a) end
                    end
                elseif r == "picture" then
                    card.picture = trim(val) ~= "" and trim(val) or nil
                elseif key and #key <= 32 and not key:match("^%s") then
                    card.facts[#card.facts + 1] = { k = trim(key), v = trim(val) }
                else
                    -- a free line of text: a note
                    note = { text = trim(line), passage = false }
                    card.notes[#card.notes + 1] = note
                end
            end
        end
    end
    finishNote()
    return cards, title
end

function M.serialize(lex)
    local out = {}
    out[#out + 1] = "# " .. (lex.title or _("Lexicon"))
    out[#out + 1] = "<!-- Book lexicon. One \"## Name\" per card. \"Key: value\" lines are facts,"
        .. " \"- \" lines are notes, \"- > \" lines are quotes from the book,"
        .. " \"→ Type: Name\" lines are relations. -->"
    for _i, c in ipairs(lex.cards) do
        out[#out + 1] = ""
        out[#out + 1] = "## " .. c.name
        out[#out + 1] = "Kind: " .. (c.kind or "Other")
        if #c.also > 0 then out[#out + 1] = "Also: " .. table.concat(c.also, ", ") end
        if c.picture then out[#out + 1] = "Picture: " .. c.picture end
        for _j, f in ipairs(c.facts) do
            if f.k ~= "" and f.v ~= "" then out[#out + 1] = f.k .. ": " .. f.v end
        end
        for _j, r in ipairs(c.rels) do
            out[#out + 1] = "→ " .. r.type .. ": " .. r.target .. (r.extra or "")
        end
        if #c.notes > 0 then
            out[#out + 1] = ""
            for _j, n in ipairs(c.notes) do
                local t = trim(n.text):gsub("\n", "\n  ")
                if n.src and n.src ~= "" then t = t .. " — *" .. n.src .. "*" end
                out[#out + 1] = "- " .. (n.pin and "📌 " or "") .. (n.passage and "> " or "") .. t
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-- ---- loading and saving -------------------------------------------------------------------

local cache = {}   -- file -> lexicon (read again when the file was changed on the PC)

local function openDir(dir, title)
    local file = dir .. "/lexicon.md"
    local mtime = lfs.attributes(file, "modification")
    local lex = cache[file]
    if lex and lex.mtime == mtime then return lex end
    lex = { dir = dir, file = file, cards = {}, mtime = mtime }
    local f = mtime and io.open(file, "r")
    if f then
        lex.cards, lex.title = M.parse(f:read("*a"))
        f:close()
    end
    lex.title = lex.title or title
    cache[file] = lex
    return lex
end

function M.save(lex)
    -- changed on a PC since it was read: keep that version, show it on the next open
    local mtime = lfs.attributes(lex.file, "modification")
    if mtime and lex.mtime ~= mtime then
        cache[lex.file] = nil
        local UIManager = require("ui/uimanager")
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("The lexicon file was changed elsewhere. Open the lexicon again to see that version."),
        })
        return false
    end
    if not util.makePath(lex.dir) then return false end
    -- the previous version stays as lexicon.md.bak
    if mtime then ffiutil.copyFile(lex.file, lex.file .. ".bak") end
    -- write a temporary file, then replace: a power loss never leaves half a file
    local tmp = lex.file .. ".zen-write"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(M.serialize(lex)) and f:flush() and ffiutil.fsyncOpenedFile(f, true) == true
    f:close()
    if not (ok and os.rename(tmp, lex.file)) then
        os.remove(tmp)
        return false
    end
    lex.mtime = lfs.attributes(lex.file, "modification")
    lex.index = nil
    if lex.book_settings then
        lex.book_settings:saveSetting("zen_lexicon_dir", lex.dir)
        lex.book_settings = nil
    end
    -- the status bar box shows the number of cards
    if M.on_change then M.on_change() end
    return true
end

-- ---- the open book ----------------------------------------------------------------------------

function M.inBook(ui) return ui and ui.document and true or false end

--- "Author - Title" of the open book (the name of its lexicon folder).
local function bookKey(ui)
    local props = ui and ui.doc_props or {}
    local title = M.clean(props.display_title or props.title or "")
    if title == "" and ui and ui.document and ui.document.file then
        title = ui.document.file:match("([^/]+)%.%w+$") or "?"
    end
    local author = props.authors and M.clean(tostring(props.authors):match("^[^\n]+") or "") or ""
    return (author ~= "" and (author .. " - ") or "") .. title
end

--- The lexicon of the open book.
-- The folder is remembered in the book's settings (zen_lexicon_dir), so the lexicon stays
-- with the book when its title or author is changed later.
function M.bookLex(ui)
    local settings = ui.doc_settings
    local dir = settings and settings:readSetting("zen_lexicon_dir")
    if dir and isFile(dir .. "/lexicon.md") then return openDir(dir, bookKey(ui)) end
    local key = bookKey(ui)
    local lex = openDir(booksDir() .. "/" .. M.safeName(key), key)
    if settings and lex.mtime then
        settings:saveSetting("zen_lexicon_dir", lex.dir)
    elseif settings then
        lex.book_settings = settings -- remembered with the first save
    end
    return lex
end

--- The cards of the book: { { card =, lex = }, ... }
function M.bookCards(ui)
    if not M.inBook(ui) then return {} end
    local lex = M.bookLex(ui)
    local out = {}
    for _i, c in ipairs(lex.cards) do out[#out + 1] = { card = c, lex = lex } end
    return out
end

--- "p. 12": the given page, or the page shown now.
function M.pageLabel(ui, at_page)
    if not M.inBook(ui) then return nil end
    local page = at_page
    if not page and ui.getCurrentPage then
        local ok, p = pcall(ui.getCurrentPage, ui)
        if ok then page = p end
        -- the printed page numbers of the book, when it has them
        local pm = ui.pagemap
        if pm and pm.has_pagemap and pm.getCurrentPageLabel then
            local okl, lbl = pcall(pm.getCurrentPageLabel, pm, true)
            if okl and lbl then page = lbl end
        end
    end
    return page and T(_("p. %1"), page) or nil
end

-- ---- names ------------------------------------------------------------------------------------

local Utf8Proc = require("ffi/utf8proc")

local function lower(s)
    return Utf8Proc.lowercase(s) or s:lower()
end

-- quotes and punctuation around a word
local PUNCT = { "„", "“", "”", "‚", "‘", "’", "»", "«", "›", "‹", "\"", "'", "(", ")", "[", "]",
    ",", ".", ";", ":", "!", "?", "–", "—", "-" }

local function escape(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end

--- A name for comparing: lower case, without the punctuation around it.
function M.norm(s)
    s = lower(M.clean(s):gsub("\n", " "))
    local changed = true
    while changed do
        changed = false
        s = trim(s)
        for _i, p in ipairs(PUNCT) do
            if s:sub(1, #p) == p then s = s:sub(#p + 1) changed = true end
            if #s >= #p and s:sub(-#p) == p then s = s:sub(1, -#p - 1) changed = true end
        end
    end
    return (s:gsub("%s+", " "))
end

--- Text as " word word " (for finding whole words).
local function words(text) return " " .. M.norm(text):gsub("[%p]", " ") .. " " end

--- "Cains", "Cain's", "Cainen" … also find "Cain".
local function variants(n)
    local out = { n }
    local base = n:match("^(.-)['’]s$")
    if base then out[#out + 1] = base end
    if #n > 3 and n:sub(-1) == "s" then out[#out + 1] = n:sub(1, -2) end
    if #n > 4 and n:sub(-2) == "es" then out[#out + 1] = n:sub(1, -3) end
    if #n > 4 and (n:sub(-1) == "n" or n:sub(-1) == "e") then out[#out + 1] = n:sub(1, -2) end
    return out
end

function M.cardNames(card)
    local out = { card.name }
    for _i, a in ipairs(card.also) do out[#out + 1] = a end
    return out
end

--- The names of a lexicon prepared for finding them, built once per lexicon (again after a save):
--- { names = { [normalised name] = card }, cards = { { card =, words = { [word] = true }, texts = { " name " } } } }
local function index(lex)
    if lex.index then return lex.index end
    local idx = { names = {}, cards = {} }
    for _i, card in ipairs(lex.cards) do
        local entry = { card = card, words = {}, texts = {} }
        for _j, name in ipairs(M.cardNames(card)) do
            local n = M.norm(name)
            if idx.names[n] == nil then idx.names[n] = card end
            local plain = n:gsub("[%p]", " ")
            for w in plain:gmatch("%S+") do entry.words[w] = true end
            if #plain >= 3 then entry.texts[#entry.texts + 1] = " " .. escape(plain) end
        end
        idx.cards[#idx.cards + 1] = entry
    end
    lex.index = idx
    return idx
end

--- The card whose name (or other name) is exactly this word.
function M.lookup(ui, word)
    local n = M.norm(word or "")
    if n == "" or not M.inBook(ui) then return nil end
    local lex = M.bookLex(ui)
    local names = index(lex).names
    for _i, v in ipairs(variants(n)) do
        if names[v] then return names[v], lex end
    end
end

--- Cards for words that are only part of a name: "Nev" -> Branne Nev, Agapito Nev.
--- More words narrow it down: every other word must be in the name or in the
--- card's notes and facts ("Kommandant Nev"). Titles and short words do not count.
--- Returns { { card =, lex = }, ... }
function M.partialLookup(ui, text)
    local TITLES = require("modules/reader/lexicon/titles")
    local list = {}
    for w in M.norm(text or ""):gsub("['’]s%f[%A]", ""):gsub("[%p]", " "):gmatch("%S+") do list[#list + 1] = w end
    if #list == 0 or #list > 4 then return {} end
    if not M.inBook(ui) then return {} end
    local lex = M.bookLex(ui)
    local out = {}
    for _i, entry in ipairs(index(lex).cards) do
        local card, in_name = entry.card, entry.words
        local hit, rest = false, {}
        for _j, w in ipairs(list) do
            if in_name[w] then
                if #w >= 3 and not TITLES[w] then hit = true end
            else
                rest[#rest + 1] = w
            end
        end
        if hit and #rest > 0 then
            local parts = {}
            for _j, n in ipairs(card.notes) do parts[#parts + 1] = n.text end
            for _j, f in ipairs(card.facts) do parts[#parts + 1] = f.k .. " " .. f.v end
            local all = words(table.concat(parts, " "))
            for _j, w in ipairs(rest) do
                if not all:find(" " .. escape(w), 1) then hit = false end
            end
        end
        if hit then out[#out + 1] = { card = card, lex = lex } end
    end
    return out
end

--- Cards whose names occur in a text (the page, a quote).
function M.cardsInText(ui, text)
    if not M.inBook(ui) then return {} end
    local lex = M.bookLex(ui)
    local t = words(text)
    local hits = {}
    for _i, entry in ipairs(index(lex).cards) do
        for _j, pattern in ipairs(entry.texts) do
            if t:find(pattern, 1) then
                hits[#hits + 1] = { card = entry.card, lex = lex }
                break
            end
        end
    end
    return hits
end

-- ---- cards --------------------------------------------------------------------------------------

--- The card with this name or other name.
function M.findCard(lex, name)
    local n = M.norm(name)
    for _i, c in ipairs(lex.cards) do
        if M.norm(c.name) == n then return c end
    end
    for _i, c in ipairs(lex.cards) do
        for _j, a in ipairs(c.also) do
            if M.norm(a) == n then return c end
        end
    end
end

function M.addCard(lex, name, kind)
    local c = M.findCard(lex, name)
    if c then return c end
    c = { name = M.clean(name), also = {}, kind = kind or "Other", facts = {}, notes = {}, rels = {} }
    lex.cards[#lex.cards + 1] = c
    M.save(lex)
    return c
end

function M.removeCard(lex, card)
    for i, c in ipairs(lex.cards) do
        if c == card then table.remove(lex.cards, i) M.save(lex) return true end
    end
end

--- Rename a card; the relations of the other cards follow.
function M.renameCard(lex, card, name)
    local old = M.norm(card.name)
    card.name = M.clean(name)
    for _i, c in ipairs(lex.cards) do
        for _j, r in ipairs(c.rels) do
            if M.norm(r.target) == old then r.target = card.name end
        end
    end
    M.save(lex)
end

--- The picture file of a card (JPG or PNG next to lexicon.md), or nil.
function M.picturePath(lex, card)
    if not card.picture then return nil end
    local p = card.picture:match("^/") and card.picture or (lex.dir .. "/" .. card.picture)
    if isFile(p) and p:lower():match("%.[jp][pn]e?g$") then return p end
end

--- What a card shows: { picture, facts, also, notes = { { note, card, lex, index }, ... } }
function M.cardView(card, lex)
    local v = { picture = M.picturePath(lex, card), facts = card.facts, also = card.also, notes = {} }
    for i, n in ipairs(card.notes) do v.notes[i] = { n, card, lex, i } end
    return v
end

-- ---- relations ------------------------------------------------------------------------------------

--- The card a relation points to (nil when there is no card of that name).
function M.relTarget(rel, lex) return M.findCard(lex, rel.target) end

local function hasRel(card, typ, target)
    for _i, r in ipairs(card.rels) do
        if r.type == typ and M.norm(r.target) == M.norm(target) then return true end
    end
end

--- Add a relation, and its counterpart on the other card.
function M.addRelation(lex, cardA, typ, cardB)
    if not hasRel(cardA, typ, cardB.name) then
        cardA.rels[#cardA.rels + 1] = { type = typ, target = cardB.name }
    end
    local ctyp = M.counterpart(typ)
    if not hasRel(cardB, ctyp, cardA.name) then
        cardB.rels[#cardB.rels + 1] = { type = ctyp, target = cardA.name }
    end
    M.save(lex)
end

--- Remove a relation and its counterpart.
function M.removeRelation(lex, cardA, rel)
    for i, r in ipairs(cardA.rels) do
        if r == rel then table.remove(cardA.rels, i) break end
    end
    local cardB = M.relTarget(rel, lex)
    if cardB then
        local ctyp = M.counterpart(rel.type)
        for i, r in ipairs(cardB.rels) do
            if r.type == ctyp and M.norm(r.target) == M.norm(cardA.name) then table.remove(cardB.rels, i) break end
        end
    end
    M.save(lex)
end

--- The relations of a card by type, in the order of the relation types:
--- { { type =, items = { { name =, card =, lex = }, ... } }, ... }
function M.relationsFor(card, lex)
    local groups, by_type = {}, {}
    for _i, rel in ipairs(card.rels) do
        local tc = M.relTarget(rel, lex)
        if tc then
            local g = by_type[rel.type]
            if not g then
                g = { type = rel.type, items = {} }
                by_type[rel.type] = g
                groups[#groups + 1] = g
            end
            g.items[#g.items + 1] = { name = tc.name, card = tc, lex = lex }
        end
    end
    local pos = {}
    for i, p in ipairs(M.relTypes()) do
        pos[p[1]] = pos[p[1]] or i * 2
        pos[p[2]] = pos[p[2]] or i * 2 + 1
    end
    table.sort(groups, function(a, b)
        local pa, pb = pos[a.type] or 999, pos[b.type] or 999
        if pa ~= pb then return pa < pb end
        return a.type < b.type
    end)
    return groups
end

--- A relation type was renamed: the relations in every book lexicon follow.
function M.renameRelType(old, new)
    if not old or not new or old == new then return end
    for _i, n in ipairs({ "Books", "Bücher" }) do
        local d = M.root() .. "/" .. n
        if isDir(d) then
            for entry in lfs.dir(d) do
                if entry ~= "." and entry ~= ".." and isFile(d .. "/" .. entry .. "/lexicon.md") then
                    local lex = openDir(d .. "/" .. entry, entry)
                    local changed = false
                    for _j, c in ipairs(lex.cards) do
                        for _k, r in ipairs(c.rels) do
                            if r.type == old then r.type = new changed = true end
                        end
                    end
                    if changed then M.save(lex) end
                end
            end
        end
    end
end

return M

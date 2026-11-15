-- Thoughtful Reading: the question list and which questions fit where.
-- Pure Lua (no KOReader modules), so it can be tested on its own.

local M = {}

M.SECTIONS = { "beginning", "middle", "end", "chapter" }
M.SECTION_TITLE = { beginning = "Beginning", middle = "Middle", ["end"] = "End", chapter = "Chapters", series = "Series" }
-- the parts a question can belong to (the question file and the editor)
M.EDIT_SECTIONS = { "beginning", "middle", "end", "chapter", "series" }
M.CATEGORIES = { "plot", "pov", "characters", "world", "themes", "style", "prediction", "personal" }
M.CATEGORY_TITLE = { plot = "Plot", pov = "Point of view", characters = "Characters", world = "World",
    themes = "Themes", style = "Style", prediction = "Prediction", personal = "Personal",
    highlight = "Your highlight", lexicon = "From your lexicon" }

-- Tags that mark a book as nonfiction: a part of the tag is enough for the
-- first list, the whole tag must match for the second ("Science-Fiction" and
-- "Kurzgeschichten" are novels).
M.NONFICTION_PART = { "nonfiction", "non-fiction", "sachbuch", "biograf", "biograph", "ratgeber", "self-help", "memoir" }
M.NONFICTION_EXACT = { "philosophie", "philosophy", "essay", "essays", "history", "geschichte", "science",
    "wissenschaft", "politik", "politics", "psychologie", "psychology" }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- a stable id for a question (its text)
function M.id(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("q%08x", h)
end

--- Parse the question file. Returns { {id, section, category, tags = {...}, text} }
function M.parse(text)
    local out = {}
    for line in (text or ""):gmatch("[^\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local sec, cat, tags, q = line:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if sec and trim(q) ~= "" then
                local t = {}
                for tag in tags:gmatch("[^,]+") do
                    tag = trim(tag):lower()
                    if tag ~= "" then t[#t + 1] = tag end
                end
                q = trim(q)
                out[#out + 1] = { id = M.id(q), section = trim(sec):lower(), category = trim(cat):lower(), tags = t, text = q }
            end
        end
    end
    return out
end

--- The question file for a list (one line per question, by part of the book).
function M.serialize(list)
    local out = {
        "# Thoughtful Reading – questions",
        "# One question per line:  part | category | tags | question",
        "#   part:     beginning, middle, end, chapter (any chapter end), series (start of volume 2 and later)",
        "#   category: plot, pov, characters, world, themes, style, prediction, personal",
        "#             (two questions at one stop come from different categories)",
        "#   tags:     empty = all novels; e.g. \"crime, thriller\" = only books with one of these tags",
        "#             (a part of the tag is enough); \"nonfiction\" = only nonfiction books",
        "",
    }
    for _i, sec in ipairs(M.EDIT_SECTIONS) do
        local any = false
        for _j, q in ipairs(list) do
            if q.section == sec then
                if not any then out[#out + 1] = "" out[#out + 1] = "# " .. (M.SECTION_TITLE[sec] or sec) any = true end
                out[#out + 1] = sec .. "|" .. (q.category or "") .. "|" .. table.concat(q.tags or {}, ", ") .. "|"
                    .. tostring(q.text):gsub("[\r\n|]+", " ")
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

function M.load(paths)
    for _i, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            local t = f:read("*a")
            f:close()
            local list = M.parse(t)
            if #list > 0 then return list, p end
        end
    end
    return {}, nil
end

--- The book's tags, lower case. keywords: the "keywords" metadata (lines or commas)
function M.bookTags(keywords)
    local out = {}
    for tag in tostring(keywords or ""):gmatch("[^\n,;]+") do
        tag = trim(tag):lower()
        if tag ~= "" then out[#out + 1] = tag end
    end
    return out
end

function M.isNonfiction(tags)
    for _i, t in ipairs(tags) do
        for _j, n in ipairs(M.NONFICTION_PART) do
            if t:find(n, 1, true) then return true end
        end
        for _j, n in ipairs(M.NONFICTION_EXACT) do
            if t == n then return true end
        end
    end
    return false
end

--- Does the question fit a book with these tags?
function M.fits(q, tags, nonfiction)
    local wants_nf = false
    local genre = {}
    for _i, t in ipairs(q.tags) do
        if t == "nonfiction" then wants_nf = true else genre[#genre + 1] = t end
    end
    if wants_nf ~= nonfiction then return false end
    if #genre == 0 then return true end
    for _i, g in ipairs(genre) do
        for _j, t in ipairs(tags) do
            if t:find(g, 1, true) then return true end
        end
    end
    return false
end

--- Pick up to n questions for a stop.
--- ctx: { section = "beginning"|"middle"|"end"|"chapter", tags, nonfiction, series_volume,
---        answered = {id=true}, shown = {id=true}, exclude = {id=true}, random = function(n) }
--- Questions of the section first (series questions at the beginning of a later
--- volume), then the short chapter questions; one per category while possible;
--- never an answered one; ones not shown yet before ones shown before.
function M.pick(list, ctx, n)
    local rnd = ctx.random or math.random
    local function pool(section)
        local fresh, seen = {}, {}
        for _i, q in ipairs(list) do
            if q.section == section and M.fits(q, ctx.tags or {}, ctx.nonfiction)
                and not (ctx.answered or {})[q.id] and not (ctx.exclude or {})[q.id] then
                if (ctx.shown or {})[q.id] then seen[#seen + 1] = q else fresh[#fresh + 1] = q end
            end
        end
        -- shuffle each
        for _k, t in ipairs({ fresh, seen }) do
            for i = #t, 2, -1 do
                local j = rnd(i)
                t[i], t[j] = t[j], t[i]
            end
        end
        local all = {}
        for _i, q in ipairs(fresh) do all[#all + 1] = q end
        for _i, q in ipairs(seen) do all[#all + 1] = q end
        return all
    end
    local order = {}
    if ctx.section == "beginning" and (ctx.series_volume or 0) > 1 then order[#order + 1] = "series" end
    if ctx.section ~= "chapter" then order[#order + 1] = ctx.section end
    order[#order + 1] = "chapter"
    local cands = {}
    for _i, s in ipairs(order) do
        for _j, q in ipairs(pool(s)) do cands[#cands + 1] = q end
    end
    local out, cats, used = {}, {}, {}
    -- first pass: different categories; second: anything left
    for pass = 1, 2 do
        for _i, q in ipairs(cands) do
            if #out >= n then break end
            if not used[q.id] and (pass == 2 or not cats[q.category]) then
                out[#out + 1] = q
                used[q.id] = true
                cats[q.category] = true
            end
        end
    end
    return out
end

--- Section of the book at a position (0..1); the last chapter counts as end.
function M.sectionAt(pct, last_chapter)
    if last_chapter or pct >= 0.9 then return "end" end
    if pct < 0.2 then return "beginning" end
    return "middle"
end

return M

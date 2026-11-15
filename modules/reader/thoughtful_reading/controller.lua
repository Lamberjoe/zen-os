--[[
Thoughtful Reading – book club style questions, offline.

At the end of a chapter a card shows two questions of the part of the book you
are in (beginning, middle, end), from different categories; a highlight you
made in that chapter can become a question too. Answer in a few words, attach
a highlight, or just tick "Noted in my journal".

With a lexicon file for the book (koreader/lexicon/Books/<Author - Title>/lexicon.md), one
question after 40 % and one at the end are about a main character. The lexicon
is only read, never written.

One controller per FileManager and ReaderUI, attached by ZenOS when the feature is on.

Tools › Thoughtful Reading: the questions and answers of the book, all books
(also in the library), export, the settings, and an editor for the questions
(saved in koreader/settings/thoughtfulreading_questions.txt, which can also be
edited on a PC).
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("common/zen_logger").new("thoughtful_reading")
local _ = require("gettext")
local T = require("ffi/util").template

local Q = require("modules/reader/thoughtful_reading/questions")
local UI = require("modules/reader/thoughtful_reading/ui")
local Lex = require("modules/reader/thoughtful_reading/lexicon")

local KEY = "thoughtful_reading"           -- per book (doc settings)
local SETTINGS = "thoughtful_reading"      -- global (reader settings)
local INDEX = "thoughtful_reading_books"   -- global: the books with answers (for All books)
local MIN_CHAPTER_PAGES = 4                -- shorter TOC entries are not a chapter of their own
local MAX_COUNT_PAGES = 120                -- names are counted in at most this many pages per stop

local FREQ = {
    { id = "chapter", text = _("At every chapter end") },
    { id = "third", text = _("Every 3rd chapter") },
    { id = "sections", text = _("Only beginning, middle, end") },
    { id = "never", text = _("Never (only from the menu)") },
}

-- titles shown in the UI and the export (the question file keeps the English names)
local function section_title(sec)
    local t = { beginning = _("Beginning"), middle = _("Middle"), ["end"] = _("End"), chapter = _("Chapters"),
        series = _("Series") }
    return t[sec] or sec
end

local CAT_TITLE = setmetatable({}, { __index = function(_t, cat)
    local t = { plot = _("Plot"), pov = _("Point of view"), characters = _("Characters"), world = _("World"),
        themes = _("Themes"), style = _("Style"), prediction = _("Prediction"), personal = _("Personal"),
        highlight = _("Your highlight"), lexicon = _("From your lexicon") }
    return t[cat]
end })

local Plugin = WidgetContainer:extend{
    name = "thoughtful_reading",
    is_doc_only = false,     -- also in the library (All books)
}

-- ---- settings, state, books -----------------------------------------------------------------

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS)
    if type(s) ~= "table" then s = {} end
    s.frequency = s.frequency or "chapter"
    s.per_stop = tonumber(s.per_stop) or 2
    if s.lexicon == nil then s.lexicon = true end
    return s
end

local function saveSettings(s) G_reader_settings:saveSetting(SETTINGS, s) end

local function index()
    local t = G_reader_settings:readSetting(INDEX)
    return type(t) == "table" and t or {}
end

local function firstLine(s) return (tostring(s or ""):match("^[^\n]*") or "") end

local function normState(st)
    if type(st) ~= "table" then st = {} end
    for _i, k in ipairs({ "answers", "shown", "stops", "sections", "lex", "tally" }) do
        if type(st[k]) ~= "table" then st[k] = {} end
    end
    return st
end

local function exists(file) return file and lfs.attributes(file, "mode") == "file" end

function Plugin:inReader() return self.ui and self.ui.document ~= nil end

function Plugin:state()
    if self._state then return self._state end
    self._state = normState(self.ui.doc_settings and self.ui.doc_settings:readSetting(KEY))
    return self._state
end

function Plugin:save()
    if self.ui.doc_settings and self._state then self.ui.doc_settings:saveSetting(KEY, self._state) end
end

function Plugin:bookInfo()
    local p = self.ui.doc_props or {}
    local tags = Q.bookTags(p.keywords)
    return {
        title = p.display_title or p.title or "", author = p.authors or "",
        tags = tags, nonfiction = Q.isNonfiction(tags),
        series_volume = tonumber(p.series_index) or 0,
    }
end

--- The open book: { file, info, st, open = true, save }
function Plugin:currentBook()
    if not self:inReader() then return nil end
    if not self._book then
        self._book = { file = self.ui.document.file, info = self:bookInfo(), st = self:state(), open = true,
            save = function() self:save() end }
    end
    return self._book
end

--- Any book by its file (the open one, or one read from its .sdr folder).
function Plugin:bookByFile(file)
    local cur = self:currentBook()
    if cur and cur.file == file then return cur end
    if not exists(file) then return nil end
    local DocSettings = require("docsettings")
    local ok, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok or not ds then return nil end
    local st = normState(ds:readSetting(KEY))
    local entry = index()[file] or {}
    local props = ds:readSetting("doc_props") or {}
    local tags = Q.bookTags(entry.keywords or props.keywords)
    local info = {
        title = entry.title or props.display_title or props.title or file:match("([^/]+)%.%w+$") or file,
        author = entry.author or props.authors or "",
        tags = tags, nonfiction = Q.isNonfiction(tags),
        series_volume = tonumber(entry.series_volume or props.series_index) or 0,
    }
    return { file = file, info = info, st = st, open = false,
        save = function()
            ds:saveSetting(KEY, st)
            ds:flush()
        end }
end

--- Keep the list of books with answers up to date (for All books).
function Plugin:touchIndex(book)
    local t = index()
    local done, n = self:count(book)
    local last = 0
    for _id, a in pairs(book.st.answers) do last = math.max(last, a.time or 0) end
    if done == 0 then
        t[book.file] = nil
    else
        t[book.file] = { title = book.info.title, author = firstLine(book.info.author),
            keywords = table.concat(book.info.tags, ", "), series_volume = book.info.series_volume,
            done = done, n = n, last = last }
    end
    G_reader_settings:saveSetting(INDEX, t)
end

function Plugin:questions()
    if self._questions then return self._questions end
    local list, path = Q.load({ self:userQuestionsPath(),
        require("common/plugin_root") .. "/modules/reader/thoughtful_reading/questions.txt" })
    self._questions, self._questions_path = list, path
    return list
end

function Plugin:userQuestionsPath() return DataStorage:getSettingsDir() .. "/thoughtfulreading_questions.txt" end

-- ---- KOReader hooks ---------------------------------------------------------------------------

function Plugin:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("thoughtful_reading_ask", { category = "none", event = "ThoughtfulReadingAsk",
        title = _("Thoughtful Reading: ask me now"), reader = true })
    Dispatcher:registerAction("thoughtful_reading_list", { category = "none", event = "ThoughtfulReadingList",
        title = _("Thoughtful Reading: questions & answers"), reader = true })
end

function Plugin:onReaderReady()
    self._last_page = nil
    self._ticks = nil
end

-- A new layout (font, margins, rotation) or table of contents: the chapter pages change.
function Plugin:onDocumentRerendered()
    self._ticks, self._last_page = nil, nil
end
Plugin.onUpdateToc = Plugin.onDocumentRerendered

function Plugin:onCloseDocument()
    self:save()
    self._state, self._book, self._lex = nil, nil, nil
end

function Plugin:onThoughtfulReadingAsk()
    if self:inReader() and Plugin.enabled() then self:askNow() end
    return true
end

function Plugin:onThoughtfulReadingList()
    if self:inReader() and Plugin.enabled() then self:showList() end
    return true
end

-- ---- chapters ---------------------------------------------------------------------------------

-- First pages of the chapters (TOC), entries closer than MIN_CHAPTER_PAGES merged.
function Plugin:chapterStarts()
    if self._ticks then return self._ticks end
    local out = {}
    local ok, ticks = pcall(function() return self.ui.toc:getTocTicksFlattened() end)
    if ok and type(ticks) == "table" then
        for _i, p in ipairs(ticks) do
            if #out == 0 or p - out[#out] >= MIN_CHAPTER_PAGES then out[#out + 1] = p end
        end
    end
    self._ticks = out
    return out
end

function Plugin:chapterTitle(page)
    local ok, t = pcall(function() return self.ui.toc:getTocTitleByPage(page) end)
    if not ok or type(t) ~= "string" then return nil end
    t = t:gsub("\194\173", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")    -- soft hyphens
    return t ~= "" and t or nil
end

--- Pages shown at once (2 in the two-page view).
function Plugin:visiblePages()
    local doc = self.ui.document
    local ok, n = pcall(function() return doc.getVisiblePageCount and doc:getVisiblePageCount() end)
    return ok and tonumber(n) and n >= 1 and n or 1
end

--- A page turn forward onto the last page of a chapter (or of the book): a stop.
function Plugin:onPageUpdate(page)
    if not page or not self:inReader() or not Plugin.enabled() then return end
    local prev = self._last_page
    self._last_page = page
    local vis = self:visiblePages()
    if not prev or page <= prev or page > prev + vis then return end
    local s = settings()
    if s.frequency == "never" then return end
    local total = self.ui.document:getPageCount()
    local last = math.min(page + vis - 1, total)      -- the right page in the two-page view
    local starts = self:chapterStarts()
    local is_end, n_chapter = last >= total, 0
    for _i, p in ipairs(starts) do
        if p <= page then n_chapter = n_chapter + 1 end
        if p - 1 >= page and p - 1 <= last then is_end = true end
    end
    if not is_end then return end
    local st = self:state()
    -- by chapter number: stays right when a new layout moves the pages
    local key = "chapter " .. n_chapter
    if st.stops[key] then return end
    local pct = last / math.max(1, total)
    local section = Q.sectionAt(pct, last >= total)
    -- the three big stops: the first chapter end after 8 %, after 45 %, and the end
    local big = false
    if not st.sections[section] then
        if (section == "beginning" and pct >= 0.08) or (section == "middle" and pct >= 0.45) or section == "end" then
            big = true
        end
    end
    local go = s.frequency == "chapter" or (s.frequency == "third" and (n_chapter % 3 == 0 or big))
        or (s.frequency == "sections" and big)
    if not go then return end
    st.stops[key] = true
    if big then st.sections[section] = true end
    self:save()
    UIManager:nextTick(function() self:showStop(section, last) end)
end

-- ---- highlights -------------------------------------------------------------------------------

function Plugin:highlights()
    local out = {}
    local annos = self.ui.annotation and self.ui.annotation.annotations or {}
    for _i, a in ipairs(annos) do
        if a.text and a.text ~= "" then
            local page = a.pageno
            if not page and a.pos0 and self.ui.document.getPageFromXPointer then
                local ok, p = pcall(self.ui.document.getPageFromXPointer, self.ui.document, a.pos0)
                page = ok and p or nil
            end
            out[#out + 1] = { text = a.text:gsub("%s+", " "), page = page, id = a.datetime or a.pos0 or a.text,
                where = page and T(_("p. %1"), page) or nil }
        end
    end
    return out
end

-- highlights made in the pages since the last stop
function Plugin:recentHighlights(page)
    local st = self:state()
    local from = math.floor((st.last_stop or 0) * self.ui.document:getPageCount())
    local out = {}
    for _i, h in ipairs(self:highlights()) do
        if h.page and h.page > from and h.page <= page and not st.answers["hl:" .. tostring(h.id)] then
            out[#out + 1] = h
        end
    end
    return out
end

-- ---- the lexicon (read only) -----------------------------------------------------------------

--- The cards of the open book's lexicon ({} without one); read again when the file changed.
function Plugin:lexCards()
    if not self:inReader() then return {} end
    -- the folder the book lexicon remembered for this book, else the one named after the book
    local dir = self.ui.doc_settings and self.ui.doc_settings:readSetting("zen_lexicon_dir")
    local path = dir and lfs.attributes(dir .. "/lexicon.md", "mode") == "file" and dir .. "/lexicon.md"
        or Lex.path(self.ui.doc_props, self.ui.document.file)
    local mtime = path and lfs.attributes(path, "modification")
    if self._lex and self._lex.path == path and self._lex.mtime == mtime then return self._lex.cards end
    local ok, cards = pcall(Lex.load, path)
    if not ok then
        logger.warn("lexicon", cards)
        cards = {}
    end
    self._lex = { path = path, mtime = mtime, cards = cards }
    return cards
end

--- Count the lexicon's people in the pages read since the last count (up to `page`).
function Plugin:countNames(page)
    local cards = self:lexCards()
    if #Lex.persons(cards) == 0 then return end
    local doc = self.ui.document
    if not (self.ui.rolling and doc.getPageXPointer and doc.getTextFromXPointers) then return end
    local st = self:state()
    local total = doc:getPageCount()
    page = math.min(page, total)
    local counted = st.counted_to or 0
    if counted > 1 then counted = counted / total end -- a page number (older answers)
    local from = math.max(math.floor(counted * total) + 1, page - MAX_COUNT_PAGES + 1)
    if from > page then return end
    local ok, text = pcall(function()
        local x0 = doc:getPageXPointer(from)
        -- up to the start of the next page (the very last page of the book is left out)
        local x1 = doc:getPageXPointer(page < total and page + 1 or page)
        return doc:getTextFromXPointers(x0, x1)
    end)
    if ok and type(text) == "string" then
        Lex.count(text, cards, st.tally)
    else
        logger.warn("counting names", text)
    end
    -- as a share of the book: stays right when a new layout changes the page count
    st.counted_to = page / total
end

--- The people of the lexicon with their roles (most named first).
function Plugin:characters()
    return Lex.roles(self:lexCards(), self:state().tally)
end

--- The lexicon question for this stop, if one is due: once after 40 %, once at the end.
function Plugin:lexQuestion(section, pct)
    if not settings().lexicon then return nil end
    local st = self:state()
    local mains = {}
    for _i, e in ipairs(self:characters()) do
        if e.role == "Main" and (e.count > 0 or e.fixed) then mains[#mains + 1] = e end
    end
    if #mains == 0 then return nil end
    if section ~= "end" and pct >= 0.4 and not st.lex.mid then
        local a = mains[1]
        -- a side character seen so far who has a relation to the main character
        local b
        for _i, e in ipairs(self:characters()) do
            if e.role == "Side" and e.count > 0 and Lex.related(a.card, e.card) then b = e break end
        end
        local text = b and T(_("How has the relationship between %1 and %2 changed?"), a.name, b.name)
            or T(_("Has %1 changed since the beginning?"), a.name)
        st.lex.mid = { id = "lex:mid", text = text, name = a.name, section = "middle" }
        return st.lex.mid
    end
    if section == "end" and not st.lex["end"] then
        local mid = st.lex.mid
        local ans = mid and st.answers["lex:mid"]
        local name = mid and mid.name or mains[1].name
        local q = { id = "lex:end", name = name, section = "end" }
        if ans and ans.text and ans.text ~= "" then
            q.text = T(_("At %1 you wrote about %2. Was your opinion confirmed, or did it change?"),
                (ans.pct or 0) .. " %", name)
            q.quote = { text = ans.text, where = ans.page and T(_("your answer · p. %1"), ans.page) or _("your answer"),
                own = true }
        else
            q.text = T(_("Did your opinion of %1 change by the end?"), name)
        end
        st.lex["end"] = q
        return q
    end
end

local function asLexCard(q)
    return { id = q.id, text = q.text, category = "lexicon", section = q.section, quote = q.quote, lexname = q.name,
        label = (CAT_TITLE.lexicon .. " · " .. (q.name or "")):upper() }
end

-- ---- choosing ---------------------------------------------------------------------------------

function Plugin:pickFor(section, n, exclude)
    local st = self:state()
    local info = self:bookInfo()
    local answered = {}
    for id in pairs(st.answers) do answered[id] = true end
    return Q.pick(self:questions(), {
        section = section, tags = info.tags, nonfiction = info.nonfiction, series_volume = info.series_volume,
        answered = answered, shown = st.shown, exclude = exclude,
    }, n)
end

local function asCard(q, section)
    return { id = q.id, text = q.text, category = q.category, section = section,
        label = (CAT_TITLE[q.category] or q.category or ""):upper() }
end

-- ---- the card ---------------------------------------------------------------------------------

function Plugin:showStop(section, page)
    local st = self:state()
    local s = settings()
    local n = math.max(1, math.min(3, s.per_stop))
    local list = {}
    -- a highlight of this chapter can be one of the questions
    local hls = self:recentHighlights(page)
    if #hls > 0 and n >= 2 then
        local h = hls[#hls]
        local label = CAT_TITLE.highlight:upper()
        list[1] = { id = "hl:" .. tostring(h.id), text = _("Why did you mark this?"), category = "highlight",
            section = "chapter", label = h.where and T("%1 · %2", label, h.where) or label,
            quote = { text = h.text, where = nil } }
        n = n - 1
    end
    -- at most one question about the lexicon
    local ok, err = pcall(function()
        if not settings().lexicon or (st.lex.mid and (section ~= "end" or st.lex["end"])) then return end
        self:countNames(page)
        local total = self.ui.document:getPageCount()
        local lq = self:lexQuestion(section, page / math.max(1, total))
        if lq then
            list[#list + 1] = asLexCard(lq)
            n = n - 1
        end
    end)
    if not ok then logger.warn("lexicon question", err) end
    if n > 0 then
        for _i, q in ipairs(self:pickFor(section, n)) do
            list[#list + 1] = asCard(q, section)
            st.shown[q.id] = true
        end
    end
    st.last_stop = page / math.max(1, self.ui.document:getPageCount())
    self:save()
    -- a lexicon question asked: the count in All books changes
    local book = self:currentBook()
    if book and index()[book.file] then self:touchIndex(book) end
    if #list == 0 then return end
    local chapter = self:chapterTitle(page)
    self:showCard(list, section, chapter, page)
end

function Plugin:showCard(list, section, chapter, page)
    local st = self:state()
    local title = "✎ " .. (chapter and (chapter .. " · ") or "") .. (section_title(section) or "")
    UI.sheet{
        title = title,
        build = function(sheet, w)
            local vg = VerticalGroup:new{ align = "left" }
            for _i, q in ipairs(list) do
                local a = st.answers[q.id]
                local qq = { text = q.text, quote = q.quote,
                    label = q.label .. (a and "   ✓ " .. (a.journal and _("journal") or _("answered")) or "") }
                vg[#vg + 1] = UI.questionBox(qq, w, function()
                    self:answer(q, { chapter = chapter, page = page, done = function() sheet:refresh() end })
                end)
                vg[#vg + 1] = VerticalSpan:new{ width = UI.s(10) }
            end
            vg[#vg + 1] = VerticalSpan:new{ width = UI.s(4) }
            vg[#vg + 1] = UI.buttonRow({
                { text = _("One more"), callback = function()
                    local ex = {}
                    for _i, q in ipairs(list) do ex[q.id] = true end
                    local more = self:pickFor(section == "chapter" and "chapter" or section, 1, ex)
                    if more[1] then
                        list[#list + 1] = asCard(more[1], section)
                        st.shown[more[1].id] = true
                        self:save()
                        sheet:refresh()
                    else
                        UIManager:show(InfoMessage:new{ text = _("No more questions for this part."), timeout = 2 })
                    end
                end },
                { text = _("Answer"), callback = function()
                    for _i, q in ipairs(list) do
                        if not st.answers[q.id] then
                            return self:answer(q, { chapter = chapter, page = page, done = function() sheet:refresh() end })
                        end
                    end
                end },
                { text = _("Keep reading"), primary = true, callback = function() sheet:onClose() end },
            }, w)
            return vg
        end,
    }
end

--- Ask now: the part of the book you are in.
function Plugin:askNow()
    local page = self.ui:getCurrentPage()
    local total = self.ui.document:getPageCount()
    local last = math.min(page + self:visiblePages() - 1, total)
    local section = Q.sectionAt(last / math.max(1, total), last >= total)
    self:showStop(section, last)
end

-- ---- answering --------------------------------------------------------------------------------

--- q: { id, text, category, section, quote }
--- o: { book (default: the open one), chapter, page, done, text, hl }
function Plugin:answer(q, o)
    local book = o.book or self:currentBook()
    if not book then return end
    local st = book.st
    local old = st.answers[q.id] or {}
    local hl = o.hl or old.hl
    local desc = q.text
    if q.quote then desc = desc .. "\n" .. (q.quote.own and q.quote.text or ("»" .. q.quote.text .. "«")) end
    if hl then desc = desc .. "\n\n+ »" .. hl.text .. "«" .. (hl.where and (" (" .. hl.where .. ")") or "") end
    local dlg
    local function store(extra)
        local a = {
            q = q.text, cat = q.category, text = dlg:getInputText(), hl = hl,
            quote = q.quote and q.quote.text or nil, quote_own = q.quote and q.quote.own or nil,
            time = os.time(),
        }
        if book.open then
            local page = o.page or old.page or self.ui:getCurrentPage()
            local total = self.ui.document:getPageCount()
            a.sec = q.section or Q.sectionAt(page / math.max(1, total), false)
            a.page = page
            a.pct = math.floor(page * 100 / math.max(1, total))
            a.chapter = o.chapter or old.chapter or self:chapterTitle(page)
        else
            -- answered from All books: where it was answered before (or nowhere)
            a.sec = q.section or old.sec
            a.page, a.pct, a.chapter = old.page, old.pct, old.chapter
        end
        for k, v in pairs(extra or {}) do a[k] = v end
        st.answers[q.id] = a
        book.save()
        self:touchIndex(book)
        UIManager:close(dlg)
        if o.done then o.done() end
    end
    local row1 = { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end } }
    if book.open then
        row1[2] = { text = _("+ Highlight"), callback = function()
            local text = dlg:getInputText()
            UIManager:close(dlg)
            self:pickHighlight(function(h)
                local oo = {}
                for k, v in pairs(o) do oo[k] = v end
                oo.text, oo.hl = text, h or hl
                self:answer(q, oo)
            end)
        end }
    end
    dlg = InputDialog:new{
        title = _("Answer"),
        description = desc,
        input = o.text or old.text or "",
        allow_newline = true,
        text_height = require("device").screen:scaleBySize(130),
        buttons = { row1, {
            { text = _("Noted in my journal"), callback = function() store({ journal = true }) end },
            { text = _("Save"), is_enter_default = false, callback = function() store() end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Choose one of the book's highlights (the newest first).
function Plugin:pickHighlight(done)
    local hls = self:highlights()
    table.sort(hls, function(a, b) return (a.page or 0) > (b.page or 0) end)
    if #hls == 0 then
        UIManager:show(InfoMessage:new{ text = _("No highlights in this book yet."), timeout = 2 })
        return done(nil)
    end
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    local answered = false
    local function finish(h)
        if answered then return end
        answered = true
        done(h)
    end
    for _i, h in ipairs(hls) do
        local t = h.text
        t = require("common/utils").truncateUtf8(t, 118, "…")
        items[#items + 1] = { text = "»" .. t .. "«", mandatory = h.where, callback = function()
            finish(h)
            UIManager:close(menu)
        end }
    end
    menu = Menu:new{
        title = _("Add a highlight"), item_table = items, is_borderless = true, is_popout = false,
        covers_fullscreen = true, close_callback = function() UIManager:close(menu) finish(nil) end,
    }
    UIManager:show(menu)
end

-- ---- all questions of a book -------------------------------------------------------------------

function Plugin:entries(section, book)
    book = book or self:currentBook()
    local st, info = book.st, book.info
    local out, seen = {}, {}
    for _i, q in ipairs(self:questions()) do
        local sec = q.section == "series" and "beginning" or q.section
        if sec == section and Q.fits(q, info.tags, info.nonfiction)
            and (q.section ~= "series" or info.series_volume > 1) then
            out[#out + 1] = { q = asCard(q, section), a = st.answers[q.id], idx = #out + 1 }
            seen[q.id] = true
        end
    end
    -- lexicon questions that were asked but not answered yet
    for _k, lq in pairs(st.lex) do
        if type(lq) == "table" and lq.id and lq.section == section and not st.answers[lq.id] then
            out[#out + 1] = { q = asLexCard(lq), a = nil, idx = 9998 }
            seen[lq.id] = true
        end
    end
    -- answers to questions not in the list (highlights, lexicon, a changed question)
    for id, a in pairs(st.answers) do
        local sec = a.cat == "highlight" and "chapter" or (a.sec == "series" and "beginning" or a.sec)
        if not seen[id] and sec == section then
            local lq = a.cat == "lexicon" and (id == "lex:mid" and st.lex.mid or id == "lex:end" and st.lex["end"]) or nil
            out[#out + 1] = { q = { id = id, text = a.q, category = a.cat, section = sec,
                quote = a.quote and { text = a.quote, own = a.quote_own } or nil, lexname = lq and lq.name,
                label = lq and (CAT_TITLE.lexicon .. " · " .. lq.name):upper() or "" }, a = a, idx = 9999 }
        end
    end
    -- answered first (in reading order), then open
    table.sort(out, function(x, y)
        if (x.a ~= nil) ~= (y.a ~= nil) then return x.a ~= nil end
        if x.a and y.a and (x.a.page or 0) ~= (y.a.page or 0) then return (x.a.page or 0) < (y.a.page or 0) end
        return x.idx < y.idx
    end)
    return out
end

function Plugin:count(book)
    local n, done = 0, 0
    for _i, sec in ipairs(Q.SECTIONS) do
        for _j, e in ipairs(self:entries(sec, book)) do
            n = n + 1
            if e.a then done = done + 1 end
        end
    end
    return done, n
end

function Plugin:entryWidget(e, w, on_tap)
    local mark = e.a and "✓" or "○"
    local mw = UI.s(26)
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg + 1] = HorizontalGroup:new{ align = "top",
        TextWidget:new{ text = mark, face = Font:getFace("cfont", 17), bold = true },
        HorizontalSpan:new{ width = mw - UI.s(14) },
        TextBoxWidget:new{ text = e.q.text, face = Font:getFace("cfont", 17), bold = true, width = w - mw } }
    local function indent(wdg)
        return HorizontalGroup:new{ HorizontalSpan:new{ width = mw }, wdg }
    end
    if e.q.quote then
        vg[#vg + 1] = VerticalSpan:new{ width = UI.s(4) }
        vg[#vg + 1] = indent(UI.quote(e.q.quote, w - mw))
    end
    if e.a and e.a.text and e.a.text ~= "" then
        vg[#vg + 1] = VerticalSpan:new{ width = UI.s(4) }
        vg[#vg + 1] = indent(TextBoxWidget:new{ text = e.a.text, width = w - mw,
            face = Font:getFace("NotoSerif-Regular.ttf", 16) })
    end
    if e.a and e.a.hl then
        vg[#vg + 1] = VerticalSpan:new{ width = UI.s(4) }
        vg[#vg + 1] = indent(UI.quote(e.a.hl, w - mw))
    end
    local meta
    if e.a then
        local parts = {}
        if e.a.journal then parts[#parts + 1] = "✓ " .. _("journal") end
        if e.a.chapter then parts[#parts + 1] = e.a.chapter end
        if e.a.pct then parts[#parts + 1] = e.a.pct .. " %" end
        if not e.a.chapter and not e.a.pct and e.a.time then parts[#parts + 1] = os.date("%d.%m.%Y", e.a.time) end
        meta = table.concat(parts, " · ")
    else
        meta = _("open – tap to answer")
    end
    if e.q.category == "lexicon" then meta = meta .. "  ·  " .. CAT_TITLE.lexicon .. (e.q.lexname and (" · " .. e.q.lexname) or "") end
    vg[#vg + 1] = VerticalSpan:new{ width = UI.s(2) }
    vg[#vg + 1] = indent(TextWidget:new{ text = meta, face = Font:getFace("cfont", 13), fgcolor = Blitbuffer.COLOR_GRAY_5,
        max_width = w - mw })
    local box = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = UI.s(8) }, vg, VerticalSpan:new{ width = UI.s(8) } }
    return UI.tap(box, w, box:getSize().h, on_tap)
end

--- The questions and answers of a book. o: { book, from_all, on_close }
function Plugin:showList(section, o)
    o = o or {}
    local book = o.book or self:currentBook()
    if not book then return end
    if not section then
        if book.open then
            local page = self.ui:getCurrentPage()
            local total = self.ui.document:getPageCount()
            section = Q.sectionAt(page / math.max(1, total), false)
        else
            section = "beginning"
        end
    end
    local page_widget
    local function reopen(sec, p)
        if page_widget then
            page_widget.on_close = nil
            page_widget:onClose()
        end
        page_widget = nil
        self:showList(sec, o)
        if p and self._list then self._list:gotoPage(p) end
    end
    local done, n = self:count(book)
    local tabs = {}
    for _i, sec in ipairs(Q.SECTIONS) do
        tabs[#tabs + 1] = { text = section_title(sec), on = sec == section, callback = function() reopen(sec) end }
    end
    local action
    if o.from_all and not book.open then
        action = { text = _("Open book"), callback = function() self:openBook(book.file) end }
    end
    page_widget = UI.page{
        title = o.from_all and firstLine(book.info.title) or _("Thoughtful Reading"),
        subtitle = T(_("%1 of %2"), done, n),
        action = action,
        tabs = tabs,
        empty = _("No questions here."),
        items = function(w)
            local out = {}
            for _i, e in ipairs(self:entries(section, book)) do
                out[#out + 1] = self:entryWidget(e, w, function()
                    local cur = page_widget and page_widget.page
                    self:answer(e.q, { book = book, chapter = e.a and e.a.chapter, page = e.a and e.a.page,
                        done = function() reopen(section, cur) end })
                end)
            end
            return out
        end,
        on_close = function()
            self._list = nil
            if o.on_close then o.on_close() end
        end,
    }
    self._list = page_widget
end

-- ---- all books ----------------------------------------------------------------------------------

--- The books with answers, the last answered first: { { file, entry, found } }
function Plugin:allBooks()
    local cur = self:currentBook()
    if cur and next(cur.st.answers) and not index()[cur.file] then self:touchIndex(cur) end
    local out = {}
    for file, entry in pairs(index()) do
        out[#out + 1] = { file = file, entry = entry, found = exists(file) }
    end
    table.sort(out, function(a, b)
        if (a.entry.last or 0) ~= (b.entry.last or 0) then return (a.entry.last or 0) > (b.entry.last or 0) end
        return tostring(a.entry.title) < tostring(b.entry.title)
    end)
    return out
end

function Plugin:openBook(file)
    UIManager:nextTick(function()
        if self:inReader() then
            if self.ui.document.file ~= file then self.ui:switchDocument(file) end
        else
            require("apps/reader/readerui"):showReader(file)
        end
    end)
    -- close the pages of Thoughtful Reading
    if self._list then self._list.on_close = nil self._list:onClose() self._list = nil end
    if self._all then self._all:onClose() self._all = nil end
end

function Plugin:showAllBooks()
    local page_widget
    page_widget = UI.page{
        title = _("All books"),
        subtitle = tostring(#self:allBooks()),
        action = { text = _("Export all"), callback = function() self:exportAll() end },
        empty = _("No answers yet. The books you answer questions for are listed here, the last answered first."),
        items = function(w)
            local out = {}
            for _i, b in ipairs(self:allBooks()) do
                local e = b.entry
                local vg = VerticalGroup:new{ align = "left",
                    VerticalSpan:new{ width = UI.s(8) },
                    TextBoxWidget:new{ text = firstLine(e.title), width = w,
                        face = Font:getFace("cfont", 18), bold = true,
                        fgcolor = b.found and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9 },
                }
                local parts = {}
                if e.author and e.author ~= "" then parts[#parts + 1] = e.author end
                if b.found then
                    parts[#parts + 1] = (e.done or 0) .. "/" .. (e.n or 0)
                    if e.last and e.last > 0 then parts[#parts + 1] = T(_("last answer %1"), os.date("%d.%m.%Y", e.last)) end
                    if self:inReader() and self.ui.document.file == b.file then parts[#parts + 1] = _("open now") end
                else
                    parts[#parts + 1] = T(_("%1 answers"), e.done or 0)
                    parts[#parts + 1] = _("book not found")
                end
                vg[#vg + 1] = VerticalSpan:new{ width = UI.s(2) }
                vg[#vg + 1] = TextWidget:new{ text = table.concat(parts, " · "), face = Font:getFace("cfont", 14),
                    fgcolor = b.found and Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_GRAY_9, max_width = w }
                vg[#vg + 1] = VerticalSpan:new{ width = UI.s(8) }
                out[#out + 1] = UI.tap(vg, w, vg:getSize().h, function()
                    if not b.found then
                        UIManager:show(InfoMessage:new{ text = T(_("This book was not found:\n%1\n\nIts answers were kept with the book (in its .sdr folder)."),
                            b.file) })
                        return
                    end
                    local book = self:bookByFile(b.file)
                    if not book then
                        UIManager:show(InfoMessage:new{ text = _("Could not read the answers of this book."), timeout = 3 })
                        return
                    end
                    self:showList(nil, { book = book, from_all = true, on_close = function()
                        if self._all then self._all:refresh() end
                    end })
                end)
            end
            return out
        end,
        on_close = function() self._all = nil end,
    }
    self._all = page_widget
end

-- ---- characters ---------------------------------------------------------------------------------

function Plugin:showCharacters()
    if not self:inReader() then return end
    pcall(function() self:countNames(self.ui:getCurrentPage()) end)
    UI.page{
        title = _("Characters"),
        subtitle = _("from your lexicon"),
        empty = _("No people in this book's lexicon.\n\nWith a book lexicon you can make cards for the people of a book. Thoughtful Reading then asks about the main characters (once after 40 % and once at the end)."),
        items = function(w)
            local out = {}
            local list = self:characters()
            for _i, e in ipairs(list) do
                local role = e.role or "–"
                if e.fixed then role = role .. " ✎" end
                local tag = FrameContainer:new{ bordersize = UI.s(2), radius = UI.s(14), padding = 0,
                    padding_left = UI.s(12), padding_right = UI.s(12), margin = 0,
                    background = e.role == "Main" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    TextWidget:new{ text = role, face = Font:getFace("cfont", 14), bold = true,
                        fgcolor = e.role == "Main" and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK } }
                local meta = TextWidget:new{ text = e.count > 0 and (e.count .. " × · " .. e.share .. " %") or _("not yet"),
                    face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5 }
                local right_w = meta:getSize().w + UI.s(12) + tag:getSize().w
                local name = TextWidget:new{ text = e.name, face = Font:getFace("cfont", 17), bold = true,
                    max_width = w - right_w - UI.s(12) }
                local row = HorizontalGroup:new{ align = "center", name,
                    HorizontalSpan:new{ width = math.max(UI.s(12), w - name:getSize().w - right_w) },
                    meta, HorizontalSpan:new{ width = UI.s(12) }, tag }
                out[#out + 1] = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = UI.s(8) }, row,
                    VerticalSpan:new{ width = UI.s(8) } }
            end
            if #list > 0 then
                out[#out + 1] = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = UI.s(10) },
                    TextBoxWidget:new{ width = w, face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5,
                        text = _("Counted in the part you have read: the 2–3 most named people with at least 15 % of all mentions are main characters. ✎ = set on the lexicon card (Role: Main or Role: Side).") } }
            end
            return out
        end,
    }
end

-- ---- editing the questions ----------------------------------------------------------------------

function Plugin:writeQuestions(list)
    local path = self:userQuestionsPath()
    local f = io.open(path, "w")
    if not f then
        UIManager:show(InfoMessage:new{ text = T(_("Could not write %1"), path) })
        return false
    end
    f:write(Q.serialize(list))
    f:close()
    self._questions = nil
    return true
end

local function booksText(q)
    for _i, t in ipairs(q.tags or {}) do
        if t == "nonfiction" then return "nonfiction books" end
    end
    if q.tags and #q.tags > 0 then return T(_("only: %1"), table.concat(q.tags, ", ")) end
    return _("all novels")
end

function Plugin:showEditor(section)
    section = section or self._edit_section or "beginning"
    self._edit_section = section
    local page_widget
    local function reopen(sec)
        if page_widget then page_widget:onClose() end
        self:showEditor(sec)
    end
    local list = self:questions()
    local tabs = {}
    for _i, sec in ipairs(Q.EDIT_SECTIONS) do
        local n = 0
        for _j, q in ipairs(list) do if q.section == sec then n = n + 1 end end
        tabs[#tabs + 1] = { text = section_title(sec) .. " " .. n, on = sec == section, callback = function() reopen(sec) end }
    end
    page_widget = UI.page{
        title = _("Questions"),
        subtitle = tostring(#list),
        action = { text = _("+ New"), callback = function() self:editQuestion(nil, section, function() reopen(self._edit_section) end) end },
        tabs = tabs,
        empty = _("No questions in this part."),
        items = function(w)
            local out = {}
            for _i, q in ipairs(list) do
                if q.section == section then
                    local vg = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = UI.s(8) },
                        TextBoxWidget:new{ text = q.text, width = w, face = Font:getFace("cfont", 17), bold = true },
                        VerticalSpan:new{ width = UI.s(2) },
                        TextWidget:new{ text = (CAT_TITLE[q.category] or q.category) .. " · " .. booksText(q),
                            face = Font:getFace("cfont", 13), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w },
                        VerticalSpan:new{ width = UI.s(8) } }
                    out[#out + 1] = UI.tap(vg, w, vg:getSize().h, function()
                        self:editQuestion(q, section, function() reopen(self._edit_section) end)
                    end)
                end
            end
            out[#out + 1] = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = UI.s(12) },
                UI.pill{ text = _("Standard questions"), size = 15, callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Replace your questions with the standard list that comes with ZenOS?"),
                        ok_text = _("Replace"),
                        ok_callback = function()
                            os.remove(self:userQuestionsPath())
                            self._questions = nil
                            reopen(section)
                        end,
                    })
                end },
                VerticalSpan:new{ width = UI.s(8) } }
            return out
        end,
    }
end

--- Edit a question (q = nil: a new one in `section`). done(): after saving or deleting.
function Plugin:editQuestion(q, section, done)
    local tags_nf, tags = false, {}
    for _i, t in ipairs(q and q.tags or {}) do
        if t == "nonfiction" then tags_nf = true else tags[#tags + 1] = t end
    end
    local d = {
        text = q and q.text or "", section = q and q.section or section or "beginning",
        category = q and q.category or "plot",
        books = tags_nf and "nf" or (#tags > 0 and "tags" or "all"), tags = table.concat(tags, ", "),
    }
    local page_widget
    local function label(text, w)
        return TextWidget:new{ text = text, face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w }
    end
    local function field(text, placeholder, w, callback)
        local frame = FrameContainer:new{ bordersize = UI.s(2), radius = UI.s(8), padding = UI.s(10), margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            TextBoxWidget:new{ text = text ~= "" and text or placeholder, width = w - 2 * UI.s(12),
                face = Font:getFace("cfont", 17), fgcolor = text ~= "" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9 } }
        return UI.tap(frame, w, frame:getSize().h, callback)
    end
    local function input(title, value, set)
        local dlg
        dlg = InputDialog:new{
            title = title, input = value, allow_newline = false,
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = _("OK"), is_enter_default = true, callback = function()
                    set(dlg:getInputText())
                    UIManager:close(dlg)
                    if page_widget then page_widget:refresh() end
                end },
            } },
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end
    local function close()
        if page_widget then page_widget:onClose() end
    end
    local function save()
        local text = (d.text:gsub("[\r\n|]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
        if text == "" then
            UIManager:show(InfoMessage:new{ text = _("The question is empty."), timeout = 2 })
            return
        end
        local t = {}
        if d.books == "nf" then
            t = { "nonfiction" }
        elseif d.books == "tags" then
            for tag in d.tags:gmatch("[^,;]+") do
                tag = tag:gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if tag ~= "" then t[#t + 1] = tag end
            end
        end
        local list, out, replaced = self:questions(), {}, false
        for _i, x in ipairs(list) do
            if q and x.id == q.id and not replaced then
                out[#out + 1] = { id = Q.id(text), section = d.section, category = d.category, tags = t, text = text }
                replaced = true
            elseif x.text == text then
                UIManager:show(InfoMessage:new{ text = _("This question is already in the list."), timeout = 2 })
                return
            else
                out[#out + 1] = x
            end
        end
        if not replaced then
            out[#out + 1] = { id = Q.id(text), section = d.section, category = d.category, tags = t, text = text }
        end
        if self:writeQuestions(out) then
            self._edit_section = d.section
            close()
            done()
        end
    end
    local function delete()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete this question?\n\n%1"), q.text),
            ok_text = _("Delete"),
            ok_callback = function()
                local out = {}
                for _i, x in ipairs(self:questions()) do
                    if x.id ~= q.id then out[#out + 1] = x end
                end
                if self:writeQuestions(out) then
                    close()
                    done()
                end
            end,
        })
    end
    page_widget = UI.page{
        title = q and _("Edit question") or _("New question"),
        items = function(w)
            local vg = VerticalGroup:new{ align = "left" }
            local function add(wdg, gap)
                vg[#vg + 1] = wdg
                vg[#vg + 1] = VerticalSpan:new{ width = gap or UI.s(10) }
            end
            add(VerticalSpan:new{ width = UI.s(4) }, 0)
            add(label(_("Question"), w), UI.s(4))
            add(field(d.text, _("Tap to write the question …"), w, function()
                input(_("Question"), d.text, function(v) d.text = v end)
            end), UI.s(16))
            add(label(_("Part of the book"), w), UI.s(6))
            local secs = {}
            for _i, sec in ipairs(Q.EDIT_SECTIONS) do
                local text = sec == "chapter" and _("Any chapter") or sec == "series" and _("Series (vol. 2+)")
                    or section_title(sec)
                secs[#secs + 1] = { text = text, on = d.section == sec,
                    callback = function() d.section = sec page_widget:refresh() end }
            end
            add(UI.pillsWrap(secs, w, 15), UI.s(16))
            add(label(_("Category (two questions at one stop come from different categories)"), w), UI.s(6))
            local cats = {}
            for _i, c in ipairs(Q.CATEGORIES) do
                cats[#cats + 1] = { text = CAT_TITLE[c], on = d.category == c,
                    callback = function() d.category = c page_widget:refresh() end }
            end
            add(UI.pillsWrap(cats, w, 15), UI.s(16))
            add(label(_("Books"), w), UI.s(6))
            local books = {}
            for _i, b in ipairs({ { "all", _("All novels") }, { "tags", _("Only with tags …") }, { "nf", _("Nonfiction") } }) do
                books[#books + 1] = { text = b[2], on = d.books == b[1],
                    callback = function() d.books = b[1] page_widget:refresh() end }
            end
            add(UI.pillsWrap(books, w, 15), UI.s(10))
            if d.books == "tags" then
                add(field(d.tags, _("Tap to enter tags, e.g. crime, thriller"), w, function()
                    input(_("Tags (separated by commas)"), d.tags, function(v) d.tags = v end)
                end), UI.s(4))
                add(label(_("A part of the tag is enough: \"fantasy\" also matches \"Dark Fantasy\"."), w), UI.s(10))
            end
            vg[#vg + 1] = VerticalSpan:new{ width = UI.s(10) }
            local buttons = {}
            if q then buttons[#buttons + 1] = { text = _("Delete"), callback = delete } end
            buttons[#buttons + 1] = { text = _("Cancel"), callback = close }
            buttons[#buttons + 1] = { text = _("Save"), primary = true, callback = save }
            vg[#vg + 1] = UI.buttonRow(buttons, w)
            return { vg }
        end,
    }
end

-- ---- export -----------------------------------------------------------------------------------

--- Markdown lines for the answers of a book (h = "#" or "##" for the book's heading), or nil.
function Plugin:exportLines(book, h)
    local info = book.info
    local author = firstLine(info.author)
    local lines = { h .. " " .. firstLine(info.title) .. (author ~= "" and (" — " .. author) or ""), "" }
    local any = false
    for _i, sec in ipairs(Q.SECTIONS) do
        local part = {}
        for _j, e in ipairs(self:entries(sec, book)) do
            if e.a then
                any = true
                part[#part + 1] = "**" .. e.q.text .. "**"
                part[#part + 1] = ""
                if e.q.quote then part[#part + 1] = "> " .. e.q.quote.text:gsub("\n", "\n> ") part[#part + 1] = "" end
                if e.a.text and e.a.text ~= "" then part[#part + 1] = e.a.text part[#part + 1] = "" end
                if e.a.hl then
                    part[#part + 1] = "> " .. e.a.hl.text .. (e.a.hl.where and (" (" .. e.a.hl.where .. ")") or "")
                    part[#part + 1] = ""
                end
                local meta = {}
                if e.a.journal then meta[#meta + 1] = _("noted in my journal") end
                if e.a.chapter then meta[#meta + 1] = e.a.chapter end
                if e.a.pct then meta[#meta + 1] = e.a.pct .. " %" end
                if #meta > 0 then part[#part + 1] = "_" .. table.concat(meta, " · ") .. "_" part[#part + 1] = "" end
            end
        end
        if #part > 0 then
            lines[#lines + 1] = h .. "# " .. section_title(sec)
            lines[#lines + 1] = ""
            for _j, l in ipairs(part) do lines[#lines + 1] = l end
        end
    end
    return any and lines or nil
end

local function writeExport(name, lines)
    local dir = DataStorage:getFullDataDir() .. "/clipboard"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local path = dir .. "/" .. name:gsub("[/\\:*?\"<>|]", "_") .. ".md"
    local f = io.open(path, "w")
    if not f then
        UIManager:show(InfoMessage:new{ text = T(_("Could not write %1"), path) })
        return
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    UIManager:show(InfoMessage:new{ text = T(_("Exported:\n%1"), path), timeout = 4 })
end

function Plugin:export()
    local book = self:currentBook()
    local lines = book and self:exportLines(book, "#")
    if not lines then
        UIManager:show(InfoMessage:new{ text = _("No answers yet."), timeout = 2 })
        return
    end
    table.insert(lines, 2, "")
    table.insert(lines, 3, "_Thoughtful Reading · " .. os.date("%Y-%m-%d") .. "_")
    local title = firstLine(book.info.title)
    writeExport((title ~= "" and title or "book") .. ".thoughtful", lines)
end

function Plugin:exportAll()
    local books = self:allBooks()
    local body, n = {}, 0
    for _i, b in ipairs(books) do
        local book = b.found and self:bookByFile(b.file)
        local lines = book and self:exportLines(book, "##")
        if lines then
            n = n + 1
            for _j, l in ipairs(lines) do body[#body + 1] = l end
        else
            local author = firstLine(b.entry.author)
            body[#body + 1] = "## " .. firstLine(b.entry.title) .. (author ~= "" and (" — " .. author) or "")
            body[#body + 1] = ""
            body[#body + 1] = "_" .. (b.found and _("no answers") or _("book not found – answers not available")) .. "_"
            body[#body + 1] = ""
        end
    end
    if n == 0 then
        UIManager:show(InfoMessage:new{ text = _("No answers yet."), timeout = 2 })
        return
    end
    local lines = { "# " .. _("Thoughtful Reading – all books"), "", "_" .. os.date("%Y-%m-%d") .. " · "
        .. (n == 1 and _("1 book") or T(_("%1 books"), n)) .. "_", "" }
    for _i, l in ipairs(body) do lines[#lines + 1] = l end
    writeExport(_("Thoughtful Reading - all books"), lines)
end

-- ---- menu -------------------------------------------------------------------------------------

function Plugin:addToMainMenu(menu_items)
    if not Plugin.enabled() then return end
    menu_items.thoughtful_reading = {
        text = _("Thoughtful Reading"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local items = {}
            local function close(tm) if tm then tm:closeMenu() end end
            if self:inReader() then
                items[#items + 1] = { text_func = function()
                    local done, n = self:count()
                    return T(_("Questions & answers  (%1/%2)"), done, n)
                end, callback = function(tm) close(tm) self:showList() end }
            end
            items[#items + 1] = { text_func = function() return T(_("All books  (%1)"), #self:allBooks()) end,
                callback = function(tm) close(tm) self:showAllBooks() end }
            if self:inReader() then
                items[#items + 1] = { text = _("Ask me now"), callback = function(tm) close(tm) self:askNow() end }
                items[#items + 1] = { text = _("Export answers"), callback = function() self:export() end }
            end
            items[#items + 1] = { text = _("Export all books"), callback = function() self:exportAll() end, separator = true }
            if self:inReader() then
                items[#items + 1] = { text = _("Characters"), callback = function(tm) close(tm) self:showCharacters() end }
            end
            local freq = { text_func = function()
                local f = settings().frequency
                for _i, x in ipairs(FREQ) do if x.id == f then return T(_("Show questions: %1"), x.text) end end
                return _("Show questions")
            end, sub_item_table = {} }
            for _i, x in ipairs(FREQ) do
                freq.sub_item_table[#freq.sub_item_table + 1] = {
                    text = x.text, radio = true,
                    checked_func = function() return settings().frequency == x.id end,
                    callback = function() local s = settings() s.frequency = x.id saveSettings(s) end,
                }
            end
            items[#items + 1] = freq
            local per = { text_func = function() return T(_("Questions per stop: %1"), settings().per_stop) end,
                sub_item_table = {} }
            for n = 1, 3 do
                per.sub_item_table[#per.sub_item_table + 1] = {
                    text = tostring(n), radio = true,
                    checked_func = function() return settings().per_stop == n end,
                    callback = function() local s = settings() s.per_stop = n saveSettings(s) end,
                }
            end
            items[#items + 1] = per
            items[#items + 1] = { text = _("Questions about lexicon cards"),
                checked_func = function() return settings().lexicon end,
                callback = function() local s = settings() s.lexicon = not s.lexicon saveSettings(s) end }
            items[#items + 1] = { text = _("Edit questions"), callback = function(tm) close(tm) self:showEditor() end }
            items[#items + 1] = { text = _("Question file"), keep_menu_open = true, callback = function()
                self:questions()
                UIManager:show(InfoMessage:new{ text = T(_("Questions from:\n%1\n\n\"Edit questions\" saves your own list to\nkoreader/settings/thoughtfulreading_questions.txt.\nYou can also change that file on a PC (one question per line)."),
                    tostring(self._questions_path)) })
            end }
            return items
        end,
    }
end

-- ---- ZenOS -------------------------------------------------------------------------------------

local zen_plugin

--- The feature is on (ZenOS setting "Thoughtful Reading").
function Plugin.enabled()
    return zen_plugin ~= nil and type(zen_plugin.config) == "table" and type(zen_plugin.config.features) == "table"
        and zen_plugin.config.features.thoughtful_reading == true
end

--- Give a FileManager or ReaderUI its controller (when the feature is on).
function Plugin.attach(ui, plugin)
    zen_plugin = plugin or zen_plugin
    if not (ui and Plugin.enabled()) or ui.thoughtful_reading then return end
    ui:registerModule("thoughtful_reading", Plugin:new{ ui = ui })
end

return Plugin

describe("thoughtful reading", function()
    local Q, Lex

    before_each(function()
        ZenSpec.unload("modules/reader/thoughtful_reading/questions")
        ZenSpec.unload("modules/reader/thoughtful_reading/lexicon")
        Q = require("modules/reader/thoughtful_reading/questions")
        Lex = require("modules/reader/thoughtful_reading/lexicon")
    end)

    local function first(n) return n end -- keeps the order when shuffling

    describe("questions", function()
        local LIST = table.concat({
            "# comment",
            "beginning | characters |  | Who are the main protagonists?",
            "beginning | world      |  | When does the story occur?",
            "beginning | plot       | crime | Who is the first suspect?",
            "middle    | themes     |  | Which theme stands out?",
            "chapter   | personal   |  | What stayed with you?",
            "series    | plot       |  | What happened before this volume?",
            "beginning | plot       | nonfiction | What does the author want to show?",
            "broken line without separators",
        }, "\n")

        it("reads the question file and gives every question a stable id", function()
            local list = Q.parse(LIST)
            assert.are.equal(7, #list)
            assert.are.equal("beginning", list[1].section)
            assert.are.equal("characters", list[1].category)
            assert.are.same({ "crime" }, list[3].tags)
            assert.are.equal(Q.id("Who are the main protagonists?"), list[1].id)
            assert.are_not.equal(list[1].id, list[2].id)
        end)

        it("writes the list back in the same format", function()
            local list = Q.parse(LIST)
            local again = Q.parse(Q.serialize(list))
            table.sort(list, function(a, b) return a.id < b.id end)
            table.sort(again, function(a, b) return a.id < b.id end)
            assert.are.same(list, again)
        end)

        it("matches genre tags by a part of the tag and keeps nonfiction apart", function()
            local list = Q.parse(LIST)
            assert.is_true(Q.fits(list[3], { "dark crime" }, false))
            assert.is_false(Q.fits(list[3], { "fantasy" }, false))
            assert.is_false(Q.fits(list[1], { "sachbuch" }, Q.isNonfiction({ "sachbuch" })))
            assert.is_true(Q.fits(list[7], { "sachbuch" }, Q.isNonfiction({ "sachbuch" })))
            assert.is_false(Q.isNonfiction({ "science-fiction" }))
            assert.are.same({ "warhammer 40k", "science-fiction" }, Q.bookTags("Warhammer 40K\nScience-Fiction"))
        end)

        it("picks different categories, never an answered question, series questions in later volumes", function()
            local list = Q.parse(LIST)
            local picked = Q.pick(list, { section = "beginning", tags = {}, nonfiction = false, random = first }, 2)
            assert.are.equal(2, #picked)
            assert.are_not.equal(picked[1].category, picked[2].category)
            local answered = { [picked[1].id] = true, [picked[2].id] = true }
            local next_pick = Q.pick(list, { section = "beginning", tags = {}, nonfiction = false, answered = answered, random = first }, 3)
            assert.is_true(#next_pick > 0)
            for _i, q in ipairs(next_pick) do assert.is_nil(answered[q.id]) end
            local later = Q.pick(list, { section = "beginning", tags = {}, nonfiction = false, series_volume = 2, random = first }, 1)
            assert.are.equal("series", later[1].section)
        end)

        it("knows the part of the book from the position", function()
            assert.are.equal("beginning", Q.sectionAt(0.1))
            assert.are.equal("middle", Q.sectionAt(0.5))
            assert.are.equal("end", Q.sectionAt(0.95))
            assert.are.equal("end", Q.sectionAt(0.6, true))
        end)

        it("ships a question file that parses", function()
            local list = Q.load({ ZenSpec.root .. "/modules/reader/thoughtful_reading/questions.txt" })
            assert.is_true(#list > 40)
            for _i, q in ipairs(list) do
                assert.is_truthy(Q.CATEGORY_TITLE[q.category], q.text)
            end
        end)
    end)

    describe("lexicon", function()
        local CARDS = table.concat({
            "## Ciaphas Cain",
            "Kind: Person",
            "Also: Cain",
            "→ Friend: Jurgen",
            "## Jurgen",
            "Kind: Person",
            "## Amberley Vail",
            "Kind: Person",
            "Role: Side",
            "## Valhalla",
            "Kind: Place",
        }, "\n")

        it("reads the people of a book lexicon", function()
            local cards = Lex.parse(CARDS)
            assert.are.equal(4, #cards)
            assert.are.equal(3, #Lex.persons(cards))
            assert.are.same({ "Cain" }, cards[1].also)
            assert.are.equal("Side", cards[3].role)
            assert.are.equal("Friend", Lex.related(cards[2], cards[1]))
        end)

        it("counts whole names, the longer name first, and finds the main characters", function()
            local cards = Lex.parse(CARDS)
            local tally = Lex.count("Ciaphas Cain met Jurgen. Cain's orders reached Jurgen; Cains Leute, Amberley Vail.",
                cards, {})
            assert.are.equal(3, tally["Ciaphas Cain"])
            assert.are.equal(2, tally["Jurgen"])
            assert.are.equal(1, tally["Amberley Vail"])
            local roles = Lex.roles(cards, tally)
            assert.are.equal("Ciaphas Cain", roles[1].name)
            assert.are.equal("Main", roles[1].role)
            assert.are.equal("Main", roles[2].role)
            assert.are.equal("Side", roles[3].role)
            assert.is_true(roles[3].fixed)
        end)

        it("names the lexicon folder like the book lexicon does", function()
            assert.are.equal("Sandy Mitchell - For the Emperor",
                Lex.key({ authors = "Sandy Mitchell\nOther", title = "For the Emperor" }))
            assert.are.equal("book", Lex.key({}, "/books/book.epub"))
        end)
    end)
end)

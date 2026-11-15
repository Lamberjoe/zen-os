describe("book lexicon store", function()
    local S, root
    local lfs = require("libs/libkoreader-lfs")

    local SAMPLE = table.concat({
        "# Gaunt's Ghosts",
        "",
        "## Ibram Gaunt",
        "Kind: Person",
        "Also: Gaunt, Colonel-Commissar",
        "Picture: gaunt.jpg",
        "Rank: Colonel-Commissar",
        "→ Enemy: Chaos",
        "",
        "- Leads the Tanith First.",
        "- > \"Men of Tanith, do you want to live forever?\" — *p. 12*",
        "",
        "## Chaos",
        "Kind: Group",
        "→ Enemy: Ibram Gaunt",
        "",
    }, "\n")

    local function lexicon()
        local dir = root .. "/Books/Abnett - First and Only"
        return { dir = dir, file = dir .. "/lexicon.md", cards = {}, title = "First and Only" }
    end

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        G_reader_settings:reset({})
        ZenSpec.replace("datastorage", { getDataDir = function() return root end })
        ZenSpec.unload("modules/reader/lexicon/store")
        S = require("modules/reader/lexicon/store")
    end)

    after_each(function()
        os.execute("rm -rf '" .. root .. "'")
        ZenSpec.unload("modules/reader/lexicon/store")
        ZenSpec.unload("datastorage")
    end)

    local function reader(title, author)
        local settings = ZenSpec.memorySettings()
        return { document = { file = "/books/" .. title .. ".epub" }, doc_settings = settings,
            doc_props = { title = title, authors = author } }
    end

    it("follows the ZenOS feature switch", function()
        assert.is_false(S.enabled())
        S.configure({ config = { features = { book_lexicon = true } } })
        assert.is_true(S.enabled())
        S.configure({ config = { features = { book_lexicon = false } } })
        assert.is_false(S.enabled())
    end)

    it("reads cards, facts, other names, relations, notes and quotes", function()
        local cards, title = S.parse(SAMPLE)
        assert.are.equal("Gaunt's Ghosts", title)
        assert.are.equal(2, #cards)
        local gaunt = cards[1]
        assert.are.equal("Ibram Gaunt", gaunt.name)
        assert.are.equal("Person", gaunt.kind)
        assert.are.same({ "Gaunt", "Colonel-Commissar" }, gaunt.also)
        assert.are.equal("gaunt.jpg", gaunt.picture)
        assert.are.same({ { k = "Rank", v = "Colonel-Commissar" } }, gaunt.facts)
        assert.are.same({ { type = "Enemy", target = "Chaos" } }, gaunt.rels)
        assert.are.equal(2, #gaunt.notes)
        assert.is_false(gaunt.notes[1].passage)
        assert.is_true(gaunt.notes[2].passage)
        assert.are.equal("p. 12", gaunt.notes[2].src)
        assert.are.equal("Group", cards[2].kind)
    end)

    it("keeps a fact named like the kind when its value is not a kind", function()
        local cards = S.parse("## Tanith\nKind: Place\nArt: Forest world\n")
        assert.are.equal("Place", cards[1].kind)
        assert.are.same({ { k = "Art", v = "Forest world" } }, cards[1].facts)
    end)

    it("writes the file back without losing anything", function()
        local lex = lexicon()
        lex.cards, lex.title = S.parse(SAMPLE)
        local again = S.parse(S.serialize(lex))
        assert.are.same(lex.cards, again)
    end)

    it("finds a card by its name or another name, ignoring case", function()
        local lex = lexicon()
        lex.cards = S.parse(SAMPLE)
        assert.are.equal(lex.cards[1], S.findCard(lex, "ibram gaunt"))
        assert.are.equal(lex.cards[1], S.findCard(lex, "Colonel-Commissar"))
        assert.is_nil(S.findCard(lex, "Corbec"))
    end)

    it("saves a backup and adds relations on both cards", function()
        local lex = lexicon()
        local gaunt = S.addCard(lex, "Ibram Gaunt", "Person")
        local corbec = S.addCard(lex, "Colm Corbec", "Person")
        assert.are.equal("file", lfs.attributes(lex.file, "mode"))
        S.addRelation(lex, gaunt, "Member of", corbec)
        assert.are.same({ { type = "Member of", target = "Colm Corbec" } }, gaunt.rels)
        assert.are.same({ { type = "Has member", target = "Ibram Gaunt" } }, corbec.rels)
        assert.are.equal("file", lfs.attributes(lex.file .. ".bak", "mode"))
        S.removeRelation(lex, gaunt, gaunt.rels[1])
        assert.are.same({}, gaunt.rels)
        assert.are.same({}, corbec.rels)
    end)

    it("moves the relations of other cards along when a card is renamed", function()
        local lex = lexicon()
        local gaunt = S.addCard(lex, "Gaunt", "Person")
        local corbec = S.addCard(lex, "Corbec", "Person")
        S.addRelation(lex, corbec, "Friend", gaunt)
        S.renameCard(lex, gaunt, "Ibram Gaunt")
        assert.are.equal("Ibram Gaunt", corbec.rels[1].target)
        assert.are.equal(gaunt, S.relTarget(corbec.rels[1], lex))
    end)

    it("keeps the relation types in KOReader's settings", function()
        local types = S.relTypes()
        assert.is_true(#types >= 5)
        assert.are.equal("Has member", S.counterpart("Member of"))
        assert.are.equal("Friend", S.counterpart("Friend"))
        assert.is_table(G_reader_settings:readSetting("book_lexicon"))
    end)

    it("shows kinds and standard relation types as translated text", function()
        assert.are.equal("Person", S.kindText("Person"))
        assert.are.equal("Places", S.kindPlural("Place"))
        assert.are.equal("Other", S.kindText("Unknown"))
        assert.are.equal("Member of", S.relText("Member of"))
        assert.are.equal("Own type", S.relText("Own type"))
    end)

    it("keeps roles as English words in the file and shows them translated", function()
        local cards = S.parse("## Sulla\nKind: Person\nRolle: Nebenfigur\n## Gaunt\nKind: Person\nRole: Main\n")
        assert.are.equal("Supporting", S.roleOf(cards[1]))
        assert.are.equal("Main", S.roleOf(cards[2]))
        assert.are.equal("Role: Supporting", S.factText(cards[1].facts[1]))
        assert.are.equal("Own role", S.roleKey(" Own role "))
    end)

    it("finds names through the lexicon index, also forms and parts of names", function()
        local ui = reader("First and Only", "Dan Abnett")
        local lex = S.bookLex(ui)
        S.addCard(lex, "Ibram Gaunt", "Person")
        S.addCard(lex, "Colm Corbec", "Person").also = { "Corbec" }
        S.save(lex)
        assert.are.equal("Colm Corbec", (S.lookup(ui, "Corbec's")).name)
        assert.are.equal("Ibram Gaunt", (S.lookup(ui, "„Ibram Gaunt“")).name)
        assert.are.equal(1, #S.partialLookup(ui, "Gaunt"))
        assert.are.equal(2, #S.cardsInText(ui, "Ibram Gaunt looked at Corbec."))
    end)

    it("stays with the book when its title changes later", function()
        local ui = reader("First and Only", "Dan Abnett")
        local lex = S.bookLex(ui)
        S.addCard(lex, "Ibram Gaunt", "Person")
        ui.doc_props.title = "First & Only"
        assert.are.equal(lex.dir, S.bookLex(ui).dir)
        assert.are.equal(1, #S.bookCards(ui))
    end)

    it("does not overwrite a lexicon file changed elsewhere", function()
        local shown
        ZenSpec.replace("ui/uimanager", { show = function(_self, widget) shown = widget end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, o) return o end })
        local lex = lexicon()
        S.addCard(lex, "Ibram Gaunt", "Person")
        lex.mtime = lex.mtime - 10
        S.addCard(lex, "Colm Corbec", "Person")
        assert.is_truthy(shown)
        local f = io.open(lex.file, "r")
        local text = f:read("*a")
        f:close()
        assert.is_nil(text:find("Corbec"))
        ZenSpec.unload("ui/uimanager")
        ZenSpec.unload("ui/widget/infomessage")
    end)
end)

-- Words that are titles or fillers, not names ("Lord", "der", "Captain").
-- A word in this list alone never finds a card.
local TITLES = {}
for _i, w in ipairs({
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "von", "van", "zu", "und",
    "the", "a", "an", "of", "and",
    "lord", "lady", "ser", "sir", "king", "queen", "prince", "princess", "captain", "lieutenant",
    "sergeant", "brother", "sister", "father", "mother", "master", "mistress", "doctor", "dr",
    "könig", "königin", "prinz", "prinzessin", "hauptmann", "leutnant", "bruder", "schwester",
    "vater", "mutter", "meister", "herr", "frau", "fürst", "graf", "gräfin", "herzog", "kaiser",
}) do TITLES[w] = true end
return TITLES

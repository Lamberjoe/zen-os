-- Icons of the lexicon (in ZenOS's icons/ folder).
local utils = require("common/utils")
local icons_dir = require("common/plugin_root") .. "/icons/"

local M = {}

function M.path(name)
    return utils.resolveLocalIcon(icons_dir, name)
end

return M

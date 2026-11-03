-- shiny_savestate.lua (lives in data/)
-- Auto-Catch Settings' "Save a savestate file when a shiny appears": a
-- named savestate in autocrystal/autosaves/ the moment a module finds a
-- shiny, so it's never lost - whatever the catch, a crash or the player
-- does next. Load it with File > Load State > Load Named State...

local Paths = require("data.paths")

local M = {}

-- Saves now. speciesName goes into the file name (letters and digits
-- only). Never stops the bot: a failed save is printed and that's all.
-- Returns the path, or nil if it couldn't be written.
function M.save(speciesName)
    local name = tostring(speciesName or "Pokemon"):gsub("[^%w]", "")
    if name == "" then name = "Pokemon" end
    local file = string.format("shiny_%s_%s.State", name, os.date("%Y-%m-%d_%H-%M-%S"))
    local path = Paths.autosave_path(file)
    local saveOk = false
    pcall(function() saveOk = savestate.save(path, true) end)
    -- Older BizHawk returns nothing from savestate.save - check the file.
    if saveOk == nil or saveOk == false then
        local f = io.open(path, "rb")
        if f then
            f:close()
            saveOk = true
        end
    end
    if saveOk then
        print("Shiny savestate saved: autocrystal/autosaves/" .. file)
        return path
    end
    print("Couldn't save the shiny savestate (" .. file .. ") - the hunt carries on.")
    return nil
end

-- The usual call from a module: saves only with the setting ticked.
function M.save_if_enabled(gui, hud, speciesName)
    if gui and gui.shiny_savestate_enabled and gui.shiny_savestate_enabled(hud) then
        return M.save(speciesName)
    end
end

return M

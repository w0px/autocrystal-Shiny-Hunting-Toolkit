-- paths.lua (lives in data/)
-- Where the bot puts the files it writes as it runs, so users can find
-- them: autocrystal/logs/ for every log, autocrystal/autosaves/ for the
-- safety-net savestates (Kill mode's, and the backups taken whenever a
-- module's Start writes over a savestate slot). Both used to sit in
-- modules/data/, mixed in with the bot's own data files.
--
-- Lua can't make a folder by itself, so a missing one is made with mkdir -
-- one quick console-window flash, only the first time.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local data_dir = script_path:match("(.*[/\\])") or "./"

-- The autocrystal folder: this file is autocrystal/modules/data/paths.lua.
M.ROOT = data_dir:match("^(.*[/\\])modules[/\\]data[/\\]$") or (data_dir .. "../../")
M.LOG_DIR = M.ROOT .. "logs/"
M.AUTOSAVE_DIR = M.ROOT .. "autosaves/"

local ready = {}

-- Renaming a folder to itself only works when it exists (checked against
-- BizHawk's own lua54.dll).
local function exists(dir)
    return os.rename(dir, dir) == true
end

-- Makes sure every folder given exists - one mkdir for all the missing
-- ones. Checked once per session per folder.
function M.ensure(...)
    local missing = {}
    for _, dir in ipairs({...}) do
        if not ready[dir] then
            ready[dir] = true
            if not exists(dir) then
                table.insert(missing, '"' .. dir:gsub("/", "\\"):gsub("\\$", "") .. '"')
            end
        end
    end
    if #missing > 0 then
        pcall(os.execute, "mkdir " .. table.concat(missing, " ") .. " 2>nul")
    end
end

-- A file in logs/ - the folder is made if it isn't there yet.
function M.log_path(name)
    M.ensure(M.LOG_DIR)
    return M.LOG_DIR .. name
end

-- A file in autosaves/ - the folder is made if it isn't there yet.
function M.autosave_path(name)
    M.ensure(M.AUTOSAVE_DIR)
    return M.AUTOSAVE_DIR .. name
end

return M

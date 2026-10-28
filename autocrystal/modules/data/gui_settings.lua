-- gui_settings.lua (lives in data/)
-- Persists GUI settings that would otherwise live only in the in-memory
-- widgets table (gui_module.lua's `w`) and get wiped out every time the
-- script is reloaded (switching to a different profile/save, or just
-- restarting BizHawk) - unlike the lifetime hunt stats (wild_stats.txt),
-- these are pure UI settings with no per-encounter write pattern, so they
-- get their own small file and are only written when actually changed
-- (a settings popup's Save button - see gui_module.lua's
-- PERSISTED_POPUP_SETTINGS for exactly which settings, and under which
-- keys).
--
-- Started out holding just the Discord ping user/role ID + whether
-- pinging is enabled; those two keep their original "pingenabled"/
-- "pingid" names so an older gui_settings.txt still loads.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local SETTINGS_FILE_PATH = script_dir .. "gui_settings.txt"

-- key -> raw string value, exactly as stored on disk. Keys missing here
-- were never saved, so callers keep their own defaults for them.
M.values = {}

function M.load()
    local f = io.open(SETTINGS_FILE_PATH, "r")
    if f == nil then return end
    for line in f:lines() do
        -- Same trailing-"\r" tolerance as data/stats.lua's parser (a copy
        -- of the file edited/saved elsewhere with CRLF line endings).
        line = line:gsub("\r$", "")
        local key, value = line:match("^(%a+)=(.*)$")
        if key then
            M.values[key] = value
        end
    end
    f:close()
end

-- nil if the key was never saved.
function M.get_bool(key)
    local value = M.values[key]
    if value == nil then return nil end
    return value == "1"
end

function M.get_text(key)
    return M.values[key]
end

-- Updates the in-memory value only - call M.save() to write it out.
-- Returns true if this actually changed anything.
function M.set(key, value)
    local text
    if type(value) == "boolean" then
        text = value and "1" or "0"
    else
        -- Settings files are one key per line, so a value can't span
        -- lines (single-line textboxes never produce one anyway).
        text = tostring(value or ""):gsub("[\r\n]", "")
    end
    if M.values[key] == text then return false end
    M.values[key] = text
    return true
end

function M.save()
    local keys = {}
    for key, _ in pairs(M.values) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do
        table.insert(lines, key .. "=" .. M.values[key] .. "\n")
    end

    local f = io.open(SETTINGS_FILE_PATH, "w")
    if f == nil then
        print("WARNING: couldn't write " .. SETTINGS_FILE_PATH .. " - GUI settings won't be remembered next time")
        return
    end
    f:write(table.concat(lines))
    f:close()
end

return M

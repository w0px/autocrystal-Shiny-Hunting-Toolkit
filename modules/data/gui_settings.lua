-- gui_settings.lua (lives in data/)
-- Persists small cross-session GUI preferences that would otherwise live
-- only in the in-memory widgets table (gui_module.lua's `w`) and get
-- wiped out every time the script is reloaded (switching to a different
-- profile/save, or just restarting BizHawk) - unlike the lifetime hunt
-- stats (wild_stats.txt), these are pure UI settings with no per-
-- encounter write pattern, so they get their own small file and are only
-- written when actually changed (Discord Settings' Save button, or its
-- window being closed), not every frame.
--
-- Currently just the Discord ping user/role ID + whether pinging is
-- enabled - the one setting that was getting lost on every reload. Add
-- more keys here later if other GUI settings need the same treatment.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local SETTINGS_FILE_PATH = script_dir .. "gui_settings.txt"

M.pingEnabled = false
M.pingIdText = ""

function M.load()
    local f = io.open(SETTINGS_FILE_PATH, "r")
    if f == nil then return end
    for line in f:lines() do
        local key, value = line:match("^(%a+)=(.*)$")
        if key == "pingenabled" then
            M.pingEnabled = (value == "1")
        elseif key == "pingid" then
            M.pingIdText = value
        end
    end
    f:close()
end

function M.save()
    local f = io.open(SETTINGS_FILE_PATH, "w")
    if f == nil then
        print("WARNING: couldn't write " .. SETTINGS_FILE_PATH .. " - the ping user/role ID won't be remembered next time")
        return
    end
    f:write(string.format("pingenabled=%s\npingid=%s\n", M.pingEnabled and "1" or "0", M.pingIdText or ""))
    f:close()
end

return M

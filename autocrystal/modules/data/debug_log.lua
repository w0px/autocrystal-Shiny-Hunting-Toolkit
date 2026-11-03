-- debug_log.lua (lives in data/)
-- The bot's main log, logs/autocrystal_log.txt - always kept: everything
-- the bot prints, each line with its time, plus every Start/Stop (with the
-- module, the ROM and the settings) and the traceback of any error that
-- stops the bot. It's what a user sends along with a bug report.
--
-- The Lua Console only shows any of it with Advanced Settings' "Verbose
-- Logging" ticked, which also adds the bot's extra detail lines (vprint)
-- to both. Unticked, the console stays empty - BizHawk still shows a Lua
-- error there itself, and the standalone diagnose_*.lua scripts print
-- there through AutocrystalConsolePrint either way.
--
-- At MAX_BYTES the file moves to autocrystal_log.old.txt and a new one
-- starts, so the two never take more than twice that on disk.
--
-- The Discord webhook and ping ID never go in: the settings line leaves
-- them out, and nothing the bot prints contains them.

local Paths = require("data.paths")
local GuiSettings = require("data.gui_settings")

local M = {}

local FILE_NAME = "autocrystal_log.txt"
local OLD_FILE_NAME = "autocrystal_log.old.txt"
-- The two together stay under Discord's 10 MB upload limit.
local MAX_BYTES = 4 * 1024 * 1024
-- gui_settings.txt keys the settings line leaves out.
local PRIVATE_SETTINGS = {discordwebhook = true, pingid = true}

local isVerbose = function() return false end
local file = nil
local bytes = 0
local lastFlush = 0
local headerWritten = false

local function close()
    if file then pcall(file.close, file) end
    file = nil
end

local function open()
    file = io.open(Paths.log_path(FILE_NAME), "a")
    if file == nil then return false end
    bytes = file:seek("end") or 0
    return true
end

local function rotate()
    close()
    local old = Paths.log_path(OLD_FILE_NAME)
    os.remove(old)
    os.rename(Paths.log_path(FILE_NAME), old)
    open()
end

-- Flushed at most once a second - often enough that a crash loses next to
-- nothing, rare enough to cost nothing at unthrottled speed.
local function write_raw(line)
    if file == nil and not open() then return end
    file:write(line, "\n")
    bytes = bytes + #line + 2
    if bytes > MAX_BYTES then rotate() end
    local now = os.time()
    if file and now ~= lastFlush then
        lastFlush = now
        file:flush()
    end
end

local function flush()
    if file then pcall(file.flush, file) end
end

-- Verbose Logging ticked - the console shows everything, and vprint lines
-- happen at all.
function M.verbose()
    local ok, on = pcall(isVerbose)
    return ok and on == true
end

-- One line in the log, with the date and time.
function M.note(text)
    if not headerWritten then
        headerWritten = true
        write_raw("")
        write_raw(os.date("===== autocrystal log - %Y-%m-%d %H:%M:%S ====="))
        local ok, version = pcall(function() return client.getversion() end)
        write_raw("BizHawk " .. (ok and tostring(version) or "(version unknown)"))
    end
    write_raw(os.date("%Y-%m-%d %H:%M:%S  ") .. text)
    -- Start/Stop lines go to disk right away.
    if text:sub(1, 5) == "=====" then flush() end
end

-- What a Start ran with: the module, the ROM and every setting.
function M.on_start(description)
    M.note("===== Start: " .. description .. " =====")
    local okName, rom = pcall(function() return gameinfo.getromname() end)
    local okHash, hash = pcall(function() return gameinfo.getromhash() end)
    M.note(string.format("ROM: %s (hash %s)", okName and tostring(rom) or "?", okHash and tostring(hash) or "?"))
    local keys = {}
    for key in pairs(GuiSettings.values) do
        if not PRIVATE_SETTINGS[key] then table.insert(keys, key) end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, key .. "=" .. GuiSettings.values[key])
    end
    M.note("Settings: " .. table.concat(parts, " "))
end

-- Runs fn(...) and returns what it returns. An error it throws is written
-- to the log with its traceback first, then thrown on unchanged - the Lua
-- Console shows it and the script stops, same as without the log.
function M.call(label, fn, ...)
    local traceback
    local results = table.pack(xpcall(fn, function(err)
        traceback = debug.traceback(tostring(err), 2)
        return err
    end, ...))
    if results[1] then return table.unpack(results, 2, results.n) end
    M.note("ERROR in " .. label .. ": " .. tostring(traceback))
    flush()
    error(results[2], 0)
end

-- Every print() goes to the log, and to the Lua Console only while
-- isVerboseFn() is true. The real print is kept in a global, so loading
-- the launcher a second time can't wrap it twice - and so standalone
-- scripts can still print to the console (AutocrystalConsolePrint).
function M.install(isVerboseFn)
    isVerbose = isVerboseFn
    AutocrystalConsolePrint = AutocrystalConsolePrint or print
    print = function(...)
        local args = table.pack(...)
        if M.verbose() then AutocrystalConsolePrint(...) end
        -- Never allowed to break printing itself.
        pcall(function()
            local parts = {}
            for i = 1, args.n do parts[i] = tostring(args[i]) end
            M.note(table.concat(parts, " "))
        end)
    end
end

return M

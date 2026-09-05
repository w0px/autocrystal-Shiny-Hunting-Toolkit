-- console_log.lua (lives in data/)
-- Shared helper for keeping BizHawk's own Lua console usable at high
-- encounter counts. Used by every hunting module (wild, static, fishing,
-- headbutt, egg, starters, gamecorner) so they all get the same fix and
-- the same tuning knobs instead of copy-pasted constants that could
-- drift out of sync between files.
--
-- Background: BizHawk's Lua console has no cap on how much text it
-- accumulates, and appending to it gets progressively slower as its own
-- backlog grows into the tens of thousands of lines. A real user report
-- confirmed a noticeable slowdown around ~20,000 encounters, previously
-- worked around by manually closing and reopening the console (which
-- throws away its internal buffer). M.maybe_clear_console() below is the
-- automatic version of that same workaround.
--
-- On top of that: clearing the console obviously throws away the
-- scrollback along with it. M.log_encounter() writes the same per-
-- encounter line to a small rotating log file on disk instead, so full
-- history is always still available even right after a clear - added
-- per a direct user request ("write the last 20k encounters in a
-- different log, to reduce the bloat in the console").

local M = {}

-- How often (in encounters/resets) to clear the BizHawk console.
-- Raised from an initial 2000 to 5000 per user request - still
-- comfortably below where the slowdown was actually observed (~20,000),
-- just keeps more visible scrollback in the console between clears.
M.CONSOLE_CLEAR_INTERVAL = 5000

-- count should be whatever per-attempt counter the calling module
-- already tracks (resetCount / sessionEncounterCount / etc.) - callers
-- pass their own so this stays a pure "does count hit the interval"
-- check with no state of its own to get out of sync.
function M.maybe_clear_console(count)
    if count % M.CONSOLE_CLEAR_INTERVAL == 0 then
        console.clear()
    end
end

-- Per-module rotating encounter log. Each module gets its own file
-- (e.g. wild_encounter_log.txt) so lines from different hunting modes
-- never interleave. Capped instead of growing forever: once the
-- current file reaches LOG_ROTATE_LINES lines, it's rotated to a
-- ".old" file (overwriting whatever was previously there) and a fresh
-- current file is started. That guarantees the current file alone
-- always holds your most recent (up to LOG_ROTATE_LINES) encounters,
-- and the .old file holds the previous full batch - so "the last ~20k
-- encounters" is always findable across the two files without ever
-- re-reading or rewriting the whole log on every single line (which
-- would just reintroduce the same kind of per-encounter I/O cost this
-- whole thing is meant to avoid).
local LOG_ROTATE_LINES = 20000

local openLogs = {} -- module_name -> {path, oldPath, file, lineCount}

local function script_dir()
    local script_path = debug.getinfo(1, "S").source:sub(2)
    return script_path:match("(.*[/\\])") or "./"
end

local function open_current(state)
    state.file = io.open(state.path, "a")
end

-- Call once per attempt/encounter with the same line you're already
-- printing to the console, plus a short module_name ("wild", "static",
-- "egg", etc.) to key its own log file. Deliberately does NOT flush
-- after every write - Lua's own buffering is far cheaper than a flush
-- per line, and this is a supplementary convenience log, not something
-- the bot's own logic depends on, so losing the last few unflushed
-- lines in a hard crash is an acceptable tradeoff for not reintroducing
-- per-encounter I/O overhead.
function M.log_encounter(module_name, line)
    local state = openLogs[module_name]
    if state == nil then
        local dir = script_dir()
        state = {
            path = dir .. module_name .. "_encounter_log.txt",
            oldPath = dir .. module_name .. "_encounter_log.txt.old",
            lineCount = 0,
        }
        open_current(state)
        openLogs[module_name] = state
    end

    if state.file == nil then
        -- Couldn't open it (e.g. permissions) - don't retry every
        -- single encounter, just silently skip the file log. The
        -- console print itself (unaffected by this) still happens.
        return
    end

    state.file:write(line, "\n")
    state.lineCount = state.lineCount + 1

    if state.lineCount >= LOG_ROTATE_LINES then
        state.file:close()
        os.remove(state.oldPath)
        os.rename(state.path, state.oldPath)
        state.lineCount = 0
        open_current(state)
    end
end

return M

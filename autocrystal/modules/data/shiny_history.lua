-- shiny_history.lua (lives in data/)
-- The most recent shinies, for the launcher's RECENT SHINIES panel: when,
-- which species and how many encounters it took. Stats.record_shiny()
-- adds to it, so every module's shinies land here. Its own file next to
-- wild_stats.txt (that one is signed - see stats.lua's check line), one
-- shiny per line: time|species|encounters (species blank for an egg).

local M = {}

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local FILE_PATH = script_dir .. "shiny_history.txt"
-- How many are kept (the panel shows the first few).
local KEEP = 20

-- Newest first: {time = os.time(), species = id or nil, encounters = n}
M.entries = {}
-- Goes up with every change, so the launcher knows when to redraw.
M.version = 0
M.loaded = false

function M.load()
    M.loaded = true
    M.entries = {}
    local f = io.open(FILE_PATH, "r")
    if f == nil then return end
    for line in f:lines() do
        local t, s, n = line:match("^(%d+)|(%d*)|(%d+)")
        if t then
            M.entries[#M.entries + 1] = {time = tonumber(t), species = tonumber(s), encounters = tonumber(n)}
        end
    end
    f:close()
    M.version = M.version + 1
end

local function save()
    local f = io.open(FILE_PATH, "w")
    if f == nil then return end
    for _, e in ipairs(M.entries) do
        f:write(string.format("%d|%s|%d\n", e.time, e.species and tostring(e.species) or "", e.encounters or 0))
    end
    f:close()
end

-- speciesId may be nil (a shiny egg); encounters is how many it took.
function M.add(speciesId, encounters)
    if not M.loaded then M.load() end
    table.insert(M.entries, 1, {time = os.time(), species = speciesId, encounters = encounters or 0})
    while #M.entries > KEEP do table.remove(M.entries) end
    save()
    M.version = M.version + 1
end

return M

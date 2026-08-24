-- stats.lua (lives in data/)
-- Shared lifetime stats across ALL modules (wild, starters, future ones).
-- One file, one set of numbers, regardless of which mode contributed to
-- them - "TOTAL ENCOUNTERS" means total across everything you've ever
-- run, not per-module.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local STATS_FILE_PATH = script_dir .. "wild_stats.txt"
-- Confirmed via a real user report: after a PC restart, TOTAL ENCOUNTERS
-- read 0 in the live GUI AND in wild_stats.txt itself - a real lifetime
-- total (hundreds of thousands of encounters) silently wiped. Nothing in
-- this codebase ever intentionally resets these stats (verified - the
-- only reads/writes of this file are M.load()/M.save() below), so the
-- leading suspect is a race with something outside Lua's control - e.g.
-- a cloud-synced folder (OneDrive Files On-Demand and similar) leaving
-- this file as a 0-byte placeholder for a moment right after boot, until
-- Windows actually re-downloads/hydrates it. If BizHawk's very first
-- M.load() this session hits that window, io.open succeeds but the file
-- reads as empty - completely indistinguishable, from here, from a
-- genuinely fresh install. Every field then silently stays at its
-- default of 0, and the very next M.save() (triggered by the first
-- encounter) bakes those zeros over the real file, permanently.
-- BAK_FILE_PATH exists specifically to survive that: M.save() only ever
-- refreshes it from a primary file that just parsed successfully -
-- never from a corrupted one - so it always holds the last CONFIRMED-
-- good snapshot. M.load() falls back to it automatically if the primary
-- file exists but nothing recognizable could be parsed from it.
local BAK_FILE_PATH = STATS_FILE_PATH .. ".bak"

M.totalEncounters = 0
M.totalShinies = 0
M.encountersSinceShiny = 0
-- Set of species IDs already caught via auto-catch (key = species ID,
-- value = true). Persisted the same way as the numeric stats above -
-- lets "catch each species only once" work across sessions, not just
-- within a single run.
M.caughtSpecies = {}
-- Per-species lifetime encounter counts (key = species ID, value =
-- count). Separate from totalEncounters, which is the sum across every
-- species combined.
M.speciesEncounters = {}
-- Per-species lifetime shiny counts (key = species ID, value = count).
-- Separate from totalShinies, which is the sum across every species
-- combined.
M.speciesShinies = {}
-- The most recent shiny's species ID (nil until the very first shiny is
-- ever found). Lifetime, persisted like everything else here - used by
-- the Discord Rich Presence relay (see data/presence.lua) as the "last
-- shiny" icon to show. egg.lua's mid-hunt shiny detection can't supply a
-- species (still 0xFD/unknown until it hatches), so this can legitimately
-- stay unset even after a shiny egg is found - callers just don't pass a
-- speciesId in that case, same as it's always worked for the per-species
-- counters below.
M.lastShinySpeciesId = nil

-- Parses one stats file (primary or backup) into M's fields. Returns
-- true if a recognized "encounters=" line was actually found - the one
-- signal M.load() below uses to tell "this file has real data" apart
-- from "this file exists but is empty/corrupted" (a plain empty file
-- and a fresh, hasn't-hunted-yet-but-genuinely-new file are otherwise
-- indistinguishable).
local function parse_stats_file(f)
    local sawEncounters = false
    for line in f:lines() do
        local key, value = line:match("^(%a+)=(.+)$")
        if key == "encounters" then
            M.totalEncounters = tonumber(value)
            sawEncounters = true
        elseif key == "shinies" then
            M.totalShinies = tonumber(value)
        elseif key == "sinceshiny" then
            M.encountersSinceShiny = tonumber(value)
        elseif key == "lastshinyspecies" then
            M.lastShinySpeciesId = tonumber(value)
        elseif key == "caughtspecies" then
            for idStr in value:gmatch("[^,]+") do
                local id = tonumber(idStr)
                if id ~= nil then
                    M.caughtSpecies[id] = true
                end
            end
        elseif key == "speciesencounters" then
            for pair in value:gmatch("[^,]+") do
                local idStr, countStr = pair:match("^(%d+):(%d+)$")
                if idStr ~= nil then
                    M.speciesEncounters[tonumber(idStr)] = tonumber(countStr)
                end
            end
        elseif key == "speciesshinies" then
            for pair in value:gmatch("[^,]+") do
                local idStr, countStr = pair:match("^(%d+):(%d+)$")
                if idStr ~= nil then
                    M.speciesShinies[tonumber(idStr)] = tonumber(countStr)
                end
            end
        end
    end
    return sawEncounters
end

function M.load()
    local f = io.open(STATS_FILE_PATH, "r")
    if f == nil then
        -- No file at all yet - a genuinely fresh install. Nothing to
        -- warn about, nothing to recover; M's fields stay at their
        -- declared defaults (all 0 / empty), same as always.
        return
    end
    local sawEncounters = parse_stats_file(f)
    f:close()

    if not sawEncounters then
        -- The file exists but nothing recognizable was in it - see the
        -- BAK_FILE_PATH comment above for why this happens and what it
        -- risks. Loud on purpose: silently proceeding here is exactly
        -- what let a real user's stats get zeroed out and then
        -- permanently overwritten by the next save.
        print("WARNING: " .. STATS_FILE_PATH .. " exists but no valid stats could be read from it (empty or corrupted) - lifetime totals would start from 0 this session instead of your real history.")
        local bak = io.open(BAK_FILE_PATH, "r")
        if bak then
            local recovered = parse_stats_file(bak)
            bak:close()
            if recovered then
                print(string.format(
                    "Recovered lifetime stats from backup (%s): encounters=%d, shinies=%d. This will be written back to %s the next time stats are saved.",
                    BAK_FILE_PATH, M.totalEncounters, M.totalShinies, STATS_FILE_PATH))
            else
                print("WARNING: backup at " .. BAK_FILE_PATH .. " also has no valid stats in it - starting from 0 with no way to auto-recover this time.")
            end
        else
            print("WARNING: no backup found at " .. BAK_FILE_PATH .. " to recover from - starting from 0 this time. This backup will start being kept automatically from now on.")
        end
    end
end

-- Serializes an {id = count} table into a sorted "id:count,id:count,..."
-- string - shared by every per-species counter we persist, so
-- speciesEncounters and speciesShinies don't each need their own
-- copy-pasted sort/format loop.
local function serialize_id_counts(idCounts)
    local ids = {}
    for id, _ in pairs(idCounts) do
        table.insert(ids, id)
    end
    table.sort(ids)
    local pairsList = {}
    for _, id in ipairs(ids) do
        table.insert(pairsList, string.format("%d:%d", id, idCounts[id]))
    end
    return table.concat(pairsList, ",")
end

-- Refreshes BAK_FILE_PATH from whatever's CURRENTLY on disk at
-- STATS_FILE_PATH, right before that file gets overwritten below - but
-- ONLY if the current on-disk content actually parses (a real
-- "encounters=" line), never blindly. This is what keeps the backup
-- always holding the last CONFIRMED-good snapshot: a corrupted/empty
-- primary file is never allowed to propagate into the backup and wipe
-- out the one remaining good copy.
local function refresh_backup_if_current_file_is_valid()
    local f = io.open(STATS_FILE_PATH, "rb")
    if f == nil then return end
    local content = f:read("*a")
    f:close()
    if not content then return end

    -- "encounters=" must appear as a whole line, not just anywhere in
    -- the content - check line by line rather than one big pattern, to
    -- keep this obviously correct instead of relying on regex trickery.
    local looksValid = false
    for line in content:gmatch("[^\n]+") do
        if line:match("^encounters=%d+$") then
            looksValid = true
            break
        end
    end
    if not looksValid then return end

    local bak = io.open(BAK_FILE_PATH, "wb")
    if bak then
        bak:write(content)
        bak:close()
    end
end

function M.save()
    refresh_backup_if_current_file_is_valid()

    local f = io.open(STATS_FILE_PATH, "w")
    if f == nil then
        print("WARNING: couldn't write " .. STATS_FILE_PATH .. " - lifetime stats won't be saved")
        return
    end
    local caughtList = {}
    for id, _ in pairs(M.caughtSpecies) do
        table.insert(caughtList, id)
    end
    table.sort(caughtList)

    f:write(string.format(
        "encounters=%d\nshinies=%d\nsinceshiny=%d\ncaughtspecies=%s\nspeciesencounters=%s\nspeciesshinies=%s\n",
        M.totalEncounters, M.totalShinies, M.encountersSinceShiny, table.concat(caughtList, ","),
        serialize_id_counts(M.speciesEncounters), serialize_id_counts(M.speciesShinies)))
    if M.lastShinySpeciesId ~= nil then
        f:write(string.format("lastshinyspecies=%d\n", M.lastShinySpeciesId))
    end
    f:close()
end

-- Call once per real encounter/reset attempt, from any module. speciesId
-- is optional - callers that don't have a species on hand still get the
-- combined counters updated, just not the per-species breakdown.
function M.record_encounter(speciesId)
    M.totalEncounters = M.totalEncounters + 1
    M.encountersSinceShiny = M.encountersSinceShiny + 1
    if speciesId ~= nil then
        M.speciesEncounters[speciesId] = (M.speciesEncounters[speciesId] or 0) + 1
    end
    M.save()
end

function M.species_encounter_count(speciesId)
    return M.speciesEncounters[speciesId] or 0
end

-- Call when a shiny is found, from any module. speciesId is optional,
-- same as record_encounter above.
function M.record_shiny(speciesId)
    M.totalShinies = M.totalShinies + 1
    M.encountersSinceShiny = 0
    if speciesId ~= nil then
        M.speciesShinies[speciesId] = (M.speciesShinies[speciesId] or 0) + 1
        M.lastShinySpeciesId = speciesId
    end
    M.save()
end

function M.species_shiny_count(speciesId)
    return M.speciesShinies[speciesId] or 0
end

-- Call when a shiny is genuinely caught (not just found) via auto-catch.
function M.record_catch(speciesId)
    M.caughtSpecies[speciesId] = true
    M.save()
end

function M.is_already_caught(speciesId)
    return M.caughtSpecies[speciesId] == true
end

return M

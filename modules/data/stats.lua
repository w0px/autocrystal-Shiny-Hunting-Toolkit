-- stats.lua (lives in data/)
-- Shared lifetime stats across ALL modules (wild, starters, future ones).
-- One file, one set of numbers, regardless of which mode contributed to
-- them - "TOTAL ENCOUNTERS" means total across everything you've ever
-- run, not per-module.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local STATS_FILE_PATH = script_dir .. "wild_stats.txt"

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

function M.load()
    local f = io.open(STATS_FILE_PATH, "r")
    if f == nil then return end
    for line in f:lines() do
        local key, value = line:match("^(%a+)=(.+)$")
        if key == "encounters" then
            M.totalEncounters = tonumber(value)
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
    f:close()
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

function M.save()
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

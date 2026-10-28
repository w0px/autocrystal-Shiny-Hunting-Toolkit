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
-- M.save() writes here first and only then swaps it into place over
-- STATS_FILE_PATH - see M.save() for why.
local TMP_FILE_PATH = STATS_FILE_PATH .. ".tmp"

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
-- Per-species lifetime counts of Perfect DVs (15/15/15/15, i.e. raw
-- atkdef == spespc == 0xFF) and Perfect Negative DVs (0/0/0/0, both raw
-- bytes 0x00) - same {id = count} shape as speciesEncounters above. Only
-- counted from the point this was added onward: older history only ever
-- stored encounter/shiny counts, so there's nothing to backfill from.
-- Fed by record_encounter()'s optional atkdef/spespc args - callers that
-- don't pass them (e.g. egg.lua, which has no species yet) simply don't
-- contribute here, same as how a nil speciesId skips the per-species
-- breakdown.
M.speciesPerfect = {}
M.speciesPerfectNegative = {}
-- True once M.load() has run at least once this session - lets the
-- Encounter Stats window (stats_window.lua) load the file itself when
-- it's opened before any hunting module has been started.
M.loaded = false

-- This session's numbers - the "Session" tab of the Encounter Stats
-- window. In memory only, never saved: a session is everything recorded
-- since this file was first required, i.e. since launcher.lua was
-- loaded into BizHawk's Lua console - the same span the main window's
-- per-module "SESSION ENCOUNTERS" counter already uses. Combined across
-- every module used during that time, same as the lifetime numbers.
--
-- Encounters/hour is based on ACTIVE time, not wall-clock time since
-- load: the bot can sit stopped for a long while mid-session (after a
-- shiny stop, between modules, overnight), and counting that would make
-- the rate meaningless. Active time is built from "segments" of
-- back-to-back encounters - any gap longer than SESSION_PAUSE_SECONDS
-- between two encounters ends the current segment, and that gap itself
-- isn't counted. 5 minutes comfortably covers the slowest normal gaps
-- (static resets, savestate-pool rerolls) while still catching a real
-- Stop. Timestamps are whole seconds (os.time), so each segment is off
-- by at most ~1s - irrelevant over any real hunting session.
local SESSION_PAUSE_SECONDS = 300
M.session = {
    encounters = 0,
    shinies = 0,
    speciesEncounters = {},
    speciesShinies = {},
    speciesPerfect = {},
    speciesPerfectNegative = {},
    closedActiveSeconds = 0, -- active time from segments already ended by a pause
    segmentStart = nil,      -- os.time() of the first encounter in the current segment
    lastEncounterTime = nil, -- os.time() of the most recent encounter
}

local function note_session_encounter_time()
    local s = M.session
    local now = os.time()
    if s.lastEncounterTime == nil or now - s.lastEncounterTime > SESSION_PAUSE_SECONDS then
        if s.segmentStart ~= nil then
            s.closedActiveSeconds = s.closedActiveSeconds + (s.lastEncounterTime - s.segmentStart)
        end
        s.segmentStart = now
    end
    s.lastEncounterTime = now
end

-- Seconds of active hunting this session (see M.session above).
function M.session_active_seconds()
    local s = M.session
    if s.segmentStart == nil then return 0 end
    return s.closedActiveSeconds + (s.lastEncounterTime - s.segmentStart)
end

-- Encounters per hour of active hunting, or nil until there's at least
-- a minute of active time to divide by (a rate from a handful of
-- seconds would be wildly off).
function M.session_encounters_per_hour()
    local active = M.session_active_seconds()
    if active < 60 then return nil end
    return M.session.encounters * 3600 / active
end

-- Gen II has exactly 251 species (1-251, internal index == National Dex
-- number - see data/pokemon_names.lua's header). Anything else reaching
-- the stats is a bogus memory read, never a real encounter: a real
-- wild_stats.txt had picked up "0:1" (Unknown #0) and "255:11" - the
-- latter with 2 "shinies" counted into the lifetime shiny total - from
-- the stale/garbage battle readings that static.lua's species guards
-- were later hardened against. Checked here, at the single shared entry
-- point every module records through, so no module's own filtering can
-- ever be the last line of defense again.
local MAX_SPECIES_ID = 251
local function is_valid_species(id)
    return type(id) == "number" and id >= 1 and id <= MAX_SPECIES_ID and id == math.floor(id)
end
M.is_valid_species = is_valid_species

-- One console line per distinct bogus ID per session, not per call - a
-- stuck bogus reading can repeat every reset, and spamming the console
-- would bury everything else.
local warnedInvalidIds = {}
local function warn_invalid_species(id, what)
    local key = tostring(id)
    if warnedInvalidIds[key] then return end
    warnedInvalidIds[key] = true
    print(string.format("Stats: ignored %s for invalid species ID %s (not a real Gen II Pokemon - a bogus memory read) - not recorded.", what, key))
end

-- Parses one stats file (primary or backup) into M's fields. Returns
-- true if a recognized "encounters=" line was actually found - the one
-- signal M.load() below uses to tell "this file has real data" apart
-- from "this file exists but is empty/corrupted" (a plain empty file
-- and a fresh, hasn't-hunted-yet-but-genuinely-new file are otherwise
-- indistinguishable).
local function parse_stats_file(f)
    local sawEncounters = false
    for line in f:lines() do
        -- Tolerate a trailing "\r" (a CRLF file read without Windows'
        -- text-mode translation, e.g. a copy edited/opened elsewhere):
        -- without this, the LAST id:count pair on each per-species line
        -- silently failed the "$"-anchored pattern below and was dropped.
        line = line:gsub("\r$", "")
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
        elseif key == "speciesperfect" then
            for pair in value:gmatch("[^,]+") do
                local idStr, countStr = pair:match("^(%d+):(%d+)$")
                if idStr ~= nil then
                    M.speciesPerfect[tonumber(idStr)] = tonumber(countStr)
                end
            end
        elseif key == "speciesperfectneg" then
            for pair in value:gmatch("[^,]+") do
                local idStr, countStr = pair:match("^(%d+):(%d+)$")
                if idStr ~= nil then
                    M.speciesPerfectNegative[tonumber(idStr)] = tonumber(countStr)
                end
            end
        end
    end
    return sawEncounters
end

-- Strips any species ID that isn't a real Gen II Pokemon (see
-- is_valid_species above) out of every per-species table, and takes
-- those bogus encounters/shinies back out of the lifetime totals they
-- were added to at the same time (record_encounter/record_shiny always
-- bumped the total and the per-species count together). Runs on every
-- load, so an older wild_stats.txt that still has entries like "0:1" or
-- "255:11" gets cleaned automatically; the cleaned numbers reach disk on
-- the next M.save(). Idempotent: re-loading an unsaved file just
-- re-reads the same raw totals and subtracts the same amounts again.
local function sanitize_invalid_species()
    local removedEncounters, removedShinies, removedIds = 0, 0, {}
    for id, count in pairs(M.speciesEncounters) do
        if not is_valid_species(id) then
            removedEncounters = removedEncounters + count
            removedIds[#removedIds + 1] = tostring(id)
            M.speciesEncounters[id] = nil
        end
    end
    for id, count in pairs(M.speciesShinies) do
        if not is_valid_species(id) then
            removedShinies = removedShinies + count
            M.speciesShinies[id] = nil
        end
    end
    for _, tbl in ipairs({M.speciesPerfect, M.speciesPerfectNegative, M.caughtSpecies}) do
        for id, _ in pairs(tbl) do
            if not is_valid_species(id) then tbl[id] = nil end
        end
    end
    if M.lastShinySpeciesId ~= nil and not is_valid_species(M.lastShinySpeciesId) then
        M.lastShinySpeciesId = nil
    end
    if removedEncounters > 0 or removedShinies > 0 then
        M.totalEncounters = math.max(0, M.totalEncounters - removedEncounters)
        M.totalShinies = math.max(0, M.totalShinies - removedShinies)
        table.sort(removedIds)
        print(string.format(
            "Stats: removed bogus species entries (ID %s) - %d encounter(s) and %d shiny(s) taken back out of the lifetime totals.",
            table.concat(removedIds, ", "), removedEncounters, removedShinies))
    end
end

function M.load()
    M.loaded = true
    local f = io.open(STATS_FILE_PATH, "r")
    if f == nil then
        -- M.save() has to delete the old file before renaming the new
        -- .tmp into place (os.rename can't overwrite on Windows), so a
        -- crash between those two steps leaves only the .tmp behind. It's
        -- always a complete save at that point - the old file is only
        -- ever deleted after the .tmp was fully written and closed.
        f = io.open(TMP_FILE_PATH, "r")
        if f == nil then
            -- No file at all yet - a genuinely fresh install. Nothing to
            -- warn about, nothing to recover; M's fields stay at their
            -- declared defaults (all 0 / empty), same as always.
            return
        end
        print("Stats: " .. STATS_FILE_PATH .. " was missing, but the last save was found at " .. TMP_FILE_PATH .. " - loading that instead.")
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

    sanitize_invalid_species()
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
    -- "\r?" matters on Windows: M.save() writes in text mode, so the file
    -- on disk has CRLF line endings, but THIS read is binary ("rb"), which
    -- keeps the "\r". Without it, "encounters=123\r" never matched, so
    -- looksValid stayed false and the backup was silently never written
    -- at all (confirmed: a real install's data folder had no
    -- wild_stats.txt.bak after millions of encounters).
    local looksValid = false
    for line in content:gmatch("[^\n]+") do
        if line:match("^encounters=%d+\r?$") then
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

-- M.save() runs on EVERY single encounter (see M.record_encounter below),
-- and until now that meant a full read of the entire current stats file
-- (refresh_backup_if_current_file_is_valid, above) plus a full rewrite of
-- it, every single time - real, avoidable synchronous disk I/O on every
-- encounter. A real user report of a slowdown around ~20,000 encounters
-- prompted a look at everything in the per-encounter hot path, and this
-- was one of the things found. The backup's whole job is surviving a
-- rare corruption/race (see BAK_FILE_PATH's comment above) - it doesn't
-- need to be perfectly current to the last encounter, so refreshing it
-- every Nth save instead of every single save trades a tiny, bounded
-- amount of backup staleness (at most BACKUP_REFRESH_INTERVAL encounters'
-- worth, in the rare case a crash lands in exactly that window) for
-- cutting this file's own contribution to the per-encounter cost by the
-- same factor. The primary file itself is still rewritten every save, so
-- live stats (encounters/shinies/etc.) are never stale - only the backup
-- refresh is throttled.
local BACKUP_REFRESH_INTERVAL = 50
local savesSinceBackupRefresh = 0

-- The in-place fallback at the bottom of M.save() warns once per
-- session, not on every encounter.
local warnedInPlaceSave = false

function M.save()
    savesSinceBackupRefresh = savesSinceBackupRefresh + 1
    if savesSinceBackupRefresh >= BACKUP_REFRESH_INTERVAL then
        refresh_backup_if_current_file_is_valid()
        savesSinceBackupRefresh = 0
    end

    local caughtList = {}
    for id, _ in pairs(M.caughtSpecies) do
        table.insert(caughtList, id)
    end
    table.sort(caughtList)

    local parts = {}
    table.insert(parts, string.format(
        "encounters=%d\nshinies=%d\nsinceshiny=%d\ncaughtspecies=%s\nspeciesencounters=%s\nspeciesshinies=%s\n",
        M.totalEncounters, M.totalShinies, M.encountersSinceShiny, table.concat(caughtList, ","),
        serialize_id_counts(M.speciesEncounters), serialize_id_counts(M.speciesShinies)))
    -- Separate line group (not folded into the format string above) -
    -- older builds reading a newer file just skip these two unknown keys,
    -- since the parser above ignores any key it doesn't recognize.
    table.insert(parts, string.format("speciesperfect=%s\nspeciesperfectneg=%s\n",
        serialize_id_counts(M.speciesPerfect), serialize_id_counts(M.speciesPerfectNegative)))
    if M.lastShinySpeciesId ~= nil then
        table.insert(parts, string.format("lastshinyspecies=%d\n", M.lastShinySpeciesId))
    end
    local content = table.concat(parts)

    -- Written to TMP_FILE_PATH first, then swapped into place, so
    -- STATS_FILE_PATH is only ever the previous complete save or the new
    -- complete save - never anything in between. Writing it in place
    -- (io.open "w" empties the file immediately) left a window on every
    -- single encounter where a crash, forced shutdown or power cut could
    -- leave it empty or half-written. Empty gets caught by the .bak
    -- recovery in M.load(), but a half-written file that still has its
    -- "encounters=" line doesn't, and silently loses everything after the
    -- cut (per-species counts, caught list) on the next save.
    local tmp = io.open(TMP_FILE_PATH, "w")
    if tmp then
        local wrote = tmp:write(content)
        local closed = tmp:close()
        if wrote and closed then
            -- os.rename can't overwrite an existing file on Windows, so the
            -- old one goes first. A crash between these two calls leaves
            -- only the (complete) .tmp, which M.load() falls back to.
            os.remove(STATS_FILE_PATH)
            if os.rename(TMP_FILE_PATH, STATS_FILE_PATH) then
                return
            end
        end
    end

    -- Couldn't write or swap in the .tmp (e.g. something has a file
    -- locked) - write in place the old way rather than stop saving.
    if not warnedInPlaceSave then
        warnedInPlaceSave = true
        print("WARNING: couldn't save stats via " .. TMP_FILE_PATH .. " - writing " .. STATS_FILE_PATH .. " directly instead (not crash-safe). Further failures this session won't be reported.")
    end
    local f = io.open(STATS_FILE_PATH, "w")
    if f == nil then
        print("WARNING: couldn't write " .. STATS_FILE_PATH .. " - lifetime stats won't be saved")
        return
    end
    f:write(content)
    f:close()
end

-- Call once per real encounter/reset attempt, from any module. speciesId
-- is optional - callers that don't have a species on hand still get the
-- combined counters updated, just not the per-species breakdown.
-- atkdef/spespc are the optional RAW DV bytes (same values the shiny
-- check uses): when given, 0xFF/0xFF counts as Perfect DVs and
-- 0x00/0x00 as Perfect Negative DVs for that species.
-- A speciesId outside 1-251 is a bogus read, not an encounter, and is
-- ignored entirely (see is_valid_species above).
function M.record_encounter(speciesId, atkdef, spespc)
    if speciesId ~= nil and not is_valid_species(speciesId) then
        warn_invalid_species(speciesId, "an encounter")
        return
    end
    M.totalEncounters = M.totalEncounters + 1
    M.encountersSinceShiny = M.encountersSinceShiny + 1
    local s = M.session
    s.encounters = s.encounters + 1
    note_session_encounter_time()
    if speciesId ~= nil then
        M.speciesEncounters[speciesId] = (M.speciesEncounters[speciesId] or 0) + 1
        s.speciesEncounters[speciesId] = (s.speciesEncounters[speciesId] or 0) + 1
        if atkdef ~= nil and spespc ~= nil then
            if atkdef == 0xFF and spespc == 0xFF then
                M.speciesPerfect[speciesId] = (M.speciesPerfect[speciesId] or 0) + 1
                s.speciesPerfect[speciesId] = (s.speciesPerfect[speciesId] or 0) + 1
            elseif atkdef == 0x00 and spespc == 0x00 then
                M.speciesPerfectNegative[speciesId] = (M.speciesPerfectNegative[speciesId] or 0) + 1
                s.speciesPerfectNegative[speciesId] = (s.speciesPerfectNegative[speciesId] or 0) + 1
            end
        end
    end
    M.save()
end

function M.species_perfect_count(speciesId)
    return M.speciesPerfect[speciesId] or 0
end

function M.species_perfect_negative_count(speciesId)
    return M.speciesPerfectNegative[speciesId] or 0
end

function M.species_encounter_count(speciesId)
    return M.speciesEncounters[speciesId] or 0
end

-- Call when a shiny is found, from any module. speciesId is optional,
-- same as record_encounter above.
function M.record_shiny(speciesId)
    if speciesId ~= nil and not is_valid_species(speciesId) then
        warn_invalid_species(speciesId, "a shiny")
        return
    end
    M.totalShinies = M.totalShinies + 1
    M.encountersSinceShiny = 0
    M.session.shinies = M.session.shinies + 1
    if speciesId ~= nil then
        M.speciesShinies[speciesId] = (M.speciesShinies[speciesId] or 0) + 1
        M.session.speciesShinies[speciesId] = (M.session.speciesShinies[speciesId] or 0) + 1
        M.lastShinySpeciesId = speciesId
    end
    M.save()
end

function M.species_shiny_count(speciesId)
    return M.speciesShinies[speciesId] or 0
end

-- Call when a shiny is genuinely caught (not just found) via auto-catch.
function M.record_catch(speciesId)
    if not is_valid_species(speciesId) then
        warn_invalid_species(speciesId, "a catch")
        return
    end
    M.caughtSpecies[speciesId] = true
    M.save()
end

function M.is_already_caught(speciesId)
    return M.caughtSpecies[speciesId] == true
end

return M

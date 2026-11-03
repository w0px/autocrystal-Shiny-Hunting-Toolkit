-- frame_search.lua (lives in data/)
-- Frame search: how Static, Starters, Egg and Game Corner look for a shiny,
-- standing where the encounter starts. It replaced reloading a savestate
-- and waiting a RANDOM 1-N frames before triggering, which kept re-drawing
-- the same few hundred outcomes (Electrode: ~516 distinct DV pairs per
-- 30-minute window - see data/rng_enabler.lua and the README's "Simulating
-- Randomness"). Instead it tests every frame offset exactly once, in order:
-- save an in-memory state, run the module's press pattern only until the
-- DVs are rolled, read them, load the state back and let ONE idle frame
-- pass before the next probe. The RNG moves every frame (VBlank mixes rDIV
-- into it), so offsets keep giving new rolls, and almost no time goes to
-- waiting. Same idea as RNG manipulation in speedruns: nothing is written
-- to game memory, every encounter comes from the game's own code on a real
-- timeline.
--
-- Measured on the Rocket HQ Electrode (2026-10-28): 4.5 probes/s at 237
-- frames each (BizHawk's ~1,070 fps is the limit), and only ~49% of probes
-- gave a DV pair not seen before - at a steady rate, so not a shrinking
-- pool. The per-offset log showed why: the overworld only reacts to A
-- every other frame, so two neighbouring offsets start the script on the
-- same frame, are in the very same game state a few frames later, and roll
-- the same DVs (150 of 299 neighbours, all of them predicted by the state
-- check below). The rhythm's phase drifts, so a fixed "every 2nd frame"
-- would miss; with this check skipping them: 4.4 new DV pairs/s instead of
-- 2.4 (the rest: ~1% of first presses ignored outright - the mash press 16
-- frames later then repeats offset +15's roll). So each probe
-- fingerprints the game state (WRAM, HRAM, CPU registers) over its first
-- STATE_FRAMES frames and compares it with the previous offset's at the
-- same frames. The first CALIBRATE_OFFSETS offsets are all probed fully to
-- check that a match really means the same DVs here (later presses still
-- land a frame apart - with dialogue, that usually changes the roll and
-- skipping stays off); only if it held every time are matching offsets
-- skipped after those few frames from then on - every CHECK_EVERY-th one
-- still gets a full probe as a check, and one wrong check turns skipping
-- off for the rest of the search.
--
-- Runs unthrottled and muted while probing (both put back exactly as they
-- were). Every probe that rolls a new encounter counts as one, like a
-- reset did - but not an offset skipped as a repeat of the one before, nor
-- a check that turned out to be one (same encounter again). A probe whose
-- roll the module calls special (shiny, Perfect...) is handed over to the
-- module's own handling - after first saving the NEXT probe position into
-- the savestate slot, so whenever that handling reloads, the search
-- carries on from there instead of starting over. The state right before
-- that press is kept (replay()), so static.lua's auto-catch can go back to
-- the very same encounter if it gets away.
--
-- logs/frame_search_log.txt gets a line every LOG_SECONDS - speed
-- and how many distinct DV pairs have turned up so far - plus calibration
-- and hand-overs; at a Start it moves to frame_search_log.old.txt once it's
-- over LOG_MAX_BYTES. CSV_OFFSETS > 0 also writes one row per frame offset
-- to logs/frame_search_offsets.csv (how the repeats above were
-- found; off normally - it adds ~190 KB per 5,000).
--
-- Usage: search = FrameSearch.new(opts) on every Start, then
-- search:step() from M.step() - true means stop. While search.handedOver
-- is set, the module finishes the encounter itself; calling step() again
-- carries on. opts:
--   label        what's searched, for the log ("Static - Sudowoodo")
--   press        "tap"  A for 2 frames every MASH_EVERY (one press goes
--                       straight to battle)
--                "hold" A, let go for 2 frames at the same rhythm - text
--                       prints at full speed while A is held, each release
--                       + press advances a box (yes/no defaults to YES)
--                "walk" hold Up (Suicune: walks in from outside)
--   detect()     after every probe frame: the roll once the DVs are in -
--                {species, atkdef, spespc, item, settle = extra frames it
--                took} - else nil. M.gift_detector() builds one for a
--                Pokemon/egg that joins the party.
--   before_probe() optional - reset whatever detect() watches
--   is_real(roll) optional - false = a bogus reading, not counted (the
--                first real roll's species is enforced here on top)
--   record(roll) count it like any encounter (Stats.record_encounter with
--                skipSave - saved once per batch here)
--   special(roll) true = hand it over
--   name(species) optional - for the log (default: the Pokemon's name)
--   slot()       the module's savestate slot
--   status(text) GUI status line
--   script_addr  wScriptRunning - when the press started the NPC's script
--                (calibration log)
--   script_busy() true while any script runs on the main timeline, a
--                phone call included - M.script_busy() builds it
--   clear_script() clears that before a probe; false = give up
--   on_hand_over(roll) optional

local M = {}
M.__index = M

local Stats = require("data.stats")
local PokemonNames = require("data.pokemon_names")
local Paths = require("data.paths")

local PROBES_PER_STEP = 20      -- frame offsets per step(), then back to launcher.lua (Stop button, GUI)
local ROLL_CAP = 4000           -- frames to wait for the roll before calling a probe failed (dialogue, cutscenes)
local MASH_EVERY = 16           -- frames between A presses while waiting (text boxes)
local MAX_FAILS = 30            -- probes in a row with no roll = not standing at the encounter
local FIRST_FAILS = 3           -- the same before anything has rolled at all
local STATE_FRAMES = 12         -- opening frames of a probe that get fingerprinted (< MASH_EVERY)
local STATE_FROM = 3            -- first of those where neither probe still holds its opening A press
local CALIBRATE_OFFSETS = 300
local CHECK_EVERY = 25
local LOG_SECONDS = 60
local LOG_PATH = Paths.log_path("frame_search_log.txt")
local LOG_MAX_BYTES = 1024 * 1024
local CSV_OFFSETS = 0           -- rows per search in the CSV below (0 = no CSV)
local CSV_PATH = Paths.log_path("frame_search_offsets.csv")

-- Past LOG_MAX_BYTES it moves to frame_search_log.old.txt (overwriting the
-- one before) - checked at every Start, and every LOG_SIZE_CHECK_LINES
-- lines in between, since one search can run for days.
local LOG_SIZE_CHECK_LINES = 100
local linesSinceSizeCheck = 0

local function rotate_log_if_big()
    local f = io.open(LOG_PATH, "r")
    if f == nil then return end
    local size = f:seek("end")
    f:close()
    if size and size > LOG_MAX_BYTES then
        local old = LOG_PATH:gsub("%.txt$", ".old.txt")
        os.remove(old)
        os.rename(LOG_PATH, old)
    end
end

local function log(line)
    local f = io.open(LOG_PATH, "a")
    if f == nil then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. line .. "\n")
    f:close()
    linesSinceSizeCheck = linesSinceSizeCheck + 1
    if linesSinceSizeCheck >= LOG_SIZE_CHECK_LINES then
        linesSinceSizeCheck = 0
        rotate_log_if_big()
    end
end

-- A byte of $C000-$DFFF the way the game's own variables see it: WRAM bank
-- 0, then bank 1. On a Game Boy Color, $D000-$DFFF is a window onto one of
-- seven WRAM banks (SVBK), and every variable read here - party, map,
-- wScriptRunning - lives in bank 1. But Crystal switches bank 6 in for
-- several frames at a time while it copies a text box or menu to the
-- screen, and a plain memory.readbyte() reads whichever bank is switched
-- in when the frame ends. That was the Game Corner's endless "Abra
-- 0/0/0/0" (bank 6 holds $FC, $3F, 0, 0 at the party count, species and
-- DVs there - confirmed in a savestate) and the Odd Egg's "party count
-- 252". BizHawk's WRAM domain has every bank side by side, so bank 1
-- starts right after bank 0: $C000-$DFFF straight through.
local wramDomain
function M.wram(addr)
    if wramDomain == nil then
        wramDomain = pcall(memory.readbyte, 0, "WRAM") and "WRAM" or false
    end
    if wramDomain and addr >= 0xC000 and addr < 0xE000 then
        return memory.readbyte(addr - 0xC000, wramDomain)
    end
    return memory.readbyte(addr)
end
local wram = M.wram

-- Writes a byte of $C000-$DFFF the same way: into bank 1, where M.wram()
-- reads it back.
function M.wram_write(addr, value)
    M.wram(0xC000) -- settles wramDomain
    if wramDomain and addr >= 0xC000 and addr < 0xE000 then
        return memory.writebyte(addr - 0xC000, value, wramDomain)
    end
    return memory.writebyte(addr, value)
end

-- True while an overworld script runs: NPC dialogue, a cutscene, a phone
-- call. wScriptRunning alone misses the call. CheckTimeEvents far-calls
-- CheckPhoneCall, a far call hands back register c in a, c is 0 after
-- LoadCallerScript's copy, and PlayerEvents stores that 0 over the $FF
-- CallScript had just written (Crystal 25:6850). So the whole call runs
-- with wScriptRunning at 0. wScriptMode is set for every script, the call
-- included (EnableScriptMode), and back to 0 when it ends. Found
-- 2026-10-29: a call rang 26,850 offsets into a Shuckle search and stayed
-- on the main timeline unseen. Every probe after it had to click through
-- the whole call first (533 -> ~1,130 frames a probe, half the speed).
function M.script_busy(runningAddr, modeAddr)
    return (runningAddr ~= nil and wram(runningAddr) ~= 0) or (modeAddr ~= nil and wram(modeAddr) ~= 0)
end

function M.is_shiny(atkdef, spespc)
    if spespc ~= 0xAA then return false end
    for _, v in ipairs({0x2A, 0x3A, 0x6A, 0x7A, 0xAA, 0xBA, 0xEA, 0xFA}) do
        if atkdef == v then return true end
    end
    return false
end

-- A detect() for an encounter that ends with the Pokemon (or egg) joining
-- the party instead of a battle: the party count goes up, then the game
-- fills in the new slot - read once count, species and DVs hold still for
-- two frames in a row (read with wram() above). opts: party (count
-- address), before() (the count before receiving = the new slot's index),
-- exact (the count must be exactly before + 1 - the Odd Egg; its "count
-- 252" turned out to be bank 6, see wram()), realSpecies (also wait for a
-- species 1-251 - Game Corner's Pokedex fade), settle (frame cap, default
-- 30).
function M.gift_detector(opts)
    local function arrived(count, before)
        if opts.exact then return count == before + 1 end
        return count > before
    end
    return function()
        local before = opts.before()
        if not arrived(wram(opts.party), before) then return nil end
        local speciesAddr = opts.party + 1 + before
        local dvAddr = opts.party + 0x1D + before * 0x30
        local last, stable, waited = nil, 0, 0
        while stable < 2 and waited < (opts.settle or 30) do
            emu.frameadvance()
            waited = waited + 1
            local s = wram(speciesAddr)
            local now = string.format("%d/%d/%d/%d", wram(opts.party), s, wram(dvAddr), wram(dvAddr + 1))
            if now == last and (not opts.realSpecies or (s >= 1 and s <= 251)) then
                stable = stable + 1
            else
                last, stable = now, 0
            end
        end
        if not arrived(wram(opts.party), before) then return nil end
        return {species = wram(speciesAddr), atkdef = wram(dvAddr),
            spespc = wram(dvAddr + 1), item = 0, settle = waited}
    end
end

function M.new(opts)
    return setmetatable({opts = opts, active = false, probing = false, handedOver = false}, M)
end

function M:log(line) log(line) end

function M:name(species)
    if self.opts.name then return self.opts.name(species) end
    return PokemonNames[species] or ("#" .. tostring(species))
end

-- CSV rows are collected per step() and written in one go.
function M:flush_csv()
    if self.csv == nil or #self.csv == 0 then return end
    local f = io.open(CSV_PATH, "a")
    if f then
        f:write(table.concat(self.csv, "\n") .. "\n")
        f:close()
    end
    self.csv = {}
end

-- One row of frame_search_offsets.csv. key (atkdef * 256 + spespc) only for
-- a probe that rolled; sameAsPrev nil when there's no previous roll to
-- compare with.
function M:csv_row(startFrame, opening, action, key, sameAsPrev, distance, rollFrames)
    if self.offsets > CSV_OFFSETS then return end
    local function opt(v) return v == nil and "" or tostring(v) end
    local dvText = ",,,"
    if key then
        dvText = string.format("%d,%d,%d,%d", math.floor(key / 4096), math.floor(key / 256) % 16, math.floor(key / 16) % 16, key % 16)
    end
    self.csv[#self.csv + 1] = string.format("%d,%d,%s,%s,%s,%s,%s,%s,%s",
        self.offsets, startFrame, opt(opening.scriptAt), opt(opening.sameAt), action, dvText,
        sameAsPrev == nil and "" or (sameAsPrev and "y" or "n"), opt(distance), opt(rollFrames))
end

-- What fingerprint() reads: all of WRAM and HRAM (as this core names them)
-- plus the CPU registers - everything the game's own code can see. Without
-- both domains there's no state check (every offset probed fully).
function M:setup_fingerprint()
    self.domains = {}
    for _, name in ipairs({"WRAM", "HRAM"}) do
        local ok, size = pcall(memory.getmemorydomainsize, name)
        if ok and type(size) == "number" and size > 0 and pcall(memory.hash_region, 0, 1, name) then
            self.domains[#self.domains + 1] = {name = name, size = size}
        end
    end
    self.registerNames = {}
    local ok, regs = pcall(emu.getregisters)
    if ok and type(regs) == "table" then
        for name in pairs(regs) do self.registerNames[#self.registerNames + 1] = name end
        table.sort(self.registerNames)
    end
    self.canCompare = #self.domains == 2
end

function M:fingerprint()
    local parts = {}
    for _, d in ipairs(self.domains) do
        parts[#parts + 1] = memory.hash_region(0, d.size, d.name)
    end
    if #self.registerNames > 0 then
        local regs = emu.getregisters()
        for _, name in ipairs(self.registerNames) do parts[#parts + 1] = tostring(regs[name]) end
    end
    return table.concat(parts, "|")
end

-- Unthrottled and muted while probing; whatever was set before comes back.
function M:set_fast(on)
    if on then
        if self.restore == nil then
            local okU, unthrottled = pcall(function() return client.getconfig().Unthrottled end)
            local okS, sound = pcall(client.GetSoundOn)
            self.restore = {
                unthrottled = okU and unthrottled == true,
                sound = okS and type(sound) == "boolean" and sound or nil,
            }
        end
        pcall(emu.limitframerate, false)
        if self.restore.sound ~= nil then pcall(client.SetSoundOn, false) end
    elseif self.restore ~= nil then
        pcall(emu.limitframerate, not self.restore.unthrottled)
        if self.restore.sound ~= nil then pcall(client.SetSoundOn, self.restore.sound) end
        self.restore = nil
    end
end

-- Loading an in-memory state rewinds emu.framecount() too, so the frames
-- that undoes go into AutocrystalRewoundFrames - data/presence.lua adds
-- them back for Discord's fps (otherwise ~10 instead of the ~1,000 really
-- emulated).
function M:load_state(state)
    local before = emu.framecount()
    memorysavestate.loadcorestate(state)
    AutocrystalRewoundFrames = (AutocrystalRewoundFrames or 0) + math.max(0, before - emu.framecount())
end

-- Rolls are recorded without a disk write each (several a second); the
-- stats file is written once per batch instead.
function M:save_stats()
    if self.unsaved and self.unsaved > 0 then
        Stats.save()
        self.unsaved = 0
    end
end

-- The state right before the press that found a handed-over encounter -
-- see replay().
function M:drop_retry()
    if self.retry then
        memorysavestate.removestate(self.retry.state)
        self.retry = nil
    end
end

function M:begin()
    self:drop_retry()
    self.active = true
    self.handedOver = false
    self.unsaved = 0
    self.startTime = os.time()
    self.offsets, self.skipped = 0, 0
    self.probes, self.real, self.failed, self.odd = 0, 0, 0, 0
    self.failStreak = 0
    self.probeFrames = 0
    self.unique, self.lastSeen = 0, {}
    self.dist = {0, 0, 0, 0} -- repeats of an earlier DV pair, by how far back: 1 offset, 2-10, 11-1000, more
    self.species = nil
    self.prev = nil
    self.skipping = false
    self.flagged, self.checks, self.checksWrong = 0, 0, 0
    self.calib = {pairs = 0, repeats = 0, scriptSame = 0, scriptSameRepeats = 0, flagged = 0, flaggedWrong = 0}
    self.lastLogTime, self.lastLogOffsets, self.lastLogUnique = os.time(), 0, 0
    self.lastGuiTime = 0
    AutocrystalHuntedSpecies = nil
    self:setup_fingerprint()
    rotate_log_if_big()
    log(string.format("=== frame search started | %s | map %d:%d ===", self.opts.label,
        wram(require("data.gs_jp").map_group_addr()), wram(require("data.gs_jp").map_group_addr() + 1)))
    if not self.canCompare then
        log("can't fingerprint the game state on this core (no WRAM/HRAM domains) - every offset gets a full probe")
    end
    self.csv = {}
    if CSV_OFFSETS > 0 then
        self.csv = {
            "# frame search started " .. os.date("%Y-%m-%d %H:%M:%S"),
            "offset,frame,script_start,same_state_at,action,atk,def,spe,spc,same_as_prev,repeat_distance,roll_frames",
        }
    end
end

function M:report(force)
    local now = os.time()
    if not force and now - self.lastLogTime < LOG_SECONDS then return end
    local window = math.max(1, now - self.lastLogTime)
    local total = math.max(1, now - self.startTime)
    log(string.format(
        "%6ds | offsets %d (%.1f/s now, %.1f/s avg) | full probes %d, skipped %d | unique DV pairs %d (+%d, %.2f/s avg) | no roll %d | other species %d | %.0f frames/probe",
        now - self.startTime, self.offsets, (self.offsets - self.lastLogOffsets) / window,
        self.offsets / total, self.probes, self.skipped,
        self.unique, self.unique - self.lastLogUnique, self.unique / total,
        self.failed, self.odd, self.probeFrames / math.max(1, self.probes)))
    self.lastLogTime, self.lastLogOffsets, self.lastLogUnique = now, self.offsets, self.unique
end

-- Where the repeated DV pairs came from, and how the skipping is doing.
function M:summary()
    local d = self.dist
    log(string.format("repeats of a DV pair already seen, by how many offsets earlier: 1: %d | 2-10: %d | 11-1000: %d | more: %d",
        d[1], d[2], d[3], d[4]))
    if self.skipped > 0 or self.checks > 0 then
        log(string.format("skipping: %d offsets skipped, %d more probed fully as a check, %d of those checks wrong",
            self.skipped, self.checks, self.checksWrong))
    end
end

-- After the first CALIBRATE_OFFSETS offsets (all probed fully): did "same
-- state as the previous offset" always mean "same DVs"?
function M:finish_calibration()
    local c = self.calib
    log(string.format(
        "first %d offsets: %d of %d rolled exactly the previous offset's DVs | the press started the script on the same frame as the previous offset's %d times (%d of them repeats) | same game state as the previous offset within %d frames: %d times, %d of them with different DVs",
        CALIBRATE_OFFSETS, c.repeats, c.pairs, c.scriptSame, c.scriptSameRepeats,
        STATE_FRAMES, c.flagged, c.flaggedWrong))
    self:summary()
    if self.canCompare and c.flagged >= 20 and c.flaggedWrong == 0 then
        self.skipping = true
        log(string.format("-> from now on an offset in the same state as the previous one is skipped after %d frames (every %dth probed fully as a check)",
            STATE_FRAMES, CHECK_EVERY))
    else
        log("-> not skipping: the state check didn't reliably predict repeats here - every offset keeps getting a full probe")
    end
end

-- One probe from the current frame: the press pattern until detect() has
-- the roll. Returns it (nil if nothing rolled), plus what happened in the
-- opening frames: the state fingerprints by frame number (prints), the
-- probe frame the game state first matched prev's at the same frame number
-- (sameAt), and the frame the press started a script (scriptAt).
-- stopIfSame: on a match, end the probe after the opening frames instead
-- of waiting for the roll.
function M:probe(prev, stopIfSame)
    local o = self.opts
    if o.before_probe then o.before_probe() end
    self.probing = true
    local roll
    local frames = 0
    local opening = {prints = {}}
    local compare = prev ~= nil and self.canCompare
    while roll == nil and frames < ROLL_CAP do
        local beat = frames % MASH_EVERY
        if o.press == "walk" then
            joypad.set({Up = true})
        elseif (o.press == "hold" and beat < MASH_EVERY - 2) or (o.press == "tap" and beat < 2) then
            joypad.set({A = true})
        end
        emu.frameadvance()
        frames = frames + 1
        roll = o.detect()
        if roll then frames = frames + (roll.settle or 0) end
        if opening.scriptAt == nil and o.script_addr and wram(o.script_addr) ~= 0 then
            opening.scriptAt = frames
        end
        -- (Frames before STATE_FROM never get compared - not here, nor by
        -- the next offset, which starts a frame later.)
        if frames >= STATE_FROM and frames <= STATE_FRAMES and self.canCompare then
            local now = emu.framecount()
            local fp = self:fingerprint()
            opening.prints[now] = fp
            if compare and opening.sameAt == nil and prev.prints[now] == fp then
                opening.sameAt = frames
            end
            -- Fingerprints go on to the last opening frame even after a
            -- match: the next offset gets compared against all of them.
            if stopIfSame and opening.sameAt and frames == STATE_FRAMES then break end
        end
    end
    self.probing = false
    opening.frames = frames
    return roll, opening
end

local function same_roll(a, b)
    return a ~= nil and b ~= nil and a.species == b.species and a.atkdef == b.atkdef and a.spespc == b.spespc
end

local function dv_text(roll)
    return string.format("A:%d D:%d S:%d Sp:%d", math.floor(roll.atkdef / 16), roll.atkdef % 16,
        math.floor(roll.spespc / 16), roll.spespc % 16)
end

-- Hands an interesting probe to the module's own handling. probeState is
-- that probe's starting frame - kept for replay().
function M:hand_over(probeState, roll)
    -- The next probe position goes into the savestate slot first...
    self:load_state(probeState)
    emu.frameadvance()
    savestate.saveslot(self.opts.slot())
    -- ...then the same probe again (BizHawk is deterministic: same roll).
    self:load_state(probeState)
    local again = self:probe(nil, false)
    if not same_roll(again, roll) then
        log(string.format("WARNING: replaying the probe rolled %s instead of %s", again and dv_text(again) or "nothing", dv_text(roll)))
    end
    log(string.format("handed over: %s %s%s after %d frame offsets", self:name(roll.species), dv_text(roll),
        M.is_shiny(roll.atkdef, roll.spespc) and " SHINY" or "", self.offsets))
    self:report(true)
    self:summary()
    self:flush_csv()
    self:set_fast(false)
    self.handedOver = true
    self.retry = {state = probeState, roll = roll}
    if self.opts.on_hand_over then self.opts.on_hand_over(roll) end
end

-- Back to the frame the handed-over encounter appeared on, and the same
-- press again - the same encounter, BizHawk being deterministic. Returns
-- the roll if it matched, else nil plus whatever it did roll.
function M:replay()
    if not self.retry then return nil end
    self:load_state(self.retry.state)
    local roll = self:probe(nil, false)
    if same_roll(roll, self.retry.roll) then return roll end
    return nil, roll
end

-- Runs a batch of frame offsets per M.step() call. Returns true to stop the bot.
function M:step()
    local o = self.opts
    if not self.active then self:begin() end
    if self.handedOver then
        -- The module's handling reloaded the savestate slot - which holds
        -- the next probe position - so just carry on.
        self.handedOver = false
        self:drop_retry()
        log("resumed after hand-over")
    end
    self:set_fast(true)

    for i = 1, PROBES_PER_STEP do
        if AutocrystalGlobalStopRequested == true then
            self:report(true)
            self:summary()
            self:flush_csv()
            self:save_stats()
            self:set_fast(false)
            return true
        end
        -- A phone call can ring while the game sits idle. Left on the main
        -- timeline, every probe from then on has to click through the
        -- whole call before its own press does anything - clear it there
        -- first.
        if o.script_busy and o.clear_script and o.script_busy() then
            log(string.format("offset %d: a script is running on the main timeline (a phone call, most likely) - clearing it", self.offsets))
            if not o.clear_script() then
                self:flush_csv()
                self:save_stats()
                self:set_fast(false)
                return true
            end
        end

        local probeState = memorysavestate.savecorestate()
        local startFrame = emu.framecount()
        -- Only the offset one frame earlier counts as the previous one (not
        -- across a cleared phone call or a hand-over).
        local prev = self.prev
        if prev and prev.start ~= startFrame - 1 then prev = nil end
        self.offsets = self.offsets + 1
        local calibrating = self.offsets <= CALIBRATE_OFFSETS
        local canSkip = self.skipping and prev ~= nil and prev.key ~= nil
        local isCheck = canSkip and (self.flagged + 1) % CHECK_EVERY == 0
        local roll, opening = self:probe(prev, canSkip and not isCheck)
        local entry = {start = startFrame, prints = opening.prints,
            scriptAt = opening.scriptAt and startFrame + opening.scriptAt}
        local flagged = opening.sameAt ~= nil and prev ~= nil and prev.key ~= nil
        if flagged then self.flagged = self.flagged + 1 end
        local skippedIt = canSkip and not isCheck and flagged and roll == nil
        local realRoll

        if skippedIt then
            -- Same game state as the previous offset: same roll, already seen.
            entry.key = prev.key
            self.skipped = self.skipped + 1
            self:csv_row(startFrame, opening, "skip", nil, nil, nil, nil)
        else
            self.probes = self.probes + 1
            self.probeFrames = self.probeFrames + opening.frames
            local distance
            if roll then
                self.failStreak = 0
                if (self.species == nil or roll.species == self.species) and (o.is_real == nil or o.is_real(roll)) then
                    realRoll = roll
                    if self.species == nil then
                        self.species = roll.species
                        -- launcher.lua's Discord line names it for "Static (open world)".
                        if roll.species >= 1 and roll.species <= 251 then AutocrystalHuntedSpecies = self:name(roll.species) end
                        log(string.format("rolling %s (#%d) here", self:name(roll.species), roll.species))
                    end
                    self.real = self.real + 1
                    entry.key = roll.atkdef * 256 + roll.spespc
                    local last = self.lastSeen[entry.key]
                    if last == nil then
                        self.unique = self.unique + 1
                    else
                        distance = self.offsets - last
                        local d = self.dist
                        local bucket = distance == 1 and 1 or distance <= 10 and 2 or distance <= 1000 and 3 or 4
                        d[bucket] = d[bucket] + 1
                    end
                    self.lastSeen[entry.key] = self.offsets
                else
                    self.odd = self.odd + 1
                end
            else
                self.failed = self.failed + 1
                self.failStreak = self.failStreak + 1
                local maxFails = (self.real + self.odd > 0) and MAX_FAILS or FIRST_FAILS
                if self.failStreak >= maxFails then
                    self:load_state(probeState)
                    memorysavestate.removestate(probeState)
                    self:report(true)
                    self:flush_csv()
                    self:save_stats()
                    self:set_fast(false)
                    log(string.format("nothing rolled %d times in a row - stopped", maxFails))
                    print(string.format("Frame search: no %s encounter started %d times in a row - stand where it starts (facing it, no text box open) and click Start again.",
                        o.label, maxFails))
                    o.status("Frame search: no encounter starts here - stand at it, then Start.")
                    return true
                end
            end

            local sameAsPrev
            if prev and prev.key then sameAsPrev = entry.key == prev.key end
            if calibrating and sameAsPrev ~= nil then
                local c = self.calib
                c.pairs = c.pairs + 1
                if sameAsPrev then c.repeats = c.repeats + 1 end
                if entry.scriptAt and entry.scriptAt == prev.scriptAt then
                    c.scriptSame = c.scriptSame + 1
                    if sameAsPrev then c.scriptSameRepeats = c.scriptSameRepeats + 1 end
                end
                if flagged then
                    c.flagged = c.flagged + 1
                    if not sameAsPrev then c.flaggedWrong = c.flaggedWrong + 1 end
                end
            end
            if flagged and self.skipping then
                self.checks = self.checks + 1
                if not sameAsPrev then
                    self.checksWrong = self.checksWrong + 1
                    self.skipping = false
                    log(string.format("WARNING: offset %d was in the same state as the previous one but rolled different DVs - no more skipping in this search",
                        self.offsets))
                end
            end
            self:csv_row(startFrame, opening, (isCheck and flagged) and "check" or "full",
                entry.key, sameAsPrev, distance, roll and opening.frames or nil)
            -- A new encounter - unless it's the previous offset's again, or
            -- one handed over below (the module's handling records that).
            if realRoll and not (flagged and sameAsPrev) and not o.special(realRoll) then
                o.record(realRoll)
                self.unsaved = self.unsaved + 1
            end
        end
        self.prev = entry
        if self.offsets == CALIBRATE_OFFSETS then self:finish_calibration() end

        if realRoll and o.special(realRoll) then
            self:save_stats()
            self:hand_over(probeState, realRoll)
            return false
        end
        self:load_state(probeState)
        memorysavestate.removestate(probeState)
        -- The idle frame before the next probe - except after the last one
        -- here: launcher.lua's main loop advances one frame before calling
        -- M.step() again, so that one IS the idle frame (otherwise one
        -- offset per batch would be skipped).
        if i < PROBES_PER_STEP then emu.frameadvance() end
    end

    self:report(false)
    self:flush_csv()
    self:save_stats()
    if os.time() ~= self.lastGuiTime then
        self.lastGuiTime = os.time()
        o.status(string.format("Frame search: %d offsets (%d skipped), %d different DVs", self.offsets, self.skipped, self.unique))
    end
    return false
end

return M

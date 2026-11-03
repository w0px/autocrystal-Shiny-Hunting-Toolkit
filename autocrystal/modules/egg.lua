-- egg.lua
-- Talk to the NPC that gives an egg (Day Care man for a normal egg, or
-- the special delivery NPC for a Togepi-style mystery egg - mechanically
-- identical from this script's perspective), receive it, and this module
-- immediately checks its DVs/shininess without walking anywhere first.
--
-- WHY THIS IS SAFE TO DO: an egg's species and DVs are fully fixed the
-- instant you receive it (confirmed via the same TASVideos RNG doc used
-- for Starters) - hatching just reveals what's already there. Walking a
-- full hatch (which can take thousands of steps depending on species)
-- only matters for actually PLAYING with the Pokemon, not for knowing
-- if it's shiny. So: fast reset-and-check loop for the common (non-shiny)
-- case, and only once we've found a shiny do we actually walk it out to
-- watch it hatch for real.
--
-- CONFIRMED mechanic: the "display species" byte for a party slot reads
-- 0xFD (253) while it's an unhatched egg, updating to the real species
-- the instant it hatches (pokecrystal disassembly + Bulbapedia's Glitch
-- Egg article, cross-checked).
--
-- Includes the same anti-determinism fix discovered for Starters: soft-
-- resetting with perfectly identical input timing produces IDENTICAL
-- "random" results every attempt (a well-known Gen 1/2 RNG quirk) unless
-- you deliberately introduce timing variance after each reload - since
-- replaced by frame search (data/frame_search.lua): every frame the talk
-- could start on, tried once each, in order.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
Stats = require("data.stats")
SavestateBackup = require("data.savestate_backup")
ConsoleLog = require("data.console_log")
local FrameSearch = require("data.frame_search")
local ShinySavestate = require("data.shiny_savestate")
-- Party, map and wScriptRunning reads go through this - WRAM bank 1 no
-- matter which bank the game has switched in (see FrameSearch.wram).
local wram = FrameSearch.wram
local GsJp = require("data.gs_jp")

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua/friendship.lua/static.lua/
-- starters.lua - see data/location_names.lua for where this comes from
-- (the actual pret/pokecrystal disassembly, not a guess). Egg-hatching
-- involves walking, so location can genuinely vary here too.
local LocationNames = require("data.gs_jp").location_names -- Crystal's or Gold/Silver's, by the loaded game

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local hud

local function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

local DISCORD_RELAY_URL = "http://127.0.0.1:5000/"

-- Escapes a value for safe inclusion inside a JSON string. Backslashes
-- MUST be escaped first, before quotes - see wild.lua for the original
-- confirmation of this ordering requirement.
local function json_escape(value)
    local str = tostring(value)
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    str = str:gsub('\n', '\\n')
    str = str:gsub('\r', '\\r')
    str = str:gsub('\t', '\\t')
    return str
end

-- Sends a rich Discord embed - same shape/behavior as wild.lua's
-- send_discord_embed, including threading a ping mention into the
-- top-level "content" field (Discord never triggers an actual
-- ping/notification from text inside an embed itself).
local function send_discord_embed(title, description, fields, color, spriteUrl)
    if not Gui.discord_enabled(hud) then return end

    local parts = {}
    table.insert(parts, string.format('"title": "%s"', json_escape(title)))
    if description then
        table.insert(parts, string.format('"description": "%s"', json_escape(description)))
    end
    if color then
        table.insert(parts, string.format('"color": %d', color))
    end
    if fields and #fields > 0 then
        local fieldsJson = {}
        for _, field in ipairs(fields) do
            table.insert(fieldsJson, string.format(
                '{"name": "%s", "value": "%s", "inline": %s}',
                json_escape(field.name), json_escape(field.value), tostring(field.inline or false)))
        end
        table.insert(parts, string.format('"fields": [%s]', table.concat(fieldsJson, ",")))
    end
    if spriteUrl then
        table.insert(parts, string.format('"thumbnail": {"url": "%s"}', json_escape(spriteUrl)))
    end
    table.insert(parts, '"footer": {"text": "autocrystal"}')
    table.insert(parts, string.format('"timestamp": "%s"', os.date("!%Y-%m-%dT%H:%M:%SZ")))

    local embedJson = "{" .. table.concat(parts, ",") .. "}"

    local mention = Gui.ping_mention(hud)
    local payload
    if mention then
        payload = string.format('{"content": "%s", "embeds": [%s]}', json_escape(mention), embedJson)
    else
        payload = string.format('{"embeds": [%s]}', embedJson)
    end

    local ok, response = pcall(comm.httpPost, DISCORD_RELAY_URL, payload)
    if ok then
        print("Discord embed sent, response: " .. tostring(response))
    else
        print("Discord embed failed: " .. tostring(response))
    end
end

-- Generation II's Hidden Power type/power formula - see wild.lua for the
-- full derivation notes (Bulbapedia's Hidden Power calculation page).
local HIDDEN_POWER_TYPES = {
    "Fighting", "Flying", "Poison", "Ground", "Rock", "Bug", "Ghost", "Steel",
    "Fire", "Water", "Grass", "Electric", "Psychic", "Ice", "Dragon", "Dark",
}

local function hidden_power(atkDV, defDV, speDV, spcDV)
    local typeIndex = 4 * (atkDV % 4) + (defDV % 4)
    local hpType = HIDDEN_POWER_TYPES[typeIndex + 1]

    local v = (spcDV >= 8) and 1 or 0
    local w = (speDV >= 8) and 1 or 0
    local x = (defDV >= 8) and 1 or 0
    local y = (atkDV >= 8) and 1 or 0
    local z = spcDV % 4
    local hpPower = math.floor((5 * (v + 2 * w + 4 * x + 8 * y) + z) / 2) + 31

    return hpType, hpPower
end

-- A visible horizontal-rule divider between field groups - see wild.lua.
local function divider_field()
    return {name = "\xE2\x80\x8B", value = string.rep("\xE2\x96\xAC", 28), inline = false}
end

local COLOR_GOLD = 16766720

local EGG_PLACEHOLDER = 0xFD
-- Value fixed once per run inside M.init() below, via the launcher's
-- Savestate slot dropdown (falls back to 4, this module's historical
-- default, separate from Starters' slot 3, if the dropdown can't be
-- read) - no longer a hardcoded constant, see launcher.lua's
-- AutocrystalGetSavestateSlot().
local SAVESTATE_SLOT

local party_base_addr
local wScriptRunningAddr -- non-zero while NPC dialogue or a cutscene runs - but not a phone call (see FrameSearch.script_busy)
local wScriptModeAddr -- set during a phone call too; frame search clears any script before a probe
local eggSlotIndex -- fixed once determined: the same slot every reset, since party size before receiving never changes
local eggDvAddr
local eggSpeciesListAddr
local partysizeBeforeReceiving

local enemy_species_addr -- generic wild-battle address, safety net during the walk-to-hatch phase only

local resetCount = 0
local stepsTaken = 0
local sessionEncounterCount = 0
local confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv

-- This Start's FrameSearch (data/frame_search.lua) - made by M.on_resume()
-- with new_frame_search() (defined further down).
local search, new_frame_search
-- A mystery-egg delivery (e.g. Togepi) has its own confirmation dialogue
-- that the standard day-care egg flow doesn't - walking logic assumes
-- the character is immediately free to move, so this needs clearing
-- once before the first walk attempt after a shiny is confirmed.
local hatchDialogueCleared = true

-- State machine: "waiting_for_egg" -> "walking_to_hatch" (only reached
-- after confirming a shiny) -> done
local state = "waiting_for_egg"

local function shiny(atkdef, spespc)
    if spespc == 0xAA then
        if atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA then
            return true
        end
    end
    return false
end

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance()
end

-- ===== Movement (verbatim from wild.lua's proven drift-proof system) -
-- only used during the walking_to_hatch phase, after a shiny is found =====
local MOVEMENT_FLAG_ADDR = 0xD4DD
local PLAYER_X_ADDR, PLAYER_Y_ADDR = 0xDCB8, 0xDCB7 -- M.init() moves all three for Japanese Crystal
local MOVEMENT_IDLE_VALUE = 0xFF

local function attempt_step(direction)
    local startX, startY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)

    -- A is held throughout the entire movement attempt, not just pressed
    -- once beforehand - this clears any leftover post-shiny dialogue as
    -- a side effect of walking, rather than needing to guess exactly how
    -- many presses are needed to clear it before movement starts.
    for i = 1, 4 do
        joypad.set({[direction] = true, A = true})
        emu.frameadvance()
    end
    joypad.set({[direction] = false, A = true})

    local n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) == MOVEMENT_IDLE_VALUE and n < 20 do
        joypad.set({A = true})
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) ~= MOVEMENT_IDLE_VALUE and n < 90 do
        joypad.set({A = true})
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    return (endX ~= startX or endY ~= startY)
end

local safe_pair = nil
local homeX, homeY = nil, nil

local function walk_toward_home()
    local curX, curY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    if curX == homeX and curY == homeY then return true end

    if curX < homeX then
        attempt_step("Right")
    elseif curX > homeX then
        attempt_step("Left")
    elseif curY < homeY then
        attempt_step("Down")
    elseif curY > homeY then
        attempt_step("Up")
    end

    if memory.readbyte(enemy_species_addr) ~= 0 then return false end
    curX, curY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    return (curX == homeX and curY == homeY)
end

local function find_safe_pair(verbose)
    local anchorX, anchorY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    local candidates = {
        {out = "Right", back = "Left"},
        {out = "Left",  back = "Right"},
        {out = "Down",  back = "Up"},
        {out = "Up",    back = "Down"},
    }

    for _, pair in ipairs(candidates) do
        local movedOut = attempt_step(pair.out)
        if memory.readbyte(enemy_species_addr) ~= 0 then return nil end

        if movedOut then
            local movedBack = attempt_step(pair.back)
            if memory.readbyte(enemy_species_addr) ~= 0 then return nil end

            local nowX, nowY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
            if movedBack and nowX == anchorX and nowY == anchorY then
                vprint(string.format("Found safe zero-drift pair: %s / %s", pair.out, pair.back))
                return pair
            else
                anchorX, anchorY = nowX, nowY
            end
        end
    end

    return nil
end

local failed_pair_attempts = 0

local function do_nudge_cycle()
    local madeRealProgress = false

    if homeX == nil then
        homeX, homeY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        vprint(string.format("Anchoring home tile at X=%d Y=%d", homeX, homeY))
    end

    if safe_pair == nil then
        local curX, curY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        if curX ~= homeX or curY ~= homeY then
            local reachedHome = walk_toward_home()
            if memory.readbyte(enemy_species_addr) ~= 0 then return false end
            if not reachedHome then return true end
        end

        local verbose = Gui.verbose_logging(hud) and (failed_pair_attempts % 20 == 0)
        safe_pair = find_safe_pair(verbose)
        if safe_pair == nil and memory.readbyte(enemy_species_addr) == 0 then
            failed_pair_attempts = failed_pair_attempts + 1
        else
            madeRealProgress = (safe_pair ~= nil)
        end
    else
        local startX, startY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end

        local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        local trulyReturned = (endX == startX and endY == startY)
        madeRealProgress = movedOut and movedBack and trulyReturned

        if movedOut and movedBack and not trulyReturned then
            safe_pair = nil
        end
    end

    return madeRealProgress
end

-- ===== M.init =====
-- Stop-on-shiny, every Auto-Catch field, and crit-safety override are
-- also greyed out - egg.lua never reads any of those Gui getters (no
-- wild-battle capture flow here). True Randomness IS in this list now -
-- egg.lua no longer calls Gui.true_randomness_enabled() at all, since
-- frame search (trying every frame) supersedes it. Greyed out
-- here so it's visually obvious it has no effect while Egg is the active
-- module. Verbose Logging stays checkable.
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkThiefMode", "txtThiefFilter",
    "chkStopOnShiny",
    "chkAutoCatch", "txtCatchFilter",
    "chkSkipAlreadyCaught",
    "chkStopAutoCatchException", "txtStopAutoCatchException",
    "chkOverrideCritSafety", "txtCustomHpTarget",
    "chkCatchOnItem", "txtCatchItemFilter",
    "chkTrueRandomness",
    "chkCatchRetry", "txtCatchRetryCount", "chkCatchRetryAlways", "chkCatchSendNext",
}
function M.init(sharedForm, yOffset, existingHud)
    -- comm.httpPost has no default timeout, meaning if the Discord
    -- relay isn't actually listening, the call can hang indefinitely
    -- with no error - freezing the whole bot silently. 3 seconds is
    -- generous for a localhost request but bounds the wait.
    -- Wrapped in pcall: BizHawk keeps one persistent HttpClient for
    -- its whole process lifetime, and .NET only allows setting Timeout
    -- BEFORE the first request is ever sent on that client. Once any
    -- Discord notification has been sent, later script restarts (same
    -- BizHawk session) would hard-crash here without this pcall, since
    -- a request has already started. Safe to ignore failure - the
    -- timeout is already set from whenever it first succeeded.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    -- SAVESTATE_SLOT is deliberately NOT set here anymore - see
    -- M.on_switch_to() below for why (M.init() only runs once per
    -- BizHawk session, which silently ignored later dropdown changes).

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    -- The Japanese versions (data/gs_jp.lua): revisions that haven't been
    -- checked stop here and say why.
    if GsJp.japanese(version, region) and not GsJp.supported(version, region) then
        print(GsJp.unsupported_reason(version))
        return false
    end

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        elseif region == 0x45 then party_base_addr = 0xDCD7
        else party_base_addr = 0xDCD7 end
        -- Verified against pokecrystal.sym: wScriptRunning ($D438). Same
        -- address static.lua already relies on for this same purpose.
        wScriptRunningAddr = 0xD438
        wScriptModeAddr = 0xD437 -- pokecrystal11.sym
        if GsJp.japanese(version, region) then
            wScriptRunningAddr, wScriptModeAddr = GsJp.w(0xD438), GsJp.w(0xD437)
            MOVEMENT_FLAG_ADDR, PLAYER_X_ADDR, PLAYER_Y_ADDR = GsJp.w(0xD4DD), GsJp.w(0xDCB8), GsJp.w(0xDCB7)
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x45 then party_base_addr = 0xDA22
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
        -- Verified against pokegold1.sym: wScriptRunning ($D15F, plain
        -- SVBK-switched WRAM view). Same address static.lua uses.
        wScriptRunningAddr = 0xD15F
        wScriptModeAddr = 0xD15E -- pokegold1.sym/pokesilver.sym
        if GsJp.japanese(version, region) then
            wScriptRunningAddr, wScriptModeAddr = GsJp.w(0xD15F), GsJp.w(0xD15E)
        end
    else
        print("No valid ROM detected")
        return false
    end

    if version == 0x54 then
        if region == 0x4A then enemy_species_addr = GsJp.w(0xD20C) + 0x22
        else enemy_species_addr = 0xd20c + 0x22 end
    else
        -- Verified against pokegold.sym for EU/US: enemy_species_addr
        -- should be based on wEnemyMonDVs ($D0F5), NOT $DA22 (which is
        -- actually wPartyCount) - same bug already found and fixed
        -- elsewhere. JP/KR still unverified, no symbol data available.
        if region == 0x4A then enemy_species_addr = GsJp.w(0xD0F5) + 0x22
        elseif region == 0x4B then enemy_species_addr = 0xdb1f + 0x22
        else enemy_species_addr = 0xd0f5 + 0x22 end
    end

    math.randomseed(os.time())

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand facing the NPC that gives the egg...")
    return true
end

function M.on_switch_to()
    -- Re-read the launcher's Savestate slot dropdown every time this
    -- module becomes active, NOT just here-and-in-M.init() - M.init()
    -- only ever runs ONCE per BizHawk session (launcher.lua's
    -- initializedModules[] cache skips it on every later Start click for
    -- the same module), so a value captured only there would silently
    -- ignore any dropdown change made after the very first run. This
    -- function, unlike M.init(), genuinely runs every single time Start
    -- is clicked - confirmed via a real user report on static.lua (see
    -- that module's identical comment) that switching the dropdown to a
    -- different slot and clicking Start again kept acting on the OLD
    -- slot from the module's first run this session.
    SAVESTATE_SLOT = AutocrystalGetSavestateSlot(4)

    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position (facing
-- the NPC) as the reset target, and records the party size right now -
-- since resets always return to this exact point, the new egg will
-- always land in the same slot (the next open one) every single attempt.
function M.on_resume()
    -- A few real frames of buffer BEFORE capturing anything - preventive
    -- fix mirroring a confirmed bug in static.lua's on_resume(): clicking
    -- Start right on the heels of a UI interaction (e.g. just changing a
    -- dropdown) could occasionally capture the savestate mid-transient,
    -- and since every later reload just replays whatever got frozen here,
    -- a bad capture means every cycle after it inherits the same bad
    -- state forever (spam-reloads immediately, only clearing on a fresh
    -- Start). This buffer gives that transition time to settle first.
    for i = 1, 10 do emu.frameadvance() end

    SavestateBackup.backup_slot_before_write(SAVESTATE_SLOT,
        SavestateBackup.label("Egg", EggTargetDropdown and forms.gettext(EggTargetDropdown)))
    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = wram(party_base_addr)
    eggSlotIndex = partysizeBeforeReceiving
    eggDvAddr = party_base_addr + 0x1D + eggSlotIndex * 0x30
    eggSpeciesListAddr = party_base_addr + 1 + eggSlotIndex
    state = "waiting_for_egg"
    safe_pair = nil
    homeX, homeY = nil, nil
    if search then search:drop_retry() end
    search = new_frame_search()
end

local SCRIPT_CLEAR_TIMEOUT = 180 -- B presses to wait for script_busy() to clear

local function script_busy()
    return FrameSearch.script_busy(wScriptRunningAddr, wScriptModeAddr)
end

-- Presses B until script_busy() is false (or the bounded timeout is
-- hit) - a real confirmation that no dialogue/call/cutscene is mid-flight,
-- not a guess. No-op (returns immediately) if nothing is open, which is
-- the common case on every call. Ported from static.lua's identical
-- helper - frame search uses it to clear a phone call before a probe.
-- Only B, never A: at the NPC's YES/NO an A would take the egg (Start
-- pressed mid-conversation) - B answers NO. See static.lua's copy.
local function wait_for_no_active_script(label)
    if not wScriptRunningAddr then return true end
    local waited = 0
    while script_busy() and waited < SCRIPT_CLEAR_TIMEOUT do
        press_button("B")
        waited = waited + 1
    end
    if waited > 0 then
        print(string.format(
            "Egg: a script/phone call was running (%s) - %s after %d B press(es).",
            label or "script/dialogue/call in progress",
            script_busy() and "gave up waiting for it to clear" or "cleared it",
            waited))
    end
    return true
end

-- This Start's search: from the NPC, hold A through the dialogue until the
-- egg joins the party. The Odd Egg's transfer writes a placeholder party
-- count first (see M.step()), so for it the count has to be exactly one
-- more.
function new_frame_search()
    local source = EggTargetDropdown and forms.gettext(EggTargetDropdown) or "Togepi"
    return FrameSearch.new({
        label = "Egg - " .. source,
        press = "hold",
        detect = FrameSearch.gift_detector({party = party_base_addr, before = function() return partysizeBeforeReceiving end,
            exact = source == "Odd Egg"}),
        -- The party's species list shows EGG_PLACEHOLDER until it hatches.
        is_real = function(roll) return roll.species == EGG_PLACEHOLDER end,
        name = function() return "Egg" end,
        record = function(roll)
            resetCount = resetCount + 1
            Stats.record_encounter(nil, nil, nil, true)
            Gui.update_last_encounter(hud, resetCount, roll.species, "Egg",
                math.floor(roll.atkdef / 16), roll.atkdef % 16, math.floor(roll.spespc / 16), roll.spespc % 16, false, nil)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount)
        end,
        special = function(roll) return shiny(roll.atkdef, roll.spespc) end,
        slot = function() return SAVESTATE_SLOT end,
        status = function(text)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount, text)
        end,
        script_addr = wScriptRunningAddr,
        script_busy = script_busy,
        clear_script = function() return wait_for_no_active_script("frame search") end,
    })
end

-- ===== M.step =====
function M.step()
    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick. Only
    -- updates when the (group, number) pair is a RECOGNIZED location -
    -- an unrecognized pair almost always means these two WRAM bytes got
    -- transiently repurposed for something else, not an actual new
    -- location. See wild.lua's M.step() for the original fix this
    -- mirrors.
    do
        local mapKey = string.format("%d:%d", wram(GsJp.map_group_addr()), wram(GsJp.map_group_addr() + 1))
        if LocationNames[mapKey] then
            AutocrystalCurrentLocation = LocationNames[mapKey]
        end
    end

    if state == "waiting_for_egg" then
        local currentPartySize = wram(party_base_addr)

        -- Read this early too - the "still waiting" gate below needs to
        -- branch per-source, same reasoning as the branch further down.
        -- Togepi's condition is untouched; only Odd Egg's is changed.
        local waitingEggSource = EggTargetDropdown and forms.gettext(EggTargetDropdown) or "Togepi"

        local stillWaitingForEgg
        if waitingEggSource == "Odd Egg" then
            -- Real diagnostic data (attempts #17-#22) showed party_base_addr
            -- reading a constant 252 (0xFC) on EVERY single attempt, never
            -- once close to a real party size (partysizeBeforeReceiving+1).
            -- Odd Egg is handed out via AddMobileMonToParty (confirmed via
            -- odd_egg.asm/mobile_46.asm - shared with the Mobile GB Adapter
            -- "receive mon" code, not the normal party-add routine every
            -- other gift path uses), which most likely writes an
            -- in-progress sentinel to this same byte before committing the
            -- real count at the very end. The old "grew at all" check
            -- (currentPartySize <= partysizeBeforeReceiving) treats that
            -- sentinel as "egg received" instantly, long before the actual
            -- transfer finishes - which is exactly what let stale/garbage
            -- species+DV reads through downstream. Odd Egg only ever adds
            -- exactly one mon, so demand the exact expected value instead
            -- of merely "greater than before".
            stillWaitingForEgg = currentPartySize ~= (partysizeBeforeReceiving + 1)
        else
            -- Togepi - deliberately untouched, original condition.
            stillWaitingForEgg = currentPartySize <= partysizeBeforeReceiving
        end

        -- Frame search does the searching; only an egg it handed over - in
        -- the party now, on the real timeline - is read and handled below.
        if stillWaitingForEgg or not search.handedOver then
            return search:step()
        end

        -- Short wait only - not mashing through extended dialogue.
        for i = 1, 10 do emu.frameadvance() end

        -- Split into two genuinely separate code paths, not just a label -
        -- explicitly requested after Odd Egg debugging (settle-frame check
        -- below) accidentally also touched the Togepi path, which was
        -- confirmed working correctly and must be left completely alone.
        -- Defaults to Togepi (the original, untouched behavior) if the
        -- dropdown isn't available for any reason, same defensive pattern
        -- static.lua uses for StaticTargetDropdown.
        local eggSource = EggTargetDropdown and forms.gettext(EggTargetDropdown) or "Togepi"

        local atkdef, spespc, species, isShiny

        if eggSource == "Odd Egg" then
            -- Same settle-frame race already found and fixed for every
            -- other gift-receive path (see rng_mechanics.md's "Reload-spam
            -- bug, actual root cause found" - Static/Starters/Game
            -- Corner): the game writes a template/placeholder value to
            -- the new slot first, before a later step overwrites it with
            -- the real DVs - reading immediately after a fixed wait can
            -- catch that placeholder instead of the final value. That fix
            -- (wait for the DV bytes to read identically on two
            -- consecutive frames before trusting them) was never ported
            -- to egg.lua until now - a user report showed an egg flagged
            -- shiny the instant it was received that hatched non-shiny,
            -- exactly this signature. species isn't useful as part of the
            -- stability check here - it's expected to stay at
            -- EGG_PLACEHOLDER (0xFD) the whole time pre-hatch - so this
            -- only waits on the DV bytes themselves settling.
            --
            -- STILL UNDER ACTIVE INVESTIGATION: a repro showed a $AA/$AA
            -- read that "settled" for 2 frames but doesn't match either
            -- real Odd Egg table row (0/0/0/0 or 2/10/10/10 - see
            -- odd_eggs.asm), meaning the settle check alone isn't the
            -- full fix - stably wrong data can pass a same-value-twice
            -- check just as easily as real data. Diagnostic fields added
            -- below (species/partySize/slot/addr) to pin down whether
            -- this is even reading the right memory at all.
            atkdef = wram(eggDvAddr)
            spespc = wram(eggDvAddr + 1)
            do
                local stableFrames = 0
                local waited = 0
                while stableFrames < 2 and waited < 30 do
                    emu.frameadvance()
                    waited = waited + 1
                    local curAtkdef = wram(eggDvAddr)
                    local curSpespc = wram(eggDvAddr + 1)
                    if curAtkdef == atkdef and curSpespc == spespc then
                        stableFrames = stableFrames + 1
                    else
                        atkdef = curAtkdef
                        spespc = curSpespc
                        stableFrames = 0
                    end
                end
                if waited > 2 then
                    print(string.format("Egg DV bytes weren't immediately stable, waited %d frames before trusting them (settled on atkdef=$%02X spespc=$%02X) - if a bogus instant-shiny recurs, this was it.", waited, atkdef, spespc))
                end
            end
            species = wram(eggSpeciesListAddr) -- still 0xFD at this point, expected
            isShiny = shiny(atkdef, spespc)
        else
            -- Togepi path - deliberately UNTOUCHED, byte-for-byte the
            -- original code from before any Odd Egg debugging began. Do
            -- not "improve" this without a specific, confirmed Togepi bug
            -- report - it's already confirmed working.
            atkdef = wram(eggDvAddr)
            spespc = wram(eggDvAddr + 1)
            species = wram(eggSpeciesListAddr) -- still 0xFD at this point, expected
            isShiny = shiny(atkdef, spespc)
        end

        local atkv = math.floor(atkdef / 16)
        local defv = atkdef % 16
        local spdv = math.floor(spespc / 16)
        local spcv = spespc % 16

        resetCount = resetCount + 1

        local encounterLine
        if eggSource == "Odd Egg" then
            -- Diagnostic fields on top of the normal line while chasing a
            -- confirmed bogus-shiny report - species is supposed to be a
            -- rock-solid EGG_PLACEHOLDER ($FD) at this point every single
            -- time; if it ever reads anything else, we're not looking at
            -- a real, freshly-written party slot at all, which would
            -- point at a wrong address/timing bug well upstream of the
            -- settle-frame check above rather than a race within it.
            encounterLine = string.format("#%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s | species=$%02X(expect $FD) partySize=%d(was %d) slot=%d dvAddr=$%04X",
                resetCount, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or "",
                species, currentPartySize, partysizeBeforeReceiving, eggSlotIndex, eggDvAddr)
        else
            -- Original Togepi print line, unchanged.
            encounterLine = string.format("#%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s",
                resetCount, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or "")
        end
        print(encounterLine)

        -- See data/console_log.lua for the full rationale: BizHawk's own
        -- Lua console has no cap on accumulated output and gets slower
        -- to append to as its backlog grows, so we clear it ourselves
        -- periodically instead of making users do it manually. The same
        -- line is also written to a rotating on-disk log so clearing the
        -- console never actually loses anything.
        ConsoleLog.maybe_clear_console(resetCount)
        ConsoleLog.log_encounter("egg", encounterLine)

        Stats.record_encounter()
        Gui.update_last_encounter(hud, resetCount, species, "Egg", atkv, defv, spdv, spcv, isShiny, nil)

        if isShiny then
            print(string.format("SHINY egg found! Atk:%d Def:%d Spe:%d Spc:%d - stopping here, walk it out to hatch yourself", atkv, defv, spdv, spcv))
            ShinySavestate.save_if_enabled(Gui, hud, "Egg")
            confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv = atkv, defv, spdv, spcv
            local encountersBeforeThisShiny = Stats.encountersSinceShiny
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "SHINY egg found! Stopped - walk it out to hatch yourself.")
            local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)
            send_discord_embed(
                "\xE2\x9C\xA8 Shiny Egg Found!",
                "Species is unknown until it hatches - walk it out to hatch yourself.",
                {
                    {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                    {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                    divider_field(),
                    {name = "Resets For This Shiny", value = tostring(encountersBeforeThisShiny), inline = true},
                    divider_field(),
                    {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                    {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
                },
                COLOR_GOLD,
                -- The egg picture (animated) - there's no public URL for
                -- it, so discord_relay.ps1 uploads data/sprites/
                -- egg_discord.gif along with the message (Discord's
                -- "attachment://" image).
                "attachment://egg_discord.gif"
            )
            return true
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            -- Read differently on the real timeline than in the search -
            -- back to the next frame to try, and carry on.
            savestate.loadslot(SAVESTATE_SLOT)
            return false
        end

    elseif state == "walking_to_hatch" then
        if not hatchDialogueCleared then
            hatchDialogueCleared = true
            for i = 1, 30 do
                press_button("A")
            end
        end

        if memory.readbyte(enemy_species_addr) ~= 0 then
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                string.format("Wild encounter interrupted - fleeing (steps so far: %d)...", stepsTaken))
            while memory.readbyte(enemy_species_addr) ~= 0 do
                emu.frameadvance()
                press_button("B")
            end
            safe_pair = nil
            return false
        end

        local madeProgress = do_nudge_cycle()
        if madeProgress then
            stepsTaken = stepsTaken + 1
        end

        local currentSpeciesListValue = wram(eggSpeciesListAddr)
        if currentSpeciesListValue ~= EGG_PLACEHOLDER then
            local speciesName = get_pokemon_name(currentSpeciesListValue)
            print(string.format("Hatched! %s - confirmed shiny, all done.", speciesName))
            Gui.update_last_encounter(hud, resetCount, currentSpeciesListValue, speciesName,
                confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv, true, nil)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Hatched: " .. speciesName .. " (SHINY)!")
            return true
        end

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            string.format("Walking to hatch the shiny... (steps so far: %d)", stepsTaken))
        return false
    end

    return false
end

return M

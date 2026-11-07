-- starters.lua
-- Shiny starter soft-resetting. Ported from an earlier standalone script
-- into the init()/step() module pattern used by the launcher.
--
-- Fixed bugs from the original version:
--   - vba.pause() was a VisualBoyAdvance function, not BizHawk - would
--     have thrown an error the moment a shiny was actually found. Now
--     just returns true (the standard "I'm done" signal the launcher
--     expects), same as every other mode.
--   - Now uses the shared GUI (same window as other modes) and the
--     shared lifetime Stats module (so TOTAL ENCOUNTERS is a true total
--     across every mode, not reset per-module).
--   - CRITICAL FIX: soft-resetting with perfectly identical input timing
--     every single attempt produces IDENTICAL "random" DVs every time -
--     a well-known Gen 1/2 RNG quirk (the roll is driven by elapsed
--     frames since a fixed point). A randomized delay after each reload
--     broke this determinism so DVs actually varied between attempts -
--     since replaced by frame search (data/frame_search.lua): every frame
--     the choice could be made on, tried once each, in order.
--
-- NOTE: the species name lookup below uses the standard Gen 1/2 party
-- structure convention (species ID list starts right after the party
-- count byte) - this has NOT been independently RAM-verified this
-- session the way other addresses were. Please sanity-check it against
-- the actual Pokemon shown on screen the first time you run this.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Gui = require("gui_module")
Stats = require("data.stats")
PokemonNames = require("data.pokemon_names")
SavestateBackup = require("data.savestate_backup")
local ShinySavestate = require("data.shiny_savestate")
ConsoleLog = require("data.console_log")
local FrameSearch = require("data.frame_search")
-- Party, map and wScriptRunning reads go through this - WRAM bank 1 no
-- matter which bank the game has switched in (see FrameSearch.wram).
local wram = FrameSearch.wram
local GsJp = require("data.gs_jp")

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua/friendship.lua/static.lua - see
-- data/location_names.lua for where this comes from (the actual
-- pret/pokecrystal disassembly, not a guess). Feeds the Rich Presence
-- location the same as those modules (always the starter-choice room,
-- but shown for consistency across every module).
local LocationNames = require("data.gs_jp").location_names -- Crystal's or Gold/Silver's, by the loaded game

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local hud
local base_address, versionStr, partysize, dv_addr, species_list_addr
local wScriptRunningAddr -- non-zero while NPC dialogue or a cutscene runs - but not a phone call (see FrameSearch.script_busy)
local wScriptModeAddr -- set during a phone call too; frame search clears any script before a probe
local atkdef, spespc

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

-- The Pokemon in a Discord message's corner: the trimmed 72px sprite once
-- "Download sprites..." has made it, else the public 56px one - see
-- data/discord_sprite.lua.
local DiscordSprite = require("data.discord_sprite")

local function shiny_sprite_url(dexNumber)
    return DiscordSprite.url(dexNumber, true)
end

local function regular_sprite_url(dexNumber)
    return DiscordSprite.url(dexNumber, false)
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
local COLOR_GREEN = 3066993 -- a shiny that's already yours (gift, egg, prize, starter)

local sessionResetCount = 0

-- Value fixed once per run inside M.init() below, via the launcher's
-- Savestate slot dropdown (falls back to 3, this module's historical
-- default, if the dropdown can't be read for some reason) - no longer a
-- hardcoded constant, see launcher.lua's AutocrystalGetSavestateSlot().
local SAVESTATE_SLOT

-- This Start's FrameSearch (data/frame_search.lua) - made by M.on_resume()
-- with new_frame_search() (defined further down).
local search, new_frame_search

local function shiny(atk, spc)
    if spc == 0xAA then
        for _, v in ipairs({0x2A, 0x3A, 0x6A, 0x7A, 0xAA, 0xBA, 0xEA, 0xFA}) do
            if atk == v then return true end
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

-- ===== M.init: runs once =====
-- Species and held item are fixed/known for a starter (not variable like
-- a wild encounter), and there's no battle to fight through, so
-- kill-mode doesn't apply either - gray all of these out.
-- Stop-on-shiny, every Auto-Catch field, and crit-safety override are
-- also greyed out - starters.lua never reads any of those Gui getters
-- (there's no wild-battle capture flow here at all), so they'd
-- otherwise look like live controls that silently do nothing.
-- Verbose Logging stays checkable.
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter", "chkUsePotions",
    "chkThiefMode", "txtThiefFilter",
    "chkStopOnShiny",
    "chkAutoCatch", "txtCatchFilter",
    "chkSkipAlreadyCaught",
    "chkStopAutoCatchException", "txtStopAutoCatchException",
    "chkOverrideCritSafety", "txtCustomHpTarget",
    "chkCatchOnItem", "txtCatchItemFilter",
    "chkCatchRetry", "txtCatchRetryCount", "chkCatchRetryAlways", "chkCatchSendNext",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall - .NET's
    -- HttpClient.Timeout can only be set before the first request, and
    -- BizHawk shares one persistent HttpClient per process, so calling
    -- this again after a restart (following any notification already
    -- sent) throws without the pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    -- SAVESTATE_SLOT is deliberately NOT set here anymore - see
    -- M.on_switch_to() below for why (M.init() only runs once per
    -- BizHawk session, which silently ignored later dropdown changes).

    local version = memory.readbyte(0x141)
    local region  = memory.readbyte(0x142)

    -- The Japanese versions (data/gs_jp.lua): revisions that haven't been
    -- checked stop here and say why.
    if GsJp.japanese(version, region) and not GsJp.supported(version, region) then
        print(GsJp.unsupported_reason(version))
        return false
    end

    if version == 0x54 then -- Crystal
        if region == 0x4A then
            base_address = 0xDC9D; versionStr = "Crystal JP"
        elseif region == 0x45 then
            base_address = 0xDCD7; versionStr = "Crystal US"
        else
            base_address = 0xDCD7; versionStr = "Crystal EU"
        end
        -- Verified against pokecrystal.sym: wScriptRunning ($D438). Same
        -- address static.lua already relies on for this same purpose.
        wScriptRunningAddr = 0xD438
        wScriptModeAddr = 0xD437 -- pokecrystal11.sym
        if GsJp.japanese(version, region) then
            wScriptRunningAddr, wScriptModeAddr = GsJp.w(0xD438), GsJp.w(0xD437)
        end
    elseif version == 0x55 or version == 0x58 then -- Gold/Silver
        if region == 0x4A then
            base_address = 0xD9E8; versionStr = "G/S JP"
        elseif region == 0x45 then
            base_address = 0xDA22; versionStr = "G/S US"
        elseif region == 0x4B then
            base_address = 0xDB1F; versionStr = "G/S KR"
        else
            base_address = 0xDA22; versionStr = "G/S EU"
        end
        -- Verified against pokegold1.sym: wScriptRunning ($D15F, plain
        -- SVBK-switched WRAM view). Same address static.lua uses.
        wScriptRunningAddr = 0xD15F
        wScriptModeAddr = 0xD15E -- pokegold1.sym/pokesilver.sym
        if GsJp.japanese(version, region) then
            wScriptRunningAddr, wScriptModeAddr = GsJp.w(0xD15F), GsJp.w(0xD15E)
            versionStr = GsJp.name(version)
        end
    else
        print("No valid ROM detected")
        return false
    end

    partysize = wram(base_address)
    dv_addr = (base_address + 0x1D) + partysize * 0x30
    -- Standard Gen 1/2 layout: species ID list starts right after the
    -- count byte, one byte per party slot - NOT independently verified
    -- this session, sanity-check against the actual species shown.
    species_list_addr = base_address + 1 + partysize

    math.randomseed(os.time())

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount,
        "Waiting for starter screen (" .. versionStr .. ")...")
    return true
end

-- Called every time this module becomes the active one, whether for the
-- first time or returning to it after a different module ran.
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
    SAVESTATE_SLOT = AutocrystalGetSavestateSlot(3)

    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position as the
-- reset target - position the game right before picking a starter, then
-- click Start.
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

    SavestateBackup.backup_slot_before_write(SAVESTATE_SLOT, "Starters")
    savestate.saveslot(SAVESTATE_SLOT)
    -- Re-read on every Start, not just in M.init() - that only runs once
    -- per BizHawk session, so starting again from a state with a
    -- different party size kept comparing against (and reading DVs from)
    -- the first run's slot. Same as egg.lua/gamecorner.lua's on_resume().
    partysize = wram(base_address)
    dv_addr = (base_address + 0x1D) + partysize * 0x30
    species_list_addr = base_address + 1 + partysize
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
-- Only B, never A: at Elm's YES/NO an A would take the starter (Start
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
            "Starters: a script/phone call was running (%s) - %s after %d B press(es).",
            label or "script/dialogue/call in progress",
            script_busy() and "gave up waiting for it to clear" or "cleared it",
            waited))
    end
    return true
end

-- Shiny, or Perfect / Perfect Negative DVs with their stop box ticked -
-- what frame search hands over to M.step() below.
local function roll_is_special(roll)
    local perfect = roll.atkdef == 0xFF and roll.spespc == 0xFF
    local negative = roll.atkdef == 0x00 and roll.spespc == 0x00
    return shiny(roll.atkdef, roll.spespc)
        or (perfect and Gui.stop_on_perfect(hud)) or (negative and Gui.stop_on_perfect_negative(hud))
end

-- This Start's search: from the starter Poke Ball, hold A through the
-- choice and Elm's lines until the starter joins the party.
function new_frame_search()
    return FrameSearch.new({
        label = "Starters",
        press = "hold",
        detect = FrameSearch.gift_detector({party = base_address, before = function() return partysize end}),
        is_real = function(roll) return roll.species >= 1 and roll.species <= 251 end,
        record = function(roll)
            sessionResetCount = sessionResetCount + 1
            Stats.record_encounter(roll.species, roll.atkdef, roll.spespc, true)
            Gui.update_last_encounter(hud, sessionResetCount, roll.species, get_pokemon_name(roll.species),
                math.floor(roll.atkdef / 16), roll.atkdef % 16, math.floor(roll.spespc / 16), roll.spespc % 16, false, nil)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount)
        end,
        special = roll_is_special,
        slot = function() return SAVESTATE_SLOT end,
        status = function(text)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, text)
        end,
        script_addr = wScriptRunningAddr,
        script_busy = script_busy,
        clear_script = function() return wait_for_no_active_script("frame search") end,
    })
end

-- ===== M.step: one call per frame =====
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

    -- Frame search does the searching; only a starter it handed over - in
    -- the party now, on the real timeline - is read and handled below.
    if not search.handedOver or wram(base_address) == partysize then
        return search:step()
    end

    -- Short wait only - NOT mashing through to
    -- the nickname prompt (that was likely overcorrecting; the actual
    -- confirmed bug was the too-narrow randomization range below, not
    -- read timing). Verify via the per-attempt console log that DVs
    -- come through consistently non-zero and correctly varying with
    -- just this short wait - if not, this needs revisiting.
    for i = 1, 10 do emu.frameadvance() end

    -- Same settle-frame race already found and fixed for the other
    -- gift-receive paths (see rng_mechanics.md's "Reload-spam bug,
    -- actual root cause found" - Static, and now Egg too after a
    -- confirmed user report there): the game writes a template/
    -- placeholder value to the new slot first, before a later step
    -- overwrites it with the real species/DVs - reading immediately
    -- after a fixed wait can catch that placeholder instead of the
    -- final value. This was flagged as an open, never-verified question
    -- right above (see the comment on the short-wait loop) and never
    -- actually got the fix - wait for species+DVs to read identically on
    -- two consecutive frames before trusting any of it, same as Static.
    atkdef = wram(dv_addr)
    spespc = wram(dv_addr + 1)
    local species = wram(species_list_addr)
    do
        local stableFrames = 0
        local waited = 0
        while stableFrames < 2 and waited < 30 do
            emu.frameadvance()
            waited = waited + 1
            local curSpecies = wram(species_list_addr)
            local curAtkdef = wram(dv_addr)
            local curSpespc = wram(dv_addr + 1)
            if curSpecies == species and curAtkdef == atkdef and curSpespc == spespc then
                stableFrames = stableFrames + 1
            else
                species = curSpecies
                atkdef = curAtkdef
                spespc = curSpespc
                stableFrames = 0
            end
        end
        if waited > 2 then
            print(string.format("Starter slot data wasn't immediately stable, waited %d frames before trusting it (species settled on #%d) - if a bogus instant-shiny recurs, this was it.", waited, species))
        end
    end
    local speciesName = get_pokemon_name(species)

    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16
    local isShiny = shiny(atkdef, spespc)

    sessionResetCount = sessionResetCount + 1
    local encounterLine = string.format("#%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s",
        sessionResetCount, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or "")
    print(encounterLine)

    -- See data/console_log.lua for the full rationale: BizHawk's own
    -- Lua console has no cap on accumulated output and gets slower to
    -- append to as its backlog grows, so we clear it ourselves
    -- periodically instead of making users do it manually. The same
    -- line is also written to a rotating on-disk log so clearing the
    -- console never actually loses anything.
    ConsoleLog.maybe_clear_console(sessionResetCount)
    ConsoleLog.log_encounter("starters", encounterLine)

    Stats.record_encounter(species, atkdef, spespc)
    Gui.update_last_encounter(hud, sessionResetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, nil)

    local isPerfect = (atkv == 15 and defv == 15 and spdv == 15 and spcv == 15)
    local isPerfectNegative = (atkv == 0 and defv == 0 and spdv == 0 and spcv == 0)
    local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)

    if isShiny then
        ShinySavestate.save_if_enabled(Gui, hud, speciesName)
        local encountersBeforeThisShiny = Stats.encountersSinceShiny
        Stats.record_shiny(species)
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "SHINY FOUND!")
        send_discord_embed(
            string.format("\xE2\x9C\xA8 Shiny Starter %s Found!", speciesName),
            nil,
            {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                divider_field(),
                {name = "Resets For This Shiny", value = tostring(encountersBeforeThisShiny), inline = true},
                {name = "Resets Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                {name = "Shinies Of This Species", value = tostring(Stats.species_shiny_count(species)), inline = true},
                divider_field(),
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            },
            COLOR_GREEN, -- already yours: green like a catch
            shiny_sprite_url(species)
        )
        return true
    elseif Gui.stop_on_perfect(hud) and isPerfect then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Perfect DVs found!")
        send_discord_embed(
            string.format("\xF0\x9F\x92\xAF Perfect DVs Found! %s", speciesName),
            nil,
            {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                divider_field(),
                {name = "Resets Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                divider_field(),
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            },
            COLOR_GREEN, -- already yours: green like a catch
            regular_sprite_url(species)
        )
        return true
    elseif Gui.stop_on_perfect_negative(hud) and isPerfectNegative then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Perfect Negative DVs found!")
        send_discord_embed(
            string.format("\xF0\x9F\x92\xAF Perfect Negative DVs Found! %s", speciesName),
            nil,
            {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                divider_field(),
                {name = "Resets Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                divider_field(),
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            },
            COLOR_GREEN, -- already yours: green like a catch
            regular_sprite_url(species)
        )
        return true
    else
        -- Read differently on the real timeline than in the search (not
        -- seen so far) - back to the next frame to try, and carry on.
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Resetting...")
        savestate.loadslot(SAVESTATE_SLOT)
        return false
    end
end

return M

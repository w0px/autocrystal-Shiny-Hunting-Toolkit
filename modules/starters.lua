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
--     breaks this determinism so DVs actually vary between attempts.
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
RngEnabler = require("data.rng_enabler")

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua/friendship.lua/static.lua - see
-- data/location_names.lua for where this comes from (the actual
-- pret/pokecrystal disassembly, not a guess). Feeds the Rich Presence
-- location the same as those modules (always the starter-choice room,
-- but shown for consistency across every module).
local LocationNames = require("data.location_names")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local hud
local base_address, versionStr, partysize, dv_addr, species_list_addr
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

local function shiny_sprite_url(dexNumber)
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/shiny/%d.png",
        dexNumber)
end

local function regular_sprite_url(dexNumber)
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/%d.png",
        dexNumber)
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
local COLOR_RED = 15158332

-- Even leaner colored embed for bot-status alerts (stuck detection) that
-- aren't about a specific encounter.
local function send_alert(title, color)
    send_discord_embed(title, nil, nil, color, nil)
end
local sessionResetCount = 0
-- Up to 8 split points across the reset sequence instead of 1 giant
-- delay - each fires once per reset cycle, at a genuinely different
-- moment with real game logic in between. Confirmed via direct
-- measurement that more split points meaningfully close the gap toward
-- true uniform coverage (2 splits: 71.5% unique; 4 splits: 94.0% unique
-- out of a real sample). Pushing further since this matters for EVERY
-- user's own save file independently - a coverage gap could mean some
-- save files structurally can't reach a shiny/perfect-DV combination
-- while others can, for no reason the user could ever detect.
-- Split 1 fires immediately on reload (no flag needed, synchronous).
-- Splits 2-6 fire one per mash-loop iteration, up to MASH_SPLITS_TARGET.
-- Split 7 fires the instant the Pokemon is received.
-- Split 8 fires right after the final settle wait, just before reading DVs.
local MASH_SPLITS_TARGET = 5
local mashSplitsFired = 0
local lastResetTime = nil
local splitAfterReceivedPending = false
local splitAfterSettlePending = false
local consecutiveStuckReloads = 0

local SAVESTATE_SLOT = 3

-- Same periodic savestate re-roll as static.lua (see rng_mechanics.md):
-- BizHawk is fully deterministic, so whatever DV states are reachable
-- from a given savestate are a FIXED set no matter how many times it's
-- reloaded and retried - if that set happens to exclude every
-- shiny/perfect combination, no amount of resetting will ever find one.
-- Every REROLL_INTERVAL_SECONDS, right at a clean boundary (still sitting
-- at the starter-choice screen, nothing mid-flight), this re-baselines
-- the savestate with a fresh, unpredictable starting point instead of
-- staying stuck on whatever pool the very first savestate happened to
-- land on. This also supersedes "True Randomness" here - see
-- reroll_savestate_pool() below and the removed Gui.true_randomness_enabled()
-- check in the not-shiny branch.
local REROLL_INTERVAL_SECONDS = 1800 -- 30 minutes
local lastRerollTime = nil

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
-- True Randomness IS in this list now - starters.lua no longer calls
-- Gui.true_randomness_enabled() at all, since reroll_savestate_pool()'s
-- periodic full-coverage injection supersedes it (same reasoning as
-- static.lua - see rng_mechanics.md). Greyed out here so it's visually
-- obvious it has no effect while Starters is the active module. Verbose
-- Logging stays checkable.
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkStopOnShiny",
    "chkAutoCatch", "txtCatchFilter",
    "chkSkipAlreadyCaught",
    "chkStopAutoCatchException", "txtStopAutoCatchException",
    "chkOverrideCritSafety", "txtCustomHpTarget",
    "chkCatchOnItem", "txtCatchItemFilter",
    "chkTrueRandomness",
    "chkDontWeaken",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall - .NET's
    -- HttpClient.Timeout can only be set before the first request, and
    -- BizHawk shares one persistent HttpClient per process, so calling
    -- this again after a restart (following any notification already
    -- sent) throws without the pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    local version = memory.readbyte(0x141)
    local region  = memory.readbyte(0x142)

    if version == 0x54 then -- Crystal
        if region == 0x4A then
            base_address = 0xDC9D; versionStr = "Crystal JP"
        elseif region == 0x45 then
            base_address = 0xDCD7; versionStr = "Crystal US"
        else
            base_address = 0xDCD7; versionStr = "Crystal EU"
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
    else
        print("No valid ROM detected")
        return false
    end

    partysize = memory.readbyte(base_address)
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

    savestate.saveslot(SAVESTATE_SLOT)
    mashSplitsFired = 0
    splitAfterReceivedPending = false
    splitAfterSettlePending = false
    lastResetTime = os.time()
    consecutiveStuckReloads = 0
    -- Fresh clock for the periodic pool re-roll - the savestate just
    -- taken above already got its own "free" reroll (whatever RNG state
    -- existed at the moment Start was clicked), so the next automatic
    -- one shouldn't fire until a full interval from now.
    lastRerollTime = os.time()
end

-- Re-baselines the savestate with a fresh, unpredictable starting point -
-- see REROLL_INTERVAL_SECONDS above for why this matters. Only called
-- while still sitting at the starter-choice screen (nothing mid-flight),
-- same safety requirement as static.lua's version.
local function reroll_savestate_pool()
    print(string.format(
        "Re-rolling savestate pool after %d minutes - injecting fresh entropy and re-baselining to avoid getting permanently stuck if this pool excludes the shiny/perfect-DV states.",
        math.floor(REROLL_INTERVAL_SECONDS / 60)))
    RngEnabler.enable_randomness(RngEnabler.FULL_COVERAGE_RANGE)
    savestate.saveslot(SAVESTATE_SLOT)
    lastRerollTime = os.time()
end

-- If 60 seconds pass without reaching a shiny/not-shiny decision (e.g.
-- a phone call interrupted the mashing sequence), force the same
-- reload this module already does every normal cycle anyway - simpler
-- and more reliable than guessing what recovery input is needed, since
-- it just goes back to a known-good state unconditionally. This part
-- ALWAYS happens immediately (it's a real fix, not a guess) - what's
-- two-tier is just the Discord notification: the first forced reload
-- only prints to console, and only escalates to Discord if a SECOND
-- consecutive stuck-trigger happens without a normal cycle completing
-- in between (i.e. the forced reload didn't actually fix anything).
local STUCK_RESET_TIMEOUT = 60
local function check_stuck_and_force_reset()
    if lastResetTime == nil then
        lastResetTime = os.time()
        return
    end
    if os.time() - lastResetTime >= STUCK_RESET_TIMEOUT then
        consecutiveStuckReloads = consecutiveStuckReloads + 1
        print(string.format("WARNING: no reset for %d+ seconds (stuck check #%d) - likely stuck (phone call, etc). Forcing a reload.",
            STUCK_RESET_TIMEOUT, consecutiveStuckReloads))
        if consecutiveStuckReloads >= 2 then
            send_alert(string.format(
                "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck: no reset for over %d seconds, even after a forced reload attempt. Check on it.",
                STUCK_RESET_TIMEOUT * consecutiveStuckReloads), COLOR_RED)
        end
        savestate.loadslot(SAVESTATE_SLOT)
        mashSplitsFired = 0
        splitAfterReceivedPending = false
        splitAfterSettlePending = false
        lastResetTime = os.time()
    end
end

-- ===== M.step: one call per frame =====
function M.step()
    check_stuck_and_force_reset()

    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick. Only
    -- updates when the (group, number) pair is a RECOGNIZED location -
    -- an unrecognized pair almost always means these two WRAM bytes got
    -- transiently repurposed for something else, not an actual new
    -- location. See wild.lua's M.step() for the original fix this
    -- mirrors.
    do
        local mapKey = string.format("%d:%d", memory.readbyte(0xdcb5), memory.readbyte(0xdcb6))
        if LocationNames[mapKey] then
            AutocrystalCurrentLocation = LocationNames[mapKey]
        end
    end

    -- Not received yet - keep mashing A and waiting.
    if memory.readbyte(base_address) == partysize then
        -- Only safe to re-roll right here: still sitting at the
        -- starter-choice screen, nothing mid-flight (received-but-not-
        -- settled, DV read pending, etc).
        if lastRerollTime and os.time() - lastRerollTime >= REROLL_INTERVAL_SECONDS then
            reroll_savestate_pool()
        end

        if mashSplitsFired < MASH_SPLITS_TARGET then
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            mashSplitsFired = mashSplitsFired + 1
        end

        for i = 1, 10 do emu.frameadvance() end
        joypad.set({A = true})
        return false
    end

    -- Party size just increased - split point right at the moment of
    -- receiving, before the final settle wait.
    if splitAfterReceivedPending then
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        splitAfterReceivedPending = false
    end

    -- Short wait only - NOT mashing through to
    -- the nickname prompt (that was likely overcorrecting; the actual
    -- confirmed bug was the too-narrow randomization range below, not
    -- read timing). Verify via the per-attempt console log that DVs
    -- come through consistently non-zero and correctly varying with
    -- just this short wait - if not, this needs revisiting.
    for i = 1, 10 do emu.frameadvance() end

    -- Final split point, right after the settle wait, just before
    -- actually reading DVs.
    if splitAfterSettlePending then
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        splitAfterSettlePending = false
    end

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
    atkdef = memory.readbyte(dv_addr)
    spespc = memory.readbyte(dv_addr + 1)
    local species = memory.readbyte(species_list_addr)
    do
        local stableFrames = 0
        local waited = 0
        while stableFrames < 2 and waited < 30 do
            emu.frameadvance()
            waited = waited + 1
            local curSpecies = memory.readbyte(species_list_addr)
            local curAtkdef = memory.readbyte(dv_addr)
            local curSpespc = memory.readbyte(dv_addr + 1)
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
    print(string.format("#%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s",
        sessionResetCount, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or ""))
    Stats.record_encounter(species)
    Gui.update_last_encounter(hud, sessionResetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, nil)

    local isPerfect = (atkv == 15 and defv == 15 and spdv == 15 and spcv == 15)
    local isPerfectNegative = (atkv == 0 and defv == 0 and spdv == 0 and spcv == 0)
    local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)

    if isShiny then
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
            COLOR_GOLD,
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
            COLOR_GOLD,
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
            COLOR_GOLD,
            regular_sprite_url(species)
        )
        return true
    else
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Resetting...")
        savestate.loadslot(SAVESTATE_SLOT)
        lastResetTime = os.time()
        consecutiveStuckReloads = 0
        -- Up to 8 split points across the reset sequence instead of one
        -- giant wait - this is the first, applied immediately; up to 5
        -- more fire during the dialogue-mash loop, one more right when
        -- received, and a final one right before reading DVs.
        --
        -- REMOVED: "True Randomness" mode used to use the full 65536+
        -- frame range for this first delay instead, gated behind the
        -- shared checkbox. Superseded by reroll_savestate_pool() above,
        -- which does the same full-coverage injection but only once per
        -- REROLL_INTERVAL_SECONDS instead of every single reset - see
        -- rng_mechanics.md for the Monte Carlo comparison that motivated
        -- this same change in static.lua. Gui.true_randomness_enabled()
        -- is deliberately not read here anymore.
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        mashSplitsFired = 0
        splitAfterReceivedPending = true
        splitAfterSettlePending = true
        return false
    end
end

return M

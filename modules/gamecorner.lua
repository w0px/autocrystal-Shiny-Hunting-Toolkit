-- gamecorner.lua
-- Game Corner prize Pokemon (Abra, Cubone, Wobbuffet, etc.) via
-- soft-reset. Structurally this is closest to egg.lua, NOT wild.lua/
-- static.lua - the prize goes directly into your PARTY (a purchase),
-- not into an enemy-data slot like a wild battle would.
--
-- Save right at the prize-selection menu, with the cursor already on
-- whichever Pokemon you want (confirmed: pressing A ~6 times from there
-- handles the "are you sure?" confirmation and the following text,
-- ending with the Pokemon in your party - no need to know the exact
-- count, just mash until party size increases, same as egg.lua).
--
-- Since the savestate is taken at this exact screen, your coin balance
-- gets correctly restored on every single reload too - no risk of
-- coins draining across resets, since nothing is ever actually spent
-- outside of a state that gets reloaded away again.
--
-- No kill mode, no species stop: the species is already fixed by
-- whichever prize you selected before saving, and killing a purchased
-- Pokemon is never desirable.
--
-- Same anti-determinism fix as Starters/Egg/Static: soft-resetting with
-- perfectly identical input timing produces IDENTICAL "random" results
-- every attempt unless timing variance is deliberately introduced after
-- each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
Stats = require("data.stats")
RngEnabler = require("data.rng_enabler")

-- Full 388-entry (map group, map number) -> name table, shared with
-- every other module - see data/location_names.lua for where this
-- comes from (the actual pret/pokecrystal disassembly, not a guess).
-- Always Goldenrod Game Corner in practice, but shown for consistency
-- across every module.
local LocationNames = require("data.location_names")

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

local function shiny_sprite_url(dexNumber)
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/shiny/%d.png",
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

local SAVESTATE_SLOT = 6 -- separate from Starters(3)/Egg(4)/Static(5)

local party_base_addr
local partysizeBeforeReceiving
local newSlotIndex
local newDvAddr, newSpeciesAddr

local resetCount = 0

-- Every split point happens during the mash-A phase - there's no
-- separate "received but not yet read" window like egg.lua has, since
-- we read DVs directly from the party slot the moment party size
-- increases, same read point as the last split.
local MASH_SPLITS_TARGET = 8
local mashSplitsFired = 0
local lastResetTime = nil
local consecutiveStuckReloads = 0

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
    joypad.set({})
    emu.frameadvance()
end

-- ===== M.init: runs ONCE =====
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkKillMode", "txtKillFilter",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    else
        print("No valid ROM detected")
        return false
    end

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand at the prize menu with your Pokemon selected, then click Start...")
    return true
end

function M.on_switch_to()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position -
-- prize menu open, cursor on the desired Pokemon - as the reset target.
function M.on_resume()
    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = memory.readbyte(party_base_addr)
    newSlotIndex = partysizeBeforeReceiving
    newDvAddr = party_base_addr + 0x1D + newSlotIndex * 0x30
    newSpeciesAddr = party_base_addr + 1 + newSlotIndex
    mashSplitsFired = 0
    lastResetTime = os.time()
    consecutiveStuckReloads = 0
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
        partysizeBeforeReceiving = memory.readbyte(party_base_addr)
        mashSplitsFired = 0
        lastResetTime = os.time()
    end
end

-- ===== M.step =====
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

    local currentPartySize = memory.readbyte(party_base_addr)

    if currentPartySize <= partysizeBeforeReceiving then
        -- Still working through the "are you sure?" confirmation and
        -- the following text - keep mashing A.
        if mashSplitsFired < MASH_SPLITS_TARGET then
            if Gui.true_randomness_enabled(hud) then
                RngEnabler.enable_randomness(RngEnabler.FULL_COVERAGE_RANGE)
            else
                RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            end
            mashSplitsFired = mashSplitsFired + 1
        end
        press_button("A")
        return false
    end

    -- Party size increased - the Pokemon is in, read its DVs directly.
    resetCount = resetCount + 1

    -- Same settle-frame race already found and fixed for the other
    -- gift-receive paths (see rng_mechanics.md's "Reload-spam bug,
    -- actual root cause found" - Static, and Egg after a confirmed user
    -- report): the game writes a template/placeholder value to the new
    -- slot first, before a later step overwrites it with the real
    -- species/DVs. This file didn't even have a fixed settle wait before
    -- reading, let alone a stability check - reading the SAME tick the
    -- party-size increase is first observed is the most exposed version
    -- of this race in the whole project. Wait for species+DVs to read
    -- identically on two consecutive frames before trusting any of it,
    -- same fix as Static/Starters/Egg.
    local species = memory.readbyte(newSpeciesAddr)
    local atkdef = memory.readbyte(newDvAddr)
    local spespc = memory.readbyte(newDvAddr + 1)
    do
        local stableFrames = 0
        local waited = 0
        while stableFrames < 2 and waited < 30 do
            emu.frameadvance()
            waited = waited + 1
            local curSpecies = memory.readbyte(newSpeciesAddr)
            local curAtkdef = memory.readbyte(newDvAddr)
            local curSpespc = memory.readbyte(newDvAddr + 1)
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
            print(string.format("Game Corner slot data wasn't immediately stable, waited %d frames before trusting it (species settled on #%d) - if a bogus instant-shiny recurs, this was it.", waited, species))
        end
    end
    local speciesName = get_pokemon_name(species)
    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16
    local isShiny = shiny(atkdef, spespc)

    print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d", speciesName, species, atkv, defv, spdv, spcv))

    Stats.record_encounter(species)
    Gui.update_last_encounter(hud, resetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, "(no item)")

    if isShiny then
        print(string.format("SHINY Game Corner Pokemon found! %s Atk:%d Def:%d Spe:%d Spc:%d - stopping here",
            speciesName, atkv, defv, spdv, spcv))
        local encountersBeforeThisShiny = Stats.encountersSinceShiny
        Stats.record_shiny(species)
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            "SHINY found! Stopped.")
        local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)
        send_discord_embed(
            string.format("\xE2\x9C\xA8 Shiny Game Corner %s Found!", speciesName),
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
    else
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            "Not shiny - resetting...")
        savestate.loadslot(SAVESTATE_SLOT)
        mashSplitsFired = 0
        lastResetTime = os.time()
        consecutiveStuckReloads = 0
        return false
    end
end

return M

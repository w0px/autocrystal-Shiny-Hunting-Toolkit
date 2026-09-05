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
SavestateBackup = require("data.savestate_backup")
ConsoleLog = require("data.console_log")

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

-- Value fixed once per run inside M.init() below, via the launcher's
-- Savestate slot dropdown (falls back to 6, this module's historical
-- default, separate from Starters(3)/Egg(4)/Static(5), if the dropdown
-- can't be read) - no longer a hardcoded constant, see launcher.lua's
-- AutocrystalGetSavestateSlot().
local SAVESTATE_SLOT

local party_base_addr
local wScriptRunningAddr -- non-zero while any overworld script (dialogue/call/fade/cutscene) is running - see the root-cause comment in M.step() for why this module needs it too
local partysizeBeforeReceiving
local newSlotIndex
local newDvAddr, newSpeciesAddr

local resetCount = 0

-- Locked in from the FIRST valid-looking read of a run and never
-- changed again after that - see the big root-cause comment in M.step()
-- for why this exists. The prize species can never actually change
-- mid-run (it was fixed the moment the savestate was taken at the prize
-- menu), so once we know it, any later read that disagrees is
-- definitely a corrupted/mid-animation read, not a real different
-- Pokemon - same "expected species" sanity-check pattern static.lua
-- already uses (BATTLE_TARGET_EXPECTED_SPECIES) for this exact class of
-- garbage-read problem. Reset to nil on every fresh Start click.
local expectedSpecies = nil

-- Gen II's internal species index range - anything outside this is
-- never a real Pokemon (0 = empty slot placeholder, 255/0xFF = the
-- "Unknown #255" garbage byte this whole fix exists because of).
local function is_plausible_species(s)
    return s >= 1 and s <= 251
end

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

-- Bounded generous timeout (frames) for wait_for_no_active_script() below
-- - matches the other modules' REROLL_SCRIPT_CLEAR_TIMEOUT ballpark. The
-- Pokedex-registration fade this exists to wait out (see M.step()'s
-- read-logic comment) is a real multi-stage animation, comfortably
-- longer than the old flat 30-frame settle cap this replaces.
local SCRIPT_CLEAR_TIMEOUT = 300

-- Presses ONLY B and waits until wScriptRunningAddr reads 0 (or the
-- bounded timeout is hit) - a real confirmation that no dialogue/fade/
-- cutscene is still mid-flight, not a guess. No-op if nothing is open
-- (the common case for every prize EXCEPT a not-yet-Pokedex'd one - see
-- M.step()).
--
-- UPDATE - originally alternated B/A like the identical helper in
-- static.lua/egg.lua/starters.lua's reroll_savestate_pool() paths, on the
-- theory that some prompts need a real A. That fixed the nickname prompt
-- for ordinary resets, but a real user report showed a SHINY catch still
-- got named "AAAAAAAAAAAA" - the "Would you like to give a nickname?"
-- yesorno prompt lands on whichever frame it lands on, and alternating
-- B/A means whether that happens to be a B (declines - correct) or an A
-- (confirms YES, then starts filling the name grid with A's) depends
-- purely on parity/timing that can differ run to run - it isn't actually
-- watching for the prompt, just guessing blind. B alone sidesteps that
-- entirely: B answers any yesorno with No, and B also clears a plain
-- waitbutton textbox just fine in Gen II (doesn't need to be A) - so
-- there's no upside to ever risking an A here, only downside.
local function wait_for_no_active_script()
    if not wScriptRunningAddr then return end
    local waited = 0
    while memory.readbyte(wScriptRunningAddr) ~= 0 and waited < SCRIPT_CLEAR_TIMEOUT do
        press_button("B")
        waited = waited + 1
    end
    if waited > 0 then
        vprint(string.format(
            "Game Corner: wScriptRunning was active after the party-size increase (Pokedex-registration fade for a first-time prize, most likely) - %s after %d frame(s).",
            (memory.readbyte(wScriptRunningAddr) == 0) and "cleared it" or "gave up waiting for it to clear",
            waited))
    end
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

    -- SAVESTATE_SLOT is deliberately NOT set here anymore - see
    -- M.on_switch_to() below for why (M.init() only runs once per
    -- BizHawk session, which silently ignored later dropdown changes).

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
        -- Verified against pokecrystal.sym: wScriptRunning ($D438). Same
        -- address static.lua/egg.lua/starters.lua already rely on for
        -- this same "is any overworld script/dialogue/fade still in
        -- progress" purpose - see wait_for_no_active_script() below for
        -- why this module needs it too now.
        wScriptRunningAddr = 0xD438
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
        -- Verified against pokegold1.sym: wScriptRunning ($D15F, plain
        -- SVBK-switched WRAM view). Same address static.lua uses.
        wScriptRunningAddr = 0xD15F
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
    SAVESTATE_SLOT = AutocrystalGetSavestateSlot(6)

    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position -
-- prize menu open, cursor on the desired Pokemon - as the reset target.
function M.on_resume()
    SavestateBackup.backup_slot_before_first_write(SAVESTATE_SLOT, "GameCorner")
    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = memory.readbyte(party_base_addr)
    newSlotIndex = partysizeBeforeReceiving
    newDvAddr = party_base_addr + 0x1D + newSlotIndex * 0x30
    newSpeciesAddr = party_base_addr + 1 + newSlotIndex
    mashSplitsFired = 0
    lastResetTime = os.time()
    consecutiveStuckReloads = 0
    expectedSpecies = nil
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

    -- REAL ROOT CAUSE of the "works fine at Goldenrod, gives garbage
    -- species/false shinies at Celadon (Kanto)" reports - confirmed
    -- against the actual pokecrystal disassembly, NOT a Johto/Kanto
    -- address difference (wPartyMon1 lives in a WRAM bank that's fixed
    -- for the whole ROM - SVBK bank 1 - identical in both cities, so no
    -- per-region profile/dropdown is needed here):
    --
    -- maps/CeladonGameCornerPrizeRoom.asm's prize vendor calls the same
    -- shared std script as Goldenrod's (checkcoins -> yesorno -> special
    -- GameCornerPrizeMonCheckDex -> givepoke -> takecoins) - but
    -- GameCornerPrizeMonCheckDex (engine/events/specials.asm) only
    -- `ret nz`s immediately if the species is ALREADY registered in your
    -- Pokedex. If it isn't, it runs a real FadeToMenu + farcall
    -- NewPokedexEntry + ExitAllMenus sequence - a genuine screen-fade/
    -- Pokedex-registration animation - BEFORE givepoke ever places the
    -- Pokemon in the party. Since this savestate reloads to a point
    -- BEFORE that registration, every single reset re-triggers the full
    -- animation for a not-yet-caught species. Goldenrod's classic prize
    -- mons are almost always already dex'd long before anyone resets for
    -- them, so this path silently never fired there - it took a
    -- genuinely first-time Kanto Pikachu to expose it. That fade can
    -- easily outlast the old flat 30-frame settle cap below, so species/
    -- DV bytes were being trusted mid-animation - explains both the
    -- bogus "Unknown #255" reads and the false shinies (a mid-fade byte
    -- can coincidentally match the shiny bit pattern). Once this exact
    -- Pikachu (or whatever species) has actually been caught once for
    -- real, its dex entry sticks in your SAVE file going forward and this
    -- extra animation stops firing entirely - same as it already doesn't
    -- for Goldenrod's prizes.
    --
    -- Fix: wait for wScriptRunningAddr to genuinely clear (mashing A to
    -- help it along) before trusting anything, same pattern already
    -- proven for reroll safety elsewhere in this project - a real
    -- "is the game actually done" check instead of a guessed frame count.
    wait_for_no_active_script()

    -- Belt-and-suspenders on top of the above: still confirm species+DVs
    -- read identically on two consecutive frames before trusting any of
    -- it (the original fix for the separate, smaller template/placeholder
    -- settle race already found and fixed for the other gift-receive
    -- paths - Static/Starters/Egg). Also now treats an IMPLAUSIBLE
    -- species (0, 255, anything outside Gen II's real 1-251 range) or a
    -- mismatch against expectedSpecies as "not stable yet" too, not just
    -- "changed since last frame" - wScriptRunningAddr can apparently
    -- still read 0 for a stray frame or two mid-animation (multi-stage
    -- sequences like this fade sometimes do), so wait_for_no_active_
    -- script() alone wasn't airtight against every timing case reported.
    -- Bumped the cap from 30 to 120 frames to match.
    local species = memory.readbyte(newSpeciesAddr)
    local atkdef = memory.readbyte(newDvAddr)
    local spespc = memory.readbyte(newDvAddr + 1)
    local SETTLE_TIMEOUT = 120
    do
        local stableFrames = 0
        local waited = 0
        while stableFrames < 2 and waited < SETTLE_TIMEOUT do
            emu.frameadvance()
            waited = waited + 1
            local curSpecies = memory.readbyte(newSpeciesAddr)
            local curAtkdef = memory.readbyte(newDvAddr)
            local curSpespc = memory.readbyte(newDvAddr + 1)
            local curPlausible = is_plausible_species(curSpecies) and
                (expectedSpecies == nil or curSpecies == expectedSpecies)
            if curSpecies == species and curAtkdef == atkdef and curSpespc == spespc and curPlausible then
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

    -- Final gate: never report/record a read that's still implausible or
    -- disagrees with the species this run already locked in - the prize
    -- species physically cannot change mid-run (fixed the moment the
    -- savestate was taken), so a mismatch here is provably a corrupted
    -- mid-animation read, not a real different Pokemon. Silently discard
    -- this cycle (no Stats.record_encounter, no shiny report, no GUI
    -- update) and reload, same as check_stuck_and_force_reset() does for
    -- a genuinely stuck cycle - this is the actual backstop against
    -- false shinies, not just a nicer wait.
    if not is_plausible_species(species) or (expectedSpecies ~= nil and species ~= expectedSpecies) then
        print(string.format(
            "Game Corner: discarding a bad read (species #%d, expected %s) after %d settle frames - reloading without recording it.",
            species, expectedSpecies and ("#" .. expectedSpecies) or "unknown yet", SETTLE_TIMEOUT))
        resetCount = resetCount - 1
        savestate.loadslot(SAVESTATE_SLOT)
        mashSplitsFired = 0
        lastResetTime = os.time()
        consecutiveStuckReloads = 0
        return false
    end
    if expectedSpecies == nil then
        expectedSpecies = species
    end

    local speciesName = get_pokemon_name(species)
    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16
    local isShiny = shiny(atkdef, spespc)

    local encounterLine = string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d", speciesName, species, atkv, defv, spdv, spcv)
    print(encounterLine)

    -- See data/console_log.lua for the full rationale: BizHawk's own
    -- Lua console has no cap on accumulated output and gets slower to
    -- append to as its backlog grows, so we clear it ourselves
    -- periodically instead of making users do it manually. The same
    -- line is also written to a rotating on-disk log so clearing the
    -- console never actually loses anything.
    ConsoleLog.maybe_clear_console(resetCount)
    ConsoleLog.log_encounter("gamecorner", encounterLine)

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

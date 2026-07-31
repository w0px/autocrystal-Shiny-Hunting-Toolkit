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
-- you deliberately introduce timing variance after each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
Stats = require("data.stats")
RngEnabler = require("data.rng_enabler")

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua/friendship.lua/static.lua/
-- starters.lua - see data/location_names.lua for where this comes from
-- (the actual pret/pokecrystal disassembly, not a guess). Egg-hatching
-- involves walking, so location can genuinely vary here too.
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

local EGG_PLACEHOLDER = 0xFD
local SAVESTATE_SLOT = 4 -- separate from Starters' slot 3, avoids any cross-module confusion

local party_base_addr
local eggSlotIndex -- fixed once determined: the same slot every reset, since party size before receiving never changes
local eggDvAddr
local eggSpeciesListAddr
local partysizeBeforeReceiving

local enemy_species_addr -- generic wild-battle address, safety net during the walk-to-hatch phase only

local resetCount = 0
local stepsTaken = 0
local sessionEncounterCount = 0
local confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv
-- Up to 8 split points across the reset sequence instead of 1 giant
-- delay - confirmed via direct measurement on Starters that this closes
-- the gap toward true uniform coverage far better than a single delay
-- (98.8% unique with 8 splits vs ~71.5% with just 1-2). Bringing egg.lua
-- up to the same standard after its own test showed only 60% unique.
local MASH_SPLITS_TARGET = 5
local mashSplitsFired = 0
local lastResetTime = nil
local consecutiveStuckReloads = 0

-- Same periodic savestate re-roll as static.lua (see rng_mechanics.md):
-- BizHawk is fully deterministic, so whatever DV states are reachable
-- from a given savestate are a FIXED set no matter how many times it's
-- reloaded and retried - if that set happens to exclude every shiny
-- combination, no amount of resetting will ever find one. Every
-- REROLL_INTERVAL_SECONDS, right at a clean boundary (still waiting for
-- the egg, nothing mid-flight), this re-baselines the savestate with a
-- fresh, unpredictable starting point instead of staying stuck on
-- whatever pool the very first savestate happened to land on. This also
-- supersedes "True Randomness" here - see reroll_savestate_pool() below
-- and the removed Gui.true_randomness_enabled() check in the not-shiny
-- branch.
local REROLL_INTERVAL_SECONDS = 1800 -- 30 minutes
local lastRerollTime = nil
-- Increments once per reroll_savestate_pool() call and gets stamped into
-- every per-encounter log line below (win:N) - lets a pasted log batch be
-- split by savestate-pool window after the fact, so the DV combos seen in
-- one 30-minute window can be diffed against the next one to confirm the
-- reroll is actually landing on a genuinely different reachable pool
-- (rather than, say, silently reusing the same one).
local rerollWindow = 1
-- A mystery-egg delivery (e.g. Togepi) has its own confirmation dialogue
-- that the standard day-care egg flow doesn't - walking logic assumes
-- the character is immediately free to move, so this needs clearing
-- once before the first walk attempt after a shiny is confirmed.
local hatchDialogueCleared = true
local splitAfterReceivedPending = false
local splitAfterSettlePending = false

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
local MOVEMENT_IDLE_VALUE = 0xFF

local function attempt_step(direction)
    local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)

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

    local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    return (endX ~= startX or endY ~= startY)
end

local safe_pair = nil
local homeX, homeY = nil, nil

local function walk_toward_home()
    local curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
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
    curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    return (curX == homeX and curY == homeY)
end

local function find_safe_pair(verbose)
    local anchorX, anchorY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
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

            local nowX, nowY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
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
        homeX, homeY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        vprint(string.format("Anchoring home tile at X=%d Y=%d", homeX, homeY))
    end

    if safe_pair == nil then
        local curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
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
        local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end

        local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
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
-- reroll_savestate_pool()'s periodic full-coverage injection supersedes
-- it (same reasoning as static.lua - see rng_mechanics.md). Greyed out
-- here so it's visually obvious it has no effect while Egg is the active
-- module. Verbose Logging stays checkable.
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

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        elseif region == 0x45 then party_base_addr = 0xDCD7
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x45 then party_base_addr = 0xDA22
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    else
        print("No valid ROM detected")
        return false
    end

    if version == 0x54 then
        if region == 0x4A then enemy_species_addr = 0xd23d + 0x22
        else enemy_species_addr = 0xd20c + 0x22 end
    else
        -- Verified against pokegold.sym for EU/US: enemy_species_addr
        -- should be based on wEnemyMonDVs ($D0F5), NOT $DA22 (which is
        -- actually wPartyCount) - same bug already found and fixed
        -- elsewhere. JP/KR still unverified, no symbol data available.
        if region == 0x4A then enemy_species_addr = 0xd9e8 + 0x22
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

    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = memory.readbyte(party_base_addr)
    eggSlotIndex = partysizeBeforeReceiving
    eggDvAddr = party_base_addr + 0x1D + eggSlotIndex * 0x30
    eggSpeciesListAddr = party_base_addr + 1 + eggSlotIndex
    state = "waiting_for_egg"
    safe_pair = nil
    homeX, homeY = nil, nil
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
-- while still waiting for the egg (nothing mid-flight), same safety
-- requirement as static.lua's version.
local function reroll_savestate_pool()
    rerollWindow = rerollWindow + 1
    print(string.format(
        "Re-rolling savestate pool after %d minutes (entering window %d) - injecting fresh entropy and re-baselining to avoid getting permanently stuck if this pool excludes the shiny states.",
        math.floor(REROLL_INTERVAL_SECONDS / 60), rerollWindow))
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

    if state == "waiting_for_egg" then
        local currentPartySize = memory.readbyte(party_base_addr)

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

        if stillWaitingForEgg then
            -- Only safe to re-roll right here: still waiting for the egg,
            -- nothing mid-flight (received-but-not-settled, DV read
            -- pending, etc).
            if lastRerollTime and os.time() - lastRerollTime >= REROLL_INTERVAL_SECONDS then
                reroll_savestate_pool()
            end

            -- Still working through the NPC's dialogue - keep mashing A.
            if mashSplitsFired < MASH_SPLITS_TARGET then
                RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
                mashSplitsFired = mashSplitsFired + 1
            end
            for i = 1, 4 do emu.frameadvance() end
            press_button("A")
            return false
        end

        -- Egg received - split point right at the moment of receiving.
        if splitAfterReceivedPending then
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            splitAfterReceivedPending = false
        end

        -- Short wait only - not mashing through extended dialogue.
        for i = 1, 10 do emu.frameadvance() end

        -- Final split point, right after the settle wait, just before
        -- actually reading DVs.
        if splitAfterSettlePending then
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            splitAfterSettlePending = false
        end

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
            atkdef = memory.readbyte(eggDvAddr)
            spespc = memory.readbyte(eggDvAddr + 1)
            do
                local stableFrames = 0
                local waited = 0
                while stableFrames < 2 and waited < 30 do
                    emu.frameadvance()
                    waited = waited + 1
                    local curAtkdef = memory.readbyte(eggDvAddr)
                    local curSpespc = memory.readbyte(eggDvAddr + 1)
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
            species = memory.readbyte(eggSpeciesListAddr) -- still 0xFD at this point, expected
            isShiny = shiny(atkdef, spespc)
        else
            -- Togepi path - deliberately UNTOUCHED, byte-for-byte the
            -- original code from before any Odd Egg debugging began. Do
            -- not "improve" this without a specific, confirmed Togepi bug
            -- report - it's already confirmed working.
            atkdef = memory.readbyte(eggDvAddr)
            spespc = memory.readbyte(eggDvAddr + 1)
            species = memory.readbyte(eggSpeciesListAddr) -- still 0xFD at this point, expected
            isShiny = shiny(atkdef, spespc)
        end

        local atkv = math.floor(atkdef / 16)
        local defv = atkdef % 16
        local spdv = math.floor(spespc / 16)
        local spcv = spespc % 16

        resetCount = resetCount + 1

        if eggSource == "Odd Egg" then
            -- Diagnostic fields on top of the normal line while chasing a
            -- confirmed bogus-shiny report - species is supposed to be a
            -- rock-solid EGG_PLACEHOLDER ($FD) at this point every single
            -- time; if it ever reads anything else, we're not looking at
            -- a real, freshly-written party slot at all, which would
            -- point at a wrong address/timing bug well upstream of the
            -- settle-frame check above rather than a race within it.
            print(string.format("#%d | win:%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s | species=$%02X(expect $FD) partySize=%d(was %d) slot=%d dvAddr=$%04X",
                resetCount, rerollWindow, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or "",
                species, currentPartySize, partysizeBeforeReceiving, eggSlotIndex, eggDvAddr))
        else
            -- Original Togepi print line, unchanged.
            print(string.format("#%d | win:%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s",
                resetCount, rerollWindow, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or ""))
        end
        Stats.record_encounter()
        Gui.update_last_encounter(hud, resetCount, species, "Egg", atkv, defv, spdv, spcv, isShiny, nil)

        if isShiny then
            print(string.format("SHINY egg found! Atk:%d Def:%d Spe:%d Spc:%d - stopping here, walk it out to hatch yourself", atkv, defv, spdv, spcv))
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
                nil
            )
            return true
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            savestate.loadslot(SAVESTATE_SLOT)
            lastResetTime = os.time()
            consecutiveStuckReloads = 0
            -- REMOVED: "True Randomness" mode used to use the full
            -- 65536+ frame range for this delay instead, gated behind
            -- the shared checkbox. Superseded by reroll_savestate_pool()
            -- above, which does the same full-coverage injection but
            -- only once per REROLL_INTERVAL_SECONDS instead of every
            -- single reset - see rng_mechanics.md for the Monte Carlo
            -- comparison that motivated this same change in static.lua.
            -- Gui.true_randomness_enabled() is deliberately not read
            -- here anymore.
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            mashSplitsFired = 0
            splitAfterReceivedPending = true
            splitAfterSettlePending = true
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

        local currentSpeciesListValue = memory.readbyte(eggSpeciesListAddr)
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

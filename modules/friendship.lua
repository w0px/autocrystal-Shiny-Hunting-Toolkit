-- friendship.lua
-- Walks the character back and forth continuously to raise friendship
-- (walking increases happiness for every party member simultaneously in
-- Gen 2, not just one). Tracks and displays all party members' current
-- friendship live, with slot 1 specifically treated as the evolution
-- target - stops once slot 1 reaches the 220 threshold. Flees any wild
-- encounter that interrupts walking, same as egg.lua's walk-to-hatch
-- phase.
--
-- Verified via pokecrystal.sym: wPartyMon1Happiness ($DCFA) and
-- wPartyMon2Happiness ($DD2A) confirm the per-slot happiness formula
-- used below covers every party member, not just the first.
-- Evolution threshold confirmed at 220 (multiple independent sources) -
-- happiness-based evolutions (Golbat->Crobat, Chansey->Blissey, Eevee->
-- Espeon/Umbreon, Pichu/Cleffa/Igglybuff/Togepi's baby evolutions)
-- trigger on the NEXT level up once happiness reaches this value -
-- reaching 220 alone doesn't evolve it immediately.
--
-- Discord notification fires only once, when the TARGET (slot 1)
-- reaches the threshold - not on every individual increase across the
-- party (which would be far too frequent given how often walking ticks
-- happiness up).

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Gui = require("gui_module")
Stats = require("data.stats")
PokemonNames = require("data.pokemon_names")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua - see data/location_names.lua for
-- where this comes from (the actual pret/pokecrystal disassembly, not
-- a guess). Friendship-walking can happen anywhere you choose to stand,
-- so this feeds the Rich Presence location the same as those modules.
local LocationNames = require("data.location_names")

local function location_name(group, number)
    return LocationNames[string.format("%d:%d", group, number)]
        or string.format("Map Group %d, #%d", group, number)
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

local COLOR_GOLD = 16766720
local COLOR_RED = 15158332

-- Even leaner colored embed for bot-status alerts (stuck detection) that
-- aren't about a specific encounter.
local function send_alert(title, color)
    send_discord_embed(title, nil, nil, color, nil)
end

-- Stuck detection: tracks real-world time since the bot last made
-- genuine progress (a successful nudge cycle, or fleeing an
-- interrupting wild encounter) - NOT raw position, since a successful
-- nudge cycle deliberately returns to the exact same "home" tile every
-- time by design, which would make raw position look "unchanged"
-- constantly even when everything is working perfectly.
--
-- Two-tier response, matching wild.lua exactly: once STUCK_RECOVERY_SECONDS
-- passes with no progress, print to console and try the automatic A/B
-- recovery - quietly, on a repeating cadence, with NO Discord
-- notification yet, since a first stall is often nothing (a slow
-- animation, a menu, etc) and resolves itself or via the first recovery
-- attempt. Only once the bot is STILL stuck after the much longer
-- STUCK_DISCORD_SECONDS - i.e. it's genuinely likely stuck and recovery
-- isn't working - does a single Discord alert fire. Either timer resets
-- the moment real progress happens again.
local STUCK_RECOVERY_SECONDS = 30
local STUCK_DISCORD_SECONDS = 120
local lastProgressTime = nil
local nextStuckRecoveryTime = nil
local stuckDiscordSent = false

local function mark_progress()
    lastProgressTime = os.time()
    nextStuckRecoveryTime = nil
    stuckDiscordSent = false
end

local function attempt_unstuck_recovery()
    print("Attempting automatic recovery - alternating A/B presses for a few seconds...")
    for cycle = 1, 50 do
        for i = 1, 20 do
            joypad.set({A = true})
            emu.frameadvance()
        end
        for i = 1, 10 do
            joypad.set({B = true})
            emu.frameadvance()
        end
    end
    joypad.set({})
end

local function check_stuck_and_notify()
    if lastProgressTime == nil then
        lastProgressTime = os.time()
        return
    end
    local stuckFor = os.time() - lastProgressTime
    if stuckFor < STUCK_RECOVERY_SECONDS then
        return
    end

    if nextStuckRecoveryTime == nil or os.time() >= nextStuckRecoveryTime then
        print(string.format("WARNING: no progress for %d+ seconds - potentially stuck, attempting automatic recovery", stuckFor))
        attempt_unstuck_recovery()
        -- Recovery attempts consume real time themselves, so re-derive
        -- how long we've actually been stuck rather than using the
        -- pre-recovery snapshot.
        stuckFor = os.time() - lastProgressTime
        nextStuckRecoveryTime = os.time() + STUCK_RECOVERY_SECONDS
    end

    if not stuckDiscordSent and stuckFor >= STUCK_DISCORD_SECONDS then
        stuckDiscordSent = true
        print(string.format("Still stuck after %d+ seconds despite automatic recovery attempts - notifying Discord", STUCK_DISCORD_SECONDS))
        send_alert(string.format(
            "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck: no walking progress for over %d seconds, even after automatic recovery attempts. Check on it.",
            STUCK_DISCORD_SECONDS), COLOR_RED)
    end
end

-- Corrupted friendship readings (e.g. from a phone call) no longer fire
-- their own immediate Discord alert - they just trigger the same
-- automatic recovery attempt (console-only) and otherwise fold into the
-- SAME two-tier mechanism above: since corruption isn't real walking
-- progress, lastProgressTime doesn't get refreshed for it, so if it
-- keeps happening (recovery isn't working) the shared stuck-Discord
-- escalation above still fires on its own once genuinely stuck long
-- enough. Guarded so it only attempts recovery once per detection
-- streak, not every single frame corruption is seen.
local corruptionRecoveryAttempted = false

local EVOLUTION_THRESHOLD = 220
-- Verified via pokecrystal.sym: wPartyMon1Happiness ($DCFA) and
-- wPartyMon2Happiness ($DD2A) are both exactly 0x23 bytes past their
-- respective party_base_addr + slot*0x30 offset, confirming this
-- formula covers every slot, not just the first.
local HAPPINESS_OFFSET = 0x23
local PARTY_MON_SIZE = 0x30

local enemy_species_addr
local party_base_addr
local lastFriendshipBySlot = {} -- slotIndex (0-based) -> last known value
local targetPokemonName = "?" -- slot 1 specifically, the evolution target

local function happiness_addr(slotIndex)
    return party_base_addr + HAPPINESS_OFFSET + slotIndex * PARTY_MON_SIZE
end

local function species_addr(slotIndex)
    return party_base_addr + 1 + slotIndex
end

-- If party count ever reads as garbage (e.g. during a phone call, when
-- this memory region might be temporarily disrupted), looping over
-- hundreds of invalid slots would compute addresses that overflow
-- past the valid GB address space entirely, causing a permanent hang.
-- Clamp to the real valid range (1-6) rather than trusting it blindly.
local function get_safe_party_count()
    local raw = memory.readbyte(party_base_addr)
    if raw < 1 then return 1 end
    if raw > 6 then return 6 end
    return raw
end

local lastFriendship -- slot 1 specifically, the evolution target
local thresholdNotified = false
local stepsTaken = 0
local sessionIncreaseCount = 0

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance()
end

-- ===== Movement (verbatim from egg.lua/wild.lua's proven drift-proof
-- system) =====
local MOVEMENT_FLAG_ADDR
local PLAYER_X_ADDR, PLAYER_Y_ADDR
local MOVEMENT_IDLE_VALUE = 0xFF

local function attempt_step(direction)
    local startX, startY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)

    for i = 1, 4 do
        joypad.set({[direction] = true})
        emu.frameadvance()
    end
    joypad.set({[direction] = false})

    local n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) == MOVEMENT_IDLE_VALUE and n < 20 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) ~= MOVEMENT_IDLE_VALUE and n < 90 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    -- A single step should only ever move by 1 tile. A larger jump
    -- indicates this memory region got corrupted/repurposed for
    -- something else (same class of corruption seen in the happiness
    -- bytes during a phone call) rather than genuine movement - don't
    -- trust it as success, since that would incorrectly reset the
    -- stuck-timer while nothing real actually happened.
    local dx, dy = math.abs(endX - startX), math.abs(endY - startY)
    if dx > 1 or dy > 1 then
        return false
    end
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

        -- If the character wasn't already facing this direction, the
        -- first press just turns them (no actual step) - a second
        -- press of the same direction, now that they're facing it,
        -- should actually walk. Confirmed via testing: a manual press
        -- unstuck the bot exactly this way.
        if not movedOut then
            movedOut = attempt_step(pair.out)
            if memory.readbyte(enemy_species_addr) ~= 0 then return nil end
        end

        if movedOut then
            local movedBack = attempt_step(pair.back)
            if memory.readbyte(enemy_species_addr) ~= 0 then return nil end

            if not movedBack then
                movedBack = attempt_step(pair.back)
                if memory.readbyte(enemy_species_addr) ~= 0 then return nil end
            end

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
        if not movedOut then
            -- Same turn-then-walk retry as find_safe_pair - if
            -- something turned the character to face a different
            -- direction since the last cycle, this first press just
            -- turns again rather than actually stepping.
            movedOut = attempt_step(safe_pair.out)
            if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        if not movedBack then
            movedBack = attempt_step(safe_pair.back)
            if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        end

        local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        local trulyReturned = (endX == startX and endY == startY)
        madeRealProgress = movedOut and movedBack and trulyReturned

        -- Reset the pair any time it stops actually working - whether
        -- it drifted somewhere unexpected, OR (the bug this comment
        -- fixes) it just turned in place without moving at all. Without
        -- this second case, a pair that stops working (e.g. an
        -- interruption reset the facing direction) gets retried forever
        -- with the bot spinning in place, never re-validating via
        -- find_safe_pair() again.
        if not madeRealProgress then
            safe_pair = nil
        end
    end

    return madeRealProgress
end

local function friendship_labels(value)
    return string.format("Target: %s - Friendship: %d", targetPokemonName, value),
        string.format("Threshold: %d", EVOLUTION_THRESHOLD),
        string.format("Still needed: %d", math.max(0, EVOLUTION_THRESHOLD - value)),
        (value >= EVOLUTION_THRESHOLD) and "READY - level up to evolve" or "-"
end

-- Walking raises happiness for every party member simultaneously, not
-- just slot 1 - the snapshot shows all of them live, since only
-- tracking the evolution target alone would hide that the rest of the
-- party is progressing too. Recent timestamped increases are appended
-- below the snapshot in the same 8-line display, so both are visible
-- at once rather than choosing one or the other.
local recentIncreaseLog = {}

local function build_party_display()
    local partyCount = get_safe_party_count()
    local lines = {}
    for slotIndex = 0, partyCount - 1 do
        local name = get_pokemon_name(memory.readbyte(species_addr(slotIndex)))
        local value = memory.readbyte(happiness_addr(slotIndex))
        local marker = (slotIndex == 0) and " [TARGET]" or ""
        local readyFlag = (value >= EVOLUTION_THRESHOLD) and "  READY!" or ""
        lines[#lines + 1] = string.format("%-10s %3d/%d%s%s", name, value, EVOLUTION_THRESHOLD, marker, readyFlag)
    end

    if #recentIncreaseLog > 0 then
        lines[#lines + 1] = "---- Recent increases ----"
        for i = 1, #recentIncreaseLog do
            if #lines >= 8 then break end
            lines[#lines + 1] = recentIncreaseLog[i]
        end
    end

    return lines
end

-- ===== M.init: runs once =====
-- Nothing here relates to species/DVs/items/kill-mode/RNG splitting,
-- since there's no resetting involved at all - just continuous walking.
-- Stop-on-shiny, every Auto-Catch field, and crit-safety override are
-- also greyed out here - this module never reads any of those Gui
-- getters (no shiny to catch/weaken mid-walk), so they'd otherwise look
-- like live controls that silently do nothing. True Randomness stays
-- enabled per-module-batch convention with Starters/Static/Egg even
-- though friendship.lua doesn't currently read it either (no soft-reset
-- here) - flagged as a no-op rather than silently left disabled.
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
    "chkStopPerfect", "chkStopNegative",
    "chkDontWeaken",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall - safe to
    -- ignore failure if it was already set successfully earlier in
    -- this same BizHawk session.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    -- Confirmed via direct symbol lookup: wPlayerWalking lives at a
    -- different address in Gold/Silver ($D204) than Crystal ($D4DD).
    -- Same for wXCoord/wYCoord: Crystal $DCB8/$DCB7, Gold/Silver
    -- $DA03/$DA02 - completely different, and previously hardcoded
    -- throughout this file's movement logic, which explains why
    -- friendship's walking never worked on Gold even after the
    -- movement-flag fix alone.
    if version == 0x55 or version == 0x58 then
        MOVEMENT_FLAG_ADDR = 0xD204
        PLAYER_X_ADDR = 0xDA03
        PLAYER_Y_ADDR = 0xDA02
    else
        MOVEMENT_FLAG_ADDR = 0xD4DD
        PLAYER_X_ADDR = 0xDCB8
        PLAYER_Y_ADDR = 0xDCB7
    end

    if version == 0x54 then
        if region == 0x4A then
            enemy_species_addr = 0xd23d + 0x22
            party_base_addr = 0xDC9D
        else
            enemy_species_addr = 0xd20c + 0x22
            party_base_addr = 0xDCD7
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then
            -- STILL UNVERIFIED - same enemy_addr=party_base_addr bug
            -- pattern, no JP-specific symbol data available.
            enemy_species_addr = 0xd9e8 + 0x22
            party_base_addr = 0xD9E8
        elseif region == 0x4B then
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_species_addr = 0xdb1f + 0x22
            party_base_addr = 0xDB1F
        else
            -- Verified against pokegold.sym: enemy_species_addr should
            -- be based on wEnemyMonDVs ($D0F5), NOT $DA22 (which is
            -- actually wPartyCount) - the same bug already found and
            -- fixed in wild.lua/fishing.lua/headbutt.lua/static.lua,
            -- but missed here since friendship.lua has its own third
            -- separate copy of this setup.
            enemy_species_addr = 0xd0f5 + 0x22
            party_base_addr = 0xDA22
        end
    else
        print("No valid ROM detected")
        return false
    end

    targetPokemonName = get_pokemon_name(memory.readbyte(species_addr(0)))

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.set_history_header(hud, "PROGRESS:")

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionIncreaseCount,
        "Ready - stand somewhere safe to walk back and forth, then click Start...")
    return true
end

function M.on_switch_to()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.set_history_header(hud, "PROGRESS:")
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. No savestate needed - this just
-- starts walking from wherever the character currently is.
function M.on_resume()
    safe_pair = nil
    homeX, homeY = nil, nil
    stepsTaken = 0
    sessionIncreaseCount = 0
    thresholdNotified = false
    recentIncreaseLog = {}
    lastProgressTime = nil
    nextStuckRecoveryTime = nil
    stuckDiscordSent = false
    corruptionRecoveryAttempted = false
    targetPokemonName = get_pokemon_name(memory.readbyte(species_addr(0)))

    lastFriendshipBySlot = {}
    local partyCount = get_safe_party_count()
    for slotIndex = 0, partyCount - 1 do
        lastFriendshipBySlot[slotIndex] = memory.readbyte(happiness_addr(slotIndex))
    end
    lastFriendship = lastFriendshipBySlot[0]

    print(string.format("[%s] Starting - tracking %d party member(s), target: %s at %d",
        os.date("%H:%M:%S"), partyCount, targetPokemonName, lastFriendship))
    local l1, l2, l3, l4 = friendship_labels(lastFriendship)
    Gui.set_full_history(hud, build_party_display())
    Gui.set_labels(hud, l1, l2, l3, l4)
end

-- ===== M.step: one call per frame =====
function M.step()
    check_stuck_and_notify()

    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick. Only
    -- updates when the (group, number) pair is a RECOGNIZED location -
    -- an unrecognized pair almost always means these two WRAM bytes got
    -- transiently repurposed for something else (e.g. a battle
    -- interrupting the walk), not an actual new location. See
    -- wild.lua's M.step() for the original fix this mirrors.
    do
        local mapKey = string.format("%d:%d", memory.readbyte(0xdcb5), memory.readbyte(0xdcb6))
        if LocationNames[mapKey] then
            AutocrystalCurrentLocation = LocationNames[mapKey]
        end
    end

    if memory.readbyte(enemy_species_addr) ~= 0 then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionIncreaseCount,
            string.format("Wild encounter interrupted - fleeing (steps so far: %d)...", stepsTaken))
        -- BOUNDED: this used to have no timeout at all - if something
        -- like a phone call interrupted here, this ran forever, and
        -- M.step() could never return for check_stuck_and_notify() to
        -- get another chance to fire. Break out and let the outer
        -- stuck-detection (which does a proper alternating A/B
        -- recovery, better suited to a phone call than B-only mashing)
        -- handle it if this keeps happening.
        local fleeWaitFrames = 0
        while memory.readbyte(enemy_species_addr) ~= 0 and fleeWaitFrames < 300 do
            emu.frameadvance()
            press_button("B")
            fleeWaitFrames = fleeWaitFrames + 1
        end
        -- Only mark progress if the flee actually succeeded - merely
        -- entering this branch isn't progress, and marking it
        -- unconditionally would let a genuinely stuck encounter keep
        -- resetting its own stuck-timer forever.
        if memory.readbyte(enemy_species_addr) == 0 then
            mark_progress()
        end
        safe_pair = nil
        return false
    end

    local madeProgress = do_nudge_cycle()
    if madeProgress then
        stepsTaken = stepsTaken + 1
        mark_progress()
    end

    local partyCount = get_safe_party_count()
    local anyChanged = false
    local corruptionDetected = false
    for slotIndex = 0, partyCount - 1 do
        local current = memory.readbyte(happiness_addr(slotIndex))
        local previous = lastFriendshipBySlot[slotIndex]
        if previous ~= nil and current ~= previous then
            local delta = current - previous
            if math.abs(delta) > 20 then
                -- Implausible jump - real friendship gains per step are
                -- small (1-3). This is direct evidence of memory
                -- corruption (phone call, etc.), not a real change -
                -- don't log it, and don't let it poison the stored
                -- value for future comparisons.
                corruptionDetected = true
            else
                anyChanged = true
                if delta > 0 then
                    if slotIndex == 0 then sessionIncreaseCount = sessionIncreaseCount + 1 end
                    local name = get_pokemon_name(memory.readbyte(species_addr(slotIndex)))
                    local logLine = string.format("[%s] %s: %d->%d (+%d)%s",
                        os.date("%H:%M:%S"), name, previous, current, delta,
                        (slotIndex == 0) and " [T]" or "")
                    print(logLine)
                    table.insert(recentIncreaseLog, 1, logLine)
                    if #recentIncreaseLog > 8 then table.remove(recentIncreaseLog) end
                end
                lastFriendshipBySlot[slotIndex] = current
            end
        end
    end
    lastFriendship = lastFriendshipBySlot[0]

    if corruptionDetected then
        if not corruptionRecoveryAttempted then
            corruptionRecoveryAttempted = true
            print("WARNING: implausible friendship jump detected - likely memory corruption from a phone call or similar interruption. Attempting immediate recovery.")
            attempt_unstuck_recovery()
        end
        -- Deliberately NOT calling mark_progress() here - corruption
        -- isn't real progress, so the shared stuck timer above keeps
        -- counting if this keeps happening, letting IT decide when a
        -- Discord alert is actually warranted.
    else
        corruptionRecoveryAttempted = false
    end

    if anyChanged then
        Gui.set_full_history(hud, build_party_display())
        local l1, l2, l3, l4 = friendship_labels(lastFriendship)
        Gui.set_labels(hud, l1, l2, l3, l4)
    end

    if lastFriendship >= EVOLUTION_THRESHOLD then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionIncreaseCount,
            string.format("Friendship threshold reached (%d)! Level up to evolve.", lastFriendship))
        if not thresholdNotified then
            thresholdNotified = true
            local curMapGroup, curMapNumber = memory.readbyte(0xdcb5), memory.readbyte(0xdcb6)
            send_discord_embed(
                string.format("\xF0\x9F\x8E\x89 Friendship Threshold Reached! %s", targetPokemonName),
                "Level up (battle or Rare Candy) to trigger the evolution.",
                {
                    {name = "Current Friendship", value = tostring(lastFriendship), inline = true},
                    {name = "Threshold", value = tostring(EVOLUTION_THRESHOLD), inline = true},
                    {name = "Steps Taken", value = tostring(stepsTaken), inline = true},
                    {name = "Location", value = location_name(curMapGroup, curMapNumber), inline = true},
                },
                COLOR_GOLD,
                nil
            )
        end
        return true
    end

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionIncreaseCount,
        string.format("Walking (friendship: %d, steps: %d)...", lastFriendship, stepsTaken))
    return false
end

return M

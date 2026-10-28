local M = {}

-- ===== Setup (runs once when this module is required by the launcher) =====

local script_path = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
local script_dir = script_path:match("(.*[/\\])") or "./"
-- wild.lua lives in modules/, and data/ is a SIBLING of modules/ (both
-- directly under the base folder) - "../?.lua" reaches up one level so
-- require("data.X") resolves correctly.
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")
LevelUpMoves = require("data.level_up_moves")

local hud -- assigned in M.init()

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function get_item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

-- Routine, high-frequency trace prints go through this instead of print()
-- directly, so they can be silenced by default (they add real overhead
-- at high fast-forward speeds) and re-enabled via the GUI's "Verbose
-- Logging" checkbox when actually debugging something.
local function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

-- Checks a list of raw typed tokens (each could be a number like "69" or
-- a name like "Bellsprout") against the current species, matching on
-- either its numeric ID or its name (case-insensitive). nil tokens list
-- means no filter was set, so everything is allowed.
local function species_matches_filter(tokens, id, name)
    if tokens == nil then return true end
    local nameLower = name:lower()
    for _, token in ipairs(tokens) do
        local asNumber = tonumber(token)
        if asNumber ~= nil and asNumber == id then
            return true
        end
        if token:lower() == nameLower then
            return true
        end
    end
    return false
end

-- Sends a notification via a local relay (discord_relay.ps1 + start_relay.bat)
-- which forwards it to Discord. CONFIRMED via webhook.site testing that
-- comm.httpPost always wraps its payload as a URL-encoded form field named
-- "payload" (application/x-www-form-urlencoded) - this is fixed BizHawk
-- behavior on every version, not a bug, and Discord's webhook endpoint
-- will never accept that shape directly. The relay always runs on this
-- fixed local address, so it's a constant rather than a GUI field.
local DISCORD_RELAY_URL = "http://127.0.0.1:5000/"

local function send_discord_notification(message)
    if not Gui.discord_enabled(hud) then return end
    local safeMessage = message:gsub('"', '\\"')
    local payload = string.format('{"content": "%s"}', safeMessage)
    local ok, response = pcall(comm.httpPost, DISCORD_RELAY_URL, payload)
    if ok then
        print("Discord notification sent, response: " .. tostring(response))
    else
        print("Discord notification failed: " .. tostring(response))
    end
end

-- Stuck detection: tracks real-world time since the bot last made
-- genuine progress (a successful nudge cycle, or being actively engaged
-- in a battle) - NOT raw position, since a successful nudge cycle
-- deliberately returns to the exact same "home" tile every time by
-- design, which would make raw position look "unchanged" constantly
-- even when everything is working perfectly. If it's been
-- STUCK_THRESHOLD_SECONDS since the last progress signal, sends a
-- single Discord alert (not repeated every frame) until progress
-- happens again, at which point it resets and can fire again later.
local STUCK_THRESHOLD_SECONDS = 90
local lastProgressTime = nil
local stuckNotificationSent = false

local function mark_progress()
    lastProgressTime = os.time()
    stuckNotificationSent = false
end

local function attempt_unstuck_recovery()
    print("Attempting automatic recovery - alternating A/B presses for a few seconds...")
    for cycle = 1, 20 do
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
    if not stuckNotificationSent and os.time() - lastProgressTime >= STUCK_THRESHOLD_SECONDS then
        stuckNotificationSent = true
        print(string.format("WARNING: no progress for %d+ seconds - potentially stuck, attempting automatic recovery", STUCK_THRESHOLD_SECONDS))
        attempt_unstuck_recovery()
        send_discord_notification(string.format(
            "Potentially stuck: no movement or battle progress for over %d seconds. Attempted automatic recovery (A/B presses) - check on it if this keeps happening.",
            STUCK_THRESHOLD_SECONDS))
        -- Give the recovery attempt a fresh window before considering
        -- it stuck again, rather than immediately re-triggering.
        lastProgressTime = os.time()
    end
end

-- ===== Persistent state (shared between M.init and M.step via closure) =====

local desired_species = -1
local atkdef
local spespc
local species
local item = 0
local shinyvalue = 0
-- Set true once per new battle (in the hook that only fires on a genuine
-- new encounter, not per turn). PP reads as stale for a couple of frames
-- right when a battle menu first loads - this ensures we only wait for
-- it to settle ONCE, on the actual first turn, not on every turn of an
-- ongoing multi-turn battle (where PP is already accurate from the start).
local pendingBattleSettle = false
local stopRequested = false
local stopReason = ""
-- Set true only by the ROM hook (a real, one-time confirmation that an
-- actual encounter started) - used so the DV-wait loop doesn't bail out
-- on a transient species_addr==0 blip during a real encounter's own
-- startup transition, while still catching genuinely spurious flickers
-- where no real battle ever started at all.
local realEncounterConfirmed = false
local pendingEncounterUpdate = false
local printedMessage = false
local enemy_addr
local LoadBattleMenuAddr
local EnemyWildmonInitialized
local LearnMoveAddr
local learnMovePromptDetected = false
local party_base_addr
local curPartyMonAddr

local mapgroup, mapnumber
local version, region
-- Deliberately NOT persisted - resets to 0 every launch, so it's always
-- unambiguous "encounters this session" vs the shared lifetime totals.
local sessionEncounterCount = 0

Stats = require("data.stats")

local highestSpeSpc = 0
local highestAtkDef = 0

-- $CFA9 (Y) / $CFAA (X) confirmed via multi-frame stability testing: both
-- read with ZERO flicker across 6 consecutive frames at every one of the
-- four menu positions, and the layout is 1-indexed (not 0-indexed):
--   FIGHT=(1,1)  PKMN=(1,2)
--   PACK =(2,1)  RUN =(2,2)
local MENU_CURSOR_Y, MENU_CURSOR_X
local wCurItemAddr, wItemsAddr, wNumItemsAddr
-- Preference order when scanning the bag for something to throw -
-- Poke Ball specifically preferred (per direct instruction), falling
-- back to other ball types only if no Poke Balls are left.
local BALL_ITEM_IDS = {5, 4, 2, 1} -- Poke, Great, Ultra, Master
local RUN_CURSOR = {y = 2, x = 2}

-- $C634: confirmed via WRAM diffing (before/after using the first move)
-- to be the in-battle PP counter for the first move slot. Lives in the
-- fixed WRAM bank ($C000-$CFFF), so no bank-switching concerns reading it.
local FIRST_MOVE_PP_ADDR
-- Verified via pokecrystal.sym/pokegold.sym symbol files: wBattleMonHP/
-- wBattleMonMaxHP, same fixed (non-bank-switched) region as
-- FIRST_MOVE_PP_ADDR above.
local OWN_HP_ADDR
local OWN_MAX_HP_ADDR
-- Flee instead of attacking if HP drops below this fraction of max -
-- a safety margin above the game's own "red bar" threshold, so there's
-- room to actually flee before a possible next hit could faint us.
local LOW_HP_FLEE_THRESHOLD = 0.25

local dv_flag_addr, species_addr, item_addr, enemy_hp_addr, enemy_max_hp_addr

local function shiny(atkdef, spespc)
    -- IMPORTANT: reset every call, not just set on a hit - otherwise
    -- shinyvalue stays 1 forever after the first real shiny, silently
    -- flagging every subsequent encounter as shiny too.
    shinyvalue = 0
    if spespc == 0xAA then
        if atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA then
            shinyvalue = 1
            return true
        end
    end
    return false
end

-- Own Pokemon's HP can exceed 255 at higher levels, so this is a 16-bit
-- read, not a single byte like the PP check.
local function has_safe_hp()
    local currentHP = memory.read_u16_be(OWN_HP_ADDR)
    local maxHP = memory.read_u16_be(OWN_MAX_HP_ADDR)
    if maxHP == 0 then return true end -- avoid divide-by-zero if read too early
    return (currentHP / maxHP) > LOW_HP_FLEE_THRESHOLD
end

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do -- Hold button for 4 frames (make sure the game registers it)
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance() -- Add one frame buffer so consecutive button presses don't blend together
end

-- $D4DD: confirmed via multi-frame WRAM diffing + a 5-step verification
-- test to be a real "movement in progress" flag. Idle value 0xFF; goes
-- busy the instant a step starts (observed 0-frame delay across every
-- test), returns to 0xFF right as the tile-step completes (~11-12 frames
-- later on flat ground). This replaces position-polling entirely - no
-- more guessing how many frames to wait.
local MOVEMENT_FLAG_ADDR
local PLAYER_X_ADDR, PLAYER_Y_ADDR
local MOVEMENT_IDLE_VALUE = 0xFF

-- Press `direction`, then use the flag to know exactly when the step
-- (if any) starts and finishes, rather than guessing frame counts.
-- Returns true only if the tile position actually changed - the flag
-- tells us WHEN to check, the position change tells us WHETHER it
-- counted as a real step (vs. a blocked bump against a wall/tree).
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
        if memory.readbyte(species_addr) ~= 0 then return true end
    end

    n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) ~= MOVEMENT_IDLE_VALUE and n < 90 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(species_addr) ~= 0 then return true end
    end

    local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    return (endX ~= startX or endY ~= startY)
end

-- Only ever commits to a direction pair verified to be a true round trip
-- (step out, step back, land on the EXACT same tile) - guarantees zero
-- net drift WITHIN a single established pair's use. On its own this does
-- NOT stop the anchor itself from slowly relocating: whenever a pair
-- needs re-verifying (e.g., after a battle, or after a cycle fails the
-- round-trip check), find_safe_pair() used to just treat wherever the
-- character currently is as the new reference point - small shifts from
-- each re-verification compound over many encounters into real drift.
-- homeX/homeY fixes this: it's the one true anchor, set once per Start,
-- and do_nudge_cycle actively walks back to it before ever re-verifying
-- a pair, rather than settling for "wherever we happen to be now".
local safe_pair = nil
local homeX, homeY = nil, nil

-- Attempts one step closer to home. Returns true once actually there.
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

    if memory.readbyte(species_addr) ~= 0 then return false end
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
        if memory.readbyte(species_addr) ~= 0 then return nil end

        if movedOut then
            local movedBack = attempt_step(pair.back)
            if memory.readbyte(species_addr) ~= 0 then return nil end

            local nowX, nowY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
            if movedBack and nowX == anchorX and nowY == anchorY then
                vprint(string.format("Found safe zero-drift pair: %s / %s", pair.out, pair.back))
                return pair
            else
                if verbose then
                    print(string.format("%s/%s didn't return to anchor (now X=%d Y=%d, anchor was X=%d Y=%d) - trying next pair",
                        pair.out, pair.back, nowX, nowY, anchorX, anchorY))
                end
                anchorX, anchorY = nowX, nowY
            end
        else
            if verbose then
                print(string.format("%s blocked from this tile - skipping this pair", pair.out))
            end
        end
    end

    return nil
end

local cycles_since_print = 0
local failed_pair_attempts = 0
local consecutive_movement_failures = 0
local UNSTUCK_THRESHOLD = 100

-- If a phone call, sign, or any other unexpected text box pops up in the
-- overworld, our button presses stop producing real movement even though
-- the terrain itself is fine - this looks identical to any other stretch
-- of failed attempts from here, so rather than detecting each possible
-- interruption individually, we just notice "no real movement for a
-- long time despite believing we're free to move" and try to clear
-- whatever's blocking us generically.
local function try_unstuck()
    print(string.format("No real movement for %d cycles - possibly a phone call/sign/text box blocking input. Trying to clear it.", consecutive_movement_failures))
    -- B, never A: some phone calls (rematch challenges) end in a
    -- "battle now? Yes/No" prompt, and mashing A could accidentally
    -- CONFIRM a trainer battle - something this bot has zero ability to
    -- handle (completely different menus/addresses than wild encounters).
    -- B is the safe cancel/decline button used everywhere else in this
    -- script for exactly this reason.
    for i = 1, 40 do
        press_button("B")
        if memory.readbyte(species_addr) ~= 0 then break end
    end
    safe_pair = nil -- re-verify from scratch, position/context may have shifted
    consecutive_movement_failures = 0
end

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
            if memory.readbyte(species_addr) ~= 0 then return end
            madeRealProgress = true -- getting closer to home is real progress, not a stall
            if not reachedHome then
                return
            end
        end

        -- This can fail repeatedly right before a wild encounter actually
        -- triggers (the game appears to briefly lock out new movement
        -- input during that transition) - print full detail occasionally
        -- rather than on every single cycle to avoid spamming the console.
        local verbose = Gui.verbose_logging(hud) and (failed_pair_attempts % 20 == 0)
        safe_pair = find_safe_pair(verbose)
        if safe_pair == nil and memory.readbyte(species_addr) == 0 then
            failed_pair_attempts = failed_pair_attempts + 1
            if verbose then
                print("No safe zero-drift pair found yet - will retry next cycle")
            end
        else
            madeRealProgress = (safe_pair ~= nil)
        end
    else
        local startX, startY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(species_addr) ~= 0 then return end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(species_addr) ~= 0 then return end

        local endX, endY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        local trulyReturned = (endX == startX and endY == startY)
        madeRealProgress = movedOut and movedBack and trulyReturned

        if movedOut and movedBack and not trulyReturned then
            print(string.format(
                "WARNING: established pair (%s/%s) didn't return to start (was X=%d Y=%d, now X=%d Y=%d) - re-verifying a fresh pair",
                safe_pair.out, safe_pair.back, startX, startY, endX, endY))
            safe_pair = nil
        end

        cycles_since_print = cycles_since_print + 1
        if cycles_since_print >= 20 then
            cycles_since_print = 0
            local x, y = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
            vprint(string.format("Still nudging (%s/%s) at X=%d Y=%d", safe_pair and safe_pair.out or "?", safe_pair and safe_pair.back or "?", x, y))
        end
    end

    if madeRealProgress then
        consecutive_movement_failures = 0
    else
        consecutive_movement_failures = consecutive_movement_failures + 1
        if consecutive_movement_failures >= UNSTUCK_THRESHOLD then
            try_unstuck()
        end
    end
end

-- Compute the single correct next input to move the battle-menu cursor
-- toward `target` ({y=.., x=..}), based on the ACTUAL current cursor
-- position, never on an assumed sequence.
local function navigate_to_menu_option(target)
    local cy = memory.readbyte(MENU_CURSOR_Y)
    local cx = memory.readbyte(MENU_CURSOR_X)

    if cy == target.y and cx == target.x then
        return "A"
    elseif cy < target.y then
        return "Down"
    elseif cy > target.y then
        return "Up"
    elseif cx < target.x then
        return "Right"
    else
        return "Left"
    end
end

-- Press a button, then wait until the cursor actually moves (or we time out).
-- Self-correcting: if a press is dropped or lag delays it, we just
-- re-evaluate from wherever we actually ended up.
local function press_and_wait_for_cursor_change(btn, timeout)
    local prevY = memory.readbyte(MENU_CURSOR_Y)
    local prevX = memory.readbyte(MENU_CURSOR_X)
    press_button(btn)
    local n = 0
    while memory.readbyte(MENU_CURSOR_Y) == prevY
      and memory.readbyte(MENU_CURSOR_X) == prevX
      and n < timeout
      and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        n = n + 1
    end
end

local have_battle_controls = false

-- Navigate to FIGHT and use whichever move is already highlighted by
-- default (the first move in the list) - no move-submenu navigation
-- needed, since "kill non-shiny" always wants the first attack.
local FIGHT_CURSOR = {y = 1, x = 1}
local PACK_CURSOR = {y = 2, x = 1}

local function get_active_mon_level()
    local slotIndex = memory.readbyte(curPartyMonAddr)
    if slotIndex > 5 then slotIndex = 5 end
    return memory.readbyte(party_base_addr + 0x27 + slotIndex * 0x30)
end

local function get_active_mon_species()
    local slotIndex = memory.readbyte(curPartyMonAddr)
    if slotIndex > 5 then slotIndex = 5 end
    return memory.readbyte(party_base_addr + 1 + slotIndex)
end

-- Verified via wPartyMon1Moves in both pokecrystal.sym ($DCE1, party
-- base +0x0A) and pokegold.sym ($DA2C, also +0x0A) - identical offset
-- between games. Counts how many of the 4 move slots are non-zero. If
-- fewer than 4, the Pokemon has a free slot and any newly-learned move
-- will auto-fill it with NO prompt at all - no risk, safe to let A
-- presses through without stopping for that specific level-up.
local function get_active_mon_move_count()
    local slotIndex = memory.readbyte(curPartyMonAddr)
    if slotIndex > 5 then slotIndex = 5 end
    local baseAddr = party_base_addr + 0x0A + slotIndex * 0x30
    local count = 0
    for i = 0, 3 do
        if memory.readbyte(baseAddr + i) ~= 0 then
            count = count + 1
        end
    end
    return count
end

-- Checks whether the species learns a move at ANY level in
-- (oldLevel, newLevel] - not just newLevel itself, since a big EXP gain
-- could jump multiple levels in one hit, and a move-learn at an
-- intermediate level would otherwise get skipped right past.
-- +/-1 safety margin: confirmed discrepancy between the disassembly
-- data and actual retail ROM behavior (Croconaw/Bite - data says level
-- 21, but the actual US/EU Rev A cartridge shows it already learned at
-- level 20, confirmed via PP already used on the party screen). Given
-- missing a move-learn defeats the whole point of this feature, treat
-- each listed level as potentially off by one in either direction
-- rather than trusting it as exact.
local function learns_move_in_range(species, oldLevel, newLevel)
    local movesetLevels = LevelUpMoves[species]
    if not movesetLevels then return false end
    for _, lv in ipairs(movesetLevels) do
        if lv >= oldLevel and lv <= newLevel + 1 then
            return true
        end
    end
    return false
end

-- Persistent across the WHOLE battle, not reset per do_kill_turn()
-- call - confirmed bug: individual calls can exit (have_battle_controls
-- becoming true again) before the level-up animation progresses far
-- enough to observe the change within that one call's own short
-- execution, and the next call would just re-establish a fresh
-- baseline from wherever the level already ended up, permanently blind
-- to whatever happened in between.
local battleLevelBaseline = nil
local battleLevelBaselineSpecies = nil
local battleLevelBaselineMoveCount = nil

-- ===== Auto-catch =====
-- Scans the bag for the first ball type found, in BALL_ITEM_IDS
-- preference order (Poke Ball preferred, per direct instruction).
-- Returns the item ID found, or nil if no balls at all.
local function find_ball_in_bag()
    for _, ballId in ipairs(BALL_ITEM_IDS) do
        for i = 0, 19 do
            local itemId = memory.readbyte(wItemsAddr + i * 2)
            if itemId == 0xFF then break end
            if itemId == ballId then
                return ballId
            end
        end
    end
    return nil
end

-- Navigates PACK -> scrolls to the given ball -> selects it (which
-- throws it directly at a wild Pokemon, no "use on which Pokemon?"
-- prompt the way a Potion would have). wCurItem reliably reflects the
-- currently-highlighted item once the menu has settled (confirmed via
-- direct observation), so this checks it before each Down press rather
-- than blindly pressing a fixed number of times - self-correcting if a
-- press is dropped or the bag layout isn't what was last scanned.
local function navigate_to_pack_and_select_ball(ballId)
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)
        if cy == PACK_CURSOR.y and cx == PACK_CURSOR.x then
            press_button("A")
            break
        else
            nav_attempts = nav_attempts + 1
            if nav_attempts > 12 then
                print("Catch-mode: navigation to PACK stuck after 12 attempts")
                return false
            end
            local next_input = navigate_to_menu_option(PACK_CURSOR)
            press_and_wait_for_cursor_change(next_input, 30)
        end
    end

    -- Give the Pack menu a moment to actually open and settle - directly
    -- observed a brief (1-4 frame) window of unrelated/noisy values in
    -- this same memory region right as a menu transition happens, same
    -- class of issue as the EXP-gain animation corruption found earlier.
    for i = 1, 30 do
        emu.frameadvance()
        if memory.readbyte(species_addr) == 0 then return false end
    end

    local scrollAttempts = 0
    while scrollAttempts < 20 and memory.readbyte(species_addr) ~= 0 do
        local curItem = memory.readbyte(wCurItemAddr)
        if curItem == ballId then
            press_button("A")
            return true
        end
        press_button("Down")
        scrollAttempts = scrollAttempts + 1
    end

    print("Catch-mode: couldn't find the ball in the Pack menu after scrolling")
    press_button("B")
    return false
end

-- Simplified attack turn for weakening the enemy before catching -
-- deliberately NOT do_kill_turn(), since that function's move-learn
-- detection doesn't apply here (our own Pokemon can't level up from a
-- hit that doesn't faint the enemy). Returns "fainted" if the attack
-- accidentally faints the target (a real risk with an over-leveled
-- attacker, worth surfacing rather than silently treating as success),
-- "ok" otherwise.
local function do_catch_attack_turn()
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)
        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            press_button("A")
            break
        else
            nav_attempts = nav_attempts + 1
            if nav_attempts > 12 then
                print("Catch-mode: attack navigation stuck after 12 attempts")
                return "stuck"
            end
            local next_input = navigate_to_menu_option(FIGHT_CURSOR)
            press_and_wait_for_cursor_change(next_input, 30)
        end
    end

    if memory.readbyte(species_addr) == 0 then return "fainted" end

    for i = 1, 15 do
        emu.frameadvance()
        if memory.readbyte(species_addr) == 0 then return "fainted" end
    end
    press_button("A")

    have_battle_controls = false
    local postAttackWait = 0
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        press_button("A")
        postAttackWait = postAttackWait + 1
        if postAttackWait > 600 then
            print("Catch-mode: post-attack wait timed out")
            return "stuck"
        end
    end

    if memory.readbyte(species_addr) == 0 then return "fainted" end
    return "ok"
end

local CATCH_HP_TARGET_PERCENT = 0.30

local function do_catch_sequence()
    print("Shiny found! Starting auto-catch sequence...")
    send_discord_notification("Shiny found! Attempting to catch it automatically.")

    local ballId = find_ball_in_bag()
    if not ballId then
        print("No balls in the bag - stopping so you can restock and catch it manually.")
        send_discord_notification("Shiny found, but no balls in the bag! Stopped - restock and catch manually.")
        return true
    end

    -- Weaken the enemy to a safe-but-catchable HP range first, since
    -- Gen 2's catch formula weights heavily on current HP - throwing
    -- balls at full HP wastes far more of them on average. Checks HP
    -- after EVERY attack, not periodically, to minimize the window
    -- where an over-leveled hit could overshoot straight to a faint.
    while true do
        local curHP = memory.read_u16_be(enemy_hp_addr)
        local maxHP = memory.read_u16_be(enemy_max_hp_addr)
        if maxHP == 0 then
            print("Catch-mode: couldn't read enemy max HP - stopping so you can catch it manually.")
            return true
        end
        if curHP <= maxHP * CATCH_HP_TARGET_PERCENT then
            break
        end
        local result = do_catch_attack_turn()
        if result == "fainted" then
            print("The shiny fainted while weakening it for capture - it's gone. Stopping.")
            send_discord_notification("A shiny fainted during the auto-catch attempt and got away. Sorry - you may want to double-check the catch HP threshold.")
            return true
        elseif result == "stuck" then
            print("Catch-mode: got stuck while weakening the enemy - stopping so you can take over.")
            send_discord_notification("Auto-catch got stuck while weakening the shiny for capture. Stopping so you can take over manually.")
            return true
        end
    end

    -- Throw balls until caught, or we run out.
    local maxThrows = 20
    local throws = 0
    while throws < maxThrows do
        ballId = find_ball_in_bag()
        if not ballId then
            print("Ran out of balls mid-catch - stopping so you can restock and finish manually.")
            send_discord_notification("Ran out of balls while trying to catch a shiny! Stopped - restock and catch manually.")
            return true
        end

        local navigated = navigate_to_pack_and_select_ball(ballId)
        if not navigated then
            print("Catch-mode: failed to navigate to the ball - stopping so you can take over.")
            send_discord_notification("Auto-catch failed to navigate the Pack menu. Stopping so you can take over manually.")
            return true
        end

        -- Same reasoning as do_kill_turn()'s post-attack wait: keep
        -- pressing A through the throw animation/messages, bounded so a
        -- stuck state doesn't hang forever.
        local waitFrames = 0
        while memory.readbyte(species_addr) ~= 0 and not have_battle_controls and waitFrames < 600 do
            emu.frameadvance()
            press_button("A")
            waitFrames = waitFrames + 1
        end

        if memory.readbyte(species_addr) == 0 then
            -- Battle ended - the catch succeeded. Press through the
            -- nickname prompt (declining it) and any "sent to a Box"
            -- message if the party was already full (automatic in
            -- Gen 2, just needs a few more A presses to clear).
            print("Caught! Declining nickname prompt and clearing any follow-up messages...")
            for i = 1, 120 do
                press_button("B")
                emu.frameadvance()
            end
            send_discord_notification("Shiny caught successfully via auto-catch!")
            return true
        end

        throws = throws + 1
        print(string.format("Ball thrown (%d/%d) - still in battle, trying again.", throws, maxThrows))
    end

    print("Ran out of throw attempts (" .. maxThrows .. ") without catching it - stopping so you can take over.")
    send_discord_notification("Auto-catch used " .. maxThrows .. " balls without success. Stopping so you can take over manually.")
    return true
end

local function do_kill_turn()
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)

        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            vprint("Pressing A to select FIGHT")
            press_button("A")
            break
        else
            nav_attempts = nav_attempts + 1
            if nav_attempts > 12 then
                print("Kill-mode navigation stuck after 12 attempts - backing out with B")
                press_button("B")
                return
            end
            local next_input = navigate_to_menu_option(FIGHT_CURSOR)
            press_and_wait_for_cursor_change(next_input, 30)
        end
    end

    if memory.readbyte(species_addr) == 0 then return end

    for i = 1, 15 do
        emu.frameadvance()
        if memory.readbyte(species_addr) == 0 then return end
    end
    vprint("Pressing A to use first move")
    press_button("A")

    -- IMPORTANT: use A here, not B. This window includes the post-faint
    -- sequence (EXP gain, level up, evolution) if the enemy fainted, and
    -- pressing B during the evolution sparkle animation is the actual
    -- in-game way to CANCEL an evolution mid-way through. A advances the
    -- same text/menus without that side effect.
    --
    -- TIMEOUT: a "would you like to learn a new move?" or evolution
    -- prompt doesn't re-trigger the battle-menu hook this loop is
    -- waiting on, so without a limit here it can loop forever - which is
    -- exactly what was preventing Stop from working (step() never
    -- returns control to the launcher while stuck in an internal loop).
    -- If we hit this, signal the caller to stop the bot entirely rather
    -- than guess how to navigate a prompt we can't reliably detect.
    have_battle_controls = false
    local postAttackWait = 0
    -- If the enemy already fainted from this attack, this window
    -- specifically risks a move-learn or evolution prompt appearing -
    -- and since we press A every single frame with no way to check
    -- what's actually being shown, that A would immediately confirm
    -- "yes, learn this move" and pick whatever move the cursor lands
    -- on to forget. Use a much shorter timeout in that case to
    -- minimize the risk window, rather than the full budget used when
    -- the enemy is still alive (where there's no such risk at all).
    local enemyFainted = memory.read_u16_be(enemy_hp_addr) == 0
    local postAttackTimeout = enemyFainted and 300 or 600
    if battleLevelBaseline == nil then
        battleLevelBaseline = get_active_mon_level()
        battleLevelBaselineSpecies = get_active_mon_species()
        battleLevelBaselineMoveCount = get_active_mon_move_count()
    end
    local levelBeforeAttack = battleLevelBaseline
    local activeSpecies = battleLevelBaselineSpecies
    local confirmedHigherLevelFrames = 0
    local lastSeenLevel = get_active_mon_level()
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        -- Check BEFORE pressing - a move can only be learned on a
        -- level-up, so the instant level increases, a move-learn
        -- prompt could be showing right now. Stop before any further A
        -- press could risk confirming it. This is more reliable than
        -- hooking the exact LearnMove routine (which never fired - the
        -- actual call path likely goes through some indirection our
        -- hook didn't catch) or a timeout (the whole prompt sequence
        -- completes too fast when mashing A every frame to reliably
        -- hit any reasonable timeout).
        --
        -- Uses the actual verified level-up moveset data (see
        -- data/level_up_moves.lua) rather than stopping on every
        -- level-up regardless of whether a move is actually offered -
        -- a Pokemon only learns new moves at specific levels, not
        -- every level, so this lets ordinary level-ups with no move
        -- pass through automatically.
        if learnMovePromptDetected then
            if battleLevelBaselineMoveCount ~= nil and battleLevelBaselineMoveCount < 4 then
                vprint("Move-learn prompt detected, but a free move slot was available at battle start - auto-fills with no risk, continuing.")
                learnMovePromptDetected = false
            else
                print("Move-learn prompt detected - stopping immediately so you can decide (this Pokemon likely also just leveled up).")
                return "stuck"
            end
        end
        local currentLevel = get_active_mon_level()
        -- Require the SAME level value to be confirmed across 3
        -- consecutive frames before trusting it - a single read can be
        -- corrupted during the EXP-gain/level-up animation window
        -- (confirmed: observed a read of 25->20, which is impossible
        -- during a real battle, since level can only ever go up).
        if currentLevel > levelBeforeAttack and currentLevel == lastSeenLevel then
            confirmedHigherLevelFrames = confirmedHigherLevelFrames + 1
        else
            confirmedHigherLevelFrames = (currentLevel > levelBeforeAttack) and 1 or 0
        end
        lastSeenLevel = currentLevel
        if confirmedHigherLevelFrames >= 3 and learns_move_in_range(activeSpecies, levelBeforeAttack, currentLevel) then
            if battleLevelBaselineMoveCount ~= nil and battleLevelBaselineMoveCount < 4 then
                vprint(string.format("Level increase to %d with a move-learn possible, but a free move slot was available at battle start - auto-fills with no risk, continuing.", currentLevel))
            else
                print(string.format("Level increase to %d - this species learns a move somewhere in that range, a learn-prompt is likely showing. Stopping so you can decide.", currentLevel))
                return "stuck"
            end
        end
        emu.frameadvance()
        press_button("A")
        postAttackWait = postAttackWait + 1
        if postAttackWait > postAttackTimeout then
            if enemyFainted then
                print("Enemy fainted and battle hasn't ended after a short wait - likely a move-learn or evolution prompt. Stopping so you can decide.")
            else
                print("Stuck after attacking for 600+ frames (likely a move-learn or evolution prompt) - stopping so you can handle it manually")
            end
            return "stuck"
        end
    end
end

local overworld_loaded = false
local overworld_settle_frames = 0
local REQUIRED_SETTLE_FRAMES = 10 -- consecutive frames of species_addr==0 before we trust we're truly back

-- Top-level watchdog: tracks real-world time since the player's tile
-- position last actually changed, completely independent of which
-- internal branch/state we're currently in. Uses os.time() (real
-- wall-clock time), not emu.framecount() (game frames) - a frame-count
-- threshold fires inconsistently early when running at a speedup,
-- since the same number of game frames passes in less real time.
local WATCHDOG_SECONDS = 45
local watchdogLastX, watchdogLastY
local watchdogLastMoveTime

-- Separate battle watchdog: the overworld watchdog above can't apply
-- during battle at all (position is SUPPOSED to stay fixed the whole
-- time), and the earlier mark_progress()-based approach had the same
-- blind spot - merely BEING in battle (species_addr ~= 0) is true every
-- single frame regardless of whether anything's actually happening
-- within it, so it could never detect a genuinely stuck battle either
-- (e.g. an interrupting phone call mid-fight). This tracks real-world
-- time since the CURRENT battle started - if we're still in the same
-- ongoing battle after BATTLE_WATCHDOG_SECONDS regardless of what's
-- happening inside it, that's inherently suspicious on its own.
local BATTLE_WATCHDOG_SECONDS = 15
local battleWatchdogStartTime = nil
local battleWatchdogLastDiagnostic = nil
local battleWatchdogTriggered = false

local function watchdog_force_unstuck()
    print(string.format("WATCHDOG: no position change for %d+ seconds regardless of internal state - forcing recovery", WATCHDOG_SECONDS))
    attempt_unstuck_recovery()
    safe_pair = nil
    overworld_settle_frames = 0
    overworld_loaded = false
    realEncounterConfirmed = false
    watchdogLastMoveTime = os.time()
end

-- Hooks get REPLACED by name every time RegisterROMHook runs (confirmed
-- from data/memory.lua's own event.unregisterbyname call) - so whichever
-- module registered LAST keeps its hooks active, even after switching to
-- a "different" module, unless that module re-registers its own. This
-- must be called every time this module becomes active, not just once.
local function register_hooks()
    if LearnMoveAddr then
        Mem.RegisterROMHook(LearnMoveAddr, function()
            if ActiveModuleName ~= "wild" then return end
            learnMovePromptDetected = true
            vprint("LearnLevelMoves.learn entered - a move is being learned, stopping A presses")
        end, "Detect Move-Learn Prompt")
    end

    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "wild" then return end
        have_battle_controls = true
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "wild" then return end
        realEncounterConfirmed = true
        pendingBattleSettle = true
        vprint("combat started")
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

        sessionEncounterCount = sessionEncounterCount + 1

        -- IMPORTANT: this hook fires as a ROM-hook callback, and we've
        -- confirmed BizHawk restricts what's allowed inside callbacks
        -- (emu.frameadvance throws outright; forms.drawText/drawRectangle
        -- calls made from here appear to silently not flush to screen).
        -- So we only record raw data here and let M.step() - running in
        -- the main loop, a confirmed-safe context - do all the actual
        -- GUI updates, stop-condition checks, and Discord notification.
        pendingEncounterUpdate = true
    end, "Tell Display Battle Started / sending data")
end

-- ===== M.init: runs ONCE, sets everything up =====
-- sharedForm: the launcher's persistent window handle.
-- yOffset: vertical position to start building this mode's UI at, so it
-- sits below whatever the launcher put at the top of the window.
-- Returns true on success, false if this ROM/version isn't supported.
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

    mapgroup, mapnumber = memory.readbyte(0xdcb5), memory.readbyte(0xdcb6)
    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, {"chkTrueRandomness"}) -- wild uses every encounter-related field; True Randomness only applies to soft-reset modules

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            Mem.SetRomBankAddress("Crystal")
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
            print("EUR Gold/Silver detected")
            -- Verified against pokegold.sym (symbols branch): enemy_addr
            -- is wEnemyMonDVs ($D0F5), NOT $DA22 (which is actually
            -- wPartyCount - a confirmed bug in the previous, unverified
            -- value). EnemyWildmonInitialized corrected to the
            -- .skip_unown sub-label ($7400), matching the same reasoning
            -- used to pick that specific sub-label for Crystal.
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            -- Verified against pokegold.sym: LearnLevelMoves.learn is at
            -- $64C1 (bank $10), only 4 bytes off from Crystal's $64C5 -
            -- makes the hook the PRIMARY move-learn detection instead of
            -- relying solely on the level-check fallback, which is
            -- inherently imprecise (data-table based, plus a deliberate
            -- +/-1 safety margin that can false-positive on a level
            -- where nothing is actually being offered yet).
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x45 then
            print("USA Gold/Silver detected")
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            print("JPN Gold/Silver detected")
            -- STILL UNVERIFIED: enemy_addr here is $D9E8, the exact same
            -- value as party_base_addr for this region below - the same
            -- bug pattern just confirmed and fixed for EU/US, but I
            -- don't have JP-specific symbol data to correct it to the
            -- right value. This branch is known-broken until verified.
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            -- Also unverified for this region specifically, though the
            -- hook address itself (bank/offset) is a ROM code location
            -- that should be region-independent, same as the other hooks.
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            print("KOR Gold/Silver detected")
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            Mem.SetRomBankAddress("Gold")
        end
    else
        print("No valid ROM detected")
        return false
    end

    dv_flag_addr = enemy_addr + 0x21
    species_addr = enemy_addr + 0x22
    item_addr = enemy_addr - 0x05
    -- Verified via pokecrystal.sym: wEnemyMonHP is +0x0A from the same
    -- base as enemy_addr (structurally consistent with the standard
    -- Species+Item+Moves+OT_ID+DVs = 10 bytes before HP layout).
    enemy_hp_addr = enemy_addr + 0x0A
    -- Verified via pokecrystal.sym/pokegold.sym: wEnemyMonMaxHP is
    -- +0x0C from the same base as enemy_addr in both games (right after
    -- the 2-byte HP value itself) - needed to compute HP% for deciding
    -- when the target is weak enough to start throwing balls.
    enemy_max_hp_addr = enemy_addr + 0x0C
    -- Gold/Silver note: item_addr (-0x05) and enemy_hp_addr (+0x0A) are
    -- directly confirmed against pokegold.sym's named wEnemyMonItem and
    -- wEnemyMonHP. species_addr (+0x22) and dv_flag_addr (+0x21) are
    -- NOT directly confirmed for Gold - they're extrapolated from the
    -- same offset pattern that works for Crystal, on the basis that
    -- InitEnemyWildmon.skip_unown is structurally very similar between
    -- the two games (nearly identical bank/offset for the hook itself).
    -- Reasonable, but worth specifically sanity-checking species names
    -- and DV-read timing during Gold testing.

    -- For the move-learn detection fix: a move can only be learned on
    -- a level-up, so tracking the active Pokemon's level directly is
    -- more reliable than trying to hook the exact prompt (which didn't
    -- work) or guess at timeouts (which also didn't work, since the
    -- whole sequence completes too fast when mashing A every frame).
    -- wCurPartyMon (RAM, no bank translation needed) tells us which
    -- party slot is actually battling - not always slot 0, if an
    -- earlier Pokemon in this session already fainted.
    -- Switched from wCurPartyMon ($D109) to wCurBattleMon ($D0D4) -
    -- confirmed via the game's own DrawPlayerHUD routine, which uses
    -- wCurBattleMon specifically to determine "which party member's
    -- data to display during battle" - exactly our use case. The
    -- wrong variable was very likely why level reads were unreliable.
    -- wCurBattleMon determines "which party member's data to display
    -- during battle" (confirmed via Crystal's DrawPlayerHUD routine) -
    -- but it's at a DIFFERENT address in Gold/Silver ($CFC6, bank 00)
    -- than in Crystal ($D0D4), confirmed via pokegold.sym. Must be
    -- version-specific, not hardcoded to one game's value.
    -- Same critical fix for the menu cursor addresses: confirmed via
    -- direct symbol lookup that wMenuCursorY/X live at completely
    -- different addresses between Crystal ($CFA9/$CFAA) and Gold/Silver
    -- ($CEE0/$CEE1) - using the wrong one meant the bot was reading
    -- unrelated memory during battle, so cursor-position checks never
    -- matched anything real and navigation always timed out.
    -- Confirmed via direct symbol lookup: wPlayerWalking lives at a
    -- different address in Gold/Silver ($D204) than Crystal ($D4DD) -
    -- using the wrong one meant attempt_step()'s wait loops never saw
    -- the flag change correctly, so every step always hit its full
    -- timeout instead of completing as soon as real movement finished
    -- (explains "3-4x slower overworld movement").
    -- Confirmed via direct symbol lookup: wPlayerWalking lives at a
    -- different address in Gold/Silver ($D204) than Crystal ($D4DD) -
    -- using the wrong one meant attempt_step()'s wait loops never saw
    -- the flag change correctly, so every step always hit its full
    -- timeout instead of completing as soon as real movement finished
    -- (explains "3-4x slower overworld movement"). Same for
    -- wXCoord/wYCoord: Crystal $DCB8/$DCB7, Gold/Silver $DA03/$DA02 -
    -- previously hardcoded throughout the nudge-cycle and overworld
    -- watchdog position-tracking, meaning the watchdog specifically
    -- was reading unrelated memory on Gold even after basic movement
    -- itself started working via the flag-address fix alone.
    if version == 0x55 or version == 0x58 then
        curPartyMonAddr = 0xcfc6
        MENU_CURSOR_Y = 0xCEE0
        MENU_CURSOR_X = 0xCEE1
        MOVEMENT_FLAG_ADDR = 0xD204
        FIRST_MOVE_PP_ADDR = 0xCB14
        OWN_HP_ADDR = 0xCB1C
        OWN_MAX_HP_ADDR = 0xCB1E
        PLAYER_X_ADDR = 0xDA03
        PLAYER_Y_ADDR = 0xDA02
        wCurItemAddr = 0xD002
        wItemsAddr = 0xD5B8
        wNumItemsAddr = 0xD5B7
    else
        curPartyMonAddr = 0xd0d4
        MENU_CURSOR_Y = 0xCFA9
        MENU_CURSOR_X = 0xCFAA
        MOVEMENT_FLAG_ADDR = 0xD4DD
        FIRST_MOVE_PP_ADDR = 0xC634
        OWN_HP_ADDR = 0xC63C
        OWN_MAX_HP_ADDR = 0xC63E
        PLAYER_X_ADDR = 0xDCB8
        PLAYER_Y_ADDR = 0xDCB7
        wCurItemAddr = 0xD106
        wItemsAddr = 0xD893
        wNumItemsAddr = 0xD892
    end
    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    end

    watchdogLastX, watchdogLastY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
    watchdogLastMoveTime = os.time()

    register_hooks()

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Settling into overworld...")
    return true
end

-- ===== M.step: called once per frame by the launcher's own loop =====
-- The launcher has ALREADY called emu.frameadvance() before this.
-- Returns true when this mode is done (shiny found / stop condition met)
-- so the launcher knows to stop calling step() and reset its UI to idle.
-- Returns false/nil to mean "keep going, call me again next frame".
-- Called by the launcher every time Start is clicked, even if this module
-- was already loaded and running before. Forces a fresh anchor point for
-- wherever the character actually is right now - handles being manually
-- moved to a different spot/map while stopped, which step() would
-- otherwise have no way to notice (it simply isn't called while stopped).
-- Called every time this module becomes the active one, whether for the
-- first time or returning to it after a different module ran. Distinct
-- from on_resume, which is specifically about the Start button.
function M.on_switch_to()
    register_hooks()
    Gui.reconfigure(hud, {"chkTrueRandomness"})
    Gui.clear_last_encounter(hud)
end

function M.on_resume()
    safe_pair = nil
    homeX, homeY = nil, nil
    overworld_settle_frames = 0
    overworld_loaded = false
    lastProgressTime = nil
    stuckNotificationSent = false
    stopRequested = false
    stopReason = ""
    shinyvalue = 0
    learnMovePromptDetected = false
end

function M.step()
    check_stuck_and_notify()

    if pendingEncounterUpdate then
        pendingEncounterUpdate = false

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local atkDV = math.floor(atkdef / 16)
        local defDV = atkdef % 16
        local speDV = math.floor(spespc / 16)
        local spcDV = spespc % 16
        local isShinyEncounter = (shinyvalue == 1)
        Stats.record_encounter()

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Checking encounter...")
        Gui.update_last_encounter(hud, sessionEncounterCount, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

        if isShinyEncounter then
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "SHINY FOUND!")
            send_discord_notification(string.format(
                "Shiny found! %s (#%d) (Atk:%d Def:%d Spe:%d Spc:%d) holding %s",
                speciesName, species, atkDV, defDV, speDV, spcDV, itemName))
        end

        local isPerfect = (atkDV == 15 and defDV == 15 and speDV == 15 and spcDV == 15)
        local isPerfectNegative = (atkDV == 0 and defDV == 0 and speDV == 0 and spcDV == 0)
        local speciesStopEnabled, speciesTarget = Gui.stop_on_species(hud)
        local itemStopEnabled, itemFilterTokens = Gui.stop_on_item(hud)
        local itemMatches = item ~= 0 and species_matches_filter(itemFilterTokens, item, itemName)

        if Gui.stop_on_perfect(hud) and isPerfect then
            stopRequested = true
            stopReason = "Perfect DVs (15/15/15/15) found!"
        elseif Gui.stop_on_perfect_negative(hud) and isPerfectNegative then
            stopRequested = true
            stopReason = "Perfect Negative DVs (0/0/0/0) found!"
        elseif speciesStopEnabled and species == speciesTarget then
            stopRequested = true
            stopReason = string.format("Target species %s (#%d) found!", speciesName, speciesTarget)
        elseif itemStopEnabled and itemMatches then
            stopRequested = true
            stopReason = string.format("Held item %s found!", itemName)
        end

        if stopRequested then
            print(stopReason)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, stopReason)
            send_discord_notification(string.format(
                "%s %s (#%d) (Atk:%d Def:%d Spe:%d Spc:%d)",
                stopReason, speciesName, species, atkDV, defDV, speDV, spcDV))
        end

    end

    local rawSpecies = memory.readbyte(species_addr)

    -- The watchdog only makes sense in the overworld - position is
    -- SUPPOSED to stay constant during a battle. While in battle, just
    -- keep refreshing the clock so it starts fresh once we're actually
    -- back in the overworld.
    if rawSpecies ~= 0 then
        watchdogLastX, watchdogLastY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        watchdogLastMoveTime = os.time()
    else
        local watchdogX, watchdogY = memory.readbyte(PLAYER_X_ADDR), memory.readbyte(PLAYER_Y_ADDR)
        if watchdogX ~= watchdogLastX or watchdogY ~= watchdogLastY then
            watchdogLastX, watchdogLastY = watchdogX, watchdogY
            watchdogLastMoveTime = os.time()
        elseif os.time() - watchdogLastMoveTime >= WATCHDOG_SECONDS then
            watchdog_force_unstuck()
        end
    end

    if rawSpecies == 0 then
        have_battle_controls = false
        overworld_settle_frames = overworld_settle_frames + 1
        if overworld_settle_frames >= REQUIRED_SETTLE_FRAMES then
            if not overworld_loaded then
                vprint("Overworld loaded - movement enabled")
                -- Force a fresh safe-pair verification for wherever we
                -- actually are now - handles being manually moved to a
                -- different spot/map while the bot was stopped, and any
                -- residual drift from the encounter that just ended.
                safe_pair = nil
                -- Reset the battle watchdog too, so the next battle
                -- gets its own fresh start time rather than inheriting
                -- this one's.
                battleWatchdogStartTime = nil
                battleWatchdogTriggered = false
                battleWatchdogLastDiagnostic = nil
                battleLevelBaseline = nil
                battleLevelBaselineSpecies = nil
                battleLevelBaselineMoveCount = nil
                learnMovePromptDetected = false
            end
            overworld_loaded = true
        end
    else
        overworld_settle_frames = 0
        overworld_loaded = false
    end

    if not overworld_loaded then
        if rawSpecies == 0 then
            joypad.set({B = true})
        end
    end

    if overworld_loaded then
        if do_nudge_cycle() then
            mark_progress()
        end
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Searching for encounters...")

    elseif memory.readbyte(species_addr) ~= 0 then
        if battleWatchdogStartTime == nil then
            battleWatchdogStartTime = os.time()
            battleWatchdogTriggered = false
            -- Capture the level baseline HERE, at the very start of the
            -- battle, before any attack has happened at all - setting
            -- this lazily inside do_kill_turn() was too late, since
            -- that function both executes the attack AND sets up the
            -- post-attack wait in the same call, so by the time the
            -- baseline was captured the attack (and any level-up it
            -- caused) had already happened.
            battleLevelBaseline = get_active_mon_level()
            battleLevelBaselineSpecies = get_active_mon_species()
            battleLevelBaselineMoveCount = get_active_mon_move_count()
        elseif not battleWatchdogTriggered and os.time() - battleWatchdogStartTime >= BATTLE_WATCHDOG_SECONDS then
            battleWatchdogTriggered = true
            local enemyHP = memory.read_u16_be(enemy_hp_addr)
            if enemyHP == 0 then
                print("BATTLE WATCHDOG: enemy has fainted and battle still hasn't ended - likely a move-learn or evolution prompt. Stopping so you can decide.")
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                    "Stopped - likely a move-learn or evolution prompt needs your input")
                send_discord_notification(
                    "Grinding stopped: the enemy fainted but the battle hasn't ended after a while - likely a move-learn or evolution prompt waiting for your input. Handle it manually, then resume.")
                return true
            else
                print(string.format("BATTLE WATCHDOG: still in the same battle after %d+ seconds - attempting automatic recovery", BATTLE_WATCHDOG_SECONDS))
                attempt_unstuck_recovery()
                send_discord_notification(string.format(
                    "Potentially stuck in battle: same encounter still active after over %d seconds. Attempted automatic recovery (A/B presses) - check on it if this keeps happening.",
                    BATTLE_WATCHDOG_SECONDS))
                battleWatchdogStartTime = os.time() -- give the recovery attempt a fresh window
            end
        end
        mark_progress()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "In battle...")

        local dvWaitFrames = 0
        while memory.readbyte(dv_flag_addr) ~= 0x01 and dvWaitFrames < 120 do
            if memory.readbyte(species_addr) == 0 and not realEncounterConfirmed then
                break
            end
            emu.frameadvance()
            press_button("B")
            dvWaitFrames = dvWaitFrames + 1
        end

        if memory.readbyte(dv_flag_addr) ~= 0x01 then
            if realEncounterConfirmed then
                print("DV-wait: timed out after " .. dvWaitFrames .. " frames waiting for dv_flag_addr despite a confirmed encounter - backing off")
            end
            realEncounterConfirmed = false
            goto continue
        end

        realEncounterConfirmed = false

        if Gui.auto_catch_test_mode(hud) then
            return do_catch_sequence()
        end

        if shinyvalue == 1 then
            if Gui.auto_catch_enabled(hud) then
                return do_catch_sequence()
            else
                print("Shiny found!!")
                return true
            end
        end

        if stopRequested then
            return true
        end

        if memory.readbyte(species_addr) ~= 0 then
            -- BOUNDED: if this never becomes true (for any reason),
            -- this must not loop forever - this runs BEFORE the battle
            -- watchdog check below even happens, so an unbounded loop
            -- here would prevent the watchdog from ever getting a
            -- chance to fire at all.
            local initialWaitFrames = 0
            while not have_battle_controls and memory.readbyte(species_addr) ~= 0 and initialWaitFrames < 300 do
                emu.frameadvance()
                press_button("B")
                initialWaitFrames = initialWaitFrames + 1
            end

            -- PP reads as stale for a couple of frames immediately after
            -- a NEW battle's menu first loads, before settling to its
            -- real value. Only wait for this ONCE per battle
            -- (pendingBattleSettle only gets set true on a genuine new
            -- encounter). Note: species_addr can transiently flicker to
            -- 0 for a single frame right at battle start before settling
            -- to its real nonzero value, so this wait does NOT bail out
            -- early on that check the way other loops do - a flicker
            -- there previously cut this wait short after just 1 frame.
            if pendingBattleSettle then
                pendingBattleSettle = false
                for i = 1, 30 do
                    emu.frameadvance()
                end
            end

            local killFilterTokens = Gui.kill_species_filter(hud)
            local killAllowedForThisSpecies = species_matches_filter(killFilterTokens, species, get_pokemon_name(species))
            local hasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0
            local hpSafe = has_safe_hp()

            if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and hasPP and hpSafe then
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Attacking...")
                local killResult = do_kill_turn()
                if killResult == "stuck" then
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                        "Stopped - move-learn or evolution prompt needs your input")
                    send_discord_notification("Grinding stopped: a move-learn or evolution prompt is likely showing and needs your input. Handle it manually, then resume.")
                    return true
                end
            else
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Fleeing battle...")

                -- Running from a wild battle in Gen 2 isn't guaranteed to
                -- succeed - there's a chance-based escape formula, and a
                -- failed attempt shows "Can't escape!" while the battle
                -- continues (the enemy gets a turn). Selecting RUN and
                -- pressing A only confirms we ATTEMPTED to flee, not that
                -- it worked - so retry the whole sequence if the first
                -- attempt's exit-wait times out, rather than assuming
                -- success and getting stuck.
                local escapeAttempts = 0
                local fledSuccessfully = false
                while not fledSuccessfully and escapeAttempts < 5 and memory.readbyte(species_addr) ~= 0 do
                    escapeAttempts = escapeAttempts + 1

                    -- Don't rely on have_battle_controls (hook-driven)
                    -- for retries - the hook watches for the menu
                    -- LOADING, and after "Can't escape!" the game may
                    -- return to the same already-open menu without a
                    -- full reload event, meaning the hook might never
                    -- re-fire and have_battle_controls could stay false
                    -- forever. Check the cursor position directly
                    -- instead, which doesn't depend on any hook at all.
                    local waitForControlsFrames = 0
                    while memory.readbyte(species_addr) ~= 0 and waitForControlsFrames < 300 do
                        local cy0 = memory.readbyte(MENU_CURSOR_Y)
                        local cx0 = memory.readbyte(MENU_CURSOR_X)
                        if (cy0 == FIGHT_CURSOR.y or cy0 == RUN_CURSOR.y) and (cx0 == FIGHT_CURSOR.x or cx0 == RUN_CURSOR.x) then
                            have_battle_controls = true
                            break
                        end
                        emu.frameadvance()
                        press_button("B")
                        waitForControlsFrames = waitForControlsFrames + 1
                    end

                    local nav_attempts = 0
                    local ran_away = false
                    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                        local cy = memory.readbyte(MENU_CURSOR_Y)
                        local cx = memory.readbyte(MENU_CURSOR_X)

                        if cy == RUN_CURSOR.y and cx == RUN_CURSOR.x then
                            vprint(string.format("Pressing A to select RUN (Y=%d X=%d)", cy, cx))
                            press_button("A")
                            ran_away = true
                            break
                        else
                            nav_attempts = nav_attempts + 1
                            if nav_attempts > 12 then
                                vprint("Navigation stuck after 12 attempts - backing out with B and stopping this attempt")
                                press_button("B")
                                break
                            end
                            local next_input = navigate_to_menu_option(RUN_CURSOR)
                            vprint(string.format("Y=%d X=%d -> pressing %s", cy, cx, next_input))
                            press_and_wait_for_cursor_change(next_input, 30)
                            local ny, nx = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
                            if ny == cy and nx == cx then
                                vprint(string.format("  no change after %s (still Y=%d X=%d) - possible timeout", next_input, ny, nx))
                            end
                        end
                    end

                    if ran_away then
                        vprint(string.format("Ran away (attempt %d) - clearing exit text until battle actually ends", escapeAttempts))
                        local exitWaitFrames = 0
                        while memory.readbyte(species_addr) ~= 0 and exitWaitFrames < 180 do
                            emu.frameadvance()
                            press_button("B")
                            exitWaitFrames = exitWaitFrames + 1
                        end
                        if memory.readbyte(species_addr) == 0 then
                            fledSuccessfully = true
                            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Escaped, wrapping up...")
                        else
                            vprint(string.format("Escape attempt %d timed out (Can't escape!, most likely) - retrying", escapeAttempts))
                        end
                        have_battle_controls = false
                    end
                end

                if not fledSuccessfully and memory.readbyte(species_addr) ~= 0 then
                    print(string.format("WARNING: could not escape after %d attempts - continuing anyway", escapeAttempts))
                end
            end
        end
    end

    ::continue::
    return false
end

return M

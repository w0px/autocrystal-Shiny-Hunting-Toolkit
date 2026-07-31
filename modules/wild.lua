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
RngEnabler = require("data.rng_enabler")

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

-- Checks the global flag set by launcher.lua's Stop button. Needed
-- specifically for the auto-catch sequence, which runs long, blocking
-- loops (throwing up to 20 balls, each with several sub-waits) entirely
-- within a single M.step() call - the launcher can't act on a Stop
-- press until M.step() actually returns, so this lets that long
-- sequence notice and bail out on its own instead of the user having no
-- way to interrupt it until it finishes naturally.
local function stop_was_requested()
    return AutocrystalGlobalStopRequested == true
end

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

-- Escapes a value for safe inclusion inside a JSON string. Backslashes
-- MUST be escaped first, before quotes - otherwise the backslash we
-- just inserted for the quote would itself get escaped on a second pass.
local function json_escape(value)
    local str = tostring(value)
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    str = str:gsub('\n', '\\n')
    str = str:gsub('\r', '\\r')
    str = str:gsub('\t', '\\t')
    return str
end

-- Sends a rich Discord embed instead of plain text - title, optional
-- description, optional fields (array of {name, value, inline}),
-- optional color (decimal RGB), optional sprite thumbnail URL (small,
-- top-right corner - Discord's other option, "image", renders large and
-- full-width but the source sprites are tiny pixel art so it didn't
-- actually look any bigger, just moved to the bottom; thumbnail keeps
-- the nicer top-right placement for the same effective size). Built by
-- only ever inserting valid parts into a list (never leaving nil gaps
-- in the middle of it), since Lua's ipairs() stops at the first nil -
-- a fixed-size array with conditional nils in the middle would silently
-- drop everything after the first missing piece.
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

    -- Discord only ever triggers an actual ping/notification from a
    -- message's top-level "content" field - text formatted as a mention
    -- inside an embed (title/description/fields) is displayed as plain
    -- text and never notifies anyone, no matter how it's escaped. So the
    -- mention has to be threaded in here, as a sibling of "embeds", not
    -- tucked into the embed itself.
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

-- Builds a URL for this species' authentic Gen II Crystal shiny sprite,
-- served via jsdelivr's CDN mirror of PokeAPI's open sprite repo - no
-- hosting of our own needed. Keyed directly off the national dex number,
-- which equals Generation II's internal species index (see the header
-- comment in data/pokemon_names.lua), so the "species" value we already
-- have on hand for every encounter can be passed straight in.
local function shiny_sprite_url(dexNumber)
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/shiny/%d.png",
        dexNumber)
end

-- Generation II's Hidden Power type/power formula - distinct from every
-- later generation's version (which uses all 6 stats and a different
-- range). Type comes from just the two low bits of Attack and Defense
-- DVs (a 0-15 index into the 16 non-Normal types); power comes from the
-- high bit (>=8) of all four DVs plus Special's low two bits, and always
-- lands in the 31-70 range. Source: Bulbapedia's Hidden Power
-- calculation page.
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

-- Maps (map group, map number) pairs - as read from wCurMapGroup /
-- wCurMapNumber, addresses 0xDCB5/0xDCB6 - to human-readable location
-- names. Full 388-entry table extracted from the real pret/pokecrystal
-- disassembly (constants/map_constants.asm - the actual source the game
-- itself is built from, not a guess), cross-checked against every
-- group:number pair this project had already hand-verified in a live
-- emulator before being trusted. See data/location_names.lua. Anything
-- somehow still missing (e.g. a ROM revision with different map data)
-- falls back to the raw "Map Group X, #Y" instead of guessing.
local LocationNames = require("data.location_names")

local function location_name(group, number)
    return LocationNames[string.format("%d:%d", group, number)]
        or string.format("Map Group %d, #%d", group, number)
end

-- Prefer the already-safe AutocrystalCurrentLocation global (maintained by
-- M.step() below, which only updates it when the map group/number pair is a
-- RECOGNIZED location) over a fresh raw read of 0xdcb5/0xdcb6. Discord embed
-- code (shiny-found, stop-condition) used to read those two WRAM bytes
-- directly at the moment the embed was built - but by then a battle was
-- already in progress, and those bytes can transiently read as garbage
-- during battle (the exact issue M.step()'s comment already warns about),
-- producing an unresolved "Map Group 0, #0" location in the embed instead
-- of the real place name. Falls back to a raw read only if
-- AutocrystalCurrentLocation hasn't been set yet (e.g. very early on).
local function current_location_name()
    if AutocrystalCurrentLocation then
        return AutocrystalCurrentLocation
    end
    return location_name(memory.readbyte(0xdcb5), memory.readbyte(0xdcb6))
end

-- A visible horizontal-rule divider between field groups. Discord embeds
-- have no actual "separator" element, so the standard workaround is a
-- non-inline field whose value is a run of block characters (forces a
-- full-width line) with a zero-width space as the name (so no label
-- prints above it).
local function divider_field()
    return {name = "\xE2\x80\x8B", value = string.rep("\xE2\x96\xAC", 28), inline = false}
end

-- Embed colors, used to color-code every Discord message by what kind
-- of event it is at a glance (gold = found/stopped for a target, green =
-- successfully caught, red = failed/error/stuck).
local COLOR_GOLD = 16766720
local COLOR_GREEN = 3066993
local COLOR_RED = 15158332

-- Same idea as shiny_sprite_url, but the regular (non-shiny) sprite -
-- used for auto-catch notifications about a held-item match that isn't
-- shiny (do_catch_sequence(false) can still fire for those).
local function regular_sprite_url(dexNumber)
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/%d.png",
        dexNumber)
end

-- Lean colored embed for the auto-catch dialogue - just a title, color,
-- Dex #, held item, and the species' sprite for visual consistency,
-- without the full stat breakdown the shiny-found and stop-found embeds
-- use (these fire multiple times per catch attempt, so a lighter
-- footprint keeps the channel readable). itemName is optional - pass
-- nil to omit the field entirely (e.g. contexts where it isn't known).
local function send_catch_notification(title, color, speciesId, isShiny, itemName)
    local spriteUrl = isShiny and shiny_sprite_url(speciesId) or regular_sprite_url(speciesId)
    local fields = {{name = "Dex #", value = string.format("#%03d", speciesId), inline = true}}
    if itemName then
        table.insert(fields, {name = "Held Item", value = itemName, inline = true})
    end
    send_discord_embed(title, nil, fields, color, spriteUrl)
end

-- Even leaner colored embed for bot-status alerts (stuck detection,
-- battle watchdog, move-learn prompts) that aren't about a specific
-- catch attempt, so there's no species to attach a sprite/Dex # to.
local function send_alert(title, color)
    send_discord_embed(title, nil, nil, color, nil)
end

-- Stuck detection: tracks real-world time since the bot last made
-- genuine progress (a successful nudge cycle, or being actively engaged
-- in a battle) - NOT raw position, since a successful nudge cycle
-- deliberately returns to the exact same "home" tile every time by
-- design, which would make raw position look "unchanged" constantly
-- even when everything is working perfectly.
--
-- Two-tier response: once STUCK_RECOVERY_SECONDS passes with no
-- progress, print to console and try the automatic A/B recovery -
-- quietly, on a repeating cadence, with NO Discord notification yet,
-- since a first stall is often nothing (a slow animation, a menu, etc)
-- and resolves itself or via the first recovery attempt. Only once the
-- bot is STILL stuck after the much longer STUCK_DISCORD_SECONDS - i.e.
-- it's genuinely likely stuck and recovery isn't working - does a single
-- Discord alert fire. Either timer resets the moment real progress
-- happens again.
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
            "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck: no movement or battle progress for over %d seconds, even after automatic recovery attempts. Check on it.",
            STUCK_DISCORD_SECONDS), COLOR_RED)
    end
end

-- ===== Persistent state (shared between M.init and M.step via closure) =====

local desired_species = -1
local atkdef
local spespc
local species
local item = 0
local shinyvalue = 0
-- Rich embed fields/sprite for the CURRENT encounter, if it's shiny -
-- computed once in M.step()'s pendingEncounterUpdate handling and
-- consumed exactly once, either by the auto-catch "found! attempting to
-- catch" notification (merged in, so that message carries the full
-- details) or by send_pending_shiny_embed() below (for every other
-- shiny-found branch that doesn't go through auto-catch). Confirmed via
-- a real user report/screenshot (on fishing.lua, identical architecture
-- to this file): this used to be sent unconditionally as its own
-- separate embed AND auto-catch sent its own separate "found/attempting"
-- + "caught successfully" pair, so a single successful shiny catch
-- produced 3 Discord messages with the detailed one oddly sandwiched in
-- the middle/end instead of leading. Reset to nil at the top of every
-- new pendingEncounterUpdate so a non-shiny encounter never accidentally
-- reuses a previous shiny's leftover fields.
local pendingShinyFields = nil
local pendingShinySpriteUrl = nil
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
-- Hooks the actual MoveSelectionScreen ROM routine (confirmed via
-- direct pokecrystal.sym/pokegold.sym symbol lookups: bank $0F, address
-- $64bc on Crystal and $62f3 on Gold/Silver - same bank as
-- EnemyWildmonInitialized below) so the bot can know FOR CERTAIN the
-- move-select submenu has genuinely opened, instead of inferring it
-- from cursor position/timing. Set below for every ROM version/region
-- this bot supports; every use of it below still falls back to the old
-- timing-based approach as a defensive default should it ever end up
-- unset for some reason.
local MoveSelectionAddr
local EnemyWildmonInitialized
local LearnMoveAddr
-- Precise, verified hooks for the actual catch outcome - found via
-- direct symbol lookup in both pokecrystal.sym and pokegold.sym:
-- PokeBallEffect.caught and PokeBallEffect.shake_and_break_free.
-- Replaces extensive, repeatedly-failed guessing based on species_addr/
-- have_battle_controls, which proved capable of reading stably WRONG
-- for 400+ consecutive frames during this exact transition (confirmed
-- via direct observation) - no heuristic on top of those signals could
-- ever have been reliable, since the underlying signals themselves
-- aren't trustworthy here.
local CatchSuccessAddr
local CatchFailAddr
local catchOutcomeSucceeded = false
local catchOutcomeFailed = false
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
local wBallsAddr, wNumBallsAddr
-- Preference order when scanning the bag for something to throw -
-- Poke Ball specifically preferred (per direct instruction), falling
-- back to other ball types only if no Poke Balls are left.
local BALL_ITEM_IDS = {5, 4, 2, 1} -- Poke, Great, Ultra, Master

-- Sends the detailed "Shiny X Found!" embed built from pendingShinyFields
-- (DVs, Hidden Power, Location, encounter stats, sprite - see where those
-- are computed in M.step()'s pendingEncounterUpdate handling). Used by
-- every shiny-found branch EXCEPT the auto-catch-will-attempt-it path,
-- where these same fields get merged into the "found! attempting to
-- catch" notification instead (see do_catch_sequence) so a successful
-- auto-catch produces exactly 2 Discord messages, not 3.
local function send_pending_shiny_embed(speciesName)
    if pendingShinyFields then
        send_discord_embed(string.format("✨ Shiny %s Found!", speciesName),
            nil, pendingShinyFields, COLOR_GOLD, pendingShinySpriteUrl)
    end
end

-- Broader than BALL_ITEM_IDS - used to detect "have we arrived at the
-- Balls pocket at all", regardless of which specific ball happens to be
-- first in it (which won't necessarily be our preferred one). Includes
-- Apricorn balls (157-166) and Park Ball (177) alongside the standard four.
local function is_ball_item(itemId)
    for _, ballId in ipairs(BALL_ITEM_IDS) do
        if itemId == ballId then return true end
    end
    if itemId >= 157 and itemId <= 166 then return true end
    if itemId == 177 then return true end
    return false
end
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
local UNSTUCK_THRESHOLD = 30

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
    for i = 1, 80 do
        press_button("B")
        if memory.readbyte(species_addr) ~= 0 then break end
    end
    safe_pair = nil -- re-verify from scratch, position/context may have shifted
    consecutive_movement_failures = 0
end

-- Entropy injection for continuous wild encounters - a DIFFERENT problem
-- than the one RngEnabler was originally built for (see rng_mechanics.md).
-- That doc confirms hRandomAdd/hRandomSub are genuinely high-entropy
-- BETWEEN frames (a 1-frame difference in savestate-reload timing always
-- produces a totally different RNG state) - the soft-reset modules exist
-- to restore variance BizHawk's determinism removes, not to fix any
-- weakness in the RNG itself.
--
-- Wild encounters never reload a savestate, so that specific problem
-- doesn't apply here. But a real, DIFFERENT correlation was found by
-- statistically analyzing a genuine 14,822-encounter log from this exact
-- module: the two DV bytes (atkdef, spespc) are read back-to-back inside
-- a single encounter's own ROM routine, essentially the same instant -
-- almost certainly the same frame, with at most a handful of CPU cycles
-- between the two internal "Random" calls that produce them. Measured
-- across that real log: encounters where Def=10 (from the first byte)
-- co-occurred with Spe=10 AND Spc=10 (both from the second byte) came up
-- ZERO times in 14,822 tries versus ~3.6 expected, and a chi-square test
-- on (spespc - atkdef) mod 256 came back at 908 against an expected ~255
-- (df=255) - 20 simulated fully-random control runs of the same size
-- never exceeded 318. That's not bad luck; the two bytes are landing in
-- a narrower relationship than genuine independence would produce,
-- almost certainly because so little time (if any distinct frame at all)
-- separates the two internal rolls within one encounter.
--
-- What DOES vary a lot, per the same confirmed measurement above, is the
-- overall RNG state from one FRAME to the next. So the fix isn't "fix
-- the RNG" (it isn't broken) - it's "don't let every encounter's DV-roll
-- land on the same narrow slice of frame-timing relative to this cycle's
-- start," which the bot's mechanically identical nudge-cycle timing was
-- otherwise doing every single time. Bounded intentionally small (unlike
-- the reset-oriented RngEnabler.SPLIT_RANGE=256) since this fires on
-- EVERY nudge cycle, not once per reset - a full 256-frame burn here
-- would add far more overhead than the once-per-attempt cost it was
-- tuned for. Start conservative and widen only if a fresh post-fix log
-- still shows the same correlation.
local WILD_JITTER_RANGE = 64

local function do_nudge_cycle()
    -- See WILD_JITTER_RANGE above - burns a random 1-64 idle frames
    -- before every cycle so consecutive encounters don't keep landing on
    -- the same frame-timing relationship between the two DV-roll reads.
    -- Safe to do blindly here (no species_addr check needed): Gen 2 only
    -- rolls a wild encounter on an actual step, never while idle, so
    -- burning idle frames can't itself trigger or mask one.
    RngEnabler.enable_randomness(WILD_JITTER_RANGE)

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
-- Set true by the MoveSelectionScreen ROM hook (see MoveSelectionAddr
-- above) the instant the real move-select submenu opens - a positive,
-- address-based confirmation instead of inferring it from cursor
-- position/timing. Reset to false right before each attempt to open
-- FIGHT so it always reflects "has the submenu opened THIS attempt".
local moveSelectScreenOpen = false

-- Navigate to FIGHT and use whichever move is already highlighted by
-- default (the first move in the list) - normally no move-submenu
-- navigation needed, since both kill-non-shiny and catch-mode want the
-- first attack whenever it has PP.
local FIGHT_CURSOR = {y = 1, x = 1}
local PACK_CURSOR = {y = 2, x = 1}
-- Second move slot in the FIGHT submenu's 2x2 grid (top-right, one
-- "Right" press over from the default top-left cursor position) - used
-- as a fallback when the first move is out of PP, so a depleted move
-- doesn't stop the bot outright if a second attack is still usable.
-- Originally assumed to be {y=1,x=2} by analogy with the main battle
-- menu's 2x2 FIGHT/PKMN/ITEM/RUN layout, but a live diagnostic (cursor
-- verification added after the first user report) confirmed that guess
-- was wrong: after pressing Right from (1,1), the cursor stayed at
-- (1,1) - it never moves on the x-axis at all. The move-select submenu
-- is a single-column list of 4 moves (unlike the 2x2 top-level menu),
-- so the second move is one row DOWN, not one column to the right.
local MOVE2_CURSOR = {y = 2, x = 1}

-- Tracks consecutive failures to confirm the cursor reached
-- MOVE2_CURSOR (shared across do_catch_attack_turn/do_kill_turn, since
-- only one of them is ever in use per battle). Confirmed via a real
-- user report: this verification can legitimately fail even when
-- nothing's wrong - a status condition (confusion hitting itself,
-- sleep, etc.) can skip the move-select screen ENTIRELY for a turn,
-- so the cursor just never moves (there's no menu to navigate). That
-- looks identical to a genuine navigation bug, so a single failure
-- now backs out safely and retries next tick instead of stopping the
-- bot outright - this counter only escalates to a real stop if it
-- keeps failing far more than any normal status condition would.
local move2NavFailStreak = 0

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
-- Balls live in their own dedicated pocket (wBalls), completely
-- separate from the general Items pocket (wItems) - confirmed the hard
-- way (the bot correctly found Potion/Berry/Super Potion in wItems,
-- but never any balls, because they were never there to find).
local function find_ball_in_bag()
    for _, ballId in ipairs(BALL_ITEM_IDS) do
        for i = 0, 11 do
            local itemId = memory.readbyte(wBallsAddr + i * 2)
            if itemId == 0xFF then break end
            if itemId == ballId then
                return ballId
            end
        end
    end
    return nil
end

-- Total balls remaining across ALL ball types combined (Poke + Great +
-- Ultra + Master), not just whichever one is currently being thrown.
-- Only actually gets low once every other type is exhausted, given
-- BALL_ITEM_IDS' priority order works through them one at a time - so
-- this naturally reflects "how many balls are left overall" rather
-- than false-alarming just because one specific early-priority type
-- ran out while others remain.
local function total_ball_count()
    local total = 0
    for i = 0, 11 do
        local itemId = memory.readbyte(wBallsAddr + i * 2)
        if itemId == 0xFF then break end
        if is_ball_item(itemId) then
            total = total + memory.readbyte(wBallsAddr + i * 2 + 1)
        end
    end
    return total
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
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return false
        end
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
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return false
        end
        if memory.readbyte(species_addr) == 0 then
            return false
        end
    end

    -- Balls live in their own pocket, one or two Right presses over
    -- from the Items pocket the menu opens into by default - BUT the
    -- menu remembers its last position across throws, so on a retry
    -- we're often already sitting on the Balls pocket from the
    -- previous attempt. Confirmed via direct observation: pressing
    -- Right unconditionally in that case overshoots straight past
    -- Balls into Key Items and even a third pocket (TM/Battle Items)
    -- beyond that. Check first, and only switch pockets if we're not
    -- already there.
    local landedOnBalls = is_ball_item(memory.readbyte(wCurItemAddr))
    for presses = 1, 3 do
        if landedOnBalls then break end
        press_button("Right")
        for i = 1, 15 do
            emu.frameadvance()
            if stop_was_requested() then
                print("Catch-mode: Stop requested - aborting.")
                return false
            end
            if memory.readbyte(species_addr) == 0 then
                return false
            end
        end
        local curItem = memory.readbyte(wCurItemAddr)
        if is_ball_item(curItem) then
            landedOnBalls = true
            break
        end
    end

    local scrollAttempts = 0
    while scrollAttempts < 12 and memory.readbyte(species_addr) ~= 0 do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return false
        end
        local curItem = memory.readbyte(wCurItemAddr)
        -- Fall back to whatever ball is actually visible if the
        -- specific target can't be found - handles a disagreement
        -- between our own bag-scan (wBallsAddr) and the live menu
        -- display (wCurItem), confirmed via direct observation right
        -- after the last ball of a stack gets used (the scan correctly
        -- sees it's gone, but the menu still shows it briefly) - any
        -- valid ball actually on screen is better than getting stuck.
        if curItem == ballId or is_ball_item(curItem) then
            press_button("A")
            -- Selecting the ball opens a Use/Quit-style submenu. Give
            -- it a moment to appear, then let the caller's confirm-loop
            -- press A directly - confirmed via direct diagnostic data
            -- that the cursor is ALREADY correctly on "Use" every time
            -- this submenu opens (cursorY=1 cursorX=1, consistently
            -- across every successful throw). No cursor adjustment
            -- needed at all; an earlier "defensive" Up press here was
            -- actually the bug - if this is a wrapping 2-option menu,
            -- pressing Up while already on the top option would cycle
            -- straight to Quit instead of staying on Use.
            for i = 1, 20 do
                emu.frameadvance()
                if memory.readbyte(species_addr) == 0 then return true end
            end
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
-- Require BOTH species_addr AND enemy_hp_addr to agree the enemy is
-- gone before trusting it as a genuine faint. species_addr alone
-- proved unreliable even with a 10-frame confirmation window (confirmed:
-- still false-positived on a Pokemon the user could see was still at
-- meaningful HP) - enemy_hp_addr reading 0 is a more direct signal of
-- an actual faint, less likely to share whatever specifically affects
-- species_addr during this window.
local function do_catch_attack_turn()
    local nav_attempts = 0
    while have_battle_controls do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return "stuck"
        end
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)
        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            moveSelectScreenOpen = false
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

    -- Wait for the move-select submenu to actually be open before doing
    -- anything else. When MoveSelectionAddr is available (see its
    -- definition above - a verified pokecrystal.sym/pokegold.sym
    -- symbol lookup), this is a real, address-confirmed signal instead
    -- of a guess: moveSelectScreenOpen only becomes true once the
    -- MoveSelectionScreen ROM routine itself has actually been entered,
    -- so there's no more ambiguity between "still on the top-level
    -- FIGHT/PACK/RUN menu" and "genuinely in the submenu" - PACK_CURSOR
    -- and MOVE2_CURSOR sharing the coordinate {y=2,x=1} stops mattering
    -- once we know for certain which menu is showing. Falls back to the
    -- old fixed 60-frame wait if this hook isn't set up for the current
    -- game version/region (still relies on the cursor disambiguation
    -- probe further below in that case).
    if MoveSelectionAddr then
        local moveSelectWaitFrames = 0
        while not moveSelectScreenOpen and moveSelectWaitFrames < 90
          and memory.readbyte(species_addr) ~= 0 do
            emu.frameadvance()
            moveSelectWaitFrames = moveSelectWaitFrames + 1
        end
        -- Short extra settle after the hook fires: confirmed via
        -- pokecrystal.sym that MoveSelectionScreen's cursor-reset-to-
        -- default logic (the .got_default_coord sub-label) is further
        -- into the routine than its entry point, which is where this
        -- hook fires. Reading MENU_CURSOR_Y/X immediately can catch a
        -- STALE value left over from earlier in the same battle (e.g.
        -- a leftover (2,1) from a previous successful second-move
        -- selection), before the routine's own init code has
        -- overwritten it with the real default. A real user report
        -- (screenshots) showed exactly this failure mode: the bot's
        -- navigate_to_menu_option() saw the stale (2,1), concluded it
        -- was "already on the second move", and pressed A immediately
        -- instead of Down - but the screen had actually reset to move 1
        -- (Peck, at 0 PP), so it kept hitting "There's no PP left for
        -- this move!" and retrying forever instead of ever really
        -- moving to Tackle.
        for i = 1, 15 do
            emu.frameadvance()
        end
    else
        for i = 1, 60 do
            emu.frameadvance()
        end
    end

    -- Prefer the first move, but fall back to the second if the first
    -- is out of PP (see MOVE2_CURSOR's definition above for the
    -- caveat on this). The caller already confirmed at least one of
    -- the two has PP before calling this function at all.
    local usedSecondMove = false
    if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 then
        usedSecondMove = true
        vprint("First move out of PP - using the second move instead")
        press_and_wait_for_cursor_change(navigate_to_menu_option(MOVE2_CURSOR), 30)
        -- Confirmed via a real user report: this can legitimately fail
        -- even when nothing's wrong - a status condition (confusion
        -- self-hit, sleep, etc.) can skip the move-select screen
        -- entirely for a turn, so the cursor never moves (there's no
        -- menu to navigate). That looks identical to a real navigation
        -- bug. Blindly pressing A here would risk re-selecting move 1
        -- (still on 0 PP) if a menu genuinely IS showing and just
        -- failed to move - so back out with B instead (safe either
        -- way: cancels a stuck menu without confirming anything, or
        -- just advances whatever status message is showing) and let
        -- the next tick retry from scratch. Only escalate to a real
        -- stop if this keeps happening far more than any normal status
        -- condition would.
        --
        -- curItemDiag (wCurItemAddr, diagnostic-only, doesn't affect
        -- behavior) is logged alongside every outcome below because the
        -- PACK/MOVE2_CURSOR coordinate collision (see above) means a
        -- cursor-only check can't fully distinguish "confirmed on the
        -- second move" from "confirmed on PACK" - if this keeps
        -- happening, this value across a real failure will show whether
        -- it's actually landing on PACK (a real bag item ID) versus
        -- something else entirely.
        local curItemDiag = memory.readbyte(wCurItemAddr)
        local cy2, cx2 = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
        if cy2 ~= MOVE2_CURSOR.y or cx2 ~= MOVE2_CURSOR.x then
            move2NavFailStreak = move2NavFailStreak + 1
            if move2NavFailStreak >= 25 then
                print(string.format("Catch-mode: couldn't navigate to the second move %d times in a row (cursor at %d,%d, expected %d,%d, wCurItem=%d) - stopping so you can handle this manually.",
                    move2NavFailStreak, cy2, cx2, MOVE2_CURSOR.y, MOVE2_CURSOR.x, curItemDiag))
                return "move2_stuck"
            end
            vprint(string.format("Couldn't confirm the cursor reached the second move (at %d,%d, expected %d,%d, wCurItem=%d) - likely a status condition skipped move selection this turn. Backing out safely and retrying.",
                cy2, cx2, MOVE2_CURSOR.y, MOVE2_CURSOR.x, curItemDiag))
            press_button("B")
            return
        end
        -- Confirmed via repeated real-world reports: reaching this
        -- coordinate is NOT proof of reaching the second move.
        -- PACK_CURSOR and MOVE2_CURSOR are the identical coordinate
        -- {y=2,x=1} (see MOVE2_CURSOR's definition above) - the bot has
        -- been directly observed pressing Down too early, before the
        -- move-select submenu actually opened, landing on PACK in the
        -- still-showing top-level menu instead, then pressing A there
        -- and getting stuck looping in and out of the PACK menu instead
        -- of attacking.
        --
        -- Skipped entirely when moveSelectScreenOpen is already true -
        -- that's a real, address-confirmed signal (see MoveSelectionAddr
        -- above) that we're genuinely in the submenu, no guessing
        -- needed. Confirmed via a real user report that this probe
        -- itself is unreliable enough to false-negative even when
        -- moveSelectScreenOpen already proved we were in the right
        -- menu (an unnecessary "backing out safely and retrying" right
        -- after the hook had just fired) - trust the hook over the
        -- probe whenever it's available.
        --
        -- Otherwise (no hook confirmation this attempt - either
        -- MoveSelectionAddr isn't set for this game version, or it
        -- genuinely didn't fire in time), disambiguate using the
        -- move-select submenu's actual shape: a single-column list with
        -- exactly as many rows as the Pokemon has moves
        -- (get_active_mon_move_count() reads the confirmed
        -- wPartyMon1Moves offset). Only the submenu can have a 3rd row
        -- - the top-level FIGHT/PKMN/PACK/RUN menu is always exactly 2
        -- rows (RUN_CURSOR = {y=2,x=2} confirms row 2 is the last one).
        -- So if this Pokemon knows 3+ moves, pressing Down once more
        -- and landing on row 3 proves we're really in the submenu;
        -- landing anywhere else means we're still on the top-level menu
        -- with the cursor sitting on PACK, not the second move. Skipped
        -- for Pokemon with only 2 known moves, since the submenu itself
        -- would only have 2 rows there and a "row 3" probe couldn't
        -- distinguish anything - falls back to trusting the coordinate
        -- alone for that case, same as before this check existed.
        local confirmedSubmenu = true
        if not moveSelectScreenOpen and get_active_mon_move_count() >= 3 then
            press_and_wait_for_cursor_change("Down", 30)
            local cy3, cx3 = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
            if cy3 == 3 and cx3 == 1 then
                press_and_wait_for_cursor_change("Up", 30)
            else
                confirmedSubmenu = false
            end
        end
        if not confirmedSubmenu then
            move2NavFailStreak = move2NavFailStreak + 1
            if move2NavFailStreak >= 25 then
                print(string.format("Catch-mode: cursor keeps reading %d,%d (the second move's coordinate) but failed to confirm it's really the move-select submenu and not PACK, %d times in a row - stopping so you can handle this manually.",
                    cy2, cx2, move2NavFailStreak))
                return "move2_stuck"
            end
            vprint(string.format("Cursor reads %d,%d but couldn't confirm it's really the second move and not PACK - backing out safely and retrying.", cy2, cx2))
            press_button("B")
            return
        end
        move2NavFailStreak = 0
    else
        -- Move 1 still has PP - a fresh battle/PP situation, so any
        -- past move-2 navigation failures are no longer relevant.
        move2NavFailStreak = 0
    end
    press_button("A")

    -- No species_addr OR enemy_hp_addr checks during this wait -
    -- confirmed via direct evidence (twice now) that BOTH signals can
    -- go unreliable during this window: species_addr via a screenshot
    -- showing the ENEMY's own turn ("Enemy VENONAT identified"), and
    -- enemy_hp_addr via a direct false "fainted" report on a Pokemon
    -- genuinely still at 60% HP (stably reading 0 for 10+ consecutive
    -- frames, not a brief blip). Neither signal is trustworthy here,
    -- so don't try to positively detect a faint at all during this
    -- wait - just wait for have_battle_controls with a bounded
    -- timeout, and let the caller treat a timeout as "something's
    -- wrong, stop and let the user check" either way, whether that's a
    -- genuine faint or something else - a timeout is always handled
    -- safely, so there's no need to guess which one it was here.
    have_battle_controls = false
    local postAttackWait = 0
    -- Confirmed via a real user report: the second-move fallback can
    -- time out at the normal budget on a confused turn. Give it
    -- significantly more room before giving up, since that's
    -- specifically where this has been observed - move 1 has been
    -- reliable every time, so its timeout is left as-is.
    local postAttackTimeout = usedSecondMove and 1800 or 600
    -- NOTE: a cursor-position-based backup for have_battle_controls was
    -- tried here and REMOVED after a confirmed real-world failure - see
    -- the full explanation in do_kill_turn above. MOVE2_CURSOR and
    -- PACK_CURSOR share the same coordinate, so "the cursor changed"
    -- can't safely mean "back at the top menu"; a false positive let a
    -- later turn misfire and open the BAG mid-battle. Relying on the
    -- hook plus the plain timeout fails SAFELY instead.
    while not have_battle_controls do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return "stuck"
        end
        emu.frameadvance()
        press_button("A")
        postAttackWait = postAttackWait + 1
        if postAttackWait > postAttackTimeout then
            print("Catch-mode: post-attack wait timed out (enemy may have fainted, or something else is blocking)")
            return "stuck"
        end
    end

    return "ok"
end

local CATCH_HP_TARGET_PERCENT = 0.40

-- shinyEmbedFields/shinySpriteUrl (optional): the detailed fields built
-- in M.step()'s pendingEncounterUpdate handling for THIS same shiny
-- encounter (DVs, Hidden Power, Location, stats - see
-- send_pending_shiny_embed). When present, the initial "found!
-- attempting to catch" notification below uses these instead of the
-- lean send_catch_notification fields, so the detailed info that used
-- to arrive as its own separate embed is now merged into this first
-- message - confirmed via a real user report/screenshot that a
-- successful shiny auto-catch previously sent 3 Discord messages (lean
-- "found/attempting", lean "caught successfully", and a redundant
-- detailed "Shiny Found!" sandwiched after both) - this keeps it to 2.
local function do_catch_sequence(isShiny, shinyEmbedFields, shinySpriteUrl)
    local label = isShiny and "Shiny " or ""
    print(label .. "found! Starting auto-catch sequence...")

    -- Captured here, early, while species_addr is still known-reliable
    -- (right after confirming the encounter) - by the time the catch
    -- succeeds and the battle has fully ended, species_addr would
    -- already read 0, too late to use for later notifications.
    local caughtSpeciesId = memory.readbyte(species_addr)
    local caughtSpeciesName = get_pokemon_name(caughtSpeciesId)
    -- Same early-capture reasoning as species above - item_addr is also
    -- only reliable this early in the encounter.
    local caughtItemName = get_item_name(memory.readbyte(item_addr))

    if isShiny and shinyEmbedFields then
        send_discord_embed(string.format("%s%s found! Attempting to catch it automatically.", label, caughtSpeciesName),
            nil, shinyEmbedFields, COLOR_GOLD, shinySpriteUrl)
    else
        send_catch_notification(string.format("%s%s found! Attempting to catch it automatically.", label, caughtSpeciesName), COLOR_GOLD, caughtSpeciesId, isShiny, caughtItemName)
    end

    -- Unlike do_kill_turn() (which is naturally only reached after
    -- enough frames have passed for have_battle_controls to already be
    -- true), this fires immediately and synchronously the instant
    -- shinyvalue==1 is detected - potentially before the battle menu
    -- has had any chance to load at all. Wait for it explicitly.
    -- No species_addr check here deliberately - we just confirmed a
    -- genuine shiny encounter moments ago, and haven't even reached the
    -- battle menu to act yet, so there's no legitimate way for the
    -- battle to actually end during this specific window. Checking it
    -- here only picked up a transient dip (confirmed: it read 0 for
    -- well over 5 consecutive frames right as the encounter started,
    -- despite the Pokemon genuinely still being there) rather than a
    -- real signal - so just wait for have_battle_controls and nothing else.
    local waitFrames = 0
    while not have_battle_controls and waitFrames < 300 do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return true
        end
        press_button("B")
        waitFrames = waitFrames + 1
    end
    if not have_battle_controls then
        print("Catch-mode: battle menu never loaded within the timeout - stopping so you can take over.")
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu timeout).", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return true
    end

    -- species_addr can still be oscillating between 0 and the real
    -- species ID for a while even as have_battle_controls first
    -- becomes true (confirmed via direct observation - fluctuating for
    -- 90+ frames before settling) - do_kill_turn() never hits this
    -- because it's naturally only reached much later, giving it plenty
    -- of time to settle first. Give it that same settling time here
    -- explicitly, rather than trusting species_addr immediately and
    -- risking a false "fainted" read on a Pokemon that's still at full
    -- health, as happened before this fix.
    for i = 1, 60 do
        emu.frameadvance()
    end

    local ballId = find_ball_in_bag()
    if not ballId then
        print("No balls in the bag - stopping so you can restock and catch it manually.")
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (no balls left).", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return true
    end

    -- Weaken the enemy to a safe-but-catchable HP range first, since
    -- Gen 2's catch formula weights heavily on current HP - throwing
    -- balls at full HP wastes far more of them on average. Checks HP
    -- after EVERY attack, not periodically, to minimize the window
    -- where an over-leveled hit could overshoot straight to a faint.
    --
    -- Skippable entirely via "Don't weaken enemy Pokemon" in Auto-Catch
    -- Settings - goes straight to the ball-throwing phase below at
    -- whatever HP the encounter started at. Pure risk/ball-count
    -- tradeoff (more balls used on average, but zero chance of an
    -- attack-turn faint/crit costing the catch outright) - no
    -- interaction with DVs or catch legality either way, so safe to
    -- gate on nothing but this one checkbox.
    if not Gui.dont_weaken_enabled(hud) then
    local lastDamageDealt = nil
    local previousHP = nil
    local overrideCritSafety = Gui.crit_safety_override_enabled(hud)
    local targetPercent = overrideCritSafety and Gui.custom_catch_hp_target(hud) or CATCH_HP_TARGET_PERCENT
    while true do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return true
        end
        local curHP = memory.read_u16_be(enemy_hp_addr)
        local maxHP = memory.read_u16_be(enemy_max_hp_addr)
        if maxHP == 0 then
            print("Catch-mode: couldn't read enemy max HP - stopping so you can catch it manually.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (couldn't read enemy max HP).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end
        if previousHP ~= nil and curHP < previousHP then
            lastDamageDealt = previousHP - curHP
        end
        if curHP <= maxHP * targetPercent then
            break
        end
        -- Predictive safety check: if another hit anywhere near the
        -- size of the last one (doubled, to account for a possible
        -- critical hit) would drop HP to 0 or below, stop attacking
        -- now and start throwing balls instead - even though curHP is
        -- still technically above the nominal target threshold. Losing
        -- the shiny to an unlucky crit is worse than catching it a bit
        -- above the ideal HP window. Skipped entirely when the user has
        -- explicitly opted into the crit-safety override, accepting
        -- more risk in exchange for fewer wasted balls on a less
        -- valuable catch.
        if not overrideCritSafety and lastDamageDealt ~= nil and curHP <= lastDamageDealt * 2 then
            print(string.format("Catch-mode: another hit (possible crit) could faint the target (curHP=%d, last hit dealt %d) - stopping attacks early.",
                curHP, lastDamageDealt))
            break
        end
        if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 and memory.readbyte(FIRST_MOVE_PP_ADDR + 1) == 0 then
            -- Confirmed via a real user report: attacking with a
            -- depleted move triggers the game's "No PP left!" message
            -- instead of an actual attack - no damage is dealt and the
            -- battle doesn't end, but the unexpected menu state then
            -- confused the stuck/faint detection below into reporting a
            -- false faint. Worse, since the real battle was still going,
            -- resuming the hunt (the normal false-faint recovery path
            -- below) immediately re-encountered the SAME still-alive
            -- shiny, looping "found! -> not caught, fainted" forever and
            -- spamming Discord every cycle. do_catch_attack_turn()
            -- already falls back to the second move if only the first
            -- is depleted (see MOVE2_CURSOR above) - this only stops the
            -- bot once BOTH of the first two moves are out of PP,
            -- before ever pressing A on either depleted slot - same
            -- "let the user take over" pattern as the "no balls in the
            -- bag" case above.
            print(string.format("Catch-mode: out of PP on the first two moves while weakening %s - stopping so you can handle this manually.", caughtSpeciesName))
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (out of PP on first two moves).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end
        previousHP = curHP
        local result = do_catch_attack_turn()
        if result == "fainted" then
            print(string.format("%s%s fainted while weakening it for capture - it's gone. Clearing messages and resuming the hunt.", label, caughtSpeciesName))
            send_catch_notification(string.format("%s%s was not caught, most likely fainted.", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            for i = 1, 400 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return true
                end
                press_button("B")
            end
            return false
        elseif result == "stuck" then
            -- Most likely a genuine faint - have_battle_controls only
            -- fails to return if the battle ended entirely, which for
            -- the weaken phase almost always means the wild Pokemon
            -- fainted. Unfortunate (this specific shiny is lost), but
            -- not a reason to stop the whole bot - clear the post-faint
            -- messages and get back to hunting.
            print("Catch-mode: got stuck while weakening the enemy (likely fainted) - clearing messages and resuming the hunt.")
            send_catch_notification(string.format("%s%s was not caught, most likely fainted.", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            for i = 1, 400 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return true
                end
                press_button("B")
            end
            return false
        elseif result == "move2_stuck" then
            -- NOT the same as "stuck" above - this means the second-move
            -- navigation itself failed (the cursor didn't land where
            -- expected), a real bug rather than a presumed faint.
            -- Resuming the hunt here would just walk back into the exact
            -- same battle and hit the identical navigation failure next
            -- turn, looping forever - so stop the bot entirely instead.
            print(string.format("Catch-mode: stopping bot - couldn't reliably use the second move on %s.", caughtSpeciesName))
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (second-move navigation failed).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end
    end
    end

    -- Throw balls until caught, or we run out.
    local maxThrows = 20
    local throws = 0
    local LOW_BALL_THRESHOLD = 3
    while throws < maxThrows do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return true
        end
        ballId = find_ball_in_bag()
        if not ballId then
            print("Ran out of balls mid-catch - stopping so you can restock and finish manually.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (ran out of balls mid-catch).", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end

        -- Stop BEFORE using one of the last few balls (combined across
        -- every ball type, not just whichever is currently being
        -- thrown) - preserves them for manual catching (status
        -- effects, etc) rather than throwing straight down to zero.
        local remainingBalls = total_ball_count()
        if remainingBalls <= LOW_BALL_THRESHOLD then
            print(string.format("Catch-mode: only %d ball(s) left total - stopping so you can finish manually.", remainingBalls))
            send_catch_notification(string.format(
                "%s%s could not be caught, bot stopped (only %d ball(s) left, preserved for manual catching).", label, caughtSpeciesName, remainingBalls),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end

        local navigated = navigate_to_pack_and_select_ball(ballId)
        if not navigated then
            print("Catch-mode: failed to navigate to the ball - stopping so you can take over.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (navigation stuck).", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end

        -- Use the precise, verified catch-outcome hooks
        -- (PokeBallEffect.caught / .shake_and_break_free) instead of
        -- guessing from species_addr/have_battle_controls - those
        -- proved capable of reading stably WRONG for 400+ consecutive
        -- frames during this exact transition (confirmed via direct
        -- observation), making any heuristic built on them fundamentally
        -- unreliable. These hooks fire exactly when the game itself
        -- determines the outcome, so no guessing is needed at all.
        catchOutcomeSucceeded = false
        catchOutcomeFailed = false
        local waitFrames = 0
        while not catchOutcomeSucceeded and not catchOutcomeFailed and waitFrames < 1200 do
            if stop_was_requested() then
                print("Catch-mode: Stop requested - aborting.")
                return true
            end
            press_button("A")
            for i = 1, 15 do
                emu.frameadvance()
            end
            waitFrames = waitFrames + 20
        end

        if catchOutcomeSucceeded then
            -- Battle ended - the catch succeeded. Press through the
            -- nickname prompt (declining it), the Pokedex registration
            -- text, and any "sent to a Box" message if the party was
            -- already full (automatic in Gen 2), then hand off to the
            -- normal M.step() overworld-detection flow, which is
            -- already proven for every other battle-end scenario in
            -- this project (escapes, kills, etc).
            print("Caught! Declining nickname prompt and clearing follow-up messages...")
            if isShiny then
                Stats.record_catch(caughtSpeciesId)
            end
            send_catch_notification(string.format("%s%s caught successfully via auto-catch!", label, caughtSpeciesName), COLOR_GREEN, caughtSpeciesId, isShiny, caughtItemName)
            for i = 1, 400 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return true
                end
                press_button("B")
            end
            print("Resuming the hunt.")
            return false
        elseif catchOutcomeFailed then
            throws = throws + 1
            print(string.format("Ball thrown (%d/%d) - it broke free, trying again.", throws, maxThrows))
            -- The hook fires the instant the game decides the outcome,
            -- but the "It broke free!" text still needs to visibly play
            -- out and the main battle menu needs to actually reload
            -- before navigating to Pack makes sense - wait for that here.
            have_battle_controls = false
            local recoverFrames = 0
            while not have_battle_controls and recoverFrames < 300 do
                press_button("A")
                recoverFrames = recoverFrames + 1
            end
        else
            -- Neither hook fired within the timeout - genuinely stuck
            -- somewhere (not a determined outcome either way). Back out
            -- with B and retry.
            print("Catch-mode: timed out without a determined outcome - backing out with B and retrying.")
            for i = 1, 10 do
                press_button("B")
                if have_battle_controls then break end
            end
            throws = throws + 1
        end
    end

    print("Ran out of throw attempts (" .. maxThrows .. ") without catching it - stopping so you can take over.")
    send_catch_notification(string.format("%s%s could not be caught, bot stopped (ran out of throw attempts).", label, caughtSpeciesName), COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
    return true
end

local function do_kill_turn()
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)

        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            vprint("Pressing A to select FIGHT")
            moveSelectScreenOpen = false
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

    -- Wait for the move-select submenu to actually be open before doing
    -- anything else. When MoveSelectionAddr is available (see its
    -- definition above - a verified pokecrystal.sym/pokegold.sym
    -- symbol lookup), this is a real, address-confirmed signal instead
    -- of a guess: moveSelectScreenOpen only becomes true once the
    -- MoveSelectionScreen ROM routine itself has actually been entered,
    -- so there's no more ambiguity between "still on the top-level
    -- FIGHT/PACK/RUN menu" and "genuinely in the submenu" - PACK_CURSOR
    -- and MOVE2_CURSOR sharing the coordinate {y=2,x=1} stops mattering
    -- once we know for certain which menu is showing. Falls back to the
    -- old fixed 60-frame wait if this hook isn't set up for the current
    -- game version/region (still relies on the cursor disambiguation
    -- probe further below in that case).
    if MoveSelectionAddr then
        local moveSelectWaitFrames = 0
        while not moveSelectScreenOpen and moveSelectWaitFrames < 90
          and memory.readbyte(species_addr) ~= 0 do
            emu.frameadvance()
            moveSelectWaitFrames = moveSelectWaitFrames + 1
        end
        -- Short extra settle after the hook fires: confirmed via
        -- pokecrystal.sym that MoveSelectionScreen's cursor-reset-to-
        -- default logic (the .got_default_coord sub-label) is further
        -- into the routine than its entry point, which is where this
        -- hook fires. Reading MENU_CURSOR_Y/X immediately can catch a
        -- STALE value left over from earlier in the same battle (e.g.
        -- a leftover (2,1) from a previous successful second-move
        -- selection), before the routine's own init code has
        -- overwritten it with the real default. A real user report
        -- (screenshots) showed exactly this failure mode: the bot's
        -- navigate_to_menu_option() saw the stale (2,1), concluded it
        -- was "already on the second move", and pressed A immediately
        -- instead of Down - but the screen had actually reset to move 1
        -- (Peck, at 0 PP), so it kept hitting "There's no PP left for
        -- this move!" and retrying forever instead of ever really
        -- moving to Tackle.
        for i = 1, 15 do
            emu.frameadvance()
            if memory.readbyte(species_addr) == 0 then return end
        end
    else
        for i = 1, 60 do
            emu.frameadvance()
            if memory.readbyte(species_addr) == 0 then return end
        end
    end

    -- Prefer the first move, but fall back to the second if the first
    -- is out of PP (see MOVE2_CURSOR's definition above for the
    -- caveat on this). The caller already confirmed at least one of
    -- the two has PP before deciding to kill at all.
    local usedSecondMove = false
    if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 then
        usedSecondMove = true
        vprint("First move out of PP - using the second move instead")
        press_and_wait_for_cursor_change(navigate_to_menu_option(MOVE2_CURSOR), 30)
        -- Confirmed via a real user report: this can legitimately fail
        -- even when nothing's wrong - a status condition (confusion
        -- self-hit, sleep, etc.) can skip the move-select screen
        -- entirely for a turn, so the cursor never moves (there's no
        -- menu to navigate). That looks identical to a real navigation
        -- bug. Blindly pressing A here would risk re-selecting move 1
        -- (still on 0 PP) if a menu genuinely IS showing and just
        -- failed to move - so back out with B instead (safe either
        -- way: cancels a stuck menu without confirming anything, or
        -- just advances whatever status message is showing), same as
        -- the existing FIGHT-navigation-stuck case above, and let the
        -- next tick retry from scratch. Only escalate to a real stop
        -- if this keeps happening far more than any normal status
        -- condition would.
        --
        -- curItemDiag (wCurItemAddr, diagnostic-only, doesn't affect
        -- behavior) is logged alongside every outcome below because the
        -- PACK/MOVE2_CURSOR coordinate collision (see above) means a
        -- cursor-only check can't fully distinguish "confirmed on the
        -- second move" from "confirmed on PACK" - if this keeps
        -- happening, this value across a real failure will show whether
        -- it's actually landing on PACK (a real bag item ID) versus
        -- something else entirely.
        local curItemDiag = memory.readbyte(wCurItemAddr)
        local cy2, cx2 = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
        if cy2 ~= MOVE2_CURSOR.y or cx2 ~= MOVE2_CURSOR.x then
            move2NavFailStreak = move2NavFailStreak + 1
            if move2NavFailStreak >= 25 then
                print(string.format("Kill-mode: couldn't navigate to the second move %d times in a row (cursor at %d,%d, expected %d,%d, wCurItem=%d) - stopping so you can handle this manually.",
                    move2NavFailStreak, cy2, cx2, MOVE2_CURSOR.y, MOVE2_CURSOR.x, curItemDiag))
                return "stuck"
            end
            vprint(string.format("Couldn't confirm the cursor reached the second move (at %d,%d, expected %d,%d, wCurItem=%d) - likely a status condition skipped move selection this turn. Backing out safely and retrying.",
                cy2, cx2, MOVE2_CURSOR.y, MOVE2_CURSOR.x, curItemDiag))
            press_button("B")
            return
        end
        -- Confirmed via repeated real-world reports: reaching this
        -- coordinate is NOT proof of reaching the second move.
        -- PACK_CURSOR and MOVE2_CURSOR are the identical coordinate
        -- {y=2,x=1} (see MOVE2_CURSOR's definition above) - the bot has
        -- been directly observed pressing Down too early, before the
        -- move-select submenu actually opened, landing on PACK in the
        -- still-showing top-level menu instead, then pressing A there
        -- and getting stuck looping in and out of the PACK menu instead
        -- of attacking.
        --
        -- Skipped entirely when moveSelectScreenOpen is already true -
        -- that's a real, address-confirmed signal (see MoveSelectionAddr
        -- above) that we're genuinely in the submenu, no guessing
        -- needed. Confirmed via a real user report that this probe
        -- itself is unreliable enough to false-negative even when
        -- moveSelectScreenOpen already proved we were in the right
        -- menu (an unnecessary "backing out safely and retrying" right
        -- after the hook had just fired) - trust the hook over the
        -- probe whenever it's available.
        --
        -- Otherwise (no hook confirmation this attempt - either
        -- MoveSelectionAddr isn't set for this game version, or it
        -- genuinely didn't fire in time), disambiguate using the
        -- move-select submenu's actual shape: a single-column list with
        -- exactly as many rows as the Pokemon has moves
        -- (get_active_mon_move_count() reads the confirmed
        -- wPartyMon1Moves offset). Only the submenu can have a 3rd row
        -- - the top-level FIGHT/PKMN/PACK/RUN menu is always exactly 2
        -- rows (RUN_CURSOR = {y=2,x=2} confirms row 2 is the last one).
        -- So if this Pokemon knows 3+ moves, pressing Down once more
        -- and landing on row 3 proves we're really in the submenu;
        -- landing anywhere else means we're still on the top-level menu
        -- with the cursor sitting on PACK, not the second move. Skipped
        -- for Pokemon with only 2 known moves, since the submenu itself
        -- would only have 2 rows there and a "row 3" probe couldn't
        -- distinguish anything - falls back to trusting the coordinate
        -- alone for that case, same as before this check existed.
        local confirmedSubmenu = true
        if not moveSelectScreenOpen and get_active_mon_move_count() >= 3 then
            press_and_wait_for_cursor_change("Down", 30)
            local cy3, cx3 = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
            if cy3 == 3 and cx3 == 1 then
                press_and_wait_for_cursor_change("Up", 30)
            else
                confirmedSubmenu = false
            end
        end
        if not confirmedSubmenu then
            move2NavFailStreak = move2NavFailStreak + 1
            if move2NavFailStreak >= 25 then
                print(string.format("Kill-mode: cursor keeps reading %d,%d (the second move's coordinate) but failed to confirm it's really the move-select submenu and not PACK, %d times in a row - stopping so you can handle this manually.",
                    cy2, cx2, move2NavFailStreak))
                return "stuck"
            end
            vprint(string.format("Cursor reads %d,%d but couldn't confirm it's really the second move and not PACK - backing out safely and retrying.", cy2, cx2))
            press_button("B")
            return
        end
        move2NavFailStreak = 0
        vprint("Pressing A to use second move")
    else
        -- Move 1 still has PP - a fresh battle/PP situation, so any
        -- past move-2 navigation failures are no longer relevant.
        move2NavFailStreak = 0
        vprint("Pressing A to use first move")
    end
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
    -- NOTE: a cursor-position-based backup for have_battle_controls was
    -- tried here and REMOVED after a confirmed real-world failure: on a
    -- confused turn, "the cursor moved away from where the move-select
    -- menu left it" was wrongly treated as "control is back at the top
    -- menu", but MOVE2_CURSOR {y=2,x=1} and PACK_CURSOR {y=2,x=1} are
    -- the exact same coordinate (the top-level menu and the move-select
    -- submenu share the same underlying cursor address), so there is no
    -- way to tell "back at the top menu" apart from "still in a
    -- submenu showing a different move" from the coordinate alone. The
    -- false-positive let a subsequent turn's navigation misfire and
    -- open the BAG mid-battle instead of selecting a move - confirmed
    -- via a user screenshot showing the ITEMS menu open. Relying only
    -- on the hook plus the plain timeout below is less clever but
    -- fails SAFELY (a clean stop) instead of corrupting what menu the
    -- bot thinks it's looking at.
    -- If the enemy already fainted from this attack, this window
    -- specifically risks a move-learn or evolution prompt appearing -
    -- and since we press A every single frame with no way to check
    -- what's actually being shown, that A would immediately confirm
    -- "yes, learn this move" and pick whatever move the cursor lands
    -- on to forget. Use a much shorter timeout in that case to
    -- minimize the risk window, rather than the full budget used when
    -- the enemy is still alive (where there's no such risk at all).
    local enemyFainted = memory.read_u16_be(enemy_hp_addr) == 0
    -- Confirmed via a real user report: the second-move fallback can
    -- time out at the normal budget on a confused turn. Give it
    -- significantly more room before giving up, since that's
    -- specifically where this has been observed - move 1 has been
    -- reliable every time, so its timeout is left as-is.
    local postAttackTimeout = enemyFainted and 300 or (usedSecondMove and 1800 or 600)
    if battleLevelBaseline == nil then
        battleLevelBaseline = get_active_mon_level()
        battleLevelBaselineSpecies = get_active_mon_species()
        battleLevelBaselineMoveCount = get_active_mon_move_count()
    end
    local levelBeforeAttack = battleLevelBaseline
    local activeSpecies = battleLevelBaselineSpecies
    local confirmedHigherLevelFrames = 0
    local lastSeenLevel = get_active_mon_level()
    local ownFaintConfirmedFrames = 0
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        -- Own Pokemon fainting mid-turn (confusion hitting itself,
        -- recoil, etc.) throws the battle into a "send out next
        -- Pokemon" or whiteout prompt that blind A-mashing can't
        -- safely resolve - it could confirm sending out whichever
        -- party member the cursor happens to be on. Confirmed via a
        -- real user report: a confusion status during the second-move
        -- fallback led to exactly this kind of stuck loop. Require 3
        -- consecutive confirmed-0 frames before trusting it, same
        -- pattern as the level-up check below, to rule out a single
        -- bad read.
        local ownHP = memory.read_u16_be(OWN_HP_ADDR)
        if ownHP == 0 then
            ownFaintConfirmedFrames = ownFaintConfirmedFrames + 1
        else
            ownFaintConfirmedFrames = 0
        end
        if ownFaintConfirmedFrames >= 3 then
            print("Kill-mode: your own Pokemon appears to have fainted mid-turn (confusion self-hit, recoil, etc.) - stopping so you can send out a replacement manually.")
            return "stuck"
        end
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
                print(string.format("Stuck after attacking for %d+ frames (likely a move-learn or evolution prompt) - stopping so you can handle it manually", postAttackTimeout))
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
local WATCHDOG_SECONDS = 30
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
--
-- Same two-tier approach as the overworld stuck check: the first
-- crossing of BATTLE_WATCHDOG_SECONDS (and every BATTLE_WATCHDOG_SECONDS
-- after that, while still stalled) prints to console and tries the A/B
-- recovery, quietly - no Discord yet. Only once the SAME battle has
-- been stalled for the much longer BATTLE_WATCHDOG_DISCORD_SECONDS does
-- a single Discord alert fire, since by then recovery attempts clearly
-- aren't working and it's genuinely likely stuck.
local BATTLE_WATCHDOG_SECONDS = 15
local BATTLE_WATCHDOG_DISCORD_SECONDS = 120
local battleWatchdogStartTime = nil
local battleWatchdogNextCheckTime = nil
local battleWatchdogDiscordSent = false
local battleWatchdogLastDiagnostic = nil

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

    if CatchSuccessAddr then
        Mem.RegisterROMHook(CatchSuccessAddr, function()
            if ActiveModuleName ~= "wild" then return end
            catchOutcomeSucceeded = true
            vprint("PokeBallEffect.caught entered - the catch definitely succeeded")
        end, "Detect Catch Success")
    end

    if CatchFailAddr then
        Mem.RegisterROMHook(CatchFailAddr, function()
            if ActiveModuleName ~= "wild" then return end
            catchOutcomeFailed = true
            vprint("PokeBallEffect.shake_and_break_free entered - the Pokemon definitely broke free")
        end, "Detect Catch Failure")
    end

    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "wild" then return end
        have_battle_controls = true
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    if MoveSelectionAddr then
        Mem.RegisterROMHook(MoveSelectionAddr, function()
            if ActiveModuleName ~= "wild" then return end
            moveSelectScreenOpen = true
            vprint("MoveSelectionScreen entered - move-select submenu confirmed open")
        end, "Detect Move Select Screen")
    end

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
            -- Verified against pokecrystal.sym: PokeBallEffect.caught
            -- and PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            -- Verified against pokecrystal.sym: MoveSelectionScreen,
            -- bank $0F.
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            -- Verified against pokecrystal.sym: PokeBallEffect.caught
            -- and PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            -- Verified against pokecrystal.sym: PokeBallEffect.caught
            -- and PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
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
            -- Verified against pokegold.sym: PokeBallEffect.caught and
            -- PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            -- Verified against pokegold.sym: MoveSelectionScreen,
            -- bank $0F.
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x45 then
            print("USA Gold/Silver detected")
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            -- Verified against pokegold.sym: PokeBallEffect.caught and
            -- PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
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
            -- Verified against pokegold.sym: PokeBallEffect.caught and
            -- PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            print("KOR Gold/Silver detected")
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1)
            -- Verified against pokegold.sym: PokeBallEffect.caught and
            -- PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
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
        wBallsAddr = 0xD5FD
        wNumBallsAddr = 0xD5FC
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
        wBallsAddr = 0xD8D8
        wNumBallsAddr = 0xD8D7
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
    nextStuckRecoveryTime = nil
    stuckDiscordSent = false
    stopRequested = false
    stopReason = ""
    shinyvalue = 0
    learnMovePromptDetected = false
end

function M.step()
    check_stuck_and_notify()

    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick so the
    -- displayed location always reflects wherever you're actually
    -- standing right now, not just a snapshot from the last encounter.
    --
    -- Only updates when the (group, number) pair is a RECOGNIZED
    -- location - confirmed via a user report that during a battle these
    -- two WRAM bytes can transiently read as nonsense (e.g. "Map Group
    -- 15, #228", not a real place), presumably that RAM getting
    -- momentarily repurposed for battle-only data. Skipping the update
    -- on an unrecognized pair just keeps showing the last real location
    -- instead of flashing garbage on the Rich Presence card.
    do
        local mapKey = string.format("%d:%d", memory.readbyte(0xdcb5), memory.readbyte(0xdcb6))
        if LocationNames[mapKey] then
            AutocrystalCurrentLocation = LocationNames[mapKey]
        end
    end

    if pendingEncounterUpdate then
        pendingEncounterUpdate = false

        -- NOTE: a "wait for dv_flag_addr, then re-read atkdef/spespc and
        -- recompute shininess" step was tried here across the last two
        -- fixes and REVERTED after confirmed real-world evidence (a user
        -- screenshot showing the console's encounter line - printed
        -- straight from the ROM hook's IMMEDIATE atkdef/spespc read -
        -- correct in every one of 8 consecutive encounters, while the
        -- GUI's Recent Encounters history - built from the re-read value
        -- added here - showed 0/0/0/0 in 7 of those same 8. That proves
        -- the ORIGINAL theory backwards: the hook's immediate read is
        -- the reliable one; whatever dv_flag_addr actually signals, by
        -- the time it flips (or this wait times out) enemy_addr's bytes
        -- are no longer valid DV data - probably repurposed for
        -- something else once the battle actually gets moving. Waiting
        -- and re-reading was therefore actively replacing good data with
        -- bad. Reverted back to trusting atkdef/spespc/shinyvalue exactly
        -- as the hook set them. The original bug this was chasing (the
        -- encounter right after a real shiny catch sometimes getting
        -- flagged shiny too) is NOT explained by this after all - if it
        -- recurs, it needs a fresh, properly-verified diagnosis rather
        -- than another guess at what dv_flag_addr means.

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local atkDV = math.floor(atkdef / 16)
        local defDV = atkdef % 16
        local speDV = math.floor(spespc / 16)
        local spcDV = spespc % 16
        local isShinyEncounter = (shinyvalue == 1)
        Stats.record_encounter(species)

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Checking encounter...")
        Gui.update_last_encounter(hud, sessionEncounterCount, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

        -- Reset every time, BEFORE the isShinyEncounter check below, so a
        -- non-shiny encounter can never accidentally inherit a previous
        -- shiny's leftover fields (see the declaration above for why).
        pendingShinyFields = nil
        pendingShinySpriteUrl = nil

        if isShinyEncounter then
            -- Captured BEFORE Stats.record_shiny() resets this to 0, so
            -- the embed shows the real encounter count leading up to
            -- this find, not 0.
            local encountersBeforeThisShiny = Stats.encountersSinceShiny
            Stats.record_shiny(species)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "SHINY FOUND!")
            local hpType, hpPower = hidden_power(atkDV, defDV, speDV, spcDV)
            -- Re-read fresh rather than trusting the mapgroup/mapnumber
            -- Built here but NOT sent immediately - stored for whichever
            -- branch handles this encounter next (see
            -- send_pending_shiny_embed and do_catch_sequence) so a
            -- successful auto-catch doesn't ALSO get this as a separate,
            -- redundant third message.
            pendingShinyFields = {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkDV, defDV, speDV, spcDV), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                {name = "Location", value = current_location_name(), inline = true},
                {name = "Held Item", value = itemName, inline = true},
                divider_field(),
                {name = "Encounters Since Last Shiny", value = tostring(encountersBeforeThisShiny), inline = true},
                {name = "Encounters This Session", value = tostring(sessionEncounterCount), inline = true},
                {name = "Encounters Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                {name = "Shinies Of This Species", value = tostring(Stats.species_shiny_count(species)), inline = true},
                {name = "\xE2\x80\x8B", value = "\xE2\x80\x8B", inline = false},
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            }
            pendingShinySpriteUrl = shiny_sprite_url(species)
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
            local stopHpType, stopHpPower = hidden_power(atkDV, defDV, speDV, spcDV)
            send_discord_embed(
                string.format("\xF0\x9F\x9B\x91 %s", stopReason),
                nil,
                {
                    {name = "Species", value = speciesName, inline = true},
                    {name = "Dex #", value = string.format("#%03d", species), inline = true},
                    {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkDV, defDV, speDV, spcDV), inline = true},
                    {name = "Hidden Power", value = string.format("%s (%d)", stopHpType, stopHpPower), inline = true},
                    {name = "Location", value = current_location_name(), inline = true},
                    {name = "Held Item", value = itemName, inline = true},
                    divider_field(),
                    {name = "Encounters This Session", value = tostring(sessionEncounterCount), inline = true},
                    {name = "Encounters Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                    divider_field(),
                    {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                    {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
                },
                COLOR_GOLD,
                isShinyEncounter and shiny_sprite_url(species) or regular_sprite_url(species)
            )
        end

        -- A "stop on X" condition overrides EVERYTHING else - auto-catch,
        -- kill/flee, all of it - for this encounter. Returning immediately
        -- here, right after the notification above, is what makes that
        -- true: previously this flag was only checked much later (after
        -- the auto-catch-on-item logic), so a matching auto-catch item
        -- could return out of M.step() first and the bot would keep
        -- running even though it had already sent a "stopped" message.
        if stopRequested then
            return true
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
                battleWatchdogNextCheckTime = nil
                battleWatchdogDiscordSent = false
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
            battleWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
            battleWatchdogDiscordSent = false
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
        elseif os.time() >= battleWatchdogNextCheckTime then
            local stalledFor = os.time() - battleWatchdogStartTime
            local enemyHP = memory.read_u16_be(enemy_hp_addr)
            if enemyHP == 0 then
                -- This one always alerts immediately, regardless of the
                -- discord-escalation timer above - it's not a guess, the
                -- bot is genuinely stopping right here and needs input.
                print("BATTLE WATCHDOG: enemy has fainted and battle still hasn't ended - likely a move-learn or evolution prompt. Stopping so you can decide.")
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                    "Stopped - likely a move-learn or evolution prompt needs your input")
                send_alert(
                    "\xE2\x9A\xA0\xEF\xB8\x8F Grinding stopped: the enemy fainted but the battle hasn't ended after a while - likely a move-learn or evolution prompt waiting for your input. Handle it manually, then resume.",
                    COLOR_RED)
                return true
            else
                print(string.format("BATTLE WATCHDOG: still in the same battle after %d+ seconds - attempting automatic recovery", stalledFor))
                attempt_unstuck_recovery()
                -- Keep retrying quietly (console-only) on this cadence
                -- rather than giving up after one attempt - only the
                -- Discord alert below is gated on the longer timer.
                battleWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
                if not battleWatchdogDiscordSent and stalledFor >= BATTLE_WATCHDOG_DISCORD_SECONDS then
                    battleWatchdogDiscordSent = true
                    send_alert(string.format(
                        "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck in battle: same encounter still active after over %d seconds, despite automatic recovery attempts. Check on it.",
                        BATTLE_WATCHDOG_DISCORD_SECONDS), COLOR_RED)
                end
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

        -- Computed once, independent of shininess - "Auto-catch on held
        -- item" should catch ANY Pokemon holding a matching item,
        -- shiny or not, same as "Kill non-shiny" works independently
        -- of shininess. Reused below both as its own trigger for
        -- non-shiny encounters, and folded into the shiny decision
        -- tree as an OR-condition alongside the species filter.
        local currentSpecies = memory.readbyte(species_addr)
        local currentSpeciesName = get_pokemon_name(currentSpecies)
        local currentItem = memory.readbyte(item_addr)
        local currentItemName = get_item_name(currentItem)
        local itemCatchEnabled, itemCatchFilterTokens = Gui.catch_on_item(hud)
        local catchAllowedByItem = Gui.auto_catch_enabled(hud) and itemCatchEnabled and currentItem ~= 0
            and species_matches_filter(itemCatchFilterTokens, currentItem, currentItemName)

        -- Auto-catch on Perfect / Perfect Negative DVs - same
        -- "independent of shininess" reasoning as the held-item catch
        -- above, and same gating (still requires the master Auto-Catch
        -- toggle, same as every other Auto-Catch Settings option).
        -- Recomputed here from atkdef/spespc directly rather than
        -- trusting isPerfect/isPerfectNegative from the
        -- pendingEncounterUpdate block above - that block only runs
        -- once, right as the encounter starts, while this point is
        -- reached on every subsequent M.step() tick of the same battle.
        -- Guarded on atkdef/spespc being non-nil: they're only populated
        -- once the encounter hook has fired at least once THIS SCRIPT
        -- SESSION (see the `local atkdef` / `local spespc` declarations
        -- near the top of the file). Restarting the Lua script mid-battle
        -- - e.g. to pick up a patched file - does not reset the emulator,
        -- so this in-battle branch can run before that hook ever fires,
        -- leaving both nil. Recomputing unconditionally here crashed with
        -- "attempt to perform arithmetic on a nil value (upvalue 'atkdef')".
        -- Skipping Perfect-DV auto-catch for the remainder of that one
        -- stale battle is the safe fallback; it resumes normally on the
        -- very next fresh encounter.
        local isPerfectDVs = false
        local isPerfectNegativeDVs = false
        if atkdef and spespc then
            local atkDV = math.floor(atkdef / 16)
            local defDV = atkdef % 16
            local speDV = math.floor(spespc / 16)
            local spcDV = spespc % 16
            isPerfectDVs = (atkDV == 15 and defDV == 15 and speDV == 15 and spcDV == 15)
            isPerfectNegativeDVs = (atkDV == 0 and defDV == 0 and speDV == 0 and spcDV == 0)
        end
        local catchAllowedByPerfect = Gui.auto_catch_enabled(hud)
            and ((isPerfectDVs and Gui.catch_on_perfect(hud))
                or (isPerfectNegativeDVs and Gui.catch_on_perfect_negative(hud)))

        if shinyvalue == 1 then
            local shinySpecies = currentSpecies
            local shinySpeciesName = currentSpeciesName

            if Gui.stop_on_shiny(hud) then
                -- Plain, filter-less blanket stop - manual mode,
                -- overrides Auto-Catch entirely regardless of its own
                -- settings. No auto-catch notification will ever follow
                -- here, so send the detailed embed now.
                print("Shiny found!!")
                send_pending_shiny_embed(shinySpeciesName)
                return true
            end

            if Gui.auto_catch_enabled(hud) then
                local exceptionEnabled, exceptionFilterTokens = Gui.auto_catch_stop_exception(hud)
                if exceptionEnabled and species_matches_filter(exceptionFilterTokens, shinySpecies, shinySpeciesName) then
                    -- This species is on the "don't auto-catch, stop
                    -- instead" exception list - e.g. reserving a
                    -- specific rare/valuable species for manual
                    -- catching while everything else still gets
                    -- auto-caught normally. No auto-catch attempt
                    -- follows, so send the detailed embed now.
                    print(string.format("Shiny %s found - on the auto-catch exception list, stopping for manual catching.", shinySpeciesName))
                    send_pending_shiny_embed(shinySpeciesName)
                    return true
                end

                if Gui.skip_already_caught_enabled(hud) and Stats.is_already_caught(shinySpecies) then
                    -- Living dex mode - this species has already been
                    -- caught before (tracked persistently across
                    -- sessions), so skip auto-catching another one and
                    -- fall through to the normal kill/flee handling. No
                    -- auto-catch notification will follow, so send the
                    -- detailed embed now.
                    print(string.format("Shiny %s found, but already caught before (living dex mode) - skipping, continuing the hunt.", shinySpeciesName))
                    send_pending_shiny_embed(shinySpeciesName)
                else

                local catchFilterTokens = Gui.catch_species_filter(hud)
                local catchAllowedBySpecies = species_matches_filter(catchFilterTokens, shinySpecies, shinySpeciesName)

                if catchAllowedBySpecies or catchAllowedByItem then
                    -- do_catch_sequence merges pendingShinyFields into
                    -- its own "found! attempting to catch" notification
                    -- instead of sending a separate embed here - keeps a
                    -- successful catch down to 2 Discord messages instead
                    -- of 3 (confirmed via a real user report/screenshot
                    -- on fishing.lua showing the redundant, oddly-ordered
                    -- third one - identical architecture to this file).
                    local stillHunting = do_catch_sequence(true, pendingShinyFields, pendingShinySpriteUrl)
                    if not stillHunting then
                        -- Confirmed via a real user report/screenshot: the
                        -- very next M.step() tick after a successful catch
                        -- sometimes re-sent the SAME "Shiny found!" embed
                        -- with identical species/DVs. Root cause traced
                        -- through the actual code path: species_addr is
                        -- already documented above (do_catch_sequence's own
                        -- settling-wait comment) to flicker non-zero for up
                        -- to 90+ frames after a battle genuinely ends. If
                        -- M.step()'s top-level dispatch samples species_addr
                        -- during one of those blips, it re-enters this "in
                        -- battle" branch - and since dv_flag_addr is also
                        -- left at 0x01 from the battle that just finished
                        -- (nothing clears it), the DV-wait loop's condition
                        -- is already satisfied and its body (the only bail-
                        -- out check) never runs even once. Execution falls
                        -- straight through to here with shinyvalue still 1
                        -- from the encounter we just caught, since only a
                        -- genuine new encounter hook resets it. Explicitly
                        -- clearing it the moment a catch resolves closes
                        -- that window - a real new shiny always re-sets
                        -- shinyvalue via shiny() inside the ROM hook, so
                        -- this can never suppress a genuine one.
                        shinyvalue = 0
                    end
                    return stillHunting
                else
                    -- Deliberately NOT returning here - let execution
                    -- fall through to the normal kill/flee handling
                    -- immediately below, same as any non-shiny
                    -- encounter would get. Returning false instead
                    -- would just re-enter this same branch on the next
                    -- M.step() call with shinyvalue still 1, printing
                    -- "skipping" forever without ever actually escaping
                    -- the battle. No auto-catch notification will
                    -- follow, so send the detailed embed now.
                    print(string.format("Shiny %s found, but doesn't match the auto-catch filter - skipping, continuing the hunt.", shinySpeciesName))
                    send_pending_shiny_embed(shinySpeciesName)
                end
                end
            else
                print("Shiny found!!")
                send_pending_shiny_embed(shinySpeciesName)
                return true
            end
        elseif catchAllowedByItem then
            -- NOT shiny, but holding a matching item - catch it
            -- regardless, independent of every shiny-specific check
            -- above (stop-on-shiny, exception list, living dex - none
            -- of those are about shininess, so they don't apply here).
            print(string.format("%s found holding %s - auto-catching (item match, not shiny).", currentSpeciesName, currentItemName))
            return do_catch_sequence(false)
        elseif catchAllowedByPerfect then
            -- Also independent of shininess - a genuine Perfect or
            -- Perfect Negative roll can never itself be shiny (shininess
            -- requires Def=10, which rules out both all-15 and all-0),
            -- so this can never double-fire alongside the shiny branch
            -- above.
            local perfectLabel = isPerfectDVs and "Perfect DVs (15/15/15/15)" or "Perfect Negative DVs (0/0/0/0)"
            print(string.format("%s found with %s - auto-catching.", currentSpeciesName, perfectLabel))
            return do_catch_sequence(false)
        end

        -- (stopRequested, if set, already returned true right after its
        -- Discord notification was sent, earlier in this same M.step()
        -- call - so this point is only ever reached when it's false.)

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
            -- True if EITHER of the first two moves still has PP -
            -- do_kill_turn() itself picks whichever one to actually use
            -- (preferring the first, falling back to the second only if
            -- the first is depleted). Only treat this as "can't attack
            -- at all" once both are out.
            local hasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0 or memory.readbyte(FIRST_MOVE_PP_ADDR + 1) > 0
            local hpSafe = has_safe_hp()

            if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and hasPP and hpSafe then
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Attacking...")
                local killResult = do_kill_turn()
                if killResult == "stuck" then
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                        "Stopped - move-learn or evolution prompt needs your input")
                    send_alert("\xE2\x9A\xA0\xEF\xB8\x8F Grinding stopped: a move-learn or evolution prompt is likely showing and needs your input. Handle it manually, then resume.", COLOR_RED)
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

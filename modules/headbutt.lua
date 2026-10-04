-- headbutt.lua
-- Headbutt tree encounters. Stand facing a headbuttable tree (the small
-- pointy ones, distinct from regular trees) and start this module.
--
-- Confirmed mechanic: a tree's encounter table and rate (some trees are
-- much better than others - 80%/50%/10% "rare") is permanently fixed by
-- a formula using your Trainer ID and that tree's exact map coordinates.
-- It never changes, never moves to a different tree, and trees never
-- deplete with repeated use (unlike the HGSS remakes) - so there's
-- nothing to reset here, just keep headbutting the same tree forever,
-- same as recasting a fishing rod.
--
-- Each attempt is confirmed to be immediate (not a timed wait like
-- fishing): 4 A presses performs the headbutt, and you either get an
-- encounter or you don't - checked directly, no timeout/guessing needed.
--
-- Once an encounter actually triggers, it's the EXACT SAME battle system
-- wild.lua already handles (same species_addr, same DV/shiny detection,
-- same menu navigation) - reused here essentially unchanged.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")
Stats = require("data.stats")
LevelUpMoves = require("data.level_up_moves")
RngEnabler = require("data.rng_enabler")
ConsoleLog = require("data.console_log")

local hud

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function get_item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

local function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

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

local DISCORD_RELAY_URL = "http://127.0.0.1:5000/"

-- Checks the global flag set by launcher.lua's Stop button. Needed
-- specifically for the auto-catch sequence, which runs long, blocking
-- loops (throwing up to 20 balls, each with several sub-waits) entirely
-- within a single M.step() call.
local function stop_was_requested()
    return AutocrystalGlobalStopRequested == true
end

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
    if not Gui.discord_enabled(hud) then
        -- Deliberately NOT silent - a real user log showed several
        -- genuine shinies (confirmed via the Atk/Def/Spe/Spc printed
        -- right above each one) with zero "Discord embed sent/failed"
        -- line anywhere after them, indistinguishable from this gate
        -- just quietly doing nothing. This print exists so a future
        -- occurrence is unambiguous in the console/log instead of
        -- looking identical to a silent success.
        print("Discord embed skipped (Discord notifications disabled): " .. title)
        return
    end

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

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua - see data/location_names.lua for where this comes from
-- (the actual pret/pokecrystal disassembly, not a guess).
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

-- A visible horizontal-rule divider between field groups - see wild.lua.
local function divider_field()
    return {name = "\xE2\x80\x8B", value = string.rep("\xE2\x96\xAC", 28), inline = false}
end

local COLOR_GOLD = 16766720
local COLOR_GREEN = 3066993
local COLOR_RED = 15158332
-- Neutral "heads up, nothing's wrong" tone - used only for the one-time
-- Thief-PP-depleted notice below, so it doesn't read as an error (RED)
-- or get visually confused with a shiny-related notice (GOLD).
local COLOR_BLUE = 3447003

-- Lean colored embed for the auto-catch dialogue - just title, color,
-- Dex #, held item, and the species' sprite. itemName is optional - pass
-- nil to omit the field entirely.
local function send_catch_notification(title, color, speciesId, isShiny, itemName)
    local spriteUrl = isShiny and shiny_sprite_url(speciesId) or regular_sprite_url(speciesId)
    local fields = {{name = "Dex #", value = string.format("#%03d", speciesId), inline = true}}
    if itemName then
        table.insert(fields, {name = "Held Item", value = itemName, inline = true})
    end
    send_discord_embed(title, nil, fields, color, spriteUrl)
end

-- Even leaner colored embed for bot-status alerts (stuck detection,
-- battle watchdog) that aren't about a specific catch attempt.
local function send_alert(title, color)
    send_discord_embed(title, nil, nil, color, nil)
end

-- Battle/cast watchdogs: tracks real-world time since the CURRENT battle
-- started (battleWatchdog...) or since the last headbutt attempt with no
-- encounter at all (overworldWatchdog...). Being in battle
-- (species_addr ~= 0) is true every single frame regardless of whether
-- anything's actually happening within it, so this can't rely on that
-- alone - if we're still in the same ongoing battle after
-- BATTLE_WATCHDOG_SECONDS, that's inherently suspicious on its own (e.g.
-- an interrupting phone call mid-fight).
--
-- Two-tier response, same as wild.lua: the first crossing of
-- BATTLE_WATCHDOG_SECONDS (and every BATTLE_WATCHDOG_SECONDS after that,
-- while still stalled) prints to console and tries the A/B recovery,
-- quietly - no Discord yet. Only once stalled for the much longer
-- BATTLE_WATCHDOG_DISCORD_SECONDS does a single Discord alert fire.
local BATTLE_WATCHDOG_SECONDS = 15
local BATTLE_WATCHDOG_DISCORD_SECONDS = 120
local battleWatchdogStartTime = nil
local battleWatchdogNextCheckTime = nil
local battleWatchdogDiscordSent = false
local overworldWatchdogStartTime = nil
local overworldWatchdogNextCheckTime = nil
local overworldWatchdogDiscordSent = false

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

-- ===== Persistent state =====

local atkdef, spespc, species, item
local shinyvalue = 0
-- Containment fix ported from wild.lua (identical architecture): a real
-- verbose wild.lua log proved shinyvalue can revert to 0 by the time the
-- in-battle decision block reads it, just a tick or two after the ROM
-- hook set it to 1 for a confirmed real shiny (Stats correctly recorded
-- it) - with no explicit `shinyvalue = 0` assignment anywhere in the file
-- able to explain it. Rather than risk the same silent loss here, the
-- hook's verdict is latched into this separate variable, which nothing
-- else in this file writes to, and the real catch/flee decision reads
-- THIS instead of the raw shinyvalue.
local shinyLatchedThisBattle = false
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
-- Thief mode (see chkThiefMode/txtThiefFilter in gui_module.lua): only
-- ever attempt one Thief steal per battle, then always fall through to
-- the normal flee behavior regardless of the outcome - see wild.lua's
-- own copy of this same comment for the full "once per battle, not once
-- per tick" reasoning (identical architecture to this file). Reset to
-- false alongside pendingBattleSettle in the EnemyWildmonInitialized
-- hook, since both are scoped to exactly one battle.
local thiefUsedThisBattle = false
-- Session-scoped and NEVER reset once set - fires the "Thief is out of
-- PP" notice the first time PP hits 0 and never again for the rest of
-- the session, even if PP is later restored (Elixir/PP Up/etc) and then
-- depletes a second time.
--
-- A real per-refill re-arm was attempted here twice (clearing this back
-- to false once a later battle's PP read looked nonzero again, with a
-- debounce first 60 frames, then a second debounce on the re-arm read
-- itself) - both attempts still caused this same notice to spam
-- repeatedly, minutes apart, all session, with PP never actually having
-- been restored. That means FIRST_MOVE_PP_ADDR can apparently read
-- nonzero for well over 60 straight frames without PP really being
-- refilled, at least in whatever state this was - not just the
-- single-frame flicker every other debounce in this file was sized for.
-- Reverted back to the simple one-time-ever version (the last
-- known-stable behavior) rather than guess at a third, longer debounce
-- with no real diagnostic data to size it against.
local thiefPpDepletedNotified = false
-- Reset per-battle (alongside thiefUsedThisBattle, same hook) so the PP
-- check below runs exactly ONCE per genuine new battle - see wild.lua's
-- copy of this same comment for the full root-cause explanation: without
-- this latch, the notification check re-ran on every tick of the stale
-- post-battle tail window (species_addr flickering nonzero for up to
-- 90+ frames after a battle actually ends), during which
-- FIRST_MOVE_PP_ADDR no longer holds valid battle data - causing "out
-- of PP" to fire on essentially every battle regardless of real PP.
local thiefPpCheckedThisBattle = false
-- Session-scoped and NEVER reset once set - same one-time-ever pattern
-- as thiefPpDepletedNotified above. See wild.lua's own copy of this
-- comment for the full rationale.
local thiefLowHpNotified = false
-- Reset per-battle (same hook as thiefPpCheckedThisBattle) so this
-- evaluates at most ONCE per genuine new battle.
local thiefLowHpCheckedThisBattle = false

-- ===== Kill mode safety savestates =====
-- See wild.lua's own copy of this comment for the full rationale -
-- written as NAMED FILES (savestate.save(path, true)) in modules/data/,
-- the same location/mechanism Static/Starters/Egg/Game Corner's own
-- SavestateBackup files already use, rather than numbered
-- savestate.saveslot() slots - far more discoverable than a slot number,
-- and since the filenames are exclusively ours there's no collision risk
-- to guard against either. Gated on Kill mode specifically being
-- checked, not on this module simply being active.
local KILL_MODE_SAFETY_SAVE_PATH = script_dir .. "data/kill_mode_safety.State"
local KILL_MODE_AUTOSAVE_PATH = script_dir .. "data/kill_mode_autosave.State"
local KILL_MODE_AUTOSAVE_INTERVAL_SECONDS = 5 * 60
local killModeWasEnabled = false
local killModeAutosaveNextTime = nil

local stopRequested = false
local stopReason = ""
local realEncounterConfirmed = false
local pendingEncounterUpdate = false
-- Set true (alongside pendingEncounterUpdate) the instant the ROM hook
-- confirms a NEW encounter is shiny - cleared the moment the in-battle
-- shiny-decision block ("if shinyvalue == 1 then" further down M.step())
-- actually starts handling it. Ported from the same confirmed bug/fix in
-- wild.lua (identical architecture) - that block can, for reasons not
-- fully pinned down, sometimes never run for a battle at all even though
-- the ROM hook fired and Stats correctly recorded the shiny. This flag is
-- the safety net: if it's STILL true once we're confirmed back at the
-- tree, the shiny was provably never handled, so a fallback notification
-- fires right there instead of the user finding out only from "since
-- last shiny" quietly dropping with no explanation.
local shinyNotificationPending = false
-- Diagnostic companion to shinyNotificationPending, armed/reset
-- alongside it. Set true by the LoadBattleMenuAddr ROM hook (fires
-- exactly when the game loads the player-visible FIGHT/PKMN/ITEM/RUN
-- menu, not a guess) if that menu is ever actually reached while a
-- shiny notification is still pending. Lets the fallback warning below
-- say, with real evidence, whether the bot ever got a turn at all for
-- that encounter, rather than asserting an unconfirmed cause.
local shinyNotificationBattleMenuSeen = false
-- Snapshot of Stats.encountersSinceShiny taken in the ROM hook, BEFORE
-- Stats.record_encounter/record_shiny run there - see the hook itself
-- for why stats bookkeeping moved out of M.step(). M.step() reads this
-- (instead of Stats.encountersSinceShiny directly) when building the
-- shiny Discord embed's "Encounters Since Last Shiny" field, since by
-- the time M.step() runs, Stats.encountersSinceShiny has already been
-- reset to 0 for a shiny encounter.
local pendingEncounterStatsBeforeShiny = 0
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
-- Precise, verified hooks for the actual catch outcome - found via
-- direct symbol lookup in both pokecrystal.sym and pokegold.sym:
-- PokeBallEffect.caught and PokeBallEffect.shake_and_break_free. Same
-- hooks fishing.lua uses - the battle system (and therefore the catch
-- mechanic) is identical once an encounter actually starts.
local CatchSuccessAddr
local CatchFailAddr
local catchOutcomeSucceeded = false
local catchOutcomeFailed = false
local version, region
local sessionEncounterCount = 0
local highestSpeSpc = 0
local highestAtkDef = 0

local MENU_CURSOR_Y, MENU_CURSOR_X
local RUN_CURSOR = {y = 2, x = 2}
local wCurItemAddr, wItemsAddr, wNumItemsAddr
local wBallsAddr, wNumBallsAddr
-- Preference order when scanning the bag for something to throw -
-- Poke Ball specifically preferred, falling back to other ball types
-- only if no Poke Balls are left.
local BALL_ITEM_IDS = {5, 4, 2, 1} -- Poke, Great, Ultra, Master

-- Sends the detailed "Shiny X Found!" embed built from pendingShinyFields
-- (DVs, Hidden Power, Location, encounter stats, sprite - see where those
-- are computed in M.step()'s pendingEncounterUpdate handling). Used by
-- every shiny-found branch EXCEPT the auto-catch-will-attempt-it path,
-- where these same fields get merged into the "found! attempting to
-- catch" notification instead (see do_catch_sequence) so a successful
-- auto-catch produces exactly 2 Discord messages, not 3.
-- titleOverride lets a specific call site (e.g. the "doesn't match the
-- auto-catch filter, resuming hunt" case below) use wording that reflects
-- what's actually happening instead of the generic "Found!" title, which
-- read as misleadingly alarming/final for an encounter the bot is about
-- to just skip past and keep hunting through.
local function send_pending_shiny_embed(speciesName, titleOverride)
    if pendingShinyFields then
        local title = titleOverride or string.format("\xE2\x9C\xA8 Shiny %s Found!", speciesName)
        send_discord_embed(title, nil, pendingShinyFields, COLOR_GOLD, pendingShinySpriteUrl)
    end
end

-- Broader than BALL_ITEM_IDS - used to detect "have we arrived at the
-- Balls pocket at all", regardless of which specific ball happens to be
-- first in it. Includes Apricorn balls (157-166) and Park Ball (177)
-- alongside the standard four.
local function is_ball_item(itemId)
    for _, ballId in ipairs(BALL_ITEM_IDS) do
        if itemId == ballId then return true end
    end
    if itemId >= 157 and itemId <= 166 then return true end
    if itemId == 177 then return true end
    return false
end
local PACK_CURSOR = {y = 2, x = 1}
local FIRST_MOVE_PP_ADDR
local OWN_HP_ADDR
local OWN_MAX_HP_ADDR
-- Flee instead of attacking if HP drops below this fraction of max -
-- a safety margin above the game's own "red bar" threshold, so there's
-- room to actually flee before a possible next hit could faint us.
local LOW_HP_FLEE_THRESHOLD = 0.25
-- User-requested, Thief-specific HP floor - see wild.lua's own copy of
-- this comment for the full rationale (deliberately separate from and
-- lower than LOW_HP_FLEE_THRESHOLD, since Thief only ever risks one
-- attack before fleeing regardless of outcome).
local THIEF_LOW_HP_THRESHOLD = 0.20

local dv_flag_addr, species_addr, item_addr, enemy_hp_addr, enemy_max_hp_addr

-- For the move-learn detection fix, ported from wild.lua - declared as
-- file-locals here (not globals) to match the same convention wild.lua
-- and every other module using party_base_addr already follows.
local curPartyMonAddr
local party_base_addr
local LearnMoveAddr

-- Own Pokemon's HP can exceed 255 at higher levels, so this is a 16-bit
-- read, not a single byte like the PP check.
local function has_safe_hp()
    local currentHP = memory.read_u16_be(OWN_HP_ADDR)
    local maxHP = memory.read_u16_be(OWN_MAX_HP_ADDR)
    if maxHP == 0 then return true end -- avoid divide-by-zero if read too early
    return (currentHP / maxHP) > LOW_HP_FLEE_THRESHOLD
end

-- Same read, different (lower) threshold - see THIEF_LOW_HP_THRESHOLD's
-- own comment for why Thief gets its own, separate HP floor.
local function thief_has_safe_hp()
    local currentHP = memory.read_u16_be(OWN_HP_ADDR)
    local maxHP = memory.read_u16_be(OWN_MAX_HP_ADDR)
    if maxHP == 0 then return true end
    return (currentHP / maxHP) > THIEF_LOW_HP_THRESHOLD
end

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

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance()
end

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
local FIGHT_CURSOR = {y = 1, x = 1}
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
-- First move slot on the move-select submenu - see wild.lua's own copy
-- of this comment for the full rationale (do_thief_turn used to ASSUME
-- move 1 was always already highlighted and skip navigating entirely,
-- which a real user report showed doesn't always hold - Thief could
-- silently confirm whatever move was left highlighted from an earlier
-- turn instead of Thief itself).
local MOVE1_CURSOR = {y = 1, x = 1}

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

-- Proactive move-learn-prompt detection, ported from wild.lua after a
-- confirmed real-world gap: this module previously relied solely on the
-- postAttackWait timeout below to eventually stop on a "would you like
-- to learn a new move?" prompt. Once that timeout was extended to 1800
-- frames (30 seconds) to give the confused/second-move case enough room,
-- that same 30-second budget became long enough for blind A-mashing to
-- fully resolve a move-learn prompt (confirm "yes", then pick whatever
-- move slot the cursor defaults to) before the timeout ever fired -
-- confirmed via a user report of the bot "spamming" through a new-move
-- prompt until the game forced a move to be learned automatically.
-- wild.lua already solved this the same way: track the active Pokemon's
-- level every frame and stop the instant a level-up is confirmed AND the
-- species is known to learn a move somewhere in that range AND there's
-- no free move slot to auto-fill into - more reliable than hooking the
-- exact learn-move routine (confirmed to never fire on Crystal) or
-- trusting a timeout alone (the whole sequence completes too fast when
-- mashing A every frame to reliably hit any reasonable timeout).
local learnMovePromptDetected = false

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

-- Held item byte for the LEAD Pokemon specifically (party slot 1) - NOT
-- to be confused with get_active_mon_*() above, which always track
-- whichever party slot is CURRENTLY BATTLING (via curPartyMonAddr). The
-- startup held-item check below always means "party slot 1" regardless
-- of battle state, so this hardcodes slot index 0 rather than reading
-- curPartyMonAddr.
--
-- Offset derivation: see wild.lua's own copy of this comment for the
-- full cross-check against get_active_mon_move_count()'s and
-- get_active_mon_level()'s already-trusted offsets (+0x0A and +0x27),
-- both of which are only consistent with each party mon's struct
-- starting at party_base_addr + 0x08, and the standard Gen 1/2 struct
-- order (Species+0, Item+1, Moves+2..+5, ...). So for the lead
-- (slot index 0): party_base_addr + 0x08 + 1 = party_base_addr + 0x09.
local LEAD_HELD_ITEM_ADDR_OFFSET = 0x09

local function get_lead_held_item()
    return memory.readbyte(party_base_addr + LEAD_HELD_ITEM_ADDR_OFFSET)
end

-- Checks whether the species learns a move at ANY level in
-- (oldLevel, newLevel] - not just newLevel itself, since a big EXP gain
-- could jump multiple levels in one hit, and a move-learn at an
-- intermediate level would otherwise get skipped right past. +1 safety
-- margin on the upper bound: confirmed discrepancy between the
-- disassembly data and actual retail ROM behavior (see wild.lua for the
-- Croconaw/Bite example this was verified against).
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

-- Persistent across the WHOLE battle, not reset per do_kill_turn() call
-- - see wild.lua for why (a level-up can complete between calls, and a
-- fresh per-call baseline would be permanently blind to what happened
-- in between).
local battleLevelBaseline = nil
local battleLevelBaselineSpecies = nil
local battleLevelBaselineMoveCount = nil

-- ===== Auto-catch engine: ported verbatim from fishing.lua, which
-- itself confirmed this is the EXACT SAME battle system a headbutt
-- encounter reaches once triggered - same species_addr, same bag/ball
-- memory layout, same catch-outcome hooks. See fishing.lua for the full
-- design notes behind each piece below. =====

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

-- Navigates PACK -> scrolls to the given ball -> selects it (throws it
-- directly at a wild Pokemon, no "use on which Pokemon?" prompt).
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
        if curItem == ballId or is_ball_item(curItem) then
            press_button("A")
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

-- Simplified attack turn for weakening the enemy before catching.
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
    -- is out of PP (see MOVE2_CURSOR's definition above for the caveat
    -- on this). The caller already confirmed at least one of the two
    -- has PP before calling this function at all, so this only ever
    -- needs to move the cursor, never bail out itself.
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
    -- the full explanation in do_kill_turn below. MOVE2_CURSOR and
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

-- ===== Thief mode ===== (see wild.lua's own copy for the full rationale
-- - identical architecture to this file, ported verbatim)
local function do_thief_turn()
    -- CONFIRMED via a real user report (on a fishing encounter
    -- specifically) - see wild.lua's own copy of this comment for the
    -- full rationale: Thief can be the very first attack attempted in a
    -- battle, and the caller's own "wait for the battle menu to load"
    -- loop (300 frames, mashing B) isn't always long enough before we
    -- get here. When that happens, have_battle_controls is still false
    -- the instant this function starts, and the `while have_battle_
    -- controls do` loop below (a Lua while-loop, which checks its
    -- condition before the first iteration) executes zero iterations -
    -- never opening FIGHT or selecting anything - yet still falls
    -- through to report back "ok". Actively waiting for
    -- have_battle_controls here (rather than assuming the caller already
    -- guaranteed it) makes Thief self-sufficient regardless of how long
    -- this encounter's intro runs, without touching do_kill_turn's or
    -- do_catch_attack_turn's own already-battle-tested logic.
    if not have_battle_controls then
        -- Deliberately NOT gated on species_addr ~= 0 - see wild.lua's
        -- own copy of this comment for the full rationale (a real user
        -- report showed species_addr itself can read 0 for an instant
        -- during a genuinely ongoing battle, which made this loop bail
        -- out immediately - "waited 0 frame(s)" - instead of actually
        -- waiting). have_battle_controls plus the hard frame cap below
        -- is sufficient on its own to bound this loop safely.
        local preWaitFrames = 0
        while not have_battle_controls and preWaitFrames < 600 do
            if stop_was_requested() then
                print("Thief mode: Stop requested - aborting.")
                return "stuck"
            end
            emu.frameadvance()
            press_button("B")
            preWaitFrames = preWaitFrames + 1
        end
        vprint(string.format("Thief mode: waited %d frame(s) for the battle menu to load - have_battle_controls=%s",
            preWaitFrames, tostring(have_battle_controls)))
        if not have_battle_controls then
            -- "skipped", not "stuck" - see wild.lua's own copy of this
            -- comment: this isn't an error needing manual input, just a
            -- slow-loading menu, so fall straight through to the normal
            -- flee instead of stopping the bot.
            print("Thief mode: battle menu never became interactive in time - skipping Thief this battle, falling back to normal behavior")
            return "skipped"
        end
    end
    local nav_attempts = 0
    while have_battle_controls do
        if stop_was_requested() then
            print("Thief mode: Stop requested - aborting.")
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
                print("Thief mode: navigation to FIGHT stuck after 12 attempts")
                return "stuck"
            end
            local next_input = navigate_to_menu_option(FIGHT_CURSOR)
            press_and_wait_for_cursor_change(next_input, 30)
        end
    end
    vprint(string.format("Thief mode: FIGHT navigation loop exited after %d attempt(s) - have_battle_controls=%s, cursor Y=%d X=%d",
        nav_attempts, tostring(have_battle_controls), memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))

    if MoveSelectionAddr then
        local moveSelectWaitFrames = 0
        while not moveSelectScreenOpen and moveSelectWaitFrames < 90
          and memory.readbyte(species_addr) ~= 0 do
            emu.frameadvance()
            moveSelectWaitFrames = moveSelectWaitFrames + 1
        end
        for i = 1, 15 do
            emu.frameadvance()
        end
    else
        for i = 1, 60 do
            emu.frameadvance()
        end
    end

    -- Explicitly confirm (and if needed, navigate to) move slot 1
    -- instead of assuming it's already highlighted - see wild.lua's own
    -- copy of this comment and MOVE1_CURSOR's definition for the full
    -- rationale.
    local move1_attempts = 0
    while true do
        if stop_was_requested() then
            print("Thief mode: Stop requested - aborting.")
            return "stuck"
        end
        local my = memory.readbyte(MENU_CURSOR_Y)
        local mx = memory.readbyte(MENU_CURSOR_X)
        if my == MOVE1_CURSOR.y and mx == MOVE1_CURSOR.x then
            -- Defensive re-check, right before actually committing to
            -- the attack (real user report): the caller decides whether
            -- to use Thief at all this battle from a single PP read
            -- taken once, at battle start - and that PP-depletion notice
            -- block only ever double-checks/waits when that read looked
            -- like 0 (to avoid a false "depleted" notification), never
            -- when it looked nonzero. So a stale/misread "PP available"
            -- at that one moment can still get all the way here even
            -- though PP is actually already sitting at 0 - confirmed via
            -- a real screenshot showing the in-game "There's no PP left
            -- for this move!" refusal right after this exact press. That
            -- refusal bounces back to this same move-select screen
            -- (not the top-level battle menu), so the post-attack wait
            -- loop below would just mash A into the same refusal forever
            -- and time out as "stuck" - stopping the whole bot over
            -- something that should have just skipped Thief and kept
            -- hunting normally. Checking PP fresh right here, immediately
            -- before pressing A, catches this regardless of why the
            -- earlier read was wrong.
            if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 then
                print("Thief mode: move slot 1 is actually out of PP right now (caught right before attacking) - backing out without attacking so hunting can continue normally.")
                -- Piggyback on the same one-time-ever notification the
                -- earlier per-battle check normally sends - this path
                -- only gets hit when THAT check was fooled by a stale
                -- read, so without this, a session could hit real PP
                -- depletion and never actually get told about it.
                if not thiefPpDepletedNotified then
                    thiefPpDepletedNotified = true
                    send_alert("Thief mode: move slot 1 is out of PP - pausing Thief steals until you restore it (Elixir/PP Up/etc). Continuing to hunt normally in the meantime.", COLOR_BLUE)
                end
                press_button("B")
                return "skipped"
            end
            vprint(string.format("Thief mode: confirmed cursor on move slot 1 after %d correction(s) - pressing A", move1_attempts))
            -- Clear the ROM-hook-driven move-select-screen flag right
            -- before committing to the attack, so the post-attack wait
            -- loop below can tell the difference between "still waiting
            -- for the attack to resolve" and "got bounced straight back
            -- to this same move-select screen" - the hook
            -- (MoveSelectionAddr, see its registration further down)
            -- fires every single time the game's move-select routine is
            -- entered, including every time a move gets REJECTED (e.g.
            -- "There's no PP left for this move!") and control bounces
            -- back here. That makes it a hard, unambiguous signal for a
            -- stuck refusal - unlike polling FIRST_MOVE_PP_ADDR/cursor
            -- position, which real logs have shown can be misread or
            -- miss the exact refusal state. If it fires again after this
            -- point, we know for certain the attack never actually went
            -- through.
            moveSelectScreenOpen = false
            press_button("A")
            break
        else
            move1_attempts = move1_attempts + 1
            if move1_attempts > 6 then
                print(string.format("Thief mode: couldn't confirm the cursor on move slot 1 after %d attempt(s) (stuck at Y=%d X=%d) - backing out without attacking",
                    move1_attempts, my, mx))
                press_button("B")
                return "skipped"
            end
            press_and_wait_for_cursor_change(navigate_to_menu_option(MOVE1_CURSOR), 30)
        end
    end

    -- FIX (real user report): this loop used to just be
    -- `while not have_battle_controls do ... end`, with no exit
    -- condition for the battle ending entirely. A Thief attack that
    -- also happens to knock the wild Pokemon out ends the battle with
    -- no menu left to reload - have_battle_controls then never becomes
    -- true again, so the old loop mashed A for the full timeout and
    -- reported "stuck", stopping the whole bot even though nothing was
    -- actually wrong (the steal itself may well have already
    -- succeeded). Mirrors do_kill_turn's own already-battle-tested
    -- post-attack loop below: exit early on species_addr == 0 (battle
    -- over, nothing to wait for), and guard against a move-learn
    -- prompt exactly the same way - previously this function had ZERO
    -- protection against that, unlike do_kill_turn, so a Thief-induced
    -- level-up with a move-learn prompt could have been blindly
    -- confirmed by the A-mash below (potentially overwriting an
    -- existing move, possibly Thief itself).
    -- CORRECTION to the fix above (real user report, round 2): the first
    -- version of this made the loop's own CONDITION exit the instant
    -- memory.readbyte(species_addr) read 0 even ONCE - but this exact
    -- function already documents, in its own pre-wait loop's comment
    -- above, that species_addr can read 0 for a single-frame flicker
    -- DURING A REAL, ONGOING BATTLE, not just once it's truly over. That
    -- flicker made this loop exit early mid-turn (before the attack had
    -- actually resolved), and since have_battle_controls was still
    -- false and a SECOND species_addr read moments later could easily
    -- have already bounced back nonzero, execution fell through to a
    -- bare "return "ok"" while the real battle was still in progress -
    -- confirmed via a real user report as the cause of two new
    -- symptoms: the held item no longer being taken after a real steal,
    -- and no Discord notification being sent, because the caller's own
    -- item/species reads immediately afterward were sampled mid-
    -- animation instead of after the turn genuinely finished.
    --
    -- Fix: never let a single frame decide this. Keep the loop running
    -- (pressing A every frame, exactly like before) purely on
    -- `not have_battle_controls`, and separately require
    -- BATTLE_END_CONFIRM_FRAMES CONSECUTIVE frames of species_addr == 0
    -- before trusting that the battle has actually, genuinely ended -
    -- the same "don't trust a single read" principle already proven
    -- elsewhere in this file (REQUIRED_SETTLE_FRAMES, and this
    -- function's own take_item_from_lead()). A real flicker only ever
    -- lasts an instant, so it can never accumulate anywhere near this
    -- many consecutive zero-reads - only a genuine battle end can.
    -- CORRECTION, round 4 (real user report): reading enemy_hp_addr
    -- exactly once, on the very same frame the attack button was
    -- pressed, is too early to trust - a real log showed a genuinely
    -- lethal Thief hit (the wild Grimer really did faint, confirmed by
    -- the user) still getting the full 600-frame non-fainted timeout,
    -- meaning enemyFainted read false at that instant even though the
    -- hit was about to be fatal. The HP value evidently doesn't update
    -- synchronously with the button press - it lands sometime during
    -- the attack's own animation/text sequence, a few frames later.
    -- Gating the whole "fainted" detection on that one early snapshot
    -- (as the previous fix did) meant a real KO could permanently fail
    -- to ever be recognized, right back to the original "stuck" false
    -- stop this was all meant to solve.
    --
    -- Fix: don't snapshot it once - keep sampling it every single frame
    -- of this same wait loop and latch it permanently true the moment
    -- it's ever actually seen at 0 (HP only decreases within a turn, so
    -- this can't un-latch, and this loop never spans past one attack).
    -- By the time species_addr's own consecutive-zero debounce below
    -- could possibly confirm a real battle end, the HP write is
    -- guaranteed to have long since landed - so this sticky flag ends
    -- up just as reliable as the species check for a genuine KO, while
    -- still staying false the entire time for a Muk-style non-fainting
    -- hit (its HP genuinely never reaches 0), which is exactly what
    -- keeps the round-3 fix's protection intact.
    have_battle_controls = false
    local postAttackWait = 0
    local postAttackTimeout = 600
    local enemyFainted = memory.read_u16_be(enemy_hp_addr) == 0
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
    local BATTLE_END_CONFIRM_FRAMES = 30
    local battleEndConfirmedFrames = 0
    -- CORRECTION, round 5 (real user report): confirming the battle
    -- ended isn't the same as confirming there's nothing left on screen.
    -- A real KO is very often followed by "gained N EXP!"/"grew to
    -- level X!" text, which this loop DOES press A through while it's
    -- still running - but the moment battleEndConfirmedFrames hits its
    -- threshold, this used to return "fainted" immediately, potentially
    -- mid-EXP-bar-fill or with that text still up. The very next thing
    -- that happens is take_item_from_lead()'s own settle-wait, which
    -- deliberately does NOT press any buttons at all (so it can't fire
    -- off an unwanted NPC/sign interaction when the SAME function is
    -- used by the startup held-item check on a player standing in the
    -- overworld) - so any leftover EXP/level text just sits there
    -- un-dismissed for that entire wait, and the Start-menu button
    -- sequence that follows gets silently swallowed/misapplied by that
    -- stuck screen. That's exactly why the steal was registering (this
    -- function's own read of the lead's item happens fine beforehand)
    -- but the item never actually left the Pokemon - only the next
    -- Start press's fresh startup check caught it, because that one
    -- runs from a screen that's had plenty of time to fully settle.
    --
    -- Fix: once the battle-end is confirmed, don't hand off yet - keep
    -- doing exactly what this loop was already doing (mashing A,
    -- watching for a move-learn prompt/own-faint) for a further fixed
    -- stretch, specifically to flush out any leftover EXP-gain/level-up
    -- text before returning. A real move-learn prompt occurring during
    -- this window is still caught correctly by the checks below, same
    -- as before.
    local POST_FAINT_TEXT_FLUSH_FRAMES = 90
    local battleEndConfirmed = false
    local postFaintFlushFrames = 0
    local PP_STUCK_CONFIRM_FRAMES = 20
    local ppStuckConfirmFrames = 0
    while not have_battle_controls do
        if stop_was_requested() then
            print("Thief mode: Stop requested - aborting.")
            return "stuck"
        end

        -- CORRECTION, round 8 (real user report, with full verbose log
        -- proof this time): round 7's PP-value debounce below STILL
        -- never fired on a real "no PP left" refusal - the user's raw
        -- console log showed "MoveSelectionScreen entered - move-select
        -- submenu confirmed open" (the ROM hook further down in this
        -- file, MoveSelectionAddr) printing roughly 50 times in a row
        -- right after "Thief mode: confirmed cursor on move slot 1 ...
        -- pressing A", all the way to the generic 600-frame timeout -
        -- proving the game really was bouncing the refusal back to this
        -- same move-select screen the entire time, yet round 7's own
        -- 0-PP debounce never caught it. That hook fires unconditionally
        -- every single time the game's move-select routine is entered,
        -- including every rejection bounce-back, regardless of whatever
        -- FIRST_MOVE_PP_ADDR or the cursor happens to read at that
        -- instant - so unlike polling those addresses (which multiple
        -- rounds of real-world evidence have now shown can be misread or
        -- miss the exact refusal window), it can't be fooled the same
        -- way. moveSelectScreenOpen was explicitly cleared to false
        -- right before this turn's "A" press (see move1_attempts above);
        -- if it has flipped back to true by the time we get here, the
        -- move never actually went through - control bounced straight
        -- back to move-select, which for Thief (no fallback second move)
        -- can only mean this same "no PP left" refusal (or something
        -- equally un-attackable). Treat that as decisive on its own,
        -- with no PP-value or enemyFainted gating needed - the game
        -- physically cannot re-enter MoveSelectionScreen after a real
        -- faint, so there's no legitimate case this could collide with.
        if moveSelectScreenOpen then
            print("Thief mode: caught stuck - bounced back to the move-select screen right after pressing A (almost always a 'no PP left' refusal) - backing out without attacking so hunting can continue normally.")
            if not thiefPpDepletedNotified then
                thiefPpDepletedNotified = true
                send_alert("Thief mode: move slot 1 is out of PP - pausing Thief steals until you restore it (Elixir/PP Up/etc). Continuing to hunt normally in the meantime.", COLOR_BLUE)
            end
            press_button("B")
            return "skipped"
        end

        -- CORRECTION, round 7 (real user report + screenshots, the
        -- round-6 fix STILL wasn't catching this): round 6 required the
        -- cursor to read back exactly at MOVE1_CURSOR before trusting a
        -- 0-PP reading, on the assumption the "There's no PP left for
        -- this move!" refusal leaves the cursor sitting there untouched
        -- - but if that assumption about the cursor's exact behavior
        -- during the refusal is wrong, that extra condition could keep
        -- this from ever firing, which matches the repeated reports of
        -- this exact screenshot recurring unchanged. Dropping the
        -- cursor requirement entirely removes that whole point of
        -- doubt: this now only needs PP to genuinely read 0, debounced
        -- across PP_STUCK_CONFIRM_FRAMES consecutive frames (so a
        -- single bad read can't trigger it), while the enemy is NOT
        -- confirmed fainted (enemyFainted is the same sticky flag used
        -- below - a legitimate last-PP-point KO also shows PP at 0, but
        -- that case is already correctly handled by the fainted-
        -- detection logic further down, so this must never compete with
        -- it). A real, ordinary turn has no reason to sit at 0 PP AND
        -- no battle controls AND no faint for 20 straight frames - only
        -- this exact stuck refusal does.
        if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 and not enemyFainted then
            ppStuckConfirmFrames = ppStuckConfirmFrames + 1
        else
            ppStuckConfirmFrames = 0
        end
        if ppStuckConfirmFrames >= PP_STUCK_CONFIRM_FRAMES then
            print("Thief mode: caught stuck on a 'no PP left' refusal for move slot 1 - backing out without attacking so hunting can continue normally.")
            if not thiefPpDepletedNotified then
                thiefPpDepletedNotified = true
                send_alert("Thief mode: move slot 1 is out of PP - pausing Thief steals until you restore it (Elixir/PP Up/etc). Continuing to hunt normally in the meantime.", COLOR_BLUE)
            end
            press_button("B")
            return "skipped"
        end

        -- CORRECTION, round 3 (real user report): species_addr reading
        -- 0 is NOT on its own reliable proof the battle ended, even
        -- across many consecutive frames - a real log showed it holding
        -- at 0 for well over the 30-frame debounce this used to rely on
        -- alone, WHILE the wild Pokemon (Muk) was still fully alive and
        -- the battle carried on right after (a fresh "Battle menu
        -- loaded" a moment later, then a normal flee). That false
        -- "fainted" conclusion made this return early mid-turn, before
        -- the steal's own held-item write had actually landed yet -
        -- exactly matching the report: item not taken, no Discord
        -- notification, because the caller checked the lead's held item
        -- far too early.
        --
        -- Fix: only let species_addr==0 count toward "the battle ended"
        -- when we ALREADY independently know from the enemy's own HP
        -- that this attack genuinely fainted it. If the enemy's HP has
        -- never once read 0 (see the sticky-latch comment above), no
        -- amount of species_addr misreads should ever be trusted as a
        -- battle end - so this simply never counts toward the debounce,
        -- and the loop just keeps waiting for have_battle_controls
        -- exactly like it always did for an ordinary non-fainting turn.
        if memory.read_u16_be(enemy_hp_addr) == 0 then
            enemyFainted = true
        end
        if enemyFainted and memory.readbyte(species_addr) == 0 then
            battleEndConfirmedFrames = battleEndConfirmedFrames + 1
        else
            battleEndConfirmedFrames = 0
        end
        if not battleEndConfirmed and battleEndConfirmedFrames >= BATTLE_END_CONFIRM_FRAMES then
            battleEndConfirmed = true
            vprint("Thief mode: battle end confirmed - mashing through any leftover EXP/level-up text for a bit before handing off.")
        end
        if battleEndConfirmed then
            postFaintFlushFrames = postFaintFlushFrames + 1
            if postFaintFlushFrames >= POST_FAINT_TEXT_FLUSH_FRAMES then
                -- The battle ended right when/after we attacked (most
                -- likely the wild Pokemon fainted from the hit) - this
                -- is a normal, harmless battle end, not a stuck bot,
                -- and by now any leftover EXP/level-up text has had a
                -- solid stretch of real A presses to clear. The caller
                -- checks the lead's actual held item directly to see
                -- whether the steal landed before this KO, rather than
                -- trusting any battle-address reads here (those go
                -- stale the instant the battle state clears).
                vprint("Thief mode: battle ended right after the attack (likely the wild Pokemon fainted from it) - treating this as a clean battle end, not stuck.")
                return "fainted"
            end
        end

        -- Same reasoning as do_kill_turn's own copy of this check: our
        -- own Pokemon fainting mid-turn (confusion self-hit, recoil,
        -- etc.) opens a "send out next Pokemon"/whiteout prompt that
        -- blind A-mashing can't safely resolve.
        local ownHP = memory.read_u16_be(OWN_HP_ADDR)
        if ownHP == 0 then
            ownFaintConfirmedFrames = ownFaintConfirmedFrames + 1
        else
            ownFaintConfirmedFrames = 0
        end
        if ownFaintConfirmedFrames >= 3 then
            print("Thief mode: your own Pokemon appears to have fainted mid-turn (confusion self-hit, recoil, etc.) - stopping so you can send out a replacement manually.")
            return "stuck"
        end

        -- Same move-learn-prompt guard as do_kill_turn - see its own
        -- comment above for the full rationale. Shares that function's
        -- battleLevelBaseline/learnMovePromptDetected state (captured
        -- once at battle start in M.step(), not per-attack), so it
        -- stays correct across Thief's own multi-attempt retry loop
        -- within the same battle.
        if learnMovePromptDetected then
            if battleLevelBaselineMoveCount ~= nil and battleLevelBaselineMoveCount < 4 then
                vprint("Thief mode: move-learn prompt detected, but a free move slot was available at battle start - auto-fills with no risk, continuing.")
                learnMovePromptDetected = false
            else
                print("Thief mode: move-learn prompt detected - stopping immediately so you can decide (this Pokemon likely also just leveled up).")
                return "stuck"
            end
        end
        local currentLevel = get_active_mon_level()
        -- Also reject anything above the real maximum level (100) -
        -- confirmed via a real user report: a Thief attack that
        -- one-shots the wild Pokemon (fainting it) can read
        -- get_active_mon_level() as 255 during that same battle-end
        -- teardown window - the same kind of transient WRAM corruption
        -- already documented above for the impossible 25->20 case, just
        -- in the other direction. Left unguarded, that fake level "255"
        -- reads as higher than levelBeforeAttack, stays consistent for
        -- 3 frames (it's a stable garbage value, not noise), and then
        -- makes learns_move_in_range() check almost the whole rest of
        -- the level table (levelBeforeAttack..255) - which is
        -- essentially guaranteed to match something, falsely declaring
        -- a move-learn prompt and stopping the bot when it actually
        -- just needed a few more A presses to finish leaving battle.
        if currentLevel > levelBeforeAttack and currentLevel <= 100 and currentLevel == lastSeenLevel then
            confirmedHigherLevelFrames = confirmedHigherLevelFrames + 1
        else
            confirmedHigherLevelFrames = (currentLevel > levelBeforeAttack and currentLevel <= 100) and 1 or 0
        end
        lastSeenLevel = currentLevel
        if confirmedHigherLevelFrames >= 3 and learns_move_in_range(activeSpecies, levelBeforeAttack, currentLevel) then
            if battleLevelBaselineMoveCount ~= nil and battleLevelBaselineMoveCount < 4 then
                vprint(string.format("Thief mode: level increase to %d with a move-learn possible, but a free move slot was available at battle start - auto-fills with no risk, continuing.", currentLevel))
            else
                print(string.format("Thief mode: level increase to %d - this species learns a move somewhere in that range, a learn-prompt is likely showing. Stopping so you can decide.", currentLevel))
                return "stuck"
            end
        end

        emu.frameadvance()
        press_button("A")
        postAttackWait = postAttackWait + 1
        if postAttackWait > postAttackTimeout then
            if enemyFainted then
                print(string.format("Thief mode: enemy fainted but the battle still hasn't ended after %d+ frames - likely a move-learn or evolution prompt. Stopping so you can decide.", postAttackTimeout))
            else
                print(string.format("Thief mode: stuck after attacking for %d+ frames (likely a move-learn or evolution prompt) - stopping so you can handle it manually", postAttackTimeout))
            end
            return "stuck"
        end
    end

    return "ok"
end

-- Extracted so both the plain "nothing else applies" case and the
-- "just used Thief, now flee like normal" case can share the exact same
-- flee logic - see wild.lua's own copy for the full rationale.
local function flee_battle()
    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Fleeing battle...")

    local escapeAttempts = 0
    local fledSuccessfully = false
    while not fledSuccessfully and escapeAttempts < 5 and memory.readbyte(species_addr) ~= 0 do
        escapeAttempts = escapeAttempts + 1

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

    shinyvalue = 0
    shinyLatchedThisBattle = false
end

-- ===== Auto-unequip Thief's stolen item =====
-- See wild.lua's own copy of this comment for the full rationale, the
-- USER-CONFIRMED button-press counts (Start menu: 1 Down to POKEMON;
-- action menu: 3 Downs to ITEM for a Thief user with no field moves),
-- and the safety notes (a wrong action-menu count risks landing on
-- SWITCH, which reorders the party). Ported verbatim - same menu flow,
-- same risks, same UNVERIFIED-outside-battle caveat on MENU_CURSOR_Y/X.
local ITEM_MENU_DOWN_PRESSES = 3

-- See wild.lua's own copy of this comment for the full rationale (a
-- real user report proved a single species_addr==0 read plus a flat
-- 30-frame buffer wasn't enough after a Thief steal specifically -
-- Start got pressed too early, mid-fade back to the overworld, and was
-- silently swallowed). Requires this many CONSECUTIVE zero-reads
-- instead, the same fix already proven for the exact same problem via
-- REQUIRED_SETTLE_FRAMES elsewhere in this file (out of scope here, so
-- duplicated as its own local constant).
local THIEF_LEAD_ITEM_SETTLE_FRAMES = 90

-- Shared menu-driving sequence behind both auto_unequip_thief_item()
-- (mid-hunt, right after a successful Thief steal) and the one-time
-- startup lead-held-item check (see check_and_clear_lead_item_on_startup
-- below) - see wild.lua's own copy of this comment for the full
-- rationale. contextLabel prefixes this function's print/vprint lines
-- so console output still makes it obvious which feature triggered it.
local function take_item_from_lead(contextLabel)
    local consecutiveZeroFrames = 0
    local totalWaitFrames = 0
    while consecutiveZeroFrames < THIEF_LEAD_ITEM_SETTLE_FRAMES and totalWaitFrames < 600 do
        if memory.readbyte(species_addr) == 0 then
            consecutiveZeroFrames = consecutiveZeroFrames + 1
        else
            consecutiveZeroFrames = 0
        end
        emu.frameadvance()
        totalWaitFrames = totalWaitFrames + 1
    end
    if consecutiveZeroFrames < THIEF_LEAD_ITEM_SETTLE_FRAMES then
        print(string.format("%s: couldn't confirm a clean return to the overworld before clearing the held item - skipping this time.", contextLabel))
        return
    end

    vprint(string.format("%s: auto-unequip starting - cursor Y=%d X=%d (diagnostic only, not gated on)",
        contextLabel, memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))

    -- DIAGNOSTIC - see wild.lua's own copy of this comment for the full
    -- rationale (a real user report showed Start pressing Down instead
    -- of opening the menu, suggesting "Start" may not be the right
    -- joypad key name for this core).
    do
        joypad.set({Start = true})
        local okGet, joypadState = pcall(joypad.get)
        if okGet and joypadState then
            local pressed = {}
            for k, v in pairs(joypadState) do
                if v then table.insert(pressed, tostring(k)) end
            end
            print(string.format("%s: right after setting Start=true, joypad.get() shows pressed: %s",
                contextLabel, (next(pressed) and table.concat(pressed, ", ") or "NOTHING - 'Start' is likely not the right key name for this core")))
        else
            print(string.format("%s: joypad.get() unavailable - can't verify the button name this way.", contextLabel))
        end
    end
    for i = 1, 3 do
        joypad.set({Start = true})
        emu.frameadvance()
    end
    emu.frameadvance()
    for i = 1, 60 do emu.frameadvance() end
    press_button("Down") -- POKEDEX -> POKEMON (user-confirmed: 1 press)
    for i = 1, 15 do emu.frameadvance() end
    press_button("A") -- open the party list
    -- Raised from 45 - see wild.lua's own copy of this comment for the
    -- full rationale (a real user report showed the next A press, meant
    -- to select the lead, having no effect - the party list's icon/HP-
    -- bar draw-in likely needs longer than a simple text menu does).
    for i = 1, 100 do emu.frameadvance() end
    vprint(string.format("%s: about to press A to select the lead - cursor Y=%d X=%d (diagnostic only, not gated on)",
        contextLabel, memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    press_button("A") -- select the lead (party slot 1, default-highlighted)
    for i = 1, 45 do emu.frameadvance() end
    vprint(string.format("%s: after pressing A on the lead - cursor Y=%d X=%d (diagnostic only, not gated on)",
        contextLabel, memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))

    for i = 1, ITEM_MENU_DOWN_PRESSES do
        press_button("Down")
        for j = 1, 15 do emu.frameadvance() end
    end
    press_button("A") -- select ITEM
    for i = 1, 30 do emu.frameadvance() end
    press_button("Down") -- GIVE -> TAKE
    for i = 1, 15 do emu.frameadvance() end
    press_button("A") -- confirm TAKE
    for i = 1, 45 do emu.frameadvance() end

    -- Raised from 4 to 8 - see wild.lua's own copy of this comment (a
    -- real user report confirmed the flow otherwise works, but 4 B
    -- presses weren't quite enough to fully back out of every menu
    -- layer every time - extra presses once already back in the
    -- overworld are harmless no-ops).
    for i = 1, 8 do
        press_button("B")
        for j = 1, 20 do emu.frameadvance() end
    end

    vprint(string.format("%s: auto-unequip finished - cursor Y=%d X=%d (diagnostic only)",
        contextLabel, memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    print(string.format("%s: cleared the held item off your lead Pokemon. (If your Bag's pocket was full, this may not have actually worked - check in-game if it's still holding it.)", contextLabel))
end

-- Thin wrapper kept so the existing Thief-mode caller site doesn't need
-- to change at all - just labels the shared sequence above.
local function auto_unequip_thief_item()
    take_item_from_lead("Thief mode")
end

-- ===== Startup check: clear any pre-existing held item off the lead =====
-- See wild.lua's own copy of this comment for the full rationale.
-- Deliberately unconditional (not gated on Thief mode being enabled).
local function check_and_clear_lead_item_on_startup()
    local leadItem = get_lead_held_item()
    if leadItem == 0 then
        vprint("Startup check: lead Pokemon isn't holding anything - nothing to clear.")
        return
    end
    local leadItemName = get_item_name(leadItem)
    print(string.format("Startup check: your lead Pokemon is already holding %s - clearing it before hunting begins.", leadItemName))
    take_item_from_lead("Startup check")
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

    local caughtSpeciesId = memory.readbyte(species_addr)
    local caughtSpeciesName = get_pokemon_name(caughtSpeciesId)
    local caughtItemName = get_item_name(memory.readbyte(item_addr))

    if isShiny and shinyEmbedFields then
        send_discord_embed(string.format("%s%s found! Attempting to catch it automatically.", label, caughtSpeciesName),
            nil, shinyEmbedFields, COLOR_GOLD, shinySpriteUrl)
    else
        send_catch_notification(string.format("%s%s found! Attempting to catch it automatically.", label, caughtSpeciesName),
            COLOR_GOLD, caughtSpeciesId, isShiny, caughtItemName)
    end

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
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu timeout).", label, caughtSpeciesName),
            COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return true
    end

    for i = 1, 60 do
        emu.frameadvance()
    end

    local ballId = find_ball_in_bag()
    if not ballId then
        print("No balls in the bag - stopping so you can restock and catch it manually.")
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (no balls left).", label, caughtSpeciesName),
            COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return true
    end

    -- Skippable entirely via "Don't weaken enemy Pokemon" in Auto-Catch
    -- Settings - see wild.lua's do_catch_sequence for the full reasoning
    -- (identical logic, mirrored here).
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
            send_catch_notification(string.format("%s%s was not caught, most likely fainted.", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            for i = 1, 400 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return true
                end
                press_button("B")
            end
            return false
        elseif result == "stuck" then
            print("Catch-mode: got stuck while weakening the enemy (likely fainted) - clearing messages and resuming the hunt.")
            send_catch_notification(string.format("%s%s was not caught, most likely fainted.", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
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
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (ran out of balls mid-catch).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end

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
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (navigation stuck).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return true
        end

        catchOutcomeSucceeded = false
        catchOutcomeFailed = false
        local waitFrames2 = 0
        while not catchOutcomeSucceeded and not catchOutcomeFailed and waitFrames2 < 1200 do
            if stop_was_requested() then
                print("Catch-mode: Stop requested - aborting.")
                return true
            end
            press_button("A")
            for i = 1, 15 do
                emu.frameadvance()
            end
            waitFrames2 = waitFrames2 + 20
        end

        if catchOutcomeSucceeded then
            print("Caught! Declining nickname prompt and clearing follow-up messages...")
            if isShiny then
                Stats.record_catch(caughtSpeciesId)
            end
            local ballsUsed = throws + 1 -- throws only counts FAILED attempts; this successful one isn't in it yet
            send_catch_notification(string.format("%s%s caught successfully via auto-catch! (used %d Ball%s)",
                label, caughtSpeciesName, ballsUsed, ballsUsed == 1 and "" or "s"),
                COLOR_GREEN, caughtSpeciesId, isShiny, caughtItemName)
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
            -- Budget raised from a flat 300 to 900, and a stop_was_requested()
            -- check added (missing before, unlike every other wait loop in
            -- this function): confirmed via a real user report (console log
            -- showing "Ball thrown (1/20) - it broke free, trying again."
            -- immediately followed by "Catch-mode: failed to navigate to
            -- the ball") that the wild Pokemon getting its own turn here -
            -- e.g. using Thunder Wave and paralyzing the player's Pokemon -
            -- adds a SECOND message on top of "It broke free!", more
            -- dialogue than 300 frames of A-mashing reliably clears. When
            -- that happened, have_battle_controls was still false when this
            -- loop gave up, and navigate_to_pack_and_select_ball() below -
            -- whose own PACK-selection loop only runs `while have_battle_
            -- controls`- silently skipped straight to scrolling a menu that
            -- was never actually open, eventually failing with a confusing
            -- "couldn't find the ball" instead of describing what actually
            -- happened.
            have_battle_controls = false
            local recoverFrames = 0
            while not have_battle_controls and recoverFrames < 900 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return true
                end
                press_button("A")
                recoverFrames = recoverFrames + 1
            end
            if not have_battle_controls then
                -- CORRECTION (real user report, shiny Delibird - see
                -- wild.lua's own copy of this comment for the full
                -- rationale): before concluding this needs manual
                -- intervention, check whether the battle has actually
                -- already ENDED - species_addr reading 0 means there's no
                -- wild Pokemon left to have a battle menu for at all. The
                -- most likely real cause: the wild Pokemon used its own
                -- turn (after the failed throw) to flee instead of
                -- attacking, which genuinely ends the battle outright -
                -- a normal, harmless outcome, not an error worth stopping
                -- the whole bot over.
                if memory.readbyte(species_addr) == 0 then
                    -- Still need to rule out our own Pokemon fainting
                    -- instead (recoil, confusion self-hit, a status
                    -- condition, etc, on the wild Pokemon's turn) - same
                    -- OWN_HP_ADDR check do_kill_turn/do_thief_turn already
                    -- use for exactly this. That genuinely does need a
                    -- replacement sent out manually, so it still stops.
                    if memory.read_u16_be(OWN_HP_ADDR) == 0 then
                        print("Catch-mode: your own Pokemon appears to have fainted during the wild Pokemon's turn (after the failed throw) - stopping so you can send out a replacement manually.")
                        send_catch_notification(string.format("%s%s could not be caught - your Pokemon fainted before the next throw. Bot stopped, send out a replacement.", label, caughtSpeciesName),
                            COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
                        return true
                    end
                    print("Catch-mode: the wild Pokemon appears to have fled during its own turn after the failed throw - resuming the hunt normally.")
                    send_catch_notification(string.format("%s%s got away (likely fled) before it could be caught - continuing the hunt.", label, caughtSpeciesName),
                        COLOR_BLUE, caughtSpeciesId, isShiny, caughtItemName)
                    return false
                end
                -- species_addr is still nonzero - still nominally the
                -- same battle, so this isn't a flee/faint - a real stuck
                -- state worth stopping for.
                print("Catch-mode: battle menu didn't reload after the failed throw within the extended timeout - stopping so you can take over.")
                send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu didn't return after a failed throw - possibly stuck on an unexpected prompt).", label, caughtSpeciesName),
                    COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
                return true
            end
        else
            print("Catch-mode: timed out without a determined outcome - backing out with B and retrying.")
            for i = 1, 10 do
                press_button("B")
                if have_battle_controls then break end
            end
            throws = throws + 1
        end
    end

    print("Ran out of throw attempts (" .. maxThrows .. ") without catching it - stopping so you can take over.")
    send_catch_notification(string.format("%s%s could not be caught, bot stopped (ran out of throw attempts).", label, caughtSpeciesName),
        COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
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
    -- is out of PP (see MOVE2_CURSOR's definition above for the caveat
    -- on this). The caller already confirmed at least one of the two
    -- has PP before deciding to kill at all, so this only ever needs to
    -- move the cursor, never bail out itself.
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

    -- TIMEOUT: a "would you like to learn a new move?" or evolution
    -- prompt does not re-trigger the battle-menu hook this loop is
    -- waiting on, so without a limit here it can loop forever - which
    -- prevents Stop from working (step() never returns control to the
    -- launcher while stuck in an internal loop). If hit, signal the
    -- caller to stop the bot entirely rather than guess navigation.
    have_battle_controls = false
    local postAttackWait = 0
    local ownFaintConfirmedFrames = 0
    -- Confirmed via a real user report: the second-move fallback can
    -- time out at the normal budget on a confused turn. Give it
    -- significantly more room before giving up, since that's
    -- specifically where this has been observed - move 1 has been
    -- reliable every time, so its timeout is left as-is.
    local postAttackTimeout = usedSecondMove and 1800 or 600
    -- NOTE: a cursor-position-based backup for have_battle_controls was
    -- tried here and REMOVED after a confirmed real-world failure:
    -- MOVE2_CURSOR and PACK_CURSOR share the same coordinate (both
    -- menus reuse the same underlying cursor address), so "the cursor
    -- changed" can't safely mean "back at the top menu" versus "still
    -- in a submenu showing a different move" - a false positive let a
    -- later turn misfire and open the BAG mid-battle instead of
    -- selecting a move (confirmed via a user screenshot of the ITEMS
    -- menu open). Relying on the hook plus the plain timeout below
    -- fails SAFELY instead of corrupting what menu the bot thinks it's
    -- looking at.
    --
    -- Ported from wild.lua after a confirmed real-world gap: extending
    -- postAttackTimeout to 1800 frames for the second-move case (above)
    -- gave blind A-mashing enough real time to fully resolve a
    -- move-learn prompt on its own before this timeout ever fired -
    -- confirmed via a user report of the bot "spamming" through a
    -- new-move prompt until the game forced a move to be learned. The
    -- level-based check below stops BEFORE that can happen, same as
    -- wild.lua.
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
        -- Own Pokemon fainting mid-turn (confusion hitting itself,
        -- recoil, etc.) throws the battle into a "send out next
        -- Pokemon" or whiteout prompt that blind A-mashing can't
        -- safely resolve - it could confirm sending out whichever
        -- party member the cursor happens to be on. Confirmed via a
        -- real user report: a confusion status during the second-move
        -- fallback led to exactly this kind of stuck loop. Require 3
        -- consecutive confirmed-0 frames before trusting it, to rule
        -- out a single bad read.
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
        -- Check BEFORE pressing - see wild.lua's do_kill_turn() for the
        -- full reasoning (a move can only be learned on a level-up, so
        -- the instant level increases, a move-learn prompt could be
        -- showing right now - stop before any further A press could
        -- risk confirming it).
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
        -- Require the SAME level value confirmed across 3 consecutive
        -- frames before trusting it - a single read can be corrupted
        -- during the EXP-gain/level-up animation window.
        -- Also reject anything above the real maximum level (100) -
        -- confirmed via a real user report: a Thief attack that
        -- one-shots the wild Pokemon (fainting it) can read
        -- get_active_mon_level() as 255 during that same battle-end
        -- teardown window - the same kind of transient WRAM corruption
        -- already documented above for the impossible 25->20 case, just
        -- in the other direction. Left unguarded, that fake level "255"
        -- reads as higher than levelBeforeAttack, stays consistent for
        -- 3 frames (it's a stable garbage value, not noise), and then
        -- makes learns_move_in_range() check almost the whole rest of
        -- the level table (levelBeforeAttack..255) - which is
        -- essentially guaranteed to match something, falsely declaring
        -- a move-learn prompt and stopping the bot when it actually
        -- just needed a few more A presses to finish leaving battle.
        if currentLevel > levelBeforeAttack and currentLevel <= 100 and currentLevel == lastSeenLevel then
            confirmedHigherLevelFrames = confirmedHigherLevelFrames + 1
        else
            confirmedHigherLevelFrames = (currentLevel > levelBeforeAttack and currentLevel <= 100) and 1 or 0
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
            print(string.format("Stuck after attacking for %d+ frames (likely a move-learn or evolution prompt) - stopping so you can handle it manually", postAttackTimeout))
            return "stuck"
        end
    end
end

-- ===== Headbutt-specific: 4 A presses while facing the tree, then check =====
-- Confirmed directly: unlike fishing's cast-and-wait, headbutt is
-- immediate - 4 presses performs the headbutt, and you either get an
-- encounter or you don't, no waiting period needed.
-- Entropy injection - see wild.lua's WILD_JITTER_RANGE comment for the
-- full statistical writeup (14,822-encounter log analysis that found the
-- two DV bytes correlated far beyond chance, most likely because both
-- are read back-to-back inside one encounter's own ROM routine). Same
-- fix here, same reasoning, same conservative default: bounded well
-- below RngEnabler's reset-oriented SPLIT_RANGE=256 since this fires
-- every single headbutt attempt, not once per reset.
local HEADBUTT_JITTER_RANGE = 64

local function do_headbutt_cycle()
    -- Burns a random 1-64 idle frames before every attempt so consecutive
    -- encounters don't keep landing on the same frame-timing relationship
    -- between the two DV-roll reads. Safe blind here, same as wild.lua -
    -- Gen 2 only rolls an encounter on the headbutt attempt itself, never
    -- while idle beforehand.
    RngEnabler.enable_randomness(HEADBUTT_JITTER_RANGE)

    vprint("Headbutting tree...")
    -- Deliberately NOT using the shared press_button() helper here.
    -- press_button() holds its button for 4 straight frames via
    -- joypad.set before ever checking species_addr again - the same
    -- shape of bug confirmed and fixed in wild.lua's try_unstuck():
    -- EnemyWildmonInitialized can fire mid-hold (during ANY
    -- emu.frameadvance(), including ones buried inside an in-flight
    -- press_button() call), so a "check once per full press" loop could
    -- keep forcing A down for up to 3 more frames after a real encounter
    -- had already started initializing. Checking species_addr before
    -- EVERY frame of each hold (not just before/after each full press)
    -- closes that window entirely.
    for i = 1, 4 do
        local encounterStarted = false
        for f = 1, 4 do
            if memory.readbyte(species_addr) ~= 0 then
                encounterStarted = true
                break
            end
            joypad.set({A = true})
            emu.frameadvance()
        end
        joypad.set({A = false})
        if encounterStarted then
            vprint("Encounter triggered mid-headbutt!")
            return
        end
        emu.frameadvance() -- frame buffer, matches press_button()'s own spacing
        if memory.readbyte(species_addr) ~= 0 then
            vprint("Encounter triggered mid-headbutt!")
            return
        end
    end

    if memory.readbyte(species_addr) ~= 0 then
        vprint("Encounter triggered!")
    else
        vprint("No encounter this headbutt - trying again")
    end
end

local overworld_loaded = false
local overworld_settle_frames = 0
-- Set true in M.on_resume() (once per Start press) and consumed exactly
-- once - the first time overworld_loaded is true afterward - by
-- check_and_clear_lead_item_on_startup() below. See wild.lua's own copy
-- of this comment for the full rationale.
local startupItemCheckPending = false
-- Was 10 - raised to match wild.lua's fix (identical architecture): a
-- real verbose wild.lua log proved species_addr can read 0 for 10+
-- consecutive frames purely as part of a battle's own intro transition,
-- firing this "back in overworld" detection (and the shiny fallback
-- notification/cleanup below it) while the battle was still in progress.
-- Raised to 90 to match this file's own documented worst-case species_addr
-- flicker duration around a battle boundary.
local REQUIRED_SETTLE_FRAMES = 90

-- ===== M.init =====
-- Hooks get REPLACED by name every time RegisterROMHook runs (confirmed
-- from data/memory.lua's own event.unregisterbyname call) - so whichever
-- module registered LAST keeps its hooks active, even after switching to
-- a "different" module, unless that module re-registers its own. This
-- must be called every time this module becomes active, not just once.
local function register_hooks()
    if LearnMoveAddr then
        Mem.RegisterROMHook(LearnMoveAddr, function()
            if ActiveModuleName ~= "headbutt" then return end
            learnMovePromptDetected = true
            vprint("LearnLevelMoves.learn entered - a move is being learned, stopping A presses")
        end, "Detect Move-Learn Prompt")
    end

    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "headbutt" then return end
        have_battle_controls = true
        if shinyNotificationPending then
            shinyNotificationBattleMenuSeen = true
        end
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    if MoveSelectionAddr then
        Mem.RegisterROMHook(MoveSelectionAddr, function()
            if ActiveModuleName ~= "headbutt" then return end
            moveSelectScreenOpen = true
            vprint("MoveSelectionScreen entered - move-select submenu confirmed open")
        end, "Detect Move Select Screen")
    end

    if CatchSuccessAddr then
        Mem.RegisterROMHook(CatchSuccessAddr, function()
            if ActiveModuleName ~= "headbutt" then return end
            catchOutcomeSucceeded = true
            vprint("PokeBallEffect.caught entered - the catch definitely succeeded")
        end, "Detect Catch Success")
    end

    if CatchFailAddr then
        Mem.RegisterROMHook(CatchFailAddr, function()
            if ActiveModuleName ~= "headbutt" then return end
            catchOutcomeFailed = true
            vprint("PokeBallEffect.shake_and_break_free entered - the Pokemon definitely broke free")
        end, "Detect Catch Failure")
    end

    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "headbutt" then return end
        if pendingEncounterUpdate then
            -- The previous hook firing's species/shinyvalue/atkdef/spespc
            -- (about to get overwritten below) never got consumed by
            -- M.step() - meaning that encounter's Stats.record_encounter/
            -- record_shiny call, GUI update, and Discord notification
            -- never ran for it. Flagged here rather than staying silent
            -- because this is the leading suspect for reports of the
            -- "since last shiny" counter not resetting despite a
            -- confirmed shiny appearing in the console log - if this
            -- warning shows up right before/around a shiny's encounter
            -- line, that shiny's bookkeeping was silently dropped.
            print(string.format(
                "WARNING: encounter update overwritten before M.step() processed it - previous encounter (%s, shiny=%s) never reached Stats/GUI/Discord.",
                get_pokemon_name(species), tostring(shinyvalue == 1)))
        end
        realEncounterConfirmed = true
        pendingBattleSettle = true
        thiefUsedThisBattle = false
        thiefPpCheckedThisBattle = false
        thiefLowHpCheckedThisBattle = false
        vprint("combat started")
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc)
        -- Latched here, synchronously - see shinyLatchedThisBattle's
        -- declaration near the top of the file.
        shinyLatchedThisBattle = (shinyvalue == 1)

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local encounterLine = string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName)
        print(encounterLine)

        sessionEncounterCount = sessionEncounterCount + 1

        -- See data/console_log.lua for the full rationale: BizHawk's own
        -- Lua console has no cap on accumulated output and gets slower
        -- to append to as its backlog grows, so we clear it ourselves
        -- periodically instead of making users do it manually. The same
        -- line is also written to a rotating on-disk log so clearing the
        -- console never actually loses anything.
        ConsoleLog.maybe_clear_console(sessionEncounterCount)
        ConsoleLog.log_encounter("headbutt", encounterLine)

        -- Stats bookkeeping (record_encounter / record_shiny) happens
        -- HERE, synchronously, instead of being deferred to M.step() via
        -- pendingEncounterUpdate like the GUI/Discord side still is.
        -- Deferring it bought nothing but risk: M.step()'s "in battle"
        -- handling runs its own internal emu.frameadvance() loop (the
        -- DV-wait below), so a SECOND hook firing during that window
        -- could silently overwrite species/shinyvalue/atkdef/spespc
        -- before M.step() ever got to record the FIRST encounter - a
        -- real, confirmed shiny vanishing from Stats and the "since last
        -- shiny" counter without a trace, while the console still prints
        -- it correctly (since that print, and the later filter/auto-catch
        -- decision, read shinyvalue directly rather than through Stats).
        -- Recording immediately here closes that window entirely: by the
        -- time anything could possibly clobber these locals, Stats
        -- already has this encounter locked in. This is safe to do from
        -- inside a hook - the documented callback restrictions are
        -- specifically emu.frameadvance (throws) and forms.* drawing
        -- (silently doesn't flush); Stats.record_* only touches Lua
        -- tables and io.open, neither of which is affected.
        local isShinyThisEncounter = (shinyvalue == 1)
        pendingEncounterStatsBeforeShiny = Stats.encountersSinceShiny
        Stats.record_encounter(species)

        -- pendingShinyFields/pendingShinySpriteUrl (the Discord embed's
        -- data) are ALSO built synchronously here now, for the exact same
        -- reason Stats moved up here - a real user log showed two
        -- confirmed shinies (Stats correctly recorded/reset, proven by
        -- the "Stats: shiny recorded" print) that never got a Discord
        -- notification at all, not even the "Discord embed skipped"
        -- diagnostic - meaning send_pending_shiny_embed() ran with
        -- pendingShinyFields still nil. That only happens if M.step()'s
        -- OWN re-check of `shinyvalue == 1` (done independently, later,
        -- possibly on a different tick) disagreed with this hook's
        -- isShinyThisEncounter - the same shared-mutable-global race,
        -- just hitting the embed-building code instead of Stats this
        -- time. Building the embed here, atomically with Stats, removes
        -- that race entirely: every field below is a pure computation
        -- (string formatting, table construction, memory.readbyte) - none
        -- of it touches emu.frameadvance or forms.*, so none of it is
        -- restricted inside a hook callback.
        pendingShinyFields = nil
        pendingShinySpriteUrl = nil
        if isShinyThisEncounter then
            Stats.record_shiny(species)
            print(string.format("Stats: shiny %s recorded - encounters since last shiny reset from %d to %d.",
                speciesName, pendingEncounterStatsBeforeShiny, Stats.encountersSinceShiny))

            local atkDV = math.floor(atkdef / 16)
            local defDV = atkdef % 16
            local speDV = math.floor(spespc / 16)
            local spcDV = spespc % 16
            local hpType, hpPower = hidden_power(atkDV, defDV, speDV, spcDV)
            pendingShinyFields = {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkDV, defDV, speDV, spcDV), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                {name = "Location", value = current_location_name(), inline = true},
                {name = "Held Item", value = itemName, inline = true},
                divider_field(),
                {name = "Encounters Since Last Shiny", value = tostring(pendingEncounterStatsBeforeShiny), inline = true},
                {name = "Encounters This Session", value = tostring(sessionEncounterCount), inline = true},
                {name = "Encounters Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                {name = "Shinies Of This Species", value = tostring(Stats.species_shiny_count(species)), inline = true},
                divider_field(),
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            }
            pendingShinySpriteUrl = shiny_sprite_url(species)
            shinyNotificationPending = true
            shinyNotificationBattleMenuSeen = false
        end

        pendingEncounterUpdate = true
    end, "Tell Display Battle Started / sending data")
end

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

    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, {"chkTrueRandomness"}) -- headbutt uses every encounter-related field; True Randomness only applies to soft-reset modules

    -- Confirmed via direct symbol lookup: wMenuCursorY/X live at
    -- completely different addresses between Crystal ($CFA9/$CFAA) and
    -- Gold/Silver ($CEE0/$CEE1) - using the wrong one meant the bot was
    -- reading unrelated memory during battle, so cursor-position checks
    -- never matched anything real and navigation always timed out.
    if version == 0x55 or version == 0x58 then
        MENU_CURSOR_Y = 0xCEE0
        MENU_CURSOR_X = 0xCEE1
        FIRST_MOVE_PP_ADDR = 0xCB14
        OWN_HP_ADDR = 0xCB1C
        OWN_MAX_HP_ADDR = 0xCB1E
        wCurItemAddr = 0xD002
        wItemsAddr = 0xD5B8
        wNumItemsAddr = 0xD5B7
        wBallsAddr = 0xD5FD
        wNumBallsAddr = 0xD5FC
    else
        MENU_CURSOR_Y = 0xCFA9
        MENU_CURSOR_X = 0xCFAA
        FIRST_MOVE_PP_ADDR = 0xC634
        OWN_HP_ADDR = 0xC63C
        OWN_MAX_HP_ADDR = 0xC63E
        wCurItemAddr = 0xD106
        wItemsAddr = 0xD893
        wNumItemsAddr = 0xD892
        wBallsAddr = 0xD8D8
        wNumBallsAddr = 0xD8D7
    end

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x53 then
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
        elseif region == 0x49 then
            -- Italian Crystal - split off from the merged EU branch above
            -- after a real bug report (static encounters, e.g. Snorlax,
            -- never detected) traced to EnemyWildmonInitialized firing at
            -- the wrong address on this build. Found via byte-signature
            -- scanning (diagnose_rom_addresses.lua) against a real Italian
            -- ROM, not disassembly - LoadBattleMenuAddr/MoveSelectionAddr
            -- happen to be byte-identical to English (same address);
            -- EnemyWildmonInitialized/CatchSuccessAddr/CatchFailAddr/
            -- LearnMoveAddr are shifted by a couple bytes. enemy_addr
            -- (0xD20C, same as English) is now CONFIRMED for this build
            -- too - a real mid-battle WRAM dump (diagnose_wram_addresses.lua)
            -- from dynux90 showed sensible, internally-consistent values
            -- (matching species, full-HP enemy_hp==enemy_max_hp, correct
            -- held item) reading from this address during an actual
            -- Lugia static battle, confirming WRAM layout is unchanged
            -- from English here.
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7649)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c4)
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f7)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bde)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c5) -- LearnLevelMoves.learn
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
            -- Verified against pokegold.sym: enemy_addr is wEnemyMonDVs
            -- ($D0F5), NOT $DA22 (which is actually wPartyCount).
            -- EnemyWildmonInitialized corrected to the .skip_unown
            -- sub-label ($7400), same reasoning as Crystal's hook.
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1) -- LearnLevelMoves.learn
            -- Verified against pokegold.sym: PokeBallEffect.caught and
            -- PokeBallEffect.shake_and_break_free, both bank $03.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            -- Verified against pokegold.sym: MoveSelectionScreen,
            -- bank $0F.
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x45 then
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1) -- LearnLevelMoves.learn
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            -- STILL UNVERIFIED - same enemy_addr=party_base_addr bug
            -- pattern just confirmed and fixed for EU/US, but no
            -- JP-specific symbol data available to correct it.
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1) -- LearnLevelMoves.learn
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            LearnMoveAddr = Mem.BankAddressToLinear(0x10, 0x64c1) -- LearnLevelMoves.learn
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
    -- base as enemy_addr in both games. wEnemyMonMaxHP is +0x0C.
    enemy_hp_addr = enemy_addr + 0x0A
    enemy_max_hp_addr = enemy_addr + 0x0C

    -- For the move-learn detection fix (see wild.lua for the full
    -- writeup): wCurBattleMon tells us which party slot is actually
    -- battling - version-specific address, same fix wild.lua needed.
    if version == 0x55 or version == 0x58 then
        curPartyMonAddr = 0xcfc6
    else
        curPartyMonAddr = 0xd0d4
    end
    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    end

    register_hooks()

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
        "Ready - stand facing a headbuttable tree...")
    return true
end

function M.on_switch_to()
    register_hooks()
    Gui.reconfigure(hud, {"chkTrueRandomness"})
    Gui.clear_last_encounter(hud)
end

function M.on_resume()
    overworld_settle_frames = 0
    overworld_loaded = false
    stopRequested = false
    stopReason = ""
    shinyvalue = 0
    shinyLatchedThisBattle = false
    battleWatchdogStartTime = nil
    battleWatchdogNextCheckTime = nil
    battleWatchdogDiscordSent = false
    overworldWatchdogStartTime = nil
    overworldWatchdogNextCheckTime = nil
    overworldWatchdogDiscordSent = false
    learnMovePromptDetected = false
    startupItemCheckPending = true
    killModeWasEnabled = false
    killModeAutosaveNextTime = nil
end

-- ===== M.step =====
function M.step()
    -- Kill mode safety savestates - see wild.lua's own copy of this
    -- comment for the full rationale. Checked every tick (cheap - just a
    -- forms.ischecked() read) so both a mid-run checkbox toggle AND a
    -- fresh Start click with it already checked are caught the same way.
    do
        local killModeEnabledNow = Gui.kill_non_shiny(hud)
        if killModeEnabledNow and not killModeWasEnabled then
            local saveOk = false
            pcall(function() saveOk = savestate.save(KILL_MODE_SAFETY_SAVE_PATH, true) end)
            if saveOk then
                print(string.format(
                    "Kill mode: safety savestate saved to %s - if a move-learn/level-up hiccup ever corrupts a move, load this file to get back to right before this Kill mode run started.",
                    KILL_MODE_SAFETY_SAVE_PATH))
            else
                print(string.format("Kill mode: WARNING - couldn't save the safety savestate to %s.", KILL_MODE_SAFETY_SAVE_PATH))
            end
            killModeAutosaveNextTime = os.time() + KILL_MODE_AUTOSAVE_INTERVAL_SECONDS
        elseif not killModeEnabledNow then
            killModeAutosaveNextTime = nil
        end
        killModeWasEnabled = killModeEnabledNow

        if killModeEnabledNow and killModeAutosaveNextTime and os.time() >= killModeAutosaveNextTime then
            local saveOk = false
            pcall(function() saveOk = savestate.save(KILL_MODE_AUTOSAVE_PATH, true) end)
            if saveOk then
                vprint(string.format("Kill mode: periodic autosave refreshed (%s).", KILL_MODE_AUTOSAVE_PATH))
            else
                print(string.format("Kill mode: WARNING - periodic autosave to %s failed.", KILL_MODE_AUTOSAVE_PATH))
            end
            killModeAutosaveNextTime = os.time() + KILL_MODE_AUTOSAVE_INTERVAL_SECONDS
        end
    end

    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick so the
    -- displayed location always reflects wherever you're actually
    -- headbutting right now, not just a snapshot from the last
    -- encounter.
    --
    -- Only updates when the (group, number) pair is a RECOGNIZED
    -- location - confirmed via a user report that during a battle these
    -- two WRAM bytes can transiently read as nonsense (e.g. "Map Group
    -- 15, #228", not a real place), presumably that RAM getting
    -- momentarily repurposed for battle-only data. Skipping the update
    -- on an unrecognized pair just keeps showing the last real location
    -- instead of flashing garbage on the Rich Presence card. Same
    -- pattern as wild.lua's M.step().
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
        local isShinyEncounter = shinyLatchedThisBattle
        -- Stats.record_encounter/record_shiny already ran synchronously
        -- inside the ROM hook above (see the comment there) - NOT
        -- repeated here, to avoid double-counting every encounter.

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Checking encounter...")
        Gui.update_last_encounter(hud, sessionEncounterCount, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

        -- pendingShinyFields/pendingShinySpriteUrl (and the Stats
        -- bookkeeping that goes with them) are already built synchronously
        -- inside the ROM hook above now - NOT rebuilt here, since redoing
        -- it from this point's (possibly stale, possibly clobbered)
        -- shinyvalue/species is exactly the race that used to cause a
        -- confirmed shiny to end up with no Discord embed at all. Only
        -- the GUI status text still needs updating from here.
        if isShinyEncounter then
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "SHINY FOUND!")
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

            -- A "stop on X" condition overrides EVERYTHING else -
            -- auto-catch, kill/flee, all of it - for this encounter.
            -- Returning immediately here, right after the notification
            -- above, is what makes that true - see wild.lua for the full
            -- writeup of the priority bug this fixes.
            return true
        end
    end

    local rawSpecies = memory.readbyte(species_addr)

    if rawSpecies == 0 then
        have_battle_controls = false
        overworld_settle_frames = overworld_settle_frames + 1
        if overworld_settle_frames >= REQUIRED_SETTLE_FRAMES then
            if not overworld_loaded then
                vprint("Ready to headbutt again")

                -- Fallback safety net - see shinyNotificationPending's
                -- declaration near the top of the file for the full
                -- writeup (ported from wild.lua's confirmed fix). If this
                -- is still armed right as we confirm we're back at the
                -- tree, the in-battle shiny-decision block provably never
                -- ran for that encounter. Uses shinyNotificationBattleMenuSeen
                -- (a real ROM-hook signal) to report actual evidence
                -- rather than guessing at a cause - "it likely got away"
                -- was an unverified assumption that doesn't match how
                -- Gen 2 wild battles actually work (the player always
                -- gets to act first).
                if shinyNotificationPending then
                    shinyNotificationPending = false
                    local missedName = get_pokemon_name(species)
                    local menuState = shinyNotificationBattleMenuSeen
                        and "the battle menu DID load (so the bot had controls at some point) but never acted before the battle ended"
                        or "the battle menu never loaded at all before the battle ended - the bot never had a chance to act"
                    print(string.format(
                        "WARNING: shiny %s was detected and recorded, but the battle ended before the bot ever got to act on it (no catch attempt, no stop) - %s - sending a fallback notification now.",
                        missedName, menuState))
                    send_pending_shiny_embed(missedName, string.format(
                        "\xE2\x9A\xA0\xEF\xB8\x8F Shiny %s detected but the battle resolved before auto-catch/kill handling ran (%s). Outcome not confirmed - check in-game. Fallback notification.",
                        missedName, shinyNotificationBattleMenuSeen and "battle menu loaded, no action taken" or "battle menu never loaded"))
                end

                battleWatchdogStartTime = nil
                battleWatchdogNextCheckTime = nil
                battleWatchdogDiscordSent = false
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
        -- Runs at most once per Start press - see startupItemCheckPending's
        -- declaration above and the reset in M.on_resume(). Gated on
        -- Thief mode actually being enabled - see wild.lua's own copy of
        -- this comment for the full rationale (a user not using Thief
        -- may be intentionally holding an item on their lead for an
        -- unrelated reason, so this must never touch it uninvited).
        if startupItemCheckPending then
            startupItemCheckPending = false
            if Gui.thief_mode_enabled(hud) then
                check_and_clear_lead_item_on_startup()
            else
                vprint("Startup check: Thief mode isn't enabled - leaving your lead's held item alone.")
            end
        end

        if overworldWatchdogStartTime == nil then
            overworldWatchdogStartTime = os.time()
            overworldWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
            overworldWatchdogDiscordSent = false
        elseif os.time() >= overworldWatchdogNextCheckTime then
            local stalledFor = os.time() - overworldWatchdogStartTime
            print(string.format("CAST WATCHDOG: no battle started after %d+ seconds of headbutt attempts - attempting automatic recovery", stalledFor))
            attempt_unstuck_recovery()
            overworldWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
            if not overworldWatchdogDiscordSent and stalledFor >= BATTLE_WATCHDOG_DISCORD_SECONDS then
                overworldWatchdogDiscordSent = true
                send_alert(string.format(
                    "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck while headbutting: no battle triggered after over %d seconds, despite automatic recovery attempts. Check on it.",
                    BATTLE_WATCHDOG_DISCORD_SECONDS), COLOR_RED)
            end
        end
        do_headbutt_cycle()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Headbutt...")

    elseif memory.readbyte(species_addr) ~= 0 then
        overworldWatchdogStartTime = nil
        overworldWatchdogNextCheckTime = nil
        overworldWatchdogDiscordSent = false
        if battleWatchdogStartTime == nil then
            battleWatchdogStartTime = os.time()
            battleWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
            battleWatchdogDiscordSent = false
            -- Capture the level baseline HERE, at the very start of the
            -- battle, before any attack has happened at all - setting it
            -- lazily inside do_kill_turn() is too late, since that
            -- function both executes the attack AND sets up the
            -- post-attack wait in the same call. Same fix as wild.lua.
            battleLevelBaseline = get_active_mon_level()
            battleLevelBaselineSpecies = get_active_mon_species()
            battleLevelBaselineMoveCount = get_active_mon_move_count()
        elseif os.time() >= battleWatchdogNextCheckTime then
            local stalledFor = os.time() - battleWatchdogStartTime
            local enemyHP = memory.read_u16_be(enemy_hp_addr)
            if enemyHP == 0 then
                -- Always alerts immediately, regardless of the discord-
                -- escalation timer above - it's not a guess, the bot is
                -- genuinely stopping right here and needs input.
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
                battleWatchdogNextCheckTime = os.time() + BATTLE_WATCHDOG_SECONDS
                if not battleWatchdogDiscordSent and stalledFor >= BATTLE_WATCHDOG_DISCORD_SECONDS then
                    battleWatchdogDiscordSent = true
                    send_alert(string.format(
                        "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck in battle: same encounter still active after over %d seconds, despite automatic recovery attempts. Check on it.",
                        BATTLE_WATCHDOG_DISCORD_SECONDS), COLOR_RED)
                end
            end
        end
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
        -- item" should catch ANY Pokemon holding a matching item, shiny
        -- or not, same as "Kill non-shiny" works independently of
        -- shininess. See wild.lua/fishing.lua for the full design notes
        -- behind this decision tree.
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

        -- Reads the latch, not the raw shinyvalue - see
        -- shinyLatchedThisBattle's declaration near the top of the file.
        if shinyLatchedThisBattle then
            shinyNotificationPending = false
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
                    -- instead" exception list - no auto-catch attempt
                    -- follows, so send the detailed embed now.
                    print(string.format("Shiny %s found - on the auto-catch exception list, stopping for manual catching.", shinySpeciesName))
                    send_pending_shiny_embed(shinySpeciesName)
                    return true
                end

                if Gui.skip_already_caught_enabled(hud) and Stats.is_already_caught(shinySpecies) then
                    -- Living dex mode - already caught before, skip
                    -- auto-catching another one and fall through to the
                    -- normal kill/flee handling. No auto-catch
                    -- notification will follow, so send the detailed
                    -- embed now.
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
                        -- Confirmed via a real user report/screenshot (on
                        -- wild.lua, identical architecture to this file):
                        -- the very next M.step() tick after a successful
                        -- catch sometimes re-sent the SAME "Shiny found!"
                        -- embed with identical species/DVs. Root cause
                        -- traced through the actual code path: species_addr
                        -- is already documented above (do_catch_sequence's
                        -- own settling-wait comment) to flicker non-zero
                        -- for up to 90+ frames after a battle genuinely
                        -- ends. If M.step()'s top-level dispatch samples
                        -- species_addr during one of those blips, it
                        -- re-enters this "in battle" branch - and since
                        -- dv_flag_addr is also left at 0x01 from the battle
                        -- that just finished (nothing clears it), the
                        -- DV-wait loop's condition is already satisfied and
                        -- its body (the only bail-out check) never runs
                        -- even once. Execution falls straight through to
                        -- here with shinyvalue still 1 from the encounter
                        -- we just caught, since only a genuine new
                        -- encounter hook resets it. Explicitly clearing it
                        -- the moment a catch resolves closes that window -
                        -- a real new shiny always re-sets shinyvalue via
                        -- shiny() inside the ROM hook, so this can never
                        -- suppress a genuine one.
                        shinyvalue = 0
                        shinyLatchedThisBattle = false
                    end
                    return stillHunting
                else
                    -- Deliberately NOT returning here - let execution
                    -- fall through to the normal kill/flee handling
                    -- immediately below, same as any non-shiny
                    -- encounter would get. No auto-catch notification
                    -- will follow, so send the detailed embed now.
                    print(string.format("Shiny %s found, but doesn't match the auto-catch filter - skipping, continuing the hunt.", shinySpeciesName))
                    send_pending_shiny_embed(shinySpeciesName, string.format("\xF0\x9F\x94\x81 Shiny %s encountered, resuming hunt - not a current target", shinySpeciesName))
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
            local stillHunting = do_catch_sequence(false)
            if not stillHunting then
                -- Same root cause/fix as wild.lua's identical branch (see
                -- that comment for the full writeup): species_addr can
                -- flicker non-zero for up to 90+ frames after a battle
                -- ends, re-entering this dispatch before the next real
                -- encounter's hook has repopulated atkdef/spespc -
                -- leaving a stale Perfect-DV reading that can trigger an
                -- auto-catch on the following, genuinely different
                -- Pokemon. Clearing atkdef/spespc closes that window
                -- exactly like the `if atkdef and spespc then` guard a
                -- few lines up already relies on; a real new encounter
                -- always repopulates both via its own hook.
                atkdef = nil
                spespc = nil
            end
            return stillHunting
        end

        -- (stopRequested, if set, already returned true right after its
        -- Discord notification was sent, earlier in this same M.step()
        -- call - so this point is only ever reached when it's false.)

        if memory.readbyte(species_addr) ~= 0 then
            -- BOUNDED: this runs BEFORE the battle watchdog check
            -- happens, so an unbounded loop here would prevent the
            -- watchdog from ever getting a chance to fire at all.
            local initialWaitFrames = 0
            while not have_battle_controls and memory.readbyte(species_addr) ~= 0 and initialWaitFrames < 300 do
                emu.frameadvance()
                press_button("B")
                initialWaitFrames = initialWaitFrames + 1
            end

            -- PP reads as stale for a couple of frames immediately after
            -- a NEW battle menu first loads, before settling to its real
            -- value. Only wait for this ONCE per battle. Note:
            -- species_addr can transiently flicker to 0 for a single
            -- frame right at battle start, so this wait does NOT bail
            -- out early on that check - doing so previously cut the
            -- wait short after just 1 frame.
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
                -- Thief mode - see wild.lua's own copy of this same block
                -- for the full rationale (identical architecture to this
                -- file, ported verbatim).
                local thiefHasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0
                -- Thief-specific HP check (THIEF_LOW_HP_THRESHOLD, not
                -- the shared hpSafe used by Kill mode above) - see
                -- wild.lua's own copy of this comment for the rationale.
                local thiefHpSafe = thief_has_safe_hp()
                -- Set true only when a steal genuinely lands this turn -
                -- read after flee_battle() below to decide whether to
                -- run auto_unequip_thief_item() (see its own comment).
                local thiefStoleItemThisTurn = false

                -- REMOVED (real user report, with hard proof - see
                -- wild.lua's own copy of this comment for the full
                -- writeup): this used to be a proactive "out of PP"
                -- notice fired once per battle from a single speculative
                -- FIRST_MOVE_PP_ADDR read taken right when the battle
                -- menu loads. A real report showed it firing sandwiched
                -- directly between two genuinely successful Thief steals,
                -- with nothing done in between - proving this specific
                -- read can be flatly wrong even after a 60-frame
                -- debounce. Removed entirely rather than guess at a
                -- fourth debounce; it was never load-bearing for Thief's
                -- actual behavior (thiefHasPP above still gates whether
                -- Thief attempts to act this battle, and an occasional
                -- misread there just skips one battle's steal harmlessly,
                -- self-correcting next battle). The genuinely reliable
                -- PP-depletion detection/notification already lives in
                -- do_thief_turn() itself (the pre-attack re-check and the
                -- post-attack ROM-hook-driven catch), which only ever
                -- check PP at the exact moment it's actually about to be
                -- spent and have never been shown to false-positive.

                -- Low-HP notice - see wild.lua's own copy of this comment
                -- for the full rationale.
                if Gui.thief_mode_enabled(hud) and have_battle_controls and not thiefLowHpCheckedThisBattle then
                    thiefLowHpCheckedThisBattle = true
                    if not thiefHpSafe and not thiefLowHpNotified then
                        thiefLowHpNotified = true
                        print("Thief mode: HP is below 20% - pausing Thief steals until it recovers (healing/switching/etc). Continuing to hunt normally in the meantime.")
                        send_alert("Thief mode: HP below 20% - pausing steals until it recovers. Still hunting normally in the meantime.", COLOR_BLUE)
                    end
                end

                if Gui.thief_mode_enabled(hud) and not thiefUsedThisBattle and thiefHasPP and thiefHpSafe
                    and currentItem ~= 0
                    and species_matches_filter(Gui.thief_item_filter(hud), currentItem, currentItemName) then
                    thiefUsedThisBattle = true
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Using Thief...")

                    -- Keep using Thief across MULTIPLE turns of this same
                    -- battle (no flee_battle() in between) until the
                    -- steal lands or it's no longer safe/possible to keep
                    -- trying - see wild.lua's own copy of this comment
                    -- for the full rationale (Protect/Detect blocking a
                    -- steal used to cause an immediate flee with the item
                    -- never taken, even with PP left to just try again).
                    local THIEF_MAX_RETRY_ATTEMPTS = 15
                    local thiefAttempts = 0
                    while true do
                        thiefAttempts = thiefAttempts + 1
                        local thiefResult = do_thief_turn()
                        if thiefResult == "stuck" then
                            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                                "Stopped - Thief attack didn't return to the battle menu")
                            send_alert("\xE2\x9A\xA0\xEF\xB8\x8F Grinding stopped: Thief mode's attack didn't return to the battle menu in time (the wild Pokemon may have fainted from it, or something else needs your input). Handle it manually, then resume.", COLOR_RED)
                            return true
                        elseif thiefResult == "skipped" then
                            -- See do_thief_turn's own comment - no attack
                            -- actually happened, nothing to check the item
                            -- for. Falls straight through to the normal
                            -- flee below.
                            vprint("Thief: skipped this attempt (battle menu wasn't ready in time) - continuing normally")
                            break
                        elseif thiefResult == "fainted" then
                            -- The wild Pokemon fainted from this very
                            -- attack, ending the battle immediately -
                            -- do_thief_turn() already confirmed this is a
                            -- clean, harmless battle end (see its own
                            -- comment), not a stuck bot. Previously this
                            -- case fell through to do_thief_turn()
                            -- reporting "stuck" instead (no species_addr
                            -- exit condition existed at all), which is
                            -- the exact false-positive stop a real user
                            -- reported - restarting the bot afterward
                            -- "fixed" it only because the STARTUP
                            -- held-item check happened to clean up
                            -- whatever Thief had already stolen.
                            --
                            -- The enemy's own item_addr/species_addr
                            -- reads go stale the instant the battle
                            -- state clears, so they can't tell us
                            -- whether the steal landed before the KO -
                            -- check the LEAD's own held item directly
                            -- instead (get_lead_held_item(), the same
                            -- WRAM read the startup check already
                            -- trusts), which is unaffected by the battle
                            -- having ended.
                            local leadItemAfterThief = get_lead_held_item()
                            if leadItemAfterThief ~= 0 then
                                local leadItemName = get_item_name(leadItemAfterThief)
                                print(string.format("Thief: stole %s from %s right as it fainted from the attack!", leadItemName, currentSpeciesName))
                                -- Gated on the "Notify on Discord for
                                -- every item stolen" checkbox (Advanced
                                -- Settings, defaults to on) - see
                                -- wild.lua's own copy of this comment for
                                -- the full rationale.
                                if Gui.thief_notify_enabled(hud) then
                                    send_catch_notification(string.format("Thief: stole %s from %s right as it fainted!", leadItemName, currentSpeciesName),
                                        COLOR_GREEN, currentSpecies, false, leadItemName)
                                end
                                thiefStoleItemThisTurn = true
                            else
                                vprint(string.format("Thief: %s fainted from the attack, but the lead isn't holding anything afterward - the steal likely didn't land (or there was nothing to steal)", currentSpeciesName))
                            end
                            break
                        else
                            local thiefSpecies = memory.readbyte(species_addr)
                            local thiefSpeciesName = get_pokemon_name(thiefSpecies)
                            local itemAfterThief = memory.readbyte(item_addr)
                            if currentItem ~= 0 and itemAfterThief == 0 then
                                print(string.format("Thief: stole %s from %s!%s", currentItemName, thiefSpeciesName,
                                    thiefAttempts > 1 and string.format(" (took %d attempts - something was blocking earlier steals, e.g. Protect)", thiefAttempts) or ""))
                                -- Gated the same way as the fainted-on-
                                -- attack steal case above.
                                if Gui.thief_notify_enabled(hud) then
                                    send_catch_notification(string.format("Thief: stole %s from %s!", currentItemName, thiefSpeciesName),
                                        COLOR_GREEN, thiefSpecies, false, currentItemName)
                                end
                                thiefStoleItemThisTurn = true
                                break
                            elseif currentItem == 0 then
                                vprint("Thief: used, but the wild Pokemon wasn't holding anything to steal")
                                break
                            else
                                vprint(string.format("Thief: attempt %d used, but %s is still holding %s (likely blocked by Protect/Detect, or a miss)",
                                    thiefAttempts, thiefSpeciesName, currentItemName))
                                if memory.readbyte(species_addr) == 0 then
                                    vprint("Thief: battle already ended (wild Pokemon fled/fainted on its own) - nothing more to do")
                                    break
                                elseif not thief_has_safe_hp() then
                                    print("Thief: giving up further attempts this battle - HP below 20%, fleeing now")
                                    break
                                elseif memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 then
                                    vprint("Thief: out of PP for move slot 1 - can't try again this battle")
                                    break
                                elseif thiefAttempts >= THIEF_MAX_RETRY_ATTEMPTS then
                                    print(string.format("Thief: giving up after %d attempts this battle - moving on", thiefAttempts))
                                    break
                                end
                                -- Otherwise: loop again and use Thief once
                                -- more, same battle, no flee in between.
                            end
                        end
                    end
                end
                flee_battle()
                if thiefStoleItemThisTurn then
                    auto_unequip_thief_item()
                end
            end
        end
    end

    ::continue::
    return false
end

return M

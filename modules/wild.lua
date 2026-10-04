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
ConsoleLog = require("data.console_log")

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
-- Neutral "heads up, nothing's wrong" tone - used only for the one-time
-- Thief-PP-depleted notice below, so it doesn't read as an error (RED)
-- or get visually confused with a shiny-related notice (GOLD).
local COLOR_BLUE = 3447003

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
-- Containment fix for a confirmed, still-not-fully-root-caused bug: a
-- real verbose log (a shiny Raticate, "Stats: shiny recorded" printed
-- correctly, encounters-since-shiny genuinely reset 2237->0) proved that
-- by the time the in-battle decision block's own "Decision check"
-- diagnostic ran - just 1-2 M.step() ticks later, same battle, same
-- atkdef/spespc still reading the correct shiny values - shinyvalue had
-- already reverted to 0, and the bot went on to actually flee the real
-- shiny (not just a bad fallback notification). Every explicit
-- `shinyvalue = 0` assignment in this file was checked against that log
-- (shiny() itself, M.on_resume(), the two post-catch/post-flee cleanup
-- resets) and NONE of them could have fired for this encounter - no
-- second hook firing occurred either (would have unconditionally printed
-- a second "combat started", which the log doesn't show). The exact
-- mechanism is still unidentified. Rather than keep guessing at wild.lua
-- while a real shiny gets lost, this latches the hook's own verdict into
-- a SEPARATE variable that nothing else in this file writes to, and the
-- real catch/flee decision below reads THIS instead of the raw
-- shinyvalue - so whatever is clobbering shinyvalue (if anything still
-- is) can no longer flip a real shiny into a flee. Decision check now
-- prints both so a future recurrence will show directly whether they
-- ever diverge.
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
-- Thief mode (see chkThiefMode/txtThiefFilter in gui_module.lua, wild.lua
-- only): only ever attempt one Thief steal per battle, then always fall
-- through to the normal flee behavior regardless of the outcome. Without
-- this latch, the per-tick decision block below (which re-runs every
-- M.step() call for as long as the battle is still going) would try to
-- use Thief again on every subsequent turn instead of just fleeing after
-- the first attempt - the same "once per battle, not once per tick"
-- problem pendingBattleSettle above already had to solve. Reset to false
-- alongside pendingBattleSettle in the EnemyWildmonInitialized hook,
-- since both are scoped to exactly one battle.
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
-- check below runs exactly ONCE per genuine new battle. Without this,
-- the notification check re-ran on every M.step() tick for as long as
-- species_addr stayed nonzero - including the well-documented tail
-- window where species_addr flickers nonzero for up to 90+ frames AFTER
-- a battle has actually ended (see the shinyvalue/atkdef/spespc reset
-- comments further down). During that trailing window the battle-mon
-- WRAM struct FIRST_MOVE_PP_ADDR lives in is no longer valid battle
-- data, so thiefHasPP read as false on essentially every single battle's
-- tail end regardless of the real, current PP - this is the root cause
-- of the "out of PP" notice firing every battle even with full PP.
-- Latching the check to the battle's own properly-settled first tick
-- (right alongside pendingBattleSettle) avoids ever evaluating it during
-- that stale tail window.
local thiefPpCheckedThisBattle = false
-- Session-scoped and NEVER reset once set - same one-time-ever pattern
-- as thiefPpDepletedNotified above, per user request ("send a
-- notification once"). Fires the "Thief mode: HP too low" notice the
-- first time Thief would otherwise have a real steal available but HP
-- is below THIEF_LOW_HP_THRESHOLD, and never again for the rest of the
-- session even if HP recovers and later dips again.
local thiefLowHpNotified = false
-- Reset per-battle (alongside thiefUsedThisBattle/thiefPpCheckedThisBattle,
-- same hook) so this evaluates at most ONCE per genuine new battle - same
-- reasoning as thiefPpCheckedThisBattle's own comment above (avoids ever
-- evaluating during the stale post-battle tail window).
local thiefLowHpCheckedThisBattle = false

-- ===== Kill mode safety savestates =====
-- User-requested after a real report that Kill mode can occasionally hit
-- a "hiccup" around a level-up/move-learn prompt and end up overwriting
-- an existing move unexpectedly - these give the user somewhere safe to
-- reload back to if that ever happens, without having to lose the whole
-- session's progress.
--
-- Written as NAMED FILES via savestate.save(path, true) - the same
-- mechanism SavestateBackup (data/savestate_backup.lua) already uses for
-- Static/Starters/Egg/Game Corner's own backup files - rather than
-- numbered savestate.saveslot() slots. A user report pointed out slots
-- require knowing/selecting a specific slot number through BizHawk's own
-- Save/Load State UI, which is far less discoverable than a plainly-
-- named file sitting right in the same modules/data folder the other
-- backups already land in - the user can just browse there and load it.
-- This also sidesteps any slot-collision risk entirely (no shared
-- numbered slot to clobber someone's own manual save), so unlike the
-- Static/Starters/Egg/Game Corner reset-target slot, this doesn't need
-- to go through SavestateBackup's backup-the-prior-contents dance at
-- all - the filenames below are exclusively ours.
--
-- Both are FIXED filenames, overwritten every time (not timestamped per
-- occurrence) - deliberately, so there's always exactly one obvious file
-- to reload for each ("the safety save" / "the latest autosave") instead
-- of an ever-growing pile the user has to sort through by date.
--
-- Gated on Kill mode specifically being checked (Gui.kill_non_shiny) -
-- NOT on this module simply being active/running - per explicit
-- request: switching to wild.lua at all should never trigger this on
-- its own, only actually turning Kill mode on should.
local KILL_MODE_SAFETY_SAVE_PATH = script_dir .. "data/kill_mode_safety.State"
local KILL_MODE_AUTOSAVE_PATH = script_dir .. "data/kill_mode_autosave.State"
local KILL_MODE_AUTOSAVE_INTERVAL_SECONDS = 5 * 60
-- Reset to false in M.on_resume() (every Start click) - not just once
-- ever - so a fresh "right before this run" safety savestate gets taken
-- every time Kill mode is (re)started, whether the checkbox was just
-- ticked or was already checked from an earlier run this session. Also
-- doubles as the actual OFF->ON edge detector for mid-run checkbox
-- toggles, since Gui.kill_non_shiny() itself has no such tracking.
local killModeWasEnabled = false
-- Wall-clock deadline (os.time()) for the next periodic autosave - nil
-- while Kill mode is off (no autosave should be running at all then).
local killModeAutosaveNextTime = nil

local stopRequested = false
local stopReason = ""
-- Set true only by the ROM hook (a real, one-time confirmation that an
-- actual encounter started) - used so the DV-wait loop doesn't bail out
-- on a transient species_addr==0 blip during a real encounter's own
-- startup transition, while still catching genuinely spurious flickers
-- where no real battle ever started at all.
local realEncounterConfirmed = false
local pendingEncounterUpdate = false
-- Set true (alongside pendingEncounterUpdate) the instant the ROM hook
-- confirms a NEW encounter is shiny - cleared the moment the in-battle
-- shiny-decision block (the "if shinyvalue == 1 then" branch further
-- down M.step(), which unconditionally calls send_pending_shiny_embed()
-- in every one of its sub-branches) actually starts handling it. A real,
-- confirmed bug (see the fallback check where overworld_loaded flips
-- back true below) showed that block can, for reasons not yet fully
-- pinned down, sometimes never run for a battle at all even though the
-- ROM hook fired and Stats correctly recorded the shiny - meaning the
-- console's "Stats: shiny X recorded" print appeared with ZERO further
-- output (no "Shiny found!!", no catch attempt, no Discord message)
-- before the very next encounter started, as if that battle was never
-- actually processed. This flag is the safety net: if it's STILL true
-- once we're confirmed back in the overworld, the shiny was provably
-- never handled, so a fallback notification fires right there instead
-- of the user finding out only from "since last shiny" quietly dropping
-- with no explanation.
local shinyNotificationPending = false
-- Diagnostic companion to shinyNotificationPending, armed/reset
-- alongside it. Set true by the LoadBattleMenuAddr ROM hook (a real,
-- confirmed hook - see its own comment - that fires exactly when the
-- game loads the player-visible FIGHT/PKMN/ITEM/RUN menu, not a guess)
-- if that menu is ever actually reached while a shiny notification is
-- still pending. Lets the fallback warning below say, with real
-- evidence instead of a guess, whether the bot ever got a turn at all
-- for that encounter - a user correctly pointed out that "it likely
-- got away" was an unverified assumption baked into the original
-- fallback message, since a normal wild Pokemon doesn't flee before
-- the player gets to act.
local shinyNotificationBattleMenuSeen = false
-- Snapshot of Stats.encountersSinceShiny taken in the ROM hook, BEFORE
-- Stats.record_encounter/record_shiny run there - see the hook itself
-- for why stats bookkeeping moved out of M.step(). M.step() reads this
-- (instead of Stats.encountersSinceShiny directly) when building the
-- shiny Discord embed's "Encounters Since Last Shiny" field, since by
-- the time M.step() runs, Stats.encountersSinceShiny has already been
-- reset to 0 for a shiny encounter.
local pendingEncounterStatsBeforeShiny = 0
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
-- titleOverride lets a specific call site (e.g. the "doesn't match the
-- auto-catch filter, resuming hunt" case below) use wording that reflects
-- what's actually happening instead of the generic "Found!" title, which
-- read as misleadingly alarming/final for an encounter the bot is about
-- to just skip past and keep hunting through.
local function send_pending_shiny_embed(speciesName, titleOverride)
    if pendingShinyFields then
        local title = titleOverride or string.format("✨ Shiny %s Found!", speciesName)
        send_discord_embed(title, nil, pendingShinyFields, COLOR_GOLD, pendingShinySpriteUrl)
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
-- User-requested, Thief-specific HP floor - deliberately separate from
-- (and lower than) LOW_HP_FLEE_THRESHOLD above. Thief only ever risks
-- ONE attack before fleeing regardless of outcome (steal or miss) - it
-- never sustains multi-turn attacking the way Kill mode does - so it can
-- safely tolerate a slightly thinner margin than Kill mode's own 25%
-- without meaningfully increasing faint risk. Below this, Thief is
-- skipped entirely for the battle (falls straight through to a normal
-- flee) and the user gets a one-time notice - see thiefLowHpNotified's
-- own comment.
local THIEF_LOW_HP_THRESHOLD = 0.20

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

-- Same read, different (lower) threshold - see THIEF_LOW_HP_THRESHOLD's
-- own comment for why Thief gets its own, separate HP floor instead of
-- reusing has_safe_hp()/LOW_HP_FLEE_THRESHOLD directly.
local function thief_has_safe_hp()
    local currentHP = memory.read_u16_be(OWN_HP_ADDR)
    local maxHP = memory.read_u16_be(OWN_MAX_HP_ADDR)
    if maxHP == 0 then return true end
    return (currentHP / maxHP) > THIEF_LOW_HP_THRESHOLD
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
        -- Check BEFORE forcing input on this frame, not just after the
        -- full 4-frame hold completes - see try_unstuck()'s matching
        -- comment for why. EnemyWildmonInitialized can fire mid-hold,
        -- and continuing to hold a direction through frames the game
        -- never expected input on during a real encounter's own startup
        -- transition is exactly the kind of window that produced a
        -- confirmed encounter (Stats/DV print correct, M.step() in-battle
        -- branch never ran) elsewhere in this same failure class.
        if memory.readbyte(species_addr) ~= 0 then
            joypad.set({[direction] = false})
            return true
        end
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

    -- Idle grace period - NO input at all - before this function ever
    -- presses a button. Added after a live miss recurred even with the
    -- per-frame check below already in place: this watchdog message
    -- fires far too often (roughly 1 in every 25 encounters in a real
    -- log) to be mostly rare phone calls/signs. The much more likely
    -- explanation is that a real wild encounter's own screen-freeze,
    -- during the handful of frames between the triggering step and
    -- species_addr becoming readable as nonzero, LOOKS IDENTICAL to
    -- "stuck" from this watchdog's point of view - so a meaningful
    -- fraction of the time this fires, an encounter is already quietly
    -- in progress, not actually stuck at all. The per-frame check further
    -- down can still leave exactly one B-press asserted on the very
    -- frame the encounter's ROM hook fires (we can't know a frame is the
    -- critical one until after we've already committed input for it) -
    -- that's the gap this grace period closes: wait quietly first and
    -- let anything already in flight fully reveal itself BEFORE ever
    -- risking a button press into it. Only once nothing shows up here do
    -- we treat this as a genuine stuck-textbox and start mashing B.
    local GRACE_FRAMES = 60
    for i = 1, GRACE_FRAMES do
        emu.frameadvance()
        if memory.readbyte(species_addr) ~= 0 then
            vprint("A real encounter revealed itself during the unstuck grace period - not actually stuck, leaving it alone.")
            consecutive_movement_failures = 0
            return
        end
    end

    -- B, never A: some phone calls (rematch challenges) end in a
    -- "battle now? Yes/No" prompt, and mashing A could accidentally
    -- CONFIRM a trainer battle - something this bot has zero ability to
    -- handle (completely different menus/addresses than wild encounters).
    -- B is the safe cancel/decline button used everywhere else in this
    -- script for exactly this reason.
    --
    -- Deliberately NOT using the shared press_button() helper here.
    -- press_button() holds its button for 4 straight frames via
    -- joypad.set before ever checking species_addr again, and this loop
    -- calls it up to 80 times back-to-back with no gap - up to ~400
    -- frames where B can be getting forced down every single frame.
    -- EnemyWildmonInitialized (the wild-encounter ROM hook) fires the
    -- instant its ROM address executes, during ANY emu.frameadvance()
    -- call, including ones buried inside an in-flight press_button()
    -- hold - so the old "check once per full press" loop could keep
    -- forcing B for up to 3 more frames AFTER a real encounter had
    -- already started initializing. Confirmed via log correlation: in a
    -- real user log, every single missed-shiny encounter (3/3, where
    -- Stats/the DV print fired correctly straight from the hook but
    -- M.step()'s in-battle branch never ran at all for that battle) was
    -- immediately preceded by this exact "No real movement" message -
    -- this is the only place in the overworld dispatch that holds a
    -- button for this many consecutive frames unbroken. Checking
    -- species_addr before EVERY frame of the hold (not just after each
    -- full press) closes that window down to zero extra frames.
    for i = 1, 80 do
        local encounterStarted = false
        for f = 1, 4 do
            if memory.readbyte(species_addr) ~= 0 then
                encounterStarted = true
                break
            end
            joypad.set({B = true})
            emu.frameadvance()
        end
        joypad.set({B = false})
        if encounterStarted then break end
        emu.frameadvance() -- frame buffer, matches press_button()'s own spacing
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
-- First move slot on the move-select submenu (same numeric coordinate as
-- FIGHT_CURSOR, but a completely different screen - the submenu is its
-- own single-column list, unrelated to the top-level menu's 2x2 grid).
-- Added because do_thief_turn used to ASSUME move 1 was always already
-- highlighted when this submenu opens and skip navigating entirely -
-- confirmed via a real user report that this assumption doesn't always
-- hold (the submenu's cursor doesn't necessarily reset to move 1 between
-- turns/battles the way a fresh top-level battle menu resets to FIGHT),
-- so Thief could silently end up confirming whatever move was left
-- highlighted from an earlier turn instead of Thief itself - explaining
-- both "Thief never seems to actually fire" and "the item is never
-- stolen" at once, with no error, since a genuine non-Thief move was
-- still being used successfully every time.
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
-- Offset derivation: there's no ROM hook/symbol lookup available for
-- this at hunt-start (we're not in battle), so this is cross-checked
-- against two offsets this file ALREADY trusts and uses in production,
-- both independently confirmed above against pokecrystal.sym/
-- pokegold.sym:
--   - get_active_mon_move_count() reads Moves at party_base_addr +
--     0x0A + slotIndex*0x30 (verified via wPartyMon1Moves).
--   - get_active_mon_level() reads Level at party_base_addr + 0x27 +
--     slotIndex*0x30.
-- The standard Gen 1/2 party mon struct (confirmed via pokecrystal's
-- own constants/pokemon_data_constants.asm) orders fields as:
-- Species(+0), Item(+1), Moves(+2..+5), ..., Level(+31 = 0x1F). So each
-- mon's struct must start at party_base_addr + 0x08 - that's the only
-- value consistent with BOTH already-trusted offsets at once (0x08 + 2
-- = 0x0A matches Moves; 0x08 + 0x1F = 0x27 matches Level). Item is
-- struct offset +1, so for the lead (slot index 0):
--   party_base_addr + 0x08 + 1 = party_base_addr + 0x09
local LEAD_HELD_ITEM_ADDR_OFFSET = 0x09

local function get_lead_held_item()
    return memory.readbyte(party_base_addr + LEAD_HELD_ITEM_ADDR_OFFSET)
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

-- ===== Thief mode =====
-- Uses whatever's in move slot 1 exactly once (see chkThiefMode in
-- gui_module.lua) - the caller below already confirmed
-- FIRST_MOVE_PP_ADDR > 0 before calling this, and that move is assumed
-- to be Thief, per the whole premise of this feature: the user's lead
-- Pokemon has Thief taught in slot 1 themselves. This does NOT verify
-- the move actually IS Thief - there's no reliable memory address for
-- "move ID in slot 1" worth adding just to double-check something the
-- user already set up, and using whatever's genuinely there behaves
-- correctly either way (steals successfully if it's Thief, just acts as
-- a normal attack + a wasted PP if it isn't).
--
-- Deliberately does NOT fall back to move 2 the way do_catch_attack_turn/
-- do_kill_turn do when move 1 is out of PP - a random second move
-- stealing nothing defeats the entire point of "steal held items", so
-- running out of Thief PP should mean "don't attack at all this battle"
-- (handled by the caller checking PP before ever calling this), not
-- "attack with whatever's left instead."
--
-- Same known limitation as do_catch_attack_turn (see its own comment):
-- neither species_addr nor enemy_hp_addr is trustworthy enough right
-- after an attack to positively detect a faint, so this doesn't try to.
-- Thief is weak enough that fainting the wild Pokemon outright is rare,
-- but not impossible against a very low-level/low-HP encounter - if it
-- happens, the battle ends and have_battle_controls never returns true,
-- which reads identically to "stuck" below and stops the bot for you to
-- clear manually, exactly like do_catch_attack_turn's own unhandled-
-- faint case already does. Not treated as a bug to fix here - it's the
-- same accepted tradeoff already shipped for that function.
--
-- Returns "ok" (attack went through - caller checks the enemy's item
-- afterward to see if the steal actually landed) or "stuck" (navigation
-- failed, or the post-attack wait timed out).
local function do_thief_turn()
    -- CONFIRMED via a real user report + the diagnostic below: Thief can
    -- be the very FIRST attack attempted in a battle (unlike kill mode,
    -- which only ever runs after the caller's own earlier wait already
    -- succeeded in a previously-observed-working case) - and the
    -- caller's own "wait for the battle menu to load" loop (300 frames /
    -- 5 seconds, mashing B) is not always long enough before we get
    -- here, confirmed specifically on a fishing encounter (the rod-cast
    -- / "Oh! A bite!" intro runs longer than a standard grass encounter
    -- does). When that happens, have_battle_controls is STILL false the
    -- instant this function starts - and the `while have_battle_controls
    -- do` navigation loop further below is a Lua while-loop, which checks
    -- its condition BEFORE the first iteration: if it's already false,
    -- the loop body never runs even once, so it never reaches the
    -- FIGHT_CURSOR match OR the 12-attempt "stuck" cap - it just silently
    -- falls through to the move-select wait and a blind "confirm"
    -- button-press further down, having never actually opened FIGHT or
    -- selected anything, then still reports back "ok". That's exactly
    -- what a real user's log showed: "have_battle_controls=false, cursor
    -- Y=0 X=0" and "FIGHT navigation loop exited after 0 attempt(s)",
    -- with the real "Battle menu loaded" hook only firing AFTER this
    -- function had already returned.
    --
    -- Fix: actively wait for have_battle_controls to become true here,
    -- the same way the caller's own initial wait loop does, instead of
    -- assuming it already is. This makes Thief self-sufficient
    -- regardless of how long any particular encounter's intro runs, and
    -- doesn't touch/risk do_kill_turn's or do_catch_attack_turn's own
    -- already-battle-tested logic.
    if not have_battle_controls then
        -- Deliberately NOT gated on species_addr ~= 0 the way the
        -- caller's own initial wait loop is (and the way this loop's
        -- first draft also was). CONFIRMED via a real user report on a
        -- second fishing encounter: species_addr can itself read 0 for
        -- an instant during this exact window - "waited 0 frame(s)"
        -- logged immediately, meaning the loop's condition was already
        -- false on its very first check, which given have_battle_controls
        -- was confirmed false means memory.readbyte(species_addr) ~= 0
        -- must have been false too, i.e. species_addr read 0 despite a
        -- battle genuinely being in progress (the encounter had already
        -- printed correctly a moment earlier this same tick). This is
        -- the same flicker already documented elsewhere in this file
        -- (species_addr staying nonzero too long after a battle ends) -
        -- here it's the opposite direction, reading 0 too early/briefly
        -- during a real, ongoing battle. Relying on it to decide "give
        -- up early" made the wait bail out instantly instead of actually
        -- waiting. have_battle_controls plus a hard frame cap (below) is
        -- sufficient on its own to bound this loop safely.
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
            -- Deliberately "skipped", not "stuck" - the caller treats
            -- "stuck" as "something needs your manual input, stop the
            -- bot and alert" (a move-learn prompt, a possible faint).
            -- This isn't that - the battle itself is presumably fine,
            -- its menu is just still loading. Skipping this one Thief
            -- attempt and falling straight through to the normal flee
            -- is the same "go back to usual behavior" fallback already
            -- used when Thief PP is depleted, not a real error.
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

    -- Same settle wait as do_catch_attack_turn above - see its own
    -- comment for the full rationale (hook-confirmed when
    -- MoveSelectionAddr is available for this game version/region,
    -- fixed-frame fallback otherwise).
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
    -- instead of assuming it's already highlighted - see MOVE1_CURSOR's
    -- own comment above for why the old blind "just press A" assumption
    -- was the real bug: it could silently confirm whatever move was
    -- already highlighted from an earlier turn, using a real move that
    -- just isn't Thief, with no error and no visible sign anything was
    -- wrong other than the item never actually getting stolen.
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
                -- Same reasoning as do_catch_attack_turn's own
                -- MOVE2_CURSOR handling: a status condition (confusion/
                -- sleep/etc.) can also skip the move-select screen for a
                -- turn, which looks identical to a stuck cursor. Back out
                -- with B rather than risk confirming the wrong move, and
                -- let the caller's flee_battle() run as usual afterward.
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

-- Extracted from what used to be the inline "else" branch of the kill-
-- vs-flee decision in M.step(), so Thief mode (below) can flee via the
-- exact same, already-battle-tested escape logic afterward instead of a
-- second copy that could drift out of sync - Thief mode still flees
-- afterward exactly like it always did before Thief mode existed.
local function flee_battle()
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

    -- Same fix as do_catch_sequence's post-catch reset above
    -- (see that comment for the full root-cause writeup),
    -- applied here for the exact same reason: species_addr is
    -- already documented to flicker non-zero for up to 90+
    -- frames after a battle genuinely ends - including after
    -- a successful flee, not just a catch. Confirmed via a
    -- real user report: a shiny that doesn't match the
    -- auto-catch filter correctly flees here, but without
    -- this reset, the next M.step() tick(s) can sample one of
    -- those stale nonzero reads, re-enter the "in battle"
    -- shiny branch with shinyvalue still 1 (nothing else
    -- clears it) and dv_flag_addr still left at 0x01 from the
    -- battle that just ended, and re-send the exact same
    -- "Shiny found" Discord embed - observed as ~5 duplicate
    -- notifications for one shiny. A real new shiny always
    -- re-sets shinyvalue via shiny() inside the ROM hook, so
    -- clearing it here can never suppress a genuine one.
    shinyvalue = 0
    shinyLatchedThisBattle = false
end

-- ===== Auto-unequip Thief's stolen item =====
-- Gen 2's Thief mechanic (see the "must not already hold an item"
-- comment on the Thief decision block below) hands a successfully
-- stolen item to the THIEF USER itself, not directly to the Bag - so
-- until that item is cleared off, Thief can never steal again (every
-- following encounter gets blocked by the same "already holding an
-- item" condition, confirmed via a real user report of exactly this).
-- This automates the manual fix: Start -> POKEMON -> (lead, party slot
-- 1) -> ITEM -> TAKE.
--
-- Every button-press COUNT below is USER-CONFIRMED against their own
-- real game (counted by physically opening each menu) - NOT guessed:
--   - The Start menu opens with POKEDEX highlighted; POKEMON is
--     confirmed to be exactly 1 Down-press away.
--   - The per-Pokemon action menu (STATS/SWITCH/MOVE/ITEM/CANCEL, for a
--     mon with no field moves) needs exactly 3 Downs from open to reach
--     ITEM - CONFIRMED SPECIFIC TO A THIEF USER THAT KNOWS NO FIELD
--     MOVES (Cut/Fly/Surf/Strength/Whirlpool/Headbutt/Rock Smash/Sweet
--     Scent/Softboiled/Milk Drink). Each of those inserts an extra
--     entry ABOVE ITEM in that menu and would shift this count. If the
--     Thief user ever learns one of those moves, THIEF_ITEM_MENU_DOWN_
--     PRESSES below needs updating to match - otherwise this function
--     risks landing on the wrong option, most dangerously SWITCH (which
--     silently reorders the party and breaks the "lead = Thief user"
--     premise this whole feature depends on).
--   - The Item submenu is always exactly GIVE (top, default-highlighted)
--     then TAKE (one Down below it) whenever a mon already holds an
--     item - taken directly from the pokecrystal disassembly
--     (GiveTakeItemMenuData), not user-counted, but this one has no
--     conditional variability to begin with so it's low-risk regardless.
--   - The party list defaulting to the lead (slot 1) highlighted when
--     freshly opened is standard, ordinary Game Boy menu behavior (no
--     known quirk like the move-select screen's stale-cursor issue) but
--     genuinely UNVERIFIED for this specific build. If it's ever wrong,
--     the worst case is unequipping the wrong party member's item
--     (annoying, not destructive) rather than anything worse.
--
-- UNVERIFIED WARNING: MENU_CURSOR_Y/MENU_CURSOR_X are only confirmed
-- for the BATTLE menu (per this file's version-detection code). Reusing
-- them here for diagnostics rests on the reasonable-but-not-WRAM-
-- diffed assumption that Crystal's engine shares one cursor variable
-- across every menu. Because of that, this function does NOT gate any
-- decision on those reads - it only logs them for future debugging -
-- and paces every step with generous fixed frame waits instead (the
-- same fallback strategy this file already uses elsewhere for game
-- versions without a confirmed ROM hook), so the actual button
-- presses (which are real inputs regardless of what any memory read
-- says) still work correctly even if that address assumption is wrong.
local ITEM_MENU_DOWN_PRESSES = 3

-- Same threshold M.step()'s own overworld_loaded detector already
-- proved necessary (see REQUIRED_SETTLE_FRAMES's declaration/history
-- further down this file, raised from 10 to 90 after real evidence that
-- species_addr can read 0 for 10+ CONSECUTIVE frames purely as part of
-- a battle's own transition, well before the battle has actually
-- ended). A real user report proved the exact same failure mode here:
-- after a Thief steal, Start was pressed too early (species_addr had
-- read 0, but the screen was still fading back to the overworld) - the
-- Start press was silently swallowed mid-fade, and the very next
-- scripted "Down" (meant to move the Start menu's highlight onto
-- POKEMON) was instead read as ordinary overworld movement, walking
-- the character off their tile instead of navigating any menu.
-- Requiring this many CONSECUTIVE zero-reads (not just one single read
-- plus a flat buffer, which is what this used before) is the same fix
-- already proven for the exact same underlying problem elsewhere in
-- this file - duplicated here as its own local constant (rather than
-- referencing REQUIRED_SETTLE_FRAMES directly) since that one is
-- declared later in the file, out of scope for this function.
local THIEF_LEAD_ITEM_SETTLE_FRAMES = 90

-- Shared menu-driving sequence behind both auto_unequip_thief_item()
-- (mid-hunt, right after a successful Thief steal) and the one-time
-- startup lead-held-item check (see check_and_clear_lead_item_on_startup
-- below) - both ultimately need the exact same Start -> POKEMON ->
-- (lead) -> ITEM -> TAKE flow against the exact same party slot (the
-- lead), so the mechanics live here once and each caller only supplies
-- a short label used to prefix this function's own print/vprint lines
-- (so console output still makes it obvious which feature triggered it).
local function take_item_from_lead(contextLabel)
    -- Only run once genuinely back in the overworld - see
    -- THIEF_LEAD_ITEM_SETTLE_FRAMES's comment above for why this
    -- requires that many CONSECUTIVE zero-reads, not just one.
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

    -- DIAGNOSTIC: a real user report showed the bot pressing Down right
    -- after Start with no menu ever visibly opening - i.e. Start looks
    -- like a silent no-op, exactly what happens if "Start" isn't
    -- actually a recognized joypad key name for this core (joypad.set
    -- ignores unknown keys rather than erroring, unlike A/B/Up/Down/
    -- Left/Right which are already proven elsewhere in this file).
    -- Reading straight back with joypad.get() right after setting it
    -- uses the exact same key-naming convention as joypad.set itself
    -- (unlike joypad.getavailablebuttons, which can use a differently-
    -- prefixed naming scheme) - settling this definitively instead of
    -- guessing at a different name blind.
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
    -- Raised from 45 - a real user report showed the very next A press
    -- (meant to select the lead and open its action menu) having no
    -- visible effect at all: the bot went straight from the party list
    -- to pressing Down 3 times inside THAT list (moving between party
    -- slots) instead of opening the action menu first. The party list
    -- draws in party-member icons/HP bars for every mon (slower than a
    -- simple text menu like the Start menu), so 45 frames likely wasn't
    -- long enough for it to finish loading/become interactive yet,
    -- causing that A press to be silently swallowed mid-transition -
    -- same category of issue as species_addr's well-documented
    -- transition flicker elsewhere in this file, just for a different
    -- screen. This is a one-time (or post-battle) action, not
    -- performance-sensitive, so it can afford to wait generously.
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

    -- Clear the "X took the Y back!" message and back out of every menu
    -- we opened (action menu, party list, Start menu) with B, rather
    -- than assuming an exact number of screens - B only ever
    -- cancels/closes here, it never confirms anything, so extra presses
    -- once already back in the overworld are harmless no-ops. Raised
    -- from 4 to 8 - a real user report confirmed the flow otherwise
    -- works, but 4 B presses weren't quite enough to fully back out of
    -- every menu layer every time.
    for i = 1, 8 do
        press_button("B")
        for j = 1, 20 do emu.frameadvance() end
    end

    vprint(string.format("%s: auto-unequip finished - cursor Y=%d X=%d (diagnostic only)",
        contextLabel, memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    print(string.format("%s: cleared the held item off your lead Pokemon. (If your Bag's pocket was full, this may not have actually worked - check in-game if it's still holding it.)", contextLabel))
end

-- Thin wrapper kept so the existing Thief-mode caller site (M.step's
-- Thief decision block) doesn't need to change at all - just labels the
-- shared sequence above for its own console output.
local function auto_unequip_thief_item()
    take_item_from_lead("Thief mode")
end

-- ===== Startup check: clear any pre-existing held item off the lead =====
-- User-requested: some hunts get started with the lead Pokemon already
-- holding an item (left over from manual play, a previous session, etc).
-- Thief mode specifically NEEDS an empty-handed lead to be able to steal
-- at all (see the Gen 2 mechanic comment on the Thief decision block
-- below), so this runs once, right when the bot first settles into the
-- overworld after Start is pressed (see startupItemCheckPending's
-- declaration/reset near overworld_loaded and M.on_resume), and clears
-- whatever the lead is holding via the exact same menu flow as
-- auto_unequip_thief_item() above. Deliberately unconditional (not
-- gated on Thief mode being enabled) since the user asked for this as a
-- general startup step, not a Thief-only one.
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
            local ballsUsed = throws + 1 -- throws only counts FAILED attempts; this successful one isn't in it yet
            send_catch_notification(string.format("%s%s caught successfully via auto-catch! (used %d Ball%s)",
                label, caughtSpeciesName, ballsUsed, ballsUsed == 1 and "" or "s"), COLOR_GREEN, caughtSpeciesId, isShiny, caughtItemName)
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
                -- CORRECTION (real user report, shiny Delibird - a
                -- species with a notably high wild flee rate): before
                -- concluding this needs manual intervention, check
                -- whether the battle has actually already ENDED -
                -- species_addr reading 0 means there's no wild Pokemon
                -- left to have a battle menu for at all, which this
                -- recovery loop could never succeed at by definition. The
                -- most likely real cause: the wild Pokemon used its own
                -- turn (after the failed throw) to flee instead of
                -- attacking, which genuinely ends the battle outright -
                -- exactly like any other mid-battle flee elsewhere in
                -- this project. That's a normal, harmless outcome, not an
                -- error - the message calling it a bare "battle menu
                -- timeout" was misleading (a real user report pointed
                -- this out directly), and stopping the whole bot over it
                -- was unnecessary, same principle behind every other
                -- "don't stop for a harmless outcome" fix in this
                -- codebase (Thief's PP-stuck/fainted handling, etc).
                if memory.readbyte(species_addr) == 0 then
                    -- Still need to rule out the OTHER thing that ends a
                    -- battle outright: our own Pokemon fainting (recoil,
                    -- confusion self-hit, a status condition, etc, on the
                    -- wild Pokemon's turn). Same OWN_HP_ADDR check
                    -- do_kill_turn/do_thief_turn already use for exactly
                    -- this - that genuinely does need a replacement sent
                    -- out manually, so it still stops.
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
                -- same battle, so this ISN'T a flee/faint ending things
                -- early. The menu genuinely never came back for some
                -- other reason (an unresolved dialog/prompt this recovery
                -- loop's A-mashing couldn't clear) - that IS a real stuck
                -- state worth stopping for.
                print("Catch-mode: battle menu didn't reload after the failed throw within the extended timeout - stopping so you can take over.")
                send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu didn't return after a failed throw - possibly stuck on an unexpected prompt).", label, caughtSpeciesName),
                    COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
                return true
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
-- Set true in M.on_resume() (once per Start press) and consumed exactly
-- once - the first time overworld_loaded is true afterward - by
-- check_and_clear_lead_item_on_startup() below. Deliberately NOT tied to
-- overworld_loaded's own per-battle true/false toggling (that flips
-- after every single encounter, not just at hunt start), so this really
-- only runs once per Start press, not once per battle.
local startupItemCheckPending = false
-- Was 10. A real verbose log (the shiny Raticate investigated alongside
-- shinyLatchedThisBattle above) directly proved species_addr can read 0
-- for 10+ CONSECUTIVE frames purely as part of a battle's own intro
-- transition - i.e. genuinely reaching this exact old threshold - which
-- fired "Overworld loaded" (and, when a shiny was pending, the fallback-
-- notification/battle-state-cleanup block below) while the same battle
-- was still very much in progress; that same log showed it happen 4
-- separate times in a row for one encounter before the real battle menu
-- ever loaded. Elsewhere in this file, species_addr is independently
-- documented (do_catch_sequence's own settling-wait comments) to flicker
-- for "up to 90+ frames" around a real battle boundary - raised to match
-- that same, already-evidenced worst case instead of the old, now-proven-
-- too-short 10.
local REQUIRED_SETTLE_FRAMES = 90 -- consecutive frames of species_addr==0 before we trust we're truly back

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
        if shinyNotificationPending then
            shinyNotificationBattleMenuSeen = true
        end
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
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable
        -- Latched here, synchronously, in the same trusted atomic context
        -- as Stats.record_shiny below - see shinyLatchedThisBattle's own
        -- declaration near the top of the file for why the real catch/
        -- flee decision trusts this instead of the raw shinyvalue.
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
        ConsoleLog.log_encounter("wild", encounterLine)

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
                {name = "\xE2\x80\x8B", value = "\xE2\x80\x8B", inline = false},
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            }
            pendingShinySpriteUrl = shiny_sprite_url(species)
            -- Armed here, synchronously with everything else above -
            -- see this flag's declaration near the top of the file for
            -- the full reasoning (the fallback notification this enables
            -- further down in M.step()).
            shinyNotificationPending = true
            -- Reset alongside it - see this flag's own declaration for
            -- why. Tells the fallback below whether the player-visible
            -- FIGHT/PKMN/ITEM/RUN menu (LoadBattleMenuAddr, a real
            -- confirmed ROM hook, not a guess) ever actually appeared for
            -- THIS encounter before it resolved.
            shinyNotificationBattleMenuSeen = false
        end

        -- IMPORTANT: this hook fires as a ROM-hook callback, and we've
        -- confirmed BizHawk restricts what's allowed inside callbacks
        -- (emu.frameadvance throws outright; forms.drawText/drawRectangle
        -- calls made from here appear to silently not flush to screen).
        -- So GUI updates, stop-condition checks, and Discord notification
        -- still wait for M.step() - running in the main loop, a
        -- confirmed-safe context - same as before.
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
            -- after a real bug report (static encounters never detected)
            -- traced to EnemyWildmonInitialized firing at the wrong
            -- address on this build. Found via byte-signature scanning
            -- (diagnose_rom_addresses.lua) against a real Italian ROM:
            -- LoadBattleMenuAddr/MoveSelectionAddr are byte-identical to
            -- English (same address); EnemyWildmonInitialized/
            -- CatchSuccessAddr/CatchFailAddr are shifted a couple bytes;
            -- LearnMoveAddr is shifted by 1 byte earlier. enemy_addr
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
    shinyLatchedThisBattle = false
    learnMovePromptDetected = false
    startupItemCheckPending = true
    killModeWasEnabled = false
    killModeAutosaveNextTime = nil
end

function M.step()
    check_stuck_and_notify()

    -- Kill mode safety savestates - see KILL_MODE_SAFETY_SLOT's own
    -- declaration/comment above for the full rationale. Checked every
    -- tick (cheap - just a forms.ischecked() read) so both a mid-run
    -- checkbox toggle AND a fresh Start click with it already checked
    -- are caught the same way, via the OFF->ON edge this produces.
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
            -- (Re)arm the periodic autosave timer fresh each time Kill
            -- mode (re)starts, rather than letting it carry over a stale
            -- deadline from a previous run.
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
        -- Reads the latch, not the raw shinyvalue - see
        -- shinyLatchedThisBattle's declaration for why: this runs one
        -- tick after the hook, which is exactly the same window a real
        -- shiny was confirmed lost in (shinyvalue read back 0 by the time
        -- code just a tick or two later checked it). Keeps the GUI/
        -- Recent Encounters display consistent with the actual catch/flee
        -- decision below, which already uses this same latch.
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

                -- Fallback safety net - see shinyNotificationPending's
                -- declaration near the top of the file for the full
                -- writeup. If this is still armed right as we confirm
                -- we're back in the overworld, the in-battle shiny-
                -- decision block provably never ran for that encounter,
                -- without the bot ever attempting to catch/stop/notify
                -- for a shiny it had already correctly detected and
                -- recorded in Stats. Fire the notification here instead
                -- of leaving it silently dropped, and flag it loudly in
                -- the console so a recurrence is easy to spot/correlate.
                --
                -- IMPORTANT: earlier wording here asserted "it likely got
                -- away," implying the wild Pokemon fled on its own before
                -- any input was possible - a user correctly pointed out
                -- that doesn't match how Gen 2 wild battles work (the
                -- player always gets to act first; a Pokemon doesn't just
                -- vanish pre-emptively). That was an unverified guess,
                -- not a confirmed mechanism, so it's been replaced with
                -- shinyNotificationBattleMenuSeen - a real signal off the
                -- LoadBattleMenuAddr ROM hook - so this message reports
                -- actual evidence about what happened instead of asserting
                -- an unconfirmed cause.
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
        -- Runs at most once per Start press - see startupItemCheckPending's
        -- declaration above and the reset in M.on_resume(). Deliberately
        -- placed before do_nudge_cycle()/searching begins so the lead is
        -- guaranteed empty-handed (and Thief able to steal) from the very
        -- first encounter of the hunt onward.
        --
        -- Gated on Thief mode actually being enabled - this whole feature
        -- only exists because Thief needs an empty-handed lead to steal
        -- at all (see the Gen 2 mechanic comment on the Thief decision
        -- block below); a user NOT using Thief this session may well be
        -- intentionally holding an item on their lead for an unrelated
        -- reason, so this must never touch it uninvited.
        if startupItemCheckPending then
            startupItemCheckPending = false
            if Gui.thief_mode_enabled(hud) then
                check_and_clear_lead_item_on_startup()
            else
                vprint("Startup check: Thief mode isn't enabled - leaving your lead's held item alone.")
            end
        end

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

        -- Temporary diagnostic (verbose-only). A real user log showed a
        -- confirmed shiny (Stats recorded it, the hook's own DV print was
        -- correct) fall all the way through to the plain kill/flee code
        -- below with NONE of the shinyvalue==1 branch's own prints ever
        -- firing - meaning shinyvalue must not have read as 1 at the
        -- moment this decision actually ran, despite no known code path
        -- resetting it between the hook and here. The same log also
        -- proved (for the first time, directly, not inferred) that
        -- species_addr can flicker to 0 for 10+ consecutive frames
        -- SEVERAL TIMES in a row during one battle's own intro transition
        -- - each flip re-enters this whole per-tick block from scratch.
        -- This line exists to catch the exact state at the moment of
        -- that fall-through, the next time it happens, instead of
        -- guessing further.
        vprint(string.format(
            "Decision check: shinyvalue=%s shinyLatchedThisBattle=%s currentSpecies=%d(%s) atkdef=%s spespc=%s catchAllowedByItem=%s catchAllowedByPerfect=%s auto_catch_enabled=%s",
            tostring(shinyvalue), tostring(shinyLatchedThisBattle), currentSpecies, currentSpeciesName, tostring(atkdef), tostring(spespc),
            tostring(catchAllowedByItem), tostring(catchAllowedByPerfect), tostring(Gui.auto_catch_enabled(hud))))

        -- Reads the latch, NOT the raw shinyvalue - see
        -- shinyLatchedThisBattle's declaration near the top of the file
        -- for why (a real shiny was confirmed lost to shinyvalue reading
        -- back 0 here despite no known code path resetting it).
        if shinyLatchedThisBattle then
            -- Disarm the fallback notification below - we made it here,
            -- so one of this block's own branches is about to send (or
            -- has already decided not to need) the real notification.
            shinyNotificationPending = false
            local shinySpecies = currentSpecies
            local shinySpeciesName = currentSpeciesName

            -- DEBUG MODE: when true, every filter/exception/living-dex
            -- check below is bypassed entirely - ANY detected shiny gets
            -- an immediate catch attempt as long as the master Auto-Catch
            -- toggle is on, full stop. This existed purely to isolate an
            -- earlier "shiny detected, Stats recorded, but never caught"
            -- bug from the species-filter/exception/living-dex logic -
            -- that investigation finished and this got left flipped to
            -- true, which is itself a real bug a user actually hit: with
            -- this on, "Only auto-catch a species the FIRST time (living
            -- dex mode)" being checked in the GUI does nothing at all -
            -- every shiny gets re-caught every time regardless, exactly
            -- as if that checkbox (and the auto-catch exception list)
            -- were silently ignored. Now permanently false - flip back to
            -- true only for a deliberate one-off debugging session, never
            -- leave it set afterward.
            local DEBUG_CATCH_ANY_SHINY = false

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
                if not DEBUG_CATCH_ANY_SHINY and exceptionEnabled and species_matches_filter(exceptionFilterTokens, shinySpecies, shinySpeciesName) then
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

                if not DEBUG_CATCH_ANY_SHINY and Gui.skip_already_caught_enabled(hud) and Stats.is_already_caught(shinySpecies) then
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
                local catchAllowedBySpecies = DEBUG_CATCH_ANY_SHINY or species_matches_filter(catchFilterTokens, shinySpecies, shinySpeciesName)

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
                        shinyLatchedThisBattle = false
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
                -- Same root cause/fix as the shinyvalue reset above and
                -- in do_catch_sequence's own post-catch comment:
                -- species_addr is documented to flicker non-zero for up
                -- to 90+ frames after a battle genuinely ends, which can
                -- re-enter this whole "in battle" dispatch before the
                -- NEXT real encounter's own EnemyWildmonInitialized hook
                -- has fired to overwrite atkdef/spespc with the new
                -- Pokemon's actual values. isPerfectDVs/isPerfectNegativeDVs
                -- are recomputed fresh from atkdef/spespc on every single
                -- tick (unlike shinyvalue, which is a cached flag) - so
                -- during that window, a stale leftover atkdef/spespc
                -- still reading the JUST-CAUGHT Perfect-DV mon's values
                -- makes catchAllowedByPerfect true again for whatever
                -- happens to be on screen next, including a genuinely
                -- different, non-perfect wild Pokemon that encounter
                -- hasn't even been fully registered yet - confirmed via a
                -- real user report of the very next Pokemon encountered
                -- after a Perfect-DV catch also getting auto-caught.
                -- Clearing atkdef/spespc to nil here closes that window
                -- exactly the way it's already handled a few lines up
                -- (the `if atkdef and spespc then` guard around the
                -- isPerfectDVs/isPerfectNegativeDVs computation) - a real
                -- new encounter always repopulates both via its own hook,
                -- so this can never suppress a genuine Perfect DV catch.
                atkdef = nil
                spespc = nil
            end
            return stillHunting
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
                -- Thief mode (wild.lua only - see chkThiefMode in
                -- gui_module.lua): steal the wild Pokemon's held item
                -- with whatever's in move slot 1, once per battle, then
                -- flee exactly like normal. thiefUsedThisBattle (reset
                -- per-battle in the EnemyWildmonInitialized hook) stops
                -- this from re-triggering on every subsequent tick of
                -- the same battle - it's a one-shot per encounter, not a
                -- replacement for kill mode's repeated-attack loop above.
                -- FIRST_MOVE_PP_ADDR specifically (not the OR-both-moves
                -- `hasPP` used for kill mode just above) - if the move in
                -- slot 1 (assumed to be Thief) has 0 PP, this is skipped
                -- entirely and falls straight through to flee_battle()
                -- below, i.e. exactly the same as if Thief mode had never
                -- been turned on at all, per direct request.
                local thiefHasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0
                -- Thief-specific HP check (THIEF_LOW_HP_THRESHOLD, NOT
                -- the shared hpSafe/LOW_HP_FLEE_THRESHOLD used by Kill
                -- mode just above) - see that constant's own comment for
                -- why Thief gets a separate, lower floor. No debounce
                -- needed the way thiefHasPP gets below - HP isn't
                -- documented to flicker the way PP was.
                local thiefHpSafe = thief_has_safe_hp()
                -- Set true only when a steal genuinely lands this turn -
                -- read after flee_battle() below to decide whether to
                -- run auto_unequip_thief_item() (see its own comment).
                local thiefStoleItemThisTurn = false

                -- REMOVED (real user report, with hard proof): this used
                -- to be a proactive "out of PP" notice fired once per
                -- battle from a single speculative FIRST_MOVE_PP_ADDR
                -- read, taken right when the battle menu loads - before
                -- Thief has even decided to act this turn. A real report
                -- showed it firing "Thief mode: move slot 1 is out of PP"
                -- at 11:27, sandwiched directly between two genuinely
                -- successful Thief steals (11:25 and 11:28) with nothing
                -- done in between (no restart, no PP restored) - proving
                -- this specific read can be flatly wrong even after the
                -- 60-frame debounce it already had, not just wrong for a
                -- single flicker frame. Three separate attempts to fix
                -- this (rounds 5, 9, 10 - tighter debounce, re-arm on
                -- refill, debounced re-arm) all failed to make this
                -- specific speculative read trustworthy enough to inform
                -- the user with.
                --
                -- Rather than keep guessing at a fourth debounce, this
                -- notice is removed entirely. It was never load-bearing
                -- for Thief's actual behavior - thiefHasPP (declared
                -- above) still gates whether Thief attempts to act this
                -- battle at all
                -- (an occasional misread here just means Thief quietly
                -- skips one battle's steal and tries again normally next
                -- battle, exactly as if Thief mode were off for that one
                -- encounter - no different from before, and self-
                -- corrects immediately). The genuinely reliable PP-
                -- depletion detection - and the notification the user
                -- actually wants - already lives in do_thief_turn()
                -- itself: the pre-attack re-check right before pressing A
                -- on move slot 1, and the post-attack ROM-hook-driven
                -- catch (moveSelectScreenOpen bouncing back to the
                -- move-select screen) - both of which only ever check PP
                -- at the exact moment it's actually about to be spent,
                -- not speculatively at battle start, and neither has ever
                -- been shown to false-positive the way this one just was.

                -- Low-HP notice - user-requested (same once-per-battle
                -- check latch via thiefLowHpCheckedThisBattle, same
                -- one-time-ever notify latch via thiefLowHpNotified as
                -- the old PP notice used to have, before that one was
                -- removed above for being unreliable) so the user gets
                -- told,
                -- once, that Thief is being skipped for low HP instead of
                -- it just silently falling through to a normal flee every
                -- time this comes up for the rest of the session.
                if Gui.thief_mode_enabled(hud) and have_battle_controls and not thiefLowHpCheckedThisBattle then
                    thiefLowHpCheckedThisBattle = true
                    if not thiefHpSafe and not thiefLowHpNotified then
                        thiefLowHpNotified = true
                        print("Thief mode: HP is below 20% - pausing Thief steals until it recovers (healing/switching/etc). Continuing to hunt normally in the meantime.")
                        send_alert("Thief mode: HP below 20% - pausing steals until it recovers. Still hunting normally in the meantime.", COLOR_BLUE)
                    end
                end

                -- currentItem ~= 0 is checked separately from (and
                -- before) the filter match - species_matches_filter
                -- returns true unconditionally for a blank filter
                -- ("steal any item"), which without this would waste a
                -- Thief PP swinging at a Pokemon holding nothing at all
                -- to steal. A specific filter already can't match item
                -- ID 0 either way, but this makes the "nothing to steal"
                -- case explicit and correct for both filter modes.
                if Gui.thief_mode_enabled(hud) and not thiefUsedThisBattle and thiefHasPP and thiefHpSafe
                    and currentItem ~= 0
                    and species_matches_filter(Gui.thief_item_filter(hud), currentItem, currentItemName) then
                    thiefUsedThisBattle = true
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Using Thief...")

                    -- Keep using Thief across MULTIPLE turns of this same
                    -- battle (no flee_battle() in between) until the
                    -- steal actually lands or it's no longer safe/
                    -- possible to keep trying - user-requested, since a
                    -- wild Pokemon using Protect/Detect (or a plain miss)
                    -- previously caused an immediate flee with the item
                    -- never actually stolen, even though Thief still had
                    -- PP left to just try again. Protect's own success
                    -- chance drops sharply with each consecutive use in
                    -- Gen 2, so it reliably fails within a few turns -
                    -- and Thief's own PP (10 by default, before any PP
                    -- Ups) naturally caps how many attempts are even
                    -- possible via the PP check below, so
                    -- THIEF_MAX_RETRY_ATTEMPTS is just a defensive
                    -- backstop, not the real limiter.
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
                            -- The battle menu wasn't interactive in time this
                            -- attempt (see do_thief_turn's own comment) -
                            -- no attack actually happened, so there's
                            -- nothing to check the item for, and nothing
                            -- gained by immediately retrying. Fall
                            -- straight through to the normal flee below,
                            -- same as if Thief mode were off this
                            -- encounter.
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
                                -- User-requested: notifying Discord on
                                -- every single steal turned into spam for
                                -- fast grinding sessions - now gated on
                                -- the "Notify on Discord for every item
                                -- stolen" checkbox (Advanced Settings,
                                -- defaults to on). The console print
                                -- above and thiefStoleItemThisTurn below
                                -- both stay unconditional either way -
                                -- this only ever suppresses the Discord
                                -- message itself.
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
                            -- item_addr tracks the enemy's held item live, so
                            -- re-reading it now (after the attack resolved)
                            -- tells us directly whether the steal actually
                            -- landed, rather than guessing from animation/text.
                            local thiefSpecies = memory.readbyte(species_addr)
                            local thiefSpeciesName = get_pokemon_name(thiefSpecies)
                            local itemAfterThief = memory.readbyte(item_addr)
                            if currentItem ~= 0 and itemAfterThief == 0 then
                                print(string.format("Thief: stole %s from %s!%s", currentItemName, thiefSpeciesName,
                                    thiefAttempts > 1 and string.format(" (took %d attempts - something was blocking earlier steals, e.g. Protect)", thiefAttempts) or ""))
                                -- Gated the same way as the fainted-on-
                                -- attack steal case above - see that
                                -- comment for the full rationale.
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
                                -- Decide whether it's still worth using
                                -- Thief again THIS SAME battle, rather
                                -- than looping unconditionally:
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
                    -- Gen 2 Thief hands the item to the Thief user
                    -- itself, not the Bag - see
                    -- auto_unequip_thief_item's own comment. Runs after
                    -- flee_battle() has already fully returned (species
                    -- confirmed 0, well past the post-battle flicker
                    -- window per flee_battle's own 180-frame exit wait),
                    -- so this always starts from a genuinely settled
                    -- overworld state.
                    auto_unequip_thief_item()
                end
            end
        end
    end

    ::continue::
    return false
end

return M

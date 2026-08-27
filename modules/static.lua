-- static.lua
-- Static encounters (Sudowoodo, legendary beasts/birds, gift Pokemon
-- battles, etc.) via soft-reset - works for BOTH respawnable statics
-- (which could also be fled-and-retried) and one-time-only statics
-- (which can't), since reloading a savestate from BEFORE the
-- interaction happened is universal regardless of which category a
-- given static falls into. No need to special-case either kind.
--
-- Mechanically this is a hybrid: the encounter itself is read the same
-- way wild.lua reads any wild battle (hook-based, since the Pokemon is
-- the ENEMY, not a party addition like Starters/Egg) - but the overall
-- flow (savestate, 8-way split RNG, mash-and-check, reload-if-not-shiny)
-- matches Starters/Egg's soft-reset loop, not Wild's continuous walking.
--
-- No kill mode, no species stop, no True Randomness disabling: killing
-- a static is never desirable (many are one-time-only, and even
-- respawnable ones aren't worth killing over catching), and the species
-- is already fixed/known for whichever static you're resetting, so a
-- species filter doesn't apply the way it does for Wild.
--
-- Same anti-determinism fix as Starters/Egg: soft-resetting with
-- perfectly identical input timing produces IDENTICAL "random" results
-- every attempt unless timing variance is deliberately introduced after
-- each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")
Stats = require("data.stats")
RngEnabler = require("data.rng_enabler")
SavestateBackup = require("data.savestate_backup")

-- Full 388-entry (map group, map number) -> name table, shared with
-- wild.lua/fishing.lua/headbutt.lua/friendship.lua - see
-- data/location_names.lua for where this comes from (the actual
-- pret/pokecrystal disassembly, not a guess). Different static
-- encounters live at different locations, so this feeds the Rich
-- Presence location the same as those modules.
local LocationNames = require("data.location_names")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function get_item_name(id)
    if id == 0 then return "(no item)" end
    return ItemNames[id] or ("Unknown item #" .. tostring(id))
end

-- Checks a list of raw typed tokens (each could be a number like "69" or
-- a name like "Bellsprout") against the current species/item, matching on
-- either its numeric ID or its name (case-insensitive). nil tokens list
-- means no filter was set, so everything is allowed. Ported verbatim
-- from wild.lua/fishing.lua - needed now that Auto-Catch's species/item
-- filters actually apply to Static (open world) encounters too.
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

-- Checks the global flag set by launcher.lua's Stop button - see
-- wild.lua for the original explanation. Needed here now for the same
-- reason: the new auto-catch sequence runs long, blocking loops (up to
-- 20 ball throws) inside a single M.step() call, so this lets it notice
-- a Stop press without waiting for the whole sequence to finish first.
local function stop_was_requested()
    return AutocrystalGlobalStopRequested == true
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

-- Same idea as shiny_sprite_url, but the regular (non-shiny) sprite -
-- used for auto-catch notifications about a held-item/Perfect-DV match
-- that isn't shiny (do_catch_sequence(false) can fire for those).
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
local COLOR_GREEN = 3066993

-- Even leaner colored embed for bot-status alerts (stuck detection) that
-- aren't about a specific encounter.
local function send_alert(title, color)
    send_discord_embed(title, nil, nil, color, nil)
end

-- Lean colored embed for the auto-catch dialogue - just a title, color,
-- Dex #, held item, and the species' sprite, without the full stat
-- breakdown the shiny-found embed uses (these fire multiple times per
-- catch attempt, so a lighter footprint keeps the channel readable).
-- Ported from wild.lua/fishing.lua's send_catch_notification.
local function send_catch_notification(title, color, speciesId, isShiny, itemName)
    local spriteUrl = isShiny and shiny_sprite_url(speciesId) or regular_sprite_url(speciesId)
    local fields = {{name = "Dex #", value = string.format("#%03d", speciesId), inline = true}}
    if itemName then
        table.insert(fields, {name = "Held Item", value = itemName, inline = true})
    end
    send_discord_embed(title, nil, fields, color, spriteUrl)
end

-- Value fixed once per run inside M.init() below, via the launcher's
-- Savestate slot dropdown (falls back to 5, this module's historical
-- default, separate from Starters' slot 3 and Egg's slot 4, if the
-- dropdown can't be read) - no longer a hardcoded constant, see
-- launcher.lua's AutocrystalGetSavestateSlot().
local SAVESTATE_SLOT

-- Tracks whether SAVESTATE_SLOT has EVER actually been saved to yet this
-- BizHawk session - see the "cold slot" warm-up in M.on_resume() below.
local savestateSlotWarmedUp = false

local enemy_addr, species_addr, item_addr
local party_base_addr
local partysizeBeforeReceiving
local LoadBattleMenuAddr, EnemyWildmonInitialized
local version, region

-- ===== Auto-catch support (Static "open world" encounters only) =====
-- Ported from wild.lua/fishing.lua - see those files for the original,
-- more heavily-commented versions of everything in this section.
local CatchSuccessAddr, CatchFailAddr, MoveSelectionAddr
local have_battle_controls = false
-- Set true by the MoveSelectionScreen ROM hook the instant the real
-- move-select submenu opens - a positive, address-based confirmation
-- instead of inferring it from cursor position/timing.
local moveSelectScreenOpen = false
local catchOutcomeSucceeded = false
local catchOutcomeFailed = false
local curPartyMonAddr
local MENU_CURSOR_Y, MENU_CURSOR_X
local FIRST_MOVE_PP_ADDR
local enemy_hp_addr, enemy_max_hp_addr
local wCurItemAddr, wItemsAddr, wNumItemsAddr
local wBallsAddr, wNumBallsAddr
-- Preference order when scanning the bag for something to throw - Poke
-- Ball specifically preferred, falling back to other ball types only if
-- no Poke Balls are left.
local BALL_ITEM_IDS = {5, 4, 2, 1} -- Poke, Great, Ultra, Master
-- Navigate to FIGHT and use whichever move is already highlighted by
-- default (the first move in the list).
local FIGHT_CURSOR = {y = 1, x = 1}
local PACK_CURSOR = {y = 2, x = 1}
-- Second move slot in the FIGHT submenu's 2x2 grid - used as a fallback
-- when the first move is out of PP.
local MOVE2_CURSOR = {y = 2, x = 1}
-- Tracks consecutive failures to confirm the cursor reached MOVE2_CURSOR
-- - see wild.lua's do_catch_attack_turn for the full explanation of why
-- a single failure isn't treated as fatal.
local move2NavFailStreak = 0
local CATCH_HP_TARGET_PERCENT = 0.40

local atkdef, spespc, species, item = 0, 0, 0, 0
local shinyvalue = 0
local resetCount = 0
local pendingEncounterUpdate = false

-- Every split point happens during the mash-A phase, since (unlike
-- Egg) the hook reads DVs immediately the instant the battle starts -
-- there's no later "received but not yet read" window to split at
-- afterward, so every split needs to land before that hook ever fires.
--
-- USED TO cap out at a fixed 8 splits, then go 100% deterministic for
-- however many mash ticks remained. That's fine for Eevee's one-line
-- handoff (resolves in just a couple ticks anyway), but Shuckle's long
-- multi-page Cianwood dialogue takes way more than 8 ticks to get
-- through - so after tick 8, EVERY run took the exact same deterministic
-- sequence of A-presses the rest of the way, meaning the only entropy
-- feeding the actual DV roll was whatever the first 8 splits produced,
-- then pushed through an identical deterministic transform every single
-- time. Measured over 452 real Shuckle resets, the reachable DV space
-- worked out to only ~1,370 of the full 65,536 combos (~2%) - a fixed-
-- length deterministic tail after entropy injection stops is a very
-- plausible explanation for that collapse. Now splits fire on every
-- mash tick for as long as mashing continues (no fixed cap), so entropy
-- keeps getting injected all the way up to whatever tick the DV roll
-- actually happens on - scaling naturally with how long a given
-- target's dialogue takes instead of assuming a fixed tick count.
-- Trade-off: more injected delay per reset (slower resets/hour,
-- especially for Shuckle's longer dialogue) in exchange for actually
-- reaching a larger slice of the DV space.
local mashSplitsFired = 0
-- REMOVED: True Randomness (a single FULL_COVERAGE_RANGE call per reset,
-- ~35000 frames average) used to be an option here, gated to fire once per
-- reset so it didn't multiply that huge wait by every dialogue tick. It's
-- now superseded by reroll_savestate_pool() below: that does the exact
-- same FULL_COVERAGE_RANGE injection, but only once per
-- REROLL_INTERVAL_SECONDS (30 min) instead of once per reset - the same
-- "reach the whole reachable-state space" job, at a small fraction of the
-- time cost. Per the Monte Carlo comparison in rng_mechanics.md, paying
-- that huge cost on every single reset (what True Randomness did) is
-- strictly worse than paying it once per 30-minute window and staying
-- fast in between, so static.lua no longer reads
-- Gui.true_randomness_enabled() at all - see DISABLED_FIELDS below, which
-- greys the checkbox out while Static is the active module so it's clear
-- it has no effect here. Starters/Egg don't have their own reroll yet, so
-- they still read and honor the shared checkbox normally.
local lastResetTime = nil
local consecutiveStuckReloads = 0

-- Which static target this run is for - controls ONLY how long each A
-- press is held (see press_button() above). "Eevee" and "Static (open
-- world)" both use the original 4-frame hold, untouched. "Shuckle" uses
-- a longer hold, added specifically because Shuckle's Cianwood NPC has
-- a much longer multi-page backstory than Eevee's one-line handoff.
-- Doubling PRESS FREQUENCY instead (tried first) made things worse, not
-- better, so frequency stays exactly as it always was - only hold
-- duration changes, and only for the option that asks for it.
--
-- Reads the GLOBAL StaticTargetDropdown built in launcher.lua (not a
-- widget of our own) - see launcher.lua for why: it needs to exist and
-- be pickable BEFORE the first Start click, since M.init() here only
-- runs as part of that click, too late for the very first run.
local SHUCKLE_HOLD_FRAMES = 12
-- Spearow - added on the same reasoning as Shuckle above: user-reported
-- symptom was "produces no output" with the default 4-frame hold, and
-- manually starting mid-conversation (skipping past where the short hold
-- was getting stuck) worked - exactly the same signature that led to
-- SHUCKLE_HOLD_FRAMES existing in the first place. User reports Spearow's
-- dialogue is longer than Shuckle's, so this starts one notch above
-- SHUCKLE_HOLD_FRAMES rather than reusing it - an untuned first guess
-- (Shuckle's 12 was itself arrived at via user testing, not derived from
-- anything) - report back if resets still stall or still produce nothing
-- and this needs adjusting further.
local SPEAROW_HOLD_FRAMES = 16
-- Celebi (GS Ball / Ilex Forest shrine event) - structurally a MIX of
-- the two static flows rather than purely one or the other: it starts
-- with a Shuckle/Spearow-style mash-through-dialogue phase (the shrine's
-- cutscene text), but - unlike Eevee/Shuckle/Spearow, which hand the
-- Pokemon over directly via party-size increase and never battle at all -
-- Celebi's encounter resolves as a genuine wild-style battle once that
-- intro finishes, the same EnemyWildmonInitialized-hook-driven path
-- "Static (open world)" already uses below (pendingEncounterUpdate),
-- auto-catch included. No new code path is needed for that half - only
-- the pre-battle mash timing needs its own entry here, same reasoning as
-- Shuckle/Spearow above. Untuned first guess (same starting point as
-- Shuckle, since the shrine cutscene is likely comparable in length to
-- Shuckle's backstory dialogue rather than Spearow's) - adjust if resets
-- stall or produce nothing.
local CELEBI_HOLD_FRAMES = 12

-- Snorlax (Route 11, blocking the road - the sleeping Snorlax that needs
-- the Poke Flute played on it first before it can be battled at all).
-- Added after a real user report: "Static (open world)" was being used
-- for it (no dedicated entry existed), which only ever credits ONE real
-- button-advance point - the exact same wrong assumption "Static (open
-- world)" made about Sudowoodo before that got its own branch below. User
-- confirmed report matches that signature exactly: "just wants to talk to
-- it even with mashing" (splits exhausted against a textbox that wasn't
-- going anywhere, then the isDribbleTarget no-op branch let a still-
-- pending script sit forever) and "needs a lot of A mashes" (i.e. it DOES
-- eventually resolve with enough real presses - this is a step-count
-- problem, not a story-flag/Poke-Flute gate, so the Flute has already
-- been used). Untuned first guess for both the hold length and the step
-- count below - no disassembly on hand to verify Snorlax's exact script
-- shape the way Sudowoodo's SquirtbottleScript was confirmed, so this
-- starts from Shuckle/Celebi's hold baseline and Sudowoodo's step count
-- as the closest known comparable (another battle-style target reached
-- via more than one real text box) - report back if it still stalls or
-- still produces nothing and both need adjusting further.
local SNORLAX_HOLD_FRAMES = 12
-- Both Snorlax and Sudowoodo went through a round of guessing a fixed
-- numSteps (how many real A-presses to spend before going quiet) that
-- kept turning out wrong in practice - Snorlax needed way more than the
-- first guess of 3, and even after bumping it to 10 and separately
-- giving Sudowoodo (below) its own hold length, a real user report
-- showed Sudowoodo STILL stalling on the very first textbox with a fixed
-- count of 5. Rather than guess yet another number, both targets now
-- just mash every single dribble_entropy_until_hook() iteration (see
-- DIALOGUE_MASH_CAP below) instead of stopping after some fixed count -
-- dribble_entropy_until_hook already checks pendingEncounterUpdate
-- before AND after each step and bails out the instant the real
-- battle-start hook fires, so there was never any actual need to cap the
-- press count below the iteration cap itself; doing so only ever
-- recreated this exact "not enough presses" stall whenever a target's
-- real script needed more advances than whatever number was guessed.
-- Mashing every iteration means the bot naturally keeps pressing through
-- however many textboxes/prompts the target's real script has, and
-- naturally stops the moment the encounter actually starts - no more
-- guessing, no more per-target step-count tuning.
local DIALOGUE_MASH_CAP = 40

-- Sudowoodo hold length - added after a real user report of a stall on
-- the VERY FIRST textbox ("The weird tree doesn't like the...", i.e. the
-- "Use SQUIRTBOTTLE?" yesorno prompt) despite numSteps=3 already being
-- disassembly-correct for the step COUNT at the time. Sudowoodo was,
-- until now, the only multi-step dialogue-driven target in this file
-- with no dedicated current_hold_frames() entry - it fell through to the
-- bare 4-frame default, which is the exact same "produces no output"
-- signature that originally justified SHUCKLE_HOLD_FRAMES/
-- SPEAROW_HOLD_FRAMES existing at all (a too-short hold not reliably
-- registering as a real button press). Starts at the same 12-frame
-- baseline as Shuckle/Celebi/Snorlax rather than a fresh guess - report
-- back if it still stalls and this needs its own separate value. (The
-- separate numSteps guessing problem is now handled by DIALOGUE_MASH_CAP
-- above instead of a per-target step count.)
local SUDOWOODO_HOLD_FRAMES = 12

-- Lapras (Union Cave B2F, Friday-only Surf encounter): confirmed against
-- the actual pokecrystal disassembly (maps/UnionCaveB2F.asm) that its
-- script is faceplayer -> cry -> loadwildmon -> startbattle, with NO
-- dialogue at all - the battle starts from a single trigger press, never
-- reaching a second mash tick. That's a real problem for the split-
-- injection design below (see the "not firstPressPending" mash-A section
-- near M.step()), which only ever fires starting on the SECOND press of
-- an attempt - Lapras never gets one, so every reset was silently using
-- ZERO injected entropy and replaying 100% deterministically off the
-- current savestate. Confirmed via a real 39,402-encounter log: 55% of
-- every reset sat inside just 5 blocks, each repeating one exact DV roll
-- thousands of times in a row back to back, only ever changing at
-- (roughly) a 30-minute reroll boundary.
--
-- BATTLE_TARGET_EXPECTED_SPECIES is what makes it safe to give Lapras a
-- pre-first-press entropy injection despite the "never split before the
-- first press" rule elsewhere (see that comment for the full reasoning -
-- the risk is a stray encounter firing during that blind window and
-- getting misread as real data). Any dropdown target listed here gets
-- its battle-hook encounter checked against the expected species before
-- being trusted - a mismatch is silently discarded and retried instead
-- of recorded, the same protection the Gift Pokemon path already has for
-- Eevee/Shuckle/Spearow. This is what closes the loop and makes the
-- pre-first-press split safe specifically for the target(s) listed here,
-- without touching the shared safety rule that still protects every
-- other target with real dialogue to mash through.
local BATTLE_TARGET_EXPECTED_SPECIES = {
    ["Lapras"] = "Lapras",
}

-- Suicune (Tin Tower 1F, the real "loadwildmon SUICUNE, 40 / startbattle"
-- moment): confirmed against the disassembly (maps/TinTower1F.asm,
-- TinTower1FSuicuneBattleScript) that this trigger is a scene_script
-- (SCENE_TINTOWER1F_SUICUNE_BATTLE) that auto-fires once the player is on
-- the TinTower1F map with the right story flags set - NOT a talk-to-NPC
-- interaction. (The Burned Tower beast-release cutscene some players call
-- "the burnt tower encounter" is a red herring for bot purposes -
-- confirmed via BurnedTowerB1F.asm that it has no loadwildmon/startbattle
-- at all, just Raikou/Entei/Suicune fleeing and special InitRoamMons; the
-- actual catchable/resettable battle is at Tin Tower.)
--
-- REVISED after real testing: the original assumption above ("the player
-- is already on the map, so it just auto-fires") was wrong - the
-- savestate actually starts OUTSIDE the tower entirely (confirmed via a
-- screenshot of the player standing in the courtyard below Tin Tower's
-- door, on maps/EcruteakTinTowerEntrance.asm), and there's no NPC or
-- dialogue there for the old default mash-A loop to do anything useful
-- with - it was just pressing A into empty air every reset, never
-- actually walking the player toward the tower at all, so the scene never
-- had a chance to trigger. Confirmed via maps/TinTower1F.asm that once
-- the player genuinely reaches that map (warp_event 9,15 / 10,15, coming
-- from Ecruteak City), TinTower1FSuicuneBattleScript IS entirely
-- automatic from there: applymovement PLAYER walks itself in, then
-- Raikou/Entei cameo (if not yet caught) and Suicune's own approach all
-- run via scripted applymovement/pause/cry/playsound calls with zero
-- waitbutton anywhere - genuinely no button input needed once inside,
-- all the way to startbattle.
--
-- So Suicune needs a real one-time WALK from the savestate's outside
-- position through the door (held-Up tile-steps, mashed via
-- DIALOGUE_MASH_CAP - see its declaration above), then just waiting out
-- the automatic cutscene - see the dedicated "Suicune" branch in the
-- mash-loop below instead of the default press-A path.
-- Joins OPEN_WORLD_STYLE_TARGETS (see above) for the same reason
-- "Static (open world)" needed it: no fixed expected species to guard
-- with BATTLE_TARGET_EXPECTED_SPECIES, so it needs the full
-- have_battle_controls-confirmed detection instead.

-- Electrode (Team Rocket Base B2F, the disguised-Voltorb puzzle room):
-- confirmed via the disassembly (maps/TeamRocketBaseB2F.asm,
-- RocketElectrode1/2/3) that every one of the 6 ball-sprite objects in
-- that room (SPRITE_VOLTORB visually, hence "looks like Voltorb" in
-- practice) is a REAL, unconditional Electrode encounter - each script is
-- just `cry ELECTRODE / loadwildmon ELECTRODE, 23 / startbattle`, no
-- randomness on which ones are "real," no dialogue, no faceplayer. This
-- is architecturally identical to Lapras above (a single trigger press
-- goes straight to battle, never reaching a second mash-loop tick before
-- startbattle fires), which is almost certainly why running this under
-- "Static (open world)" produced garbage alternating readings (Unknown
-- #255 / stale Slowbro data) instead of real Electrode encounters - the
-- same "zero injected entropy, and nothing to catch a stray/stale hook
-- firing" failure mode Lapras had.
--
-- Rather than giving Electrode its own dropdown entry (which is where
-- this went the first time, and got corrected), it gets the SAME
-- pre-first-press entropy treatment through "Static (open world)" itself
-- now, generically: that target is meant to cover ANY overworld
-- click-to-encounter object (Lugia, Electrode, and whatever else turns
-- up later) without needing a hardcoded species per target the way this
-- table requires. See wait_for_reload_settle()'s species_addr-zeroing
-- and the isBogusOpenWorldReading check further down for how "Static
-- (open world)" gets Lapras-equivalent protection without needing an
-- entry here. "Sudowoodo" is the separate, explicitly-named target for
-- the dialogue-driven Squirtbottle flow this module was originally built
-- around - see its own entry in STATIC_TARGET_ART/the dropdown list in
-- launcher.lua for that split.

-- Bumped well past the shared RngEnabler.SPLIT_RANGE (256) - kept as a
-- module-local override (not a change to data/rng_enabler.lua) so this
-- experiment doesn't silently slow down Starters/Egg too, which use the
-- shared constant. NOT reintroducing a fixed split-COUNT cap alongside
-- this: a fixed cap (originally 8) is what caused the "1 real encounter,
-- then instant-reset spam forever" bug - once the cap was hit, everything
-- after went 100% deterministic, which is a confirmed real bug, not a
-- theoretical one. Splits still fire every tick, uncapped; this only
-- makes each individual injection bigger. Also worth knowing: measured
-- Shuckle coverage (~3%) was already LOWER than the case-study's own
-- 8-split number (~16%) despite Shuckle already firing more than 8
-- splits per reset given its long dialogue - so split COUNT alone
-- doesn't look like the limiting factor here. This tests the other
-- lever (range per injection) instead.
--
-- Dialed back from 2048 to 512 (still 2x the original 256, but 4x
-- cheaper) - 2048 was pushing resets down to ~50 per 5 minutes, too
-- slow to iterate on. This is a speed/entropy middle ground so another
-- batch can actually get run in a reasonable amount of time.
--
-- 512 measured at ~21% effective coverage (up from ~3% at 256) - a much
-- bigger jump than the split-count tuning ever produced.
--
-- Dialed back down to 512 from the 1024 test: the reachable pool for a
-- given savestate is a fixed ceiling no matter how wide this range goes
-- (it's baked into that exact savestate, since BizHawk is deterministic -
-- see REROLL_INTERVAL_SECONDS below), so pushing per-tick range higher
-- and higher has diminishing value and a real speed cost on literally
-- every reset. Better trade: keep per-tick range cheap/fast, and instead
-- periodically re-roll the savestate itself so a run isn't permanently
-- stuck with whatever pool the very first savestate happened to land on.
--
-- Dialed down further, 512 -> 256: once re-rolling happens automatically
-- every REROLL_INTERVAL_SECONDS regardless of outcome, a "wasted" 30-min
-- window (one whose pool happens to exclude all 8 shiny states) costs
-- the same fixed time either way - so a bigger pool that makes each
-- window less likely to be a total waste doesn't pay for itself if it
-- also means far fewer resets fit inside that same window. Simulated
-- this with realistic measured throughput per range (256 ~1900-state
-- pool at high speed vs 512's ~13920-state pool at lower speed): the
-- faster/smaller-pool setting won on expected real time to shiny,
-- because cycling through more 30-min windows per hour matters more
-- than each individual window's odds. Speed wins once reroll is in play.
local STATIC_SPLIT_RANGE = 256

-- ===== Dribble range for the instant-trigger targets (Static (open =====
-- ===== world)/Sudowoodo/Suicune/Lapras), settled after a real A/B/C =====
-- ===== test - see below for the numbers and why 1024 won =====
-- Ran a cycling 256/1024/4096 experiment (see git history/prior comments
-- for the mechanics, removed now that it's served its purpose) across 9
-- real reroll windows. Fitting a birthday-collision model to the observed
-- unique-combo counts gave consistent-ish per-baseline pool-size
-- estimates - ~235 at 256, ~752 at 1024, ~2543 at 4096 - and combining
-- those with measured throughput (256 ~2400/hr, 1024 ~1600/hr, 4096
-- ~760/hr) into an expected-time-to-shiny model predicted 1024 as the
-- winner (~66 modeled hours, vs ~140 for 256 and ~92 for 4096) because
-- 4096's bigger pool wasn't worth much when the fixed 30-minute reroll
-- window isn't long enough to actually search a pool that size before
-- getting cut off.
--
-- 1024 picked the right winner, but the actual magnitude was WAY off:
-- a real shiny was caught 8,007 encounters into that same run (~4.5 real
-- hours, mostly at 1024), practically matching the naive independent-draw
-- estimate (8192 attempts / measured throughput ~ 5 hours) - nowhere
-- close to the ~66-hour model prediction. That gap means the birthday-fit
-- pool-size numbers above were very likely a significant underestimate of
-- the TRUE reachable range (a known failure mode of collision-based
-- estimators when the underlying distribution has a long tail beyond
-- what limited samples reveal) - the "this baseline might structurally
-- exclude the shiny most windows" risk the model leaned on is real in
-- principle (that's what the whole Suicune saga was about) but far
-- smaller in practice than that model said. Take the ~66/140/92-hour
-- numbers as "which one's better," not as literal ETAs.
--
-- Net result: 1024 confirmed as the setting to keep - real coverage win
-- over the original 256 (per-baseline pool measurably ~3x bigger) without
-- 4096's throughput cost, and now with an actual caught shiny as a real-
-- world data point instead of just a model. Fixed here instead of still
-- cycling - if a future report suggests this needs revisiting, the A/B/C
-- methodology above is the one to reuse, just trust the real observed
-- time-to-shiny over the theoretical model if they disagree again.
local FIXED_DRIBBLE_RANGE = 1024
local function current_dribble_range()
    return FIXED_DRIBBLE_RANGE
end

-- Separate, INDEPENDENTLY-tunable range for "Static (open world)" ONLY -
-- split off from FIXED_DRIBBLE_RANGE above on a real user request after a
-- log showed only ~6% of 30-minute Electrode windows even had a
-- shiny-valid combo reachable at all (mean K~516 at range 1024, measured
-- across many real logs).
--
-- Deliberately scoped to "Static (open world)" alone, NOT Sudowoodo or
-- Lapras too, despite all three sharing dribble_entropy_until_hook() -
-- explicit user call: Sudowoodo already gets real extra entropy runway
-- from its own 3-step textbox sequence (see that branch below) and
-- Lapras is believed to have more frames before its encounter too, so
-- neither needs this widened range the way "Static (open world)" does -
-- that target has the least runway of the three (a single bare trigger
-- press, no textbox, per the disassembly), making the one guaranteed
-- pre-press split the only real lever it has.
--
-- The A/B/C test that settled on 1024 above was run entirely on SUICUNE,
-- which averages ~3 splits per attempt thanks to its multi-step walk-in -
-- there was real room for range size and split count to trade off against
-- each other. Inheriting that value for "Static (open world)" was never
-- actually verified for its very different (single-press, no-dialogue)
-- shape - it just happened to be the only value that existed when it was
-- added to the dribble design.
--
-- Starting at 4096 (the widest value already real-world-validated in the
-- Suicune A/B/C test, rather than picking a totally untested number) -
-- explicitly a STARTING POINT for this target, not yet independently
-- re-verified the way Suicune's 1024 has been. Send a follow-up Static
-- (open world) log after running with this so the resulting K can
-- actually be measured and compared against the ~516 baseline above,
-- same methodology as the original Suicune test - trust that real
-- measurement over this starting guess if they disagree.
local INSTANT_TRIGGER_DRIBBLE_RANGE = 4096

-- Which range is actually in force for whatever target is currently
-- selected - used by the raw per-encounter log print below so post-hoc
-- log analysis (fitting K from a real log, same as every prior range
-- experiment in this project) still correctly attributes the range that
-- was really used, now that it can differ by target instead of always
-- being the single old FIXED_DRIBBLE_RANGE value.
local function active_dribble_range()
    local target = StaticTargetDropdown and forms.gettext(StaticTargetDropdown)
    if target == "Static (open world)" then
        return INSTANT_TRIGGER_DRIBBLE_RANGE
    end
    return current_dribble_range()
end

-- Targets that get the full "Static (open world)" hardened battle-hook
-- treatment: the battle-menu-confirm wait (have_battle_controls, pressing
-- B until the real FIGHT menu loads), the species==0/255 + HP + own-party
-- sanity checks, and exclusion from the Gift Pokemon path. Originally
-- built for Electrode/Lugia-style click-to-battle targets with no fixed
-- expected species to guard against with BATTLE_TARGET_EXPECTED_SPECIES.
-- Suicune joined this list once real testing showed its trigger runs
-- through the exact same EnemyWildmonInitialized hook with nothing to
-- hang a species-name guard off of either - see the big Suicune comment
-- block below for why (and for its walk-in-then-mash handling, its other
-- special case).
--
-- "Sudowoodo" joins here too on an audit pass, not a specific bug report:
-- the top-of-file comment already classified it as a "battle-style
-- static" alongside the legendary beasts/birds (goes through
-- EnemyWildmonInitialized like every other target here, never a party-
-- size gift), same as Suicune/"Static (open world)" - and it has no
-- fixed expected species to hang a BATTLE_TARGET_EXPECTED_SPECIES guard
-- off of (Sudowoodo is the only species it should ever be, but so was
-- Electrode for "Static (open world)" before the Slowbro saga showed
-- unguarded battle-style targets need this regardless). Before this it
-- had NONE of these protections and, worse, no entropy injection at all
-- (see its new branch in the mash-dispatch chain below) - this closes
-- both gaps at once. Report back if this turns out to be wrong about
-- Sudowoodo's trigger mechanics.
local OPEN_WORLD_STYLE_TARGETS = {
    ["Static (open world)"] = true,
    ["Suicune"] = true,
    ["Sudowoodo"] = true,
    -- Snorlax joins on the same reasoning as Sudowoodo right above: it's
    -- a genuine wild-style battle via EnemyWildmonInitialized once
    -- triggered (catchable/fleeable, not a party-size gift), reached via
    -- a person-event interaction with no ambient wild encounters nearby
    -- to worry about - same shape as Sudowoodo, just with its own
    -- dedicated step count below instead of reusing "Static (open
    -- world)"'s single-press assumption.
    ["Snorlax"] = true,
}
local function is_open_world_style_target(name)
    return OPEN_WORLD_STYLE_TARGETS[name] == true
end

-- Used to be a fixed "UNTUNED FIRST GUESS" step count (8) for how many
-- held-Up tile-steps it takes to walk the savestate's starting position -
-- just outside Tin Tower, confirmed via a screenshot of the player
-- standing below the tower's door - through the door and onto the
-- TinTower1F map, where TinTower1FSuicuneBattleScript's scene_script can
-- actually trigger. That's exactly the same class of guess that caused
-- the real Sudowoodo/Snorlax stalls (see DIALOGUE_MASH_CAP above) - if 8
-- steps ever undershot the door, the walk-in stepFn would stop pressing
-- Up while isDribbleTarget's no-op branch let a still-short-of-the-door
-- character sit there forever. Pre-emptively switched to the same
-- DIALOGUE_MASH_CAP mash-every-iteration approach below (walking a few
-- extra tile-steps into an already-automatic cutscene is harmless the
-- same way a few extra A-presses are) rather than waiting for a real
-- stuck report to prove this constant was wrong too - no fixed step
-- count needed anymore, so there's no local declaration left here.
-- Frames to hold Up per simulated tile-step - 16 is standard Gen II
-- overworld walking speed (one full tile per 16 frames at normal, non-
-- bike pace); using press_button()'s hold-then-release shape so each
-- call reliably completes exactly one step before the next begins.
local SUICUNE_WALK_HOLD_FRAMES = 16

-- Since the reachable DV pool is fixed for a given savestate (BizHawk is
-- fully deterministic - reloading the same savestate and replaying any
-- combination of delays can only ever reach whatever states are latent
-- in that exact starting point), a run that never re-saves is capped at
-- one fixed pool for its entire duration - if that pool happens to
-- exclude all 8 shiny states, no amount of resets will ever produce one.
-- Every real Start click gets a genuinely different pool "for free"
-- because the game's RNG registers have been evolving unpredictably in
-- the background the whole time before that click - this automates that
-- same effect periodically, without needing a manual Stop/Start.
--
-- Re-baselining is done with ONE big FULL_COVERAGE_RANGE delay (not the
-- cheap per-tick STATIC_SPLIT_RANGE) specifically to make the new
-- starting point as unpredictable as possible relative to the old one -
-- this only costs that ~35000-frame average once per interval, not per
-- reset, so it doesn't meaningfully affect overall throughput.
local REROLL_INTERVAL_SECONDS = 1800 -- 30 minutes
local lastRerollTime = nil

-- The FIRST A press after every reload is special: confirmed via user
-- testing that a savestate taken even one frame before the NPC's text
-- box actually opens breaks the reset loop (false party-size/instant-
-- reset), while a savestate taken one frame later - after the box is
-- already up - works perfectly. A long 12-frame hold straddles that
-- exact "conversation not yet open" -> "conversation opening" boundary
-- if it lands on the wrong frame, which is exactly the trap. Since we
-- can't guarantee the savestate always lands a frame after that
-- boundary, the fix is to never risk it: the very first press after any
-- reload always uses the short, proven-safe 4-frame hold (same as
-- Eevee) just to safely open the conversation - only presses AFTER that
-- (once a text box is confirmed already open) get the longer Shuckle
-- hold. Reset alongside mashSplitsFired everywhere that gets zeroed.
local firstPressPending = true

local function current_hold_frames()
    if firstPressPending then
        return 4
    end
    if StaticTargetDropdown then
        local target = forms.gettext(StaticTargetDropdown)
        if target == "Shuckle" then
            return SHUCKLE_HOLD_FRAMES
        elseif target == "Spearow" then
            return SPEAROW_HOLD_FRAMES
        elseif target == "Celebi" then
            return CELEBI_HOLD_FRAMES
        elseif target == "Snorlax" then
            return SNORLAX_HOLD_FRAMES
        elseif target == "Sudowoodo" then
            return SUDOWOODO_HOLD_FRAMES
        end
    end
    return 4
end

-- Waits for party_base_addr to genuinely reflect the just-reloaded
-- state (i.e. actually back down to partysizeBeforeReceiving) instead
-- of just guessing a fixed number of settle frames. Confirmed via user
-- reports that even a fixed 8-frame wait wasn't always enough -
-- savestate.loadslot() apparently doesn't always finish settling within
-- the same handful of frames every time, so waiting for the REAL
-- condition we actually care about is more robust than any constant.
--
-- Bumped 60 -> 240: user reports the "1 real encounter, then instant-
-- reset spam forever" bug only clears with a full Stop/Start (which
-- forces a brand new savestate.saveslot() + a fresh partysizeBeforeReceiving
-- read via on_resume()) - that points at the settle genuinely NOT
-- finishing within the old 60-frame window at least once, after which
-- party_base_addr stays permanently out of sync with partysizeBeforeReceiving
-- for the rest of that run (every later tick sees it as "elevated",
-- repeatedly re-triggering the gift-detection branch on stale/bogus
-- data). A Stop/Start "fixes" it only because it resets the comparison
-- baseline, not because whatever caused the slow settle went away.
-- Always prints (not gated behind Verbose Logging) when a timeout
-- actually happens, since that's the exact signal needed to confirm
-- this is the mechanism rather than something else entirely.
local function wait_for_reload_settle()
    local waited = 0
    while memory.readbyte(party_base_addr) ~= partysizeBeforeReceiving and waited < 240 do
        emu.frameadvance()
        waited = waited + 1
    end
    if waited >= 240 then
        print(string.format(
            "WARNING: reload settle timed out after %d frames - party_base_addr never returned to %d (still reads %d). State is likely stuck; a Stop/Start may be needed if resets stop progressing.",
            waited, partysizeBeforeReceiving, memory.readbyte(party_base_addr)))
        return false
    end

    -- Generic freshness guard for every OPEN_WORLD_STYLE_TARGETS member
    -- (see its declaration above): force species_addr back to 0 right
    -- after every reload. Originally built just for "Static (open
    -- world)" (Lugia, Electrode's disguised Voltorb room, and any future
    -- click-to-encounter target like them - deliberately NOT species-
    -- specific, since it's meant to work for whatever overworld object
    -- the player is standing in front of, without a hardcoded expected-
    -- species list per target the way Lapras's BATTLE_TARGET_EXPECTED_SPECIES
    -- entry needed) - Suicune joined it for the identical reason once its
    -- trigger turned out to go through this same hook with no NPC/species
    -- to guard against by name either.
    --
    -- Without this, a reload can leave species_addr holding whatever was
    -- last written there - either genuinely stale data from an unrelated
    -- earlier battle context (confirmed by a user report: readings
    -- alternating between "Unknown #255" and a leftover "Slowbro" that
    -- has nothing to do with the Electrode room being hunted), or simply
    -- 0/uninitialized. Zeroing it here makes species_addr's value
    -- provably trustworthy the moment pendingEncounterUpdate fires: it
    -- can only read as non-zero/non-0xFF again once the actual game code
    -- has genuinely written fresh enemy data, which is exactly the
    -- signal the encounter-recording logic needs to trust a reading
    -- without knowing in advance which species to expect.
    if StaticTargetDropdown and is_open_world_style_target(forms.gettext(StaticTargetDropdown)) and species_addr then
        memory.writebyte(species_addr, 0)
    end

    return true
end

local function shiny(atk, sp)
    shinyvalue = 0
    if sp == 0xAA then
        if atk == 0x2A or atk == 0x3A or atk == 0x6A or atk == 0x7A or atk == 0xAA or atk == 0xBA or atk == 0xEA or atk == 0xFA then
            shinyvalue = 1
            return true
        end
    end
    return false
end

-- holdFrames defaults to 4 (the original, unchanged timing used by
-- Eevee and every other gift/static target). The "Shuckle" dropdown
-- option below passes a longer holdFrames instead - same ONE press per
-- step as always, just held down longer per press, for NPCs with much
-- longer multi-page dialogue (Shuckle's stolen-Pokemon backstory in
-- Cianwood vs. Eevee's one-line handoff). Confirmed via user report that
-- pressing A MORE OFTEN per step (two presses per tick) made things
-- worse, not better - so this only ever changes hold duration, never
-- frequency.
local function press_button(btn, holdFrames)
    holdFrames = holdFrames or 4
    local input = {[btn] = true}
    for i = 1, holdFrames do
        joypad.set(input)
        emu.frameadvance()
    end
    joypad.set({})
    emu.frameadvance()
end

-- ===== Auto-catch machinery (ported from wild.lua/fishing.lua) =====
-- Only used by the "Static (open world)" battle-style path
-- (pendingEncounterUpdate below) - the Gift Pokemon path (Eevee/Shuckle/
-- Spearow) never enters a battle at all, so none of this ever runs for it.

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

-- Scans the bag for the first ball type found, in BALL_ITEM_IDS
-- preference order. Returns the item ID found, or nil if no balls at all.
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

-- Total balls remaining across ALL ball types combined, not just
-- whichever one is currently being thrown.
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

-- Verified via wPartyMon1Moves offset (+0x0A from party base) - counts
-- how many of the 4 move slots are non-zero. Only used as a fallback
-- disambiguation check inside do_catch_attack_turn when MoveSelectionAddr
-- doesn't fire in time - see there for the full explanation.
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

-- Navigates PACK -> scrolls to the given ball -> selects it (which
-- throws it directly at the wild Pokemon).
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

    -- Give the Pack menu a moment to actually open and settle.
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

    -- Balls live in their own pocket, one or two Right presses over from
    -- the Items pocket the menu opens into by default - BUT the menu
    -- remembers its last position across throws, so check first and only
    -- switch pockets if we're not already there.
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
            -- Selecting the ball opens a Use/Quit-style submenu, already
            -- sitting on "Use" - let the caller's confirm-loop press A
            -- directly, no cursor adjustment needed.
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
-- deliberately not a "kill" turn (static.lua has no kill mode, and
-- move-learn detection doesn't apply here). Returns "fainted" if the
-- attack accidentally faints the target, "ok" otherwise, "stuck" if
-- battle controls never came back, or "move2_stuck" if second-move
-- navigation genuinely failed.
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
    -- anything else - address-confirmed via MoveSelectionAddr when
    -- available, falling back to a fixed wait otherwise.
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

    -- Prefer the first move, but fall back to the second if the first is
    -- out of PP. The caller already confirmed at least one of the two
    -- has PP before calling this function at all.
    local usedSecondMove = false
    if memory.readbyte(FIRST_MOVE_PP_ADDR) == 0 then
        usedSecondMove = true
        vprint("First move out of PP - using the second move instead")
        press_and_wait_for_cursor_change(navigate_to_menu_option(MOVE2_CURSOR), 30)

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
            return "ok"
        end

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
            return "ok"
        end
        move2NavFailStreak = 0
    else
        move2NavFailStreak = 0
    end
    press_button("A")

    -- No species_addr/enemy_hp_addr checks during this wait - both can go
    -- unreliable during this exact transition (see wild.lua for the full
    -- confirmed-via-evidence explanation) - just wait for
    -- have_battle_controls with a bounded timeout.
    have_battle_controls = false
    local postAttackWait = 0
    local postAttackTimeout = usedSecondMove and 1800 or 600
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

-- shinyEmbedFields/shinySpriteUrl (optional): the detailed fields already
-- built by M.step()'s pendingEncounterUpdate handling for THIS same
-- shiny encounter - merged into the initial "found! attempting to catch"
-- notification instead of arriving as a separate embed, same as wild.lua.
--
-- Return contract is intentionally 3-way (NOT the plain true/false wild.lua
-- and fishing.lua use), because static.lua's reload-based loop needs to
-- tell these apart at the call site:
--   "caught"   - a genuine successful catch. MUST NOT be followed by a
--                savestate reload (that would rewind BizHawk's state and
--                erase the catch, since it was never saved to the real
--                cartridge) - the caller should just stop here.
--   "continue" - the target fainted/escaped during the attempt, or
--                something recoverable happened. Nothing was kept, so
--                it's safe (and desirable) for the caller to reload the
--                savestate and keep resetting for another attempt.
--   "stop"     - something needs manual intervention (no balls, timeout,
--                out of throws, navigation stuck, Stop was pressed). The
--                caller should stop without reloading, same as it would
--                have without Auto-Catch at all.
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

    -- This fires immediately and synchronously the instant the encounter
    -- is confirmed - potentially before the battle menu has had any
    -- chance to load at all. Wait for it explicitly.
    local waitFrames = 0
    while not have_battle_controls and waitFrames < 300 do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return "stop"
        end
        press_button("B")
        waitFrames = waitFrames + 1
    end
    if not have_battle_controls then
        print("Catch-mode: battle menu never loaded within the timeout - stopping so you can take over.")
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu timeout).", label, caughtSpeciesName),
            COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return "stop"
    end

    -- species_addr can still be oscillating for a while even right as
    -- have_battle_controls first becomes true - give it a settling window.
    for i = 1, 60 do
        emu.frameadvance()
    end

    local ballId = find_ball_in_bag()
    if not ballId then
        print("No balls in the bag - stopping so you can restock and catch it manually.")
        send_catch_notification(string.format("%s%s could not be caught, bot stopped (no balls left).", label, caughtSpeciesName),
            COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
        return "stop"
    end

    -- Weaken the enemy to a safe-but-catchable HP range first - skippable
    -- entirely via "Don't weaken enemy Pokemon" in Auto-Catch Settings.
    if not Gui.dont_weaken_enabled(hud) then
    local lastDamageDealt = nil
    local previousHP = nil
    local overrideCritSafety = Gui.crit_safety_override_enabled(hud)
    local targetPercent = overrideCritSafety and Gui.custom_catch_hp_target(hud) or CATCH_HP_TARGET_PERCENT
    while true do
        if stop_was_requested() then
            print("Catch-mode: Stop requested - aborting.")
            return "stop"
        end
        local curHP = memory.read_u16_be(enemy_hp_addr)
        local maxHP = memory.read_u16_be(enemy_max_hp_addr)
        if maxHP == 0 then
            print("Catch-mode: couldn't read enemy max HP - stopping so you can catch it manually.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (couldn't read enemy max HP).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
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
            print(string.format("Catch-mode: out of PP on the first two moves while weakening %s - stopping so you can handle this manually.", caughtSpeciesName))
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (out of PP on first two moves).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
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
                    return "stop"
                end
                press_button("B")
            end
            return "continue"
        elseif result == "stuck" then
            print("Catch-mode: got stuck while weakening the enemy (likely fainted) - clearing messages and resuming the hunt.")
            send_catch_notification(string.format("%s%s was not caught, most likely fainted.", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            for i = 1, 400 do
                if stop_was_requested() then
                    print("Catch-mode: Stop requested - aborting.")
                    return "stop"
                end
                press_button("B")
            end
            return "continue"
        elseif result == "move2_stuck" then
            print(string.format("Catch-mode: stopping bot - couldn't reliably use the second move on %s.", caughtSpeciesName))
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (second-move navigation failed).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
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
            return "stop"
        end
        ballId = find_ball_in_bag()
        if not ballId then
            print("Ran out of balls mid-catch - stopping so you can restock and finish manually.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (ran out of balls mid-catch).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
        end

        local remainingBalls = total_ball_count()
        if remainingBalls <= LOW_BALL_THRESHOLD then
            print(string.format("Catch-mode: only %d ball(s) left total - stopping so you can finish manually.", remainingBalls))
            send_catch_notification(string.format(
                "%s%s could not be caught, bot stopped (only %d ball(s) left, preserved for manual catching).", label, caughtSpeciesName, remainingBalls),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
        end

        local navigated = navigate_to_pack_and_select_ball(ballId)
        if not navigated then
            print("Catch-mode: failed to navigate to the ball - stopping so you can take over.")
            send_catch_notification(string.format("%s%s could not be caught, bot stopped (navigation stuck).", label, caughtSpeciesName),
                COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
            return "stop"
        end

        catchOutcomeSucceeded = false
        catchOutcomeFailed = false
        local ballWaitFrames = 0
        while not catchOutcomeSucceeded and not catchOutcomeFailed and ballWaitFrames < 1200 do
            if stop_was_requested() then
                print("Catch-mode: Stop requested - aborting.")
                return "stop"
            end
            press_button("A")
            for i = 1, 15 do
                emu.frameadvance()
            end
            ballWaitFrames = ballWaitFrames + 20
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
                    return "stop"
                end
                press_button("B")
            end
            print("Caught - stopping here so it's preserved (reloading the savestate now would undo the catch).")
            return "caught"
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
                    return "stop"
                end
                press_button("A")
                recoverFrames = recoverFrames + 1
            end
            if not have_battle_controls then
                -- Genuinely didn't recover in time - report this specific
                -- failure instead of falling through into
                -- navigate_to_pack_and_select_ball() with a false premise
                -- (see comment above).
                print("Catch-mode: battle menu didn't reload after the failed throw within the extended timeout - stopping so you can take over.")
                send_catch_notification(string.format("%s%s could not be caught, bot stopped (battle menu didn't return after a failed throw).", label, caughtSpeciesName),
                    COLOR_RED, caughtSpeciesId, isShiny, caughtItemName)
                return "stop"
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
    return "stop"
end

-- Hooks get REPLACED by name every time RegisterROMHook runs - must be
-- called every time this module becomes active, not just once. See
-- wild.lua for the original confirmation of this behavior.
local function register_hooks()
    if CatchSuccessAddr then
        Mem.RegisterROMHook(CatchSuccessAddr, function()
            if ActiveModuleName ~= "static" then return end
            catchOutcomeSucceeded = true
            vprint("PokeBallEffect.caught entered - the catch definitely succeeded")
        end, "Detect Catch Success")
    end

    if CatchFailAddr then
        Mem.RegisterROMHook(CatchFailAddr, function()
            if ActiveModuleName ~= "static" then return end
            catchOutcomeFailed = true
            vprint("PokeBallEffect.shake_and_break_free entered - the Pokemon definitely broke free")
        end, "Detect Catch Failure")
    end

    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "static" then return end
        have_battle_controls = true
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    if MoveSelectionAddr then
        Mem.RegisterROMHook(MoveSelectionAddr, function()
            if ActiveModuleName ~= "static" then return end
            moveSelectScreenOpen = true
            vprint("MoveSelectionScreen entered - move-select submenu confirmed open")
        end, "Detect Move Select Screen")
    end

    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "static" then return end
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        -- Splits count added per a user request while chasing a
        -- suspiciously long shiny-less streak on Electrode (45k+ resets,
        -- 0 shinies) - the Gift Pokemon path already logs this
        -- (mashSplitsFired), this hook-driven path never did. Needed to
        -- see directly how much entropy is actually going into each
        -- encounter instead of inferring it indirectly from DV
        -- distributions after the fact.
        --
        -- "Range: %d" was added for the now-finished 256/1024/4096 dribble-
        -- range experiment (see FIXED_DRIBBLE_RANGE above STATIC_SPLIT_
        -- RANGE for the result and reasoning) - left in since it's cheap
        -- and confirms the setting in force. Now reads active_dribble_
        -- range() instead of always current_dribble_range(), since Static
        -- (open world)/Sudowoodo/Lapras use their own independent
        -- INSTANT_TRIGGER_DRIBBLE_RANGE - see that constant's declaration.
        -- Still meaningless for targets that don't use
        -- dribble_entropy_until_hook() at all (Eevee/Shuckle/Spearow/
        -- Celebi).
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s | Splits: %d | Range: %d",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName, mashSplitsFired, active_dribble_range()))

        pendingEncounterUpdate = true
    end, "Static Encounter Battle Started")
end

-- ===== M.init: runs ONCE =====
-- Stop-on-species, stop-on-item, kill mode, and stop-on-shiny stay
-- greyed out - static's species is fixed/known per target (a species
-- filter doesn't apply the way it does for Wild), and killing a static
-- is never desirable. "Stop on shiny" specifically stays disabled too:
-- static.lua doesn't need a separate override toggle for it - Auto-Catch
-- itself IS the toggle (off = always stop manually on shiny, exactly
-- like before; on = attempt to catch it, per the settings below).
--
-- Every other Auto-Catch Settings field is now LIVE for Static (open
-- world) encounters - auto_catch, its species filter, skip-already-
-- caught (living dex mode), the auto-catch exception list, the crit-
-- safety override + custom HP target, catch-on-item (+ its filter), and
-- don't-weaken all get read by do_catch_sequence/M.step() below now.
--
-- True Randomness stays disabled - static.lua no longer calls
-- Gui.true_randomness_enabled() at all, since reroll_savestate_pool()'s
-- periodic full-coverage injection supersedes it for this module (see
-- the comment by mashSplitsFired's declaration). Greyed out here so it's
-- visually obvious it has no effect while Static is the active module,
-- instead of silently doing nothing. Verbose Logging stays checkable.
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkStopOnShiny",
    "chkTrueRandomness",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    -- SAVESTATE_SLOT is deliberately NOT set here anymore - see
    -- M.on_switch_to() below for why (M.init() only runs once per
    -- BizHawk session, which silently ignored later dropdown changes).

    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x53 or region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            -- Verified against pokecrystal.sym: PokeBallEffect.caught /
            -- .shake_and_break_free (bank $03), MoveSelectionScreen
            -- (bank $0F) - same addresses wild.lua/fishing.lua use.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
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
            -- EnemyWildmonInitialized/CatchSuccessAddr/CatchFailAddr are
            -- shifted by a couple bytes; LearnMoveAddr isn't used by this
            -- module so wasn't needed here. enemy_addr (0xD20C, same as
            -- English) is now CONFIRMED for this build too - a real
            -- mid-battle WRAM dump (diagnose_wram_addresses.lua) from
            -- dynux90 showed sensible, internally-consistent values
            -- (matching species, full-HP enemy_hp==enemy_max_hp, correct
            -- held item) reading from this address during an actual
            -- Lugia static battle, confirming WRAM layout is unchanged
            -- from English here.
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7649)
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f7)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bde)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x69f5)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6bdc)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x64bc)
            Mem.SetRomBankAddress("Crystal")
        else
            print("No valid ROM detected")
            return false
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 or region == 0x45 then
            -- Verified against pokegold.sym: enemy_addr is wEnemyMonDVs
            -- ($D0F5), NOT $DA22 (which is actually wPartyCount - the
            -- same bug already found and fixed in wild.lua/fishing.lua/
            -- headbutt.lua, but missed here since static.lua has its own
            -- separate copy of this setup). EnemyWildmonInitialized
            -- corrected to the .skip_unown sub-label ($7400).
            enemy_addr = 0xd0f5
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            -- Verified against pokegold.sym: PokeBallEffect.caught /
            -- .shake_and_break_free (bank $03), MoveSelectionScreen
            -- (bank $0F) - same addresses wild.lua/fishing.lua use.
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            -- STILL UNVERIFIED - same enemy_addr=party_base_addr bug
            -- pattern, no JP-specific symbol data available.
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            CatchSuccessAddr = Mem.BankAddressToLinear(0x3, 0x6a79)
            CatchFailAddr = Mem.BankAddressToLinear(0x3, 0x6c45)
            MoveSelectionAddr = Mem.BankAddressToLinear(0xF, 0x62f3)
            Mem.SetRomBankAddress("Gold")
        else
            print("No valid ROM detected")
            return false
        end
    else
        print("No valid ROM detected")
        return false
    end

    species_addr = enemy_addr + 0x22
    item_addr = enemy_addr - 0x05
    -- Verified via pokecrystal.sym/pokegold.sym: wEnemyMonHP/wEnemyMonMaxHP
    -- are +0x0A/+0x0C from the same base as enemy_addr in both games -
    -- needed to compute HP% for the weaken phase below.
    enemy_hp_addr = enemy_addr + 0x0A
    enemy_max_hp_addr = enemy_addr + 0x0C

    -- NOTE on species_addr (enemy_addr + 0x22, above): cross-referencing
    -- macros/ram.asm's battle_struct layout against enemy_addr's own
    -- verified identity (wEnemyMonDVs) suggests species_addr may not
    -- actually land on wEnemyMonSpecies at all, but one byte past
    -- wBattleMode/wTempWildMonSpecies instead - a plausible explanation
    -- for the recurring bogus-encounter reports (Slowbro, then "Ivysaur
    -- ... [Ultra Ball]", then "Pinsir ... [Card Key]"), all of which read
    -- as individually stable/valid/non-placeholder data despite not being
    -- real encounters. That struct-arithmetic derivation was NOT reliable
    -- enough to build a fix on directly, though - a first attempt at it
    -- (gating on a hand-derived wBattleMode address, enemy_addr + 0x21)
    -- still let both bogus reports through, meaning at least one of the
    -- constants it rested on (NUM_EXP_STATS, SERIAL_RN_PREAMBLE_LENGTH,
    -- SERIAL_RNS_LENGTH - none confirmed against this codebase's actual
    -- verified values) was wrong. The real fix (see the
    -- have_battle_controls wait in M.step()'s pendingEncounterUpdate
    -- handling) sidesteps needing this address at all, using the
    -- already-verified "Detect Battle Menu" hook instead.

    -- Menu-cursor/battle-UI addresses for the catch machinery - same
    -- verified values wild.lua/fishing.lua use (confirmed via direct
    -- symbol lookup: these live at different addresses between Crystal
    -- and Gold/Silver).
    if version == 0x55 or version == 0x58 then
        curPartyMonAddr = 0xcfc6
        MENU_CURSOR_Y = 0xCEE0
        MENU_CURSOR_X = 0xCEE1
        FIRST_MOVE_PP_ADDR = 0xCB14
        wCurItemAddr = 0xD002
        wItemsAddr = 0xD5B8
        wNumItemsAddr = 0xD5B7
        wBallsAddr = 0xD5FD
        wNumBallsAddr = 0xD5FC
        -- Verified against pokegold1.sym: wScriptRunning (bank $01:$D15F,
        -- i.e. plain $D15F through the normal SVBK-switched WRAM view
        -- every other WRAM address in this file already relies on). Non-
        -- zero for the whole duration of any overworld script - NPC
        -- dialogue (faceplayer/opentext/...), a Pokegear call prompt,
        -- a cutscene, etc. Used by reroll_savestate_pool() to confirm
        -- the game is actually idle before saving a new baseline,
        -- instead of guessing with a fixed number of blind button
        -- presses. See reroll_savestate_pool() for why this replaced
        -- that guess.
        wScriptRunningAddr = 0xD15F
    else
        curPartyMonAddr = 0xd0d4
        MENU_CURSOR_Y = 0xCFA9
        MENU_CURSOR_X = 0xCFAA
        FIRST_MOVE_PP_ADDR = 0xC634
        wCurItemAddr = 0xD106
        wItemsAddr = 0xD893
        wNumItemsAddr = 0xD892
        wBallsAddr = 0xD8D8
        wNumBallsAddr = 0xD8D7
        -- Verified against pokecrystal.sym: wScriptRunning ($D438). See
        -- the Gold/Silver branch above for what this is used for.
        wScriptRunningAddr = 0xD438
    end

    -- Gift Pokemon (Eevee, etc.) are structurally different from
    -- battle-style statics (Sudowoodo, legendary beasts/birds) - they
    -- go directly into the party via NPC dialogue, never triggering a
    -- battle at all. The enemy-hook-based detection above never fires
    -- for these, so party size is tracked too - whichever condition
    -- fires first (battle starts, or party size increases) determines
    -- how the result gets read.
    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    end

    math.randomseed(os.time())
    register_hooks()

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand facing the static encounter, then click Start...")
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
    -- is clicked - confirmed via a real user report: switching the
    -- dropdown to a different slot and clicking Start again kept acting
    -- on the OLD slot from the module's first run this session.
    SAVESTATE_SLOT = AutocrystalGetSavestateSlot(5)

    register_hooks()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position
-- (facing the static encounter) as the reset target.
--
-- REVISED AGAIN: the previous two fixes here targeted "is the read/frame
-- stable" - but user testing ruled that whole class of theory out: the
-- bug reproduces ONLY on the very first Start of a session, never again
-- afterward even when pausing, walking away, and returning to line up
-- the EXACT same position and pressing Start the exact same way. Nothing
-- about player position or dialogue timing explains that - what's
-- actually different about the first Start vs. every later one is that
-- SAVESTATE_SLOT has never been saved to yet this BizHawk session.
--
-- Some emulators handle a save TO a completely fresh/never-used slot
-- differently under the hood than overwriting an already-used one (e.g.
-- first-time buffer allocation) - which fits the exact symptom: broken
-- only once, on that very first save, never again once the slot has been
-- exercised at all. Rather than guess at BizHawk's internals further,
-- this just neutralizes it directly: the first-ever on_resume() in a
-- session does a cheap throwaway save-then-load of SAVESTATE_SLOT BEFORE
-- capturing the real reset target, so the real capture is never the
-- first thing ever written to that slot.
function M.on_resume()
    -- Runs before EVERYTHING else in here, including the warm-up dance
    -- right below - that warm-up's own savestate.saveslot() call is
    -- itself the first write this slot would see this session, so the
    -- backup has to happen before it, not just before the "real" capture
    -- further down.
    SavestateBackup.backup_slot_before_first_write(SAVESTATE_SLOT, "Static")

    if not savestateSlotWarmedUp then
        savestate.saveslot(SAVESTATE_SLOT)
        savestate.loadslot(SAVESTATE_SLOT)
        savestateSlotWarmedUp = true
    end

    local baseline = memory.readbyte(party_base_addr)
    local stableFrames = 0
    local waited = 0
    while stableFrames < 2 and waited < 30 do
        emu.frameadvance()
        waited = waited + 1
        local current = memory.readbyte(party_base_addr)
        if current == baseline then
            stableFrames = stableFrames + 1
        else
            baseline = current
            stableFrames = 0
        end
    end

    savestate.saveslot(SAVESTATE_SLOT)
    mashSplitsFired = 0
    firstPressPending = true
    pendingEncounterUpdate = false
    shinyvalue = 0
    partysizeBeforeReceiving = baseline
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
-- when firstPressPending is true (i.e. right at a clean reset boundary,
-- standing in front of the NPC, nothing mid-flight) so it never risks
-- interrupting an in-progress detection.
--
-- This is the OTHER place (besides on_resume()) that saves a NEW reset
-- target rather than just reloading the existing one - and until now it
-- did so with none of on_resume()'s protection against the known
-- "captured one frame before the text box opens" trap (see
-- current_hold_frames() above). on_resume() only runs once, at Start;
-- this runs every REROLL_INTERVAL_SECONDS for as long as the bot keeps
-- running - so a bad capture here would show up as the reload-spam bug
-- recurring mid-run, not just at the start of a session, which matches
-- what's actually been observed. Added the same stability-confirm loop
-- on_resume() uses before saving here too.
-- v1 of this function used ONE blind RngEnabler.FULL_COVERAGE_RANGE delay
-- (~1-70000 frames, up to ~19 real minutes) with zero input, then saved
-- whatever state that landed in. A real Suicune report showed one genuine
-- capture right after a reroll, then 18 consecutive 60-second stuck-checks
-- in a row, every forced reload landing back in the same broken state -
-- which only makes sense if the state SAVED as the new baseline was
-- itself broken (BizHawk is perfectly deterministic, so reloading a
-- broken savestate and replaying identical inputs reproduces the exact
-- same "stuck" outcome every single time, forever, until the pool rerolls
-- again 30 minutes later).
--
-- v2 (this version) guessed the specific cause was a wandering courtyard
-- NPC opening a dialogue box mid-delay, and patched it by blindly
-- pressing B 10 times after the delay before saving. The user confirmed
-- that guess was wrong - the actual game console showed normal Pokegear
-- calls coming in and being declined, not a stuck dialogue. That means a
-- bounded, unconditional "press B N times" patch was never actually
-- verifying anything; it happened to do nothing meaningful and the real
-- problem was untouched.
--
-- v3 (below) stops guessing at what might be open and checks directly:
-- wScriptRunningAddr (see version-detection block above) is non-zero for
-- the ENTIRE duration of any overworld script - NPC dialogue, a Pokegear
-- call prompt, a cutscene, anything - regardless of which one. Instead of
-- pressing a fixed number of buttons and hoping, this waits and presses
-- B/A in a loop until that flag actually reads clear (bounded, so it
-- can't hang forever), which is a real confirmation rather than a guess.
--
-- It also replaces the single ~19-minute blind window with several much
-- shorter RngEnabler.SPLIT_RANGE (256-frame, ~4s) chunks, checking for an
-- active script after EVERY chunk instead of only once at the very end.
-- This is the same split-delay technique already proven for "Static
-- (open world)" above (see STATIC_SPLIT_RANGE and
-- diagnose_rng_split_delay.lua - confirmed close to multiplicative
-- coverage, e.g. two 256-frame splits reach ~256x256=65536 combinations
-- for a fraction of one big delay's average wait), just chained across
-- more chunks here for extra margin since a reroll only has to pay this
-- cost once every REROLL_INTERVAL_SECONDS. Two side benefits: any
-- randomly-timed overworld event (a call ringing, an NPC wandering into
-- the player) has many fewer consecutive real-time seconds of zero-input
-- exposure to land in per chunk, and the total average wait drops from
-- ~35000 frames (~9.7 minutes) to REROLL_SPLIT_COUNT * ~128 frames
-- (a few seconds) - directly fixing the "takes crazy long" complaint too.
local REROLL_SPLIT_COUNT = 6
local REROLL_SCRIPT_CLEAR_TIMEOUT = 180 -- frames to wait for wScriptRunning to clear

-- Presses B/A until wScriptRunningAddr reads 0 (or the bounded timeout is
-- hit) - a real confirmation that no dialogue/call/cutscene is mid-flight,
-- not a guess. No-op (returns immediately) if nothing is open, which is
-- the common case on every call.
local function wait_for_no_active_script(label)
    if not wScriptRunningAddr then return true end
    local waited = 0
    while memory.readbyte(wScriptRunningAddr) ~= 0 and waited < REROLL_SCRIPT_CLEAR_TIMEOUT do
        if stop_was_requested() then
            print("Stop requested during reroll script-clear wait - aborting.")
            return false
        end
        press_button(waited % 2 == 0 and "B" or "A")
        waited = waited + 1
    end
    if waited > 0 then
        print(string.format(
            "reroll_savestate_pool(): wScriptRunning was active (%s) - %s after %d frame(s).",
            label or "script/dialogue/call in progress",
            (memory.readbyte(wScriptRunningAddr) == 0) and "cleared it" or "gave up waiting for it to clear",
            waited))
    end
    return true
end

local function reroll_savestate_pool()
    print(string.format(
        "Re-rolling savestate pool after %d minutes - injecting fresh entropy across %d short split(s) and re-baselining to avoid getting permanently stuck if this pool excludes the shiny states.",
        math.floor(REROLL_INTERVAL_SECONDS / 60), REROLL_SPLIT_COUNT))


    for i = 1, REROLL_SPLIT_COUNT do
        if stop_was_requested() then return end
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        if not wait_for_no_active_script(string.format("split %d/%d", i, REROLL_SPLIT_COUNT)) then
            return
        end
    end

    local baseline = memory.readbyte(party_base_addr)
    local stableFrames = 0
    local waited = 0
    while stableFrames < 2 and waited < 30 do
        emu.frameadvance()
        waited = waited + 1
        local current = memory.readbyte(party_base_addr)
        if current == baseline then
            stableFrames = stableFrames + 1
        else
            baseline = current
            stableFrames = 0
        end
    end
    if waited > 2 then
        print(string.format("reroll_savestate_pool(): party_base_addr wasn't immediately stable, waited %d frames before saving - if the reload-spam bug shows up right after a reroll, this line is the first thing worth checking.", waited))
    end

    -- Final check right before saving - covers the (rare) case something
    -- started during the stability wait just above.
    wait_for_no_active_script("final pre-save check")

    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = baseline
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
        print(string.format("WARNING: no reset for %d+ seconds (stuck check #%d) - cause unknown, forcing a reload back to the last saved baseline.",
            STUCK_RESET_TIMEOUT, consecutiveStuckReloads))
        if consecutiveStuckReloads >= 2 then
            send_alert(string.format(
                "\xE2\x9A\xA0\xEF\xB8\x8F Likely stuck: no reset for over %d seconds, even after a forced reload attempt. Check on it.",
                STUCK_RESET_TIMEOUT * consecutiveStuckReloads), COLOR_RED)
        end
        savestate.loadslot(SAVESTATE_SLOT)
        -- A few real frames of buffer right after the reload, before
        -- ANYTHING re-reads memory - same fix as the other two
        -- loadslot() sites below, see there for the full explanation.
        wait_for_reload_settle()
        mashSplitsFired = 0
        firstPressPending = true
        pendingEncounterUpdate = false
        -- Deliberately NOT re-reading partysizeBeforeReceiving here - see
        -- the other two loadslot() sites below for why.
        lastResetTime = os.time()

        -- Backstop for the exact failure mode a real Suicune report
        -- showed (18 consecutive stuck-checks in a row): because BizHawk
        -- is perfectly deterministic, reloading the SAME saved baseline
        -- and replaying identical inputs reproduces the exact same
        -- outcome every time - so if the saved baseline itself is what's
        -- bad, no amount of just reloading it again ever escapes that.
        -- reroll_savestate_pool() now checks wScriptRunningAddr before
        -- saving (see there), which should prevent a bad baseline from
        -- being saved in the first place - but this is a second, cheap
        -- line of defense regardless of root cause: if the SAME baseline
        -- has failed to produce a normal reset 3 times in a row, stop
        -- reloading it and force a brand new one instead.
        if consecutiveStuckReloads >= 3 then
            print("check_stuck_and_force_reset(): the same baseline has failed 3 times in a row - forcing a fresh reroll instead of reloading it again.")
            reroll_savestate_pool()
            consecutiveStuckReloads = 0
        end
    end
end

-- Shared entropy design for every "instant/no-dialogue trigger" battle-
-- style target (Static (open world)/Sudowoodo/Lapras/Suicune) - built
-- out from what a real 3556-encounter Suicune log proved (see the big
-- writeup that used to live in Suicune's own branch below): a fixed
-- number of blind splits placed at fixed points can silently miss the
-- actual DV roll entirely - EnemyWildmonInitialized's ROM hook can fire
-- mid-frame-advance, i.e. DURING any of these calls, at whatever point
-- each target's own trigger script happens to reach it. Guessing where
-- that point falls relative to a fixed split layout produced a hard
-- ~128-of-65536-combo ceiling for Suicune that more splits did nothing
-- to raise, because splits fired after the (unknown, earlier-than-
-- assumed) roll point are provably wasted.
--
-- Instead of guessing, this dribbles small splits (current_dribble_range()
-- by default, or an explicit `range` override - see
-- INSTANT_TRIGGER_DRIBBLE_RANGE above for why Static (open world)/
-- Sudowoodo/Lapras now pass their own instead of sharing Suicune's tuned
-- value) one at a time and checks pendingEncounterUpdate (set by that same
-- hook) after every single one, stopping immediately once it flips true -
-- so every split that actually fires is verified to land before the roll,
-- never assumed to. stepFn (optional) is called once per iteration, up to
-- numSteps times, to actually interact with/trigger the encounter -
-- Suicune passes a single held Up-press repeated 8 times to walk into Tin
-- Tower; every other target here just needs one or a few "A" presses. cap
-- is a safety ceiling for the (should-never-happen) case the hook is
-- somehow missed entirely, so this can't hang forever.
local function dribble_entropy_until_hook(cap, numSteps, stepFn, range)
    cap = cap or 40
    numSteps = numSteps or 0
    range = range or current_dribble_range()
    local stepsTaken = 0
    for i = 1, cap do
        if pendingEncounterUpdate then break end
        RngEnabler.enable_randomness(range)
        mashSplitsFired = mashSplitsFired + 1
        if pendingEncounterUpdate then break end
        if stepFn and stepsTaken < numSteps then
            stepFn()
            stepsTaken = stepsTaken + 1
        end
    end
end

-- ===== M.step =====
function M.step()
    check_stuck_and_force_reset()

    -- Only safe to re-roll right at a clean reset boundary (standing in
    -- front of the NPC, nothing mid-flight) - firstPressPending being
    -- true is exactly that state, since it's only ever true immediately
    -- after a fresh savestate reload and before the first press of a
    -- new attempt.
    if firstPressPending and lastRerollTime and os.time() - lastRerollTime >= REROLL_INTERVAL_SECONDS then
        reroll_savestate_pool()
    end

    -- Feeds launcher.lua's Discord Rich Presence status line (see
    -- data/presence.lua) - cheap two-byte read, done every tick. Only
    -- updates when the (group, number) pair is a RECOGNIZED location -
    -- an unrecognized pair almost always means these two WRAM bytes got
    -- transiently repurposed for something else (e.g. a battle in
    -- progress), not an actual new location. See wild.lua's M.step()
    -- for the original fix this mirrors.
    do
        local mapKey = string.format("%d:%d", memory.readbyte(0xdcb5), memory.readbyte(0xdcb6))
        if LocationNames[mapKey] then
            AutocrystalCurrentLocation = LocationNames[mapKey]
        end
    end

    -- Gift Pokemon path: party size increased without any battle ever
    -- starting - read the new slot directly (same formula as
    -- gamecorner.lua/egg.lua/starters.lua, since this IS a party
    -- addition, not a wild-style battle).
    --
    -- "Static (open world)" is deliberately EXCLUDED from this whole path.
    -- Every target using it (Electrode's disguised Voltorb room, Lugia,
    -- etc.) is purely click-to-battle - it's never a dialogue gift-receive,
    -- so a real encounter for it should only ever be seen via the
    -- EnemyWildmonInitialized hook (pendingEncounterUpdate) below, never
    -- via a party-size increase. That matters because this path has NO
    -- species-match protection for "Static (open world)" (can't - there's
    -- no single fixed expected species to check against, unlike Eevee/
    -- Shuckle/Spearow just below) - it was relying entirely on the debounce
    -- and settle-frame checks to keep it honest. Those checks weren't
    -- enough: a user report of repeated stable "Slowbro A:0 D:0 S:15
    -- Sp:15" and "Unknown #255" readings survived TWO rounds of hardening
    -- the pendingEncounterUpdate path directly (a stability-confirm loop,
    -- then an enemy_hp_addr sanity check) with zero effect - meaning those
    -- readings were never coming from that hook at all. The likely real
    -- source: party_base_addr (and the memory right after it, where this
    -- path reads the "new" slot's species/DVs from) getting transiently
    -- repurposed as scratch space during an actual battle - the exact
    -- same class of WRAM reuse already confirmed and worked around for
    -- the Rich Presence location bytes above ("almost always means these
    -- two WRAM bytes got transiently repurposed for something else, e.g.
    -- a battle in progress"). A real Electrode/Lugia battle starting could
    -- transiently nudge party_base_addr's reused bytes past
    -- partysizeBeforeReceiving, and with no species filter to catch it for
    -- this target, whatever garbage sits at the computed slot offset -
    -- consistent garbage in this case, hence the identical DVs every time -
    -- sailed straight into Recent Encounters unfiltered. Skipping this
    -- entire path for "Static (open world)" removes that surface
    -- completely rather than trying to filter it after the fact. Suicune
    -- gets the same exclusion for the same reason - its battle also comes
    -- exclusively through the EnemyWildmonInitialized hook, never a party
    -- addition, and it's just as exposed to this class of false positive.
    local skipsGiftPath = StaticTargetDropdown and is_open_world_style_target(forms.gettext(StaticTargetDropdown))
    local currentPartySize = memory.readbyte(party_base_addr)
    if not skipsGiftPath and currentPartySize > partysizeBeforeReceiving then
        -- Debounce: a genuine gift-receive stays elevated; a one-frame
        -- transient/garbage read (the same class of bug the settle-frame
        -- fix and species cross-check were built to catch) doesn't.
        -- Uncapping the RNG-enabler splits (previous fix) means a LOT
        -- more total blind, zero-input frames now happen per reset on
        -- targets with long dialogue (Shuckle) - more blind frames means
        -- more chances to catch one of these transient reads, which is
        -- the likely cause of reset-spam coming back after that change.
        -- Confirming the elevated read survives one more frame catches
        -- these without weakening the real-detection path at all (costs
        -- one extra frame only on the rare tick this branch fires).
        emu.frameadvance()
        if memory.readbyte(party_base_addr) <= partysizeBeforeReceiving then
            return false
        end
        local newSlotIndex = partysizeBeforeReceiving
        local newSpeciesAddr = party_base_addr + 1 + newSlotIndex
        local newDvAddr = party_base_addr + 0x1D + newSlotIndex * 0x30

        -- The party-COUNT debounce above only confirms the slot exists -
        -- it says nothing about whether the new slot's OWN data (species,
        -- DVs) has actually finished being written yet. Verbose Logging
        -- finally caught this directly: the "bogus" reading below wasn't
        -- random garbage, it was the SAME wrong species (Nidoran-M) every
        -- single time - consistent with reading a template/placeholder
        -- value the game's own gift-give routine writes first, before a
        -- later step overwrites it with the real species and DVs, rather
        -- than a one-off transient. That also explains why it wasn't
        -- limited to the very first Start or to right after a reroll -
        -- this race exists on every single gift-receive, independent of
        -- anything on_resume()/reroll_savestate_pool() do. Same fix as
        -- those two: wait for species+DVs to read identically on two
        -- consecutive frames before trusting any of it.
        local newSpecies = memory.readbyte(newSpeciesAddr)
        local newAtkdef = memory.readbyte(newDvAddr)
        local newSpespc = memory.readbyte(newDvAddr + 1)
        do
            local stableFrames = 0
            local waited = 0
            while stableFrames < 2 and waited < 30 do
                emu.frameadvance()
                waited = waited + 1
                local curSpecies = memory.readbyte(newSpeciesAddr)
                local curAtkdef = memory.readbyte(newDvAddr)
                local curSpespc = memory.readbyte(newDvAddr + 1)
                if curSpecies == newSpecies and curAtkdef == newAtkdef and curSpespc == newSpespc then
                    stableFrames = stableFrames + 1
                else
                    newSpecies = curSpecies
                    newAtkdef = curAtkdef
                    newSpespc = curSpespc
                    stableFrames = 0
                end
            end
            if waited > 2 then
                print(string.format("Gift-receive slot data wasn't immediately stable, waited %d frames before trusting it (species settled on #%d) - if the reload-spam bug stops recurring, this was it.", waited, newSpecies))
            end
        end
        local speciesName = get_pokemon_name(newSpecies)

        -- Second line of defense on top of the settle-frame fix above:
        -- when the target dropdown names a specific species (Eevee,
        -- Shuckle, or Spearow - "Static (open world)" has no fixed
        -- expected species, so this is skipped for that option), a
        -- bogus/stale read never matches it. Confirmed via user testing
        -- that the settle buffer alone cut this from constant spam down
        -- to a rare stray hit (2 out of ~40 in one run) rather than zero -
        -- this catches those remaining stragglers by simply never
        -- counting or logging a result that doesn't match what we're
        -- actually hunting, and quietly retrying instead.
        local expectedName = StaticTargetDropdown and forms.gettext(StaticTargetDropdown)
        if (expectedName == "Eevee" or expectedName == "Shuckle" or expectedName == "Spearow") and speciesName ~= expectedName then
            vprint(string.format("Ignoring a bogus '%s' reading (expected %s) - reloading and retrying.", speciesName, expectedName))
            savestate.loadslot(SAVESTATE_SLOT)
            wait_for_reload_settle()
            mashSplitsFired = 0
            firstPressPending = true
            lastResetTime = os.time()
            consecutiveStuckReloads = 0
            return false
        end

        resetCount = resetCount + 1
        -- newAtkdef/newSpespc are already the stability-confirmed values
        -- from above - deliberately NOT re-read here, since that would
        -- throw away the whole point of confirming them.
        local atkv = math.floor(newAtkdef / 16)
        local defv = newAtkdef % 16
        local spdv = math.floor(newSpespc / 16)
        local spcv = newSpespc % 16
        local isShiny = shiny(newAtkdef, newSpespc)

        -- Splits count is logged here so we can actually see how many
        -- RNG-enabler injections fired before this DV roll happened -
        -- needed to tell whether split COUNT or split RANGE is the real
        -- lever, instead of guessing.
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Splits: %d", speciesName, newSpecies, atkv, defv, spdv, spcv, mashSplitsFired))

        Stats.record_encounter(newSpecies)
        Gui.update_last_encounter(hud, resetCount, newSpecies, speciesName, atkv, defv, spdv, spcv, isShiny, "(no item)")

        if isShiny then
            print(string.format("SHINY gift Pokemon found! %s Atk:%d Def:%d Spe:%d Spc:%d - stopping here",
                speciesName, atkv, defv, spdv, spcv))
            local encountersBeforeThisShiny = Stats.encountersSinceShiny
            Stats.record_shiny(newSpecies)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "SHINY found! Stopped.")
            local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)
            send_discord_embed(
                string.format("\xE2\x9C\xA8 Shiny Gift %s Found!", speciesName),
                nil,
                {
                    {name = "Dex #", value = string.format("#%03d", newSpecies), inline = true},
                    {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                    {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                    divider_field(),
                    {name = "Resets For This Shiny", value = tostring(encountersBeforeThisShiny), inline = true},
                    {name = "Resets Of This Species", value = tostring(Stats.species_encounter_count(newSpecies)), inline = true},
                    {name = "Shinies Of This Species", value = tostring(Stats.species_shiny_count(newSpecies)), inline = true},
                    divider_field(),
                    {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                    {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
                },
                COLOR_GOLD,
                shiny_sprite_url(newSpecies)
            )
            return true
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            savestate.loadslot(SAVESTATE_SLOT)
            -- A few real frames of buffer right after the reload, before
            -- ANYTHING re-reads memory. Confirmed via user testing this
            -- is needed even with partysizeBeforeReceiving no longer
            -- being re-read (see below) - the OTHER side of that same
            -- comparison, currentPartySize, is read fresh on every tick
            -- including the very next one right after this reload, and
            -- was catching memory before the reload had fully settled -
            -- egg.lua's proven mash loop always inserts exactly this
            -- many frames before its own next party-size check for the
            -- same reason.
            wait_for_reload_settle()
            mashSplitsFired = 0
            firstPressPending = true
            -- CRITICAL FIX: do NOT re-read partysizeBeforeReceiving here.
            -- A reload always rewinds to the EXACT same party state every
            -- time (confirmed by egg.lua's reference implementation,
            -- which reads this value exactly once, right after the
            -- initial save, and never again) - re-reading it immediately
            -- after loadslot() can catch memory before the reload has
            -- actually settled, occasionally producing a stale value.
            -- The very next tick's currentPartySize check would then
            -- compare against that stale number and fire a false
            -- "party increased" positive, reading garbage from whatever
            -- slot that stale index happened to point at (confirmed via
            -- a user report: constant fake "Abra Atk:0 Def:0 Spe:0
            -- Spc:0" spam, immediately, every single reset, without ever
            -- actually talking to the NPC).
            lastResetTime = os.time()
            consecutiveStuckReloads = 0
            return false
        end
    end

    if pendingEncounterUpdate then
        pendingEncounterUpdate = false

        -- "Static (open world)" gets a completely reordered flow now,
        -- based on real evidence from a Verbose Logging capture instead of
        -- another guess. That log showed the raw hook-time read was
        -- CORRECTLY "Electrode" with real varying DVs every single time -
        -- the bug wasn't a bad initial read. What broke it was the order
        -- of operations that followed: (1) the stability-confirm loop
        -- below immediately started polling species_addr again, right
        -- through the same volatile pre-menu window do_catch_sequence's
        -- own comment already warned about ("species_addr can still be
        -- oscillating for a while even right as have_battle_controls
        -- first becomes true") - and landed on garbage (Quilava, Mr. Mime,
        -- Unknown #0) instead of keeping the correct Electrode read; then
        -- (2) the have_battle_controls wait added last round never once
        -- pressed a button while waiting, so it just sat blocked on the
        -- "Wild ELECTRODE appeared!" text box (which needs input to
        -- advance, exactly like do_catch_sequence's own post-attack wait
        -- does with press_button("B")) until its own timeout - discarding
        -- genuine encounters 100% of the time, which is exactly what the
        -- log showed.
        --
        -- Fixed by matching do_catch_sequence's own proven order for this
        -- exact transition: confirm the battle menu has actually loaded
        -- FIRST (mashing B to clear any text in the way, same button
        -- do_catch_sequence uses here so it can't accidentally select a
        -- wrong menu option), THEN give species_addr/DVs the same settling
        -- window do_catch_sequence already relies on, THEN do a fresh read
        -- - only after both of those does the stability-confirm loop below
        -- even make sense to run. Applies to every OPEN_WORLD_STYLE_TARGETS
        -- member (Suicune included) - same hook, same volatile pre-menu
        -- window, same fix.
        if StaticTargetDropdown and is_open_world_style_target(forms.gettext(StaticTargetDropdown)) then
            -- Explicitly reset to false first: have_battle_controls is a
            -- Lua-side variable, NOT part of emulated console memory, so
            -- savestate.loadslot() never resets it - without this reset, a
            -- stale `true` left over from the last REAL battle's menu
            -- would make this check pass instantly and pointlessly.
            have_battle_controls = false
            local waited = 0
            while not have_battle_controls and waited < 300 do
                if stop_was_requested() then
                    print("Stop requested during battle-confirm wait - aborting.")
                    return true
                end
                press_button("B")
                waited = waited + 1
            end
            if not have_battle_controls then
                print(string.format(
                    "Ignoring a bogus '%s' battle-hook firing - the battle menu never actually loaded within %d attempts, so this was never a real battle. Reloading and retrying.",
                    get_pokemon_name(species), waited))
                savestate.loadslot(SAVESTATE_SLOT)
                wait_for_reload_settle()
                mashSplitsFired = 0
                firstPressPending = true
                lastResetTime = os.time()
                consecutiveStuckReloads = 0
                return false
            end

            -- Same settling window do_catch_sequence uses right after
            -- have_battle_controls first goes true, before this file
            -- trusts species_addr again.
            for i = 1, 60 do
                emu.frameadvance()
            end

            -- Fresh read - the hook-time snapshot is stale/irrelevant now
            -- that real frames (and real menu navigation) have passed.
            species = memory.readbyte(species_addr)
            atkdef = memory.readbyte(enemy_addr)
            spespc = memory.readbyte(enemy_addr + 1)
            item = memory.readbyte(item_addr)
        end

        -- Stability-confirm the battle-hook reading before trusting any of
        -- it - the exact same race already found and fixed for the Gift
        -- Pokemon path below (see the "Reload-spam bug, actual root cause
        -- found" section of rng_mechanics.md): the game can write a
        -- template/placeholder species+DV combo to the shared enemy-mon
        -- struct first, before a later step overwrites it with the real
        -- encounter's data - EnemyWildmonInitialized firing right in that
        -- window reads the placeholder, not the final value. That fix was
        -- only ever ported to the Gift Pokemon path (Eevee/Shuckle/
        -- Spearow) - never to this hook - which is exactly why "Static
        -- (open world)" (no expected-species guard to catch a WRONG but
        -- otherwise valid-looking species) could report a consistent bogus
        -- reading (a real user report: "Slowbro A:0 D:0 S:15 Sp:15"
        -- appearing repeatedly with IDENTICAL DVs, interleaved with
        -- genuine Electrode encounters that have varying DVs - the
        -- identical-every-time signature is the same tell that cracked
        -- the Nidoran-M case). Waiting for species/atkdef/spespc/item to
        -- read identically on two consecutive frames before trusting them
        -- catches the placeholder window the same way it already does for
        -- the Gift Pokemon path. For "Static (open world)" this now runs
        -- AFTER the battle-confirm block above, on the fresh post-settle
        -- read rather than the raw hook-time snapshot.
        do
            local stableFrames = 0
            local waited = 0
            local curSpecies, curAtkdef, curSpespc, curItem
            while stableFrames < 2 and waited < 30 do
                emu.frameadvance()
                waited = waited + 1
                curSpecies = memory.readbyte(species_addr)
                curAtkdef = memory.readbyte(enemy_addr)
                curSpespc = memory.readbyte(enemy_addr + 1)
                curItem = memory.readbyte(item_addr)
                if curSpecies == species and curAtkdef == atkdef and curSpespc == spespc and curItem == item then
                    stableFrames = stableFrames + 1
                else
                    species, atkdef, spespc, item = curSpecies, curAtkdef, curSpespc, curItem
                    stableFrames = 0
                end
            end
            if waited > 2 then
                print(string.format("Battle-hook reading wasn't immediately stable, waited %d frames before trusting it (settled on species #%d) - if a bogus reading recurs, this was it.", waited, species))
            end
            shiny(atkdef, spespc) -- re-derive shinyvalue from the settled bytes
        end

        -- Species-validation guard for battle-triggered targets with a
        -- known expected species (currently just Lapras - see
        -- BATTLE_TARGET_EXPECTED_SPECIES above for the full reasoning).
        -- Mirrors the Gift Pokemon path's existing bogus-reading
        -- protection below. Checked BEFORE incrementing resetCount/
        -- recording stats, so a discarded stray encounter never pollutes
        -- either.
        --
        -- "Static (open world)" gets its own generic version of this same
        -- check instead of a fixed expected-species match, since it's
        -- meant to work for whatever click-to-encounter target the
        -- player is standing in front of (Lugia, Electrode's disguised
        -- Voltorb room, etc.) without needing a hardcoded species per
        -- target. wait_for_reload_settle() zeroes species_addr after
        -- every reload specifically for this target, so any reading here
        -- that's still 0 (never actually rewritten by the game) or 255
        -- (Unknown - the classic "uninitialized" placeholder) is provably
        -- not a genuine fresh encounter and gets discarded the same way.
        do
            local selectedTarget = StaticTargetDropdown and forms.gettext(StaticTargetDropdown)
            local expectedBattleSpecies = selectedTarget and BATTLE_TARGET_EXPECTED_SPECIES[selectedTarget]

            -- The stability-confirm loop above only proves species/DVs
            -- weren't caught MID-WRITE - it says nothing about whether
            -- this is a genuine fresh battle at all. User testing showed
            -- it wasn't: a "Slowbro A:0 D:0 S:15 Sp:15" reading survived
            -- it completely unchanged (perfectly stable, not in flux),
            -- appearing repeatedly, meaning it isn't a torn read - the
            -- hook is firing on something that genuinely isn't the
            -- expected static encounter. species_addr==0/255 alone can't
            -- catch this since Slowbro is a valid, non-placeholder ID.
            --
            -- enemy_hp_addr/enemy_max_hp_addr gives an independent, more
            -- direct signal (same idiom already used in wild.lua's
            -- do_catch_attack_turn(): "species_addr alone proved
            -- unreliable ... enemy_hp_addr reading 0 is a more direct
            -- signal"): a genuinely fresh wild/static mon always has its
            -- HP fields computed and populated (nonzero, current==max) by
            -- the time EnemyWildmonInitialized fires, since HP is derived
            -- from species+level+DVs in the same load routine. If either
            -- reads 0 here, whatever wrote species_addr did NOT come from
            -- a real fresh encounter init, regardless of how stable or
            -- valid-looking the species byte itself is.
            local curHP = memory.read_u16_be(enemy_hp_addr)
            local maxHP = memory.read_u16_be(enemy_max_hp_addr)

            -- Third round on this bug: excluding "Static (open world)" from
            -- the Gift Pokemon path (see above) didn't fix it either - the
            -- next user report showed "Ivysaur A:0 D:2 S:0 Sp:2 [Ultra
            -- Ball]" repeating, and critically this time it carried a real
            -- HELD ITEM reading, which only the battle-hook path ever
            -- populates (the Gift path always hardcodes "(no item)") - so
            -- this IS coming through EnemyWildmonInitialized/
            -- pendingEncounterUpdate, confirming the hook itself is firing
            -- too early, before wEnemyMon has actually been loaded with the
            -- real wild data. A wild Electrode holding an Ultra Ball is
            -- nonsensical - wild Pokemon never hold Poke Balls - which
            -- points directly at what's actually still sitting at
            -- enemy_addr/species_addr/item_addr at that moment: the
            -- player's OWN lead party Pokemon's data, not the enemy's. Gen
            -- II's wEnemyMon and wPartyMon1 structs are populated by
            -- shared/adjacent battle-init code, and early in that sequence
            -- (before the real wild species gets written) it's plausible
            -- for whatever was last resident there - the player's own
            -- active Pokemon, copied in for a turn-order/stat comparison -
            -- to still be readable. Directly testable without guessing:
            -- compare the settled reading against every current party
            -- slot's own species+DVs. A wild encounter coincidentally
            -- matching one of the player's own party members on all four
            -- DVs by chance is a ~1-in-65536 fluke - any match is for all
            -- practical purposes proof this is leaked player data, not a
            -- real enemy.
            local isPlayerPartyLeak = false
            if is_open_world_style_target(selectedTarget) then
                local liveParty = memory.readbyte(party_base_addr)
                for i = 0, math.min(liveParty, 6) - 1 do
                    local slotSpecies = memory.readbyte(party_base_addr + 1 + i)
                    local slotDvAddr = party_base_addr + 0x1D + i * 0x30
                    local slotAtkdef = memory.readbyte(slotDvAddr)
                    local slotSpespc = memory.readbyte(slotDvAddr + 1)
                    if slotSpecies == species and slotAtkdef == atkdef and slotSpespc == spespc then
                        isPlayerPartyLeak = true
                        break
                    end
                end
            end

            local isBogusOpenWorldReading = is_open_world_style_target(selectedTarget)
                and (species == 0 or species == 255 or curHP == 0 or maxHP == 0 or isPlayerPartyLeak)
            if (expectedBattleSpecies and get_pokemon_name(species) ~= expectedBattleSpecies) or isBogusOpenWorldReading then
                -- Unconditional (not vprint-gated) specifically for this
                -- guard while the Slowbro report is still being chased -
                -- the previous fix attempt (stability-confirm alone) LOOKED
                -- plausible but didn't hold up under actual testing, so
                -- this print exists to give real data if it recurs again
                -- rather than another blind guess: player location plus
                -- every raw field read at the moment of discard.
                print(string.format(
                    "Ignoring a bogus '%s' battle reading%s (HP %d/%d, item %s, map %d:%d%s) - reloading and retrying.",
                    get_pokemon_name(species), expectedBattleSpecies and (" (expected " .. expectedBattleSpecies .. ")") or "",
                    curHP, maxHP, get_item_name(item),
                    memory.readbyte(0xdcb5), memory.readbyte(0xdcb6),
                    isPlayerPartyLeak and ", matches a current party slot - leaked player data" or ""))
                savestate.loadslot(SAVESTATE_SLOT)
                wait_for_reload_settle()
                mashSplitsFired = 0
                firstPressPending = true
                lastResetTime = os.time()
                consecutiveStuckReloads = 0
                return false
            end
        end

        resetCount = resetCount + 1

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local atkv = math.floor(atkdef / 16)
        local defv = atkdef % 16
        local spdv = math.floor(spespc / 16)
        local spcv = spespc % 16
        local isShiny = (shinyvalue == 1)

        Stats.record_encounter(species)
        Gui.update_last_encounter(hud, resetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, itemName)

        if isShiny then
            print(string.format("SHINY static encounter found! %s Atk:%d Def:%d Spe:%d Spc:%d",
                speciesName, atkv, defv, spdv, spcv))
            local encountersBeforeThisShiny = Stats.encountersSinceShiny
            Stats.record_shiny(species)
            local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)
            local shinyEmbedFields = {
                {name = "Dex #", value = string.format("#%03d", species), inline = true},
                {name = "DVs (Atk/Def/Spe/Spc)", value = string.format("%d/%d/%d/%d", atkv, defv, spdv, spcv), inline = true},
                {name = "Hidden Power", value = string.format("%s (%d)", hpType, hpPower), inline = true},
                {name = "Held Item", value = itemName, inline = true},
                divider_field(),
                {name = "Resets For This Shiny", value = tostring(encountersBeforeThisShiny), inline = true},
                {name = "Resets Of This Species", value = tostring(Stats.species_encounter_count(species)), inline = true},
                {name = "Shinies Of This Species", value = tostring(Stats.species_shiny_count(species)), inline = true},
                divider_field(),
                {name = "Total Shinies", value = tostring(Stats.totalShinies), inline = true},
                {name = "Total Encounters", value = tostring(Stats.totalEncounters), inline = true},
            }
            local shinySpriteUrl = shiny_sprite_url(species)
            local function send_shiny_found_embed()
                send_discord_embed(string.format("\xE2\x9C\xA8 Shiny %s Found!", speciesName),
                    nil, shinyEmbedFields, COLOR_GOLD, shinySpriteUrl)
            end
            -- Reload back to the reset point and resume hunting - shared
            -- by every "the shiny is gone/skipped, keep going" outcome
            -- below (never called after a genuine catch, which must be
            -- preserved rather than rewound).
            local function reload_and_keep_hunting()
                savestate.loadslot(SAVESTATE_SLOT)
                wait_for_reload_settle()
                mashSplitsFired = 0
                firstPressPending = true
                lastResetTime = os.time()
                consecutiveStuckReloads = 0
            end

            if Gui.auto_catch_enabled(hud) then
                local exceptionEnabled, exceptionFilterTokens = Gui.auto_catch_stop_exception(hud)
                if exceptionEnabled and species_matches_filter(exceptionFilterTokens, species, speciesName) then
                    -- On the "don't auto-catch, stop instead" exception
                    -- list - reserve this one for manual catching.
                    print(string.format("Shiny %s found - on the auto-catch exception list, stopping for manual catching.", speciesName))
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "SHINY found! Stopped - handle the battle yourself from here.")
                    send_shiny_found_embed()
                    return true
                end

                if Gui.skip_already_caught_enabled(hud) and Stats.is_already_caught(species) then
                    -- Living dex mode - already have one of this species,
                    -- skip catching another and keep hunting instead.
                    print(string.format("Shiny %s found, but already caught before (living dex mode) - skipping, continuing the hunt.", speciesName))
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "Shiny already caught before (living dex mode) - resetting...")
                    send_shiny_found_embed()
                    reload_and_keep_hunting()
                    return false
                end

                local catchFilterTokens = Gui.catch_species_filter(hud)
                local catchAllowedBySpecies = species_matches_filter(catchFilterTokens, species, speciesName)
                local itemCatchEnabled, itemCatchFilterTokens = Gui.catch_on_item(hud)
                local catchAllowedByItem = itemCatchEnabled and item ~= 0
                    and species_matches_filter(itemCatchFilterTokens, item, itemName)

                if catchAllowedBySpecies or catchAllowedByItem then
                    local outcome = do_catch_sequence(true, shinyEmbedFields, shinySpriteUrl)
                    if outcome == "caught" then
                        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                            "SHINY caught via auto-catch! Stopped.")
                        return true
                    elseif outcome == "continue" then
                        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                            "Shiny lost during the catch attempt - resetting...")
                        reload_and_keep_hunting()
                        return false
                    else -- "stop"
                        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                            "SHINY found! Auto-catch stopped - handle the battle yourself from here.")
                        return true
                    end
                else
                    print(string.format("Shiny %s found, but doesn't match the auto-catch filter - stopping for manual catching.", speciesName))
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "SHINY found! Stopped - handle the battle yourself from here.")
                    send_shiny_found_embed()
                    return true
                end
            else
                print("Shiny found!! Stopping here - handle the battle yourself from here.")
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                    "SHINY found! Stopped - handle the battle yourself from here.")
                send_shiny_found_embed()
                return true
            end
        else
            -- Independent of shininess, same as wild.lua: "Auto-catch on
            -- held item" catches ANY Pokemon holding a matching item, and
            -- "Auto-catch on Perfect/Perfect Negative DVs" catches a
            -- genuine 15/15/15/15 or 0/0/0/0 roll - neither requires the
            -- encounter to be shiny.
            local itemCatchEnabled, itemCatchFilterTokens = Gui.catch_on_item(hud)
            local catchAllowedByItem = Gui.auto_catch_enabled(hud) and itemCatchEnabled and item ~= 0
                and species_matches_filter(itemCatchFilterTokens, item, itemName)
            local isPerfectDVs = (atkv == 15 and defv == 15 and spdv == 15 and spcv == 15)
            local isPerfectNegativeDVs = (atkv == 0 and defv == 0 and spdv == 0 and spcv == 0)
            local catchAllowedByPerfect = Gui.auto_catch_enabled(hud)
                and ((isPerfectDVs and Gui.catch_on_perfect(hud))
                    or (isPerfectNegativeDVs and Gui.catch_on_perfect_negative(hud)))

            if catchAllowedByItem or catchAllowedByPerfect then
                if catchAllowedByItem then
                    print(string.format("%s found holding %s - auto-catching (item match, not shiny).", speciesName, itemName))
                else
                    local perfectLabel = isPerfectDVs and "Perfect DVs (15/15/15/15)" or "Perfect Negative DVs (0/0/0/0)"
                    print(string.format("%s found with %s - auto-catching.", speciesName, perfectLabel))
                end
                local outcome = do_catch_sequence(false)
                if outcome == "caught" then
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "Caught via auto-catch! Stopped.")
                    return true
                elseif outcome == "continue" then
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "Auto-catch attempt failed - resetting...")
                    savestate.loadslot(SAVESTATE_SLOT)
                    wait_for_reload_settle()
                    mashSplitsFired = 0
                    firstPressPending = true
                    lastResetTime = os.time()
                    consecutiveStuckReloads = 0
                    return false
                else -- "stop"
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                        "Auto-catch stopped - handle the battle yourself from here.")
                    return true
                end
            end

            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            savestate.loadslot(SAVESTATE_SLOT)
            -- Same settle buffer as the other two loadslot() sites above.
            wait_for_reload_settle()
            mashSplitsFired = 0
            firstPressPending = true
            lastResetTime = os.time()
            consecutiveStuckReloads = 0
            return false
        end
    end

    -- Not yet in battle - keep mashing A to interact with/re-trigger the
    -- static encounter, injecting a fresh split delay on every mash tick
    -- (uncapped, no longer a fixed 8) so entropy keeps building all the
    -- way up to whichever tick the DV roll actually lands on.
    --
    -- CRITICAL: never run the RNG-enabler split before the FIRST press.
    -- enable_randomness() blocks and advances the emulator forward a
    -- RANDOM number of frames (up to 256 for the normal split, or up to
    -- ~70000 with True Randomness) with ZERO button input each time it's
    -- called. Doing that while still sitting in the "haven't talked to
    -- the NPC yet" state - which every single reset cycle starts in,
    -- since the savestate reload lands right back there - leaves a large
    -- blind window where the game runs on its own with nothing stopping
    -- unrelated background events from firing and getting misread as a
    -- real encounter (confirmed by a user report: false "Abra" entries
    -- with all-zero DVs interleaved with real Shuckle/Eevee attempts,
    -- worse at high emulation speed simply because more reset cycles -
    -- and therefore more of these blind windows - happen per minute of
    -- observation). Splits are safe to inject AFTER the conversation is
    -- confirmed open (once firstPressPending is false) since by then
    -- we're just advancing through known dialogue, not sitting in an
    -- ambiguous pre-interaction state.
    -- "Instant/no-dialogue trigger" battle-style targets (Static (open
    -- world)/Sudowoodo/Suicune/Lapras) are ALL deliberately EXCLUDED from
    -- this generic per-tick branch and handled by dribble_entropy_until_
    -- hook() in their own elseif arms below instead. Reasoning proven out
    -- on Suicune first (a real 3556-encounter log): once firstPressPending
    -- goes false for one of these, the DV roll has either already
    -- happened (EnemyWildmonInitialized's hook can fire mid-frame-
    -- advance, i.e. during whatever trigger action was just taken) or is
    -- about to, via that target's own fixed/automatic script timing -
    -- injecting more BLIND splits here (this branch) provably doesn't
    -- raise coverage at all once that's true, it just burns real time and
    -- produces misleadingly large "Splits" counts that don't correspond
    -- to any actual entropy gain. Every OTHER target using this function
    -- (Celebi, Shuckle/Eevee/Spearow's multi-page dialogue) keeps this
    -- generic per-tick single split unchanged - they have real
    -- intervening dialogue ticks before their outcome is ever decided
    -- (Eevee/Shuckle/Spearow via the Gift path's party-size gate, Celebi
    -- via its own shrine-cutscene mash phase before the battle half even
    -- starts), so each split fired here for them is ALREADY naturally
    -- gated the same way dribble_entropy_until_hook() gates its own
    -- splits - just one iteration per M.step() tick instead of a tight
    -- inline loop - no separate fix needed.
    local isDribbleTarget = StaticTargetDropdown and is_open_world_style_target(forms.gettext(StaticTargetDropdown))
    local isLapras = StaticTargetDropdown and forms.gettext(StaticTargetDropdown) == "Lapras"
    if not firstPressPending and not isDribbleTarget and not isLapras then
        -- Gui.true_randomness_enabled() is deliberately NOT read here
        -- anymore - see the comment by mashSplitsFired's declaration above
        -- for why reroll_savestate_pool() supersedes it for this module.
        RngEnabler.enable_randomness(STATIC_SPLIT_RANGE)
        mashSplitsFired = mashSplitsFired + 1
    elseif not firstPressPending and (isDribbleTarget or isLapras) then
        -- Nothing to do here (see above) - just let the automatic script
        -- play out. Explicitly a no-op branch rather than falling through
        -- to press "A" below, since an unwanted extra A-press mid-script
        -- could only ever risk interrupting a scripted movement for no
        -- benefit.
        return false
    elseif StaticTargetDropdown and forms.gettext(StaticTargetDropdown) == "Static (open world)" then
        -- v1 of this branch (found via a 43,984-encounter Electrode log)
        -- used a blind two-split design: one STATIC_SPLIT_RANGE injection
        -- before the trigger press, one after, assuming close-to-
        -- multiplicative 256*256 coverage. That assumption was never
        -- actually verified for Electrode's own numbers past "seems to
        -- have worked" - and the identical assumption, applied to
        -- Suicune's trigger, was later PROVEN wrong by a 3556-encounter
        -- log (unique combos plateaued at ~128 no matter how many splits
        -- fired, because the second split - and everything after it -
        -- fires after the EnemyWildmonInitialized hook, i.e. after the
        -- roll, for a trigger this fast). Upgraded to the verified
        -- dribble design instead of keeping an unverified assumption.
        --
        -- numSteps=1 is correct here (not under-provisioned the way
        -- Sudowoodo was - see that branch below): confirmed against the
        -- disassembly (TeamRocketBaseB2F.asm's RocketElectrode scripts,
        -- and every other click-to-encounter object this target covers)
        -- that there's no dialogue/faceplayer at all - a single trigger
        -- press goes straight to loadwildmon/startbattle, so there's no
        -- second real button-advance point to give it credit for. A real
        -- 8038-encounter Electrode log (K~512, avg 1.24 splits/attempt)
        -- confirms this is a stable, working ceiling for this target's
        -- actual script shape, not a bug - see Sudowoodo's branch for
        -- what an ACTUAL under-provisioned target looks like by
        -- comparison. Passes INSTANT_TRIGGER_DRIBBLE_RANGE explicitly
        -- now instead of falling back to current_dribble_range() - see
        -- that constant's declaration for why this target group is
        -- tuned independently from Suicune's 1024.
        dribble_entropy_until_hook(40, 1, function() press_button("A", current_hold_frames()) end, INSTANT_TRIGGER_DRIBBLE_RANGE)
        firstPressPending = false
        return false
    elseif StaticTargetDropdown and forms.gettext(StaticTargetDropdown) == "Sudowoodo" then
        -- Sudowoodo was originally grouped with "Static (open world)"
        -- above on the (wrong) assumption that it has the same
        -- instant/no-dialogue shape - it doesn't. Confirmed against the
        -- actual disassembly (maps/Route36.asm, SudowoodoScript/
        -- WateredWeirdTreeScript): using the Squirtbottle on the fake
        -- tree goes through a real "Use SQUIRTBOTTLE?" yesorno confirm,
        -- THEN a "Used the SQUIRTBOTTLE." waitbutton text box, THEN a
        -- playsound/applymovement tree-shake animation (real frames, no
        -- button needed), THEN a second "...SQUIRTBOTTLE attacked!"
        -- waitbutton text box - only after all of that does
        -- loadwildmon/startbattle actually fire. That's 3 genuine
        -- button-advance points, not 1.
        --
        -- With the old numSteps=1, only the FIRST prompt ever got
        -- pressed - stepsTaken reached numSteps immediately, so the
        -- dribble loop's later iterations kept firing blind splits (up
        -- to the 40-iteration cap, each blocking for real random frames)
        -- against a textbox that was never going anywhere, then gave up
        -- and started returning a pure no-op every tick after
        -- (isDribbleTarget's "let the automatic script play out" branch
        -- above) - except the script was NOT automatic past that point,
        -- it was still waiting on the SECOND text box's waitbutton. That
        -- almost certainly meant every single Sudowoodo attempt sat
        -- stalled until check_stuck_and_force_reset()'s watchdog
        -- eventually forced a reset - a real functional stall, not just
        -- a missed-entropy inefficiency. numSteps=3 (one per real
        -- button-advance point in the script above) both closes that
        -- stall and gives this target the same kind of real per-step
        -- entropy runway Suicune's walk-in and the dialogue-driven
        -- targets (Eevee/Shuckle/Spearow/Celebi) already get. Deliberately
        -- keeps the shared current_dribble_range() (1024), NOT
        -- INSTANT_TRIGGER_DRIBBLE_RANGE - explicit user call: Sudowoodo's
        -- own 3 real button-advance points above already give it more
        -- entropy runway than "Static (open world)" gets, so it doesn't
        -- need the wider range too.
        --
        -- UPDATE - real user report of a stall on the very first textbox
        -- even with the numSteps=3 fix above and a dedicated hold length
        -- (SUDOWOODO_HOLD_FRAMES): fixed step counts kept needing bumps
        -- that then turned out wrong again. Switched to mashing every
        -- iteration (DIALOGUE_MASH_CAP - see its declaration above) so
        -- there's no step count left to guess at all - the loop still
        -- bails out immediately the instant pendingEncounterUpdate fires,
        -- same as before.
        dribble_entropy_until_hook(DIALOGUE_MASH_CAP, DIALOGUE_MASH_CAP, function() press_button("A", current_hold_frames()) end)
        firstPressPending = false
        return false
    elseif StaticTargetDropdown and forms.gettext(StaticTargetDropdown) == "Snorlax" then
        -- Same DIALOGUE_MASH_CAP approach as Sudowoodo above - mashes
        -- every iteration instead of a guessed, repeatedly-wrong fixed
        -- step count. See DIALOGUE_MASH_CAP's declaration for the full
        -- reasoning.
        dribble_entropy_until_hook(DIALOGUE_MASH_CAP, DIALOGUE_MASH_CAP, function() press_button("A", current_hold_frames()) end)
        firstPressPending = false
        return false
    elseif StaticTargetDropdown and forms.gettext(StaticTargetDropdown) == "Suicune" then
        -- Suicune's savestate starts OUTSIDE Tin Tower entirely (the
        -- courtyard below its door, on EcruteakTinTowerEntrance - see the
        -- big Suicune comment block above for the full disassembly-backed
        -- explanation). An A-press does nothing useful from here - no NPC,
        -- no dialogue - the player has to actually WALK through the door
        -- and onto TinTower1F before TinTower1FSuicuneBattleScript's
        -- scene_script can trigger at all, hence the dedicated walk-in
        -- stepFn instead of a single A-press. Mashes every iteration
        -- (DIALOGUE_MASH_CAP) instead of a fixed guessed step count -
        -- see the walk-in comment block above for why.
        dribble_entropy_until_hook(DIALOGUE_MASH_CAP, DIALOGUE_MASH_CAP, function() press_button("Up", SUICUNE_WALK_HOLD_FRAMES) end)
        firstPressPending = false
        return false
    elseif StaticTargetDropdown and BATTLE_TARGET_EXPECTED_SPECIES[forms.gettext(StaticTargetDropdown)] then
        -- Deliberate, narrow exception to the "never before the first
        -- press" rule above - see BATTLE_TARGET_EXPECTED_SPECIES's
        -- declaration for the full reasoning. Targets listed here (only
        -- Lapras today) have no dialogue at all, so the battle starts
        -- from this exact first press and normal splitting (which only
        -- ever starts on the SECOND press) never gets a chance to fire -
        -- every reset was silently 100% deterministic. Safe here
        -- specifically because the species-validation guard in
        -- pendingEncounterUpdate above discards and retries anything
        -- that isn't genuinely the expected species, so a stray
        -- encounter firing during this blind window can no longer get
        -- misread as real data the way the rule above exists to prevent.
        --
        -- Previously a single blind split, "unchanged since it was never
        -- reported broken" - but Lapras has its OWN documented history of
        -- exactly this class of bug (see the comment above
        -- BATTLE_TARGET_EXPECTED_SPECIES: a real 39,402-encounter log
        -- showed 55% of resets sitting inside just 5 repeating DV blocks)
        -- and that single-split fix was never actually re-verified with a
        -- follow-up log the way Suicune's now has been. Upgraded to the
        -- same verified dribble design on an audit pass rather than
        -- waiting for a second bug report to prove it's still broken.
        -- Deliberately keeps the shared current_dribble_range() (1024),
        -- NOT INSTANT_TRIGGER_DRIBBLE_RANGE - explicit user call: Lapras
        -- is reliably encountering fine as-is, unlike "Static (open
        -- world)", so it doesn't need the wider range either.
        dribble_entropy_until_hook(40, 1, function() press_button("A", current_hold_frames()) end)
        firstPressPending = false
        return false
    end
    -- Back to exactly one press per step (the original, proven-safe
    -- timing) - see press_button() above for why "Shuckle" gets a
    -- longer HOLD instead of more frequent presses.
    press_button("A", current_hold_frames())
    firstPressPending = false
    return false
end

return M

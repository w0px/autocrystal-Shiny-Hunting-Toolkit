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

local SAVESTATE_SLOT = 5 -- separate from Starters' slot 3 and Egg's slot 4

-- Tracks whether SAVESTATE_SLOT has EVER actually been saved to yet this
-- BizHawk session - see the "cold slot" warm-up in M.on_resume() below.
local savestateSlotWarmedUp = false

local enemy_addr, species_addr, item_addr
local party_base_addr
local partysizeBeforeReceiving
local LoadBattleMenuAddr, EnemyWildmonInitialized
local version, region

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

-- Hooks get REPLACED by name every time RegisterROMHook runs - must be
-- called every time this module becomes active, not just once. See
-- wild.lua for the original confirmation of this behavior.
local function register_hooks()
    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "static" then return end
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

        pendingEncounterUpdate = true
    end, "Static Encounter Battle Started")
end

-- ===== M.init: runs ONCE =====
-- Stop-on-item, stop-on-shiny, every Auto-Catch field, and crit-safety
-- override are also greyed out - static.lua never reads any of those
-- Gui getters (no held-item/auto-catch/weaken flow here). True Randomness
-- IS in this list (unlike Starters/Egg, which still read and honor it
-- normally) - static.lua no longer calls Gui.true_randomness_enabled() at
-- all, since reroll_savestate_pool()'s periodic full-coverage injection
-- supersedes it for this module (see the comment by mashSplitsFired's
-- declaration). Greyed out here so it's visually obvious it has no effect
-- while Static is the active module, instead of silently doing nothing.
-- Verbose Logging stays checkable.
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
    -- See egg.lua/wild.lua for why this is wrapped in pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 or region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
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
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            -- STILL UNVERIFIED - same enemy_addr=party_base_addr bug
            -- pattern, no JP-specific symbol data available.
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            -- STILL UNVERIFIED - same caveat as the JP branch above.
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7400)
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
local function reroll_savestate_pool()
    print(string.format(
        "Re-rolling savestate pool after %d minutes - injecting fresh entropy and re-baselining to avoid getting permanently stuck if this pool excludes the shiny states.",
        math.floor(REROLL_INTERVAL_SECONDS / 60)))
    RngEnabler.enable_randomness(RngEnabler.FULL_COVERAGE_RANGE)

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
        print(string.format("WARNING: no reset for %d+ seconds (stuck check #%d) - likely stuck (phone call, etc). Forcing a reload.",
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
    local currentPartySize = memory.readbyte(party_base_addr)
    if currentPartySize > partysizeBeforeReceiving then
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
            print(string.format("SHINY static encounter found! %s Atk:%d Def:%d Spe:%d Spc:%d - stopping here",
                speciesName, atkv, defv, spdv, spcv))
            local encountersBeforeThisShiny = Stats.encountersSinceShiny
            Stats.record_shiny(species)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "SHINY found! Stopped - handle the battle yourself from here.")
            local hpType, hpPower = hidden_power(atkv, defv, spdv, spcv)
            send_discord_embed(
                string.format("\xE2\x9C\xA8 Shiny %s Found!", speciesName),
                nil,
                {
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
                },
                COLOR_GOLD,
                shiny_sprite_url(species)
            )
            return true
        else
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
    if not firstPressPending then
        -- Gui.true_randomness_enabled() is deliberately NOT read here
        -- anymore - see the comment by mashSplitsFired's declaration above
        -- for why reroll_savestate_pool() supersedes it for this module.
        RngEnabler.enable_randomness(STATIC_SPLIT_RANGE)
        mashSplitsFired = mashSplitsFired + 1
    end
    -- Back to exactly one press per step (the original, proven-safe
    -- timing) - see press_button() above for why "Shuckle" gets a
    -- longer HOLD instead of more frequent presses.
    press_button("A", current_hold_frames())
    firstPressPending = false
    return false
end

return M

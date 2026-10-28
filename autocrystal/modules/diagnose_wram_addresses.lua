-- diagnose_wram_addresses.lua
--
-- Companion to diagnose_rom_addresses.lua. That script finds ROM CODE
-- addresses (the ones AutoCrystal hooks into) by scanning the ROM file
-- for byte patterns. This one covers everything else AutoCrystal reads
-- or writes: WRAM (working RAM) addresses - the DV bytes, species,
-- item, party count, menu cursor, movement flag, player position, and
-- so on.
--
-- WRAM CAN'T BE SCANNED THE WAY ROM CODE CAN: it doesn't exist in the
-- ROM file at all, it's only populated once the game is actually
-- running, and its contents constantly change. There's no fixed byte
-- pattern to search for. The only way to check whether AutoCrystal's
-- WRAM addresses are correct on a given ROM (e.g. a localized build) is
-- to read them live and have a human confirm the values make sense for
-- whatever's actually happening on screen at that moment - which is
-- what this script does.
--
-- Also worth knowing: unlike the ROM hook addresses (which shift in
-- localized builds because translated text takes different space),
-- WRAM layout is generally expected to stay the same across language
-- versions of the same game, since translation mostly touches ROM
-- text/code, not how variables are laid out in RAM. So these are a
-- lower-risk category overall - but "generally expected" isn't
-- "verified", and at least one of them (party_base_addr) already had
-- the exact same untested "assume every EU language matches English"
-- gap the ROM hooks did, so it's worth actually checking rather than
-- assuming.
--
-- HOW TO USE - run this TWICE, in two different situations, so every
-- address below gets read in the state where it's actually meaningful:
--
--   RUN 1: standing still on the overworld, not in any menu, dialogue,
--          or battle.
--   RUN 2: mid-battle against your static target, right after the
--          battle menu (FIGHT/PACK/POKEMON/RUN) appears on screen.
--
-- Each run: get into position, then open this script via the Lua
-- Console (File > Open Script). It reads once and prints immediately -
-- no need to leave it running. Results also get written to
-- wram_address_scan_results.txt next to this script (each run
-- OVERWRITES that file, so if you're including both runs in a bug
-- report, copy the console output or rename the file between runs).
--
-- This never reads or transmits your ROM anywhere - everything happens
-- locally in your own BizHawk session.

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"

-- English-verified addresses (Crystal, version 0x54, region-0x45/merged
-- EU branch) - what AutoCrystal currently assumes for every non-
-- Japanese, non-Korean Crystal ROM. `context` says which run
-- (overworld / battle / either) the value is actually meaningful in;
-- `wide` means it's read as a 16-bit big-endian value (HP fields),
-- everything else is a single byte.
local ADDRESSES = {
    -- Overworld / general state
    { name = "PLAYER_X_ADDR",      addr = 0xDCB8, context = "overworld",
      note = "player's X map coordinate - should roughly match where you're standing" },
    { name = "PLAYER_Y_ADDR",      addr = 0xDCB7, context = "overworld",
      note = "player's Y map coordinate - should roughly match where you're standing" },
    { name = "MOVEMENT_FLAG_ADDR", addr = 0xD4DD, context = "overworld",
      note = "0xFF (255) when standing still/idle, something else while actually moving" },
    { name = "wScriptRunningAddr", addr = 0xD438, context = "overworld",
      note = "0 when idle (no dialogue/cutscene/script active)" },

    -- Player's own party
    { name = "party_base_addr",    addr = 0xDCD7, context = "either",
      note = "first byte read AS your party count - should exactly equal how many Pokemon you actually have" },
    { name = "curPartyMonAddr",    addr = 0xD0D4, context = "battle",
      note = "index of your active battler within your party (0 = first slot)" },

    -- Battle UI / menu (only meaningful once a battle menu is open)
    { name = "MENU_CURSOR_Y",      addr = 0xCFA9, context = "battle",
      note = "battle menu cursor row - changes as you move the cursor" },
    { name = "MENU_CURSOR_X",      addr = 0xCFAA, context = "battle",
      note = "battle menu cursor column - changes as you move the cursor" },
    { name = "FIRST_MOVE_PP_ADDR", addr = 0xC634, context = "battle",
      note = "PP of your active Pokemon's first move - should be a small sane number, not 0/garbage" },
    { name = "OWN_HP_ADDR",        addr = 0xC63C, context = "battle", wide = true,
      note = "your active Pokemon's current HP - should match what's shown on its HP bar" },
    { name = "OWN_MAX_HP_ADDR",    addr = 0xC63E, context = "battle", wide = true,
      note = "your active Pokemon's max HP - should match its actual max HP" },

    -- The enemy/static target - only meaningful mid-battle
    { name = "enemy_addr (DVs)",   addr = 0xD20C, context = "battle",
      note = "start of the enemy's DV bytes - the whole reason this bot exists, this one matters most" },
    { name = "species_addr",       addr = 0xD22E, context = "battle",
      note = "enemy species ID - should match whatever Pokemon you're actually fighting (e.g. Snorlax = 143)" },
    { name = "item_addr",          addr = 0xD207, context = "battle",
      note = "enemy's held item ID - usually 0 (none) for most statics" },
    { name = "enemy_hp_addr",      addr = 0xD216, context = "battle", wide = true,
      note = "enemy's current HP - should match its HP bar" },
    { name = "enemy_max_hp_addr",  addr = 0xD218, context = "battle", wide = true,
      note = "enemy's max HP - should match its actual max HP" },

    -- Item/Poke Ball inventory (used by the catch sequence)
    { name = "wCurItemAddr",       addr = 0xD106, context = "either",
      note = "item currently selected in the pack, if a pack menu is open - 0/irrelevant otherwise" },
    { name = "wItemsAddr",         addr = 0xD893, context = "either",
      note = "start of your item pocket list - first byte should be a real, valid item ID if you carry any items" },
    { name = "wNumItemsAddr",      addr = 0xD892, context = "either",
      note = "how many distinct item slots are filled in your item pocket" },
    { name = "wBallsAddr",         addr = 0xD8D8, context = "either",
      note = "start of your Ball pocket list - first byte should be a real Ball item ID" },
    { name = "wNumBallsAddr",      addr = 0xD8D7, context = "either",
      note = "how many distinct Ball slots are filled in your Ball pocket" },
}

local outLines = {}
local function out(line)
    print(line)
    table.insert(outLines, line)
end

out("=== AutoCrystal WRAM address dump ===")

local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)
out(string.format("Header version byte (0x141): 0x%02X", version))
out(string.format("Header region byte  (0x142): 0x%02X (%s)", region,
    region == 0x45 and "English" or
    region == 0x44 and "German" or
    region == 0x46 and "French" or
    region == 0x49 and "Italian" or
    region == 0x53 and "Spanish" or
    region == 0x4A and "Japanese" or
    region == 0x4B and "Korean" or
    "unknown"))
out("")
out("Remember: run this once on the overworld (standing still, no menus) and once")
out("mid-battle (battle menu open) so every address below gets checked in the state")
out("where it's actually meaningful. 'overworld'/'battle'/'either' below tells you")
out("which run a given line is relevant for - ignore values from the wrong run.")
out("")

for _, entry in ipairs(ADDRESSES) do
    local value
    if entry.wide then
        value = memory.read_u16_be(entry.addr)
    else
        value = memory.readbyte(entry.addr)
    end
    out(string.format("[%-9s] %-22s 0x%04X = %5d (0x%02X)   -- %s",
        entry.context, entry.name, entry.addr, value, value, entry.note))
end

out("")
out("If any value looks obviously wrong for what's actually on screen right now")
out("(garbage species ID, HP that doesn't match the HP bar, party count that's off,")
out("etc.), that address is a real suspect for this ROM/language and needs the same")
out("treatment as the ROM hook addresses - please include this whole output (both")
out("runs) in the bug report either way, correct-looking values are useful")
out("confirmation too.")
out("=== Dump complete ===")

local outPath = script_dir .. "wram_address_scan_results.txt"
local f = io.open(outPath, "w")
if f then
    f:write(table.concat(outLines, "\n"))
    f:write("\n")
    f:close()
    print("")
    print("Full results written to " .. outPath .. " (overwritten each run - copy it out between runs if you need both)")
else
    print("")
    print("WARNING: couldn't write " .. outPath .. " - copy the console output above instead.")
end

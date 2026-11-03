-- diagnose_battle_transition.lua
--
-- Shows on screen which battle transition the next battle where you stand
-- would get, and whether that transition pins the DVs.
--
-- WHY: Crystal picks the transition in StartTrainerBattle_DetermineWhichAnimation
-- by comparing "your level" + 3 with "the enemy's level" - but neither is
-- set yet when it runs (pokecrystal's own comment says so). "Your level"
-- (C639) shares memory with the overworld's tile buffer (wSurroundingTiles,
-- filled by LoadMetatiles at 00:2198), so it really holds one map tile from
-- the block about two blocks up and left of you. "The enemy's level" (D213)
-- still holds the last wild Pokemon's level. Outdoors, when tile + 3 is
-- below that level, the game plays the "speckle" transition - the only one
-- that calls Random, thousands of times - and it leaves the RNG in a state
-- that pins the DVs of the Pokemon that appears. At the Azalea Heracross
-- tree that made shiny Heracross about 50x rarer (diagnose_headbutt_rng.lua
-- found it).
--
-- HOW TO USE: open it from the Lua Console (Script > Open Script) and walk
-- around; it only reads memory. The readout is for the overworld - in a
-- battle it says so. English Crystal 1.0/1.1 only.

-- The Lua Console even with Verbose Logging off - the launcher only shows
-- its own output there with it on (data/debug_log.lua).
local print = AutocrystalConsolePrint or print

local BUS = "System Bus"
local wBattleMonLevel, wEnemyMonLevel, wEnvironment, wBattleMode = 0xC639, 0xD213, 0xD19A, 0xD22D
local CAVE_ENVIRONMENTS = {[4] = true, [5] = true, [7] = true}
-- ld de,0 / ld a,[C639] / add 3 / ld hl,D213 / cp [hl] / jr nc / set 0,e
local CHECK = "\x11\x00\x00\xFA\x39\xC6\xC6\x03\x21\x13\xD2\xBE\x30\x02\xCB\xC3"
local CHECK_ROM = 0x23 * 0x4000 + 0x4365 - 0x4000

-- memory.getmemorydomainlist() can come back as a string or a table - see
-- diagnose_rom_addresses.lua.
local function has_domain(name)
    local list = memory.getmemorydomainlist()
    if type(list) == "string" then
        for line in list:gmatch("[^\r\n]+") do
            if line == name then return true end
        end
    elseif type(list) == "table" then
        for _, d in pairs(list) do
            if d == name then return true end
        end
    end
    return false
end

if not has_domain("ROM") or memory.read_bytes_as_binary_string(CHECK_ROM, #CHECK, "ROM") ~= CHECK then
    print("[transition] Not running: the transition check isn't where English Crystal has it (23:4365).")
    return
end

-- D213 and D19A through WRAM bank 1, whatever bank the game has switched
-- in - the check itself runs with bank 1 in.
local wramDomain = has_domain("WRAM") and "WRAM" or nil
local function wram(addr)
    if wramDomain then return memory.readbyte(addr - 0xC000, wramDomain) end
    return memory.readbyte(addr, BUS)
end

print("[transition] Showing the next battle's transition on screen. Stop this script from the Lua Console when done.")

while true do
    if wram(wBattleMode) ~= 0 then
        gui.text(2, 2, "In battle - the readout is for the overworld")
    else
        local tile, last, env = memory.readbyte(wBattleMonLevel, BUS), wram(wEnemyMonLevel), wram(wEnvironment)
        local stronger = (tile + 3) % 256 < last
        local anim
        if CAVE_ENVIRONMENTS[env] then
            anim = stronger and "zoom" or "sine"
        else
            anim = stronger and "speckle" or "spin"
        end
        if anim == "speckle" then
            gui.text(2, 2, "Next battle: speckle - DVs pinned", "red")
        else
            gui.text(2, 2, "Next battle: " .. anim .. " - fine", "lime")
        end
        -- The spot itself, whatever was fought last: outdoors, any wild
        -- Pokemon above tile + 3 gets the speckle.
        if CAVE_ENVIRONMENTS[env] then
            gui.text(2, 18, "cave/dungeon - no speckle here at any level")
        else
            gui.text(2, 18, string.format("map tile %d: wild levels %d+ get the speckle (last was %d)",
                tile, (tile + 3) % 256 + 1, last))
        end
    end
    emu.frameadvance()
end

-- gs_jp.lua (lives in data/)
-- The Japanese versions: Gold (Pocket Monsters Kin), Silver (Gin, Rev A)
-- and Crystal. Where each keeps what the bot reads, and where its code
-- sits for the hooks. The modules set the English addresses (Gold/Silver
-- or Crystal) and translate them through here.
--
-- How these were found (no Japanese symbol files exist): every routine in
-- pret's pokesilver.sym / pokegold.sym / pokecrystal11.sym was looked for
-- in the Japanese ROM by its code bytes, with the address operands masked
-- out. Where a routine turned up exactly once, the addresses in the same
-- instructions pair an English address with the Japanese one - about
-- 3,700 routines and 1,300 address pairs per Gold/Silver ROM, 5,500 and
-- 1,800 for Crystal. Japanese names are 6 bytes, not 11, so WRAM shifts in
-- blocks (Gold/Silver: -10 for the battle structs, -14 for the enemy and
-- the map variables, -13 for the player and the bag, -58 for the map
-- position and the party...; Crystal has its own, the mobile adapter data
-- moves a few by +49). Each address below is one the matcher paired
-- directly, or sits in the middle of a block whose shift it confirmed on
-- both sides (marked "block"). The hooks are the same routine found by a
-- window of code around the label. hROMBank stays where it is (Bankswitch
-- is byte-for-byte the same).
--
-- Kin (Rev 0) and Gin (Rev A) agree on every address the matcher paired
-- (1,322 of them) and on all six hooks, so they share one table.

local M = {}

-- English Gold/Silver -> Kin/Gin.
local GOLD_SILVER = {
    [0xC700] = 0xC700, -- wOverworldMapBlocks
    [0xCB0C] = 0xCB02, -- wBattleMonSpecies (battle_struct)
    [0xCB14] = 0xCB0A, -- wBattleMonPP (block)
    [0xCB1C] = 0xCB12, -- wBattleMonHP
    [0xCB1E] = 0xCB14, -- wBattleMonMaxHP
    [0xCEE0] = 0xCF14, -- wMenuCursorY
    [0xCEE1] = 0xCF15, -- wMenuCursorX
    [0xCFC6] = 0xCFC0, -- wCurBattleMon
    [0xD002] = 0xCFFC, -- wCurItem
    [0xD005] = 0xCFFF, -- wCurPartyMon
    [0xD087] = 0xD079, -- wMapHeight
    [0xD088] = 0xD07A, -- wMapWidth
    [0xD0C8] = 0xD0BA, -- wTilesetCollisionBank
    [0xD0C9] = 0xD0BB, -- wTilesetCollisionAddress
    [0xD0EF] = 0xD0E1, -- wEnemyMon
    [0xD0F5] = 0xD0E7, -- wEnemyMonDVs
    [0xD116] = 0xD108, -- wBattleMode
    [0xD117] = 0xD109, -- wTempWildMonSpecies
    [0xD14D] = 0xD13F, -- wPutativeTMHMMove
    [0xD157] = 0xD149, -- wTimeOfDay
    [0xD15E] = 0xD150, -- wScriptMode
    [0xD15F] = 0xD151, -- wScriptRunning
    [0xD1EB] = 0xD1DE, -- wGameTimeHours
    [0xD1F2] = 0xD1E5, -- wCurDay
    [0xD204] = 0xD1F7, -- wPlayerWalking (block)
    [0xD5B7] = 0xD5AA, -- wNumItems
    [0xD5B8] = 0xD5AB, -- wItems (block)
    [0xD5FC] = 0xD5EF, -- wNumBalls
    [0xD5FD] = 0xD5F0, -- wBalls (block)
    [0xD682] = 0xD675, -- wPlayerState
    [0xDA00] = 0xD9C6, -- wMapGroup
    [0xDA01] = 0xD9C7, -- wMapNumber
    [0xDA02] = 0xD9C8, -- wYCoord
    [0xDA03] = 0xD9C9, -- wXCoord
    [0xDA22] = 0xD9E8, -- wPartyCount
    [0xDA2A] = 0xD9F0, -- wPartyMon1
    [0xDD1A] = 0xDC90, -- wRoamMon1
    [0xDD40] = 0xDCB1, -- wOTPlayerName
    [0xDD55] = 0xDCC6, -- wOTPartyCount
    [0xDD56] = 0xDCC7, -- wOTPartySpecies
    [0xDD5D] = 0xDCCE, -- wOTPartyMons
}

-- English Crystal -> Japanese Crystal.
local CRYSTAL = {
    [0xC2FA] = 0xD13E, -- wTileDown (GetFacingTileCoord's table lists D13E-D141)
    [0xC62C] = 0xC622, -- wBattleMon
    [0xC634] = 0xC62A, -- wBattleMonPP
    [0xC639] = 0xC62F, -- wBattleMonLevel
    [0xC63C] = 0xC632, -- wBattleMonHP
    [0xC63E] = 0xC634, -- wBattleMonMaxHP
    [0xC800] = 0xC800, -- wOverworldMapBlocks
    [0xCFA9] = 0xCF9D, -- wMenuCursorY
    [0xCFAA] = 0xCF9E, -- wMenuCursorX
    [0xD0D4] = 0xD094, -- wCurBattleMon
    [0xD106] = 0xD0C6, -- wCurItem
    [0xD109] = 0xD0C9, -- wCurPartyMon
    [0xD19A] = 0xD1CB, -- wEnvironment
    [0xD19E] = 0xD1CF, -- wMapHeight
    [0xD19F] = 0xD1D0, -- wMapWidth
    [0xD1DF] = 0xD210, -- wTilesetCollisionBank
    [0xD1E0] = 0xD211, -- wTilesetCollisionAddress
    [0xD204] = 0xD235, -- wTempEnemyMonSpecies
    [0xD206] = 0xD237, -- wEnemyMon
    [0xD20C] = 0xD23D, -- wEnemyMonDVs
    [0xD213] = 0xD244, -- wEnemyMonLevel
    [0xD22D] = 0xD25E, -- wBattleMode
    [0xD22E] = 0xD25F, -- wTempWildMonSpecies
    [0xD23D] = 0xD26E, -- wBaseType
    [0xD262] = 0xD293, -- wPutativeTMHMMove
    [0xD269] = 0xD29A, -- wTimeOfDay
    [0xD26B] = 0xD29C, -- wOTPlayerName
    [0xD280] = 0xD2B1, -- wOTPartyCount
    [0xD281] = 0xD2B2, -- wOTPartySpecies (block)
    [0xD288] = 0xD2B9, -- wOTPartyMons
    [0xD437] = 0xD428, -- wScriptMode
    [0xD438] = 0xD429, -- wScriptRunning
    [0xD47B] = 0xD48C, -- wPlayerID
    [0xD4C4] = 0xD4B7, -- wGameTimeHours
    [0xD4CB] = 0xD4BE, -- wCurDay
    [0xD4DD] = 0xD4D0, -- wPlayerWalking (block)
    [0xD4DE] = 0xD4D1, -- wPlayerDirection
    [0xD4E6] = 0xD4D9, -- wPlayerStandingMapX
    [0xD4E7] = 0xD4DA, -- wPlayerStandingMapY
    [0xD892] = 0xD885, -- wNumItems
    [0xD893] = 0xD886, -- wItems (block)
    [0xD8D7] = 0xD8CA, -- wNumBalls
    [0xD8D8] = 0xD8CB, -- wBalls (block)
    [0xD95D] = 0xD950, -- wPlayerState
    [0xDCB5] = 0xDC7B, -- wMapGroup
    [0xDCB6] = 0xDC7C, -- wMapNumber
    [0xDCB7] = 0xDC7D, -- wYCoord
    [0xDCB8] = 0xDC7E, -- wXCoord
    [0xDCD7] = 0xDC9D, -- wPartyCount
    [0xDCDF] = 0xDCA5, -- wPartyMon1
    [0xDFCF] = 0xDF45, -- wRoamMon1
}

-- The hooks (bank, address), by what they are.
local GOLD_SILVER_HOOKS = {
    LoadBattleMenu = {0x09, 0x4E6E},
    MoveSelection = {0x0F, 0x6303},   -- MoveSelectionScreen
    Caught = {0x03, 0x6D7C},          -- PokeBallEffect.caught
    BreakFree = {0x03, 0x6F48},       -- PokeBallEffect.shake_and_break_free
    SkipUnown = {0x0F, 0x7478},       -- InitEnemyWildmon.skip_unown
    LearnMove = {0x10, 0x6663},       -- LearnLevelMoves.learn
}
local CRYSTAL_HOOKS = {
    LoadBattleMenu = {0x09, 0x4F02},
    MoveSelection = {0x0F, 0x64C0},
    Caught = {0x03, 0x6CAB},
    BreakFree = {0x03, 0x6E92},
    SkipUnown = {0x0F, 0x769F},
    LearnMove = {0x10, 0x6667},
}

-- By the header's version byte. rev: the one revision that's been checked
-- (header byte $14C).
local GAMES = {
    [0x55] = {name = "Japanese Gold (Kin)", rev = 0, revName = "the original release",
        wram = GOLD_SILVER, hooks = GOLD_SILVER_HOOKS},
    [0x58] = {name = "Japanese Silver (Gin)", rev = 1, revName = "Rev A",
        wram = GOLD_SILVER, hooks = GOLD_SILVER_HOOKS},
    [0x54] = {name = "Japanese Crystal", rev = 0, revName = "the original release",
        wram = CRYSTAL, hooks = CRYSTAL_HOOKS,
        -- data/tree_overlay.lua: right after LoadMapPart's call
        -- LoadMetatiles, TreeMonMaps / TreeMons in bank $2E, and its
        -- byte-for-byte checks - the same routines as English Crystal's,
        -- each found once in this ROM with the operands masked, and
        -- every operand the overlay relies on is one of the addresses
        -- above.
        treeOverlay = {latch = 0x2147, treeMonMaps = 0x423E, treeMons = 0x42C8, signatures = {
            {0x2E, 0x41D7, "21 3E 42 CD 1F 42 30 15 CD B2 42 30 10 CD C5 43"},
            {0x2E, 0x421F, "FA 7C DC 5F FA 7B DC 57 2A FE FF 28 0D BA 20 06 2A BB 20 03 18 06 23 23 18 EE AF C9 7E 37 C9"},
            {0x2E, 0x42B2, "FE 08 30 10 A7 28 0D 5F 16 00 21 C8 42 19 19 2A 66 6F 37 C9"},
            {0x2E, 0x43C5, "E5 CD 23 44 E1 A7 28 09 FE 01 28 0F FE 02 28 16 C9 3E 0A CD 83 2F A7 20 3D 18 1F"
                .. " 3E 0A CD 83 2F FE 05 30 32 18 14 3E 0A CD 83 2F FE 08 30 27"},
            {0x2E, 0x4423, "CD 46 44 EA 1B D2 CD 7D 44 EA 1C D2 4F FA 1B D2 91 28 0D 30 02 C6 0A FE 05 38 02 AF C9 3E 01 C9 3E 02 C9"},
            {0x2E, 0x4446, "CD D9 29 21 00 00 4B 06 00 7A A7 28 04 09 3D 20 FC 09 4A 09 7C E0 B3 7D E0 B4 3E 05 E0 B7 06 02 CD F0 30"
                .. " F0 B5 E0 B3 F0 B6 E0 B4 3E 0A E0 B7 06 02 CD F0 30 F0 B7 C9"},
            {0x2E, 0x447D, "FA 8C D4 E0 B3 FA 8D D4 E0 B4 3E 0A E0 B7 06 02 CD F0 30 F0 B7 C9"},
            {0x00, 0x29D9, "FA D1 D4 E6 0C CB 3F CB 3F 6F 26 00 29 29 11 FE 29 19 56 23 5E 23 2A 66 6F FA D9 D4 82 57 FA DA D4 83 5F 7E C9"
                .. " 00 01 3E D1 00 FF 3F D1 FF 00 40 D1 01 00 41 D1"},
            {0x00, 0x1865, "FE 15 C8 FE 1D C9"},
            {0x00, 0x2144, "CD 5B 21 3E 60"},
            {0x00, 0x215B, "FA C5 D1 5F FA C6 D1 57 21 08 C6"},
            {0x23, 0x4365, "11 00 00 FA 2F C6 C6 03 21 44 D2 BE 30 02 CB C3 FA CB D1 FE 04 28 0A FE 05 28 06 FE 07 28 02 CB CB"},
        }}},
}

local function this_game()
    if memory.readbyte(0x142) ~= 0x4A then return nil end
    return GAMES[memory.readbyte(0x141)]
end

-- A Japanese Gold, Silver or Crystal (region 'J').
function M.japanese(version, region)
    return region == 0x4A and GAMES[version] ~= nil
end

-- Whether it's the revision that's been worked out.
function M.supported(version, region)
    return M.japanese(version, region) and memory.readbyte(0x14C) == GAMES[version].rev
end

function M.unsupported_reason(version)
    local g = GAMES[version]
    if g == nil then return "This Japanese game isn't supported." end
    return string.format("This %s isn't %s - only that one has been checked.", g.name, g.revName)
end

-- The game's name, for "... detected".
function M.name(version)
    return GAMES[version] and GAMES[version].name or "Japanese game"
end

-- A Japanese address for an English one (Gold/Silver or Crystal, whichever
-- this is). Unknown: an error, so a missing one shows up straight away
-- rather than reading the wrong memory.
function M.w(addr)
    local g = this_game()
    local v = g and g.wram[addr]
    if v == nil then error(string.format("gs_jp: no Japanese address for $%04X", addr)) end
    return v
end

-- For a Crystal address used as it is in the code: the Japanese Crystal one
-- on Japanese Crystal, the same address on everything else.
function M.crystal(addr)
    if memory.readbyte(0x141) == 0x54 and memory.readbyte(0x142) == 0x4A then return M.w(addr) end
    return addr
end

local function gold_silver()
    local v = memory.readbyte(0x141)
    return v == 0x55 or v == 0x58
end

-- wMapGroup (wMapNumber is the byte after) of whatever game this is:
-- Crystal $DCB5, Gold/Silver $DA00, or where the Japanese ones keep it.
function M.map_group_addr()
    local addr = gold_silver() and 0xDA00 or 0xDCB5
    if this_game() then return M.w(addr) end
    return addr
end

-- "group:number" -> map name for whatever game is loaded: Gold/Silver
-- number their maps differently from Crystal (data/location_names_gs.lua).
M.location_names = setmetatable({}, {__index = function(_, key)
    return require(gold_silver() and "data.location_names_gs" or "data.location_names")[key]
end})

-- A hook's linear ROM address, as Mem.BankAddressToLinear() gives it.
function M.hook(name)
    local h = this_game().hooks[name]
    return h[1] * 0x4000 + h[2] % 0x4000
end

-- Japanese Crystal's tree overlay addresses, or nil on any other game.
function M.tree_overlay()
    local g = this_game()
    return g and g.treeOverlay
end

-- The live view's layout table, translated (HRAM - the clock - stays).
function M.layout(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "number" and v >= 0xC000 and v < 0xE000 then out[k] = M.w(v) else out[k] = v end
    end
    return out
end

return M

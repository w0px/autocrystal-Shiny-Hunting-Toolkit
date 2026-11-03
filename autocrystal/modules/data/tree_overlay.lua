-- tree_overlay.lua (lives in data/)
-- Colored text on the game screen while Headbutt is picked (Advanced
-- Settings > "Show tree overlay"): what the tree you're facing can give,
-- and whether a battle starting where you stand gets its DVs pinned.
--
-- THE TREE (TreeMonEncounter, 2E:41EA): the map picks a tree set, then
-- GetTreeScore compares ((x*y + x + y) / 5) mod 10 - x, y being the faced
-- tile, counted from the map's 4-tile border - with your trainer ID mod 10:
--   equal                  -> rare tree:  80% a Pokemon, rare table (Heracross)
--   1-4 ahead (wrapping)   -> common:     50%, common table
--   otherwise              -> weak:       10%, common table
--
-- THE BATTLE START: StartTrainerBattle_DetermineWhichAnimation (23:4365)
-- compares "your level" + 3 with "the enemy's level", neither of which is
-- set yet. "Your level" (C639) is really a tile of the overworld map
-- buffer (LoadMetatiles writes it), and "the enemy's level" is the last
-- wild Pokemon's. Outdoors, tile + 3 below that level means the "speckle"
-- transition - the only one that calls Random, about 7,500 times - and it
-- pins the DVs: at the Azalea Heracross tree, shiny Heracross became about
-- 50x rarer (see diagnose_headbutt_rng.lua / the README).
--
-- Crystal, Gold and Silver, English and Japanese: every routine used is
-- checked byte for byte first (Japanese Crystal's own copies: data/gs_jp.lua;
-- Gold/Silver's below), and the overlay says so instead of guessing on any
-- other game. Gold/Silver run the same code - their tree score and speckle
-- check are Crystal's, with their own addresses - and have 4 tree sets
-- where Crystal has 8.

local PokemonNames = PokemonNames or require("data.pokemon_names")
local GsJp = require("data.gs_jp")

local M = {}

local BUS = "System Bus"
local CALLBACK_NAME = "autocrystal tree overlay"
local LATCH_NAME = "autocrystal tree overlay latch"
local LATCH_ADDR = 0x2184        -- right after LoadMapPart's call LoadMetatiles
local wBattleMonLevel = 0xC639   -- the tile the transition check reads as "your level"
local wTileDown = 0xC2FA         -- then Up, Left, Right: collision of the four neighbours
local wEnemyMonLevel, wEnvironment, wBattleMode = 0xD213, 0xD19A, 0xD22D
local wPlayerID = 0xD47B
local wPlayerDirection, wPlayerStandingMapX, wPlayerStandingMapY = 0xD4DE, 0xD4E6, 0xD4E7
local wMapGroup, wMapNumber = 0xDCB5, 0xDCB6
local HEADBUTT_TREE = {[0x15] = true, [0x1D] = true}
local CAVE_ENVIRONMENTS = {[4] = true, [5] = true, [7] = true}
local DIRECTIONS = {[0] = {0, 1}, {0, -1}, {-1, 0}, {1, 0}} -- down, up, left, right
local TREE_MON_MAPS, TREE_MONS, NUM_TREE_SETS = {0x2E, 0x425E}, {0x2E, 0x42E8}, 8

local COLOR = {good = "lime", ok = "yellow", bad = "red", info = "white"}

-- The English Crystal addresses; load_rom() takes another game's from
-- overlay_game().
local ENGLISH = {latch = LATCH_ADDR, treeMonMaps = TREE_MON_MAPS[2], treeMons = TREE_MONS[2]}

-- Byte-for-byte what this reads or reimplements (English Crystal 1.1).
local SIGNATURES = {
    {0x2E, 0x41F7, "21 5E 42 CD 3F 42 30 15 CD D2 42 30 10 CD E5 43"},
    {0x2E, 0x423F, "FA B6 DC 5F FA B5 DC 57 2A FE FF 28 0D BA 20 06 2A BB 20 03 18 06 23 23 18 EE AF C9 7E 37 C9"},
    {0x2E, 0x42D2, "FE 08 30 10 A7 28 0D 5F 16 00 21 E8 42 19 19 2A 66 6F 37 C9"},
    {0x2E, 0x43E5, "E5 CD 43 44 E1 A7 28 09 FE 01 28 0F FE 02 28 16 C9 3E 0A CD B1 2F A7 20 3D 18 1F"
        .. " 3E 0A CD B1 2F FE 05 30 32 18 14 3E 0A CD B1 2F FE 08 30 27"},
    {0x2E, 0x4443, "CD 66 44 EA EA D1 CD 9D 44 EA EB D1 4F FA EA D1 91 28 0D 30 02 C6 0A FE 05 38 02 AF C9 3E 01 C9 3E 02 C9"},
    {0x2E, 0x4466, "CD 07 2A 21 00 00 4B 06 00 7A A7 28 04 09 3D 20 FC 09 4A 09 7C E0 B3 7D E0 B4 3E 05 E0 B7 06 02 CD 24 31"
        .. " F0 B5 E0 B3 F0 B6 E0 B4 3E 0A E0 B7 06 02 CD 24 31 F0 B7 C9"},
    {0x2E, 0x449D, "FA 7B D4 E0 B3 FA 7C D4 E0 B4 3E 0A E0 B7 06 02 CD 24 31 F0 B7 C9"},
    {0x00, 0x2A07, "FA DE D4 E6 0C CB 3F CB 3F 6F 26 00 29 29 11 2C 2A 19 56 23 5E 23 2A 66 6F FA E6 D4 82 57 FA E7 D4 83 5F 7E C9"
        .. " 00 01 FA C2 00 FF FB C2 FF 00 FC C2 01 00 FD C2"},
    {0x00, 0x189A, "FE 15 C8 FE 1D C9"},
    {0x00, 0x2181, "CD 98 21 3E 60"},
    {0x00, 0x2198, "FA 94 D1 5F FA 95 D1 57 21 08 C6"},
    {0x23, 0x4365, "11 00 00 FA 39 C6 C6 03 21 13 D2 BE 30 02 CB C3 FA 9A D1 FE 04 28 0A FE 05 28 06 FE 07 28 02 CB CB"},
}

-- Gold and Silver (English - the two are byte for byte the same here) and
-- Kin and Gin (Japanese, the same as each other): each of English
-- Crystal's routines above, found once in the ROM by its code with the
-- address operands masked out (Gold's own labels in pokegold.sym agree),
-- and the addresses its operands give.
local GOLD_SILVER = {latch = 0x1FD2, treeMonMaps = 0x63E6, treeMons = 0x6470, numSets = 4,
    wram = {battleMonLevel = 0xCB19, tileDown = 0xCEA3, enemyMonLevel = 0xD0FC, environment = 0xD083, battleMode = 0xD116,
        playerID = 0xD1A1, playerDirection = 0xD205, standingX = 0xD20D, standingY = 0xD20E, mapGroup = 0xDA00, mapNumber = 0xDA01},
    signatures = {
        {0x2E, 0x637F, "21 E6 63 CD C7 63 30 15 CD 5A 64 30 10 CD EF 64"},
        {0x2E, 0x63C7, "FA 01 DA 5F FA 00 DA 57 2A FE FF 28 0D BA 20 06 2A BB 20 03 18 06 23 23 18 EE AF C9 7E 37 C9"},
        {0x2E, 0x645A, "FE 04 30 10 A7 28 0D 5F 16 00 21 70 64 19 19 2A 66 6F 37 C9"},
        {0x2E, 0x64EF, "E5 CD 4D 65 E1 A7 28 09 FE 01 28 0F FE 02 28 16 C9 3E 0A CD C7 30 A7 20 3D 18 1F 3E 0A CD C7 30 FE 05 30 32 18 14 3E 0A CD C7 30 FE 08 30 27 18 00"},
        {0x2E, 0x654D, "CD 70 65 EA D3 D0 CD A7 65 EA D4 D0 4F FA D3 D0 91 28 0D 30 02 C6 0A FE 05 38 02 AF C9 3E 01 C9 3E 02 C9"},
        {0x2E, 0x6570, "CD EC 2A 21 00 00 4B 06 00 7A A7 28 04 09 3D 20 FC 09 4A 09 7C E0 B5 7D E0 B6 3E 05 E0 B9 06 02 CD C9 31 F0 B7 E0 B5 F0 B8 E0 B6 3E 0A E0 B9 06 02 CD C9 31 F0 B9 C9"},
        {0x2E, 0x65A7, "FA A1 D1 E0 B5 FA A2 D1 E0 B6 3E 0A E0 B9 06 02 CD C9 31 F0 B9 C9"},
        {0x00, 0x2AEC, "FA 05 D2 E6 0C CB 3F CB 3F 6F 26 00 29 29 11 11 2B 19 56 23 5E 23 2A 66 6F FA 0D D2 82 57 FA 0E D2 83 5F 7E C9 00 01 A3 CE 00 FF A4 CE FF 00 A5 CE 01 00 A6 CE"},
        {0x00, 0x1737, "FE 15 C8 FE 1D C9"},
        {0x00, 0x1FCF, "CD E6 1F 3E 60"},
        {0x00, 0x1FE6, "FA 7D D0 5F FA 7E D0 57 21 08 C5"},
        {0x23, 0x4624, "11 00 00 FA 19 CB C6 03 21 FC D0 BE 30 02 CB C3 FA 83 D0 FE 04 28 0A FE 05 28 06 FE 07 28 02 CB CB"},
    }}
local GOLD_SILVER_JP = {latch = 0x1F7F, treeMonMaps = 0x63E6, treeMons = 0x6470, numSets = 4,
    wram = {battleMonLevel = 0xCB0F, tileDown = 0xCE97, enemyMonLevel = 0xD0EE, environment = 0xD075, battleMode = 0xD108,
        playerID = 0xD1B3, playerDirection = 0xD1F8, standingX = 0xD200, standingY = 0xD201, mapGroup = 0xD9C6, mapNumber = 0xD9C7},
    signatures = {
        {0x2E, 0x637F, "21 E6 63 CD C7 63 30 15 CD 5A 64 30 10 CD EF 64"},
        {0x2E, 0x63C7, "FA C7 D9 5F FA C6 D9 57 2A FE FF 28 0D BA 20 06 2A BB 20 03 18 06 23 23 18 EE AF C9 7E 37 C9"},
        {0x2E, 0x645A, "FE 04 30 10 A7 28 0D 5F 16 00 21 70 64 19 19 2A 66 6F 37 C9"},
        {0x2E, 0x64EF, "E5 CD 4D 65 E1 A7 28 09 FE 01 28 0F FE 02 28 16 C9 3E 0A CD 83 30 A7 20 3D 18 1F 3E 0A CD 83 30 FE 05 30 32 18 14 3E 0A CD 83 30 FE 08 30 27 18 00"},
        {0x2E, 0x654D, "CD 70 65 EA C5 D0 CD A7 65 EA C6 D0 4F FA C5 D0 91 28 0D 30 02 C6 0A FE 05 38 02 AF C9 3E 01 C9 3E 02 C9"},
        {0x2E, 0x6570, "CD A8 2A 21 00 00 4B 06 00 7A A7 28 04 09 3D 20 FC 09 4A 09 7C E0 B5 7D E0 B6 3E 05 E0 B9 06 02 CD 85 31 F0 B7 E0 B5 F0 B8 E0 B6 3E 0A E0 B9 06 02 CD 85 31 F0 B9 C9"},
        {0x2E, 0x65A7, "FA B3 D1 E0 B5 FA B4 D1 E0 B6 3E 0A E0 B9 06 02 CD 85 31 F0 B9 C9"},
        {0x00, 0x2AA8, "FA F8 D1 E6 0C CB 3F CB 3F 6F 26 00 29 29 11 CD 2A 19 56 23 5E 23 2A 66 6F FA 00 D2 82 57 FA 01 D2 83 5F 7E C9 00 01 97 CE 00 FF 98 CE FF 00 99 CE 01 00 9A CE"},
        {0x00, 0x16E4, "FE 15 C8 FE 1D C9"},
        {0x00, 0x1F7C, "CD 93 1F 3E 60"},
        {0x00, 0x1F93, "FA 6F D0 5F FA 70 D0 57 21 08 C5"},
        {0x23, 0x4449, "11 00 00 FA 0F CB C6 03 21 EE D0 BE 30 02 CB C3 FA 75 D0 FE 04 28 0A FE 05 28 06 FE 07 28 02 CB CB"},
    }}

-- The loaded game's setup, or nil when the overlay has none for it.
local function overlay_game()
    local version, region = memory.readbyte(0x141, "ROM"), memory.readbyte(0x142, "ROM")
    if version == 0x55 or version == 0x58 then return region == 0x4A and GOLD_SILVER_JP or GOLD_SILVER end
    if version ~= 0x54 then return nil end
    -- Crystal: English, or Japanese (gs_jp.lua moves the addresses).
    local base, C = GsJp.tree_overlay() or ENGLISH, GsJp.crystal
    return {latch = base.latch, treeMonMaps = base.treeMonMaps, treeMons = base.treeMons, numSets = 8,
        signatures = base.signatures or SIGNATURES,
        wram = {battleMonLevel = C(0xC639), tileDown = C(0xC2FA), enemyMonLevel = C(0xD213), environment = C(0xD19A),
            battleMode = C(0xD22D), playerID = C(0xD47B), playerDirection = C(0xD4DE), standingX = C(0xD4E6),
            standingY = C(0xD4E7), mapGroup = C(0xDCB5), mapNumber = C(0xDCB6)}}
end

local function rom_linear(bank, addr)
    if bank == 0 then return addr end
    return bank * 0x4000 + addr - 0x4000
end

local function rom_byte(bank, addr) return memory.readbyte(rom_linear(bank, addr), "ROM") end

local function bytes(hex)
    return (hex:gsub("%s", ""):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

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

-- WRAM bank 1 whatever bank the game has switched in (see FrameSearch.wram).
local wramDomain
local function wram(addr)
    if wramDomain then return memory.readbyte(addr - 0xC000, wramDomain) end
    return memory.readbyte(addr, BUS)
end

-- ===== Tree tables, read from the ROM once per game =====
local romHash, supported, mapSets, treeSets

-- One table: {percent, species, level} rows up to the -1 end marker.
-- Returns the rows and where the next table starts.
local function read_table(addr)
    local rows = {}
    while rom_byte(0x2E, addr) ~= 0xFF and #rows < 32 do
        rows[#rows + 1] = {species = rom_byte(0x2E, addr + 1), level = rom_byte(0x2E, addr + 2)}
        addr = addr + 3
    end
    return rows, addr + 1
end

local function load_rom()
    local ok, hash = pcall(gameinfo.getromhash)
    hash = ok and hash or ""
    if hash == romHash and supported ~= nil then return supported end
    romHash, supported = hash, false
    if not has_domain("ROM") then return false end
    local game = overlay_game()
    if game == nil then return false end
    for _, s in ipairs(game.signatures) do
        local want = bytes(s[3])
        if memory.read_bytes_as_binary_string(rom_linear(s[1], s[2]), #want, "ROM") ~= want then
            return false
        end
    end
    wramDomain = has_domain("WRAM") and "WRAM" or nil
    LATCH_ADDR, TREE_MON_MAPS[2], TREE_MONS[2], NUM_TREE_SETS = game.latch, game.treeMonMaps, game.treeMons, game.numSets
    local a = game.wram
    wBattleMonLevel, wTileDown = a.battleMonLevel, a.tileDown
    wEnemyMonLevel, wEnvironment, wBattleMode = a.enemyMonLevel, a.environment, a.battleMode
    wPlayerID = a.playerID
    wPlayerDirection, wPlayerStandingMapX, wPlayerStandingMapY = a.playerDirection, a.standingX, a.standingY
    wMapGroup, wMapNumber = a.mapGroup, a.mapNumber
    mapSets = {}
    local addr = TREE_MON_MAPS[2]
    while rom_byte(0x2E, addr) ~= 0xFF and addr < TREE_MON_MAPS[2] + 300 do
        mapSets[rom_byte(0x2E, addr) * 256 + rom_byte(0x2E, addr + 1)] = rom_byte(0x2E, addr + 2)
        addr = addr + 3
    end
    treeSets = {}
    for set = 1, NUM_TREE_SETS - 1 do
        local p = TREE_MONS[2] + 2 * set
        local common, nextAddr = read_table(rom_byte(0x2E, p) + 256 * rom_byte(0x2E, p + 1))
        local rare = read_table(nextAddr)
        treeSets[set] = {common = common, rare = rare}
    end
    supported = true
    return true
end

-- ===== What the screen shows =====
local latchedTile -- C639 right after the last map redraw; menus scribble over it

local function species_list(rows)
    local seen, names = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.species] then
            seen[r.species] = true
            names[#names + 1] = PokemonNames[r.species] or ("#" .. r.species)
        end
    end
    return table.concat(names, ", ")
end

-- The faced tree, as TreeMonEncounter would see it. Returns text, color and
-- the table it would roll from (nil when it can't give anything).
local function tree_line()
    local dir = (wram(wPlayerDirection) % 16) // 4
    local d = DIRECTIONS[dir]
    if not HEADBUTT_TREE[memory.readbyte(wTileDown + dir, BUS)] then
        return "Not facing a headbutt tree", COLOR.info, nil
    end
    local set = mapSets[wram(wMapGroup) * 256 + wram(wMapNumber)]
    if set == nil or set == 0 or set >= NUM_TREE_SETS then
        return "This map's trees have no Pokemon", COLOR.info, nil
    end
    local x = (wram(wPlayerStandingMapX) + d[1]) % 256
    local y = (wram(wPlayerStandingMapY) + d[2]) % 256
    local coordScore = ((x * y + x + y) // 5) % 10
    local idScore = (wram(wPlayerID) * 256 + wram(wPlayerID + 1)) % 10
    local diff = (coordScore - idScore) % 10
    local tables = treeSets[set]
    if diff == 0 then
        return "Rare tree, 80%: " .. species_list(tables.rare), COLOR.good, tables.rare
    elseif diff < 5 then
        return "Common tree, 50%: " .. species_list(tables.common), COLOR.ok, tables.common
    end
    return "Weak tree, 10%: " .. species_list(tables.common), COLOR.bad, tables.common
end

-- Whether a battle starting here gets the speckle. Against the faced
-- tree's own levels when there is one (the game uses the LAST wild level,
-- which is that tree's after the first battle there), else the last
-- wild level itself.
local function transition_line(rows)
    if CAVE_ENVIRONMENTS[wram(wEnvironment)] then
        return "Battle start: fine (cave)", COLOR.good
    end
    local tile = latchedTile or memory.readbyte(wBattleMonLevel, BUS)
    local threshold = (tile + 3) % 256
    local pinned, total = 0, 0
    if rows then
        for _, r in ipairs(rows) do
            total = total + 1
            if threshold < r.level then pinned = pinned + 1 end
        end
    else
        total, pinned = 1, threshold < wram(wEnemyMonLevel) and 1 or 0
    end
    if pinned == 0 then
        return string.format("Battle start: fine (map tile %d)", tile), COLOR.good
    elseif pinned == total then
        return string.format("Battle start: DVs PINNED (map tile %d) - move", tile), COLOR.bad
    end
    return string.format("Battle start: DVs pinned for some levels (map tile %d)", tile), COLOR.ok
end

local function draw()
    if wram(wBattleMode) ~= 0 then return end
    local text, color, rows = tree_line()
    gui.text(2, 2, text, color)
    local text2, color2 = transition_line(rows)
    gui.text(2, 18, text2, color2)
end

-- ===== On/off =====
local active, failed = false, false

local function stop()
    event.unregisterbyname(CALLBACK_NAME)
    event.unregisterbyname(LATCH_NAME)
    active, latchedTile = false, nil
end

local function start()
    if not load_rom() then
        event.unregisterbyname(CALLBACK_NAME)
        event.onframeend(function()
            gui.text(2, 2, "Tree overlay: not for this game", COLOR.info)
        end, CALLBACK_NAME)
        active = true
        return
    end
    latchedTile = nil
    event.unregisterbyname(LATCH_NAME)
    event.onmemoryexecute(function()
        latchedTile = memory.readbyte(wBattleMonLevel, BUS)
    end, LATCH_ADDR, LATCH_NAME)
    event.unregisterbyname(CALLBACK_NAME)
    event.onframeend(function()
        if failed then return end
        local ok, err = pcall(draw)
        if not ok then
            failed = true
            print("Tree overlay stopped after an error: " .. tostring(err))
        end
    end, CALLBACK_NAME)
    active = true
end

-- Called every main-loop pass with whether the overlay should show (the
-- setting is ticked, Headbutt is picked, a ROM is loaded). Cheap when
-- nothing changes; a different ROM gets checked again.
local lastHash
function M.set_wanted(wanted)
    if wanted then
        local ok, hash = pcall(gameinfo.getromhash)
        hash = ok and hash or ""
        if not active or hash ~= lastHash then
            lastHash, failed = hash, false
            stop()
            start()
        end
    elseif active then
        stop()
    end
end

return M

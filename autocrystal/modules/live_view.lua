-- live_view.lua
-- "Game Assistant" window (the launcher's "Game Assistant" button): what's going
-- on in the game right now, whether the bot is running or you're playing
-- yourself. It only ever reads the game's memory - it never presses
-- anything, and nothing it sees counts toward the bot's stats. One column,
-- the launcher's width, top to bottom:
--   * The clock (day, time, morning/day/night), play time, where you are.
--   * The wild Pokemon or the trainer's Pokemon out now (sprite, level,
--     HP, DVs, shiny, held item, Hidden Power) - after a battle, the last
--     wild one. Under it your Pokemon and its moves, always: your lead
--     outside battles (type, power, accuracy, PP), the one fighting inside
--     them, with damage, share of the target's HP, chance to knock it out,
--     and data/move_choice.lua's picks for knocking it out and for
--     weakening it to catch; then what its moves can do to you, and a
--     trainer's whole team.
--   * ENCOUNTER TABLE: what can turn up where you stand at this time of
--     day, one tab each - walking (grass and caves) and surfing (ROM bank
--     $0A), fishing per rod (bank $24, the map's fishing group from its map
--     header in bank $25), headbutt trees, common and rare (bank $2E) - and
--     where the roaming legendaries are.
--   * The level-up moves of your Pokemon - the one fighting in a battle,
--     your lead otherwise (the game's EvosAttacks table in ROM bank $10).
--   * A map of where you are, with you on it: the current map's blocks
--     (wOverworldMapBlocks, 3 blocks of border all round) through the
--     tileset's collision table (4 bytes a block, one per 16x16 quarter -
--     home/map.asm's GetCoordTileCollision), colored by what each spot is.
--
-- Addresses: Crystal from pret's pokecrystal.sym, Gold/Silver from
-- pokegold.sym (the trainer's team and the roamers on Gold/Silver are from
-- a summary of it and only shown when they read right). Confirmed in the
-- ROMs as well: play time (the code that prints it loads wGameTimeHours/
-- wGameTimeMinutes with "ld de": Crystal $D4C4/$D4C6, Gold/Silver
-- $D1EB/$D1ED) and the clock (GetTimeOfDay starts with ldh a, [hHours]:
-- $FF94 / $FF96) and the weekday (GetWeekday is wCurDay mod 7 - wCurDay
-- counts on past 6). The Japanese and Korean games keep these elsewhere - not
-- supported yet.
--
-- The last wild Pokemon: polled every frame from the launcher's main loop,
-- and also handed over by gui_module.lua's update_last_encounter() - the
-- bot can run through a whole battle within one step, between two polls.
--
-- Built like stats_window.lua (see its notes): labels are only re-texted;
-- every sprite is its own picturebox, drawn once, then only moved and
-- shown/hidden; nothing overlaps anything.

local M = {}

Gui = Gui or require("gui_module")
PokemonNames = PokemonNames or require("data.pokemon_names")
ItemNames = ItemNames or require("data.item_names")
local LocationNames = require("data.location_names")
local LocationNamesGS = require("data.location_names_gs") -- Gold/Silver number their maps differently
local MoveChoice = require("data.move_choice")
-- C000-DFFF through WRAM bank 1 (the D000 half is banked).
local wram = require("data.frame_search").wram

-- HRAM (the clock), off the system bus: a plain memory.readbyte() reads
-- BizHawk's default domain, which isn't the bus here - the clock came out
-- as "not readable" that way.
local function hram(addr)
    local ok, value = pcall(memory.readbyte, addr, "System Bus")
    if ok and value then return value end
    ok, value = pcall(memory.readbyte, addr - 0xFF80, "HRAM")
    return ok and value or 0xFF
end

-- ===== The game =====

local LAYOUTS = {
    crystal = {
        battleMode = 0xD22D, tempWild = 0xD22E, own = 0xC62C, enemy = 0xD206,
        timeOfDay = 0xD269, hours = 0xFF94, minutes = 0xFF96, seconds = 0xFF98, day = 0xD4CB, playTime = 0xD4C4,
        playerState = 0xD95D, mapGroup = 0xDCB5, mapNumber = 0xDCB6,
        partyCount = 0xDCD7, partyMons = 0xDCDF,
        otCount = 0xD280, otSpecies = 0xD281, otMons = 0xD288,
        otClass = 0xD22F, otID = 0xD231, otClassName = 0xC656, rivalName = 0xD493,
        roamers = 0xDFCF, placeNames = "crystal",
        mapBlocks = 0xC800, mapWidth = 0xD19F, mapHeight = 0xD19E, collBank = 0xD1DF, collAddr = 0xD1E0,
        xCoord = 0xDCB8, yCoord = 0xDCB7,
    },
    goldSilver = {
        battleMode = 0xD116, tempWild = 0xD117, own = 0xCB0C, enemy = 0xD0EF,
        timeOfDay = 0xD157, hours = 0xFF96, minutes = 0xFF98, seconds = 0xFF9A, day = 0xD1F2, playTime = 0xD1EB,
        playerState = 0xD682, mapGroup = 0xDA00, mapNumber = 0xDA01,
        partyCount = 0xDA22, partyMons = 0xDA2A,
        otCount = 0xDD55, otSpecies = 0xDD56, otMons = 0xDD5D,
        otClass = 0xD118, otID = 0xD11B, otClassName = 0xCB34, rivalName = 0xD1B9,
        roamers = 0xDD1A, placeNames = "goldSilver",
        mapBlocks = 0xC700, mapWidth = 0xD088, mapHeight = 0xD087, collBank = 0xD0C8, collAddr = 0xD0C9,
        xCoord = 0xDA03, yCoord = 0xDA02,
    },
}

local WILD_BATTLE, TRAINER_BATTLE = 1, 2
local PARTY_MON_SIZE, EGG = 0x30, 0xFD
local TIMES = {[0] = "Morning", "Day", "Night"}
local DAYS = {[0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
local SURFING = {[4] = true, [8] = true} -- PLAYER_SURF, PLAYER_SURF_PIKA
local ROAMER_SPECIES = {[243] = true, [244] = true, [245] = true} -- Raikou, Entei, Suicune
local LIST_LINES = 6

-- The encounter tables (data/wild/*.asm): Johto grass, Johto water, Kanto
-- grass, Kanto water, back to back in bank $0A, each ending in $FF. Grass:
-- map group, map number, 3 rates (morning/day/night), then 7 (level,
-- species) slots per time of day. Water: group, number, 1 rate, 3 slots.
-- Found by the first entry, Sprout Tower 2F - the same in Crystal, Gold
-- and Silver.
local WILD_BANK = 0x0A
local FIRST_GRASS = string.char(0x03, 0x02, 0x05, 0x05, 0x05,
    0x03, 0x13, 0x04, 0x13, 0x05, 0x13, 0x03, 0x13, 0x06, 0x13, 0x05, 0x13, 0x05, 0x13)
local GRASS_LENGTH, GRASS_SLOTS, WATER_LENGTH, WATER_SLOTS = 47, 21, 9, 3
-- How often each slot comes up (data/wild/probabilities.asm), in percent.
local GRASS_ODDS = {30, 30, 20, 10, 5, 4, 1}
local WATER_ODDS = {60, 30, 10}

-- Fishing (data/wild/fish.asm), bank $24: FishGroups - per fishing group
-- a bite chance ($80), then pointers to its Old, Good and Super Rod tables
-- (3, 4 and 4 rows: chance so far out of 255, species, level; species 0
-- means the level-th TimeFishGroups entry: day species, level, night
-- species, level). A map's fishing group is the last byte of its 9-byte
-- map header (data/maps/maps.asm), found through MapGroupPointers in bank
-- $25. Found by the Shore group's Old Rod table and the first time group
-- (Corsola / Staryu) - the same in Crystal, Gold and Silver.
local FISH_BANK, MAP_BANK = 0x24, 0x25
local SHORE_OLD_ROD = string.char(179, 129, 10, 217, 129, 10, 255, 98, 10)
local FIRST_TIME_GROUPS = string.char(222, 20, 120, 20, 222, 40, 120, 40)
local ROD_ROWS, ROD_NAMES = {3, 4, 4}, {"Old Rod", "Good Rod", "Super Rod"}
local NUM_MAP_GROUPS, MAP_HEADER = 26, 9

-- Headbutt (data/wild/treemons.asm), bank $2E: TreeMonMaps (map group,
-- number, tree set; ends $FF), RockMonMaps (Rock Smash) the same way, then
-- GetTreeMonSet's "cp NUM_TREEMON_SETS / jr nc / and a / jr z / ... / ld
-- hl, TreeMons": set 0 and any past that are none (8 sets in Crystal, 4 in
-- Gold/Silver). Each set: a common, then a rare table of (percent,
-- species, level) rows ending $FF.
local TREE_BANK = 0x2E
local TREE_SET_CODE = string.char(0x30, 0x10, 0xA7, 0x28, 0x0D, 0x5F, 0x16, 0x00, 0x21)

-- The level-up moves (data/pokemon/evos_attacks.asm): a table of 251
-- pointers in bank $10 to each species' evolutions (each 3 bytes, 4 for
-- EVOLVE_STAT, ending in 0) then (level, move) pairs ending in 0. Found
-- through Bulbasaur's entry - evolves at 16, Tackle 1, Growl 4, Leech Seed
-- 7, Vine Whip 10 - the same in Crystal, Gold/Silver and Gin.
local EVOS_BANK = 0x10
local BULBASAUR_EVOS = string.char(0x01, 0x10, 0x02, 0x00, 0x01, 0x21, 0x04, 0x2D, 0x07, 0x49, 0x0A, 0x16)
local EVO_LENGTH = {[1] = 3, [2] = 3, [3] = 3, [4] = 3, [5] = 4}

local game = {
    romHash = nil, layout = nil, wild = nil, evos = nil, learnsets = {},
    battleMode = nil,
    lastKey = nil, -- the last wild Pokemon kept, so it's kept once
    current = nil, -- the last wild Pokemon, as read in its battle
    ticks = 0, dirty = false,
}

-- The launcher's shared HUD (M.attach()) and whether a module is running
-- (M.tick()) - its encounter panels are fed from here while none is.
local launcher = {hud = nil, running = false, count = 0}

local function r8(addr) return wram(addr) end
local function r16(addr) return wram(addr) * 256 + wram(addr + 1) end

local function read_bank(bank)
    local ok, data = pcall(memory.read_bytes_as_binary_string, bank * 0x4000, 0x4000, "ROM")
    if ok and type(data) == "string" and #data == 0x4000 then return data end
    return nil
end

local function read_wild_tables()
    local bank = read_bank(WILD_BANK)
    local pos = bank and bank:find(FIRST_GRASS, 1, true)
    if pos == nil then return nil end
    local tables = {grass = {}, water = {}}
    for _, kind in ipairs({"grass", "water", "grass", "water"}) do -- Johto, then Kanto
        local length = kind == "grass" and GRASS_LENGTH or WATER_LENGTH
        local slots = kind == "grass" and GRASS_SLOTS or WATER_SLOTS
        local count = 0
        while bank:byte(pos) ~= 0xFF do
            if pos + length > #bank or count >= 120 then return nil end
            local entry = {}
            for i = 1, slots do
                local at = pos + length - 2 * slots + 2 * (i - 1)
                local level, species = bank:byte(at), bank:byte(at + 1)
                if level < 1 or level > 100 or species < 1 or species > 251 then return nil end
                entry[i] = {level = level, species = species}
            end
            tables[kind][bank:byte(pos) .. ":" .. bank:byte(pos + 1)] = entry
            pos = pos + length
            count = count + 1
        end
        pos = pos + 1
    end
    return tables
end

local function word(data, pos) return data:byte(pos) + 256 * data:byte(pos + 1) end
local function bank_pos(addr) return addr - 0x4000 + 1 end

local function read_fishing()
    local fish, maps = read_bank(FISH_BANK), read_bank(MAP_BANK)
    if fish == nil or maps == nil then return nil end
    local shore = fish:find(SHORE_OLD_ROD, 1, true)
    local times = fish:find(FIRST_TIME_GROUPS, 1, true)
    if shore == nil or times == nil then return nil end
    local addr = 0x4000 + shore - 1
    local pos = fish:find(string.char(0x80, addr % 256, addr // 256), 1, true)
    if pos == nil then return nil end
    local groups = {}
    while fish:byte(pos) == 0x80 and #groups < 20 do
        groups[#groups + 1] = {word(fish, pos + 1), word(fish, pos + 3), word(fish, pos + 5)}
        pos = pos + 7
    end
    -- MapGroupPointers: 26 pointers, the first to right after the table,
    -- each group a whole number of map headers long.
    for at = 1, #maps - 2 * NUM_MAP_GROUPS do
        if word(maps, at) == 0x4000 + at - 1 + 2 * NUM_MAP_GROUPS then
            local good = true
            for g = 1, NUM_MAP_GROUPS - 1 do
                local gap = word(maps, at + 2 * g) - word(maps, at + 2 * (g - 1))
                if gap <= 0 or gap % MAP_HEADER ~= 0 then good = false break end
            end
            if good then return {fish = fish, maps = maps, groups = groups, times = times, mapTable = at} end
        end
    end
    return nil
end

-- GetTrainerName's "dec c / push bc / ld b, 0 / ld hl, TrainerGroups / add
-- hl, bc / add hl, bc / ld a, [hli] / ld h, [hl] / ld l, a / pop bc" -
-- TrainerGroups is in the same bank (it reads it without switching).
local TRAINER_GROUPS_CODE = {string.char(0x0D, 0xC5, 0x06, 0x00, 0x21), string.char(0x09, 0x09, 0x2A, 0x66, 0x6F, 0xC1)}
local TRAINER_BANK = 0x0E

local function find_trainer_groups()
    local bank = read_bank(TRAINER_BANK)
    local at = bank and bank:find(TRAINER_GROUPS_CODE[1], 1, true)
    while at do
        if bank:sub(at + 7, at + 12) == TRAINER_GROUPS_CODE[2] then
            return {bank = bank, table = bank_pos(word(bank, at + 5))}
        end
        at = bank:find(TRAINER_GROUPS_CODE[1], at + 1, true)
    end
    return nil
end

local function read_trees()
    local bank = read_bank(TREE_BANK)
    local code = bank and bank:find(TREE_SET_CODE, 1, true)
    if code == nil or code < 4 or bank:byte(code - 2) ~= 0xFE or bank:byte(code - 3) ~= 0xFF then return nil end
    local numSets, tableAddr = bank:byte(code - 1), word(bank, code + #TREE_SET_CODE)
    -- Back over RockMonMaps (no entry byte is $FF) to the $FF ending
    -- TreeMonMaps, then over TreeMonMaps to its first entry.
    local rockEnd, rocks = code - 3, nil
    for k = 1, 30 do
        if bank:byte(rockEnd - 3 * k - 1) == 0xFF then rocks = rockEnd - 3 * k break end
    end
    if rocks == nil then return nil end
    local rockSet = bank:byte(rocks + 2)
    local mapSets, at, count = {}, rocks - 4, 0
    while at >= 1 do
        local g, m, set = bank:byte(at), bank:byte(at + 1), bank:byte(at + 2)
        -- (Gold/Silver give towns set 5: past the sets, so none.)
        if g < 1 or g > NUM_MAP_GROUPS or m < 1 or m > 100 or set > 15 then break end
        mapSets[g .. ":" .. m] = set
        count = count + 1
        at = at - 3
    end
    local sets = {}
    for set = 1, numSets - 1 do
        if set ~= rockSet then
            local pos = bank_pos(word(bank, bank_pos(tableAddr) + 2 * set))
            local tables = {}
            for i = 1, 2 do
                local rows = {}
                while bank:byte(pos) ~= 0xFF and #rows < 12 do
                    rows[#rows + 1] = {odds = bank:byte(pos), species = bank:byte(pos + 1), level = bank:byte(pos + 2)}
                    pos = pos + 3
                end
                pos = pos + 1
                tables[i] = rows
            end
            sets[set] = {common = tables[1], rare = tables[2]}
        end
    end
    return {mapSets = mapSets, sets = sets, maps = count}
end

-- The EvosAttacks pointer table: where 251 pointers, all into this bank,
-- start with the one to Bulbasaur's entry.
local function find_evos()
    local bank = read_bank(EVOS_BANK)
    local at = bank and bank:find(BULBASAUR_EVOS, 1, true)
    if at == nil then return nil end
    local ptr = 0x4000 + at - 1
    local ptrBytes = string.char(ptr % 256, ptr // 256)
    local from = 1
    while true do
        local t = bank:find(ptrBytes, from, true)
        if t == nil or t + 501 > #bank then return nil end
        local good = true
        for i = 0, 250 do
            local p = bank:byte(t + 2 * i) + 256 * bank:byte(t + 2 * i + 1)
            if p < 0x4000 or p >= 0x8000 then good = false break end
        end
        if good then return {bank = bank, table = t} end
        from = t + 1
    end
end

-- One species' level-up moves, {level, move} in the game's order.
local function learnset(species)
    local cached = game.learnsets[species]
    if cached ~= nil then return cached or nil end
    local evos = game.evos
    local list = false
    if evos and species >= 1 and species <= 251 then
        local bank, t = evos.bank, evos.table
        local pos = bank:byte(t + 2 * (species - 1)) + 256 * bank:byte(t + 2 * (species - 1) + 1) - 0x4000 + 1
        local guard = 0
        while bank:byte(pos) ~= 0 and guard < 10 do
            pos = pos + (EVO_LENGTH[bank:byte(pos)] or 3)
            guard = guard + 1
        end
        pos = pos + 1
        list = {}
        while bank:byte(pos) and bank:byte(pos) ~= 0 and #list < 30 do
            list[#list + 1] = {level = bank:byte(pos), move = bank:byte(pos + 1)}
            pos = pos + 2
        end
    end
    game.learnsets[species] = list
    return list or nil
end

-- Per game (ROM hash): which addresses, and the tables.
local function refresh_game()
    local okHash, hash = pcall(gameinfo.getromhash)
    hash = okHash and hash or ""
    if hash == game.romHash then return end
    game.romHash = hash
    local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
    game.layout = nil
    if region ~= 0x4A and region ~= 0x4B then
        if version == 0x54 then
            game.layout = LAYOUTS.crystal
        elseif version == 0x55 or version == 0x58 then
            game.layout = LAYOUTS.goldSilver
        end
    elseif require("data.gs_jp").supported(version, region) then
        -- The Japanese versions: the English addresses, moved to where they
        -- keep them (data/gs_jp.lua). No trainer name: it's kana.
        local english = {}
        for k, v in pairs(version == 0x54 and LAYOUTS.crystal or LAYOUTS.goldSilver) do english[k] = v end
        english.otClass, english.otID, english.otClassName, english.rivalName = nil, nil, nil, nil
        game.layout = require("data.gs_jp").layout(english)
    end
    game.wild = game.layout and read_wild_tables() or nil
    game.fishing = game.layout and read_fishing() or nil
    game.trees = game.layout and read_trees() or nil
    game.trainerGroups = game.layout and game.layout.otClass and find_trainer_groups() or nil
    game.evos = game.layout and find_evos() or nil
    game.learnsets = {}
    game.battleMode, game.current, game.lastKey, game.clockAt, game.water = nil, nil, nil, nil, nil
    game.dirty = true
end

-- The Pokemon in a battle struct (macros/ram.asm's battle_struct).
local function read_battle_mon(base)
    local mon = {species = r8(base), item = r8(base + 1), dv1 = r8(base + 6), dv2 = r8(base + 7),
        level = r8(base + 13), hp = r16(base + 16), maxHP = r16(base + 18), moves = {}, pp = {}}
    for slot = 1, 4 do
        mon.moves[slot] = r8(base + 1 + slot)
        mon.pp[slot] = r8(base + 7 + slot) % 64 -- the top two bits are PP Ups
    end
    return mon
end

-- A party Pokemon (party_struct): same fields, other offsets.
local function read_party_mon(base)
    local mon = {species = r8(base), item = r8(base + 1), dv1 = r8(base + 21), dv2 = r8(base + 22),
        level = r8(base + 31), hp = r16(base + 34), maxHP = r16(base + 36), moves = {}, pp = {}}
    for slot = 1, 4 do
        mon.moves[slot] = r8(base + 1 + slot)
        mon.pp[slot] = r8(base + 22 + slot) % 64
    end
    return mon
end

local function key_of(mon)
    return table.concat({mon.species, mon.dv1, mon.dv2, mon.level, mon.maxHP}, ":")
end

local function plausible(mon)
    return mon.species >= 1 and mon.species <= 251 and mon.level >= 1 and mon.level <= 100
        and mon.maxHP > 0 and mon.hp <= mon.maxHP
end

local function is_shiny(dv1, dv2)
    local atk, def, spe, spc = dv1 // 16, dv1 % 16, dv2 // 16, dv2 % 16
    return def == 10 and spe == 10 and spc == 10 and atk % 4 >= 2
end

-- Keeps a wild Pokemon as the last one (once - the poll and the bot can
-- both report it).
local function record(mon)
    local key = key_of(mon)
    if key == game.lastKey then return end
    game.lastKey = key
    game.current = mon
    game.dirty = true
    -- With no module running, nothing else puts it on the launcher's
    -- Current/Recent Encounters - M.tick() does.
    if not launcher.running then game.toLauncher = mon end
end

-- In a wild battle, the wild Pokemon in wEnemyMon - once it's this
-- battle's. It only gets there once its DVs are rolled, after the battle
-- transition, while the species the battle started with (wTempWildMon-
-- Species) is set before: a struct still holding the last battle's
-- Pokemon is the one already kept, or another species.
local function poll()
    local L = game.layout
    if L == nil then return end
    local mode = r8(L.battleMode)
    if mode ~= WILD_BATTLE and mode ~= TRAINER_BATTLE then mode = 0 end
    if mode ~= game.battleMode then game.dirty = true end
    game.battleMode = mode
    if mode == WILD_BATTLE then
        local mon = read_battle_mon(L.enemy)
        if plausible(mon) and mon.species == r8(L.tempWild) then record(mon) end
    end
end

-- Gen 2 text (charmap.asm): A-Z $80-, a-z $A0-, 0-9 $F6-, space $7F, end
-- $50, and the punctuation trainer names and classes use.
local CHARS = {[0x7F] = " ", [0x9A] = "(", [0x9B] = ")", [0x9C] = ":", [0x9D] = ";", [0x9E] = "[", [0x9F] = "]",
    [0xE0] = "'", [0xE1] = "PK", [0xE2] = "MN", [0xE3] = "-", [0xE6] = "?", [0xE7] = "!", [0xE8] = ".", [0xE9] = "&",
    [0xEA] = "é", [0xEF] = "♂", [0xF2] = ".", [0xF3] = "/", [0xF4] = ",", [0xF5] = "♀"}
local function decode_text(byte_at)
    local out = {}
    for i = 0, 12 do
        local c = byte_at(i)
        if c == nil or c == 0x50 then break end
        if c >= 0x80 and c <= 0x99 then out[#out + 1] = string.char(65 + c - 0x80)
        elseif c >= 0xA0 and c <= 0xB9 then out[#out + 1] = string.char(97 + c - 0xA0)
        elseif c >= 0xF6 then out[#out + 1] = string.char(48 + c - 0xF6)
        else out[#out + 1] = CHARS[c] or "?" end
    end
    return table.concat(out)
end
local function decode_name(addr)
    return decode_text(function(i) return r8(addr + i) end)
end

-- The trainer you're fighting, as the game prints it (PlaceEnemysName):
-- class name (wOTClassName, set at the battle's start) and the trainer's
-- own name, which isn't in RAM - GetTrainerName finds it in ROM by class
-- and number in TrainerGroups (bank $0E). The rival's entries are named
-- "?": the game prints wRivalName instead.
local function trainer_name()
    local L, tg = game.layout, game.trainerGroups
    if tg == nil then return "" end
    local class, id = r8(L.otClass), r8(L.otID)
    if class == 0 or id == 0 or 2 * class > #tg.bank then return "" end
    local pos = bank_pos(word(tg.bank, tg.table + 2 * (class - 1)))
    for _ = 2, id do
        repeat
            local b = tg.bank:byte(pos)
            pos = pos + 1
        until b == 0xFF or b == nil or pos > #tg.bank
    end
    local name = decode_text(function(i) return tg.bank:byte(pos + i) end)
    if name == "?" then return decode_name(L.rivalName) end
    local class_name = decode_name(L.otClassName)
    if name == "" or class_name == "" then return name .. class_name end
    return class_name .. " " .. name
end

-- The table's slots for one time of day, one row per species: chance
-- summed, level range.
local function by_species(slots, first, odds)
    local rows, bySpecies = {}, {}
    for i = 1, #odds do
        local s = slots[first + i - 1]
        local row = bySpecies[s.species]
        if row == nil then
            row = {species = s.species, odds = 0, low = s.level, high = s.level}
            bySpecies[s.species] = row
            rows[#rows + 1] = row
        end
        row.odds = row.odds + odds[i]
        row.low, row.high = math.min(row.low, s.level), math.max(row.high, s.level)
    end
    table.sort(rows, function(a, b)
        if a.odds ~= b.odds then return a.odds > b.odds end
        return a.species < b.species
    end)
    return rows
end

local function species_name(id)
    return PokemonNames[id] or ("#" .. tostring(id))
end

local function item_name(id)
    if id == 0 then return "none" end
    return ItemNames[id] or ("item #" .. id)
end

local function move_name(id)
    local info = MoveChoice.move_info(id)
    return info and info.name or ("move #" .. id)
end

local function place_name(group, number)
    local L = game.layout
    local names = L and (L.placeNames == "crystal" and LocationNames or L.placeNames == "goldSilver" and LocationNamesGS)
    local name = names and names[group .. ":" .. number]
    return name or string.format("Map %d:%d", group, number)
end

-- Your lead outside battles: the first party Pokemon that isn't an egg
-- and hasn't fainted (the one the game would send out) - or, with all of
-- them down, the first that isn't an egg.
local function read_lead()
    local L = game.layout
    local count = r8(L.partyCount)
    if count < 1 or count > 6 then return nil end
    local firstPokemon
    for slot = 1, count do
        if r8(L.partyCount + slot) ~= EGG then
            local mon = read_party_mon(L.partyMons + (slot - 1) * PARTY_MON_SIZE)
            if plausible(mon) then
                if mon.hp > 0 then return mon end
                firstPokemon = firstPokemon or mon
            end
        end
    end
    return firstPokemon
end

-- ===== The window =====

-- One column at the launcher's width: its panel geometry, content 8px in
-- (gui_module.lua's draw_frame rings reach 2px outside each rect).
local FORM_W = 460
local PX, PW = Gui.PANEL_X, Gui.PANEL_W
local X, W = PX + 8, PW - 16
local CARD_SIZE = 98
-- The facing Pokemon's lines, then the enemy's moves against the panel's
-- right edge. Column widths are the widest text each can hold in the
-- window font (WinForms' Microsoft Sans Serif 8.25): "100%" 33px, a move
-- name up to 99 (THUNDERPUNCH, DRAGONBREATH), a range like "103-121" 46.
-- The lines on the left (HP, DVs, held item, Hidden Power) are at most
-- 129; the name line, the only long one, runs on under the heading.
local ITS_CHANCE_W, ITS_NAME_W, ITS_DMG_W = 33, 100, 46
local ITS_X = X + W - ITS_CHANCE_W - ITS_NAME_W - ITS_DMG_W
local ITS_NAME_X = ITS_X + ITS_CHANCE_W
local INFO_W = ITS_X - (X + CARD_SIZE + 8) - 2
local INFO_NAME_W = ITS_NAME_X - (X + CARD_SIZE + 8) - 2
-- The Pokemon facing you: a white card in a frame, like the launcher's
-- Current Encounter card - 92px, 4px in and down from where CARD_SIZE's
-- space starts, so the frame (6px of rings round it) clears the panel's
-- frame, the title and the text beside it.
local CARD_X, CARD_DY, CARD_BOX, CARD_WHITE = X + 4, 4, 92, "#FFFFFF"
local PARTY_STEP_X, PARTY_STEP_Y, ICON_PARTY = 139, 50, 40
local TEAM_STEP, ICON_TEAM = 69, 28
local HERE_STEP, ICON_HERE = 26, 24
local SURF_X = X + 212
local MAP_AREA_H = 150
-- The collapsible sections, top to bottom: their frames' heights open,
-- and closed (just the title row). Which are closed is remembered
-- (gui_settings.txt's gacollapsed; all open to start).
local SECTIONS = {
    {key = "party", height = 330, title = "YOUR PARTY / BATTLE"},
    {key = "here", height = 244, title = "ENCOUNTER TABLE"},
    {key = "moves", height = 136, title = "LEVEL-UP MOVES"},
    {key = "map", height = 188, title = "MAP"},
}
local CLOSED_H, SECTION_GAP = 28, 10
-- ENCOUNTER TABLE's tabs (the one picked is remembered: gui_settings.txt's
-- gatab), and its two columns of HERE_SLOTS rows each.
local HERE_TABS = {
    {key = "walk", name = "Walking"}, {key = "surf", name = "Surfing"}, {key = "fish", name = "Fishing"},
    {key = "tree", name = "Headbutt"}, {key = "roam", name = "Roaming"},
}
local HERE_SLOTS, HERE_TABS_Y, HERE_LIST_Y = 7, 28, 58
-- Its time-of-day buttons, in the title row left of the -/+ button.
local TIME_BUTTON_W = 58

local ui = {form = nil, rootDir = "./", c = {}, texts = {}, colors = {},
    cards = {}, shownCard = false, icons = {}, warned = false, detached = false}

-- arrange_windows.ps1 docks the window titled exactly this against
-- BizHawk's left side; Detach adds " (detached)" to the title so it's let
-- go of, Attach takes it off again, and a reopened window starts attached.
local TITLE = "Game Assistant"

local function toggle_detached()
    if ui.form == nil then return end
    ui.detached = not ui.detached
    forms.settext(ui.form, ui.detached and (TITLE .. " (detached)") or TITLE)
    forms.settext(ui.c.dock, ui.detached and "Attach" or "Detach")
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function set_text(handle, text)
    if ui.texts[handle] ~= text then
        forms.settext(handle, text)
        ui.texts[handle] = text
    end
end

local function set_color(handle, color)
    if ui.colors[handle] ~= color then
        pcall(forms.setproperty, handle, "ForeColor", color)
        ui.colors[handle] = color
    end
end

-- Every control of the section being built, with where it sits in it, so
-- folding can move and hide them (relayout()).
local function track(handle, x, y, fixed)
    local sec = ui.building
    if sec then sec.items[#sec.items + 1] = {h = handle, x = x, dy = y - sec.top0, fixed = fixed} end
    return handle
end

local function label(x, y, w, h, header)
    local l = forms.label(ui.form, "", x, y, w, h or 16)
    if header then Gui.style_header(l) end
    return track(l, x, y)
end

-- gui_module.lua's draw_frame() (same rings, same colors), keeping the
-- line labels so a section's frame can be moved and swapped.
local function frame_lines(x, y, w, h)
    -- Four edge pictures (gui_module.lua's draw_frame_fast()) instead of 12
    -- line labels: same pieces list, so moving and swapping work the same.
    return Gui.draw_frame_fast(ui.form, x, y, w, h)
end

-- The card sprite (like the launcher's Current Encounter card): the best
-- kind downloaded - animated card GIF, animated GIF, PNG - shiny for a
-- shiny. One picturebox per sprite, created hidden; the white card label
-- (created first, so in front) shows while none is.
local CARD_KINDS = {
    {dir = "animated_card/", ext = "gif", mode = "CenterImage"},
    {dir = "animated/", ext = "gif", mode = "Zoom"},
    {dir = "", ext = "png", mode = "Zoom"},
}

local function card_box(species, shiny)
    for _, wantShiny in ipairs(shiny and {true, false} or {false}) do
        for _, kind in ipairs(CARD_KINDS) do
            local path = kind.ext == "png" and Gui.still_sprite(ui.rootDir, species, wantShiny)
                or string.format("%sdata/sprites/%s%s/%d.%s", ui.rootDir, kind.dir, wantShiny and "shiny" or "normal", species, kind.ext)
            if ui.cards[path] then return ui.cards[path] end
            if file_exists(path) then
                local box = forms.pictureBox(ui.form, CARD_X, ui.lay.cardY + CARD_DY + ui.scroll, CARD_BOX, CARD_BOX)
                pcall(forms.setproperty, box, "BackColor", CARD_WHITE)
                pcall(forms.setproperty, box, "SizeMode", kind.mode)
                pcall(forms.setproperty, box, "WaitOnLoad", true)
                pcall(forms.setproperty, box, "ImageLocation", path)
                pcall(forms.setproperty, box, "Visible", false)
                ui.cards[path] = box
                return box
            end
        end
    end
    return nil
end

local function show_card(species, shiny)
    local box = species and card_box(species, shiny) or nil
    if ui.shownCard == box then return end
    if ui.shownCard then pcall(forms.setproperty, ui.shownCard, "Visible", false) end
    if box then pcall(forms.setproperty, box, "Visible", true) end
    pcall(forms.setproperty, ui.c.card, "Visible", box == nil)
    ui.shownCard = box
end

-- Small sprites (Gui.still_sprite(): the PNG, or in dark mode the transparent
-- still): one picturebox per use, per species, shininess and size, drawn
-- once; each update marks what it needs and the rest get hidden.
local function begin_icons()
    for _, list in pairs(ui.icons) do
        for _, icon in ipairs(list) do icon.used = false end
    end
end

local function place_icon(species, size, x, y, shiny)
    -- species "egg": the egg picture (an egg's species isn't shown).
    local path = species == "egg" and (ui.rootDir .. "data/sprites/egg_card.png") or Gui.still_sprite(ui.rootDir, species, shiny)
    local key = species .. ":" .. size .. (shiny and "s" or "")
    local list = ui.icons[key]
    if list == nil then
        list = {}
        ui.icons[key] = list
    end
    local icon
    for _, candidate in ipairs(list) do
        if not candidate.used then
            icon = candidate
            break
        end
    end
    if icon == nil then
        if not file_exists(path) then return end
        local box = forms.pictureBox(ui.form, x, y + ui.scroll, size, size)
        pcall(forms.clear, box, Gui.THEME.card)
        pcall(forms.drawImage, box, path, 0, 0, size, size)
        -- The white PNG gets a border to make it a card; the dark mode
        -- still is transparent and needs none.
        if not Gui.dark then pcall(forms.drawRectangle, box, 0, 0, size - 1, size - 1, Gui.THEME.border) end
        pcall(forms.refresh, box)
        icon = {box = box, x = x, y = y, visible = true}
        list[#list + 1] = icon
    end
    icon.used = true
    if icon.x ~= x or icon.y ~= y then
        forms.setlocation(icon.box, x, y + ui.scroll)
        icon.x, icon.y = x, y
    end
    if not icon.visible then
        pcall(forms.setproperty, icon.box, "Visible", true)
        icon.visible = true
    end
end

local function end_icons()
    for _, list in pairs(ui.icons) do
        for _, icon in ipairs(list) do
            if not icon.used and icon.visible then
                pcall(forms.setproperty, icon.box, "Visible", false)
                icon.visible = false
            end
        end
    end
end

local function percent(part, whole)
    return math.floor(part * 100 / math.max(whole, 1) + 0.5)
end

-- The clock in HRAM only moves outside battles (the game reads the real-
-- time clock in the overworld), so in a battle it's the last reading from
-- outside plus the emulated time gone by since: BizHawk's frame count, at
-- the Game Boy Color's 59.7275 frames a second (the cartridge clock runs on
-- emulated time too). Not the play-time counter - it stops for good at
-- 999:59.
local FRAMES_PER_SECOND = 4194304 / 70224

local function frame_count()
    local ok, frames = pcall(emu.framecount)
    return ok and type(frames) == "number" and frames or nil
end

local function update_clock_and_place()
    local L, c = game.layout, ui.c
    local hours, minutes, tod, day = hram(L.hours), hram(L.minutes), r8(L.timeOfDay), r8(L.day)
    local seconds = hram(L.seconds)
    if seconds >= 60 then seconds = 0 end
    local inBattle = game.battleMode == WILD_BATTLE or game.battleMode == TRAINER_BATTLE
    if hours < 24 and minutes < 60 then
        local now = (((day % 7) * 24 + hours) * 60 + minutes) * 60 + seconds
        local frames = frame_count()
        if not inBattle then
            game.clockAt = frames and {time = now, frames = frames} or nil
        elseif game.clockAt and frames then
            local passed = math.floor((frames - game.clockAt.frames) / FRAMES_PER_SECOND)
            if passed >= 0 and passed < 6 * 3600 then
                now = (game.clockAt.time + passed) % (7 * 86400)
                day, hours, minutes = now // 86400, now // 3600 % 24, now // 60 % 60
                -- MORN_HOUR 4, DAY_HOUR 10, NITE_HOUR 18
                tod = (hours >= 18 or hours < 4) and 2 or (hours >= 10 and 1 or 0)
            end
        end
    end
    local clock
    if hours < 24 and minutes < 60 then
        clock = string.format("%s  %02d:%02d  -  %s", DAYS[day % 7], hours, minutes, TIMES[math.min(tod, 2)] or "?")
    else
        clock = "Clock: not readable"
    end
    local played, playedMinutes = r16(L.playTime), r8(L.playTime + 2)
    local playTime = (played <= 999 and playedMinutes < 60) and string.format("     Played %d:%02d", played, playedMinutes) or ""
    set_text(c.clock, clock .. playTime)
    local surfing = SURFING[r8(L.playerState)] or false
    set_text(c.place, place_name(r8(L.mapGroup), r8(L.mapNumber)) .. (surfing and "  (surfing)" or ""))
end

local MOVE_WHY = {immune = "no effect", status = "status move", never = "not used", unknown = ""}

local function clear_moves()
    for slot = 1, 4 do
        for _, h in pairs(ui.c.moves[slot]) do set_text(h, "") end
    end
end

-- Your lead's moves outside battles: type, power, accuracy, PP.
local function show_lead_moves(lead)
    local c = ui.c
    set_text(c.movesHead, string.format("YOUR LEAD  -  %s Lv %d, HP %d/%d", species_name(lead.species):upper(),
        lead.level, lead.hp, lead.maxHP))
    for slot = 1, 4 do
        local row, info = c.moves[slot], lead.moves[slot] ~= 0 and MoveChoice.move_info(lead.moves[slot]) or nil
        if info then
            set_text(row.name, string.format("  %s (%d)", info.name, lead.pp[slot]))
            set_text(row.type, info.type)
            set_text(row.dmg, info.power and ("Power " .. info.power) or "")
            set_text(row.ko, "Acc " .. info.accuracy .. "%")
        elseif lead.moves[slot] ~= 0 then
            set_text(row.name, "  " .. move_name(lead.moves[slot]))
            set_text(row.type, ""); set_text(row.dmg, ""); set_text(row.ko, "")
        else
            for _, h in pairs(row) do set_text(h, "") end
        end
        set_color(row.name, Gui.THEME.text)
    end
    set_text(c.picks, "Holding: " .. item_name(lead.item))
end

-- In a battle: damage against the Pokemon facing you, and the picks.
local function show_battle_moves(a)
    local c = ui.c
    set_text(c.movesHead, string.format("YOUR MOVES  -  %s Lv %d, HP %d/%d", species_name(a.user.species):upper(),
        a.user.level, a.user.hp, a.user.maxHP))
    for slot = 1, 4 do
        local m, row = a.moves[slot], c.moves[slot]
        if m then
            set_text(row.name, string.format("%s%s (%d)", slot == a.kill and "> " or "  ", m.name, m.pp))
            set_text(row.type, m.type)
            local r = m.result
            if r then
                set_text(row.dmg, string.format("%d-%d (%d-%d%%)", r.low, r.high,
                    percent(r.low, a.target.maxHP), percent(r.high, a.target.maxHP)))
                -- Critical hits counted: "KO 0%" read as "can't", when a
                -- crit would do it.
                local ko = r.koCrit or r.ko
                local pct = math.floor(ko * 100 + 0.5)
                set_text(row.ko, r.hit == "false_swipe" and "never KOs"
                    or (pct == 0 and ko > 0) and "KO <1%" or string.format("KO %d%%", pct))
            else
                set_text(row.dmg, MOVE_WHY[m.why] or "")
                set_text(row.ko, "")
            end
            set_color(row.name, slot == a.kill and Gui.THEME.accent or Gui.THEME.text)
        else
            for _, h in pairs(row) do set_text(h, "") end
        end
    end
    local function pick_name(slot) return slot and a.moves[slot] and a.moves[slot].name or nil end
    set_text(c.picks, string.format("Knock out: %s     Weaken to catch: %s",
        pick_name(a.kill) or "no move hurts it", pick_name(a.weaken) or "nothing safe"))
end

local function set_visible(handle, visible)
    if ui.colors["v" .. tostring(handle)] ~= visible then
        pcall(forms.setproperty, handle, "Visible", visible)
        ui.colors["v" .. tostring(handle)] = visible
    end
end

-- Outside battles, in place of the Pokemon facing you: your party, 3 by 2.
local function show_party(on)
    local L, c = game.layout, ui.c
    for i = 1, 6 do set_visible(c.party[i], on) end
    for i = 1, 5 do set_visible(c.info[i], not on) end
    set_visible(c.itsHead, not on)
    for i = 1, 4 do for _, h in pairs(c.its[i]) do set_visible(h, not on) end end
    for _, line in ipairs(c.cardFrame) do set_visible(line.h, not on) end
    if not on then return end
    show_card(nil)
    pcall(forms.setproperty, c.card, "Visible", false)
    local count = r8(L.partyCount)
    if count > 6 then count = 0 end
    for i = 1, 6 do
        local text = ""
        if i <= count then
            local x, y = X + ((i - 1) % 3) * PARTY_STEP_X, ui.lay.cardY + ((i - 1) // 3) * PARTY_STEP_Y
            if r8(L.partyCount + i) == EGG then
                place_icon("egg", ICON_PARTY, x, y + 4, false)
                text = "Egg"
            else
                local mon = read_party_mon(L.partyMons + (i - 1) * PARTY_MON_SIZE)
                if plausible(mon) then
                    place_icon(mon.species, ICON_PARTY, x, y + 4, is_shiny(mon.dv1, mon.dv2))
                    text = string.format("%s\r\nLv %d\r\nHP %d/%d%s", species_name(mon.species), mon.level, mon.hp, mon.maxHP,
                        mon.hp == 0 and " KO" or "")
                end
            end
        end
        set_text(c.party[i], text)
    end
    if count == 0 then set_text(c.party[1], "No Pokemon yet.") end
end

-- The facing Pokemon's moves: how likely each is to be picked, and what it
-- does to you. A wild Pokemon picks at random among the moves it still has
-- PP for (ParseEnemyAction), so each of those is equally likely; a
-- trainer's is chosen by the trainer AI, which weighs the situation - no
-- fixed chance to show.
local function show_its_moves(base, mode, a)
    local c = ui.c
    if base == nil then
        set_text(c.itsHead, "")
        for i = 1, 4 do for _, h in pairs(c.its[i]) do set_text(h, "") end end
        return
    end
    local ids, pps, usable = {}, {}, 0
    for slot = 1, 4 do
        ids[slot], pps[slot] = r8(base + 1 + slot), r8(base + 7 + slot) % 64
        if ids[slot] ~= 0 and pps[slot] > 0 then usable = usable + 1 end
    end
    local wild = mode == WILD_BATTLE
    if wild and usable == 0 then
        set_text(c.itsHead, "ENEMY MOVES  -  Struggle")
    else
        set_text(c.itsHead, wild and "ENEMY MOVES  (random)" or "ENEMY MOVES  (AI)")
    end
    for slot = 1, 4 do
        local row, id = c.its[slot], ids[slot]
        if id == 0 then
            for _, h in pairs(row) do set_text(h, "") end
        else
            local chance = "-"
            if wild then chance = pps[slot] > 0 and string.format("%d%%", math.floor(100 / usable + 0.5)) or "0%" end
            set_text(row.chance, chance)
            set_text(row.name, move_name(id))
            -- Damage to you: a range, "status" for a move that doesn't hit,
            -- "-" for one that can't hurt you (immune, or unknown here).
            local t, info = a and a.threats[slot], MoveChoice.move_info(id)
            local dmg = ""
            if t and t.result then dmg = string.format("%d-%d", t.result.low, t.result.high)
            elseif info then dmg = info.power and "-" or "status" end
            set_text(row.dmg, dmg)
        end
    end
end

local function update_battle()
    local L, c = game.layout, ui.c
    local mode = game.battleMode
    local inBattle = mode == WILD_BATTLE or mode == TRAINER_BATTLE
    local mon, title
    show_party(not inBattle)
    if inBattle then
        mon = read_battle_mon(L.enemy)
        if not plausible(mon) then mon = nil end
        if mode == WILD_BATTLE then
            title = "WILD POKEMON"
        else
            local name = trainer_name()
            title = name ~= "" and ("TRAINER  " .. name:upper()) or "TRAINER BATTLE"
        end
    else
        title = "YOUR PARTY"
    end
    set_text(c.battleTitle, title)

    -- The Pokemon facing you.
    if not inBattle then
        -- (the party, above)
    elseif mon then
        local shiny = is_shiny(mon.dv1, mon.dv2)
        show_card(mon.species, shiny)
        set_text(c.info[1], string.format("%s  Lv %d%s", species_name(mon.species), mon.level, shiny and "  SHINY!" or ""))
        set_color(c.info[1], shiny and Gui.THEME.accent or Gui.THEME.header)
        set_text(c.info[2], string.format("HP %d/%d (%d%%)", mon.hp, mon.maxHP, percent(mon.hp, mon.maxHP)))
        set_text(c.info[3], string.format("DVs %d/%d/%d/%d", mon.dv1 // 16, mon.dv1 % 16, mon.dv2 // 16, mon.dv2 % 16))
        set_text(c.info[4], "Held item: " .. item_name(mon.item))
        local hpType, hpPower = MoveChoice.hidden_power(mon.dv1, mon.dv2)
        set_text(c.info[5], string.format("Hidden: %s %d", hpType or "?", hpPower or 0))
    else
        show_card(nil)
        for i = 1, 5 do set_text(c.info[i], "") end
    end

    -- Your Pokemon and its moves: against the target in a battle, your
    -- lead's otherwise.
    local a = (inBattle and mon) and MoveChoice.analyze({read8 = r8, own = L.own, enemy = L.enemy}) or nil
    show_its_moves(inBattle and mon and L.enemy or nil, mode, a)
    local yours = a and a.user or nil
    if a then
        show_battle_moves(a)
    else
        local lead = read_lead()
        yours = lead
        if lead then
            show_lead_moves(lead)
        else
            set_text(c.movesHead, "YOUR MOVES")
            clear_moves()
            set_text(c.moves[1].name, "  No Pokemon in your party yet.")
            set_color(c.moves[1].name, Gui.THEME.text)
            set_text(c.picks, "")
        end
    end

    -- A trainer's team.
    local count = mode == TRAINER_BATTLE and r8(L.otCount) or 0
    for i = 1, 6 do
        local x, text = X + (i - 1) * TEAM_STEP, ""
        if i <= count and count <= 6 then
            local species = r8(L.otSpecies + i - 1)
            local base = L.otMons + (i - 1) * PARTY_MON_SIZE
            local level, hp = r8(base + 31), r16(base + 34)
            if species >= 1 and species <= 251 and level >= 1 and level <= 100 then
                place_icon(species, ICON_TEAM, x, ui.lay.teamY, is_shiny(r8(base + 21), r8(base + 22)))
                text = string.format("Lv %d%s", level, hp == 0 and " KO" or "")
            end
        end
        set_text(c.team[i], text)
    end
    return yours
end

-- This map's fishing: per rod, the species and chances (Good and Super
-- Rod's time-of-day slot resolved for now). nil: no fishing here.
local function fishing_here(group, number, night)
    local F = game.fishing
    if F == nil or group < 1 or group > NUM_MAP_GROUPS or number < 1 then return nil end
    local header = word(F.maps, F.mapTable + 2 * (group - 1)) + MAP_HEADER * (number - 1)
    if group < NUM_MAP_GROUPS and header >= word(F.maps, F.mapTable + 2 * group) then return nil end
    local rods = F.groups[F.maps:byte(bank_pos(header) + 8) or 0]
    if rods == nil then return nil end
    local out = {}
    for rod = 1, 3 do
        local slots, odds, at, before = {}, {}, bank_pos(rods[rod]), 0
        for i = 1, ROD_ROWS[rod] do
            local upTo, species, level = F.fish:byte(at), F.fish:byte(at + 1), F.fish:byte(at + 2)
            if species == 0 then
                local tg = F.times + 4 * level + (night and 2 or 0)
                species, level = F.fish:byte(tg), F.fish:byte(tg + 1)
            end
            upTo = math.floor(upTo * 100 / 255 + 0.5)
            slots[i], odds[i] = {species = species, level = level}, upTo - before
            before = upTo
            at = at + 3
        end
        out[rod] = by_species(slots, 1, odds)
    end
    return out
end

-- Whether the map you're on has water to fish in. Nearly every map's header
-- names a fishing group - Shore by default, houses included - but the game
-- only fishes facing water. Read like the map section's picture (the map's
-- own blocks, not the 3-block border of the maps around it, through the
-- tileset's collisions): a $2x water value but ice ($23/$2B) and $28, or
-- a $3x current. Kept per map: in a battle the overworld blocks can't be
-- trusted, so it keeps the last answer (or says yes).
local function map_has_water(L, key)
    game.water = game.water or {}
    if game.battleMode ~= 0 then return game.water[key] ~= false end
    local w, h = r8(L.mapWidth), r8(L.mapHeight)
    local addr = r8(L.collAddr) + 256 * r8(L.collAddr + 1)
    if w < 1 or h < 1 or (w + 6) * (h + 6) > 1300 or addr < 0x4000 or addr >= 0x8000 then return true end
    local okB, blocks = pcall(memory.read_bytes_as_binary_string, L.mapBlocks - 0xC000, (w + 6) * (h + 6), "WRAM")
    local okC, coll = pcall(memory.read_bytes_as_binary_string, r8(L.collBank) * 0x4000 + addr - 0x4000, 1024, "ROM")
    if not okB or not okC or type(blocks) ~= "string" or type(coll) ~= "string" then return true end
    local found = false
    for row = 3, h + 2 do
        for col = 3, w + 2 do
            local block = blocks:byte(row * (w + 6) + col + 1)
            for q = 1, 4 do
                local c = block and block ~= 0 and coll:byte(block * 4 + q) or 0
                local hi = c // 16
                if (hi == 2 and c ~= 0x23 and c ~= 0x2B and c ~= 0x28) or hi == 3 then found = true break end
            end
            if found then break end
        end
        if found then break end
    end
    game.water[key] = found
    return found
end

-- One column: rows of {species, odds, low, high} or {head, color}.
local function show_column(col, entries)
    for i = 1, HERE_SLOTS do
        local e = entries and entries[i]
        if e and e.species then
            place_icon(e.species, ICON_HERE, col.x, ui.lay.hereY + (i - 1) * HERE_STEP)
            local levels = e.low == e.high and tostring(e.low) or (e.low .. "-" .. e.high)
            set_text(col.names[i], string.format("%s  Lv %s  %d%%", species_name(e.species), levels, e.odds))
        else
            set_text(col.heads[i], e and e.head or "")
            set_color(col.heads[i], e and e.color or Gui.THEME.text)
        end
        set_visible(col.names[i], e ~= nil and e.species ~= nil)
        set_visible(col.heads[i], e ~= nil and e.species == nil)
    end
end

local function heading(text) return {head = text, color = Gui.THEME.header} end

local function append(list, rows)
    for _, r in ipairs(rows) do list[#list + 1] = r end
    return list
end

local function update_here()
    local L, c = game.layout, ui.c
    local now = math.min(r8(L.timeOfDay), 2)
    local tod = ui.hereTime or now
    local group, number = r8(L.mapGroup), r8(L.mapNumber)
    local key = group .. ":" .. number
    set_text(c.hereTitle, "ENCOUNTER TABLE  -  " .. (TIMES[tod] or "?"):upper())
    for t = 0, 2 do
        local back = t == tod and Gui.THEME.selected or Gui.THEME.button
        local fore = t == now and Gui.THEME.accent or Gui.THEME.text
        if ui.colors["time" .. t] ~= back .. fore then
            pcall(forms.setproperty, c.hereTimes[t], "BackColor", back)
            pcall(forms.setproperty, c.hereTimes[t], "ForeColor", fore)
            ui.colors["time" .. t] = back .. fore
        end
    end
    local tab = ui.hereTab
    for _, t in ipairs(HERE_TABS) do
        local color = t.key == tab and Gui.THEME.selected or Gui.THEME.button
        if ui.colors["tab" .. t.key] ~= color then
            pcall(forms.setproperty, c.hereTabs[t.key], "BackColor", color)
            ui.colors["tab" .. t.key] = color
        end
    end

    local left, right
    local function none(text) left = {{head = text}} end
    if tab == "walk" or tab == "surf" then
        if game.wild == nil then
            none("Encounter tables not found in this game.")
        elseif tab == "walk" then
            local grass = game.wild.grass[key]
            if grass then left = by_species(grass, tod * 7 + 1, GRASS_ODDS) else none("No walking encounters here.") end
        else
            local water = game.wild.water[key]
            if water then left = by_species(water, 1, WATER_ODDS) else none("No surfing encounters here.") end
        end
    elseif tab == "fish" then
        local rods = game.fishing and fishing_here(group, number, tod == 2)
        if game.fishing == nil then
            none("Fishing tables not found in this game.")
        elseif rods == nil or not map_has_water(L, key) then
            none("No water to fish in here.")
        else
            left = append(append(append({heading(ROD_NAMES[1])}, rods[1]), {heading(ROD_NAMES[2])}), rods[2])
            right = append({heading(ROD_NAMES[3])}, rods[3])
        end
    elseif tab == "tree" then
        local T = game.trees
        local set = T and T.sets[T.mapSets[key] or 0]
        if T == nil then
            none("Headbutt tables not found in this game.")
        elseif set == nil then
            none("No headbutt trees here.")
        else
            local function merged(rows)
                local odds = {}
                for i, r in ipairs(rows) do odds[i] = r.odds end
                return by_species(rows, 1, odds)
            end
            left = append({heading("Common trees")}, merged(set.common))
            right = append({heading("Rare trees")}, merged(set.rare))
        end
    end
    show_column(c.hereCols[1], left)
    show_column(c.hereCols[2], right)

    -- The roaming legendaries, an icon each.
    local roamers = {}
    if tab == "roam" then
        for i = 0, 2 do
            local base = L.roamers + 7 * i
            local species, level, g, n = r8(base), r8(base + 1), r8(base + 2), r8(base + 3)
            if ROAMER_SPECIES[species] and level >= 1 and level <= 100 and g ~= 0 and g ~= 0xFF then
                local here = (g .. ":" .. n) == key
                roamers[#roamers + 1] = {species = species, text = string.format("%s  Lv %d  -  %s%s", species_name(species),
                    level, place_name(g, n), here and "  HERE!" or ""), here = here}
            end
        end
        if #roamers == 0 then show_column(c.hereCols[1], {{head = "No Pokemon roaming right now."}}) end
    end
    for i, lbl in ipairs(c.roamRows) do
        local r = roamers[i]
        if r then
            place_icon(r.species, ICON_HERE, X, ui.lay.hereY + (i - 1) * HERE_STEP)
            set_text(lbl, r.text)
            set_color(lbl, r.here and Gui.THEME.accent or Gui.THEME.text)
        end
        set_visible(lbl, r ~= nil)
    end
end

-- The bottom list: the level-up moves of your Pokemon (the one fighting
-- in a battle, your lead otherwise) - the last two it learned and what's
-- next.
local function update_list(pokemon)
    local c = ui.c
    local moves = pokemon and learnset(pokemon.species)
    if pokemon == nil or moves == nil then
        set_text(c.listTitle, "LEVEL-UP MOVES")
        for i = 1, LIST_LINES do
            set_text(c.list[i], i == 1 and (pokemon and "Not readable in this game." or "No Pokemon in your party yet.") or "")
            set_color(c.list[i], Gui.THEME.text)
        end
        return
    end
    set_text(c.listTitle, string.format("LEVEL-UP MOVES  -  %s Lv %d", species_name(pokemon.species):upper(), pokemon.level))
    local nextIndex = #moves + 1
    for i, m in ipairs(moves) do
        if m.level > pokemon.level then
            nextIndex = i
            break
        end
    end
    local first = math.max(1, math.min(nextIndex - 2, #moves - LIST_LINES + 1))
    for i = 1, LIST_LINES do
        local m = moves[first + i - 1]
        if m then
            local info = MoveChoice.move_info(m.move)
            local learned = m.level <= pokemon.level
            set_text(c.list[i], string.format("Lv %-3d  %s%s%s", m.level, info and info.name or move_name(m.move),
                info and ("  (" .. info.type .. (info.power and (", power " .. info.power) or "") .. ")") or "",
                learned and "  - learned" or ""))
            set_color(c.list[i], learned and Gui.THEME.frameDark or Gui.THEME.text)
        else
            set_text(c.list[i], i == 1 and "Learns nothing more by leveling up." or "")
            set_color(c.list[i], Gui.THEME.text)
        end
    end
end

-- ===== The map around you =====

local update_map, toggle_map_zoom -- below (a click on the map calls back in)

-- What each collision value (constants/collision_constants.asm) looks
-- like, by its high nybble and then the odd ones out.
local MAP_COLORS = {
    floor = "#E8DCB0", wall = "#59616B", grass = "#5FB35F", tree = "#2F7A34", headbutt = "#1F5A24",
    water = "#4C8FD6", ice = "#BFE6F5", ledge = "#A87A40", warp = "#E0503C", furniture = "#8C7356",
    pit = "#30302F", outside = "#1E1E1E",
}

local function collision_color(c)
    if c == 0x00 then return MAP_COLORS.floor end
    if c == 0xFF then return MAP_COLORS.outside end
    local hi = c // 16
    if hi == 0x0 then return MAP_COLORS.wall end
    if hi == 0x1 then
        if c == 0x15 or c == 0x1D then return MAP_COLORS.headbutt end
        if c == 0x12 or c == 0x1A or c == 0x08 then return MAP_COLORS.tree end
        return MAP_COLORS.grass
    end
    if hi == 0x2 then
        if c == 0x23 or c == 0x2B then return MAP_COLORS.ice end
        if c == 0x28 then return MAP_COLORS.tree end
        return MAP_COLORS.water
    end
    if hi == 0x3 or hi == 0xC then return MAP_COLORS.water end
    if hi == 0x6 then return MAP_COLORS.pit end
    if hi == 0x7 then return MAP_COLORS.warp end
    if hi == 0x9 then return MAP_COLORS.furniture end
    if hi == 0xA then return MAP_COLORS.ledge end
    return MAP_COLORS.floor -- spinners, one-sided walls
end

-- The current map's blocks and collision data (nil when they don't read
-- right).
local function read_map(L)
    local w, h = r8(L.mapWidth), r8(L.mapHeight)
    if w < 1 or h < 1 or (w + 6) * (h + 6) > 1300 then return nil end
    local addr = r8(L.collAddr) + 256 * r8(L.collAddr + 1)
    if addr < 0x4000 or addr >= 0x8000 then return nil end
    local okB, blocks = pcall(memory.read_bytes_as_binary_string, L.mapBlocks - 0xC000, (w + 6) * (h + 6), "WRAM")
    local okC, coll = pcall(memory.read_bytes_as_binary_string, r8(L.collBank) * 0x4000 + addr - 0x4000, 1024, "ROM")
    if not okB or not okC or type(blocks) ~= "string" or type(coll) ~= "string" then return nil end
    return {blocks = blocks, coll = coll, w = w, cols = 2 * w, rows = 2 * h,
        fit = math.max(1, math.min(8, W // (2 * w), MAP_AREA_H // (2 * h)))}
end

local function map_color(data, col, row)
    local block = data.blocks:byte((row // 2 + 3) * (data.w + 6) + col // 2 + 3 + 1)
    local c = 0xFF
    if block and block ~= 0 then c = data.coll:byte(block * 4 + col % 2 + 2 * (row % 2) + 1) or 0xFF end
    return collision_color(c)
end

-- Paints the map's cells from (c0, r0), ncols x nrows of them, into a
-- picturebox - a row at a time, one rectangle per run of one color.
local function paint_map(box, data, c0, r0, ncols, nrows, cell)
    pcall(forms.clear, box, MAP_COLORS.outside)
    for row = 0, nrows - 1 do
        local runStart, runColor = 0, nil
        for col = 0, ncols do
            local color = col < ncols and map_color(data, c0 + col, r0 + row) or nil
            if color ~= runColor then
                if runColor then
                    pcall(forms.drawRectangle, box, runStart * cell, row * cell, (col - runStart) * cell, cell, runColor, runColor)
                end
                runStart, runColor = col, color
            end
        end
    end
    pcall(forms.refresh, box)
end

-- Two ways to show a map. Whole: all of it, scaled to fit, drawn once.
-- Close-up: MAP_ZOOM_CELL px a tile, a window of it around you, drawn again
-- when you walk near its edge. A long route (Route 32 is 10 x 45 blocks)
-- fits only at 1px a tile, so it starts close-up; a click on the map
-- switches.
local MAP_ZOOM_CELL, MAP_MIN_CELL, MAP_EDGE = 6, 4, 4

local function map_view(entry, zoomed)
    local data = entry.data
    if not zoomed then
        if entry.whole == nil then
            local cell = data.fit
            local ox, dy = X + (W - data.cols * cell) // 2, (MAP_AREA_H - data.rows * cell) // 2
            local box = forms.pictureBox(ui.form, ox, ui.lay.mapY + dy + ui.scroll, data.cols * cell, data.rows * cell)
            paint_map(box, data, 0, 0, data.cols, data.rows, cell)
            pcall(forms.addclick, box, toggle_map_zoom)
            entry.whole = {box = box, ox = ox, dy = dy, cell = cell, c0 = 0, r0 = 0, ncols = data.cols, nrows = data.rows}
        end
        return entry.whole
    end
    if entry.close == nil then
        local cell = MAP_ZOOM_CELL
        local ncols, nrows = math.min(data.cols, W // cell), math.min(data.rows, MAP_AREA_H // cell)
        local ox, dy = X + (W - ncols * cell) // 2, (MAP_AREA_H - nrows * cell) // 2
        local box = forms.pictureBox(ui.form, ox, ui.lay.mapY + dy + ui.scroll, ncols * cell, nrows * cell)
        pcall(forms.addclick, box, toggle_map_zoom)
        entry.close = {box = box, ox = ox, dy = dy, cell = cell, ncols = ncols, nrows = nrows}
    end
    return entry.close
end

-- Close-up: the window moves so you're in its middle again once you get
-- within MAP_EDGE tiles of a side that has more map past it.
local function window_start(pos, size, total, cur)
    if cur ~= nil then
        local nearLow = pos < cur + MAP_EDGE and cur > 0
        local nearHigh = pos >= cur + size - MAP_EDGE and cur < total - size
        local inside = pos >= cur and pos < cur + size
        if inside and not nearLow and not nearHigh then return cur end
    end
    return math.max(0, math.min(total - size, pos - size // 2))
end

local function follow(view, data, x, y)
    local c0, r0 = window_start(x, view.ncols, data.cols, view.c0), window_start(y, view.nrows, data.rows, view.r0)
    if c0 ~= view.c0 or r0 ~= view.r0 then
        view.c0, view.r0 = c0, r0
        paint_map(view.box, data, c0, r0, view.ncols, view.nrows, view.cell)
    end
end

local function zoomed_for(entry)
    if ui.mapZoom ~= nil then return ui.mapZoom end
    return entry.data.fit < MAP_MIN_CELL
end

-- A click on the map: whole <-> close-up (for every map from then on).
toggle_map_zoom = function()
    local m = ui.map
    local entry = m and m.key and m.entries[m.key]
    if not entry then return end
    ui.mapZoom = not zoomed_for(entry)
    m.dotX, m.dotY = nil, nil
    update_map()
end

update_map = function()
    local L, c, m = game.layout, ui.c, ui.map
    local group, number = r8(L.mapGroup), r8(L.mapNumber)
    set_text(c.mapTitle, "MAP  -  " .. place_name(group, number))
    -- In a battle the overworld's blocks aren't to be trusted: keep the map.
    if game.battleMode ~= 0 then return end
    local key = table.concat({group, number, r8(L.mapWidth), r8(L.mapHeight), r8(L.collBank), r8(L.collAddr), r8(L.collAddr + 1)}, ":")
    if key ~= m.key then m.key, m.stable = key, 0 end
    m.stable = m.stable + 1
    local entry = m.entries[key]
    -- Only once the map has held still for a moment (it's rebuilt while
    -- you walk through a door or a connection).
    if entry == nil and m.stable >= 3 then
        local data = read_map(L)
        entry = data and {data = data} or false
        m.entries[key] = entry
    end
    local view = entry and map_view(entry, zoomed_for(entry)) or nil
    local x, y = r8(L.xCoord), r8(L.yCoord)
    local onMap = entry and x < entry.data.cols and y < entry.data.rows
    if view and onMap and view == entry.close then follow(view, entry.data, x, y) end
    for _, e in pairs(m.entries) do
        if e then
            if e.whole then set_visible(e.whole.box, e.whole == view) end
            if e.close then set_visible(e.close.box, e.close == view) end
        end
    end
    if view and onMap and x >= view.c0 and x < view.c0 + view.ncols and y >= view.r0 and y < view.r0 + view.nrows then
        local dx = view.ox + (x - view.c0) * view.cell + view.cell // 2 - 3
        local dy = ui.lay.mapY + view.dy + (y - view.r0) * view.cell + view.cell // 2 - 3
        if m.dotX ~= dx or m.dotY ~= dy then
            forms.setlocation(c.mapDot, dx, dy + ui.scroll)
            m.dotX, m.dotY = dx, dy
        end
        set_visible(c.mapDot, true)
    else
        set_visible(c.mapDot, false)
    end
end

-- How far the window is scrolled down. WinForms places a control in the
-- scrolled view's coordinates, so everything placed after the window is
-- built adds this (the clock label sits at content y 12 - stats_window.lua
-- does the same).
local function scroll_offset()
    local top = ui.c.clock and tonumber(forms.getproperty(ui.c.clock, "Top"))
    return top and (top - 12) or 0
end

local function update()
    if ui.form == nil then return end
    ui.scroll = scroll_offset()
    if game.layout == nil then
        set_text(ui.c.clock, "Game Assistant supports Crystal, Gold and Silver (English/European).")
        return
    end
    begin_icons()
    update_clock_and_place()
    local open = {}
    for _, s in ipairs(SECTIONS) do open[s.key] = not ui.closed[s.key] end
    local yours
    if open.party then
        yours = update_battle()
    else
        -- The level-up moves still need to know whose.
        local inBattle = game.battleMode == WILD_BATTLE or game.battleMode == TRAINER_BATTLE
        local a = inBattle and MoveChoice.analyze({read8 = r8, own = game.layout.own, enemy = game.layout.enemy}) or nil
        yours = a and a.user or read_lead()
    end
    if open.here then update_here() end
    if open.moves then update_list(yours) end
    if open.map then update_map() end
    end_icons()
end

local function safe_update()
    local ok, err = pcall(update)
    if not ok and not ui.warned then
        ui.warned = true
        print("Game Assistant: update failed (" .. tostring(err) .. ") - close and reopen it.")
    end
end

-- One open section's controls, from its frame's top.
local function build_section(key, top)
    local c, form = ui.c, ui.form
    if key == "party" then
        -- The battle: the Pokemon facing you (your party outside battles),
        -- then yours.
        local cardY = top + 28
        ui.lay.cardY, ui.lay.teamY = cardY, top + 278
        c.battleTitle = label(X, top + 8, W - 28, 16, true)
        c.card = track(forms.label(form, "", CARD_X, cardY + CARD_DY, CARD_BOX, CARD_BOX), CARD_X, cardY + CARD_DY)
        pcall(forms.setproperty, c.card, "BackColor", CARD_WHITE)
        c.cardFrame = frame_lines(CARD_X - 4, cardY + CARD_DY - 4, CARD_BOX + 8, CARD_BOX + 8)
        for _, line in ipairs(c.cardFrame) do track(line.h, line.x, line.y) end
        c.info = {}
        for i = 1, 5 do c.info[i] = label(X + CARD_SIZE + 8, cardY + (i - 1) * 18, i == 1 and INFO_NAME_W or INFO_W, 16, i == 1) end
        -- Its moves, right of that: a heading, then per move the chance it
        -- gets picked, its name and its damage to you.
        c.itsHead = label(ITS_NAME_X, cardY, X + W - ITS_NAME_X, 16, true)
        c.its = {}
        for i = 1, 4 do
            local y = cardY + i * 18
            c.its[i] = {chance = label(ITS_X, y, ITS_CHANCE_W, 16), name = label(ITS_NAME_X, y, ITS_NAME_W, 16),
                dmg = label(ITS_NAME_X + ITS_NAME_W, y, ITS_DMG_W, 16)}
        end
        c.party = {}
        for i = 1, 6 do
            c.party[i] = label(X + ((i - 1) % 3) * PARTY_STEP_X + ICON_PARTY + 4, cardY + ((i - 1) // 3) * PARTY_STEP_Y + 2,
                PARTY_STEP_X - ICON_PARTY - 8, 46)
        end
        c.movesHead = label(X, top + 134, W, 16, true)
        c.moves = {}
        for slot = 1, 4 do
            local y = top + 152 + (slot - 1) * 18
            c.moves[slot] = {name = label(X, y, 150, 16), type = label(X + 152, y, 62, 16),
                dmg = label(X + 216, y, 120, 16), ko = label(X + 338, y, 78, 16)}
        end
        c.picks = label(X, top + 226, W, 16)
        c.team = {}
        for i = 1, 6 do c.team[i] = label(X + (i - 1) * TEAM_STEP, top + 308, TEAM_STEP - 3, 14) end
    elseif key == "here" then
        local hereY = top + HERE_LIST_Y
        ui.lay.hereY = hereY
        local timesX = X + W - 26 - 3 * TIME_BUTTON_W - 6
        c.hereTitle = label(X, top + 8, timesX - X - 4, 16, true)
        -- Morning / Day / Night: the one shown (now, unless you pick
        -- another) highlighted, the time it is now in orange.
        c.hereTimes = {}
        for tod = 0, 2 do
            local bx = timesX + tod * (TIME_BUTTON_W + 3)
            local b = forms.button(form, TIMES[tod], function() M.select_here_time(tod) end, bx, top + 4, TIME_BUTTON_W, 22)
            Gui.style_button(b)
            c.hereTimes[tod] = track(b, bx, top + 4)
        end
        c.hereTabs = {}
        local tabW = (W - 4 * (#HERE_TABS - 1)) // #HERE_TABS
        for i, tab in ipairs(HERE_TABS) do
            local bx = X + (i - 1) * (tabW + 4)
            local b = forms.button(form, tab.name, function() M.select_here_tab(tab.key) end, bx, top + HERE_TABS_Y, tabW, 22)
            Gui.style_button(b)
            c.hereTabs[tab.key] = track(b, bx, top + HERE_TABS_Y)
        end
        -- Two columns of rows: a species (its icon goes left of the name) or
        -- a heading.
        c.hereCols = {}
        for col, cx in ipairs({X, SURF_X}) do
            local colW = col == 1 and SURF_X - X - 6 or X + W - SURF_X
            local entry = {x = cx, heads = {}, names = {}}
            for i = 1, HERE_SLOTS do
                local y = hereY + 4 + (i - 1) * HERE_STEP
                entry.heads[i] = label(cx, y, colW, 16)
                entry.names[i] = label(cx + ICON_HERE + 4, y, colW - ICON_HERE - 4, 16)
            end
            c.hereCols[col] = entry
        end
        -- The roaming legendaries: full-width rows, an icon each.
        c.roamRows = {}
        for i = 1, 3 do c.roamRows[i] = label(X + ICON_HERE + 4, hereY + 4 + (i - 1) * HERE_STEP, W - ICON_HERE - 4, 16) end
    elseif key == "moves" then
        c.listTitle = label(X, top + 8, W - 28, 16, true)
        c.list = {}
        for i = 1, LIST_LINES do c.list[i] = label(X, top + 28 + (i - 1) * 17, W, 16) end
    elseif key == "map" then
        -- The dot comes first, so it's in front of the map pictures made
        -- later (WinForms puts later controls behind earlier ones).
        local mapY = top + 28
        ui.lay.mapY = mapY
        c.mapTitle = label(X, top + 8, W - 28, 16, true)
        c.mapDot = track(forms.pictureBox(form, X, mapY, 6, 6), X, mapY, true)
        pcall(forms.clear, c.mapDot, "#FF2020")
        pcall(forms.drawRectangle, c.mapDot, 0, 0, 5, 5, "#000000")
        pcall(forms.refresh, c.mapDot)
        pcall(forms.setproperty, c.mapDot, "Visible", false)
    end
end

-- Places every section below the last - an open one with its contents and
-- full frame, a folded one as just its title row - and sizes the window to
-- them. Nothing is rebuilt: controls only move and show or hide.
local function relayout()
    -- Placed in the scrolled view's coordinates (see scroll_offset()).
    ui.scroll = scroll_offset()
    local top = 58
    for _, s in ipairs(SECTIONS) do
        local sec, open = ui.sections[s.key], not ui.closed[s.key]
        if not open and s.key == "party" then show_card(nil) end
        for _, item in ipairs(sec.items) do
            local always = item.h == sec.title or item.h == sec.toggle
            if not item.fixed and item.y ~= top + item.dy then
                forms.setlocation(item.h, item.x, top + item.dy + ui.scroll)
                item.y = top + item.dy
            end
            if item.h == ui.c.card then
                -- The sprite code decides on the white card (it sits in front
                -- of the sprites); shownCard = false makes it decide afresh.
                if not open then
                    pcall(forms.setproperty, item.h, "Visible", false)
                    ui.shownCard = false
                end
            elseif not always then
                set_visible(item.h, open and (item.h ~= ui.c.mapDot))
            end
        end
        for _, frame in ipairs({{sec.frameOpen, open}, {sec.frameClosed, not open}}) do
            for _, line in ipairs(frame[1]) do
                if line.top ~= top then
                    forms.setlocation(line.h, line.x, line.y - sec.top0 + top + ui.scroll)
                    line.top = top
                end
                set_visible(line.h, frame[2])
            end
        end
        forms.settext(sec.toggle, open and "-" or "+")
        if not open then forms.settext(sec.title, s.title) end
        sec.top = top
        top = top + (open and s.height or CLOSED_H) + SECTION_GAP
    end
    local secs = ui.sections
    ui.lay.cardY, ui.lay.teamY = secs.party.top + 28, secs.party.top + 278
    ui.lay.hereY, ui.lay.mapY = secs.here.top + HERE_LIST_Y, secs.map.top + 28
    -- The map pictures move with their section; the dot is placed again.
    for _, entry in pairs(ui.map.entries) do
        for _, v in ipairs({entry and entry.whole or false, entry and entry.close or false}) do
            if v then
                forms.setlocation(v.box, v.ox, ui.lay.mapY + v.dy + ui.scroll)
                if ui.closed.map then set_visible(v.box, false) end
            end
        end
    end
    ui.map.dotX, ui.map.dotY = nil, nil
    -- No height of its own past the first: docked, arrange_windows.ps1
    -- makes it as tall as the launcher, and it scrolls by mouse wheel - the
    -- helper keeps its scroll bars hidden. It opens at its content's
    -- height, up to 900px.
    if not ui.sized then
        ui.sized = true
        forms.setsize(ui.form, FORM_W, math.min(top - SECTION_GAP + 8 + 39, 900))
    end
end

local function build()
    if ui.closed == nil then
        ui.closed = {}
        local saved = GuiSettings and GuiSettings.get_text and GuiSettings.get_text("gacollapsed") or ""
        for key in (saved or ""):gmatch("[%a]+") do ui.closed[key] = true end
    end
    local form = forms.newform(FORM_W, 400, TITLE, function()
        -- Only drop our own handles here (see gui_module.lua's onclose notes).
        ui.form, ui.c, ui.texts, ui.colors, ui.cards, ui.shownCard, ui.icons = nil, {}, {}, {}, {}, false, {}
    end)
    ui.form, ui.c, ui.texts, ui.colors, ui.cards, ui.shownCard, ui.icons = form, {}, {}, {}, {}, false, {}
    -- Hidden while it's built (a shown window repaints for every control as
    -- it arrives); shown at the end, complete. Same as the settings popups.
    pcall(forms.setproperty, form, "Visible", false)
    ui.map = {key = nil, stable = 0, entries = {}}
    ui.warned, ui.detached, ui.sized = false, false, false
    if ui.hereTab == nil then
        local saved = GuiSettings and GuiSettings.get_text and GuiSettings.get_text("gatab")
        ui.hereTab = "walk"
        for _, tab in ipairs(HERE_TABS) do
            if tab.key == saved then ui.hereTab = saved end
        end
    end
    Gui.style_window(form)
    ui.scroll = 0
    local c = ui.c

    -- The clock and the place, and Detach / Attach.
    c.clock = label(X, 12, W - 76, 16, true)
    c.place = label(X, 30, W - 76, 16)
    c.dock = forms.button(form, "Detach", toggle_detached, X + W - 70, 13, 70, 24)
    Gui.style_button(c.dock)
    Gui.draw_frame_fast(form, PX, 4, PW, 44)

    -- Every section is built open, all of them stacked; relayout() then
    -- folds and places them.
    local top = 58
    ui.lay, ui.sections = {}, {}
    local titles = {party = "battleTitle", here = "hereTitle", moves = "listTitle", map = "mapTitle"}
    for _, s in ipairs(SECTIONS) do
        local sec = {top0 = top, items = {}}
        ui.sections[s.key] = sec
        ui.building = sec
        sec.toggle = track(forms.button(form, "-", function() M.toggle_section(s.key) end, X + W - 22, top + 6, 22, 20), X + W - 22, top + 6)
        Gui.style_button(sec.toggle)
        build_section(s.key, top)
        sec.title = c[titles[s.key]]
        ui.building = nil
        sec.frameOpen = frame_lines(PX, top, PW, s.height)
        sec.frameClosed = frame_lines(PX, top, PW, CLOSED_H)
        top = top + s.height + SECTION_GAP
    end
    relayout()
    safe_update()
    -- Scrolls by mouse wheel (the helper hides the bars - see relayout()).
    -- Only now, once everything's in: with it on, every control added made
    -- WinForms work out the scroll range again (and the helper hide the bar
    -- again) - the window took seconds to open.
    pcall(forms.setproperty, form, "AutoScroll", true)
    pcall(forms.setproperty, form, "Visible", true)
end

-- A section's -/+ button: folds or opens it right there, and remembers it.
function M.toggle_section(key)
    if ui.form == nil then return end
    ui.closed[key] = not ui.closed[key] or nil
    local keys = {}
    for _, s in ipairs(SECTIONS) do
        if ui.closed[s.key] then keys[#keys + 1] = s.key end
    end
    if GuiSettings and GuiSettings.set then
        pcall(GuiSettings.set, "gacollapsed", table.concat(keys, ","))
        pcall(GuiSettings.save)
    end
    relayout()
    safe_update()
end

-- A time-of-day button: shows that time's encounters; the time it is now
-- goes back to following the clock.
function M.select_here_time(tod)
    if ui.form == nil or game.layout == nil then return end
    ui.hereTime = tod ~= math.min(r8(game.layout.timeOfDay), 2) and tod or nil
    safe_update()
end

-- An ENCOUNTER TABLE tab: shows it, and remembers it.
function M.select_here_tab(key)
    if ui.form == nil then return end
    ui.hereTab = key
    if GuiSettings and GuiSettings.set then
        pcall(GuiSettings.set, "gatab", key)
        pcall(GuiSettings.save)
    end
    safe_update()
end

-- The launcher's "Game Assistant" button. rootDir: the bot's folder (for the
-- sprites). Opening it while it's open does nothing.
function M.open(rootDir)
    ui.rootDir = rootDir or ui.rootDir
    if ui.form ~= nil then return end
    build()
end

-- From gui_module.lua's update_last_encounter(), the one place every module
-- shows an encounter: listed when the enemy's battle struct holds that very
-- Pokemon right now - which leaves out eggs and starters shown on the same
-- card.
function M.note_encounter(species, atk, def, spe, spc)
    if game.layout == nil then return end
    local mon = read_battle_mon(game.layout.enemy)
    if plausible(mon) and mon.species == species and mon.dv1 == atk * 16 + def and mon.dv2 == spe * 16 + spc then
        record(mon)
        -- Redrawn right here: the bot handles a whole battle (flee, catch,
        -- Kill mode) inside one step, and M.tick() only runs between steps -
        -- so the window used to catch up once the battle was over.
        if ui.form and game.dirty then
            poll()
            game.dirty = false
            safe_update()
        end
    end
end

-- Every frame from launcher.lua's main loop, open or not - so the last wild
-- Pokemon is known when the window opens. Cheap: a few reads a frame; the
-- window itself refreshes 4 times a second, or right away when a battle
-- starts or ends or a new wild Pokemon turns up.
-- launcher.lua's shared HUD, for its Current/Recent Encounters.
function M.attach(hud)
    launcher.hud = hud
end

function M.tick(romLoaded, moduleRunning)
    if not romLoaded then return end
    launcher.running = moduleRunning == true
    game.ticks = game.ticks + 1
    if game.romHash == nil or game.ticks % 120 == 0 then refresh_game() end
    poll()
    local mon = game.toLauncher
    if mon and launcher.hud then
        game.toLauncher = nil
        launcher.count = launcher.count + 1
        pcall(Gui.update_last_encounter, launcher.hud, launcher.count, mon.species, species_name(mon.species),
            mon.dv1 // 16, mon.dv1 % 16, mon.dv2 // 16, mon.dv2 % 16, is_shiny(mon.dv1, mon.dv2),
            mon.item == 0 and "(no item)" or item_name(mon.item))
    end
    if ui.form and (game.dirty or game.ticks % 15 == 0) then
        game.dirty = false
        safe_update()
    end
end

return M

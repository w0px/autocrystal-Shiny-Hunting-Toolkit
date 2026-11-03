-- move_choice.lua (lives in data/)
-- Which of the active Pokemon's 4 moves to use, instead of always move 1:
--   M.weaken(view, opts) - auto-catch's weakening: the move that takes the
--     most HP while even its highest roll, a critical hit included, can't
--     knock the target out (opts.ignoreCrits: Advanced Settings' crit
--     override - only the normal highest roll counts). nil once no move can
--     do that any more: time for the balls.
--   M.kill(view) - Kill mode: the best chance to knock it out this turn,
--     else the most damage. nil when no move can hurt it at all.
-- view: {read8 = function(addr), own = wBattleMon, enemy = wEnemyMon} - the
-- two battle structs (pokecrystal's battle_struct, macros/ram.asm).
--
-- The damage is worked out the way the game does it (pokecrystal's
-- engine/battle/effect_commands.asm): BattleCommand_DamageCalc, then
-- BattleCommand_Stab (weather, badge boost, STAB, the type chart, row by
-- row), then BattleCommand_DamageVariation (x217-255/255). Power, type,
-- accuracy and effect come from the game's own move table in ROM bank $10,
-- found by its first entries - the same table in Crystal, Gold/Silver and
-- the Japanese games. Where it isn't found, M.available() is false and the
-- modules use move 1 (move 2 once 1 is out of PP) as before.
--
-- What it can't read, weakening takes at its worst: a badge's type boost
-- (x1.125), a type-boosting held item (x1.1 for any held item), rain or sun
-- (x1.5, only if the target knows Rain Dance or Sunny Day), and a critical
-- hit's stats from before any stat changes (the first look at each Pokemon
-- in a battle). A hit that still takes more than it worked out (the
-- target's own recoil can do that too) puts that encounter back on the old
-- rule - see check_last_hit().

local M = {}

local BANK = 0x10
local FIRST_MOVES = "01 00 28 00 ?? 23 00 02 00 32 01 ?? 19 00 03 1D 0F 00 ?? 0A 00"
local NUM_MOVES, MOVE_LENGTH = 251, 7

-- constants/type_constants.asm. Below SPECIAL: physical.
local NORMAL, FIGHTING, FLYING, POISON, GROUND, ROCK, BUG, GHOST, STEEL =
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x07, 0x08, 0x09
local FIRE, WATER, GRASS, ELECTRIC, PSYCHIC, ICE, DRAGON, DARK =
    0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B
local SPECIAL = 0x14
-- Hidden Power's type by 4 * (Atk DV & 3) + (Def DV & 3) (hidden_power.asm).
local HIDDEN_POWER_TYPES = {FIGHTING, FLYING, POISON, GROUND, ROCK, BUG, GHOST, STEEL,
    FIRE, WATER, GRASS, ELECTRIC, PSYCHIC, ICE, DRAGON, DARK}

-- data/types/type_matchups.asm in its own order, which matters: each row
-- floors the damage in turn. Attacker, defender, multiplier in tenths. The
-- last two (Ghost's immunities) only Foresight lifts.
local SE, NVE, NO = 20, 5, 0
local MATCHUPS = {
    {NORMAL, ROCK, NVE}, {NORMAL, STEEL, NVE},
    {FIRE, FIRE, NVE}, {FIRE, WATER, NVE}, {FIRE, GRASS, SE}, {FIRE, ICE, SE}, {FIRE, BUG, SE},
    {FIRE, ROCK, NVE}, {FIRE, DRAGON, NVE}, {FIRE, STEEL, SE},
    {WATER, FIRE, SE}, {WATER, WATER, NVE}, {WATER, GRASS, NVE}, {WATER, GROUND, SE}, {WATER, ROCK, SE},
    {WATER, DRAGON, NVE},
    {ELECTRIC, WATER, SE}, {ELECTRIC, ELECTRIC, NVE}, {ELECTRIC, GRASS, NVE}, {ELECTRIC, GROUND, NO},
    {ELECTRIC, FLYING, SE}, {ELECTRIC, DRAGON, NVE},
    {GRASS, FIRE, NVE}, {GRASS, WATER, SE}, {GRASS, GRASS, NVE}, {GRASS, POISON, NVE}, {GRASS, GROUND, SE},
    {GRASS, FLYING, NVE}, {GRASS, BUG, NVE}, {GRASS, ROCK, SE}, {GRASS, DRAGON, NVE}, {GRASS, STEEL, NVE},
    {ICE, WATER, NVE}, {ICE, GRASS, SE}, {ICE, ICE, NVE}, {ICE, GROUND, SE}, {ICE, FLYING, SE},
    {ICE, DRAGON, SE}, {ICE, STEEL, NVE}, {ICE, FIRE, NVE},
    {FIGHTING, NORMAL, SE}, {FIGHTING, ICE, SE}, {FIGHTING, POISON, NVE}, {FIGHTING, FLYING, NVE},
    {FIGHTING, PSYCHIC, NVE}, {FIGHTING, BUG, NVE}, {FIGHTING, ROCK, SE}, {FIGHTING, DARK, SE}, {FIGHTING, STEEL, SE},
    {POISON, GRASS, SE}, {POISON, POISON, NVE}, {POISON, GROUND, NVE}, {POISON, ROCK, NVE}, {POISON, GHOST, NVE},
    {POISON, STEEL, NO},
    {GROUND, FIRE, SE}, {GROUND, ELECTRIC, SE}, {GROUND, GRASS, NVE}, {GROUND, POISON, SE}, {GROUND, FLYING, NO},
    {GROUND, BUG, NVE}, {GROUND, ROCK, SE}, {GROUND, STEEL, SE},
    {FLYING, ELECTRIC, NVE}, {FLYING, GRASS, SE}, {FLYING, FIGHTING, SE}, {FLYING, BUG, SE}, {FLYING, ROCK, NVE},
    {FLYING, STEEL, NVE},
    {PSYCHIC, FIGHTING, SE}, {PSYCHIC, POISON, SE}, {PSYCHIC, PSYCHIC, NVE}, {PSYCHIC, DARK, NO}, {PSYCHIC, STEEL, NVE},
    {BUG, FIRE, NVE}, {BUG, GRASS, SE}, {BUG, FIGHTING, NVE}, {BUG, POISON, NVE}, {BUG, FLYING, NVE},
    {BUG, PSYCHIC, SE}, {BUG, GHOST, NVE}, {BUG, DARK, SE}, {BUG, STEEL, NVE},
    {ROCK, FIRE, SE}, {ROCK, ICE, SE}, {ROCK, FIGHTING, NVE}, {ROCK, GROUND, NVE}, {ROCK, FLYING, SE},
    {ROCK, BUG, SE}, {ROCK, STEEL, NVE},
    {GHOST, NORMAL, NO}, {GHOST, PSYCHIC, SE}, {GHOST, DARK, NVE}, {GHOST, STEEL, NVE}, {GHOST, GHOST, SE},
    {DRAGON, DRAGON, SE}, {DRAGON, STEEL, NVE},
    {DARK, FIGHTING, NVE}, {DARK, PSYCHIC, SE}, {DARK, GHOST, SE}, {DARK, DARK, NVE}, {DARK, STEEL, NVE},
    {STEEL, FIRE, NVE}, {STEEL, WATER, NVE}, {STEEL, ELECTRIC, NVE}, {STEEL, ICE, SE}, {STEEL, ROCK, SE},
    {STEEL, STEEL, NVE},
    {NORMAL, GHOST, NO}, {FIGHTING, GHOST, NO},
}

-- Moves the target can know that change what a hit does to it.
local FLY, DIG, MINIMIZE, RAIN_DANCE, SUNNY_DAY = 19, 91, 107, 240, 241

-- How each effect (constants/move_effect_constants.asm) hits. One that
-- isn't listed is never picked: status moves, one-hit KOs, Explosion,
-- Counter, Present (it can heal), Dream Eater, locking moves (Thrash,
-- Rollout) and the like.
--   weaken: fine for weakening - no burn, poison, confusion or trapping
--     chance (those keep hurting it while the balls fly, and confusion can
--     make it knock itself out), no two-turn move, nothing growing.
--   kill: Kill mode's score multiplier (default 1) - two-turn moves count
--     half, a recharge turn or hurting yourself a bit less.
--   x2: the target move that doubles this one's damage (Fly for Gust, ...).
local EFFECTS = {
    [0x00] = {hit = "normal", weaken = true},           -- NORMAL_HIT
    [0x02] = {hit = "normal"},                          -- POISON_HIT
    [0x03] = {hit = "normal", weaken = true},           -- LEECH_HIT
    [0x04] = {hit = "normal"},                          -- BURN_HIT
    [0x05] = {hit = "normal", weaken = true},           -- FREEZE_HIT
    [0x06] = {hit = "normal", weaken = true},           -- PARALYZE_HIT
    [0x11] = {hit = "normal", weaken = true},           -- ALWAYS_HIT
    [0x1D] = {hit = "multi", weaken = true},            -- MULTI_HIT (2-5 hits)
    [0x1F] = {hit = "normal", weaken = true},           -- FLINCH_HIT
    [0x22] = {hit = "normal", weaken = true},           -- PAY_DAY
    [0x24] = {hit = "normal"},                          -- TRI_ATTACK (can burn)
    [0x27] = {hit = "normal", kill = 0.5},              -- RAZOR_WIND (two turns)
    [0x28] = {hit = "super_fang", weaken = true},       -- SUPER_FANG
    [0x29] = {hit = "static", weaken = true},           -- STATIC_DAMAGE (SonicBoom, Dragon Rage)
    [0x2A] = {hit = "normal"},                          -- TRAP_TARGET (Wrap: hurts it every turn)
    [0x2C] = {hit = "double", weaken = true},           -- DOUBLE_HIT
    [0x2D] = {hit = "normal", weaken = true, kill = 0.9}, -- JUMP_KICK (hurts you on a miss)
    [0x30] = {hit = "normal", weaken = true, kill = 0.9}, -- RECOIL_HIT
    [0x44] = {hit = "normal", weaken = true},           -- ATTACK_DOWN_HIT
    [0x45] = {hit = "normal", weaken = true},           -- DEFENSE_DOWN_HIT
    [0x46] = {hit = "normal", weaken = true},           -- SPEED_DOWN_HIT
    [0x47] = {hit = "normal", weaken = true},           -- SP_ATK_DOWN_HIT
    [0x48] = {hit = "normal", weaken = true},           -- SP_DEF_DOWN_HIT
    [0x49] = {hit = "normal", weaken = true},           -- ACCURACY_DOWN_HIT
    [0x4A] = {hit = "normal", weaken = true},           -- EVASION_DOWN_HIT
    [0x4B] = {hit = "normal", kill = 0.5},              -- SKY_ATTACK
    [0x4C] = {hit = "normal"},                          -- CONFUSE_HIT
    [0x4D] = {hit = "double"},                          -- POISON_MULTI_HIT (Twineedle)
    [0x50] = {hit = "normal", weaken = true, kill = 0.75}, -- HYPER_BEAM (a turn to recharge)
    [0x51] = {hit = "normal", weaken = true},           -- RAGE
    [0x57] = {hit = "level", weaken = true},            -- LEVEL_DAMAGE (Seismic Toss, Night Shade)
    [0x58] = {hit = "psywave", weaken = true},          -- PSYWAVE
    [0x63] = {hit = "reversal", weaken = true},         -- REVERSAL (Flail, Reversal)
    [0x65] = {hit = "false_swipe", weaken = true},      -- FALSE_SWIPE
    [0x67] = {hit = "normal", weaken = true},           -- PRIORITY_HIT
    [0x68] = {hit = "triple_kick"},                     -- TRIPLE_KICK
    [0x69] = {hit = "normal", weaken = true},           -- THIEF
    [0x6C] = {hit = "normal"},                          -- FLAME_WHEEL (can burn)
    [0x77] = {hit = "normal"},                          -- FURY_CUTTER (grows each hit)
    [0x79] = {hit = "return", weaken = true},           -- RETURN
    [0x7B] = {hit = "frustration", weaken = true},      -- FRUSTRATION
    [0x7D] = {hit = "normal"},                          -- SACRED_FIRE (can burn)
    [0x7E] = {hit = "magnitude", weaken = true, x2 = DIG}, -- MAGNITUDE
    [0x80] = {hit = "normal", weaken = true},           -- PURSUIT
    [0x81] = {hit = "normal", weaken = true},           -- RAPID_SPIN
    [0x87] = {hit = "hidden_power", weaken = true},     -- HIDDEN_POWER
    [0x8A] = {hit = "normal", weaken = true},           -- DEFENSE_UP_HIT
    [0x8B] = {hit = "normal", weaken = true},           -- ATTACK_UP_HIT
    [0x8C] = {hit = "normal", weaken = true},           -- ALL_UP_HIT
    [0x91] = {hit = "normal", kill = 0.5},              -- SKULL_BASH
    [0x92] = {hit = "normal", weaken = true, x2 = FLY}, -- TWISTER
    [0x93] = {hit = "normal", weaken = true, x2 = DIG}, -- EARTHQUAKE
    [0x95] = {hit = "normal", weaken = true, x2 = FLY}, -- GUST
    [0x96] = {hit = "normal", weaken = true, x2 = MINIMIZE}, -- STOMP
    [0x97] = {hit = "normal", kill = 0.5},              -- SOLARBEAM
    [0x98] = {hit = "normal", weaken = true},           -- THUNDER
    [0x9B] = {hit = "normal", kill = 0.5},              -- FLY (and Dig)
}

-- Multi-hit moves: 2 or 3 hits 3/8 of the time each, 4 or 5 hits 1/8.
local MULTI_HITS = {{2, 3 / 8}, {3, 3 / 8}, {4, 1 / 8}, {5, 1 / 8}}
-- Magnitude's powers and how often each comes up (magnitude_power.asm).
local MAGNITUDES = {{10, 0.05}, {30, 0.10}, {50, 0.20}, {70, 0.30}, {90, 0.20}, {110, 0.10}, {150, 0.05}}
-- Flail/Reversal: power by 48ths of HP left (flail_reversal_power.asm).
local REVERSAL_POWER = {{1, 200}, {4, 150}, {9, 100}, {16, 80}, {32, 40}, {48, 20}}
-- Thick Club (Cubone, Marowak) doubles Attack, Light Ball (Pikachu) Sp. Atk.
local CUBONE, MAROWAK, PIKACHU = 104, 105, 25

-- Critical hits (BattleCommand_Critical): a level from 0 up - +2 for the
-- high-crit moves, +1 for a Scope Lens; Chansey with a Lucky Punch and
-- Farfetch'd with a Stick are at +2 whatever the move. A crit when the
-- random byte is below CRIT_CHANCES[level] (data/battle/
-- critical_hit_chances.asm: 1 out of 15, 8, 4, 3, then 2). Focus Energy's
-- +1 isn't read.
local CRIT_CHANCES = {17, 32, 64, 85, 128}
local HIGH_CRIT_MOVES = {[0x02] = true, [0x0D] = true, [0x4B] = true, [0x98] = true, [0xA3] = true, [0xB1] = true, [0xEE] = true}
local CHANSEY, FARFETCH_D, LUCKY_PUNCH, STICK, SCOPE_LENS = 113, 83, 0x1E, 0x69, 0x8C

local function crit_chance(user, id)
    local level = 0
    if (user.species == CHANSEY and user.item == LUCKY_PUNCH) or (user.species == FARFETCH_D and user.item == STICK) then
        level = 2
    else
        if HIGH_CRIT_MOVES[id] then level = level + 2 end
        if user.item == SCOPE_LENS then level = level + 1 end
    end
    return CRIT_CHANCES[math.min(level, 4) + 1] / 256
end
-- The random roll: damage * 217..255 / 255 (BattleCommand_DamageVariation).
local ROLL_MIN, ROLL_MAX = 217, 255

-- ===== The move table =====

local romHash, moves

local function to_pattern(masked)
    local parts = {}
    for token in masked:gmatch("%S+") do
        if token == "??" then
            parts[#parts + 1] = "."
        else
            local c = string.char(tonumber(token, 16))
            parts[#parts + 1] = c:find("[%^%$%(%)%%%.%[%]%*%+%-%?]") and ("%" .. c) or c
        end
    end
    return table.concat(parts)
end

-- Finds the move table once per game. Each entry: animation (= the move's
-- own number, checked for all 251), effect, power, type, accuracy, PP,
-- effect chance.
function M.available()
    local okHash, hash = pcall(gameinfo.getromhash)
    hash = okHash and hash or ""
    if hash == romHash and moves ~= nil then return moves ~= false end
    romHash, moves = hash, false
    local okRead, bank = pcall(memory.read_bytes_as_binary_string, BANK * 0x4000, 0x4000, "ROM")
    if not okRead or type(bank) ~= "string" or #bank < 0x4000 then return false end
    local pattern = to_pattern(FIRST_MOVES)
    local at = bank:find(pattern)
    if at == nil or bank:find(pattern, at + 1) or at - 1 + NUM_MOVES * MOVE_LENGTH > #bank then return false end
    local table_ = {}
    for id = 1, NUM_MOVES do
        local o = at + (id - 1) * MOVE_LENGTH
        if bank:byte(o) ~= id then return false end
        table_[id] = {effect = bank:byte(o + 1), power = bank:byte(o + 2), type = bank:byte(o + 3), accuracy = bank:byte(o + 4)}
    end
    moves = table_
    return true
end

-- ===== Reading the battle =====

local function read16(view, addr)
    return view.read8(addr) * 256 + view.read8(addr + 1)
end

-- One side's battle_struct.
local function read_side(view, base)
    local s = {
        species = view.read8(base), item = view.read8(base + 1),
        moves = {}, pp = {},
        dvs = {view.read8(base + 6), view.read8(base + 7)},
        happiness = view.read8(base + 12), level = view.read8(base + 13),
        hp = read16(view, base + 16), maxHP = read16(view, base + 18),
        atk = read16(view, base + 20), def = read16(view, base + 22),
        spAtk = read16(view, base + 26), spDef = read16(view, base + 28),
        type1 = view.read8(base + 30), type2 = view.read8(base + 31),
    }
    for slot = 1, 4 do
        s.moves[slot] = view.read8(base + 1 + slot)
        -- The top two bits are the move's PP Ups.
        s.pp[slot] = view.read8(base + 7 + slot) % 64
    end
    s.key = table.concat({s.species, s.level, s.maxHP, s.dvs[1], s.dvs[2]}, ":")
    return s
end

local function knows(side, move)
    for slot = 1, 4 do
        if side.moves[slot] == move then return true end
    end
    return false
end

-- Each Pokemon's stats the first time it's seen in a battle - before any
-- stat change, which a critical hit can ignore (CheckDamageStatsCritical).
local firstLook = {}
local function first_look(side, which)
    local seen = firstLook[which]
    if seen == nil or seen.key ~= side.key then
        seen = {key = side.key, atk = side.atk, def = side.def, spAtk = side.spAtk, spDef = side.spDef}
        firstLook[which] = seen
    end
    return seen
end

-- ===== The damage =====

-- The type chart's multipliers for a move type against a target, in order.
local function matchup_steps(moveType, target)
    local steps = {}
    for _, row in ipairs(MATCHUPS) do
        if row[1] == moveType and (row[2] == target.type1 or row[2] == target.type2) then
            steps[#steps + 1] = row[3]
        end
    end
    return steps
end

local function immune(steps)
    for _, m in ipairs(steps) do
        if m == NO then return true end
    end
    return false
end

-- One hit, before the random roll (DamageCalc then Stab). o: crit, item,
-- weather, badge - which boosts to count.
local function hit_damage(level, power, atk, def, moveType, user, steps, o)
    while atk > 255 or def > 255 do -- TruncateHL_BC
        atk = math.max(1, atk // 4)
        def = math.max(1, def // 4)
    end
    def = math.max(def, 1)
    local d = ((level * 2) // 5 + 2) * power * atk // def // 50
    if o.item then d = d * 110 // 100 end
    if o.crit then d = d * 2 end
    d = math.min(d, 997) + 2
    if o.weather then d = d * 15 // 10 end
    if o.badge then d = d + math.max(1, d // 8) end
    if moveType == user.type1 or moveType == user.type2 then d = d + d // 2 end
    for _, m in ipairs(steps) do
        local p = d * m
        d = p // 10
        if p > 0 and d == 0 then d = 1 end
    end
    return d
end

local function roll(d, r)
    if d < 2 then return d end
    return d * r // ROLL_MAX
end

-- Power for the moves whose power isn't in the table.
local function power_of(hit, move, user, magnitudePower)
    if hit == "reversal" then
        local product, divisor = user.hp * 48, user.maxHP
        if divisor > 255 then product, divisor = product // 4, divisor // 4 end
        local q = product // math.max(divisor, 1)
        for _, row in ipairs(REVERSAL_POWER) do
            if row[1] >= q then return row[2] end
        end
        return 20
    elseif hit == "return" then
        return user.happiness * 10 // 25
    elseif hit == "frustration" then
        return (255 - user.happiness) * 10 // 25
    elseif hit == "hidden_power" then
        local atk, def = user.dvs[1] // 16, user.dvs[1] % 16
        local spe, spc = user.dvs[2] // 16, user.dvs[2] % 16
        local x = (atk >= 8 and 8 or 0) + (def >= 8 and 4 or 0) + (spe >= 8 and 2 or 0) + (spc >= 8 and 1 or 0)
        return (5 * x + spc % 4) // 2 + 31
    elseif hit == "magnitude" then
        return magnitudePower
    end
    return move.power
end

local function move_type_of(hit, move, user)
    if hit == "hidden_power" then
        return HIDDEN_POWER_TYPES[4 * (user.dvs[1] // 16 % 4) + user.dvs[1] % 4 + 1]
    end
    return move.type
end

-- Everything about using move slot against the target:
--   max: the most it can take, with the worst case of what can't be read
--     (a critical hit too, unless ignoreCrits) - for weakening.
--   low, high: its normal range, no crit, no unknown boosts.
--   expected: the average, misses included.
--   ko: the chance it knocks the target out this turn (no crit counted).
--   koCrit: the same with critical hits counted - what the Game Assistant
--     shows; the bot's own choices go by ko and maxCrit.
local function work_out(slot, user, target, userFirst, targetFirst, ignoreCrits)
    local id = user.moves[slot]
    local move = id and id >= 1 and id <= NUM_MOVES and moves[id] or nil
    if move == nil then return nil, "unknown" end
    local how = EFFECTS[move.effect]
    if how == nil then return nil, move.power == 0 and "status" or "never" end
    local hit = how.hit
    local moveType = move_type_of(hit, move, user)
    local steps = matchup_steps(moveType, target)
    local accuracy = move.accuracy >= 255 and 1 or move.accuracy / 256
    local r = {slot = slot, id = id, effect = how, hit = hit, accuracy = accuracy, hp = target.hp}
    if immune(steps) then return nil, "immune" end

    -- Damage that doesn't go through the formula.
    local fixed
    if hit == "level" then
        fixed = {user.level, user.level}
    elseif hit == "static" then
        fixed = {move.power, move.power}
    elseif hit == "super_fang" then
        local d = math.max(1, target.hp // 2)
        fixed = {d, d}
    elseif hit == "psywave" then
        local b = (user.level + user.level // 2) % 256
        fixed = {1, math.max(1, b - 1)}
    end
    if fixed then
        r.low, r.high, r.max, r.maxCrit = fixed[1], fixed[2], fixed[2], fixed[2]
        r.expected = accuracy * (fixed[1] + fixed[2]) / 2
        r.ko = target.hp <= fixed[1] and 1 or (target.hp > fixed[2] and 0
            or (fixed[2] - target.hp + 1) / (fixed[2] - fixed[1] + 1))
        r.koCrit = r.ko -- fixed damage can't crit
        return r
    end

    local physical = moveType < SPECIAL
    local atk = physical and user.atk or user.spAtk
    local def = physical and target.def or target.spDef
    local atkFirst = physical and userFirst.atk or userFirst.spAtk
    local defFirst = physical and targetFirst.def or targetFirst.spDef
    -- Worst case: the higher Attack and lower Defense of now and before any
    -- stat change, Thick Club / Light Ball doubling it, every boost.
    local atkMax, defMin = math.max(atk, atkFirst), math.min(def, defFirst)
    if user.item ~= 0 and ((physical and (user.species == CUBONE or user.species == MAROWAK))
            or (not physical and user.species == PIKACHU)) then
        atkMax = atkMax * 2
    end
    local worst = {crit = not ignoreCrits, item = user.item ~= 0, badge = true,
        weather = (moveType == FIRE or moveType == WATER) and (knows(target, RAIN_DANCE) or knows(target, SUNNY_DAY))}
    local doubled = how.x2 and knows(target, how.x2) and 2 or 1

    -- Powers it can come with (Magnitude rolls one), with their chances.
    local powers
    if hit == "magnitude" then
        powers = MAGNITUDES
    else
        powers = {{power_of(hit, move, user), 1}}
    end
    local hits = hit == "multi" and MULTI_HITS or {{hit == "double" and 2 or 1, 1}}
    local kicks = hit == "triple_kick" -- 1x, 2x and 3x the first kick's damage

    local maxPower = powers[#powers][1]
    if maxPower == 0 then return nil, "status" end -- Return/Frustration at the wrong happiness
    local mostHits = hits[#hits][1]
    local topPower = hit == "magnitude" and maxPower or powers[1][1]
    local times = (kicks and 6 or mostHits) * doubled
    r.max = hit_damage(user.level, topPower, atkMax, defMin, moveType, user, steps, worst) * times
    -- What the next look is checked against (check_last_hit): a crit too.
    worst.crit = true
    r.maxCrit = hit_damage(user.level, topPower, atkMax, defMin, moveType, user, steps, worst) * times

    -- The normal range (no crit, no unknown boost), its average, its KO chance.
    local low, high, expected, ko = math.huge, 0, 0, 0
    for _, pw in ipairs(powers) do
        local d = hit_damage(user.level, power_of(hit, move, user, pw[1]), atk, def, moveType, user, steps, {})
        for _, h in ipairs(hits) do
            local n = kicks and 6 or h[1]
            local chance = pw[2] * h[2]
            low = math.min(low, roll(d, ROLL_MIN) * n)
            high = math.max(high, roll(d, ROLL_MAX) * n)
            local sum, kos = 0, 0
            for rr = ROLL_MIN, ROLL_MAX do
                local total = roll(d, rr) * n
                sum = sum + total
                if total >= target.hp then kos = kos + 1 end
            end
            local rolls = ROLL_MAX - ROLL_MIN + 1
            expected = expected + chance * sum / rolls
            ko = ko + chance * kos / rolls
        end
    end
    -- The same KO chance on a critical hit. A crit ignores stat changes
    -- that work against the attacker (CheckDamageStatsCritical): whichever
    -- of now and before any change suits it better. Every hit of a multi-
    -- hit move counted as the first one's (crit or not).
    local critAtk, critDef = atk, def
    if atkFirst * def > atk * defFirst then critAtk, critDef = atkFirst, defFirst end
    local koOnCrit = 0
    for _, pw in ipairs(powers) do
        local d = hit_damage(user.level, power_of(hit, move, user, pw[1]), critAtk, critDef, moveType, user, steps, {crit = true})
        for _, h in ipairs(hits) do
            local n = kicks and 6 or h[1]
            local kos = 0
            for rr = ROLL_MIN, ROLL_MAX do
                if roll(d, rr) * n >= target.hp then kos = kos + 1 end
            end
            koOnCrit = koOnCrit + pw[2] * h[2] * kos / (ROLL_MAX - ROLL_MIN + 1)
        end
    end
    local critP = crit_chance(user, id)
    if hit == "false_swipe" then
        -- Never takes the last HP.
        local cap = math.max(target.hp - 1, 0)
        r.max, r.maxCrit = math.min(r.max, cap), math.min(r.maxCrit, cap)
        low, high = math.min(low, cap), math.min(high, cap)
        expected = math.min(expected, cap)
        ko, koOnCrit = 0, 0
    end
    r.low, r.high = low, high
    r.expected = accuracy * expected
    r.ko = accuracy * ko
    r.koCrit = accuracy * ((1 - critP) * ko + critP * koOnCrit)
    return r
end

-- ===== Choosing =====

local Names = MoveNames
local function move_name(id)
    if Names == nil then
        local ok, names = pcall(require, "data.move_names")
        Names = ok and type(names) == "table" and names or {}
    end
    return Names[id] or ("move #" .. tostring(id))
end

-- The last pick, to check the next look against: a hit that took more
-- than it can at most, a critical hit included (the target's own recoil or
-- Substitute can do that, or the math is off), gets logged - and while
-- weakening, puts that encounter back on the old rule.
local lastPick, distrusted, flagged

local function check_last_hit(target, weakening)
    local last = lastPick
    if last == nil or last.key ~= target.key or target.hp >= last.hp then return end
    local took = last.hp - target.hp
    if took <= last.pick.maxCrit then return end
    if weakening and distrusted ~= target.key then
        distrusted = target.key
        print(string.format(
            "Move choice: the target lost %d HP, more than the %d %s can take at most - its own move (recoil, Substitute) or the math. Weakening goes by the old rule for this Pokemon.",
            took, last.pick.maxCrit, move_name(last.pick.id)))
    elseif not weakening and flagged ~= target.key then
        flagged = target.key
        print(string.format("Move choice: the target lost %d HP, more than the %d %s can take at most - its own move (recoil, Substitute) or the math.",
            took, last.pick.maxCrit, move_name(last.pick.id)))
    end
end

local VALID_TYPE = {}
for _, t in ipairs({NORMAL, FIGHTING, FLYING, POISON, GROUND, ROCK, BUG, GHOST, STEEL,
        FIRE, WATER, GRASS, ELECTRIC, PSYCHIC, ICE, DRAGON, DARK}) do
    VALID_TYPE[t] = true
end

-- Whether a side reads as a real Pokemon in battle - a version whose
-- addresses aren't right (some are still unverified) reads garbage.
local function plausible(s)
    return s.species >= 1 and s.species <= 251 and s.level >= 1 and s.level <= 100
        and s.maxHP > 0 and s.hp <= s.maxHP and VALID_TYPE[s.type1] and VALID_TYPE[s.type2] or false
end

-- Both sides, or nil when either doesn't read right.
local function look(view)
    local user = read_side(view, view.own)
    local target = read_side(view, view.enemy)
    if not (plausible(user) and plausible(target)) then return nil end
    return user, target, first_look(user, "own"), first_look(target, "enemy")
end

-- The weakening pick: the most expected damage whose max stays under the
-- target's HP. No side effects (see M.analyze()).
local function pick_weaken(user, target, userFirst, targetFirst, ignoreCrits)
    local best
    for slot = 1, 4 do
        if user.pp[slot] > 0 then
            local r = work_out(slot, user, target, userFirst, targetFirst, ignoreCrits)
            if r and r.effect.weaken and r.max < target.hp and r.expected > 0
                    and (best == nil or r.expected > best.expected) then
                best = r
            end
        end
    end
    return best
end

-- Kill mode's pick: the best chance to knock it out, then the most damage.
local function pick_kill(user, target, userFirst, targetFirst)
    local best, bestKo, bestExpected
    for slot = 1, 4 do
        if user.pp[slot] > 0 then
            local r = work_out(slot, user, target, userFirst, targetFirst, true)
            if r and r.hit ~= "false_swipe" and r.expected > 0 then
                local weight = r.effect.kill or 1
                local ko, expected = r.ko * weight, r.expected * weight
                if best == nil or ko > bestKo or (ko == bestKo and expected > bestExpected) then
                    best, bestKo, bestExpected = r, ko, expected
                end
            end
        end
    end
    return best
end

-- See the top of the file. Returns the pick, or nil and why: "none" (no
-- move can safely take more) or "distrust" (a hit went past its max).
function M.weaken(view, opts)
    if not M.available() then return nil, "distrust" end
    local user, target, userFirst, targetFirst = look(view)
    if user == nil then return nil, "distrust" end
    check_last_hit(target, true)
    if distrusted == target.key then return nil, "distrust" end
    local best = pick_weaken(user, target, userFirst, targetFirst, opts and opts.ignoreCrits)
    if best == nil then return nil, "none" end
    lastPick = {key = target.key, hp = target.hp, pick = best}
    return best
end

-- The target's first move, with PP left, that's super effective against the
-- user overall (x2 or x4 - a resistance in the user's other type can cancel
-- it out), or nil: Kill mode only fights matchups that favour it. Moves of
-- fixed damage (Seismic Toss, SonicBoom, Super Fang) don't count - type
-- doesn't change what they do.
local FIXED_DAMAGE = {level = true, static = true, super_fang = true, psywave = true}
local function super_effective_threat(target, user)
    for slot = 1, 4 do
        local id = target.moves[slot]
        local move = id and id >= 1 and id <= NUM_MOVES and moves[id] or nil
        local how = move and EFFECTS[move.effect]
        if how and not FIXED_DAMAGE[how.hit] and target.pp[slot] > 0 then
            local x = 1
            for _, step in ipairs(matchup_steps(move_type_of(how.hit, move, target), user)) do x = x * step / 10 end
            if x > 1 then return id end
        end
    end
    return nil
end

-- See the top of the file. Returns the pick, or nil and why: "none" (no
-- move can hurt it), "risky" (it knows a move super effective against
-- yours - its name comes third) or "unknown" (no move table, or the battle
-- doesn't read right - go by move 1 and 2 as before).
function M.kill(view)
    if not M.available() then return nil, "unknown" end
    local user, target, userFirst, targetFirst = look(view)
    if user == nil then return nil, "unknown" end
    local threat = super_effective_threat(target, user)
    if threat then return nil, "risky", move_name(threat) end
    check_last_hit(target, false)
    local best = pick_kill(user, target, userFirst, targetFirst)
    if best == nil then return nil, "none" end
    lastPick = {key = target.key, hp = target.hp, pick = best}
    return best
end

local TYPE_NAMES = {[NORMAL] = "Normal", [FIGHTING] = "Fighting", [FLYING] = "Flying", [POISON] = "Poison",
    [GROUND] = "Ground", [ROCK] = "Rock", [BUG] = "Bug", [GHOST] = "Ghost", [STEEL] = "Steel", [0x13] = "???",
    [FIRE] = "Fire", [WATER] = "Water", [GRASS] = "Grass", [ELECTRIC] = "Electric", [PSYCHIC] = "Psychic",
    [ICE] = "Ice", [DRAGON] = "Dragon", [DARK] = "Dark"}

-- One side's moves against the other, for a display.
local function each_move(user, target, userFirst, targetFirst)
    local rows = {}
    for slot = 1, 4 do
        local id = user.moves[slot]
        if id and id >= 1 and id <= NUM_MOVES then
            local move = moves[id]
            local hit = EFFECTS[move.effect] and EFFECTS[move.effect].hit
            local r, why = work_out(slot, user, target, userFirst, targetFirst, false)
            rows[slot] = {slot = slot, id = id, name = move_name(id), pp = user.pp[slot],
                type = TYPE_NAMES[move_type_of(hit, move, user)] or "?", result = r, why = why}
        end
    end
    return rows
end

-- A move's name, type, power and accuracy (%) for a display - power nil for
-- moves whose power isn't fixed (or that don't hit), nil when unknown.
function M.move_info(id)
    if not M.available() or id == nil or id < 1 or id > NUM_MOVES then return nil end
    local move = moves[id]
    return {name = move_name(id), type = TYPE_NAMES[move.type] or "?",
        power = move.power > 1 and move.power or nil,
        accuracy = math.floor(move.accuracy * 100 / 255 + 0.5)}
end

-- Hidden Power's type name and power for a Pokemon's two DV bytes.
function M.hidden_power(atkDef, speSpc)
    local user = {dvs = {atkDef, speSpc}}
    return TYPE_NAMES[move_type_of("hidden_power", nil, user)], power_of("hidden_power", nil, user)
end

-- Everything a display needs about the battle on screen, without touching
-- what M.weaken()/M.kill() remember between turns (a display may look at
-- any time, the bot mid-catch included):
--   user/target: both sides as read (species, level, HP, stats, moves...);
--   moves[slot]: {id, name, pp, type, result = work_out()'s table or nil,
--     why = "immune"/"status"/"never"/"unknown" when nil}, ours vs theirs;
--   threats[slot]: the same for the target's known moves against us;
--   kill, weaken: the slots Kill mode and weakening would pick (or nil).
-- nil when there's no move table or the battle doesn't read right.
function M.analyze(view)
    if not M.available() then return nil end
    local user = read_side(view, view.own)
    local target = read_side(view, view.enemy)
    if not (plausible(user) and plausible(target)) then return nil end
    local userFirst, targetFirst = first_look(user, "display own"), first_look(target, "display enemy")
    local killPick = pick_kill(user, target, userFirst, targetFirst)
    local weakenPick = pick_weaken(user, target, userFirst, targetFirst, false)
    return {
        user = user, target = target,
        moves = each_move(user, target, userFirst, targetFirst),
        threats = each_move(target, user, targetFirst, userFirst),
        kill = killPick and killPick.slot, weaken = weakenPick and weakenPick.slot,
    }
end

-- "Tackle (move 1): 5-7 damage, up to 14 with a critical hit, against 30 HP".
-- how: nil (weakening), "override" (weakening, crits ignored) or "kill"
-- (the chance to knock it out instead of the worst case).
function M.describe(pick, how)
    local range = pick.low == pick.high and tostring(pick.low) or (pick.low .. "-" .. pick.high)
    local extra = ""
    if how == "kill" then
        if pick.ko > 0 then extra = string.format(" (%d%% to knock it out)", math.floor(pick.ko * 100 + 0.5)) end
    elseif pick.max > pick.high then
        extra = string.format(", up to %d %s", pick.max, how == "override" and "with every boost" or "with a critical hit")
    end
    return string.format("%s (move %d): %s damage, against %d HP%s", move_name(pick.id), pick.slot, range, pick.hp, extra)
end

-- The PP left on move slot (1-4) of the active Pokemon, PP Ups masked off.
function M.pp(view, slot)
    return view.read8(view.own + 7 + slot) % 64
end

return M

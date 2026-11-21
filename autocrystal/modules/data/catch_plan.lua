-- catch_plan.lua (lives in modules/data/)
-- What auto-catch does each turn, from what the party can do (v1.3.0):
--
--   1. A target that can get away by itself - it runs (the game's flee list,
--      data/wild/flee_mons.asm) or knows Teleport - and someone in the party
--      knows Mean Look (or Spider Web): that one traps it first. Mean Look
--      stops both (TryEnemyFlee and BattleCommand_Teleport check the trap).
--      Roar and Whirlwind are NOT stopped by it - only sleep helps there.
--   2. Not asleep, and someone knows a sleep move (Spore, Sleep Powder,
--      Lovely Kiss, Hypnosis, Sing): put it to sleep - the one out if it
--      knows one, else the most accurate one in the party. A target that
--      already has another status can't be put to sleep (the move fails),
--      so that's skipped.
--   3. Above the HP target: weaken it - only with a move that can't knock it
--      out even with a critical hit (data/move_choice.lua; the Advanced
--      Settings crit override is the only way to allow that risk). The one
--      out if it has such a move, else a party member that does.
--   4. Else balls.
-- Switching is only ever to a party member that brings one of these - a
-- party without such Pokemon just throws balls (a Lv 100 party against a
-- Lv 10 Pidgey: no move is safe, no sleep move, so balls straight away).
-- Once a runner is trapped there's no more switching: the trap ends when the
-- trapper leaves the field, and a switch is a free turn for the target.
--
-- M.decide(party, active, enemy, st, opts) -> action:
--   {kind = "trap" | "sleep" | "weaken", slot = move slot 1-4, pick = ...}
--     a move for the one out
--   {kind = "switch", to = party slot (0-based), why = "trap"/"sleep"/"weaken"}
--   {kind = "balls", why = text}
-- party: {[slot0] = {species, hp, egg, moves = {4 ids}, pp = {4}}, ...} (0-based keys)
-- active: the party slot out (wCurBattleMon); its moves/PP from the battle struct
-- enemy: {species, hp, maxhp, status, moves = {4}, pp = {4}}
-- st: this catch's own state (trapped, sleepTries, switches, noSwitch)
-- opts: {targetHP = 0.40, weaken = function(slot0) -> pick or nil}
-- Plain - tested offline (scratchpad v130/test_catch_plan.lua).

local M = {}

-- Sleep moves and their accuracy (out of 100).
M.SLEEP_MOVES = {[147] = 100, [79] = 75, [142] = 75, [95] = 60, [47] = 55}   -- Spore, Sleep Powder, Lovely Kiss, Hypnosis, Sing
M.TRAP_MOVES = {[212] = true, [169] = true}                                   -- Mean Look, Spider Web
M.TELEPORT = 100
-- The game's flee list (data/wild/flee_mons.asm): runs always, often or sometimes.
M.FLEE = {[243] = true, [244] = true, [104] = true, [144] = true, [145] = true, [146] = true, [195] = true,
    [225] = true, [231] = true, [216] = true, [81] = true, [88] = true, [114] = true, [122] = true, [133] = true,
    [137] = true, [147] = true, [148] = true, [176] = true, [197] = true, [201] = true, [209] = true, [214] = true}
M.MAX_SLEEP_TRIES = 8     -- missed sleep moves in one catch before it's balls (or weakening) without
M.MAX_SWITCHES = 8        -- switches in one catch (a loop guard; sleep wears off, so a sleeper and a weakener take turns)
M.MAX_TRAP_TRIES = 3
M.MIN_SLEEP_TO_SWITCH = 3  -- sleep turns left for a switch to the weakener to be worth it

local function asleep(status) return (status or 0) & 0x07 ~= 0 or (status or 0) & 0x20 ~= 0 end

-- The best move of `kind` a member has with PP: slot, id, accuracy.
local function find_move(mon, kind)
    local bestSlot, bestId, bestAcc
    for slot = 1, 4 do
        local id = mon.moves and mon.moves[slot]
        if id and (mon.pp[slot] or 0) > 0 then
            local acc = kind == "sleep" and M.SLEEP_MOVES[id] or (kind == "trap" and M.TRAP_MOVES[id] and 100) or nil
            if acc and (bestAcc == nil or acc > bestAcc) then bestSlot, bestId, bestAcc = slot, id, acc end
        end
    end
    return bestSlot, bestId, bestAcc
end

local function can_fight(mon) return mon and not mon.egg and (mon.hp or 0) > 0 end

-- The party member (not the one out) with the best move of kind: slot0, acc.
local function find_member(party, active, kind)
    local best, bestAcc
    for slot0 = 0, 5 do
        local mon = party[slot0]
        if slot0 ~= active and can_fight(mon) then
            local _, _, acc = find_move(mon, kind)
            if acc and (bestAcc == nil or acc > bestAcc) then best, bestAcc = slot0, acc end
        end
    end
    return best, bestAcc
end

-- It can get away by itself in a way Mean Look stops.
function M.runner(enemy)
    if M.FLEE[enemy.species] then return true end
    for slot = 1, 4 do
        if enemy.moves and enemy.moves[slot] == M.TELEPORT and ((enemy.pp and enemy.pp[slot]) or 1) > 0 then return true end
    end
    return false
end

-- It knows a move that ends a wild battle: Teleport (not once trapped),
-- Roar or Whirlwind (Mean Look doesn't stop those).
M.ROAR = {[46] = true, [18] = true}   -- Roar, Whirlwind
function M.roarer(enemy)
    for slot = 1, 4 do
        local id = enemy.moves and enemy.moves[slot]
        if id and M.ROAR[id] and ((enemy.pp and enemy.pp[slot]) or 1) > 0 then return true end
    end
    return false
end
function M.ender(enemy, trapped)
    for slot = 1, 4 do
        local id = enemy.moves and enemy.moves[slot]
        if id and ((enemy.pp and enemy.pp[slot]) or 1) > 0 and (M.ROAR[id] or (id == M.TELEPORT and not trapped)) then return true end
    end
    return false
end

function M.decide(party, active, enemy, st, opts)
    opts = opts or {}
    local me = party[active]
    -- (ours asleep or frozen - a wild Gastly's Hypnosis: it can't use a
    -- move, so its moves don't count this turn - someone else's, or balls,
    -- which work whatever state ours is in; the stress test, 2026-11-21:
    -- seven "Sleep Powder"s in a row from a Butterfree that was asleep)
    if me and asleep(me.status) then
        me = {species = me.species, hp = me.hp, maxhp = me.maxhp, moves = {}, pp = {}}
        party = setmetatable({[active] = me}, {__index = party})
        local base = opts
        opts = setmetatable({weaken = function(slot0) if slot0 == active then return nil end return base.weaken and base.weaken(slot0) end}, {__index = base})
    end
    local mayswitch = not st.noSwitch and (st.switches or 0) < M.MAX_SWITCHES and not st.trapped
    -- (awake and able to end the battle with its own move - Teleport while
    -- not trapped, Roar or Whirlwind always: a switch hands it that turn for
    -- free, a ball at least gets a chance; asleep it can't use it, so a
    -- switch is fine then; the stress test, 2026-11-21: a Teleport-only
    -- target got away during every switch to the Mean Look one, a Growlithe
    -- woke and Roared during a switch back to the sleeper)
    if mayswitch and not asleep(enemy.status) and M.ender(enemy, st.trapped) then mayswitch = false end
    -- 1. trap a runner
    if M.runner(enemy) and not st.trapped and (st.trapTries or 0) < M.MAX_TRAP_TRIES then
        local slot, id = find_move(me, "trap")
        if slot then return {kind = "trap", slot = slot, id = id} end
        if mayswitch then
            local to = find_member(party, active, "trap")
            if to then return {kind = "switch", to = to, why = "trap"} end
        end
    end
    -- 2. sleep
    local status = enemy.status or 0
    if status == 0 and (st.sleepTries or 0) < M.MAX_SLEEP_TRIES then
        local slot, id, acc = find_move(me, "sleep")
        if slot then return {kind = "sleep", slot = slot, id = id, acc = acc} end
        if mayswitch then
            local to = find_member(party, active, "sleep")
            if to then return {kind = "switch", to = to, why = "sleep"} end
        end
    end
    -- (Roar / Whirlwind: the user's rule, 2026-11-21 - sleep, then balls at
    -- once; no weakening turns for it to wake up in and blow the battle away)
    if M.roarer(enemy) then
        return {kind = "balls", roar = true, why = "it knows Roar or Whirlwind - no weakening, it could end the battle"}
    end
    -- 3. weaken
    local target = opts.targetHP or 0.40
    if enemy.maxhp and enemy.maxhp > 0 and enemy.hp > enemy.maxhp * target then
        local pick = opts.weaken and opts.weaken(active)
        if pick then return {kind = "weaken", slot = pick.slot, pick = pick} end
        -- (asleep for only 1-2 more turns: the switch would use one of them up
        -- and it wakes before the weakening gets anywhere - balls while it
        -- sleeps instead; the stress test, 2026-11-21: sleep, switch, awake,
        -- switch back, in a loop)
        local sleepLeft = status & 0x07
        local shortSleep = sleepLeft ~= 0 and sleepLeft < M.MIN_SLEEP_TO_SWITCH
        if mayswitch and opts.weaken and not shortSleep then
            for slot0 = 0, 5 do
                if slot0 ~= active and can_fight(party[slot0]) and opts.weaken(slot0) then
                    return {kind = "switch", to = slot0, why = "weaken"}
                end
            end
        end
        return {kind = "balls", why = "no move can weaken it without a risk of knocking it out"}
    end
    return {kind = "balls", why = asleep(status) and "asleep and low enough" or "low enough"}
end

-- ------------------------------------------------------------ the balls
-- The chance a ball catches it now, the game's way (engine/items/
-- item_effects.asm PokeBallEffect): catch rate x the ball's multiplier
-- (255 at most) x (3 max HP - 2 HP) / (3 max HP), +10 asleep or frozen
-- (255 at most); caught when a random byte is under it. 0-1.
M.BALL_MULT = {[2] = 2, [4] = 1.5, [5] = 1}       -- Ultra, Great, Poke
M.LEVEL_BALL, M.LURE_BALL = 159, 160
-- On a tie (both catch it every time, say) the one that's easiest to replace.
M.TIE_ORDER = {[5] = 1, [4] = 2, [160] = 3, [159] = 4, [2] = 5}
function M.ball_chance(id, rate, hp, maxhp, status, ownLevel, enemyLevel, lureMult)
    local mult
    if id == M.LEVEL_BALL then
        -- (as 1.2.0 worked it out: x1 when theirs is at least ours, x2 at
        -- half of ours or more, x4 at a quarter or more, else x8)
        local mine, theirs = ownLevel or 0, enemyLevel or 0
        mult = theirs >= mine and 1 or theirs >= mine // 2 and 2 or theirs >= mine // 4 and 4 or 8
    elseif id == M.LURE_BALL then mult = lureMult or 1
    else mult = M.BALL_MULT[id] end
    if not mult then return nil end
    local a = math.min(255, math.floor((rate or 255) * mult))
    if id ~= M.LEVEL_BALL and maxhp and maxhp > 0 then
        -- (the game skips the HP part for the Level Ball)
        a = math.max(1, math.floor(a * (3 * maxhp - 2 * hp) / (3 * maxhp)))
    end
    if asleep(status) then a = math.min(255, a + 10) end
    return (a + 1) / 256
end
-- balls: {{id, count}, ...}. The ball with the best chance; ties to the
-- easiest to replace. Never a Master Ball (it isn't in M.BALL_MULT).
function M.best_ball(balls, rate, hp, maxhp, status, ownLevel, enemyLevel, lureMult)
    local best, bestChance
    for _, b in ipairs(balls) do
        if (b[2] or 0) > 0 then
            local c = M.ball_chance(b[1], rate, hp, maxhp, status, ownLevel, enemyLevel, lureMult)
            if c and (best == nil or c > bestChance + 1e-9 or (math.abs(c - bestChance) <= 1e-9 and (M.TIE_ORDER[b[1]] or 9) < (M.TIE_ORDER[best] or 9))) then
                best, bestChance = b[1], c
            end
        end
    end
    return best, bestChance
end

return M

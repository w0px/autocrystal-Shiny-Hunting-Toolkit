-- train.lua (lives in modules/data/)
-- v1.3.0 General Settings' "Switch-training": the lead (the trainee) gets
-- EXP from fights it couldn't safely win alone. When it can - knocks the
-- wild one out within M.SOLO_TURNS turns at the lowest roll, nothing about
-- it is "risky" (data/move_choice.lua's M.kill) and it's healthy - it
-- fights alone and gets all the EXP. Otherwise the best partner comes in
-- (the game shares the EXP between every Pokemon that was out) and knocks
-- it out. The partner: healthy (over M.FIT_HP), not threatened by it,
-- the best chance to knock it out this turn, then the most damage.
-- Nobody left who can (out of HP or PP): the bot stops ("depleted").
--
-- M.solo(pick, why, me) -> true when the trainee fights alone
--   pick/why: M.kill()'s answer for the one out; me: {hp, maxhp}
-- M.partner(party, active, check) -> party slot (0-based) or nil
--   check(slot0) -> MoveChoice.kill_check's pick (nil when it can't / risky)

local M = {}

M.SOLO_TURNS = 3
M.FIT_HP = 0.5

function M.solo(pick, why, me, enemyHP)
    if not pick or why then return false end
    if me.maxhp > 0 and me.hp <= M.FIT_HP * me.maxhp then return false end
    local low = pick.low or 0
    if low <= 0 then return false end
    return math.ceil((enemyHP or pick.hp) / low) <= M.SOLO_TURNS
end

function M.partner(party, active, check)
    local best, bestKo, bestExp
    for slot0 = 0, 5 do
        local mon = party[slot0]
        if slot0 ~= active and mon and not mon.egg and (mon.hp or 0) > 0
                and (mon.maxhp or 0) > 0 and mon.hp > M.FIT_HP * mon.maxhp then
            local pick = check(slot0)
            if pick then
                local ko, exp = pick.ko or 0, pick.expected or 0
                if best == nil or ko > bestKo or (ko == bestKo and exp > bestExp) then
                    best, bestKo, bestExp = slot0, ko, exp
                end
            end
        end
    end
    return best
end

return M

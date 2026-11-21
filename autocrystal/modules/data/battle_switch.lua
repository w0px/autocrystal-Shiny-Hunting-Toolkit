-- battle_switch.lua (lives in modules/data/)
-- Switching the Pokemon out during a wild battle (v1.3.0 auto-catch: the
-- party member that can trap, put to sleep or safely weaken the target -
-- data/catch_plan.lua). The way a player does it: PKMN on the battle menu,
-- the Pokemon in the list, SWITCH.
--
-- Each screen is told apart by the game's own 2D-menu data, which sits right
-- before wMenuCursorY in every version (Crystal, Gold/Silver, the Japanese
-- games): w2DMenuCursorInitX (-7), w2DMenuNumRows (-6), w2DMenuNumCols (-5):
--   the battle menu   2 rows x 2 columns (FIGHT PKMN / PACK RUN)
--   the party list    one row per Pokemon in the party, 1 column
--   SWITCH/STATS/CANCEL  3 rows, 1 column, further right than the list
-- and it's done once wCurBattleMon is the one picked and the battle menu is
-- back. Anything that doesn't look right: B back to the battle menu and
-- false - the catch then goes on without switching (never a guess).
--
-- M.to(ctx, slot0) -> true, or false and why ("fainted": ours went down
-- coming in). ctx:
--   read8(addr), read16(addr)
--   press(button)          hold it the module's usual way
--   frame()                one frame (the module's frame advance)
--   cursorY                wMenuCursorY's address
--   curBattleMon           wCurBattleMon's address (the party slot out, 0-based)
--   partyCount             wPartyCount's address
--   ownHP                  the battle mon's HP address
--   menuOption(y, x)       the module's battle-menu cursor driver -> true when there
--   battleControls()       the battle menu is up (the LoadBattleMenu hook's flag)
--   clearBattleControls()  forget it (it's set again when the menu comes back)
--   advance()              one step of waiting through text (ButtonWait's A)
--   stop()                 true: the Stop button
--   log(text)

local M = {}

local INIT_X, NUM_ROWS, NUM_COLS = -7, -6, -5

local function menu(ctx)
    local y = ctx.cursorY
    return {x = ctx.read8(y + INIT_X), rows = ctx.read8(y + NUM_ROWS), cols = ctx.read8(y + NUM_COLS), cursor = ctx.read8(y)}
end

local function wait_for(ctx, n, test)
    for _ = 1, n do
        if ctx.stop() then return false end
        if test() then return true end
        ctx.frame()
    end
    return test()
end

-- B until the battle menu is back (or give up).
local function back_out(ctx, why)
    ctx.log("Switch: " .. why .. " - backing out to the battle menu.")
    for _ = 1, 8 do
        if ctx.battleControls() then return end
        ctx.press("B")
        for _ = 1, 20 do ctx.frame() end
    end
end

function M.to(ctx, slot0)
    local count = ctx.read8(ctx.partyCount)
    if slot0 == nil or slot0 < 0 or slot0 >= count then return false, "no such party slot" end
    if ctx.read8(ctx.curBattleMon) == slot0 then return true end
    if not ctx.battleControls() then return false, "the battle menu isn't up" end
    -- (the battle menu's own 2x2 data, steady for a few frames, before its
    -- cursor counts: right after a turn it can still hold the move list's
    -- numbers, and PKMN "reached" that way was FIGHT; the stress test,
    -- 2026-11-21: "the party list didn't come up" now and then)
    local steady = 0
    wait_for(ctx, 90, function()
        local m = menu(ctx)
        steady = (m.rows == 2 and m.cols == 2) and steady + 1 or 0
        return steady >= 3
    end)
    local battleMenu = menu(ctx)
    if not ctx.menuOption(1, 2) then return false, "couldn't get the cursor onto PKMN" end
    ctx.clearBattleControls()
    -- the party list
    ctx.press("A")
    local list
    local ok = wait_for(ctx, 150, function()
        local m = menu(ctx)
        -- (InitPartyMenuWithCancel: one row more than the party - CANCEL)
        if m.cols == 1 and (m.rows == count + 1 or m.rows == count) and m.cursor >= 1 and m.cursor <= count + 1
                and m.x ~= battleMenu.x then list = m; return true end
        return false
    end)
    if not ok then back_out(ctx, "the party list didn't come up"); return false, "no party list" end
    for _ = 1, 30 do ctx.frame() end      -- (the list drawn and taking input)
    -- the cursor onto the Pokemon
    for _ = 1, 14 do
        local at = ctx.read8(ctx.cursorY)
        if at == slot0 + 1 then break end
        ctx.press(at < slot0 + 1 and "Down" or "Up")
        for _ = 1, 6 do ctx.frame() end
    end
    if ctx.read8(ctx.cursorY) ~= slot0 + 1 then back_out(ctx, "the cursor didn't reach the Pokemon"); return false, "cursor" end
    -- SWITCH / STATS / CANCEL
    ctx.press("A")
    ok = wait_for(ctx, 90, function()
        local m = menu(ctx)
        return m.cols == 1 and m.rows == 3 and m.cursor == 1 and m.x ~= list.x
    end)
    if not ok then back_out(ctx, "the SWITCH box didn't come up"); return false, "no SWITCH box" end
    for _ = 1, 10 do ctx.frame() end
    ctx.press("A")
    -- "Come back! ... Go! X!", the target's free turn, the battle menu again
    local downFrames = 0
    for _ = 1, 2400 do
        if ctx.stop() then return false, "stopped" end
        if ctx.read8(ctx.curBattleMon) == slot0 and ctx.battleControls() then
            ctx.log(string.format("Switch: party slot %d is out.", slot0 + 1))
            return true
        end
        if ctx.read8(ctx.curBattleMon) == slot0 and ctx.read16(ctx.ownHP) == 0 then
            downFrames = downFrames + 1
            if downFrames >= 3 then return false, "fainted" end
        else
            downFrames = 0
        end
        ctx.advance()
    end
    if ctx.read8(ctx.curBattleMon) ~= slot0 then back_out(ctx, "the switch didn't happen") end
    return false, "the battle menu didn't come back"
end

return M

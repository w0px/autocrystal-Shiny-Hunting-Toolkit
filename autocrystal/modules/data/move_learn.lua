-- move_learn.lua (lives in modules/data/)
-- v1.3.0 General Settings' "Learn better moves by itself": a Pokemon with
-- four moves that wants a new one learns it only when it hits harder than
-- the weakest attack it would replace - never over an HM move or a move
-- that isn't an attack (Sleep Powder, Mean Look... stay: you picked those).
-- Otherwise it's skipped. Unticked, the bot stops and asks, as in 1.2.0.
--
-- "Hits harder": power x accuracy x 1.5 when it's one of the Pokemon's own
-- types (same-type bonus). Moves whose power isn't fixed (Seismic Toss,
-- Flail...) count as power 60.
--
-- The prompts, told apart by the game's own 2D-menu data (the same in every
-- version - see data/battle_switch.lua): "Delete an older move to make
-- room for X?" YES/NO (2 rows, 1 column), the move list to forget from
-- (5 rows: the four and CANCEL - learn.asm), and after NO, "Stop learning
-- X?" YES/NO.
--
-- M.choose(known, new, data, types) -> slot to replace (1-4) or nil
--   known: the 4 move ids; new: the new move's id; data(id) -> {power, type,
--   accuracy} (data/move_choice.lua's move_data); types: the species' {t1, t2}
-- M.answer(ctx, slot) -> true, or false and why. ctx: read8, press, frame,
--   cursorY (wMenuCursorY), advance() (one step through text, never B),
--   stop(), log(text)

local M = {}

M.HM = {[15] = true, [19] = true, [57] = true, [70] = true, [127] = true, [148] = true, [250] = true}
M.MARGIN = 1.1     -- the new move must be this much better
local INIT_X, NUM_ROWS, NUM_COLS = -7, -6, -5

local function strength(d, types)
    if not d or d.power == 0 then return nil end
    local power = d.power > 1 and d.power or 60
    local acc = d.accuracy >= 255 and 1 or d.accuracy / 256
    local stab = types and (d.type == types[1] or d.type == types[2]) and 1.5 or 1
    return power * acc * stab
end

function M.choose(known, new, data, types, isAttack)
    local newS = strength(data(new), types)
    if not newS or (isAttack and not isAttack(new)) then return nil, "it isn't an attack" end
    local worst, worstS
    for slot = 1, 4 do
        local id = known[slot]
        if id and id ~= 0 and not M.HM[id] and (not isAttack or isAttack(id)) then
            local s = strength(data(id), types)
            if s and (worstS == nil or s < worstS) then worst, worstS = slot, s end
        end
    end
    if not worst then return nil, "every move it knows is an HM or not an attack" end
    if newS < worstS * M.MARGIN then return nil, "it isn't better than what it knows" end
    return worst
end

local function menu(ctx)
    local y = ctx.cursorY
    return {x = ctx.read8(y + INIT_X), rows = ctx.read8(y + NUM_ROWS), cols = ctx.read8(y + NUM_COLS), cursor = ctx.read8(y)}
end
local function wait_for(ctx, n, test)
    for _ = 1, n do
        if ctx.stop() then return false end
        if test() then return true end
        ctx.advance()
    end
    return test()
end
local function cursor_to(ctx, row)
    for _ = 1, 8 do
        local at = ctx.read8(ctx.cursorY)
        if at == row then return true end
        ctx.press(at < row and "Down" or "Up")
        for _ = 1, 6 do ctx.frame() end
    end
    return ctx.read8(ctx.cursorY) == row
end

local function yes_no(m) return m.rows == 2 and m.cols == 1 and (m.cursor == 1 or m.cursor == 2) end

function M.answer(ctx, slot)
    -- "Delete an older move...?"
    if not wait_for(ctx, 900, function() return yes_no(menu(ctx)) end) then return false, "the YES/NO box never came up" end
    for _ = 1, 20 do ctx.frame() end
    local box = menu(ctx)
    if slot then
        if not cursor_to(ctx, 1) then return false, "couldn't get onto YES" end
        ctx.press("A")
        -- the move list
        -- (ForgetMove: wNumMoves + 1 rows - a CANCEL row below the four)
        local ok = wait_for(ctx, 300, function() local m = menu(ctx); return (m.rows == 5 or m.rows == 4) and m.cols == 1 and m.x ~= box.x end)
        if not ok then return false, "the move list didn't come up" end
        for _ = 1, 20 do ctx.frame() end
        if not cursor_to(ctx, slot) then return false, "couldn't get onto the move" end
        ctx.press("A")
        ctx.log(string.format("forgetting move %d for the new one", slot))
        return true
    end
    if not cursor_to(ctx, 2) then return false, "couldn't get onto NO" end
    ctx.press("A")
    -- "Stop learning X?" - a new box, its cursor back on YES
    local ok = wait_for(ctx, 300, function() local m = menu(ctx); return yes_no(m) and m.cursor == 1 end)
    if not ok then return false, "the 'Stop learning?' box didn't come up" end
    for _ = 1, 20 do ctx.frame() end
    if not cursor_to(ctx, 1) then return false, "couldn't get onto YES" end
    ctx.press("A")
    ctx.log("skipped the new move")
    return true
end

return M

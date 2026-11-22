-- lead_trapper.lua (lives in modules/data/)
-- Smart catching (the user, 2026-11-22): "if there are teleport users on
-- that route the bot should lead with a mean look user". A wild Teleport
-- user that's awake gets no switch (a switch hands it a free turn to leave),
-- so the trapper has to be out from the start.
--
-- note(): after each battle, the wild one's moves (still in the enemy battle
-- struct) - Teleport marks this map. want(): on a marked map, with a lead
-- that can't trap and someone behind it who can (Mean Look / Spider Web with
-- PP, not an egg, not fainted), that one's slot. swap(): Start > POKEMON >
-- that Pokemon > SWITCH > the first slot, driven like data/potions.lua
-- (same ctx), SWITCH found in the submenu list the game builds (its size
-- changes with the field moves the Pokemon knows: CUT, FLY, SURF...).
-- Plain - tested offline (scratchpad v130/test_lead_trapper.lua) and in the
-- stress harness.

local M = {}

M.TRAP = {[212] = true, [169] = true}   -- Mean Look, Spider Web
M.TELEPORT = 100
M.marked = {}          -- "group:number" -> true: a Teleport user was met here
M.tries = {}           -- "group:number" -> swaps tried (gives up after 3)
M.MAX_TRIES = 3

local EGG = 0xFD
local MON, MOVES, PP, HP = 0x30, 0x02, 0x17, 0x22
local STARTMENU_POKEMON = 1  -- start_menu.asm's STARTMENUITEM_POKEMON
local MONMENUITEM_SWITCH = 16 -- menu_constants.asm
local INIT_X, NUM_ROWS, JOYPAD_FILTER = -7, -6, -1
local A_OR_B = 0x03

-- The enemy battle struct's moves: true if one is Teleport. base = the
-- struct (species at +0, moves at +2..+5). species: the encounter's, so a
-- struct left over from another battle never counts.
function M.note(read8, base, species, mapKey)
    if read8(base) ~= species or species == 0 then return false end
    for i = 2, 5 do
        if read8(base + i) == M.TELEPORT then
            if not M.marked[mapKey] then M.marked[mapKey] = true; return true end
            return false
        end
    end
    return false
end

local function knows_trap(read8, mon)
    for i = 0, 3 do
        if M.TRAP[read8(mon + MOVES + i)] and read8(mon + PP + i) % 64 > 0 then return true end
    end
    return false
end

-- The slot (0-based) to put in front, or nil. partyCount = wPartyCount
-- (the species list follows it, the party structs at +8).
function M.want(read8, read16, partyCount, mapKey)
    if not M.marked[mapKey] or (M.tries[mapKey] or 0) >= M.MAX_TRIES then return nil end
    local n = math.min(read8(partyCount), 6)
    local lead
    for s = 0, n - 1 do
        local mon = partyCount + 8 + s * MON
        if read8(partyCount + 1 + s) ~= EGG and read16(mon + HP) > 0 then
            if lead == nil then
                lead = s
                if knows_trap(read8, mon) then return nil end      -- already in front
            elseif knows_trap(read8, mon) then
                return s
            end
        end
    end
    return nil
end

-- Moves wMenuCursorY to row (1-based); true once there.
local function to_row(ctx, row)
    for _ = 1, 10 do
        local cy = ctx.read8(ctx.cursorYAddr)
        if cy == row then return true end
        ctx.press(cy < row and "Down" or "Up")
        if not ctx.wait(10) then return false end
    end
    return ctx.read8(ctx.cursorYAddr) == row
end

-- Puts party slot `from` (0-based) in front. ctx as data/potions.lua's,
-- plus submenuAddr (wMonSubmenuCount, the items right after it).
-- Returns true; or false, why. Every menu is closed again either way.
function M.swap(ctx, from)
    local log = ctx.log or function() end
    local function fail(why) log("stopped: " .. why); ctx.back_out(); return false, why end
    local pc = ctx.partyCountAddr
    local function species_at(s) return ctx.read8(pc + 1 + s) end
    local wantFront, wantBack = species_at(from), species_at(0)
    local function menu_x() return ctx.read8(ctx.cursorYAddr + INIT_X) end
    local function menu_rows() return ctx.read8(ctx.cursorYAddr + NUM_ROWS) end
    local function menu_buttons() return ctx.read8(ctx.cursorYAddr + JOYPAD_FILTER) end
    local count = ctx.read8(pc)
    local function on_party_screen()
        return menu_x() == 0 and menu_rows() == count + 1 and menu_buttons() == A_OR_B
    end

    -- standing still first (a step into grass under the menus starts a battle)
    if ctx.idle then
        local still = 0
        for _ = 1, 120 do
            if not ctx.wait(1) then return fail("a battle started") end
            still = ctx.idle() and still + 1 or 0
            if still >= 10 then break end
        end
        if still < 10 then return fail("the player never stood still") end
    end

    -- Start: POKEMON's row from the list the game builds (as potions.lua)
    ctx.write8(ctx.menuItemsAddr, 0)
    local row
    for _ = 1, 5 do
        ctx.press("Start")
        for _ = 1, 24 do
            if not ctx.wait(5) then return fail("a battle started") end
            local n = ctx.read8(ctx.menuItemsAddr)
            if n >= 1 and n <= 10 then
                for i = 1, n do if ctx.read8(ctx.menuItemsAddr + i) == STARTMENU_POKEMON then row = i end end
                local cy = ctx.read8(ctx.cursorYAddr)
                if row and cy >= 1 and cy <= n and menu_x() ~= 0 then break end
                row = nil
            end
        end
        if row then break end
        if not ctx.wait(10) then return fail("a battle started") end
    end
    if row == nil then return fail("the Start menu didn't open") end
    if not ctx.wait(10) then return fail("a battle started") end
    if not to_row(ctx, row) then return fail("couldn't get to POKEMON") end
    log(string.format("Start menu open, POKEMON is row %d", row))

    -- POKEMON -> the party screen (loads its graphics first)
    local ok = false
    for _ = 1, 4 do
        ctx.press("A")
        for _ = 1, 30 do
            if not ctx.wait(5) then return fail("a battle started") end
            if on_party_screen() then ok = true; break end
        end
        if ok then break end
    end
    if not ok then return fail("the party screen didn't open") end
    if not ctx.wait(30) then return fail("a battle started") end
    if not to_row(ctx, from + 1) then return fail("couldn't put the cursor on row " .. (from + 1)) end

    -- The Pokemon -> its submenu: field moves, STATS, SWITCH, ITEM, CANCEL.
    -- The count is cleared first, so it only reads right once the game
    -- built the list for this Pokemon.
    ctx.write8(ctx.submenuAddr, 0)
    local switchRow
    for _ = 1, 4 do
        ctx.press("A")
        for _ = 1, 30 do
            if not ctx.wait(5) then return fail("a battle started") end
            local n = ctx.read8(ctx.submenuAddr)
            if n >= 2 and n <= 9 and menu_rows() == n and menu_x() ~= 0 then
                for i = 1, n do if ctx.read8(ctx.submenuAddr + i) == MONMENUITEM_SWITCH then switchRow = i end end
                if switchRow then break end
            end
        end
        if switchRow or not on_party_screen() then break end
    end
    if switchRow == nil then return fail("its submenu didn't open") end
    if not ctx.wait(10) then return fail("a battle started") end
    log(string.format("submenu open: %d rows, SWITCH is row %d", ctx.read8(ctx.submenuAddr), switchRow))
    if not to_row(ctx, switchRow) then return fail("couldn't get to SWITCH") end

    -- SWITCH -> "Move to where?": the party screen again
    -- (SwitchPartyMons: InitPartyMenuNoCancel - one row a Pokemon, no
    -- CANCEL. The normal party menu's data - one row more - comes back for
    -- a moment first as the submenu closes; matching that, the A meant for
    -- row 1 opened its submenu instead. In-game test, 2026-11-22.)
    local function on_switch_screen()
        return menu_x() == 0 and menu_rows() == count and menu_buttons() == A_OR_B
    end
    -- (A again only while the submenu is still up on SWITCH: an A that went
    -- through must never be followed by one on the switch screen)
    local subRows = ctx.read8(ctx.submenuAddr)
    local function on_switch_row()
        return menu_x() ~= 0 and menu_rows() == subRows and ctx.read8(ctx.cursorYAddr) == switchRow
    end
    ok = false
    for _ = 1, 4 do
        ctx.press("A")
        for _ = 1, 40 do
            if not ctx.wait(5) then return fail("a battle started") end
            if on_switch_screen() then ok = true; break end
        end
        if ok or not on_switch_row() then break end
    end
    if not ok then return fail(string.format("the switch screen didn't open (column %d, rows %d)", menu_x(), menu_rows())) end
    if not ctx.wait(20) then return fail("a battle started") end
    log(string.format("switch screen: %d rows, cursor on row %d", menu_rows(), ctx.read8(ctx.cursorYAddr)))
    if not to_row(ctx, 1) then return fail("couldn't put the cursor on row 1") end

    -- row 1 -> the swap: done once the species list reads the new order.
    -- A again only while the switch screen is still up on row 1.
    local function swapped() return species_at(0) == wantFront and species_at(from) == wantBack end
    for _ = 1, 4 do
        ctx.press("A")
        for _ = 1, 30 do
            if not ctx.wait(5) then return fail("a battle started") end
            if swapped() then break end
        end
        if swapped() or not (on_switch_screen() and ctx.read8(ctx.cursorYAddr) == 1) then break end
    end
    if not swapped() then return fail("the order didn't change") end
    ctx.wait(30)
    ctx.back_out()
    return true
end

return M

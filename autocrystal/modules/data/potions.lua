-- data/potions.lua
-- Kill mode's "Use potions" (General Settings): back in the overworld after
-- a battle, if the Pokemon that fights next is at LOW_HP or less, it drinks
-- potions from the Items pocket (Start > PACK > the potion > USE) until it's
-- above that again. Shared by wild.lua, fishing.lua and headbutt.lua: each
-- passes its own addresses and button helpers (see M.heal's ctx).
--
-- Nothing here counts button presses: every menu remembers where it was
-- (the Start menu its row, the Pack its pocket and cursor, the party screen
-- its cursor), so each step reads where the cursor is and moves from there.

local M = {}

-- At or below this share of max HP Kill mode stops attacking (the modules'
-- LOW_HP_FLEE_THRESHOLD) - and, with "Use potions" on, heals after the battle.
M.LOW_HP = 0.25
-- Most potions in one go: a pocket of small Potions against a big HP bar
-- shouldn't empty itself in one sitting.
M.MAX_IN_A_ROW = 6

local FULL = 9999
-- Item ID -> HP healed (Gen 2's HealHP amounts). Max Potion comes before
-- Full Restore when both would do. Not used: Energy Powder and Energy Root
-- (they lower friendship) and Berries (often kept to hold).
M.HEAL = {
    [139] = 20,       -- Berry Juice
    [18] = 20,        -- Potion
    [17] = 50,        -- Super Potion
    [46] = 50,        -- Fresh Water
    [47] = 60,        -- Soda Pop
    [48] = 80,        -- Lemonade
    [72] = 100,       -- Moomoo Milk
    [16] = 200,       -- Hyper Potion
    [15] = FULL,      -- Max Potion
    [14] = FULL + 1,  -- Full Restore
}

-- After the first potion: another one only while the HP still missing is
-- at least what it heals (nothing wasted) - the biggest such one. nil once
-- every potion left would heal more than is missing.
function M.pick_more(list, missing)
    local best
    for _, it in ipairs(list) do
        local heal = M.HEAL[it.id]
        if heal and it.qty > 0 and heal <= missing and (best == nil or heal > M.HEAL[best]) then best = it.id end
    end
    return best, best and M.HEAL[best]
end

local STARTMENU_PACK = 2   -- start_menu.asm's STARTMENUITEM_PACK
-- The 2D menu block right before wMenuCursorY (same layout in Crystal and
-- Gold/Silver): w2DMenuCursorInitX, w2DMenuNumRows, wMenuJoypadFilter.
local INIT_X, NUM_ROWS, JOYPAD_FILTER = -7, -6, -1
local A_OR_B = 0x03
local SCROLL_BUTTONS = 0xC0 -- D_UP | D_DOWN: only a scrolling menu (the Pack list) exits on them
local EGG = 0xFD
local PARTY_MON_SIZE, MON_HP, MON_MAXHP = 0x30, 0x22, 0x24

-- The Items pocket: {id, qty} in pocket order. wItems is pairs of
-- (item, quantity) ending in $FF; the pocket holds 20.
function M.items(read8, itemsAddr)
    local list = {}
    for i = 0, 19 do
        local id = read8(itemsAddr + i * 2)
        if id == 0xFF or id == 0 then break end
        list[#list + 1] = {id = id, qty = read8(itemsAddr + i * 2 + 1)}
    end
    return list
end

-- The potion for `missing` HP: the smallest that heals all of it, or the
-- biggest there is when none does. nil when the pocket has none.
function M.pick(list, missing)
    local fits, biggest
    for _, it in ipairs(list) do
        local heal = M.HEAL[it.id]
        if heal and it.qty > 0 then
            if heal >= missing and (fits == nil or heal < M.HEAL[fits]) then fits = it.id end
            if biggest == nil or heal > M.HEAL[biggest] then biggest = it.id end
        end
    end
    local id = fits or biggest
    return id, id and M.HEAL[id]
end

-- The Pokemon Kill mode fights with next: the first in the party that
-- isn't fainted (or an egg). Returns its 0-based slot, HP and max HP.
function M.next_fighter(read8, read16, partyCountAddr)
    local count = read8(partyCountAddr)
    if count < 1 or count > 6 then return nil end
    for slot = 0, count - 1 do
        if read8(partyCountAddr + 1 + slot) ~= EGG then
            local mon = partyCountAddr + 8 + slot * PARTY_MON_SIZE
            local hp, maxHP = read16(mon + MON_HP), read16(mon + MON_MAXHP)
            if hp > 0 and maxHP > 0 then return slot, hp, maxHP end
        end
    end
    return nil
end

function M.hp_addr(partyCountAddr, slot)
    return partyCountAddr + 8 + slot * PARTY_MON_SIZE + MON_HP
end

local function index_of(list, id)
    for i, it in ipairs(list) do
        if it.id == id then return i end
    end
    return nil
end

-- Moves wMenuCursorY to row (1-based) with Up/Down; true once it's there.
local function to_row(ctx, row)
    for _ = 1, 10 do
        local cy = ctx.read8(ctx.cursorYAddr)
        if cy == row then return true end
        ctx.press(cy < row and "Down" or "Up")
        if not ctx.wait(10) then return false end
    end
    return ctx.read8(ctx.cursorYAddr) == row
end

-- Uses itemId on party slot `slot`, from the overworld. ctx:
--   read8(addr), read16(addr)
--   press(button)            one press (the module's press_button)
--   wait(frames) -> bool     advances; false once Stop is pressed or a
--                            battle has started
--   back_out()               B until every menu is closed (B never confirms
--                            anything; spare presses in the overworld do
--                            nothing)
--   write8(addr, value)
--   log(text)                one line to the log, for every step
--   idle() -> bool           optional: true while the player stands still
--   menuItemsAddr            wMenuItemsList: the Start menu's entries
--   cursorYAddr              wMenuCursorY (Start menu, Pack submenu and
--                            party screen all use it)
--   curItemAddr, itemsAddr   wCurItem, wItems
--   partyCountAddr           wPartyCount
-- Returns true, the HP after; or false, why. Every menu is closed again
-- either way.
function M.use(ctx, itemId, slot)
    local log = ctx.log or function() end
    local function fail(why) log("stopped: " .. why); ctx.back_out(); return false, why end

    -- Not mid-step: a step into grass that rolls an encounter would start a
    -- battle under the menus.
    if ctx.idle then
        local still = 0
        for _ = 1, 120 do
            if not ctx.wait(1) then return fail("a battle started") end
            still = ctx.idle() and still + 1 or 0
            if still >= 10 then break end
        end
        if still < 10 then return fail("the player never stood still") end
    end

    -- How each menu is told apart: the 2D menu block right before
    -- wMenuCursorY, which every menu sets up as it opens (until then
    -- wMenuCursorY and wCurItem still hold the previous menu's values, and
    -- a button pressed in the meantime is lost).
    local function menu_x() return ctx.read8(ctx.cursorYAddr + INIT_X) end
    local function menu_rows() return ctx.read8(ctx.cursorYAddr + NUM_ROWS) end
    local function menu_buttons() return ctx.read8(ctx.cursorYAddr + JOYPAD_FILTER) end
    local function menu_state()
        return string.format("menu column %d, rows %d, buttons %d", menu_x(), menu_rows(), menu_buttons())
    end

    -- Like the ball code's A presses until the throw goes through - but a
    -- press is only repeated while the menu it was meant for is still up
    -- with the cursor where it was, so a late one can't land on the next
    -- screen. true once done() holds; false, why otherwise.
    local function press_until(button, done, still_here, what)
        for _ = 1, 4 do
            ctx.press(button)
            for _ = 1, 8 do
                if not ctx.wait(5) then return false, "a battle started" end
                if done() then return true end
            end
            if not still_here() then
                -- Moved on, just not (yet) where it was meant to: a moment
                -- more before calling it.
                for _ = 1, 12 do
                    if not ctx.wait(5) then return false, "a battle started" end
                    if done() then return true end
                end
                return false, what .. " (" .. menu_state() .. ")"
            end
        end
        return false, what .. " after 4 presses (" .. menu_state() .. ")"
    end

    -- Start: the menu lists only what you have (no POKEDEX early on), so
    -- PACK's row comes from the list the game builds as it opens. Its count
    -- is cleared first, so the list only reads right once the menu really
    -- is open (a press can be swallowed - then a Down would walk instead of
    -- moving a cursor). The list shares its bytes only with script scratch
    -- (a trainer spotting you, fruit trees, item balls), set fresh before
    -- every use.
    ctx.write8(ctx.menuItemsAddr, 0)
    ctx.press("Start")
    local packRow, count
    for _ = 1, 24 do
        if not ctx.wait(5) then return fail("a battle started") end
        count = ctx.read8(ctx.menuItemsAddr)
        if count >= 1 and count <= 10 then
            for i = 1, count do
                if ctx.read8(ctx.menuItemsAddr + i) == STARTMENU_PACK then packRow = i end
            end
            local cy = ctx.read8(ctx.cursorYAddr)
            if packRow and cy >= 1 and cy <= count and menu_x() ~= 0 and menu_buttons() & SCROLL_BUTTONS == 0 then break end
            packRow = nil
        end
    end
    if packRow == nil then return fail("the Start menu didn't open") end
    if not ctx.wait(10) then return fail("a battle started") end
    local startX = menu_x()
    log(string.format("Start menu open, PACK is row %d, cursor on row %d", packRow, ctx.read8(ctx.cursorYAddr)))
    if not to_row(ctx, packRow) then return fail("couldn't get to PACK") end

    -- PACK -> the Pack. Its item list is a scrolling menu: the only one here
    -- whose buttons include Up and Down (it scrolls past its edges).
    local function pack_open()
        return menu_x() ~= startX and menu_buttons() & SCROLL_BUTTONS == SCROLL_BUTTONS
    end
    local ok, why = press_until("A", pack_open, function()
        return menu_x() == startX and ctx.read8(ctx.cursorYAddr) == packRow
    end, "the Pack didn't open")
    if not ok then return fail(why) end
    if not ctx.wait(10) then return fail("a battle started") end

    -- The Pack remembers its pocket: Items is the one whose highlighted
    -- item is in wItems. The cursor can sit on CANCEL under the list, so
    -- one Up on each pocket before moving Right to the next.
    local function on_items()
        return index_of(M.items(ctx.read8, ctx.itemsAddr), ctx.read8(ctx.curItemAddr)) ~= nil
    end
    local found = on_items()
    for _ = 1, 5 do
        if found then break end
        ctx.press("Up")
        if not ctx.wait(10) then return fail("a battle started") end
        found = on_items()
        if found then break end
        ctx.press("Right")
        if not ctx.wait(20) then return fail("a battle started") end
        found = on_items()
    end
    if not found then return fail("couldn't find the Items pocket") end
    log(string.format("Items pocket open, cursor on item %d", ctx.read8(ctx.curItemAddr)))

    -- Up or Down to it, checking wCurItem after every press.
    local selected = false
    for _ = 1, 30 do
        local list = M.items(ctx.read8, ctx.itemsAddr)
        local cur = ctx.read8(ctx.curItemAddr)
        if cur == itemId then selected = true; break end
        local target, here = index_of(list, itemId), index_of(list, cur)
        if target == nil then break end
        ctx.press((here == nil or here > target) and "Up" or "Down")
        if not ctx.wait(8) then return fail("a battle started") end
    end
    if not selected then return fail("couldn't find it in the Items pocket") end
    if not ctx.wait(10) then return fail("a battle started") end
    log(string.format("on item %d (%s)", itemId, menu_state()))

    -- The item -> the USE / GIVE / TOSS / QUIT box (pack.asm's
    -- MenuHeader_UsableItem): 4 rows, further right than the list, and not
    -- a scrolling menu.
    local packX = menu_x()
    local function box_open()
        local x = menu_x()
        return menu_rows() == 4 and x ~= packX and x ~= 0 and menu_buttons() & SCROLL_BUTTONS == 0
    end
    ok, why = press_until("A", box_open, function()
        return menu_x() == packX and ctx.read8(ctx.curItemAddr) == itemId
    end, "the USE box didn't open")
    if not ok then return fail(why) end
    if not ctx.wait(10) then return fail("a battle started") end
    if not to_row(ctx, 1) then return fail(string.format("couldn't get to USE (cursor on row %d)", ctx.read8(ctx.cursorYAddr))) end
    log("on USE")

    -- USE -> the party screen. It loads its graphics and redraws everything
    -- before it takes a button. It's set up once InitPartyMenuWithCancel has
    -- run: cursor column 0, one row per Pokemon plus CANCEL, A and B only.
    local boxX = menu_x()
    local partyCount = ctx.read8(ctx.partyCountAddr)
    local function on_party_screen()
        return menu_x() == 0 and menu_rows() == partyCount + 1 and menu_buttons() == A_OR_B
    end
    ok, why = press_until("A", on_party_screen, function()
        return menu_x() == boxX and ctx.read8(ctx.cursorYAddr) == 1
    end, "the party screen didn't open")
    if not ok then return fail(why) end
    if not ctx.wait(30) then return fail("a battle started") end

    -- Onto the Pokemon to heal (rows count from 1), then A. The game writes
    -- the new HP the moment it's picked (RestoreHealth, before the bar
    -- animates), so that's the sign it went through. A again only while
    -- the party screen is still up with the cursor on that Pokemon - never
    -- an A that could land on another one.
    local row = slot + 1
    local hpAddr = M.hp_addr(ctx.partyCountAddr, slot)
    local before = ctx.read16(hpAddr)
    if not to_row(ctx, row) then
        return fail(string.format("couldn't put the party cursor on row %d (it's on row %d)", row, ctx.read8(ctx.cursorYAddr)))
    end
    log(string.format("party screen, cursor on row %d, HP %d", row, before))
    ok, why = press_until("A", function() return ctx.read16(hpAddr) > before end, function()
        return on_party_screen() and ctx.read8(ctx.cursorYAddr) == row
    end, string.format("its HP didn't go up (still %d)", before))
    if not ok then return fail(why) end
    -- The bar fills and "...HP was restored" waits for a button; back_out's
    -- B answers it and closes the Pack and the Start menu.
    ctx.wait(90)
    ctx.back_out()
    return true, ctx.read16(hpAddr)
end

return M

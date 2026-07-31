-- diagnose_pack_menu.lua
-- STANDALONE diagnostic - not a launcher module. Run this directly in
-- BizHawk's Lua console while manually playing.
--
-- Purpose: we want to build auto-catch (navigate to Pack, select a ball,
-- throw it), but the Pack menu is a scrolling, variable-length list -
-- unlike the main battle menu's fixed 2x2 Fight/Pack/Pokemon/Run grid,
-- there's no single obvious "cursor position" address we've already
-- verified for this. This watches several promising candidates found in
-- the symbol file and prints whenever any of them change, so we can see
-- which one(s) actually track cursor movement/selection in practice
-- rather than guessing.
--
-- HOW TO USE: start this running, then manually: open the battle menu,
-- select PACK, scroll up/down through your items a few times, select a
-- Poke Ball (or whatever ball you have), throw it, and let the battle
-- resolve (caught or broke free). Watch the console the whole time.
--
-- Candidates being watched (all found via direct symbol lookup, none
-- confirmed yet for this specific purpose):
--   wCurItem / wCurItemQuantity - might directly store the currently
--     highlighted item's ID/quantity, which would be immediately useful
--     without needing to cross-reference the bag list at all.
--   wListPointer - generic list-cursor tracking used by multiple menus.
--   wMenuScrollPosition - scroll offset for menus longer than one screen.
--   MENU_CURSOR_Y/X - the same address the battle menu's Fight/Pack/
--     Pokemon/Run grid uses, in case the Pack menu reuses it too.

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

local ItemNames = require("data.item_names")

local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)

local wNumItems, wItems, wCurItem, wCurItemQuantity, wListPointer, wMenuScrollPosition
local MENU_CURSOR_Y, MENU_CURSOR_X
local enemy_species_addr

if version == 0x55 or version == 0x58 then
    print("Gold/Silver detected")
    wNumItems = 0xD5B7
    wItems = 0xD5B8
    wCurItem = 0xD002
    wCurItemQuantity = 0xD003
    wListPointer = 0xCFFC
    wMenuScrollPosition = 0xCFD4
    MENU_CURSOR_Y = 0xCEE0
    MENU_CURSOR_X = 0xCEE1
    if region == 0x4A then
        enemy_species_addr = 0xD9E8 + 0x22
    elseif region == 0x4B then
        enemy_species_addr = 0xDB1F + 0x22
    else
        enemy_species_addr = 0xD0F5 + 0x22
    end
else
    print("Crystal detected")
    wNumItems = 0xD892
    wItems = 0xD893
    wCurItem = 0xD106
    wCurItemQuantity = 0xD107
    wListPointer = 0xD100
    wMenuScrollPosition = 0xD0E4
    MENU_CURSOR_Y = 0xCFA9
    MENU_CURSOR_X = 0xCFAA
    if region == 0x4A then
        enemy_species_addr = 0xD23D + 0x22
    else
        enemy_species_addr = 0xD20C + 0x22
    end
end

local function get_item_name(id)
    if id == 0 or id == 0xFF then return "(none)" end
    return ItemNames[id] or ("Unknown item #" .. tostring(id))
end

-- Print bag contents once at start, so we can directly verify our
-- reading of wNumItems/wItems is correct against what you can see on
-- your own screen in the Pack menu.
local numItems = memory.readbyte(wNumItems)
print(string.format("=== Bag contents (wNumItems=%d) ===", numItems))
for i = 0, 19 do
    local itemId = memory.readbyte(wItems + i * 2)
    local qty = memory.readbyte(wItems + i * 2 + 1)
    if itemId == 0xFF then
        print(string.format("  [slot %d] terminator (0xFF) - end of list", i))
        break
    end
    print(string.format("  [slot %d] %s x%d (id=%d)", i, get_item_name(itemId), qty, itemId))
end
print("=== End bag contents ===")
print("")
print("Now manually: open battle menu -> PACK -> scroll around -> select a ball -> throw it.")
print("Watching for changes in: wCurItem, wCurItemQuantity, wListPointer, wMenuScrollPosition, cursor Y/X")
print("")

local lastCurItem, lastCurItemQty, lastListPointer, lastScrollPos, lastCursorY, lastCursorX
local lastSpecies = memory.readbyte(enemy_species_addr)

while true do
    local curItem = memory.readbyte(wCurItem)
    local curItemQty = memory.readbyte(wCurItemQuantity)
    local listPointer = memory.readbyte(wListPointer)
    local scrollPos = memory.readbyte(wMenuScrollPosition)
    local cursorY = memory.readbyte(MENU_CURSOR_Y)
    local cursorX = memory.readbyte(MENU_CURSOR_X)
    local species = memory.readbyte(enemy_species_addr)

    if curItem ~= lastCurItem or curItemQty ~= lastCurItemQty then
        print(string.format("[FRAME %d] wCurItem changed: %d->%d (%s) | wCurItemQuantity: %d->%d",
            emu.framecount(), lastCurItem or -1, curItem, get_item_name(curItem), lastCurItemQty or -1, curItemQty))
        lastCurItem, lastCurItemQty = curItem, curItemQty
    end
    if listPointer ~= lastListPointer then
        print(string.format("[FRAME %d] wListPointer changed: %d -> %d", emu.framecount(), lastListPointer or -1, listPointer))
        lastListPointer = listPointer
    end
    if scrollPos ~= lastScrollPos then
        print(string.format("[FRAME %d] wMenuScrollPosition changed: %d -> %d", emu.framecount(), lastScrollPos or -1, scrollPos))
        lastScrollPos = scrollPos
    end
    if cursorY ~= lastCursorY or cursorX ~= lastCursorX then
        print(string.format("[FRAME %d] Cursor Y/X changed: (%d,%d) -> (%d,%d)",
            emu.framecount(), lastCursorY or -1, lastCursorX or -1, cursorY, cursorX))
        lastCursorY, lastCursorX = cursorY, cursorX
    end
    if species ~= lastSpecies then
        print(string.format("[FRAME %d] Enemy species_addr changed: %d -> %d (0=no enemy/battle ended)",
            emu.framecount(), lastSpecies, species))
        lastSpecies = species
    end

    emu.frameadvance()
end

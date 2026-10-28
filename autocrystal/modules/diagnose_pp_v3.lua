-- diagnose_pp_v2.lua
--
-- Same as diagnose_pp.lua, but this time we cycle through all 8 possible
-- WRAM banks (via the SVBK register at $FF70) for the switchable
-- $D000-$DFFF region, instead of only seeing whatever bank happened to
-- be active at the moment we read memory. The bank-switch itself is
-- "free" (doesn't require a frame to take effect) and we restore the
-- original bank immediately after each peek, so the game's actual
-- execution is never disturbed.
--
-- HOW TO USE: same as before - sit at the main battle menu, cursor on
-- FIGHT, first move has >1 PP left, then load this script.

local FIXED_START = 0xC000
local FIXED_END   = 0xCFFF
local SWITCH_START = 0xD000
local SWITCH_END   = 0xDFFF
local SVBK_ADDR = 0xFF70

local MENU_CURSOR_Y = 0xCFA9
local MENU_CURSOR_X = 0xCFAA
local FIGHT_CURSOR = {y = 1, x = 1}

local function snapshot_all_banks()
    local originalSvbk = memory.readbyte(SVBK_ADDR)
    local snap = { fixed = {}, banks = {} }

    for addr = FIXED_START, FIXED_END do
        snap.fixed[addr] = memory.readbyte(addr)
    end

    for bank = 0, 7 do
        memory.writebyte(SVBK_ADDR, bank)
        local bankData = {}
        for addr = SWITCH_START, SWITCH_END do
            bankData[addr] = memory.readbyte(addr)
        end
        snap.banks[bank] = bankData
    end

    memory.writebyte(SVBK_ADDR, originalSvbk)
    return snap
end

local function press_button(btn)
    for i = 1, 4 do
        joypad.set({[btn] = true})
        emu.frameadvance()
    end
    emu.frameadvance()
end

print("=== PP diagnostic v2 (all WRAM banks) starting ===")
print("Make sure you're at the main battle menu with cursor on FIGHT, and")
print("your first move has more than 1 PP left.")

local before = snapshot_all_banks()

local attempts = 0
while attempts < 10 do
    local cy, cx = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
    if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
        print("Selecting FIGHT...")
        press_button("A")
        break
    end
    attempts = attempts + 1
    if cy < FIGHT_CURSOR.y then press_button("Down")
    elseif cy > FIGHT_CURSOR.y then press_button("Up")
    elseif cx < FIGHT_CURSOR.x then press_button("Right")
    else press_button("Left") end
end

for i = 1, 15 do emu.frameadvance() end
print("Using first move...")
press_button("A")

-- Generous wait - the "Pokemon used MOVE!" text animation alone can take
-- a while to fully print out, and if PP is written only after that
-- resolves (not the instant the move is confirmed), a short wait would
-- snapshot too early and miss the change entirely.
for i = 1, 200 do emu.frameadvance() end

local after = snapshot_all_banks()

print("")
print("Fixed bank ($C000-$CFFF) addresses that decreased by exactly 1:")
local found = 0
for addr = FIXED_START, FIXED_END do
    if before.fixed[addr] - after.fixed[addr] == 1 then
        print(string.format("  $%04X: %d -> %d", addr, before.fixed[addr], after.fixed[addr]))
        found = found + 1
    end
end

for bank = 0, 7 do
    for addr = SWITCH_START, SWITCH_END do
        local b = before.banks[bank][addr]
        local a = after.banks[bank][addr]
        if b - a == 1 then
            print(string.format("  [bank %d] $%04X: %d -> %d", bank, addr, b, a))
            found = found + 1
        end
    end
end

if found == 0 then
    print("  None found across any bank. Something else may have interrupted the sequence.")
end

print(string.format("Total candidates found: %d", found))
print("=== Diagnostic complete ===")

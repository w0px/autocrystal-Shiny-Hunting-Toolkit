-- diagnose_menu_cursor.lua
--
-- HOW TO USE:
-- 1. Get into a wild battle so the main battle menu (FIGHT/PKMN/PACK/RUN)
--    is on screen, cursor sitting on FIGHT (the default position).
-- 2. Load this script in the Lua Console. It runs once and stops (no loop).
-- 3. Read the final printed list - that's your real cursor address.
--
-- WHY THIS WORKS BETTER THAN MANUAL RAM SEARCH:
-- It presses Right, Down, Left, Up in one uninterrupted sequence (a full
-- loop: FIGHT -> PKMN -> RUN -> PACK -> back to FIGHT), snapshotting all of
-- WRAM before and after each press. No real time passes between snapshots,
-- so free-running counters/timers can't sneak in as false positives - and
-- the final check (does the byte return to its ORIGINAL value after the
-- full loop back to FIGHT?) is something a random ticking counter almost
-- never does by coincidence.

local SCAN_START = 0xC000
local SCAN_END   = 0xDFFF

local function snapshot()
    local snap = {}
    for addr = SCAN_START, SCAN_END do
        snap[addr] = memory.readbyte(addr)
    end
    return snap
end

local function press(btn)
    for i = 1, 4 do
        joypad.set({[btn] = true})
        emu.frameadvance()
    end
    joypad.set({[btn] = false})
    emu.frameadvance()
end

local function count(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

print("=== Menu cursor diagnostic starting ===")
print("Make sure the battle menu is on screen RIGHT NOW, cursor on FIGHT.")
print("Snapshotting...")

local initial = snapshot()
local before = initial
local candidates = nil

local sequence = {"Right", "Down", "Left", "Up"} -- FIGHT->PKMN->RUN->PACK->FIGHT

for _, dir in ipairs(sequence) do
    press(dir)
    local after = snapshot()

    local changed = {}
    for addr = SCAN_START, SCAN_END do
        if before[addr] ~= after[addr] then
            changed[addr] = {from = before[addr], to = after[addr]}
        end
    end

    print(string.format("After pressing %s: %d bytes changed", dir, count(changed)))

    if candidates == nil then
        candidates = {}
        for addr in pairs(changed) do candidates[addr] = true end
    else
        local narrowed = {}
        for addr in pairs(candidates) do
            if changed[addr] then narrowed[addr] = true end
        end
        candidates = narrowed
    end

    before = after
end

print("")
print("=== Addresses that changed on EVERY press AND returned to their")
print("    original value after the full loop back to FIGHT: ===")

local final = before
local found_any = false
for addr = SCAN_START, SCAN_END do
    if candidates[addr] and final[addr] == initial[addr] then
        print(string.format("  $%04X  (started at %d)", addr, initial[addr]))
        found_any = true
    end
end

if not found_any then
    print("  None found. Possible causes:")
    print("  - The cursor wasn't actually on FIGHT when the script started")
    print("  - A button press didn't register (try again)")
    print("  - The scan range doesn't cover it (unlikely, but possible)")
end

print("=== Diagnostic complete ===")

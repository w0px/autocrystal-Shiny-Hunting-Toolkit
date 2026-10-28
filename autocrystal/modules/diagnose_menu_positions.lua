-- diagnose_menu_positions.lua
--
-- HOW TO USE:
-- Get into a wild battle, battle menu on screen, cursor on FIGHT (default).
-- Load this script. It moves FIGHT -> PKMN -> RUN -> PACK, printing the
-- value of each candidate address at every stop. No action needed from you.

local CANDIDATES = {0xC0A3, 0xC0A4, 0xC0A5, 0xCFAC}

local function read_all()
    local vals = {}
    for _, addr in ipairs(CANDIDATES) do
        vals[addr] = memory.readbyte(addr)
    end
    return vals
end

local function print_vals(label, vals)
    local line = label .. ": "
    for _, addr in ipairs(CANDIDATES) do
        line = line .. string.format("$%04X=%d  ", addr, vals[addr])
    end
    print(line)
end

local function press(btn)
    for i = 1, 4 do
        joypad.set({[btn] = true})
        emu.frameadvance()
    end
    joypad.set({[btn] = false})
    emu.frameadvance()
end

print("=== Menu position diagnostic ===")
print("Assuming cursor starts on FIGHT right now.")

print_vals("FIGHT", read_all())

press("Right") -- FIGHT -> PKMN
print_vals("PKMN ", read_all())

press("Down") -- PKMN -> RUN
print_vals("RUN  ", read_all())

press("Left") -- RUN -> PACK
print_vals("PACK ", read_all())

print("=== Diagnostic complete ===")
print("Look at the RUN row above - that's the value(s) we need for RUN_CURSOR.")

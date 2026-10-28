-- diagnose_menu_positions_v2.lua
--
-- HOW TO USE:
-- Get into a wild battle, battle menu on screen, cursor on FIGHT (default).
-- Load this script. It moves FIGHT -> PKMN -> RUN -> PACK. At EACH stop it
-- takes 6 readings, one per frame, WITHOUT pressing anything - this exposes
-- any byte that flickers due to cursor-blink animation rather than truly
-- representing menu position (that's what caught out $CFAC last time).

local CANDIDATES = {0xC0A3, 0xC0A4, 0xC0A5, 0xCFAC, 0xCFA9, 0xCFAA}

local function read_all()
    local vals = {}
    for _, addr in ipairs(CANDIDATES) do
        vals[addr] = memory.readbyte(addr)
    end
    return vals
end

local function press(btn)
    for i = 1, 4 do
        joypad.set({[btn] = true})
        emu.frameadvance()
    end
    joypad.set({[btn] = false})
    emu.frameadvance()
end

-- Take several readings over several frames while NOT pressing anything,
-- to catch bytes that change on their own (animation/blink) rather than
-- only in response to input.
local function sample_stability(label)
    print(label .. ":")
    local readings = {}
    for _, addr in ipairs(CANDIDATES) do readings[addr] = {} end

    for frame = 1, 6 do
        local vals = read_all()
        for _, addr in ipairs(CANDIDATES) do
            table.insert(readings[addr], vals[addr])
        end
        emu.frameadvance()
    end

    for _, addr in ipairs(CANDIDATES) do
        local vs = readings[addr]
        local stable = true
        for i = 2, #vs do
            if vs[i] ~= vs[1] then stable = false end
        end
        local tag = stable and "STABLE" or "FLICKERS"
        local line = string.format("  $%04X [%s]: ", addr, tag)
        for _, v in ipairs(vs) do line = line .. v .. " " end
        print(line)
    end
end

print("=== Menu position stability diagnostic ===")
print("Assuming cursor starts on FIGHT right now.")

sample_stability("FIGHT")

press("Right") -- FIGHT -> PKMN
sample_stability("PKMN")

press("Down") -- PKMN -> RUN
sample_stability("RUN")

press("Left") -- RUN -> PACK
sample_stability("PACK")

print("=== Diagnostic complete ===")
print("Only trust addresses marked STABLE at every position.")
print("Among those, find one with a distinct value for RUN vs the others.")

-- diagnose_daytime.lua
--
-- HOW TO USE:
-- 1. Open your Pokegear's clock (or just know the current in-game time)
--    so you know what the REAL time of day should be.
-- 2. Load this script anywhere in the overworld (not mid-battle).
-- 3. Compare the printed value for each bank against what you'd expect:
--      1 = Morning, 2 = Day, 4 = Night
--    Whichever bank shows a value matching reality is the real one.
--
-- This uses the same "peek every bank without disturbing the game"
-- technique that found the real PP address earlier - writes to SVBK
-- only to read each bank's $D269, then restores the original bank
-- immediately, all without ever calling emu.frameadvance() in between.

local SVBK_ADDR = 0xFF70
local TARGET_ADDR = 0xD269

local originalSvbk = memory.readbyte(SVBK_ADDR)

print("=== Daytime bank scan ===")
print(string.format("Current SVBK (bank mapped at $D000-$DFFF): %d", originalSvbk & 0x07))
print("")

for bank = 0, 7 do
    memory.writebyte(SVBK_ADDR, bank)
    local value = memory.readbyte(TARGET_ADDR)
    local guess = ""
    if value == 1 then guess = " <- looks like Morning"
    elseif value == 2 then guess = " <- looks like Day"
    elseif value == 4 then guess = " <- looks like Night"
    end
    print(string.format("  bank %d: $D269 = %d%s", bank, value, guess))
end

memory.writebyte(SVBK_ADDR, originalSvbk)

print("")
print("Compare against your Pokegear's actual clock to confirm which bank is real.")
print("=== Scan complete ===")

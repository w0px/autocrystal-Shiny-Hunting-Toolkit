-- diagnose_starter_dv.lua
--
-- Checks whether the starter DV address ($DCF4 for Crystal EU/US, i.e.
-- base_address + 0x1D) is affected by GBC's WRAM bank-switching the same
-- way $D269 (daytime) turned out to be. If the value read differs
-- depending on which bank is active, our flat reads could be pulling
-- wrong data - which would explain "DVs vary but never actually match
-- a shiny" even after tens of thousands of attempts.
--
-- HOW TO USE: get a starter normally (once, for real) so a party member
-- actually exists, then load this script. It scans all 8 WRAM banks for
-- both DV bytes simultaneously - no need to catch anything mid-action.

local SVBK_ADDR = 0xFF70

-- Crystal EU/US base address (adjust if you're on a different version/region)
local base_address = 0xDCD7
local dv_addr = base_address + 0x1D

local originalSvbk = memory.readbyte(SVBK_ADDR)

print("=== Starter DV bank scan ===")
print(string.format("dv_addr = $%04X, dv_addr+1 = $%04X", dv_addr, dv_addr + 1))
print(string.format("Current SVBK bank: %d", originalSvbk & 0x07))
print("")

for bank = 0, 7 do
    memory.writebyte(SVBK_ADDR, bank)
    local atkdef = memory.readbyte(dv_addr)
    local spespc = memory.readbyte(dv_addr + 1)
    print(string.format("  bank %d: atkdef=$%02X spespc=$%02X", bank, atkdef, spespc))
end

memory.writebyte(SVBK_ADDR, originalSvbk)

print("")
print("If these values differ significantly across banks, dv_addr is bank-switchable")
print("and our flat reads may be unreliable depending on which bank happens to be active.")
print("If they're all the SAME (or only bank-0/1 match, which are hardware-identical),")
print("dv_addr is safe as-is and the bug is somewhere else.")
print("=== Scan complete ===")

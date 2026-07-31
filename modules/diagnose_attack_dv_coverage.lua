-- diagnose_attack_dv_coverage.lua
--
-- STANDALONE DIAGNOSTIC - not part of the main launcher, run this on
-- its own directly from BizHawk's Lua Console.
--
-- WHY THIS EXISTS: our large-scale coverage tests (thousands of resets
-- on Starters, Egg, and Wild) showed 95-100% unique-combination
-- coverage across the full 65536-value DV space, confirming the RNG
-- isn't SEVERELY structurally limited. But that measures the whole
-- space in aggregate - it cannot tell us whether a SMALL subset, like
-- the 8 specific Attack DV values that make a Pokemon eligible to be
-- shiny (2, 3, 6, 7, 10, 11, 14, 15 - see rng_manipulation_writeup.md
-- for why it's exactly these 8), are being reached evenly. Since
-- shinies themselves are rare (~1/8192), you'd need many thousands of
-- ACTUAL shinies before the overall shiny rate alone could reveal an
-- uneven distribution among just 8 buckets. This script instead
-- tallies the Attack DV of EVERY reset, shiny or not, which gives a
-- direct, fast answer without needing to wait for rare full shiny hits.
--
-- HOW TO USE:
-- 1. Load this script directly in the Lua Console (Open Script).
--    Do NOT run it alongside the main launcher - this drives its own
--    resets and inputs, they would conflict.
-- 2. It gives you a 5-second countdown after loading - during that
--    window, stand exactly where you'd normally talk to the day-care
--    man / delivery NPC to receive a fresh egg. It saves its own state
--    to slot 9 (separate from the main bot's slots 3/4) once the
--    countdown ends, then starts resetting automatically.
-- 3. Watch the console for a running tally every 100 resets, or check
--    attack_dv_coverage.txt in this folder at any time - it's updated
--    after every single reset, so you can check progress without
--    stopping the script.
--
-- If one or more of the 8 values comes back at noticeably lower count
-- than the others after a few thousand resets, that's a real signal
-- worth investigating further. If they're all within normal
-- statistical range of each other, the coverage is confirmed healthy
-- down to this level of detail.

local DIAG_SAVESTATE_SLOT = 9
local RESULTS_FILE = "attack_dv_coverage.txt"
local PRINT_EVERY = 100

-- The 8 Attack DV values that satisfy the shiny condition's bit-1
-- requirement (see the binary-pattern explanation in this session's
-- chat history / rng_manipulation_writeup.md).
local SHINY_ATTACK_VALUES = {2, 3, 6, 7, 10, 11, 14, 15}

local tally = {}
for _, v in ipairs(SHINY_ATTACK_VALUES) do
    tally[v] = 0
end
local otherCount = 0 -- attack DVs NOT in the shiny-eligible set
local totalResets = 0

-- ===== Region / address detection (same logic as egg.lua) =====
local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)
local party_base_addr

if version == 0x54 then
    if region == 0x4A then party_base_addr = 0xDC9D
    elseif region == 0x45 then party_base_addr = 0xDCD7
    else party_base_addr = 0xDCD7 end
elseif version == 0x55 or version == 0x58 then
    if region == 0x4A then party_base_addr = 0xD9E8
    elseif region == 0x45 then party_base_addr = 0xDA22
    elseif region == 0x4B then party_base_addr = 0xDB1F
    else party_base_addr = 0xDA22 end
else
    print("No valid ROM detected (version byte = " .. version .. ") - stopping.")
    return
end

print(string.format("Detected version byte = $%02X, region byte = $%02X", version, region))
print(string.format("Detected party_base_addr = $%04X", party_base_addr))

-- ===== Minimal button press helper (same timing as the main bot) =====
local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    joypad.set({})
    emu.frameadvance()
end

-- ===== Save results to disk after every reset =====
local function save_results()
    local f = io.open(RESULTS_FILE, "w")
    if not f then
        print("WARNING: could not write " .. RESULTS_FILE)
        return
    end
    f:write(string.format("Attack DV coverage diagnostic - %d total resets\n\n", totalResets))
    f:write("Shiny-eligible Attack DV values (2,3,6,7,10,11,14,15):\n")
    for _, v in ipairs(SHINY_ATTACK_VALUES) do
        local expected = totalResets * (1/16)
        f:write(string.format("  Attack=%2d : %6d hits  (expected if even: ~%.0f)\n", v, tally[v], expected))
    end
    f:write(string.format("\nAttack DVs outside the shiny-eligible set: %d\n", otherCount))
    f:close()
end

-- ===== First-time setup: save our own diagnostic savestate =====
print("=== Attack DV Coverage Diagnostic ===")
print("")
print("GET IN POSITION NOW: stand exactly where you'd normally talk to")
print("the day-care man / delivery NPC to receive a fresh egg.")
print("Saving in 5 seconds...")
for countdown = 5, 1, -1 do
    print(tostring(countdown) .. "...")
    for i = 1, 60 do emu.frameadvance() end -- ~1 second at normal speed
end
print("Saving diagnostic state to slot " .. DIAG_SAVESTATE_SLOT .. " now.")
savestate.saveslot(DIAG_SAVESTATE_SLOT)

local partysizeBeforeReceiving = memory.readbyte(party_base_addr)
local eggSlotIndex = partysizeBeforeReceiving
local eggDvAddr = party_base_addr + 0x1D + eggSlotIndex * 0x30

print(string.format("Egg slot index = %d, DV address = $%04X", eggSlotIndex, eggDvAddr))
print("Starting resets now...")

-- ===== Main loop =====
while true do
    savestate.loadslot(DIAG_SAVESTATE_SLOT)

    -- 8-way split delay, matching egg.lua's proven approach
    print(string.format("[reset %d] waiting through 8-way split delay...", totalResets + 1))
    for split = 1, 8 do
        local waitFrames = math.random(1, 256)
        for i = 1, waitFrames do
            emu.frameadvance()
        end
    end

    -- Mash through the delivery dialogue until the egg is actually
    -- added to the party.
    print(string.format("[reset %d] mashing through delivery dialogue...", totalResets + 1))
    local mashAttempts = 0
    while memory.readbyte(party_base_addr) <= partysizeBeforeReceiving and mashAttempts < 400 do
        press_button("A")
        mashAttempts = mashAttempts + 1
        if mashAttempts % 50 == 0 then
            print(string.format("  ...still mashing (%d/400 attempts, raw party_base_addr byte = %d, partysizeBeforeReceiving was %d)",
                mashAttempts, memory.readbyte(party_base_addr), partysizeBeforeReceiving))
        end
    end

    if memory.readbyte(party_base_addr) <= partysizeBeforeReceiving then
        print("WARNING: egg not received after 400 A-presses - stopping. Check your starting position.")
        break
    end

    -- Short settle wait before reading, same caution as the main module
    for i = 1, 10 do emu.frameadvance() end

    local atkdef = memory.readbyte(eggDvAddr)
    local atk = math.floor(atkdef / 16)

    totalResets = totalResets + 1
    if tally[atk] ~= nil then
        tally[atk] = tally[atk] + 1
    else
        otherCount = otherCount + 1
    end

    save_results()
    print(string.format("[reset %d] Attack DV = %d - %s", totalResets, atk,
        (tally[atk] ~= nil) and "shiny-eligible bucket" or "not in the 8 shiny-eligible values"))

    if totalResets % PRINT_EVERY == 0 then
        print(string.format("--- %d resets ---", totalResets))
        for _, v in ipairs(SHINY_ATTACK_VALUES) do
            print(string.format("  Attack=%2d : %d hits", v, tally[v]))
        end
    end
end

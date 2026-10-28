-- diagnose_rng_split_delay.lua
--
-- Tests whether splitting a random delay into TWO separate delays, with
-- a button press (triggering game logic / more Random() calls) in
-- between, produces MORE unique RNG outcomes than the delays would give
-- individually - i.e. whether they combine MULTIPLICATIVELY (5x5=25
-- possible outcomes from two small delays - great, means we could reach
-- large coverage with a much smaller average wait) or just ADDITIVELY
-- (no real benefit over one single combined delay of the same size).
--
-- HOW TO USE: same as before - load while sitting on a valid savestate
-- in slot 3.

local HRANDOMADD = 0xFFE1
local HRANDOMSUB = 0xFFE2

local function press_a()
    for i = 1, 4 do
        joypad.set({A = true})
        emu.frameadvance()
    end
    emu.frameadvance()
end

local testValues = {0, 64, 128, 192, 255}

print("=== Split-delay RNG test ===")
print("delay1 | delay2 | hRandomAdd | hRandomSub")

local seen = {}
local uniqueCount = 0
local total = 0

for _, d1 in ipairs(testValues) do
    for _, d2 in ipairs(testValues) do
        savestate.loadslot(3)
        for i = 1, d1 do emu.frameadvance() end
        press_a() -- game action in between, to see if it re-mixes the RNG independently
        for i = 1, d2 do emu.frameadvance() end

        local add = memory.readbyte(HRANDOMADD)
        local sub = memory.readbyte(HRANDOMSUB)
        local key = add .. "," .. sub
        local isNew = not seen[key]
        if isNew then
            seen[key] = true
            uniqueCount = uniqueCount + 1
        end
        total = total + 1

        print(string.format("%6d | %6d | $%02X | $%02X%s", d1, d2, add, sub, isNew and "" or "  (repeat)"))
    end
end

print("")
print(string.format("%d unique out of %d combinations tested", uniqueCount, total))
print("Close to 25 (5x5): splitting is MULTIPLICATIVE - great news, means small split delays could cover a lot of ground fast.")
print("Close to 9 (5+5-1, same as one combined delay): splitting adds NOTHING - no benefit over a single delay of equal total size.")
print("=== Test complete ===")

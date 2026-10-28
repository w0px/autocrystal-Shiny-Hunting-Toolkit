-- diagnose_rng_coverage.lua
--
-- General-purpose test (not Starters-specific): from a FIXED savestate,
-- reloads and waits a range of different extra-frame delays, reading the
-- actual RNG state bytes (hRandomAdd/hRandomSub, $FFE1/$FFE2 in Crystal)
-- after each. This tells us empirically how much delay is actually
-- needed for good coverage, instead of guessing - directly applicable
-- to any reset-based module (Starters, Egg, future Static/Game Corner).
--
-- HOW TO USE: load this while sitting on an existing savestate in slot 3
-- (the same slot Starters already uses - any valid state works, this
-- isn't testing anything Starters-specific, just the RNG mechanism).

local HRANDOMADD = 0xFFE1
local HRANDOMSUB = 0xFFE2

local delays = {0, 1, 2, 3, 5, 10, 15, 20, 30, 50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000}

print("=== RNG coverage scan ===")
print("delay_frames | hRandomAdd | hRandomSub")

local seen = {}
local uniqueCount = 0

for _, delay in ipairs(delays) do
    savestate.loadslot(3)
    for i = 1, delay do emu.frameadvance() end

    local add = memory.readbyte(HRANDOMADD)
    local sub = memory.readbyte(HRANDOMSUB)
    local key = add .. "," .. sub

    local isNew = not seen[key]
    if isNew then
        seen[key] = true
        uniqueCount = uniqueCount + 1
    end

    print(string.format("%5d | $%02X | $%02X%s", delay, add, sub, isNew and "" or "  (repeat)"))
end

print("")
print(string.format("%d unique (add,sub) pairs out of %d delays tested", uniqueCount, #delays))
print("=== Scan complete ===")

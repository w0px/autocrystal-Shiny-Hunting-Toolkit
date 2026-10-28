-- rng_enabler.lua (lives in data/)
-- Shared utility for any reset-based module (Starters, Egg, future
-- Static Encounters, Game Corner, etc.).
--
-- The RNG itself isn't broken or buggy - hRandomAdd/hRandomSub mixing
-- with rDIV (confirmed via the pokecrystal disassembly) works exactly
-- as designed, every time. The actual problem is that BizHawk's PERFECT
-- determinism means reloading the same savestate restores the exact
-- same RNG state every time - so replaying identical inputs afterward
-- suppresses the natural timing variance a real, organic play session
-- would have. This module doesn't break anything - it restores/enables
-- that missing variance on purpose.
--
-- CONFIRMED VIA DIRECT MEASUREMENT (reading hRandomAdd/hRandomSub across
-- a range of post-reload delays from a fixed savestate): every tested
-- delay value - including a difference of just ONE frame - produced a
-- completely different RNG state. There's no small repeating cycle to
-- work around; the RNG is genuinely high-entropy at the frame level.
--
-- THE CATCH: because BizHawk is perfectly deterministic, each specific
-- delay value maps to one specific, fixed outcome. This means your
-- delay RANGE directly caps how many of the 65536 possible DV
-- combinations are even reachable - a range of 1-30 can only ever reach
-- 30 of them, no matter how many times you reset. There's no guarantee
-- any shiny-producing state happens to fall within an arbitrarily
-- chosen subset.
--
-- To genuinely guarantee reaching every possible outcome with a SINGLE
-- delay, the range would need to cover the full space (at least 65536),
-- trading a much higher average wait for a real guarantee. In practice,
-- use the SPLIT approach below instead - two smaller delays at
-- different points cover nearly as much ground for a fraction of the
-- average wait.

local M = {}

-- Use this if you want a single delay that genuinely covers the full
-- space on its own - slow (average wait ~35000 frames) but complete.
M.FULL_COVERAGE_RANGE = 70000 -- >65536 for margin

-- PREFERRED: confirmed via direct measurement (diagnose_rng_split_delay.lua)
-- that splitting a delay into two smaller ones at different points, with
-- real game logic in between, produces close to multiplicative coverage
-- (19/25 unique in a 5x5 test) rather than just collapsing into an
-- equivalent single combined delay. Two of these, at two different
-- points in a reset sequence, can cover up to 256x256=65536 combinations
-- for a much smaller average total wait (~250-300 frames) than one
-- single 70000-frame delay.
M.SPLIT_RANGE = 256

function M.enable_randomness(range)
    range = range or M.FULL_COVERAGE_RANGE
    local extraFrames = math.random(1, range)
    for i = 1, extraFrames do
        emu.frameadvance()
    end
    return extraFrames
end

return M

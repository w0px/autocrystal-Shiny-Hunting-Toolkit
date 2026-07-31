-- print_slot1_friendship.lua
--
-- STANDALONE - run this on its own in BizHawk's Lua Console. Prints
-- the current party slot 1 Pokemon's friendship/happiness value
-- whenever it changes, so you can watch it update in real time while
-- playing normally (rather than spamming the console every frame).
--
-- Verified via pokecrystal.sym: wPartyMon1Happiness at $DCFA.

-- Verified via pokecrystal.sym: wPartyMon1Happiness at $DCFA.
-- Evolution threshold confirmed at 220 - happiness-based evolutions
-- (Golbat->Crobat, Chansey->Blissey, Eevee->Espeon/Umbreon, Pichu/
-- Cleffa/Igglybuff/Togepi's baby evolutions) trigger on the next level
-- up once happiness reaches this value.
local FRIENDSHIP_ADDR = 0xDCFA
local EVOLUTION_THRESHOLD = 220

local function status_for(value)
    if value >= EVOLUTION_THRESHOLD then
        return " - EVOLUTION READY (needs a level up to trigger)"
    end
    return string.format(" - %d more needed to evolve", EVOLUTION_THRESHOLD - value)
end

local currentValue = memory.readbyte(FRIENDSHIP_ADDR)
print(string.format("Slot 1 friendship: %d%s", currentValue, status_for(currentValue)))

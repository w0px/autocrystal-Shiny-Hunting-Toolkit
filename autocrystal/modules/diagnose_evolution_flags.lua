-- diagnose_evolution_flags.lua
--
-- Standalone monitor - load this ALONGSIDE launcher.lua (BizHawk
-- supports running multiple Lua scripts at once, each in its own
-- console tab). Read-only, doesn't press any buttons or interfere with
-- the bot at all - just watches evolution-related flags every frame and
-- prints whenever any of them changes.
--
-- HOW TO USE: run your normal kill-mode session as usual with this
-- ALSO loaded. When a Pokemon is about to evolve (or a move-learn
-- prompt appears), watch this console. Note roughly when each change
-- happens relative to what you see on screen (e.g. "changed right when
-- the evolving animation started" vs "changed only after it finished").
--
-- Addresses from pokecrystal.sym - names suggest what they track, but
-- exact timing/semantics aren't independently verified yet, which is
-- exactly what this is for.

local WATCH = {
    {name = "wMonTriedToEvolve",   addr = 0xD268},
    {name = "wEvolutionCanceled",  addr = 0xD1ED},
    {name = "wForceEvolution",     addr = 0xD1E9},
    {name = "wEvolutionOldSpecies",addr = 0xD1EA},
    {name = "wEvolutionNewSpecies",addr = 0xD1EB},
}

local lastValues = {}
for _, w in ipairs(WATCH) do
    lastValues[w.name] = memory.readbyte(w.addr)
end

print("=== Evolution flag monitor started ===")
for _, w in ipairs(WATCH) do
    print(string.format("  watching %s ($%04X), starting value=%d", w.name, w.addr, lastValues[w.name]))
end
print("Play normally - this will print whenever any watched value changes.")

while true do
    for _, w in ipairs(WATCH) do
        local current = memory.readbyte(w.addr)
        if current ~= lastValues[w.name] then
            print(string.format("[frame %d] %s changed: %d -> %d", emu.framecount(), w.name, lastValues[w.name], current))
            lastValues[w.name] = current
        end
    end
    emu.frameadvance()
end

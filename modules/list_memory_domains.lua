-- list_memory_domains.lua
-- Prints every memory domain BizHawk exposes for this core, with sizes.
-- We're specifically looking for a WRAM-related domain LARGER than
-- 0x2000 (8KB) - that would mean it exposes all switchable banks at
-- once, rather than just whatever's currently paged into the CPU's
-- 0xC000-0xDFFF window (which is all our previous scans have seen).

print("=== Memory domains ===")
local domains = memory.getmemorydomainlist()
for _, name in ipairs(domains) do
    local size = memory.getmemorydomainsize(name)
    print(string.format("  %-20s size=0x%X (%d bytes)", name, size, size))
end

print("")
print("Current default domain: " .. memory.getcurrentmemorydomain())

-- Also check the GBC WRAM bank select register (SVBK, $FF70) if readable
-- from the default domain - tells us which bank was active just now.
local ok, svbk = pcall(memory.readbyte, 0xFF70)
if ok then
    print(string.format("SVBK ($FF70) = %d (WRAM bank currently mapped to $D000-$DFFF)", svbk))
end

print("=== Done ===")

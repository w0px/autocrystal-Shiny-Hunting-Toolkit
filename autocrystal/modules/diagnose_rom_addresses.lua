-- diagnose_rom_addresses.lua
--
-- Locates AutoCrystal's ROM-execution-hook landmarks (the addresses
-- Static/Wild/Fishing/Headbutt plant hooks at via RegisterROMHook) in
-- WHATEVER ROM is currently loaded - built specifically to check
-- localized Crystal builds (Italian, French, German, Spanish, etc.)
-- against the English addresses this project has always used.
--
-- WHY THIS EXISTS: AutoCrystal detects encounters/catches/menus by
-- planting hooks at literal ROM code addresses, all originally found via
-- the English-only pret/pokecrystal disassembly. A real bug report
-- (Italian Crystal, Snorlax static encounter never detected) confirmed
-- at least one of these - EnemyWildmonInitialized - lands somewhere
-- wrong on a localized build: translated dialogue/menu text is rarely
-- the same byte-length as the English text it replaces, so every ROM
-- address AFTER the first translated string in a bank shifts, even
-- though the game's WRAM/variable layout usually stays identical.
--
-- HOW IT WORKS: for each landmark, this ships a byte signature captured
-- from the verified English ROM, with the 2-byte target of any embedded
-- CALL/JP instruction wildcarded out (since whatever THAT points to may
-- have shifted too, even if the routine doing the calling hasn't). It
-- then scans your currently-loaded ROM's raw bytes for that pattern.
-- A unique match is very likely the real equivalent address on your
-- ROM; zero or multiple matches mean it couldn't be pinned down
-- automatically and needs manual work.
--
-- HOW TO USE: load your ROM in BizHawk (any version/language), then
-- open this script via the Lua Console (File > Open Script). It runs
-- once and prints/writes its results - no savestate or gameplay needed,
-- just a loaded ROM. Results also get written next to this script as
-- rom_address_scan_results.txt - if you're reporting a bug, please
-- paste that file's contents into the report.
--
-- This never reads or transmits your ROM anywhere - everything happens
-- locally in your own BizHawk session, and the output is just small
-- byte offsets, not any part of the ROM itself.

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"

-- Each signature: englishAddr (linear ROM offset, bank*0x4000 + offset
-- within bank - i.e. the same convention as a raw .gbc file's byte
-- offset) plus a masked byte pattern (false = wildcard) captured from
-- the verified English (USA, Europe) Crystal ROM (header version=0x54,
-- region=0x45). See rom_sig_tools/ in the project source for how these
-- were generated, if that ever needs redoing for a different base ROM.
local LANDMARKS = {
    LoadBattleMenuAddr = {
        englishAddr = 0x024EF2, -- bank 0x9, offset 0x4EF2
        sig = { 33, 44, 79, 205, false, false, 250, 210, 208, 234, 136, 207, 205, false, false, 250, 136, 207, 234, 210, 208, 205, false, false, 201, 33, 78, 79, 205, false, false, 24, 6 },
    },
    LearnMoveAddr = {
        englishAddr = 0x0424C5, -- bank 0x10, offset 0x64C5
        sig = { 122, 234, 98, 210, 234, 101, 210, 205, false, false, 205, false, false, 62, 0, 205, false, false, 225, 24, 195, 250, 8, 209, 234, 101, 210, 201, 229, 213, 197, 33, 177, 101 },
    },
    CatchSuccessAddr = {
        englishAddr = 0x00E9F5, -- bank 0x3, offset 0x69F5
        sig = { 33, 20, 210, 42, 245, 35, 42, 245, 126, 245, 229, 33, 7, 210, 126, 245, 229, 33, 113, 198, 126, 245, 203, 222, 203, 95, 32, 2, 24, 7, 62, 132 },
    },
    CatchFailAddr = {
        englishAddr = 0x00EBDC, -- bank 0x3, offset 0x6BDC
        sig = { 205, false, false, 205, false, false, 250, 48, 210, 254, 3, 200, 254, 2, 200, 254, 6, 40, 22, 250, 78, 198, 167, 40, 6, 205, false, false, 205, false, false, 33, 146, 216 },
    },
    MoveSelectionAddr = {
        englishAddr = 0x03E4BC, -- bank 0xF, offset 0x64BC
        sig = { 205, false, false, 32, 7, 62, 64, 33, 159, 75, 207, 201, 33, 8, 210, 250, 53, 210, 61, 40, 17, 61, 40, 9, 205, false, false, 200, 33, 46, 198, 24, 5 },
    },
    EnemyWildmonInitialized = {
        englishAddr = 0x03F648, -- bank 0xF, offset 0x7648
        sig = { 17, 0, 144, 62, 62, 205, false, false, 175, 234, 51, 210, 224, 173, 33, 172, 196, 1, 7, 7, 62, 19, 205, false, false, 201, 33, 8, 210, 17, 94, 210 },
    },
}

-- Same convention as data/memory.lua's LinearAddressToBank - kept
-- inline here so this script has zero dependencies and can be handed
-- to a tester as a single standalone file.
local function linear_to_bank_string(linear)
    local bankSize = 0x4000
    local bank = math.floor(linear / bankSize)
    local addr = linear % bankSize
    if bank > 0 then addr = addr | bankSize end
    return string.format("bank 0x%X : 0x%04X", bank, addr)
end

local outLines = {}
local function out(line)
    print(line)
    table.insert(outLines, line)
end

out("=== AutoCrystal ROM address scan ===")

local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)
out(string.format("Header version byte (0x141): 0x%02X", version))
out(string.format("Header region byte  (0x142): 0x%02X (%s)", region,
    region == 0x45 and "English" or
    region == 0x44 and "German" or
    region == 0x46 and "French" or
    region == 0x49 and "Italian" or
    region == 0x53 and "Spanish" or
    region == 0x4A and "Japanese" or
    region == 0x4B and "Korean" or
    "unknown"))
out("")

-- Figure out which memory domain exposes the raw ROM image. BizHawk's
-- Gambatte (GB/GBC) core exposes this as "ROM" in every version this
-- has been checked against, but domain names aren't guaranteed forever,
-- so this checks the live list rather than assuming.
--
-- memory.getmemorydomainlist() is documented as returning a single
-- newline-delimited string, but in practice (confirmed via a real
-- runtime error) it can come back as a plain Lua table of domain name
-- strings instead - handle both shapes rather than trusting the doc.
local domainListRaw = memory.getmemorydomainlist()
local domains = {}
if type(domainListRaw) == "string" then
    for line in domainListRaw:gmatch("[^\r\n]+") do
        table.insert(domains, line)
    end
elseif type(domainListRaw) == "table" then
    for _, line in ipairs(domainListRaw) do
        table.insert(domains, line)
    end
else
    out("Unexpected return type from memory.getmemorydomainlist(): " .. type(domainListRaw))
end

local romDomain = nil
for _, d in ipairs(domains) do
    if d == "ROM" then romDomain = d break end
end
if not romDomain then
    for _, d in ipairs(domains) do
        if d:lower() == "rom" then romDomain = d break end
    end
end

if not romDomain then
    out("Could not find a 'ROM' memory domain - this script only knows how to")
    out("handle BizHawk's usual Gambatte (GB/GBC) domain naming. Available")
    out("domains on this core:")
    for _, d in ipairs(domains) do
        out("  - " .. d)
    end
    out("")
    out("Please paste this whole output into the bug report - the domain name")
    out("above will tell us what to change.")
else
    local romSize = memory.getmemorydomainsize(romDomain)
    out(string.format("Reading %d bytes from the '%s' domain...", romSize, romDomain))
    local rom = memory.read_bytes_as_binary_string(0, romSize, romDomain)
    out("")

    -- Scans `rom` for `sig` (array of byte value or false=wildcard).
    -- Anchors on the first non-wildcard byte to keep this fast even
    -- against a multi-MB ROM.
    local function find_matches(rom, sig)
        local sigLen = #sig
        local anchorIdx, anchorVal
        for i, b in ipairs(sig) do
            if b ~= false then anchorIdx = i anchorVal = b break end
        end
        local matches = {}
        local anchorChar = string.char(anchorVal)
        local searchFrom = 1
        while true do
            local foundAt = rom:find(anchorChar, searchFrom, true)
            if not foundAt then break end
            local start = foundAt - (anchorIdx - 1)
            if start >= 1 and start + sigLen - 1 <= #rom then
                local ok = true
                for offset = 0, sigLen - 1 do
                    local want = sig[offset + 1]
                    if want ~= false then
                        local got = rom:byte(start + offset)
                        if got ~= want then ok = false break end
                    end
                end
                if ok then table.insert(matches, start - 1) end -- 0-indexed linear address
            end
            searchFrom = foundAt + 1
        end
        return matches
    end

    -- Fallback for when the exact scan above finds nothing: a real
    -- localized build can differ by more than just relocation (a couple
    -- of genuinely different bytes inside the routine itself, not just
    -- its called-address operands) - an exact byte-for-byte match then
    -- fails even though the routine is really only a few bytes away.
    -- This does a TOLERANT scan instead: same signature, but restricted
    -- to the English reference address's own ROM BANK (relocation to a
    -- totally different bank would be a much bigger, rarer change than
    -- intra-bank shifting) and allowing up to maxMismatch literal-byte
    -- differences rather than requiring zero. Reports the single best
    -- (fewest-mismatch) candidate, or all tied candidates if more than
    -- one shares the best score.
    local function tolerant_scan(rom, sig, englishAddr, maxMismatch)
        local sigLen = #sig
        local bankSize = 0x4000
        local bankStart = (englishAddr // bankSize) * bankSize
        local bankEnd = bankStart + bankSize
        local bestMismatch = maxMismatch + 1
        local bestStarts = {}
        for start = bankStart, math.min(bankEnd, #rom) - sigLen do
            local mism = 0
            for offset = 0, sigLen - 1 do
                local want = sig[offset + 1]
                if want ~= false then
                    if rom:byte(start + 1 + offset) ~= want then
                        mism = mism + 1
                        if mism > bestMismatch then break end
                    end
                end
            end
            if mism <= bestMismatch then
                if mism < bestMismatch then
                    bestMismatch = mism
                    bestStarts = { start }
                elseif mism == bestMismatch then
                    table.insert(bestStarts, start)
                end
            end
        end
        if bestMismatch > maxMismatch or #bestStarts == 0 then
            return nil
        end
        return bestMismatch, bestStarts
    end

    -- Deterministic order, not Lua's unspecified table iteration order,
    -- so results read the same every run.
    local order = { "EnemyWildmonInitialized", "LoadBattleMenuAddr", "MoveSelectionAddr",
                     "CatchSuccessAddr", "CatchFailAddr", "LearnMoveAddr" }

    for _, name in ipairs(order) do
        local info = LANDMARKS[name]
        local matches = find_matches(rom, info.sig)
        if #matches == 1 then
            out(string.format("%-26s FOUND, unique  -> 0x%06X (%s)   [English ref: 0x%06X]",
                name, matches[1], linear_to_bank_string(matches[1]), info.englishAddr))
        elseif #matches == 0 then
            out(string.format("%-26s NOT FOUND (0 exact matches)   [English ref: 0x%06X]",
                name, info.englishAddr))
            local mism, starts = tolerant_scan(rom, info.sig, info.englishAddr, 8)
            if mism then
                out(string.format("    Tolerant fallback (same bank, up to 8 byte differences allowed):"))
                for _, s in ipairs(starts) do
                    out(string.format("    - %d mismatched byte(s) -> 0x%06X (%s)", mism, s, linear_to_bank_string(s)))
                end
                if #starts > 1 then
                    out("    (multiple equally-good candidates - needs manual disambiguation)")
                end
            else
                out("    Tolerant fallback also found nothing within 8 byte differences in this bank -")
                out("    this one needs real manual investigation.")
            end
        else
            out(string.format("%-26s AMBIGUOUS (%d matches) - signature too generic, needs manual work   [English ref: 0x%06X]",
                name, #matches, info.englishAddr))
            for _, m in ipairs(matches) do
                out(string.format("    - 0x%06X (%s)", m, linear_to_bank_string(m)))
            end
        end
    end

    out("")
    if version == 0x54 and region == 0x45 then
        out("Note: this ROM's header already reports English Crystal (v0x54/region 0x45) -")
        out("every 'FOUND' address above should exactly match its English reference, since")
        out("that's exactly what was scanned. This mode is mainly useful as a sanity check")
        out("of the scan logic itself, or once new landmarks are added.")
    else
        out("Any 'FOUND, unique' address above is very likely correct for this ROM - please")
        out("include this whole output in the bug report so those can be added as this")
        out("localization's addresses. 'NOT FOUND' or 'AMBIGUOUS' entries need a closer look -")
        out("still worth including, they narrow down where the real problem is.")
    end
end

out("=== Scan complete ===")

local outPath = script_dir .. "rom_address_scan_results.txt"
local f = io.open(outPath, "w")
if f then
    f:write(table.concat(outLines, "\n"))
    f:write("\n")
    f:close()
    print("")
    print("Full results written to " .. outPath)
else
    print("")
    print("WARNING: couldn't write " .. outPath .. " - copy the console output above instead.")
end

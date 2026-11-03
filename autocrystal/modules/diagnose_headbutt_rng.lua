-- diagnose_headbutt_rng.lua
--
-- Logs Crystal's random-number state around every Headbutt encounter, to
-- work out why some tree Pokemon (Heracross on the "special" tree) almost
-- never come out shiny.
--
-- HOW THE GAME ROLLS: two RNG bytes, hRandomAdd and hRandomSub, move by the
-- hardware divider (DIV) once per frame in VBlank and once per Random call.
-- TreeMonEncounter picks the species from hRandomAdd (RandomRange 100), and
-- once the battle loads, LoadEnemyMon rolls the DVs from hRandomSub (two
-- BattleRandom calls). This script hooks every place those two bytes change,
-- plus the routines in between, and writes two files to autocrystal/logs/:
--   headbutt_rng_<time>_encounters.csv - one row per headbutt that reached
--     the species roll: the RNG state at the species roll and at the DV
--     roll, what advanced it in between, species and DVs, and the two
--     level bytes the battle-transition check compared (plus the code that
--     last wrote each of them).
--   headbutt_rng_<time>_trace.csv - every single RNG update from about 10
--     seconds before the headbutt through the DV roll, for the first
--     TRACE_ENCOUNTERS encounters and for every shiny.
--
-- HOW TO USE: start the bot in Headbutt mode at the tree as usual. Then
-- restore the Lua Console (the bot minimizes it), Script > Open Script, and
-- pick this file. It only watches - it never presses buttons or writes
-- memory, so the bot runs exactly as it would without it. Stop it from the
-- Lua Console once it has logged a few thousand headbutts.
--
-- English Crystal 1.0/1.1 only: every hooked routine's bytes are checked
-- against the loaded ROM first, and the script refuses to run otherwise.

-- The Lua Console even with Verbose Logging off - the launcher only shows
-- its own output there with it on (data/debug_log.lua).
local print = AutocrystalConsolePrint or print

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"

-- The battle transition calls Random dozens of times a frame (about 6000
-- calls in its first 160 frames), so one headbutt's trace runs to tens of
-- thousands of rows.
local TRACE_ENCOUNTERS = 20     -- full RNG traces for this many encounters (shinies always get one)
local PRE_UPDATES = 600         -- RNG updates kept from before each headbutt, about 10 seconds
local MAX_OPEN_UPDATES = 150000 -- an encounter that never reaches its DV roll is closed after this
local PROGRESS_EVERY = 100

local BUS = "System Bus"
local hRandomAdd, hRandomSub, hROMBank = 0xFFE1, 0xFFE2, 0xFF9D
local wEnemyMonSpecies, wEnemyMonDVs, wCurPartyLevel, wBattleType = 0xD206, 0xD20C, 0xD143, 0xD230
local wPlayerID, wMapGroup, wMapNumber, wYCoord, wXCoord = 0xD47B, 0xDCB5, 0xDCB6, 0xDCB7, 0xDCB8
local BATTLETYPE_TREE = 8
-- What StartTrainerBattle_DetermineWhichAnimation compares. Its own comment
-- in pokecrystal: these levels "are not set at this point", so the bytes
-- hold whatever was last written there - and the outdoor "stronger" result
-- is SpeckleToBlack, the only transition that calls Random.
local wBattleMonLevel, wEnemyMonLevel, wEnvironment, rSVBK = 0xC639, 0xD213, 0xD19A, 0xFF70
local CAVE_ENVIRONMENTS = {[4] = true, [5] = true, [7] = true}

local function log(msg) print("[RNG log] " .. msg) end

local function bytes(hex)
    return (hex:gsub("%s", ""):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function rom_linear(bank, addr)
    if bank == 0 then return addr end
    return bank * 0x4000 + addr - 0x4000
end

-- memory.getmemorydomainlist() can come back as a string or a table - see
-- diagnose_rom_addresses.lua.
local function has_domain(name)
    local list = memory.getmemorydomainlist()
    if type(list) == "string" then
        for line in list:gmatch("[^\r\n]+") do
            if line == name then return true end
        end
    elseif type(list) == "table" then
        for _, d in pairs(list) do
            if d == name then return true end
        end
    end
    return false
end

-- Bank 1 directly, whatever WRAM bank the game has switched in - see
-- FrameSearch.wram.
local wramDomain = has_domain("WRAM") and "WRAM" or nil
local function wram(addr)
    if wramDomain then return memory.readbyte(addr - 0xC000, wramDomain) end
    return memory.readbyte(addr, BUS)
end
local function hram(addr) return memory.readbyte(addr, BUS) end

-- Every hooked routine with its first bytes, identical in English Crystal
-- 1.0 and 1.1 (addresses from pokecrystal11.sym).
local LANDMARKS = {
    {"TreeMonEncounter",         0x2E, 0x41EA, "3E 41 21 EF 60 CF AF EA 2E D2 EA 43 D1"},
    {"SelectTreeMon",            0x2E, 0x441F, "3E 64 CD B1 2F 96 38 05 23 23 23 18 F8"},
    {"RandomRange",              0x00, 0x2FB1, "C5 4F AF 91 91 30 FD 81 47 C5 CD 8C 2F F0 E1 4F 80 38 F7"},
    {"_BattleRandom",            0x0F, 0x6DD8, "FA DC C2 A7 CA 8C 2F"},
    {"LoadEnemyMon",             0x0F, 0x68EB, "AF 21 06 D2 01 27 00 CD"},
    {"LoadEnemyMon.GenerateDVs", 0x0F, 0x69A0, "CD 9F 2F 47 CD 9F 2F 4F"},
    {"LoadEnemyMon.UpdateDVs",   0x0F, 0x69A8, "21 0C D2 78 22 71"},
    {"LoadEnemyMon.Happiness",   0x0F, 0x6A1A, "3E 46 EA 12"},
}
local SELECT_TREE_MON_LOOP = 0x4424 -- right after SelectTreeMon's call RandomRange
-- Optional: checked separately so a ROM without it still logs everything else.
local TRANSITION = {"StartTrainerBattle_DetermineWhichAnimation", 0x23, 0x4365, "11 00 00 FA 39 C6 C6 03 21 13 D2 BE 30 02 CB C3"}
-- ldh a,[rDIV] / ld b,a / ldh a,[hRandomAdd] / adc b / ldh [hRandomAdd],a,
-- then the same with sbc into hRandomSub. Random has it, and so does VBlank.
local RNG_UPDATE = bytes("F0 04 47 F0 E1 88 E0 E1 F0 04 47 F0 E2 98 E0 E2")

local function startup_problem()
    if not has_domain("ROM") then return "this core has no ROM memory domain" end
    for _, l in ipairs(LANDMARKS) do
        local want = bytes(l[4])
        if memory.read_bytes_as_binary_string(rom_linear(l[2], l[3]), #want, "ROM") ~= want then
            return string.format("%s isn't where English Crystal has it (%02X:%04X)", l[1], l[2], l[3])
        end
    end
end

local problem = startup_problem()
if problem then
    log("Not running: " .. problem .. ". This script only supports English Crystal 1.0/1.1.")
    return
end

-- Every copy of the update sequence in bank 0. Random starts with push bc;
-- any other copy is the per-frame update in VBlank.
local sites = {}
do
    local bank0 = memory.read_bytes_as_binary_string(0, 0x4000, "ROM")
    local from = 1
    while true do
        local i = bank0:find(RNG_UPDATE, from, true)
        if not i then break end
        sites[#sites + 1] = {start = i - 1, finish = i - 1 + #RNG_UPDATE,
            kind = bank0:byte(i - 1) == 0xC5 and "R" or "V"}
        from = i + 1
    end
    local randoms, vblanks = 0, 0
    for _, site in ipairs(sites) do
        if site.kind == "R" then randoms = randoms + 1 else vblanks = vblanks + 1 end
    end
    if randoms ~= 1 or vblanks == 0 then
        log(string.format("Not running: expected Random plus a VBlank RNG update in bank 0, found %d and %d.", randoms, vblanks))
        return
    end
end

local okF, regF = pcall(emu.getregister, "F")
local haveRegs = okF and type(regF) == "number"
local okC, cyc = pcall(emu.totalexecutedcycles)
local haveCycles = okC and type(cyc) == "number"
local function cycles()
    if haveCycles then return emu.totalexecutedcycles() end
end

local names = {}
do
    local ok, t = pcall(dofile, script_dir .. "../data/pokemon_names.lua")
    if ok and type(t) == "table" then names = t end
end
local function name_of(id) return names[id] or ("#" .. id) end

-- autocrystal/logs/, like the bot's own logs (data/paths.lua) - or next to
-- this file if that can't be loaded.
local outDir = script_dir
do
    local ok, paths = pcall(dofile, script_dir .. "data/paths.lua")
    if ok and type(paths) == "table" then
        paths.ensure(paths.LOG_DIR)
        outDir = paths.LOG_DIR
    end
end
local stamp = os.date("%Y%m%d_%H%M%S")
local encPath = outDir .. "headbutt_rng_" .. stamp .. "_encounters.csv"
local tracePath = outDir .. "headbutt_rng_" .. stamp .. "_trace.csv"
local encFile = io.open(encPath, "w")
local traceFile = encFile and io.open(tracePath, "w")
if not traceFile then
    if encFile then encFile:close() end
    log("Not running: couldn't create " .. encPath)
    return
end
encFile:write(string.format("# Crystal rev %d, trainer ID %d, started %s\n", memory.readbyte(0x14C, "ROM"),
    wram(wPlayerID) * 256 + wram(wPlayerID + 1), os.date("%Y-%m-%d %H:%M:%S")))
encFile:write("enc,outcome,frame,cycles,map_group,map_num,x,y,tree_add,tree_sub,"
    .. "roll_tries,roll_f,roll_add0,roll_sub0,roll_add,roll_sub,roll,roll_frame,"
    .. "mid_vblank,mid_random,mid_frames,items,dv_tries,"
    .. "dv1_f,dv1_add0,dv1_sub0,dv1_add,dv1_sub,dv2_f,dv2_add0,dv2_sub0,dv2_add,dv2_sub,"
    .. "dv_frame,dv_cycles,atkdef,spespc,ram_atkdef,ram_spespc,species,name,level,"
    .. "atk,def,spe,spc,shiny,v,"
    .. "trans_anim,trans_my_level,trans_enemy_level,trans_env,trans_svbk,"
    .. "my_level_writes,my_level_last_write,enemy_level_writes,enemy_level_last_write\n")
traceFile:write("enc,seq,frame,cycles,phase,try,site,f,add0,sub0,add1,sub1,nested\n")
encFile:flush()
traceFile:flush()

-- ===== RNG updates =====
-- Each update is a table: frame, cycles, f (CPU flags before it, so carry-in
-- is f & 0x10), add0/sub0 before, add1/sub1 after, site ("V" VBlank or "R"
-- Random), nested (another update finished inside this one - VBlank can
-- interrupt Random), seq, and phase/try once it belongs to an encounter.
local pending = {}
local updateCount = 0
local aChecks, aMatches = 0, 0

local ring, ringNext = {}, 1
local function ring_push(u)
    ring[ringNext] = u
    ringNext = ringNext % PRE_UPDATES + 1
end
local function ring_drain()
    local out = {}
    for k = 0, PRE_UPDATES - 1 do
        local u = ring[(ringNext - 1 + k) % PRE_UPDATES + 1]
        if u then out[#out + 1] = u end
    end
    ring, ringNext = {}, 1
    return out
end

-- ===== Encounters =====
-- enc.phase: tree (TreeMonEncounter entered), species (SelectTreeMon's
-- RandomRange), between (until LoadEnemyMon), item (held item rolls), dv
-- (GenerateDVs, try = attempt number), post (Magikarp/Unown checks that can
-- send it back to GenerateDVs).
local enc = nil
local encCount, shinyCount, speciesCount = 0, 0, {}

local function cell(x)
    if x == nil then return "" end
    if x == true then return "1" end
    if x == false then return "0" end
    return tostring(x)
end

local function progress()
    local parts = {}
    for nm, c in pairs(speciesCount) do parts[#parts + 1] = {nm, c} end
    table.sort(parts, function(a, b) return a[2] > b[2] end)
    for i, p in ipairs(parts) do parts[i] = p[1] .. " " .. p[2] end
    log(string.format("%d headbutts logged, %d shiny | %s", encCount, shinyCount, table.concat(parts, ", ")))
end

local function write_trace(n, e)
    local lines = {}
    local function add(u, phase)
        lines[#lines + 1] = table.concat({n, u.seq, u.frame, cell(u.cycles), phase, cell(u.try), u.site, cell(u.f),
            u.add0, u.sub0, u.add1, u.sub1, cell(u.nested)}, ",")
    end
    for _, u in ipairs(e.pre) do add(u, "pre") end
    for _, u in ipairs(e.updates) do add(u, u.phase) end
    if #lines > 0 then traceFile:write(table.concat(lines, "\n"), "\n") end
    traceFile:flush()
end

local function finish_encounter(outcome)
    local e = enc
    enc = nil
    local rollIdx, tries = nil, 0
    for i, u in ipairs(e.updates) do
        if u.phase == "species" and u.site == "R" then rollIdx, tries = i, tries + 1 end
    end
    if not rollIdx then
        -- Never reached the species roll (not a headbutt tree), so it's all
        -- still lead-up to the next headbutt.
        for _, u in ipairs(e.updates) do ring_push(u) end
        return
    end
    if outcome ~= "battle" then
        for i = rollIdx + 1, #e.updates do ring_push(e.updates[i]) end
    end

    local roll = e.updates[rollIdx]
    local firstDv, items, dv = nil, {}, {}
    for i = rollIdx + 1, #e.updates do
        local u = e.updates[i]
        if u.site == "R" and u.phase == "item" then items[#items + 1] = u.sub1 end
        if u.site == "R" and u.phase == "dv" then
            firstDv = firstDv or i
            if u.try == e.dvTries and #dv < 2 then dv[#dv + 1] = u end
        end
    end

    local row = {}
    local function put(...)
        for i = 1, select("#", ...) do row[#row + 1] = cell((select(i, ...))) end
    end
    encCount = encCount + 1
    local n = encCount
    put(n, outcome, e.frame, e.cycles, e.mapGroup, e.mapNumber, e.x, e.y, e.treeAdd, e.treeSub)
    put(tries, roll.f, roll.add0, roll.sub0, roll.add1, roll.sub1, roll.add1 < 200 and roll.add1 % 100 or nil, roll.frame)
    if firstDv then
        local midV, midR = 0, 0
        for i = rollIdx + 1, firstDv - 1 do
            if e.updates[i].site == "V" then midV = midV + 1 else midR = midR + 1 end
        end
        put(midV, midR, e.updates[firstDv].frame - roll.frame)
    else
        put(nil, nil, nil)
    end
    put(table.concat(items, ";"), e.dvTries)
    for k = 1, 2 do
        local d = dv[k]
        if d then put(d.f, d.add0, d.sub0, d.add1, d.sub1) else put(nil, nil, nil, nil, nil) end
    end

    local atkdef, spespc = dv[1] and dv[1].sub1, dv[2] and dv[2].sub1
    local species = 0
    local level, ramA, ramS
    if outcome == "battle" then
        species, level = wram(wEnemyMonSpecies), e.level
        ramA, ramS = wram(wEnemyMonDVs), wram(wEnemyMonDVs + 1)
    end
    put(dv[1] and dv[1].frame, dv[1] and dv[1].cycles, atkdef, spespc, ramA, ramS,
        species, species ~= 0 and name_of(species) or "none", level)
    local shiny = false
    if atkdef and spespc then
        shiny = spespc == 0xAA and atkdef % 16 == 0xA and (atkdef // 16) & 2 == 2
        put(atkdef // 16, atkdef % 16, spespc // 16, spespc % 16, shiny, (16 * atkdef - 15 * spespc) % 256)
    else
        put(nil, nil, nil, nil, nil, nil)
    end
    local t = e.trans
    if t then
        put(t.anim, t.myLevel, t.enemyLevel, t.env, t.svbk, t.myWrites, t.myLast, t.enemyWrites, t.enemyLast)
    else
        put(nil, nil, nil, nil, nil, nil, nil, nil, nil)
    end
    encFile:write(table.concat(row, ","), "\n")
    encFile:flush()

    if n <= TRACE_ENCOUNTERS or shiny then write_trace(n, e) end
    if outcome == "battle" then
        local nm = name_of(species)
        speciesCount[nm] = (speciesCount[nm] or 0) + 1
    end
    if shiny then
        shinyCount = shinyCount + 1
        log(string.format("Shiny %s logged (headbutt %d) - its full RNG trace is saved too.", name_of(species), n))
    end
    if n % PROGRESS_EVERY == 0 then progress() end
end

local function update_start(site)
    pending[site.start] = {
        frame = emu.framecount(),
        f = haveRegs and emu.getregister("F") or nil,
        add0 = hram(hRandomAdd),
        sub0 = hram(hRandomSub),
        doneBefore = updateCount,
    }
end

local function update_end(site)
    local u = pending[site.start]
    if not u then return end
    pending[site.start] = nil
    u.add1, u.sub1 = hram(hRandomAdd), hram(hRandomSub)
    u.site = site.kind
    u.nested = updateCount ~= u.doneBefore
    u.doneBefore = nil
    u.cycles = cycles()
    updateCount = updateCount + 1
    u.seq = updateCount

    -- Random leaves the new hRandomSub in A. If A doesn't match, register
    -- reads inside hooks are stale on this core and the flags column is
    -- noise, so stop logging it.
    if haveRegs and site.kind == "R" and aChecks < 200 then
        aChecks = aChecks + 1
        if emu.getregister("A") == u.sub1 then aMatches = aMatches + 1 end
        if aChecks == 200 then
            if aMatches >= 195 then
                log("CPU registers read fine inside the hooks - carry flags are logged.")
            else
                haveRegs = false
                log(string.format("CPU registers aren't reliable inside the hooks (%d/200) - carry flags left blank, that's fine.", aMatches))
            end
        end
    end

    if enc then
        u.phase = enc.phase
        if enc.phase == "dv" then u.try = enc.dvTries end
        enc.updates[#enc.updates + 1] = u
        if #enc.updates > MAX_OPEN_UPDATES then finish_encounter("timeout") end
    else
        ring_push(u)
    end
end

local function on_tree_encounter()
    if enc then finish_encounter("no battle") end
    enc = {
        phase = "tree", frame = emu.framecount(), cycles = cycles(),
        mapGroup = wram(wMapGroup), mapNumber = wram(wMapNumber), x = wram(wXCoord), y = wram(wYCoord),
        treeAdd = hram(hRandomAdd), treeSub = hram(hRandomSub),
        pre = ring_drain(), updates = {}, dvTries = 0,
    }
end

local function on_select_tree_mon()
    if enc and enc.phase == "tree" then enc.phase = "species" end
end

local function on_select_tree_mon_loop()
    if enc and enc.phase == "species" then enc.phase = "between" end
end

local function on_load_enemy_mon()
    if not (enc and enc.phase == "between") then return end
    if wram(wBattleType) ~= BATTLETYPE_TREE then
        finish_encounter("no battle")
        return
    end
    enc.phase = "item"
    enc.level = wram(wCurPartyLevel)
end

local function on_generate_dvs()
    if enc and (enc.phase == "item" or enc.phase == "post") then
        enc.phase = "dv"
        enc.dvTries = enc.dvTries + 1
    end
end

local function on_update_dvs()
    if enc and enc.phase == "dv" then enc.phase = "post" end
end

local function on_happiness()
    if enc and enc.phase == "post" then finish_encounter("battle") end
end

-- ===== Battle transition =====
-- Every write to the two level bytes since the last transition: how many,
-- and the last one as bank:PC=value. PC is where the CPU was when BizHawk
-- reported the write, so the writing instruction sits just before it.
local writes = {my = {count = 0}, enemy = {count = 0}}

local function note_write(w, val, addr)
    w.count = w.count + 1
    w.pc = haveRegs and emu.getregister("PC") or nil
    w.bank = hram(hROMBank)
    w.val = val or memory.readbyte(addr, BUS)
    w.svbk = hram(rSVBK) % 8
    w.frame = emu.framecount()
end

local function describe_write(w, now)
    if w.count == 0 then return "none" end
    local where = w.pc and string.format("%02X:%04X", w.pc < 0x4000 and 0 or w.bank, w.pc) or "?"
    return string.format("%s=%d (WRAM bank %d; %d frames before)", where, w.val, w.svbk, now - w.frame)
end

-- Reads the bytes the way the game's own check does (through whatever WRAM
-- bank is switched in) and works out which transition it picks.
local function on_transition()
    if not (enc and enc.phase == "between") or enc.trans then return end
    -- Only this headbutt's battle: a headbutt that found nothing stays open
    -- until the next one, and another battle in between isn't its transition.
    if wram(wBattleType) ~= BATTLETYPE_TREE or emu.framecount() - enc.frame > 600 then return end
    local myLevel, enemyLevel = memory.readbyte(wBattleMonLevel, BUS), memory.readbyte(wEnemyMonLevel, BUS)
    local env = memory.readbyte(wEnvironment, BUS)
    local stronger = (myLevel + 3) % 256 < enemyLevel
    local anim
    if CAVE_ENVIRONMENTS[env] then
        anim = stronger and "zoom" or "sine"
    else
        anim = stronger and "speckle" or "spin"
    end
    local now = emu.framecount()
    enc.trans = {
        anim = anim, myLevel = myLevel, enemyLevel = enemyLevel, env = env, svbk = hram(rSVBK) % 8,
        myWrites = writes.my.count, myLast = describe_write(writes.my, now),
        enemyWrites = writes.enemy.count, enemyLast = describe_write(writes.enemy, now),
    }
    writes.my, writes.enemy = {count = 0}, {count = 0}
end

local function hook(name, bank, addr, fn)
    local tag = "HBRNG " .. name
    event.unregisterbyname(tag)
    event.onmemoryexecute(function()
        if bank == 0 or hram(hROMBank) == bank then fn() end
    end, addr, tag)
end

for i, site in ipairs(sites) do
    hook("rng start " .. i, 0, site.start, function() update_start(site) end)
    hook("rng end " .. i, 0, site.finish, function() update_end(site) end)
end
hook("TreeMonEncounter", 0x2E, 0x41EA, on_tree_encounter)
hook("SelectTreeMon", 0x2E, 0x441F, on_select_tree_mon)
hook("SelectTreeMon.loop", 0x2E, SELECT_TREE_MON_LOOP, on_select_tree_mon_loop)
hook("LoadEnemyMon", 0x0F, 0x68EB, on_load_enemy_mon)
hook("GenerateDVs", 0x0F, 0x69A0, on_generate_dvs)
hook("UpdateDVs", 0x0F, 0x69A8, on_update_dvs)
hook("Happiness", 0x0F, 0x6A1A, on_happiness)

local transBytes = bytes(TRANSITION[4])
if memory.read_bytes_as_binary_string(rom_linear(TRANSITION[2], TRANSITION[3]), #transBytes, "ROM") == transBytes then
    hook(TRANSITION[1], TRANSITION[2], TRANSITION[3], on_transition)
    for key, addr in pairs({my = wBattleMonLevel, enemy = wEnemyMonLevel}) do
        local tag = "HBRNG write " .. key
        event.unregisterbyname(tag)
        event.onmemorywrite(function(_, val) note_write(writes[key], val, addr) end, addr, tag)
    end
else
    log("The battle-transition check isn't where English Crystal 1.1 has it - its columns stay empty.")
end

event.onexit(function()
    if encCount > 0 then progress() end
    encFile:close()
    traceFile:close()
end, "HBRNG exit")

log("Crystal checked, hooks set. Logging every headbutt to:")
log("  " .. encPath)
log("  " .. tracePath)
log("Leave this running next to the bot, and stop it from the Lua Console when done.")

while true do
    emu.frameadvance()
end

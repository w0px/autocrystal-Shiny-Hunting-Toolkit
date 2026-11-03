-- next_pokemon.lua (lives in data/)
-- Auto-Catch Settings' "Send out the next Pokemon if yours faints": while
-- catching with frame rollback off, a fainted lead no longer stops the
-- bot. It answers "Use next POKeMON?" with YES and sends out the first
-- healthy Pokemon in the party - as long as another healthy one is still
-- left after it. The last one is never risked: if it fainted too you'd
-- white out, and the Pokemon being caught would be gone for good. The
-- module then only throws balls with it (the new Pokemon's moves could
-- knock the target out).
--
-- Why this is safe to automate, from the game's own code:
--   AskUseNextPokemon (Crystal 0F:51F8): B at its YES/NO box with the
--   cursor on YES just shows the box again - only NO tries to run away.
--   So the bot presses B through the "fainted" text until the box is up,
--   then A once, on YES.
--   ForcePickPartyMonInBattle (Crystal 0F:5362): the party menu after it
--   can't be backed out of, and a Pokemon that can't battle just gets the
--   "wrong" sound and the menu again - so the bot only ever has to move
--   the cursor (wMenuCursorY) to the right Pokemon before A.
-- Both are found by their code in bank 0F (Crystal 1.0/1.1 and Gold/Silver
-- have the same routines at different addresses). On a game where either
-- isn't found, send() returns false and the module stops as before.

local Mem = Mem or require("data.memory")

local M = {}

local BANK = 0x0F
local EGG = 0xFD
local PARTY_MON_SIZE, MON_HP = 0x30, 0x22
-- "??" = any byte. The YES/NO loop's own operand is wMenuCursorY.
local USE_NEXT = "01 07 01 CD ?? ?? FA ?? ?? 38 02 A7 C9 FA ?? ?? FE 01 28 EC"
local PICK_LOOPS = {
    "CD ?? ?? D0 CD ?? ?? D8 11 19 00 CD ?? ?? CD ?? ?? 18 ED", -- Crystal (with its mobile-battle check)
    "CD ?? ?? D0 11 19 00 CD ?? ?? CD ?? ?? 18 F1",             -- Gold/Silver
}
local HOOK_USE_NEXT, HOOK_PICK = "autocrystal next-mon use-next", "autocrystal next-mon pick"

-- A masked hex string as a Lua pattern: "??" matches any byte.
local function to_pattern(masked)
    local parts = {}
    for token in masked:gmatch("%S+") do
        if token == "??" then
            parts[#parts + 1] = "."
        else
            local c = string.char(tonumber(token, 16))
            parts[#parts + 1] = c:find("[%^%$%(%)%%%.%[%]%*%+%-%?]") and ("%" .. c) or c
        end
    end
    return table.concat(parts)
end

-- Offset of the only match in data, or nil when there's none or more than one.
local function find_once(data, masked)
    local pattern = to_pattern(masked)
    local at = data:find(pattern)
    if at == nil or data:find(pattern, at + 1) then return nil end
    return at - 1
end

local romHash, found, cursorAddr
local useNextSeen, pickSeen = 0, 0

-- Scans bank 0F once per game and hooks both routines.
function M.available()
    local okHash, hash = pcall(gameinfo.getromhash)
    hash = okHash and hash or ""
    if hash == romHash and found ~= nil then return found end
    romHash, found = hash, false
    local okRead, bank = pcall(memory.read_bytes_as_binary_string, BANK * 0x4000, 0x4000, "ROM")
    if not okRead or type(bank) ~= "string" or #bank < 0x4000 then return false end
    local useNext = find_once(bank, USE_NEXT)
    local pick
    for _, p in ipairs(PICK_LOOPS) do
        pick = pick or find_once(bank, p)
    end
    if useNext == nil or pick == nil then return false end
    cursorAddr = bank:byte(useNext + 8) + 256 * bank:byte(useNext + 9)
    Mem.RegisterROMHook(Mem.BankAddressToLinear(BANK, 0x4000 + useNext), function() useNextSeen = useNextSeen + 1 end, HOOK_USE_NEXT)
    Mem.RegisterROMHook(Mem.BankAddressToLinear(BANK, 0x4000 + pick), function() pickSeen = pickSeen + 1 end, HOOK_PICK)
    found = true
    return true
end

-- The 1-based party slot to send out, or nil when no healthy Pokemon
-- would be left after it. Read once the game has marked the fainted one
-- (it does that before asking "Use next POKeMON?").
local function pick_slot(ctx)
    local count = ctx.read8(ctx.partyBase)
    if count < 1 or count > 6 then return nil end
    local healthy = {}
    for slot = 1, count do
        local mon = ctx.partyBase + 8 + (slot - 1) * PARTY_MON_SIZE
        local hp = ctx.read8(mon + MON_HP) * 256 + ctx.read8(mon + MON_HP + 1)
        if ctx.read8(ctx.partyBase + slot) ~= EGG and hp > 0 then
            healthy[#healthy + 1] = slot
        end
    end
    if #healthy < 2 then return nil end
    return healthy[1]
end

local function wait(ctx, frames)
    for _ = 1, frames do
        if ctx.stop() then return false end
        emu.frameadvance()
    end
    return true
end

-- With the party menu open: the cursor to slot, then A. False if the
-- cursor wouldn't get there.
local function choose(ctx, slot)
    if not wait(ctx, 30) then return false end -- the menu drawn and taking input
    for _ = 1, 12 do
        local at = ctx.read8(cursorAddr)
        if at == slot then
            ctx.press("A")
            return true
        end
        ctx.press(at < slot and "Down" or "Up")
        if not wait(ctx, 4) then return false end
    end
    return false
end

-- Right after the module saw its own Pokemon faint while catching. ctx:
--   partyBase       wPartyCount for this game
--   read8(addr)     a WRAM byte as the game sees it (bank 1)
--   press(button)   one press, released after
--   stop()          true once Stop was pressed
--   battleControls() true once the battle menu is back
--   ownHP()         the Pokemon in battle's HP
-- Returns true once the new Pokemon is out and the battle menu is back;
-- else false and why - nothing was answered YES then, unless it says so.
function M.send(ctx)
    if not M.available() then return false, "this game isn't supported for it" end
    useNextSeen, pickSeen = 0, 0

    -- The "fainted" text, until "Use next POKeMON?" is up. B is safe even
    -- at the box itself (cursor on YES).
    local frames = 0
    while useNextSeen == 0 do
        if ctx.stop() then return false, "Stop was pressed" end
        if frames > 1500 then return false, "\"Use next POKeMON?\" never came up" end
        ctx.press("B")
        frames = frames + 6
    end

    local slot = pick_slot(ctx)
    if slot == nil then
        return false, "no healthy Pokemon left except your last one - not risking it"
    end

    -- YES, then the party menu. Should the box come up again (the press
    -- missed it), YES again.
    local answered, pickBefore = 0, pickSeen
    frames = 0
    while pickSeen == pickBefore do
        if ctx.stop() then return false, "Stop was pressed (at the party menu - pick one yourself)" end
        if frames > 900 then return false, "the party menu never came up" end
        if answered < useNextSeen then
            if not wait(ctx, 8) then return false, "Stop was pressed" end
            if ctx.read8(cursorAddr) ~= 1 then
                return false, "the cursor wasn't on YES - left it for you"
            end
            ctx.press("A")
            answered = useNextSeen
            frames = frames + 13
        else
            emu.frameadvance()
            frames = frames + 1
        end
    end

    -- The party menu. If the game puts it up again (that Pokemon couldn't
    -- battle after all), pick again.
    for _ = 1, 3 do
        local picks = pickSeen
        if not choose(ctx, slot) then
            return false, "couldn't move the party menu's cursor (the menu is still up - pick one yourself)"
        end
        frames = 0
        while not ctx.battleControls() and pickSeen == picks do
            if ctx.stop() then return false, "Stop was pressed" end
            if frames > 1500 then return false, "the battle menu didn't come back after sending it out" end
            emu.frameadvance()
            frames = frames + 1
        end
        if ctx.battleControls() then
            if ctx.ownHP() == 0 then return false, "the Pokemon sent out has no HP" end
            return true, slot
        end
        slot = pick_slot(ctx)
        if slot == nil then return false, "no healthy Pokemon left except your last one (the menu is still up)" end
    end
    return false, "the party menu kept coming back"
end

return M

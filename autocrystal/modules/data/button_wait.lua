-- button_wait.lua (lives in modules/data/)
-- Knows when the game is waiting for A or B, so battle code presses only
-- then instead of every few frames whatever is on screen.
--
-- Every "press A or B to go on" in the game goes through one of four home
-- bank loops, each run every frame while it waits:
--   PromptButton.input_wait_loop    text with the blinking arrow
--   WaitPressAorB_BlinkCursor.loop  the same, outside text (stat boxes)
--   SimpleWaitPressAorB, JoyWaitAorB plain waits for A/B
-- A hook on each records the frame; waiting() is true right after one ran.
-- Menus (battle menu, YES/NO, party) are different code, so a press from
-- here can never pick anything in one - and nothing is pressed while an
-- animation plays (B there would cancel an evolution).
--
-- Addresses from pokecrystal11.sym / pokegold.sym; the bytes below are the
-- start of each loop, checked in Crystal 1.0 and 1.1, Gold and Silver
-- (English). Anything else - the Japanese versions, a ROM hack with other
-- code there - fails the check and gets the old blind presses.

local M = {}

local SITES = {
    crystal = {
        {0x0AD9, "CD F5 0A CD 57 0A F0 A7 E6 03"},
        {0x0A8D, "E5 21 06 C6 CD 06 0B E1 CD 57"},
        {0x0AA5, "CD 57 0A F0 A9 E6 03 28 F7 C9"},
        {0x0A36, "CD 5A 04 CD 84 09 F0 A7 E6 03"},
    },
    gs = {
        {0x0A8A, "CD A6 0A CD 08 0A F0 A9 E6 03"},
        {0x0A3E, "E5 21 06 C5 CD B6 0A E1 CD 08"},
        {0x0A56, "CD 08 0A F0 AB E6 03 28 F7 C9"},
        {0x09E7, "CD 2E 03 CD 35 09 F0 A9 E6 03"},
    },
}

M.sites = nil       -- the loaded game's, once setup() checked them
M.lastFrame = -100  -- the last frame one of them ran

local function bytes(hex)
    return (hex:gsub("%s", ""):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Once per game: which loops this ROM has. version/region: ROM bytes
-- 0x141/0x142, like the modules read them.
function M.setup(version, region)
    M.sites = nil
    local set = (version == 0x54 and SITES.crystal) or ((version == 0x55 or version == 0x58) and SITES.gs) or nil
    if set == nil or region == 0x4A or region == 0x4B then return false end
    for _, s in ipairs(set) do
        local want = bytes(s[2])
        local ok, got = pcall(memory.read_bytes_as_binary_string, s[1], #want, "ROM")
        if not ok or got ~= want then return false end
    end
    M.sites = set
    return true
end

-- With the module's other hooks (they're replaced by name each time).
function M.register(mem)
    if M.sites == nil then return end
    for i, s in ipairs(M.sites) do
        mem.RegisterROMHook(s[1], function() M.lastFrame = emu.framecount() end, "Detect Button Wait " .. i)
    end
end

function M.available() return M.sites ~= nil end

-- True while the game sits in one of the loops (this frame or the last).
function M.waiting()
    return M.sites ~= nil and emu.framecount() - M.lastFrame <= 2
end

-- One go at moving the battle on: press btn if the game is waiting for it,
-- else let a frame pass. Without the hooks, the old blind frame + press.
-- Returns how many frames that took, for timeouts counted in frames.
function M.advance(press, btn)
    if M.sites == nil then
        emu.frameadvance()
        press(btn)
        return 6
    end
    if M.waiting() then
        press(btn)
        return 5
    end
    emu.frameadvance()
    return 1
end

return M

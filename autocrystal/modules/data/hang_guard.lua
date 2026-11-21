-- hang_guard.lua (lives in modules/data/)
-- v1.3.0: the one way the bot can get stuck that no watchdog in the modules
-- can see - Lua running on without ever letting a frame pass (a loop that
-- never calls emu.frameadvance). BizHawk just freezes then, the game and
-- the window too. A count hook looks at the frame counter every
-- M.COUNT Lua steps; M.LIMIT looks in a row on the same frame (several
-- billion steps - a normal frame of the bot is far under a million) and it
-- raises an error out of whatever was looping, so the bot stops with a
-- message in the Lua Console (and Discord, as a file for the relay - never
-- a web call) instead of a frozen emulator.
--
-- M.on(notify) / M.off(). notify(text): called once before the error.

local M = {}

M.COUNT = 1000000
M.LIMIT = 5000
local on, frame, ticks = false, -1, 0
local notify

local function hook()
    local f = emu.framecount()
    if f ~= frame then frame, ticks = f, 0; return end
    ticks = ticks + 1
    if ticks >= M.LIMIT then
        ticks = M.LIMIT - 50       -- (again soon: a pcall that swallows it gets it again)
        local text = string.format("the bot ran %.0f billion Lua steps without a single frame - stopped it", M.LIMIT * M.COUNT / 1e9)
        if notify then local n = notify; notify = nil; pcall(n, text) end
        error(debug.traceback("HANG: " .. text, 2), 0)
    end
end

function M.on(n)
    if on or not (debug and debug.sethook) then return end
    notify = n
    frame, ticks = -1, 0
    if pcall(debug.sethook, hook, "", M.COUNT) then on = true end
end

function M.off()
    if on then pcall(debug.sethook); on = false end
end

return M

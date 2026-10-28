-- diagnose_movement_state.lua
--
-- HOW TO USE:
-- Stand somewhere in the overworld with at least one open direction to
-- step into (a plain walkable tile, not blocked by a tree/ledge). Load
-- this script. It will:
--   1. Snapshot WRAM (idle baseline)
--   2. Press Down for 4 frames (a single real step, same hold BizHawk
--      already uses reliably elsewhere in the bot)
--   3. Release and keep snapshotting for 30 more frames with no input,
--      to let the step's walk animation fully complete and settle
-- It then reports which addresses went "busy" (different from idle)
-- at some point during the step and cleanly returned to their exact
-- idle value once it settled - these are candidates for a real
-- "movement in progress" flag, plus exactly which frame each one
-- flipped busy and flipped back idle, and how that lines up with when
-- the tile position (0xdcb8/0xdcb7) itself actually changed.
--
-- If Down is blocked from where you're standing, edit DIRECTION below
-- to "Up", "Left", or "Right" and reload.

local DIRECTION = "Down"
local SCAN_START = 0xC000
local SCAN_END   = 0xDFFF
local HOLD_FRAMES = 4
local SETTLE_FRAMES = 30

local function snapshot()
    local snap = {}
    for addr = SCAN_START, SCAN_END do
        snap[addr] = memory.readbyte(addr)
    end
    return snap
end

print("=== Movement state diagnostic starting ===")
print(string.format("Will press %s once and track WRAM across the step.", DIRECTION))

local frames = {}
frames[0] = snapshot()
local posX, posY = {}, {}
posX[0], posY[0] = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)

-- Hold the direction for the same duration press_button already uses
-- reliably elsewhere in the bot.
for i = 1, HOLD_FRAMES do
    joypad.set({[DIRECTION] = true})
    emu.frameadvance()
    frames[i] = snapshot()
    posX[i], posY[i] = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
end
joypad.set({[DIRECTION] = false})

-- Now release and just keep watching, no input, until well past when the
-- step should have completed and settled.
for i = HOLD_FRAMES + 1, HOLD_FRAMES + SETTLE_FRAMES do
    emu.frameadvance()
    frames[i] = snapshot()
    posX[i], posY[i] = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
end

local lastFrame = HOLD_FRAMES + SETTLE_FRAMES
local idle = frames[0]
local final = frames[lastFrame]

print("")
print("Position over time (frame: X,Y):")
for i = 0, lastFrame do
    if i == 0 or posX[i] ~= posX[i-1] or posY[i] ~= posY[i-1] then
        print(string.format("  frame %d: X=%d Y=%d", i, posX[i], posY[i]))
    end
end

print("")
print("Scanning for busy-during-step, idle-before-and-after candidates...")

local candidates = {}
for addr = SCAN_START, SCAN_END do
    local changedDuring = false
    local firstChangeFrame = nil
    local lastChangeFrame = nil
    for i = 1, lastFrame do
        if frames[i][addr] ~= idle[addr] then
            changedDuring = true
            if firstChangeFrame == nil then firstChangeFrame = i end
            lastChangeFrame = i
        end
    end
    if changedDuring and final[addr] == idle[addr] then
        table.insert(candidates, {
            addr = addr,
            idleVal = idle[addr],
            firstChange = firstChangeFrame,
            lastChange = lastChangeFrame,
        })
    end
end

print(string.format("Found %d candidate(s):", #candidates))
for _, c in ipairs(candidates) do
    print(string.format("  $%04X  idle=%d  busy frames %d-%d",
        c.addr, c.idleVal, c.firstChange, c.lastChange))
end

if #candidates == 0 then
    print("No candidates found. Possible causes:")
    print("  - The chosen direction was blocked (no real step happened)")
    print("  - The flag lives outside the C000-DFFF scan range")
    print("  - SETTLE_FRAMES wasn't long enough to see it return to idle")
end

print("=== Diagnostic complete ===")

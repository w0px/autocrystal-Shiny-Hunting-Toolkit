-- verify_movement_flag.lua
--
-- HOW TO USE:
-- Stand somewhere with several clear tiles in a row (e.g. a straight
-- stretch of walkable floor/grass, NOT near tall grass that could trigger
-- an encounter - this script doesn't handle battles, keep it simple).
-- Load the script. It does 5 consecutive steps in the same direction,
-- using $D4DD as the "movement in progress" gate instead of polling
-- position/frame-counting, and reports whether each step was clean.
--
-- If your test direction is blocked, edit DIRECTION below.

local DIRECTION = "Down"
local MOVEMENT_FLAG_ADDR = 0xD4DD
local IDLE_VALUE = 0xFF
local NUM_STEPS = 5
local TIMEOUT_FRAMES = 60 -- safety net only, shouldn't normally be hit

print("=== Movement flag verification starting ===")
print(string.format("Testing $%04X (idle=0x%02X) as the movement-ready gate.", MOVEMENT_FLAG_ADDR, IDLE_VALUE))
print("")

local function current_flag()
    return memory.readbyte(MOVEMENT_FLAG_ADDR)
end

-- Wait for the flag to be idle before we start, in case something else
-- was mid-animation when the script loaded.
local waited = 0
while current_flag() ~= IDLE_VALUE and waited < TIMEOUT_FRAMES do
    emu.frameadvance()
    waited = waited + 1
end
if current_flag() ~= IDLE_VALUE then
    print("Flag never reached idle before starting - aborting. Something else may be happening on screen.")
    return
end

for stepNum = 1, NUM_STEPS do
    local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    local startFlag = current_flag()

    -- Press for a short, fixed hold (same as press_button elsewhere) -
    -- the point of this test is whether the FLAG tells us when it's safe
    -- to move on, not how long we hold the input itself.
    for i = 1, 4 do
        joypad.set({[DIRECTION] = true})
        emu.frameadvance()
    end
    joypad.set({[DIRECTION] = false})

    -- Now wait for the flag to leave idle (movement actually started)...
    local framesToBusy = 0
    while current_flag() == IDLE_VALUE and framesToBusy < TIMEOUT_FRAMES do
        emu.frameadvance()
        framesToBusy = framesToBusy + 1
    end
    local becameBusy = (current_flag() ~= IDLE_VALUE)

    -- ...then wait for it to return to idle (movement finished).
    local framesToIdle = 0
    while current_flag() ~= IDLE_VALUE and framesToIdle < TIMEOUT_FRAMES do
        emu.frameadvance()
        framesToIdle = framesToIdle + 1
    end
    local returnedToIdle = (current_flag() == IDLE_VALUE)

    local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    local moved = (endX ~= startX or endY ~= startY)

    print(string.format(
        "Step %d: became_busy=%s (after %d frames), returned_idle=%s (after %d more), moved=%s (X=%d Y=%d -> X=%d Y=%d)",
        stepNum, tostring(becameBusy), framesToBusy, tostring(returnedToIdle), framesToIdle,
        tostring(moved), startX, startY, endX, endY))

    if not returnedToIdle then
        print("  WARNING: flag never returned to idle within timeout - stopping test, this candidate may be wrong or something interrupted it (e.g. a wild encounter).")
        break
    end
end

print("")
print("=== Verification complete ===")
print("If every step shows became_busy=true, returned_idle=true, moved=true,")
print("with framesToIdle consistently around the same small number each time,")
print("this flag is a reliable replacement for position-polling.")

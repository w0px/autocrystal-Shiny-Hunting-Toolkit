-- savestate_backup.lua
-- Shared safety net for the four "reset" modules (Starters/Egg/Static/
-- Game Corner): the very first time in a BizHawk session that ANY of
-- them is about to save OVER a given savestate slot (capturing its own
-- reset target there), this takes a timestamped copy of whatever was
-- ALREADY in that slot first.
--
-- Built after a real, severe user data-loss report: a personal,
-- finished-game savestate sitting in slot 10 got silently overwritten
-- the instant a reset module's Start button captured its reset target
-- into that same slot (root-caused to on_resume()'s own
-- savestate.saveslot(SAVESTATE_SLOT) call - that's the actual mechanic
-- of "save the current position as the reset target", so ANY slot
-- picked - intentionally or via a UI slip - gets overwritten the moment
-- Start is clicked, with zero warning before this fix existed).
--
-- Deliberately keyed by SLOT NUMBER, not by module - what's actually at
-- risk is whatever's on disk in that slot, regardless of which module is
-- about to write over it. And a slot only needs protecting once per
-- session: the FIRST write. Every write after that is just the bot
-- overwriting its own prior reset-target capture, which isn't precious
-- data worth a fresh backup - so this does not spam a new backup file on
-- every single Start click, only the first time a given slot is touched
-- since BizHawk was opened.
--
-- Uses ONLY BizHawk's own savestate.load()/save() PATH API (never tries
-- to reconstruct BizHawk's internal State-folder file naming from the
-- ROM/core name) - this way it works regardless of ROM filename, core,
-- or the user's configured savestate path, none of which this script can
-- reliably know on its own. Mechanism: snapshot the live emulator state
-- to a scratch file, load the target slot (revealing whatever's
-- currently saved there), save THAT out to a timestamped backup file,
-- then reload the scratch file to put the live state back exactly how
-- it was - net effect is a safe copy of the slot's prior contents, using
-- only the emulator's own official save/load pipeline.
--
-- Every step is wrapped in pcall - a failed backup should never block or
-- corrupt an actual hunt. Worst case on failure is just no backup and a
-- printed warning, never a crash or a lost live position.
local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"

local alreadyHandledThisSession = {}

local function timestamp_for_filename()
    -- No colons/spaces - those break Windows filenames.
    return os.date("%Y-%m-%d_%H-%M-%S")
end

-- Call this ONCE, right before a module's first savestate.saveslot(slot)
-- of the session for that slot - i.e. right before capturing a reset
-- target. moduleLabel is just cosmetic (used in the backup filename and
-- log line), e.g. "Static".
function M.backup_slot_before_first_write(slotNum, moduleLabel)
    if slotNum == nil then return end
    if alreadyHandledThisSession[slotNum] then return end
    -- Marked up front (not just on success) so a failure never retries
    -- every single Start click for the rest of the session - one honest
    -- attempt per slot per session is the contract here.
    alreadyHandledThisSession[slotNum] = true

    local liveTempPath = script_dir .. "_backup_scratch_live.State"

    local snapshotOk = false
    local ok1 = pcall(function() snapshotOk = savestate.save(liveTempPath, true) end)
    if not ok1 or not snapshotOk then
        print(string.format(
            "[autocrystal] savestate backup: couldn't snapshot the live state, skipping backup check for slot %d.",
            slotNum))
        return
    end

    -- Peek at whatever's CURRENTLY on disk in the target slot - this is
    -- exactly what's about to be overwritten.
    local loadOk = false
    pcall(function() loadOk = savestate.loadslot(slotNum, true) end)
    if not loadOk then
        -- Nothing meaningful in that slot yet (fresh/never-used this
        -- installation) - nothing to protect. Restore the live state and
        -- stop here.
        pcall(function() savestate.load(liveTempPath, true) end)
        return
    end

    local backupPath = script_dir .. string.format(
        "savestate_backup_slot%d_%s_%s.State", slotNum, tostring(moduleLabel or "unknown"), timestamp_for_filename())
    local saveOk = false
    pcall(function() saveOk = savestate.save(backupPath, true) end)
    if saveOk then
        print(string.format(
            "[autocrystal] Backed up slot %d's previous contents to modules/data/%s before reusing it for this hunt.",
            slotNum, backupPath:match("([^/\\]+)$") or backupPath))
    else
        print(string.format("[autocrystal] savestate backup: failed to write backup file for slot %d.", slotNum))
    end

    -- Restore the live position - loading the slot above replaced it,
    -- and the module's own reset-target capture needs the REAL live
    -- state (what the user actually walked to), not whatever was in the
    -- slot before.
    pcall(function() savestate.load(liveTempPath, true) end)
end

return M

-- savestate_backup.lua
-- Shared safety net for the four "reset" modules (Starters/Egg/Static/
-- Game Corner): every time one of them is about to save OVER its
-- savestate slot (capturing its reset target there - every Start), this
-- takes a timestamped copy of whatever was ALREADY in that slot first.
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
-- What's at risk is whatever's on disk in that slot, regardless of which
-- module is about to write over it. It used to be backed up only on the
-- first write of a session (later ones being the bot's own reset point),
-- but the user wants a fresh file on every Start - e.g. a new Celebi hunt
-- started after a Lapras one keeps the Lapras position too. A backup is
-- about 20 KB.
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
--
-- The backups go to autocrystal/autosaves/ (see data/paths.lua), where
-- users look for them. The scratch copy of the live state goes there too
-- and is deleted once the live state is back.
local Paths = require("data.paths")

local M = {}

local function timestamp_for_filename()
    -- No colons/spaces - those break Windows filenames.
    return os.date("%Y-%m-%d_%H-%M-%S")
end

-- The moduleLabel for a module with a sub-menu in the launcher, so the
-- backup's name says what was being hunted: ("Static", "Suicune") ->
-- "Static_Suicune", ("Static", "Static (open world)") -> "Static_OpenWorld"
-- (the first word dropped when it just repeats the module), ("Egg",
-- "Odd Egg") -> "Egg_OddEgg". No sub-menu text: just moduleLabel.
function M.label(moduleLabel, sub)
    local words = {}
    for word in tostring(sub or ""):gmatch("%w+") do
        if not (#words == 0 and word:lower() == tostring(moduleLabel):lower()) then
            words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
        end
    end
    if #words == 0 then return moduleLabel end
    return moduleLabel .. "_" .. table.concat(words)
end

-- Call this on every Start, right before the module's savestate.saveslot()
-- capturing its reset target. moduleLabel is just cosmetic (used in the
-- backup filename and log line), e.g. "Static" or M.label("Static", "Suicune").
function M.backup_slot_before_write(slotNum, moduleLabel)
    if slotNum == nil then return end

    local liveTempPath = Paths.autosave_path("_backup_scratch_live.State")

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
        os.remove(liveTempPath)
        return
    end

    local label = (tostring(moduleLabel or "unknown"):gsub("[^%w_]", ""))
    local backupPath = Paths.autosave_path(string.format(
        "savestate_backup_slot%d_%s_%s.State", slotNum, label, timestamp_for_filename()))
    local saveOk = false
    pcall(function() saveOk = savestate.save(backupPath, true) end)
    if saveOk then
        print(string.format(
            "[autocrystal] Backed up slot %d's previous contents to autosaves/%s before reusing it for this hunt.",
            slotNum, backupPath:match("([^/\\]+)$") or backupPath))
    else
        print(string.format("[autocrystal] savestate backup: failed to write backup file for slot %d.", slotNum))
    end

    -- Restore the live position - loading the slot above replaced it,
    -- and the module's own reset-target capture needs the REAL live
    -- state (what the user actually walked to), not whatever was in the
    -- slot before.
    pcall(function() savestate.load(liveTempPath, true) end)
    os.remove(liveTempPath)
end

return M

-- gui_module.lua
-- Builds the display + settings controls onto an EXISTING form (passed in
-- by the launcher), rather than creating its own window.
--
-- IMPORTANT DESIGN NOTE: after multiple attempts at a canvas-drawn
-- backdrop (background color fix, continuous throttled redraw,
-- forms.clear, destroy+recreate, then a static one-time backdrop with
-- labels on top), the canvas approach kept causing problems - most
-- recently, labels positioned inside a picturebox's bounds got silently
-- painted over by the picturebox's own repaints, even though the labels
-- were created after it. Given forms.label/forms.checkbox +
-- forms.settext/forms.ischecked have been 100% reliable throughout this
-- entire project, this version drops the canvas/border styling entirely
-- and uses plain labels only - no visual borders, but zero overlap risk.

local M = {}

-- Every control any module might want to disable. reconfigure() always
-- re-enables ALL of these first, then disables only what the newly
-- active module specifies - so switching from a module that disabled
-- some fields to one that doesn't need to disable anything correctly
-- re-enables everything, rather than leaving stale disabled state behind.
local DISABLEABLE_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkTrueRandomness",
    "chkStopPerfect", "chkStopNegative",
    "chkAutoCatch", "chkAutoCatchTestMode",
}

-- Re-enables everything, then disables only the given list. Call this
-- whenever a module becomes active (including switching back to one
-- that was already initialized before), not just on first creation.
function M.reconfigure(w, disabledFields)
    for _, key in ipairs(DISABLEABLE_FIELDS) do
        if w[key] then
            forms.setproperty(w[key], "Enabled", true)
        end
    end
    if disabledFields then
        for _, key in ipairs(disabledFields) do
            if w[key] then
                forms.setproperty(w[key], "Enabled", false)
            end
        end
    end
    if w.lblHistHeader then
        forms.settext(w.lblHistHeader, "RECENT ENCOUNTERS:")
    end
end

-- Lets a module override the history header label (e.g. friendship
-- tracking calls this with "PROGRESS:" instead). Call AFTER
-- reconfigure(), since reconfigure always resets it to the default -
-- otherwise switching away from a module that set a custom label would
-- leave it stuck showing that label forever.
function M.set_history_header(w, text)
    if w.lblHistHeader then
        forms.settext(w.lblHistHeader, text)
    end
end

-- Wipes the "Last Encounter" / history display back to blank. Call this
-- when switching to a different module, so stale data from whatever
-- module was previously active doesn't linger and confuse things.
function M.clear_last_encounter(w)
    forms.settext(w.lblLastSpecies, "Species: -")
    forms.settext(w.lblLastStats, "Atk/Def/Spe/Spc: -")
    forms.settext(w.lblLastItem, "Held Item: -")
    forms.settext(w.lblLastShiny, "Shiny: -")
    w._historyData = {}
    for i = 1, 8 do
        forms.settext(w.history[i], "")
    end
end

function M.create(existingForm, yOffset, disabledFields)
    local widgets = { frm = existingForm, yOffset = yOffset }

    local baseX = 10
    local baseY = yOffset

    widgets.lblEncounters = forms.label(existingForm, "TOTAL ENCOUNTERS: 0", baseX, baseY, 300, 16)
    widgets.lblSessionEncounters = forms.label(existingForm, "SESSION ENCOUNTERS: 0", baseX, baseY + 18, 300, 16)
    widgets.lblShinies    = forms.label(existingForm, "SHINIES: 0", baseX, baseY + 36, 300, 16)
    widgets.lblSinceShiny = forms.label(existingForm, "SINCE LAST SHINY: -", baseX, baseY + 54, 300, 16)
    widgets.lblRuntime    = forms.label(existingForm, "RUNTIME: 00:00:00", baseX, baseY + 72, 300, 16)
    widgets.lblStatus     = forms.label(existingForm, "STATUS: Starting...", baseX, baseY + 90, 300, 16)

    local SEPARATOR = string.rep("-", 55)
    widgets.lblSep1 = forms.label(existingForm, SEPARATOR, baseX, baseY + 108, 340, 16)

    widgets.lblLastHeader  = forms.label(existingForm, "LAST ENCOUNTER:", baseX, baseY + 124, 300, 16)
    widgets.lblLastSpecies = forms.label(existingForm, "Species: -", baseX, baseY + 142, 300, 16)
    widgets.lblLastStats   = forms.label(existingForm, "Atk/Def/Spe/Spc: -", baseX, baseY + 160, 300, 16)
    widgets.lblLastItem    = forms.label(existingForm, "Held Item: -", baseX, baseY + 178, 300, 16)
    widgets.lblLastShiny   = forms.label(existingForm, "Shiny: -", baseX, baseY + 196, 300, 16)

    widgets.lblSep2 = forms.label(existingForm, SEPARATOR, baseX, baseY + 214, 340, 16)

    widgets.lblHistHeader = forms.label(existingForm, "RECENT ENCOUNTERS:", baseX, baseY + 230, 300, 16)
    widgets.history = {}
    widgets._historyData = {}
    for i = 1, 8 do
        widgets.history[i] = forms.label(existingForm, "", baseX, baseY + 230 + i * 18, 340, 16)
    end

    widgets.encounterCount = 0
    widgets.shinyCount = 0
    widgets.encountersSinceShiny = 0
    widgets.sessionEncounterCount = 0
    widgets.status = "Starting..."
    widgets._startTime = os.time()

    local y = baseY + 230 + 9 * 18 + 15

    widgets.chkStopPerfect  = forms.checkbox(existingForm, "Stop on Perfect DVs (15/15/15/15)", 10, y)
    forms.setproperty(widgets.chkStopPerfect, "Width", 380)
    y = y + 23

    widgets.chkStopNegative = forms.checkbox(existingForm, "Stop on Perfect Negative DVs (0/0/0/0)", 10, y)
    forms.setproperty(widgets.chkStopNegative, "Width", 380)
    y = y + 23

    widgets.chkStopSpecies  = forms.checkbox(existingForm, "Stop on specific Species ID:", 10, y)
    forms.setproperty(widgets.chkStopSpecies, "Width", 200)
    widgets.txtSpeciesId    = forms.textbox(existingForm, "", 60, 20, nil, 215, y - 2)
    y = y + 23

    widgets.chkStopItem     = forms.checkbox(existingForm, "Stop on held item:", 10, y)
    forms.setproperty(widgets.chkStopItem, "Width", 150)
    widgets.txtItemFilter   = forms.textbox(existingForm, "", 190, 20, nil, 165, y - 2)
    y = y + 20
    widgets.lblItemFilterHint = forms.label(existingForm, "(ID or name, blank = any item)", 28, y, 380, 16)
    y = y + 26

    widgets.chkKillMode     = forms.checkbox(existingForm, "Kill non-shiny (use first move)", 10, y)
    forms.setproperty(widgets.chkKillMode, "Width", 380)
    y = y + 22
    widgets.lblKillFilter   = forms.label(existingForm, "Only kill IDs or names (comma-sep, blank=all):", 28, y, 380, 16)
    y = y + 18
    widgets.txtKillFilter   = forms.textbox(existingForm, "", 320, 20, nil, 28, y)
    y = y + 34

    widgets.chkAutoCatch    = forms.checkbox(existingForm, "Auto-catch on shiny (weaken + throw balls)", 10, y)
    forms.setproperty(widgets.chkAutoCatch, "Width", 380)
    y = y + 20
    widgets.chkAutoCatchTestMode = forms.checkbox(existingForm, "TEST MODE: catch ANY encounter, not just shiny", 28, y)
    forms.setproperty(widgets.chkAutoCatchTestMode, "Width", 380)
    y = y + 18
    widgets.lblAutoCatchTestHint = forms.label(existingForm, "(for testing the catch logic safely - turn OFF before a real hunt)", 28, y, 380, 16)
    y = y + 26

    widgets.chkDiscord      = forms.checkbox(existingForm, "Send Discord notification (shiny/stop)", 10, y)
    forms.setproperty(widgets.chkDiscord, "Width", 380)
    y = y + 20
    widgets.lblDiscordHint  = forms.label(existingForm, "(requires local relay - see discord_relay.ps1)", 28, y, 380, 16)
    y = y + 26

    widgets.chkVerbose      = forms.checkbox(existingForm, "Verbose Logging (for debugging)", 10, y)
    forms.setproperty(widgets.chkVerbose, "Width", 380)
    y = y + 26

    widgets.chkTrueRandomness = forms.checkbox(existingForm, "True Randomness (soft-reset modules only)", 10, y)
    forms.setproperty(widgets.chkTrueRandomness, "Width", 380)
    y = y + 20
    widgets.lblTrueRandomnessHint1 = forms.label(existingForm, "(much slower - guarantees full DV range", 28, y, 380, 16)
    y = y + 16
    widgets.lblTrueRandomnessHint2 = forms.label(existingForm, "coverage, for hunting 15/15/15/15 or 0/0/0/0)", 28, y, 380, 16)
    y = y + 26

    widgets.bottomY = y

    M.reconfigure(widgets, disabledFields)

    return widgets
end

function M.update_counts(w, encounterCount, shinyCount, encountersSinceShiny, sessionEncounterCount, status)
    w.encounterCount = encounterCount
    w.shinyCount = shinyCount
    w.encountersSinceShiny = encountersSinceShiny
    w.sessionEncounterCount = sessionEncounterCount
    if status then w.status = status end

    forms.settext(w.lblEncounters, string.format("TOTAL ENCOUNTERS: %d", w.encounterCount))
    forms.settext(w.lblSessionEncounters, string.format("SESSION ENCOUNTERS: %d", w.sessionEncounterCount))
    forms.settext(w.lblShinies, string.format("SHINIES: %d", w.shinyCount))
    if w.shinyCount == 0 then
        forms.settext(w.lblSinceShiny, "SINCE LAST SHINY: -")
    else
        forms.settext(w.lblSinceShiny, string.format("SINCE LAST SHINY: %d", w.encountersSinceShiny))
    end
    forms.settext(w.lblRuntime, "RUNTIME: " .. os.date("!%H:%M:%S", os.time() - w._startTime))
    forms.settext(w.lblStatus, "STATUS: " .. w.status)
end

function M.update_last_encounter(w, index, species, speciesName, atk, def, spe, spc, isShiny, itemName)
    forms.settext(w.lblLastSpecies, string.format("Species: %s (#%d)", speciesName, species))
    forms.settext(w.lblLastStats, string.format("Atk/Def/Spe/Spc: %d/%d/%d/%d", atk, def, spe, spc))
    forms.settext(w.lblLastItem, "Held Item: " .. (itemName or "-"))
    forms.settext(w.lblLastShiny, "Shiny: " .. (isShiny and "YES!" or "no"))

    local entry = string.format("#%d  %-10s  A:%-2d D:%-2d S:%-2d Sp:%-2d%s%s",
        index, speciesName, atk, def, spe, spc,
        (itemName and itemName ~= "(no item)") and ("  [" .. itemName .. "]") or "",
        isShiny and "  *SHINY*" or "")
    table.insert(w._historyData, 1, entry)
    if #w._historyData > 8 then table.remove(w._historyData) end
    for i = 1, 8 do
        forms.settext(w.history[i], w._historyData[i] or "")
    end
end

-- Generic variant for modules that don't track species/DV data at all
-- (e.g. friendship tracking) - writes a single plain-text line into the
-- same shared history display instead. Also updates the four "Last
-- Encounter" label fields with whatever text is passed in, so modules
-- can repurpose them meaningfully instead of leaving stale/irrelevant
-- text showing from a previous module.
function M.update_generic_history(w, entryText, label1, label2, label3, label4)
    if label1 then forms.settext(w.lblLastSpecies, label1) end
    if label2 then forms.settext(w.lblLastStats, label2) end
    if label3 then forms.settext(w.lblLastItem, label3) end
    if label4 then forms.settext(w.lblLastShiny, label4) end

    table.insert(w._historyData, 1, entryText)
    if #w._historyData > 8 then table.remove(w._historyData) end
    for i = 1, 8 do
        forms.settext(w.history[i], w._historyData[i] or "")
    end
end

-- Sets just the 4 "Last Encounter" label fields, without touching the
-- history display at all. For modules that update labels independently
-- of history (e.g. friendship tracking, which uses set_full_history
-- separately for the party snapshot).
function M.set_labels(w, label1, label2, label3, label4)
    if label1 then forms.settext(w.lblLastSpecies, label1) end
    if label2 then forms.settext(w.lblLastStats, label2) end
    if label3 then forms.settext(w.lblLastItem, label3) end
    if label4 then forms.settext(w.lblLastShiny, label4) end
end

-- Replaces the entire history display with the given lines (up to 8),
-- rather than appending one entry to a rolling log. For modules
-- showing a live snapshot of multiple things at once (e.g. every party
-- member's current friendship) rather than a chronological history.
function M.set_full_history(w, lines)
    w._historyData = {}
    for i = 1, 8 do
        w._historyData[i] = lines[i]
        forms.settext(w.history[i], lines[i] or "")
    end
end

function M.stop_on_perfect(w)
    return forms.ischecked(w.chkStopPerfect)
end

function M.stop_on_perfect_negative(w)
    return forms.ischecked(w.chkStopNegative)
end

function M.stop_on_species(w)
    local enabled = forms.ischecked(w.chkStopSpecies)
    local targetId = tonumber(forms.gettext(w.txtSpeciesId))
    return enabled and targetId ~= nil, targetId
end

function M.stop_on_item(w)
    local enabled = forms.ischecked(w.chkStopItem)
    local raw = forms.gettext(w.txtItemFilter)
    if raw == nil or raw:match("^%s*$") then
        return enabled, nil
    end
    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then table.insert(tokens, trimmed) end
    end
    if #tokens == 0 then return enabled, nil end
    return enabled, tokens
end

function M.kill_non_shiny(w)
    return forms.ischecked(w.chkKillMode)
end

function M.auto_catch_enabled(w)
    return forms.ischecked(w.chkAutoCatch)
end

function M.auto_catch_test_mode(w)
    return forms.ischecked(w.chkAutoCatchTestMode)
end

function M.kill_species_filter(w)
    local raw = forms.gettext(w.txtKillFilter)
    if raw == nil or raw:match("^%s*$") then
        return nil
    end
    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(tokens, trimmed)
        end
    end
    if #tokens == 0 then return nil end
    return tokens
end

function M.discord_enabled(w)
    return forms.ischecked(w.chkDiscord)
end

function M.verbose_logging(w)
    return forms.ischecked(w.chkVerbose)
end

function M.true_randomness_enabled(w)
    return forms.ischecked(w.chkTrueRandomness)
end

return M

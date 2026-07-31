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

-- Persists the Discord ping user/role ID (and whether pinging is on)
-- across script reloads - see data/gui_settings.lua for why this
-- couldn't just live in the in-memory widgets table like everything
-- else here.
GuiSettings = GuiSettings or require("data.gui_settings")

-- Every control any module might want to disable. reconfigure() always
-- re-enables ALL of these first, then disables only what the newly
-- active module specifies - so switching from a module that disabled
-- some fields to one that doesn't need to disable anything correctly
-- re-enables everything, rather than leaving stale disabled state behind.
-- Shared comma-separated token parser (name/ID filters throughout this
-- file). Used directly on whatever raw text is currently available -
-- either the live textbox, or the last-saved text if the widget's
-- popup has been closed - rather than maintaining a separate
-- pre-parsed-tokens cache that could drift out of sync with the raw
-- text it's supposed to represent.
local function parse_filter_tokens(raw)
    if raw == nil or raw:match("^%s*$") then
        return nil
    end
    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then table.insert(tokens, trimmed) end
    end
    if #tokens == 0 then return nil end
    return tokens
end

local DISABLEABLE_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
    "chkTrueRandomness",
    "chkStopPerfect", "chkStopNegative",
    "chkAutoCatch",
    "txtCatchFilter",
    "chkSkipAlreadyCaught",
    "chkStopAutoCatchException", "txtStopAutoCatchException",
    "chkOverrideCritSafety", "txtCustomHpTarget",
    "chkCatchOnItem", "txtCatchItemFilter",
    "chkStopOnShiny",
    "chkCatchOnPerfect", "chkCatchOnPerfectNegative",
}

-- Re-enables everything, then disables only the given list. Call this
-- whenever a module becomes active (including switching back to one
-- that was already initialized before), not just on first creation.
function M.reconfigure(w, disabledFields)
    w._lastDisabledFields = disabledFields
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

-- Advanced Settings popup - built lazily on first click of the button in
-- M.create(), not at startup. The widgets it creates get stored in the
-- SAME widgets table passed in from M.create() (not a separate table),
-- so every existing getter function (M.stop_on_item, etc) keeps working
-- unmodified regardless of which physical window a given control lives
-- on - forms.ischecked()/forms.gettext() operate on the widget handle
-- itself, not its parent form.
-- Explicitly captures every Advanced Settings value into the saved
-- variables. Called ONLY from the Save button - see open_advanced_
-- settings' onclose callback for why this is deliberately NOT also
-- called as a "best-effort" fallback when the window closes some other
-- way (that used to be the plan, but reading controls at that point
-- turned out to be unreliable and was actively corrupting saved state).
local function save_advanced_settings(w)
    w._savedStopItemEnabled = forms.ischecked(w.chkStopItem)
    w._savedItemFilterText = forms.gettext(w.txtItemFilter)
    w._savedOverrideCritSafety = forms.ischecked(w.chkOverrideCritSafety)
    w._savedCustomHpTargetText = forms.gettext(w.txtCustomHpTarget)
    w._savedVerbose = forms.ischecked(w.chkVerbose)
    w._savedTrueRandomness = forms.ischecked(w.chkTrueRandomness)
end

local function save_autocatch_settings(w)
    w._savedAutoCatchEnabled = forms.ischecked(w.chkAutoCatch)
    w._savedCatchFilterText = forms.gettext(w.txtCatchFilter)
    w._savedSkipAlreadyCaught = forms.ischecked(w.chkSkipAlreadyCaught)
    w._savedStopAutoCatchException = forms.ischecked(w.chkStopAutoCatchException)
    w._savedStopAutoCatchExceptionText = forms.gettext(w.txtStopAutoCatchException)
    w._savedCatchOnItemEnabled = forms.ischecked(w.chkCatchOnItem)
    w._savedCatchItemFilterText = forms.gettext(w.txtCatchItemFilter)
    w._savedCatchOnPerfect = forms.ischecked(w.chkCatchOnPerfect)
    w._savedCatchOnPerfectNegative = forms.ischecked(w.chkCatchOnPerfectNegative)
    w._savedDontWeaken = forms.ischecked(w.chkDontWeaken)
end

local function save_discord_settings(w)
    w._savedDiscordEnabled = forms.ischecked(w.chkDiscord)
    w._savedPingEnabled = forms.ischecked(w.chkPingUser)
    w._savedPingIdText = forms.gettext(w.txtPingId)

    -- Write the ping ID/enabled state to disk too, not just the
    -- in-memory cache above - this is the one setting that was
    -- resetting completely on every script reload, since everything
    -- else in this file only ever lived in the widgets table.
    GuiSettings.pingEnabled = w._savedPingEnabled
    GuiSettings.pingIdText = w._savedPingIdText
    GuiSettings.save()
end

function M.open_advanced_settings(w)
    if w._advancedForm ~= nil then
        -- Already open - nothing more to do. (If it was previously
        -- closed, the onclose callback below resets this to nil, so
        -- we'd correctly fall through and recreate it instead.)
        return
    end

    local advForm = forms.newform(420, 385, "Advanced Settings", function()
        -- Deliberately does NOT re-read/re-save the controls here, no
        -- matter how this close was triggered (native title-bar X, or
        -- forms.destroy() from the Save button below re-entering this
        -- same callback synchronously) - reading forms.ischecked()/
        -- forms.gettext() at this point turned out to be unreliable
        -- (empirically confirmed: closing via the X button could read a
        -- checkbox as unchecked even though it was checked and already
        -- saved), silently overwriting the correct cached value with a
        -- wrong one. Save is now the ONLY thing that commits changes -
        -- closing via X discards any unsaved edits instead, standard
        -- Save/Cancel dialog behavior, and can no longer corrupt
        -- whatever was already saved.
        w._advancedForm = nil
        -- Clearing these handles is the other half of the fix: every
        -- getter below falls back to the _savedXxx cache exactly when
        -- its widget field is nil. Save alone isn't enough - leaving the
        -- handles set kept reading from dead controls instead of ever
        -- reaching the fallback.
        w.chkStopItem = nil
        w.txtItemFilter = nil
        w.chkOverrideCritSafety = nil
        w.txtCustomHpTarget = nil
        w.chkVerbose = nil
        w.chkTrueRandomness = nil
    end)
    local y = 10

    w.chkStopItem = forms.checkbox(advForm, "Stop on held item:", 10, y)
    forms.setproperty(w.chkStopItem, "Width", 150)
    if w._savedStopItemEnabled then forms.setproperty(w.chkStopItem, "Checked", true) end
    w.txtItemFilter = forms.textbox(advForm, w._savedItemFilterText or "", 190, 20, nil, 165, y - 2)
    y = y + 20
    w.lblItemFilterHint = forms.label(advForm, "(ID or name, blank = any item)", 28, y, 380, 16)
    y = y + 30

    w.chkOverrideCritSafety = forms.checkbox(advForm, "Override crit-safety - use a custom HP% target instead", 10, y)
    forms.setproperty(w.chkOverrideCritSafety, "Width", 380)
    if w._savedOverrideCritSafety then forms.setproperty(w.chkOverrideCritSafety, "Checked", true) end
    y = y + 20
    w.lblCustomHpTarget = forms.label(advForm, "Custom target HP% (e.g. 40):", 28, y, 200, 16)
    w.txtCustomHpTarget = forms.textbox(advForm, w._savedCustomHpTargetText or "40", 60, 20, nil, 230, y - 2)
    y = y + 22
    w.lblCritSafetyHint = forms.label(advForm, "(skips the predictive crit-safety stop - riskier, but fewer balls wasted)", 28, y, 380, 16)
    y = y + 30

    w.chkVerbose = forms.checkbox(advForm, "Verbose Logging (for debugging)", 10, y)
    forms.setproperty(w.chkVerbose, "Width", 380)
    if w._savedVerbose then forms.setproperty(w.chkVerbose, "Checked", true) end
    y = y + 26

    w.chkTrueRandomness = forms.checkbox(advForm, "True Randomness (legacy - unused by Static/Starters/Egg)", 10, y)
    forms.setproperty(w.chkTrueRandomness, "Width", 380)
    if w._savedTrueRandomness then forms.setproperty(w.chkTrueRandomness, "Checked", true) end
    y = y + 20
    w.lblTrueRandomnessHint1 = forms.label(advForm, "(superseded there by the automatic 30-min pool reroll -", 28, y, 380, 16)
    y = y + 16
    w.lblTrueRandomnessHint2 = forms.label(advForm, "kept only in case a future module needs it, see rng_mechanics.md)", 28, y, 380, 16)
    y = y + 30

    -- Save reads the controls while they're definitely still alive,
    -- then closes the window itself (forms.destroy() re-enters the
    -- onclose callback above synchronously, but that callback no longer
    -- reads anything - it just nils the handles - so nothing gets
    -- overwritten).
    forms.button(advForm, "Save", function()
        save_advanced_settings(w)
        forms.destroy(advForm)
    end, 10, y, 100, 25)

    w._advancedForm = advForm

    -- These widgets didn't exist the last time M.reconfigure() actually
    -- ran (e.g. wild.lua disabling True Randomness, which only applies
    -- to soft-reset modules) - re-apply whatever was last requested now
    -- that they've actually been created.
    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

-- Auto-Catch Settings popup - same lazy-build/save-on-close/nil-out
-- pattern as Advanced Settings above. Also owns "Auto-catch on held
-- item", moved here from Advanced Settings since it's an auto-catch
-- behavior, not a rarely-touched advanced option.
function M.open_autocatch_settings(w)
    if w._autoCatchForm ~= nil then
        return
    end

    local acForm = forms.newform(420, 510, "Auto-Catch Settings", function()
        -- See open_advanced_settings's onclose callback for why this
        -- deliberately does NOT re-read/re-save the controls here -
        -- closing via X used to silently corrupt already-saved values
        -- this same way (e.g. Auto-Catch showing checked on reopen,
        -- then flipping back to unchecked the moment X was clicked).
        w._autoCatchForm = nil
        w.chkAutoCatch = nil
        w.txtCatchFilter = nil
        w.chkSkipAlreadyCaught = nil
        w.chkStopAutoCatchException = nil
        w.txtStopAutoCatchException = nil
        w.chkCatchOnItem = nil
        w.txtCatchItemFilter = nil
        w.chkCatchOnPerfect = nil
        w.chkCatchOnPerfectNegative = nil
        w.chkDontWeaken = nil
    end)
    local y = 10

    w.chkAutoCatch = forms.checkbox(acForm, "Auto-catch on shiny", 10, y)
    forms.setproperty(w.chkAutoCatch, "Width", 380)
    if w._savedAutoCatchEnabled then forms.setproperty(w.chkAutoCatch, "Checked", true) end
    y = y + 22
    w.lblCatchFilter = forms.label(acForm, "Only auto-catch IDs or names (comma-sep, blank=all):", 28, y, 380, 16)
    y = y + 18
    w.txtCatchFilter = forms.textbox(acForm, w._savedCatchFilterText or "", 320, 20, nil, 28, y)
    y = y + 20
    w.lblCatchFilterHint = forms.label(acForm, "(non-matching shinies are skipped - hunt continues, still notifies Discord)", 28, y, 380, 16)
    y = y + 24

    w.chkSkipAlreadyCaught = forms.checkbox(acForm, "Only auto-catch a species the FIRST time (living dex mode)", 10, y)
    forms.setproperty(w.chkSkipAlreadyCaught, "Width", 380)
    if w._savedSkipAlreadyCaught then forms.setproperty(w.chkSkipAlreadyCaught, "Checked", true) end
    y = y + 20
    w.lblSkipAlreadyCaughtHint = forms.label(acForm, "(tracked persistently across sessions - already-caught species get skipped)", 28, y, 380, 16)
    y = y + 24

    w.chkStopAutoCatchException = forms.checkbox(acForm, "EXCEPT stop (don't auto-catch) these specific shinies:", 10, y)
    forms.setproperty(w.chkStopAutoCatchException, "Width", 380)
    if w._savedStopAutoCatchException then forms.setproperty(w.chkStopAutoCatchException, "Checked", true) end
    y = y + 20
    w.txtStopAutoCatchException = forms.textbox(acForm, w._savedStopAutoCatchExceptionText or "", 320, 20, nil, 28, y)
    y = y + 18
    w.lblStopAutoCatchExceptionHint = forms.label(acForm, "(e.g. keep a rare one for yourself while the bot auto-catches the rest)", 28, y, 380, 16)
    y = y + 26

    w.chkCatchOnItem = forms.checkbox(acForm, "Auto-catch on held item:", 10, y)
    forms.setproperty(w.chkCatchOnItem, "Width", 150)
    if w._savedCatchOnItemEnabled then forms.setproperty(w.chkCatchOnItem, "Checked", true) end
    w.txtCatchItemFilter = forms.textbox(acForm, w._savedCatchItemFilterText or "", 190, 20, nil, 165, y - 2)
    y = y + 20
    w.lblCatchItemFilterHint = forms.label(acForm, "(ID or name - catches regardless of species if holding this)", 28, y, 380, 16)
    y = y + 30

    -- Both independent of shininess, same reasoning/gating as "Auto-catch
    -- on held item" above (still requires the master Auto-Catch toggle) -
    -- these can never overlap with a shiny catch, since shininess itself
    -- requires Def=10, which rules out both all-15 and all-0.
    w.chkCatchOnPerfect = forms.checkbox(acForm, "Auto-catch on Perfect DVs (15/15/15/15)", 10, y)
    forms.setproperty(w.chkCatchOnPerfect, "Width", 380)
    if w._savedCatchOnPerfect then forms.setproperty(w.chkCatchOnPerfect, "Checked", true) end
    y = y + 22

    w.chkCatchOnPerfectNegative = forms.checkbox(acForm, "Auto-catch on Perfect Negative DVs (0/0/0/0)", 10, y)
    forms.setproperty(w.chkCatchOnPerfectNegative, "Width", 380)
    if w._savedCatchOnPerfectNegative then forms.setproperty(w.chkCatchOnPerfectNegative, "Checked", true) end
    y = y + 30

    -- Skips do_catch_sequence's weaken-first phase entirely (wild/
    -- headbutt/fishing only - see M.dont_weaken_enabled's callers) and
    -- starts throwing balls immediately at full HP instead. Catch rate
    -- per ball is much worse at full HP (Gen 2's catch formula weighs
    -- current HP heavily), but some catches (a shiny with depleted PP,
    -- or a target the user doesn't want risked to an accidental crit/
    -- faint during the weaken turns at all) are worth more balls to
    -- skip that risk entirely - purely a risk/ball-count tradeoff, no
    -- effect on catch legality or DVs either way.
    w.chkDontWeaken = forms.checkbox(acForm, "Don't weaken enemy Pokemon - throw balls immediately", 10, y)
    forms.setproperty(w.chkDontWeaken, "Width", 380)
    if w._savedDontWeaken then forms.setproperty(w.chkDontWeaken, "Checked", true) end
    y = y + 20
    w.lblDontWeakenHint = forms.label(acForm, "(skips attacking to lower HP first - uses more balls on average)", 28, y, 380, 16)
    y = y + 30

    forms.button(acForm, "Save", function()
        save_autocatch_settings(w)
        forms.destroy(acForm)
    end, 10, y, 100, 25)

    w._autoCatchForm = acForm

    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

-- Discord Settings popup - just the one checkbox today, but kept as its
-- own popup (rather than inline on the main form) for consistency with
-- Auto-Catch/Advanced, and so it's easy to add more Discord-specific
-- options here later without cluttering the main form again.
function M.open_discord_settings(w)
    if w._discordForm ~= nil then
        return
    end

    local discForm = forms.newform(420, 200, "Discord Settings", function()
        -- See open_advanced_settings's onclose callback for why this
        -- deliberately does NOT re-read/re-save the controls here (and
        -- doesn't touch disk via GuiSettings either) - closing via X
        -- used to silently corrupt already-saved values this same way.
        w._discordForm = nil
        w.chkDiscord = nil
        w.chkPingUser = nil
        w.txtPingId = nil
    end)
    local y = 10

    w.chkDiscord = forms.checkbox(discForm, "Send Discord notification (shiny/stop)", 10, y)
    forms.setproperty(w.chkDiscord, "Width", 380)
    if w._savedDiscordEnabled then forms.setproperty(w.chkDiscord, "Checked", true) end
    y = y + 20
    w.lblDiscordHint = forms.label(discForm, "(requires local relay - see discord_relay.ps1)", 28, y, 380, 16)
    y = y + 30

    w.chkPingUser = forms.checkbox(discForm, "Ping user or role", 10, y)
    forms.setproperty(w.chkPingUser, "Width", 150)
    if w._savedPingEnabled then forms.setproperty(w.chkPingUser, "Checked", true) end
    w.txtPingId = forms.textbox(discForm, w._savedPingIdText or "", 190, 20, nil, 165, y - 2)
    y = y + 20
    w.lblPingIdHint1 = forms.label(discForm, "User ID for a user ping (e.g. 123456789012345678).", 28, y, 380, 16)
    y = y + 16
    w.lblPingIdHint2 = forms.label(discForm, "For a role/group ping, put && in front (e.g. &&123456789012345678).", 28, y, 380, 16)
    y = y + 16
    w.lblPingIdHint3 = forms.label(discForm, "Right-click the user/role in Discord (Developer Mode on) > Copy ID.", 28, y, 380, 16)
    y = y + 30

    forms.button(discForm, "Save", function()
        save_discord_settings(w)
        forms.destroy(discForm)
    end, 10, y, 100, 25)

    w._discordForm = discForm

    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

function M.create(existingForm, yOffset, disabledFields)
    local widgets = { frm = existingForm, yOffset = yOffset }

    -- Seed the ping user/role ID (and whether pinging is on) from disk -
    -- M.create() only ever runs once per BizHawk session (see
    -- launcher.lua's "if sharedHud == nil" guard), so this is the one
    -- correct place to load it: before that, Discord Settings hasn't
    -- been opened yet, so w._savedPingIdText would otherwise still be
    -- nil and the field would show blank even though a value was saved
    -- last time.
    GuiSettings.load()
    widgets._savedPingEnabled = GuiSettings.pingEnabled
    widgets._savedPingIdText = GuiSettings.pingIdText

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

    widgets.chkStopOnShiny  = forms.checkbox(existingForm, "Stop on ANY shiny (manual mode - overrides Auto-Catch)", 10, y)
    forms.setproperty(widgets.chkStopOnShiny, "Width", 380)
    y = y + 26

    widgets.chkKillMode     = forms.checkbox(existingForm, "Kill non-shiny (use first move)", 10, y)
    forms.setproperty(widgets.chkKillMode, "Width", 380)
    y = y + 22
    widgets.lblKillFilter   = forms.label(existingForm, "Only kill IDs or names (comma-sep, blank=all):", 28, y, 380, 16)
    y = y + 18
    widgets.txtKillFilter   = forms.textbox(existingForm, "", 320, 20, nil, 28, y)
    y = y + 34

    widgets.lblSepAutoCatch = forms.label(existingForm, SEPARATOR, 10, y, 340, 16)
    y = y + 18

    -- Auto-Catch, Discord, and Advanced Settings all live in their own
    -- popup windows instead of cluttering the main form - built lazily
    -- on first click, not at startup, so they're genuinely hidden until
    -- asked for rather than just visually tucked away.
    widgets.btnAutoCatchSettings = forms.button(existingForm, "Auto-Catch Settings...", function()
        M.open_autocatch_settings(widgets)
    end, 10, y, 150, 25)
    y = y + 30

    widgets.btnDiscordSettings = forms.button(existingForm, "Discord Settings...", function()
        M.open_discord_settings(widgets)
    end, 10, y, 150, 25)
    y = y + 30

    widgets.btnAdvancedSettings = forms.button(existingForm, "Advanced Settings...", function()
        M.open_advanced_settings(widgets)
    end, 10, y, 150, 25)
    y = y + 35

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
    if w.chkStopItem == nil then
        return w._savedStopItemEnabled or false, parse_filter_tokens(w._savedItemFilterText)
    end
    local enabled = forms.ischecked(w.chkStopItem)
    local raw = forms.gettext(w.txtItemFilter)
    w._savedStopItemEnabled = enabled
    w._savedItemFilterText = raw
    return enabled, parse_filter_tokens(raw)
end

function M.kill_non_shiny(w)
    return forms.ischecked(w.chkKillMode)
end

function M.auto_catch_enabled(w)
    if w.chkAutoCatch == nil then return w._savedAutoCatchEnabled or false end
    local enabled = forms.ischecked(w.chkAutoCatch)
    w._savedAutoCatchEnabled = enabled
    return enabled
end

function M.skip_already_caught_enabled(w)
    if w.chkSkipAlreadyCaught == nil then return w._savedSkipAlreadyCaught or false end
    local enabled = forms.ischecked(w.chkSkipAlreadyCaught)
    w._savedSkipAlreadyCaught = enabled
    return enabled
end

function M.catch_species_filter(w)
    local raw
    if w.txtCatchFilter == nil then
        raw = w._savedCatchFilterText
    else
        raw = forms.gettext(w.txtCatchFilter)
        w._savedCatchFilterText = raw
    end
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

-- Read by do_catch_sequence in wild.lua/headbutt.lua/fishing.lua only -
-- see the checkbox's own comment in open_autocatch_settings above for
-- why this exists. Same nil-safe fallback pattern as every other
-- getter here (widget handle only lives while the popup is open).
function M.dont_weaken_enabled(w)
    if w.chkDontWeaken == nil then return w._savedDontWeaken or false end
    local enabled = forms.ischecked(w.chkDontWeaken)
    w._savedDontWeaken = enabled
    return enabled
end

function M.crit_safety_override_enabled(w)
    if w.chkOverrideCritSafety == nil then return w._savedOverrideCritSafety or false end
    local enabled = forms.ischecked(w.chkOverrideCritSafety)
    w._savedOverrideCritSafety = enabled
    return enabled
end

-- Returns the custom HP% as a fraction (e.g. 40 -> 0.40). Falls back to
-- 0.40 if the field is empty, non-numeric, or out of a sane 1-100 range,
-- rather than risking a bad value silently breaking the weaken-loop.
function M.custom_catch_hp_target(w)
    if w.txtCustomHpTarget == nil then
        local savedNumber = tonumber(w._savedCustomHpTargetText)
        if savedNumber == nil or savedNumber < 1 or savedNumber > 100 then
            return 0.40
        end
        return savedNumber / 100
    end
    local raw = forms.gettext(w.txtCustomHpTarget)
    w._savedCustomHpTargetText = raw
    local asNumber = tonumber(raw)
    if asNumber == nil or asNumber < 1 or asNumber > 100 then
        return 0.40
    end
    return asNumber / 100
end

function M.stop_on_shiny(w)
    return forms.ischecked(w.chkStopOnShiny)
end

-- "Stop Auto-Catch on specific shiny" - species in this list get
-- excluded from Auto-Catch specifically (stop for manual catching
-- instead), while everything else still gets auto-caught normally.
-- Lets a rare/valuable species be reserved for the user while the bot
-- keeps auto-catching everything else.
function M.auto_catch_stop_exception(w)
    local enabled, raw
    if w.chkStopAutoCatchException == nil then
        enabled = w._savedStopAutoCatchException or false
        raw = w._savedStopAutoCatchExceptionText
    else
        enabled = forms.ischecked(w.chkStopAutoCatchException)
        raw = forms.gettext(w.txtStopAutoCatchException)
        w._savedStopAutoCatchException = enabled
        w._savedStopAutoCatchExceptionText = raw
    end
    if raw == nil or raw:match("^%s*$") then
        return enabled, nil
    end
    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(tokens, trimmed)
        end
    end
    if #tokens == 0 then return enabled, nil end
    return enabled, tokens
end

-- Auto-catch if the shiny is holding this specific item, regardless of
-- species - an OR condition alongside the species filter, not an
-- additional requirement on top of it.
function M.catch_on_item(w)
    if w.chkCatchOnItem == nil then
        return w._savedCatchOnItemEnabled or false, parse_filter_tokens(w._savedCatchItemFilterText)
    end
    local enabled = forms.ischecked(w.chkCatchOnItem)
    local raw = forms.gettext(w.txtCatchItemFilter)
    w._savedCatchOnItemEnabled = enabled
    w._savedCatchItemFilterText = raw
    return enabled, parse_filter_tokens(raw)
end

-- Auto-catch on a Perfect (15/15/15/15) or Perfect Negative (0/0/0/0) DV
-- roll, independent of shininess - same simple checkbox-getter pattern as
-- skip_already_caught_enabled/auto_catch_enabled above.
function M.catch_on_perfect(w)
    if w.chkCatchOnPerfect == nil then return w._savedCatchOnPerfect or false end
    local enabled = forms.ischecked(w.chkCatchOnPerfect)
    w._savedCatchOnPerfect = enabled
    return enabled
end

function M.catch_on_perfect_negative(w)
    if w.chkCatchOnPerfectNegative == nil then return w._savedCatchOnPerfectNegative or false end
    local enabled = forms.ischecked(w.chkCatchOnPerfectNegative)
    w._savedCatchOnPerfectNegative = enabled
    return enabled
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
    if w.chkDiscord == nil then return w._savedDiscordEnabled or false end
    local enabled = forms.ischecked(w.chkDiscord)
    w._savedDiscordEnabled = enabled
    return enabled
end

-- Returns a ready-to-send Discord mention string (e.g. "<@123...>" for a
-- user, "<@&123...>" for a role/group), or nil if the ping is disabled
-- or the ID field is blank. This only works when placed in a message's
-- top-level "content" field - Discord does NOT trigger pings from text
-- inside an embed (title/description/fields), no matter how it's
-- formatted, so every caller needs to thread this into "content"
-- alongside the embed rather than putting it in a field.
function M.ping_mention(w)
    local enabled, raw
    if w.chkPingUser == nil then
        enabled = w._savedPingEnabled or false
        raw = w._savedPingIdText
    else
        enabled = forms.ischecked(w.chkPingUser)
        raw = forms.gettext(w.txtPingId)
        w._savedPingEnabled = enabled
        w._savedPingIdText = raw
    end
    if not enabled or raw == nil then return nil end
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil end
    if trimmed:sub(1, 1) == "&" then
        return string.format("<@&%s>", trimmed:sub(2))
    else
        return string.format("<@%s>", trimmed)
    end
end

function M.verbose_logging(w)
    if w.chkVerbose == nil then return w._savedVerbose or false end
    local enabled = forms.ischecked(w.chkVerbose)
    w._savedVerbose = enabled
    return enabled
end

function M.true_randomness_enabled(w)
    if w.chkTrueRandomness == nil then return w._savedTrueRandomness or false end
    local enabled = forms.ischecked(w.chkTrueRandomness)
    w._savedTrueRandomness = enabled
    return enabled
end

return M

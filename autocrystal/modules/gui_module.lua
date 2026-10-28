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

-- Persists settings across script reloads/BizHawk restarts - see
-- data/gui_settings.lua for why these can't just live in the in-memory
-- widgets table, and PERSISTED_POPUP_SETTINGS below for which ones.
GuiSettings = GuiSettings or require("data.gui_settings")

-- Fallback for M.create()'s rootDir: modules/.. (launcher.lua passes its
-- own script_dir, same as it does for stats_window.lua).
local MODULE_DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

-- Every popup setting that survives a restart: the _savedXxx field the
-- getters further down already fall back to whenever the popup is
-- closed, the key it's stored under in gui_settings.txt, and whether it
-- comes from a checkbox ("bool") or a textbox ("text"). Grouped by popup
-- because each group is written ONLY by its own popup's Save button -
-- closing a popup via X still discards its unsaved edits, same as before
-- (see open_advanced_settings's onclose comment) - and read back once,
-- in M.create(). "pingenabled"/"pingid" keep the names the original
-- ping-only version of gui_settings.txt used.
local PERSISTED_POPUP_SETTINGS = {
    -- These lived on the main window (polled and saved once a second)
    -- until they moved into General Settings - same keys as back then, so
    -- anything saved from the main window still loads.
    general = {
        {field = "_savedStopPerfect", key = "stopperfect", kind = "bool"},
        {field = "_savedStopNegative", key = "stopnegative", kind = "bool"},
        {field = "_savedStopSpeciesEnabled", key = "stopspecies", kind = "bool"},
        {field = "_savedSpeciesIdText", key = "speciesid", kind = "text"},
        {field = "_savedStopOnShiny", key = "stoponshiny", kind = "bool"},
        {field = "_savedKillModeEnabled", key = "killmode", kind = "bool"},
        {field = "_savedKillFilterText", key = "killfilter", kind = "text"},
    },
    advanced = {
        {field = "_savedStopItemEnabled", key = "stopitem", kind = "bool"},
        {field = "_savedItemFilterText", key = "itemfilter", kind = "text"},
        {field = "_savedOverrideCritSafety", key = "overridecritsafety", kind = "bool"},
        {field = "_savedCustomHpTargetText", key = "customhptarget", kind = "text"},
        {field = "_savedVerbose", key = "verbose", kind = "bool"},
        {field = "_savedTrueRandomness", key = "truerandomness", kind = "bool"},
        {field = "_savedThiefModeEnabled", key = "thiefmode", kind = "bool"},
        {field = "_savedThiefFilterText", key = "thieffilter", kind = "text"},
        {field = "_savedThiefNotifyEnabled", key = "thiefnotify", kind = "bool"},
        -- Also read by both relays, which quit once it's "1".
        {field = "_savedRelaysDisabled", key = "relaysdisabled", kind = "bool"},
    },
    autocatch = {
        {field = "_savedAutoCatchEnabled", key = "autocatch", kind = "bool"},
        {field = "_savedCatchFilterText", key = "catchfilter", kind = "text"},
        {field = "_savedSkipAlreadyCaught", key = "skipalreadycaught", kind = "bool"},
        {field = "_savedStopAutoCatchException", key = "catchexception", kind = "bool"},
        {field = "_savedStopAutoCatchExceptionText", key = "catchexceptionfilter", kind = "text"},
        {field = "_savedCatchOnItemEnabled", key = "catchonitem", kind = "bool"},
        {field = "_savedCatchItemFilterText", key = "catchitemfilter", kind = "text"},
        {field = "_savedCatchOnPerfect", key = "catchonperfect", kind = "bool"},
        {field = "_savedCatchOnPerfectNegative", key = "catchonperfectnegative", kind = "bool"},
        {field = "_savedDontWeaken", key = "dontweaken", kind = "bool"},
    },
    discord = {
        -- Read straight from the settings file by discord_relay.ps1 for
        -- every message it forwards - see save_discord_settings().
        {field = "_savedWebhookUrl", key = "discordwebhook", kind = "text"},
        {field = "_savedDiscordEnabled", key = "discordenabled", kind = "bool"},
        {field = "_savedPingEnabled", key = "pingenabled", kind = "bool"},
        {field = "_savedPingIdText", key = "pingid", kind = "text"},
    },
}

-- ===== PokeGear theme =====
-- Colors sampled from a Crystal PokeGear screenshot: the GBC's pale
-- green screen, black frames and text, orange accent. forms.setproperty
-- can set colors ("#RRGGBB") and enums like FlatStyle, but not fonts, so
-- text stays in the default Windows font.
--
-- Frames are plain labels only (thin filled labels used as lines), never
-- a picturebox backdrop, and nothing is ever layered over anything else:
-- a control created later always ends up BEHIND earlier ones (WinForms
-- z-order) - exactly what painted over labels in the old canvas-backdrop
-- attempt described at the top of this file. So a panel's "inside" is
-- just the window background showing through, with its content placed
-- clear of the border lines.
M.THEME = {
    -- The cream inside the PokeGear's clock box (sampled), not its green
    -- screen color - the green read too strong across a whole window.
    background = "#FAF1CA",
    text = "#000000",
    border = "#000000",
    -- The two greys of the clock box's bevel (sampled, same screenshot
    -- as the cream above) - see M.draw_frame().
    frameLight = "#D2D2D2",
    frameDark = "#7D7D7D",
    button = "#F8F8F8",
    header = "#783800",
    accent = "#F87800",
    -- The PokeGear's "you are here" peach, for the active tab button.
    selected = "#F89850",
    -- Clickable text (the guide link) - fonts can't be set, so no
    -- underline; the color is the only cue.
    link = "#2050B0",
    card = "#FFFFFF",
}

-- Every styling call is pcall-wrapped: a theme glitch should never be
-- able to stop the bot itself.
local function set_style(handle, property, value)
    pcall(forms.setproperty, handle, property, value)
end

-- Window background + default text color. Labels and checkboxes that
-- don't set their own pick these up automatically (WinForms "ambient"
-- colors).
function M.style_window(form)
    set_style(form, "BackColor", M.THEME.background)
    set_style(form, "ForeColor", M.THEME.text)
end

-- Flat white button with a thin black border (a flat button's border
-- defaults to its text color) - like the PokeGear's "SWITCH>" tab.
function M.style_button(handle)
    set_style(handle, "FlatStyle", "Flat")
    set_style(handle, "BackColor", M.THEME.button)
    set_style(handle, "ForeColor", M.THEME.text)
end

-- Dropdowns only honor BackColor in Flat style.
function M.style_dropdown(handle)
    set_style(handle, "FlatStyle", "Flat")
    set_style(handle, "BackColor", M.THEME.button)
end

function M.style_header(handle)
    set_style(handle, "ForeColor", M.THEME.header)
end

local function filled_label(form, x, y, w, h, color)
    local lbl = forms.label(form, "", x, y, w, h)
    set_style(lbl, "BackColor", color)
    return lbl
end

-- One ring of a frame, t px thick: topLeft color along the top and left
-- sides, bottomRight along the bottom and right. Where sides overlap, the
-- one created first ends up on top (z-order), so bottom/right win the
-- corners. notched leaves the outermost top-right and bottom-left pixel
-- out, the way the GBC tiles round those corners off.
local function frame_ring(form, x, y, w, h, t, topLeft, bottomRight, notched)
    local n = notched and 1 or 0
    filled_label(form, x + w - t, y + n, t, h - n, bottomRight) -- right
    filled_label(form, x + n, y + h - t, w - n, t, bottomRight) -- bottom
    filled_label(form, x, y, w - n, t, topLeft)                 -- top
    filled_label(form, x, y, t, h - n, topLeft)                 -- left
end

-- The PokeGear clock box's frame, measured pixel by pixel from a real
-- screenshot: three rings, each 2 GBC pixels thick - outside, light grey
-- along the top/left and dark grey along the bottom/right; then the same
-- two greys swapped; then solid black against the inside. The swap is
-- what makes it look raised.
--
-- Drawn 2px OUTSIDE (x, y, w, h), so the black ring's inner edge sits 4px
-- inside the rect: content at x + 8 / y + 8 keeps a 4px gap from it, and
-- nothing ever overlaps the rings.
function M.draw_frame(form, x, y, w, h)
    local t = 2
    local fx, fy, fw, fh = x - 2, y - 2, w + 4, h + 4
    frame_ring(form, fx, fy, fw, fh, t, M.THEME.frameLight, M.THEME.frameDark, true)
    frame_ring(form, fx + t, fy + t, fw - 2 * t, fh - 2 * t, t, M.THEME.frameDark, M.THEME.frameLight, false)
    frame_ring(form, fx + 2 * t, fy + 2 * t, fw - 4 * t, fh - 4 * t, t, M.THEME.border, M.THEME.border, false)
end

-- Main-window panel geometry, shared with launcher.lua's top panel so
-- every frame lines up. 432 wide (not the window's full 460) because
-- launcher.lua's forms.setsize() sets the OUTER size, borders included.
M.PANEL_X = 6
M.PANEL_W = 432
-- Space between stacked panels' rects - their frames reach 2px past each
-- rect, so 10 leaves a 6px gap between the frames themselves.
M.PANEL_GAP = 10
local PANEL_GAP = M.PANEL_GAP

-- ===== Settings popup layout =====
-- Same look as the main window: framed sections stacked top to bottom,
-- each with a header, and the Save button under the last one. Same rule
-- as everywhere else - nothing overlaps anything.
local POPUP_W = 420
local POPUP_FRAME_X = 6
local POPUP_X = POPUP_FRAME_X + 8          -- content column (inside a frame)
local POPUP_INDENT_X = POPUP_X + 18        -- sub-options under a checkbox
local POPUP_TEXT_W = POPUP_W - POPUP_INDENT_X - 12 -- hint text, up to the frame

-- A popup window in the PokeGear style. Created short on purpose -
-- add_save_button() sizes it to fit once everything is in it.
local function new_popup(title, onclose)
    local form = forms.newform(POPUP_W, 100, title, onclose)
    M.style_window(form)
    -- Safety net from the main shell window (a real user report of
    -- controls being cut off with no way to reach them on a scaled
    -- display) - does nothing when everything already fits.
    forms.setproperty(form, "AutoScroll", true)
    return form
end

-- A section header at y (the section's top). Returns where the section's
-- content starts.
local function begin_section(form, y, title)
    M.style_header(forms.label(form, title, POPUP_X, y + 10, POPUP_W - 2 * POPUP_X, 16))
    return y + 30
end

-- Frames a section from its top down to contentBottom (the bottom edge of
-- its last control). Returns the next section's top.
local function end_section(form, top, contentBottom)
    local h = contentBottom - top + 9
    M.draw_frame(form, POPUP_FRAME_X, top, POPUP_W - 2 * POPUP_FRAME_X, h)
    return top + h + PANEL_GAP
end

local function popup_checkbox(form, text, x, y, width, checked)
    local c = forms.checkbox(form, text, x, y)
    forms.setproperty(c, "Width", width)
    set_style(c, "FlatStyle", "Flat")
    if checked then forms.setproperty(c, "Checked", true) end
    return c
end

-- Keeps the default (3D) border on purpose: changing a textbox's
-- BorderStyle - or UseSystemPasswordChar - after it exists makes WinForms
-- destroy and recreate its window with a NEW handle, while BizHawk's
-- forms.* functions find controls by the handle forms.textbox() returned.
-- Every later forms.gettext() on it then quietly returns "", so Save wiped
-- the field (that's what kept blanking the webhook and ping ID).
local function popup_textbox(form, text, width, x, y)
    return forms.textbox(form, text or "", width, 20, nil, x, y)
end

-- The Save button at y (under the last section), then the window resized
-- to fit. forms.setsize() takes the OUTER size, so this adds the borders
-- and title bar of a FixedDialog window at 100% scaling (+16/+39) - on
-- other scaling, AutoScroll covers any difference.
local function add_save_button(form, y, onSave)
    M.style_button(forms.button(form, "Save", onSave, POPUP_X, y, 100, 25))
    forms.setsize(form, POPUP_W + 16, y + 25 + 10 + 39)
end

-- Seeds every popup's _savedXxx field from disk. A key that was never
-- saved leaves its field nil, so each control keeps its own built-in
-- default (e.g. Thief's Discord notify defaulting to on).
local function load_popup_settings(w)
    for _, entries in pairs(PERSISTED_POPUP_SETTINGS) do
        for _, s in ipairs(entries) do
            local value
            if s.kind == "bool" then
                value = GuiSettings.get_bool(s.key)
            else
                value = GuiSettings.get_text(s.key)
            end
            if value ~= nil then
                w[s.field] = value
            end
        end
    end
end

-- Writes one popup's _savedXxx fields to disk - only call this right
-- after that popup's Save has refreshed them from its live controls.
local function persist_popup_settings(w, popup)
    local changed = false
    for _, s in ipairs(PERSISTED_POPUP_SETTINGS[popup]) do
        local value = w[s.field]
        if value ~= nil and GuiSettings.set(s.key, value) then
            changed = true
        end
    end
    if changed then
        GuiSettings.save()
    end
end

-- ===== Current-encounter sprite =====
-- Same approach stats_window.lua uses: one picturebox per sprite, set up
-- exactly ONCE when first needed, then only ever shown/hidden. Sprites
-- are local files the Stats window's "Download sprites..." button fetches
-- (download_sprites.ps1), at 1.625x on a white card (about the launcher
-- artwork's size), preferring the animated Crystal GIFs:
--   data/sprites/animated_card/{normal,shiny}/<dex>.gif - 91px, made by
--     tools/scale_sprites.ps1 nearest-neighbor, so they stay sharp (a
--     picturebox can only scale a GIF smoothly, which blurs it);
--   else data/sprites/animated/{normal,shiny}/<dex>.gif, scaled up;
--   else data/sprites/{normal,shiny}/<dex>.png, scaled up.
-- A missing file just means no sprite for that species. An unhatched Egg
-- (species 253) shows data/sprites/egg_card.png instead - made from
-- data/sprites/normal/egg.png by tools/make_egg_sprites.ps1.
local SPRITE_CARD_SIZE = 98
-- How much bigger than the 56px Crystal sprites they're shown - the same
-- scale tools/scale_sprites.ps1 makes the card GIFs at.
local SPRITE_SCALE = 1.625
-- What the game holds as the species of an Egg that hasn't hatched yet.
local EGG_SPECIES = 0xFD

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- Width/height straight from the PNG's IHDR chunk (bytes 17-24).
local function png_size(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local header = f:read(24)
    f:close()
    if header == nil or #header < 24 or header:sub(2, 4) ~= "PNG" then return nil end
    local function u32(i)
        local a, b, c, d = header:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
end

-- The kinds of sprite file, best first: folder, extension, and how the
-- card shows it ("center" = as-is, "zoom" = GIF scaled up to fit, "png" =
-- drawn at SPRITE_SCALE).
local SPRITE_KINDS = {
    {dir = "animated_card/", ext = "gif", show = "center"},
    {dir = "animated/", ext = "gif", show = "zoom"},
    {dir = "", ext = "png", show = "png"},
}

-- Which file to show for this species, how, and the cache key for its
-- box: the shiny sprite for a shiny (best kind downloaded), falling back
-- to the normal one when there's no shiny sprite at all.
local function find_sprite(w, species, isShiny)
    if species == EGG_SPECIES then
        local path = w._rootDir .. "data/sprites/egg_card.png"
        if file_exists(path) then return path, "egg", "center" end
        return nil
    end
    if type(species) ~= "number" or species < 1 or species > 251 then return nil end
    local shinyOptions = isShiny and {true, false} or {false}
    for _, shiny in ipairs(shinyOptions) do
        for i, kind in ipairs(SPRITE_KINDS) do
            local path = string.format("%sdata/sprites/%s%s/%d.%s", w._rootDir, kind.dir,
                shiny and "shiny" or "normal", species, kind.ext)
            if file_exists(path) then
                return path, species .. (shiny and "s" or "n") .. i, kind.show
            end
        end
    end
    return nil
end

-- The picturebox for this species' sprite, created the first time it's
-- needed; nil if there's no sprite file for it. Created hidden - see
-- show_sprite().
local function get_sprite_box(w, species, isShiny)
    local path, key, show = find_sprite(w, species, isShiny)
    if path == nil then return nil end
    local box = w._spriteBoxes[key]
    if box then return box end

    if show ~= "png" then
        -- The picturebox loads the file itself and, for a GIF, plays it
        -- (only while it's shown) - forms.drawImage would only ever draw
        -- its first frame. None of these properties recreate the
        -- control's handle (see popup_textbox()).
        box = forms.pictureBox(w.frm, w._spriteX, w._spriteY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE)
        set_style(box, "BackColor", M.THEME.card)
        set_style(box, "SizeMode", show == "zoom" and "Zoom" or "CenterImage")
        set_style(box, "WaitOnLoad", true)
        set_style(box, "ImageLocation", path)
    else
        local width, height = png_size(path)
        if width == nil then return nil end
        width = math.min(math.floor(width * SPRITE_SCALE + 0.5), SPRITE_CARD_SIZE)
        height = math.min(math.floor(height * SPRITE_SCALE + 0.5), SPRITE_CARD_SIZE)
        box = forms.pictureBox(w.frm, w._spriteX, w._spriteY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE)
        pcall(forms.clear, box, M.THEME.card)
        pcall(forms.drawImage, box, path,
            math.floor((SPRITE_CARD_SIZE - width) / 2), math.floor((SPRITE_CARD_SIZE - height) / 2), width, height)
        pcall(forms.refresh, box)
    end
    set_style(box, "Visible", false)
    w._spriteBoxes[key] = box
    return box
end

-- Shows one sprite (nil = none) in the Last Encounter card. The blank
-- white card label fills in whenever no sprite is showing - it sits
-- IN FRONT of every sprite box (created earlier, so higher in z-order),
-- which is why it has to be hidden rather than just covered.
local function show_sprite(w, box)
    if w._shownSprite == box then return end
    if w._shownSprite then set_style(w._shownSprite, "Visible", false) end
    if box then set_style(box, "Visible", true) end
    set_style(w.lblSpriteCard, "Visible", box == nil)
    w._shownSprite = box
end

-- ===== Getting-started text =====
-- Until the first module starts there's nothing to show in Last/Recent
-- Encounters, so they hold a short how-to and the guide link instead.
-- set_idle_help(w, false) puts them back; every function below that writes
-- into those panels does that first, so the how-to can never get mixed in
-- with real encounters.
M.GUIDE_URL = "https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit"

local IDLE_LAST_LINES = {
    "1. Load a supported ROM in BizHawk",
    "    (File > Open ROM): Gold, Silver or Crystal.",
    "2. Select a module above, then click Start.",
    "",
}
-- Seven lines - the link takes the eighth row, right under the last one.
local IDLE_HISTORY_LINES = {
    "Your encounters will show up here once a module runs.",
    "", "", "", "",
    "Setup help, module guides and updates are on GitHub",
    "(click the link below to open it in your browser):",
}

local function set_idle_help(w, on)
    if w._idleHelp == on then return end
    w._idleHelp = on
    forms.settext(w.lblLastHeader, on and "GETTING STARTED:" or "LAST ENCOUNTER:")
    if on then
        forms.settext(w.lblLastSpecies, IDLE_LAST_LINES[1])
        forms.settext(w.lblLastStats, IDLE_LAST_LINES[2])
        forms.settext(w.lblLastItem, IDLE_LAST_LINES[3])
        forms.settext(w.lblLastShiny, IDLE_LAST_LINES[4])
        for i = 1, 7 do
            forms.settext(w.history[i], IDLE_HISTORY_LINES[i] or "")
        end
    end
    -- The link sits on history line 8's row (it can't share a row with a
    -- visible label - see the theme notes on overlaps), so the two swap.
    set_style(w.history[8], "Visible", not on)
    set_style(w.lblGuideLink, "Visible", on)
end

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
    "chkThiefMode", "txtThiefFilter", "chkThiefNotify",
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
    set_idle_help(w, false)
    forms.settext(w.lblLastSpecies, "Species: -")
    forms.settext(w.lblLastStats, "Atk/Def/Spe/Spc: -")
    forms.settext(w.lblLastItem, "Held Item: -")
    forms.settext(w.lblLastShiny, "Shiny: -")
    set_style(w.lblLastShiny, "ForeColor", M.THEME.text)
    show_sprite(w, nil)
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
    w._savedThiefModeEnabled = forms.ischecked(w.chkThiefMode)
    w._savedThiefFilterText = forms.gettext(w.txtThiefFilter)
    w._savedThiefNotifyEnabled = forms.ischecked(w.chkThiefNotify)
    w._savedRelaysDisabled = forms.ischecked(w.chkRelaysDisabled)
    persist_popup_settings(w, "advanced")

    -- Saved (above) before acting on it: turning the relays OFF needs no
    -- call - both relays watch the settings file and quit within a couple
    -- of seconds - but turning them back ON means starting them, which
    -- launcher.lua does through M.on_relays_toggled. Compared against
    -- what's actually in effect (_relaysAppliedDisabled), not the old
    -- saved value: the getter below already refreshes that one live
    -- while this popup is open.
    if w._savedRelaysDisabled ~= w._relaysAppliedDisabled then
        w._relaysAppliedDisabled = w._savedRelaysDisabled
        if M.on_relays_toggled then pcall(M.on_relays_toggled, w._savedRelaysDisabled) end
    end
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
    persist_popup_settings(w, "autocatch")
end

-- Discord's webhook URLs: https://discord.com/api/webhooks/<id>/<token>,
-- also on discordapp.com and the ptb./canary. subdomains. discord_relay.ps1
-- refuses to forward anywhere else, whatever is saved here.
local WEBHOOK_HOSTS = {
    ["discord.com"] = true, ["discordapp.com"] = true,
    ["ptb.discord.com"] = true, ["canary.discord.com"] = true,
    ["ptb.discordapp.com"] = true, ["canary.discordapp.com"] = true,
}
local function is_discord_webhook(url)
    local host = url:match("^https://([^/]+)/api/webhooks/%d+/[%w_%-]+$")
    return host ~= nil and WEBHOOK_HOSTS[host:lower()] == true
end

local WEBHOOK_HINT_EMPTY = "Paste your webhook here to get notifications (shown as stars)."
local WEBHOOK_HINT_SET = "Saved (shown as stars). A new one applies right away - no restart."
local WEBHOOK_HINT_INVALID = "Not a Discord webhook URL (https://discord.com/api/webhooks/...)"

-- Returns false - and leaves the popup open - if the pasted webhook isn't
-- one, so a typo can't quietly break notifications.
local function save_discord_settings(w)
    local webhook = (forms.gettext(w.txtWebhookUrl) or ""):match("^%s*(.-)%s*$")
    if webhook ~= "" and not is_discord_webhook(webhook) then
        forms.settext(w.lblWebhookHint, WEBHOOK_HINT_INVALID)
        set_style(w.lblWebhookHint, "ForeColor", M.THEME.accent)
        return false
    end
    local hadWebhook = (w._savedWebhookUrl or "") ~= ""
    -- discord_relay.ps1 re-reads this from the settings file for every
    -- message it forwards, so persisting it below is all it takes - no
    -- relay restart.
    w._savedWebhookUrl = webhook
    w._savedDiscordEnabled = forms.ischecked(w.chkDiscord)
    -- Pasting a first webhook only makes sense if you want notifications,
    -- so switch them on if they're still off.
    if webhook ~= "" and not hadWebhook then w._savedDiscordEnabled = true end
    w._savedPingEnabled = forms.ischecked(w.chkPingUser)
    w._savedPingIdText = forms.gettext(w.txtPingId)
    persist_popup_settings(w, "discord")
    return true
end

function M.open_advanced_settings(w)
    if w._advancedForm ~= nil then
        -- Already open - nothing more to do. (If it was previously
        -- closed, the onclose callback below resets this to nil, so
        -- we'd correctly fall through and recreate it instead.)
        return
    end

    local advForm = new_popup("Advanced Settings", function()
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
        w.chkThiefMode = nil
        w.txtThiefFilter = nil
        w.chkThiefNotify = nil
        w.chkRelaysDisabled = nil
    end)
    local top = 6
    local y = begin_section(advForm, top, "HELD ITEMS")
    w.chkStopItem = popup_checkbox(advForm, "Stop on held item:", POPUP_X, y, 150, w._savedStopItemEnabled)
    w.txtItemFilter = popup_textbox(advForm, w._savedItemFilterText, 190, POPUP_X + 155, y - 2)
    y = y + 22
    w.lblItemFilterHint = forms.label(advForm, "(ID or name, blank = any item)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(advForm, top, y + 16)

    y = begin_section(advForm, top, "THIEF MODE")

    -- Available for every module now (kill-mode-style battle interaction
    -- requires an actual wild battle to attack in, which static/egg/
    -- gamecorner/starters genuinely don't have - they just receive the
    -- Pokemon directly with no FIGHT/RUN menu at all - so the checkbox
    -- itself still shows there, but stays greyed out via those modules'
    -- own DISABLED_FIELDS/reconfigure calls, same as Kill Mode already
    -- is for them). Assumes the lead Pokemon already has Thief taught in
    -- move slot 1 - this doesn't teach or verify the move itself, it
    -- just uses whatever's in that slot every time PP allows, on the
    -- assumption the user set that up themselves. If move slot 1 has 0
    -- PP, the module skips this entirely and behaves exactly like Thief
    -- mode was never turned on (falls straight through to its normal
    -- flee behavior) - it does NOT fall back to a different move the way
    -- Kill Mode/Catch-mode's attack turns do, since a random second move
    -- stealing nothing is not what "steal held items" means.
    w.chkThiefMode = popup_checkbox(advForm, "Steal held item with Thief (move slot 1), then flee", POPUP_X, y, 390, w._savedThiefModeEnabled)
    y = y + 22
    w.lblThiefFilter = forms.label(advForm, "Only steal these items (comma-sep, blank=any):", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 18
    w.txtThiefFilter = popup_textbox(advForm, w._savedThiefFilterText, 320, POPUP_INDENT_X, y)
    y = y + 24

    -- User-requested: every successful Thief steal used to always send a
    -- Discord notification unconditionally, which turned into unwanted
    -- spam for anyone grinding fast enough to rack up steals every
    -- minute or two. Defaults to CHECKED (notify, matching the original
    -- always-on behavior) so nobody's existing setup goes silent just
    -- from updating - _savedThiefNotifyEnabled is only ever nil before
    -- the very first time this popup gets saved with this checkbox
    -- present, so "~= false" (rather than the plain truthy check every
    -- other checkbox here uses) is what makes that first-run default
    -- land on checked instead of unchecked.
    w.chkThiefNotify = popup_checkbox(advForm, "Notify on Discord for every item stolen", POPUP_X, y, 390, w._savedThiefNotifyEnabled ~= false)
    top = end_section(advForm, top, y + 22)

    y = begin_section(advForm, top, "AUTO-CATCH WEAKENING")
    w.chkOverrideCritSafety = popup_checkbox(advForm, "Override crit-safety - use a custom HP% target instead", POPUP_X, y, 390, w._savedOverrideCritSafety)
    y = y + 24
    w.lblCustomHpTarget = forms.label(advForm, "Custom target HP% (e.g. 40):", POPUP_INDENT_X, y + 2, 200, 16)
    w.txtCustomHpTarget = popup_textbox(advForm, w._savedCustomHpTargetText or "40", 60, POPUP_INDENT_X + 202, y)
    y = y + 24
    w.lblCritSafetyHint = forms.label(advForm, "(skips the predictive crit-safety stop - riskier, but fewer balls wasted)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(advForm, top, y + 16)

    -- For anyone who'd rather not have the two relays (small local web
    -- listeners) running at all - see M.relays_disabled().
    y = begin_section(advForm, top, "DISCORD RELAYS")
    w.chkRelaysDisabled = popup_checkbox(advForm, "Don't run the Discord relays (no notifications or Rich Presence)", POPUP_X, y, 390, w._savedRelaysDisabled)
    y = y + 22
    w.lblRelaysHint1 = forms.label(advForm, "(they only listen on this PC - 127.0.0.1 - and only ever send to Discord.", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 16
    w.lblRelaysHint2 = forms.label(advForm, "Saving this stops or starts them right away.)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(advForm, top, y + 16)

    y = begin_section(advForm, top, "DEBUG")
    w.chkVerbose = popup_checkbox(advForm, "Verbose Logging (for debugging)", POPUP_X, y, 390, w._savedVerbose)
    y = y + 24
    w.chkTrueRandomness = popup_checkbox(advForm, "True Randomness (legacy - unused by Static/Starters/Egg)", POPUP_X, y, 390, w._savedTrueRandomness)
    y = y + 22
    w.lblTrueRandomnessHint1 = forms.label(advForm, "(superseded there by the automatic 30-min pool reroll -", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 16
    w.lblTrueRandomnessHint2 = forms.label(advForm, "kept only in case a future module needs it, see rng_mechanics.md)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(advForm, top, y + 16)

    -- Save reads the controls while they're definitely still alive,
    -- then closes the window itself (forms.destroy() re-enters the
    -- onclose callback above synchronously, but that callback no longer
    -- reads anything - it just nils the handles - so nothing gets
    -- overwritten).
    add_save_button(advForm, top, function()
        save_advanced_settings(w)
        forms.destroy(advForm)
    end)

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

    local acForm = new_popup("Auto-Catch Settings", function()
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
    local top = 6
    local y = begin_section(acForm, top, "SHINIES")
    w.chkAutoCatch = popup_checkbox(acForm, "Auto-catch on shiny", POPUP_X, y, 390, w._savedAutoCatchEnabled)
    y = y + 22
    w.lblCatchFilter = forms.label(acForm, "Only auto-catch IDs or names (comma-sep, blank=all):", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 18
    w.txtCatchFilter = popup_textbox(acForm, w._savedCatchFilterText, 320, POPUP_INDENT_X, y)
    y = y + 22
    w.lblCatchFilterHint = forms.label(acForm, "(non-matching shinies are skipped - hunt continues, still notifies Discord)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 24

    w.chkSkipAlreadyCaught = popup_checkbox(acForm, "Only auto-catch a species the FIRST time (living dex mode)", POPUP_X, y, 390, w._savedSkipAlreadyCaught)
    y = y + 22
    w.lblSkipAlreadyCaughtHint = forms.label(acForm, "(remembered across sessions - already-caught species get skipped)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 24

    w.chkStopAutoCatchException = popup_checkbox(acForm, "EXCEPT stop (don't auto-catch) these specific shinies:", POPUP_X, y, 390, w._savedStopAutoCatchException)
    y = y + 22
    w.txtStopAutoCatchException = popup_textbox(acForm, w._savedStopAutoCatchExceptionText, 320, POPUP_INDENT_X, y)
    y = y + 22
    w.lblStopAutoCatchExceptionHint = forms.label(acForm, "(e.g. keep a rare one for yourself while the bot auto-catches the rest)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(acForm, top, y + 16)

    y = begin_section(acForm, top, "ALSO CATCH (SHINY OR NOT)")
    w.chkCatchOnItem = popup_checkbox(acForm, "Auto-catch on held item:", POPUP_X, y, 150, w._savedCatchOnItemEnabled)
    w.txtCatchItemFilter = popup_textbox(acForm, w._savedCatchItemFilterText, 190, POPUP_X + 155, y - 2)
    y = y + 22
    w.lblCatchItemFilterHint = forms.label(acForm, "(ID or name - catches regardless of species if holding this)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 24

    -- Both independent of shininess, same reasoning/gating as "Auto-catch
    -- on held item" above (still requires the master Auto-Catch toggle) -
    -- these can never overlap with a shiny catch, since shininess itself
    -- requires Def=10, which rules out both all-15 and all-0.
    w.chkCatchOnPerfect = popup_checkbox(acForm, "Auto-catch on Perfect DVs (15/15/15/15)", POPUP_X, y, 390, w._savedCatchOnPerfect)
    y = y + 23
    w.chkCatchOnPerfectNegative = popup_checkbox(acForm, "Auto-catch on Perfect Negative DVs (0/0/0/0)", POPUP_X, y, 390, w._savedCatchOnPerfectNegative)
    top = end_section(acForm, top, y + 22)

    y = begin_section(acForm, top, "WEAKENING")

    -- Skips do_catch_sequence's weaken-first phase entirely (wild/
    -- headbutt/fishing only - see M.dont_weaken_enabled's callers) and
    -- starts throwing balls immediately at full HP instead. Catch rate
    -- per ball is much worse at full HP (Gen 2's catch formula weighs
    -- current HP heavily), but some catches (a shiny with depleted PP,
    -- or a target the user doesn't want risked to an accidental crit/
    -- faint during the weaken turns at all) are worth more balls to
    -- skip that risk entirely - purely a risk/ball-count tradeoff, no
    -- effect on catch legality or DVs either way.
    w.chkDontWeaken = popup_checkbox(acForm, "Don't weaken enemy Pokemon - throw balls immediately", POPUP_X, y, 390, w._savedDontWeaken)
    y = y + 22
    w.lblDontWeakenHint = forms.label(acForm, "(skips attacking to lower HP first - uses more balls on average)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(acForm, top, y + 16)

    add_save_button(acForm, top, function()
        save_autocatch_settings(w)
        forms.destroy(acForm)
    end)

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

    local discForm = new_popup("Discord Settings", function()
        -- See open_advanced_settings's onclose callback for why this
        -- deliberately does NOT re-read/re-save the controls here (and
        -- doesn't touch disk via GuiSettings either) - closing via X
        -- used to silently corrupt already-saved values this same way.
        w._discordForm = nil
        w.chkDiscord = nil
        w.chkPingUser = nil
        w.txtPingId = nil
        w.txtWebhookUrl = nil
        w.lblWebhookHint = nil
    end)
    local top = 6
    -- First, since nothing else here does anything without it - and with
    -- no webhook saved yet, the hint below it asks for one in the accent
    -- color the first time this opens.
    local y = begin_section(discForm, top, "WEBHOOK")
    forms.label(discForm, "Webhook URL (channel > Edit Channel > Integrations > Webhooks):", POPUP_X, y, POPUP_W - 2 * POPUP_X - 4, 16)
    y = y + 18
    w.txtWebhookUrl = popup_textbox(discForm, w._savedWebhookUrl, 380, POPUP_X, y)
    -- Shown as stars: anyone who sees the URL (on a stream, a screenshot)
    -- can post to your channel with it. PasswordChar, not
    -- UseSystemPasswordChar - see popup_textbox() for why.
    set_style(w.txtWebhookUrl, "PasswordChar", "*")
    y = y + 24
    local hasWebhook = (w._savedWebhookUrl or "") ~= ""
    w.lblWebhookHint = forms.label(discForm, hasWebhook and WEBHOOK_HINT_SET or WEBHOOK_HINT_EMPTY, POPUP_X, y, POPUP_W - 2 * POPUP_X - 4, 16)
    if not hasWebhook then set_style(w.lblWebhookHint, "ForeColor", M.THEME.accent) end
    top = end_section(discForm, top, y + 16)

    y = begin_section(discForm, top, "NOTIFICATIONS")
    w.chkDiscord = popup_checkbox(discForm, "Send Discord notification (shiny/stop)", POPUP_X, y, 390, w._savedDiscordEnabled)
    y = y + 22
    local relaysOff = M.relays_disabled(w)
    w.lblDiscordHint = forms.label(discForm,
        relaysOff and "(the relays are off in Advanced Settings - nothing gets sent)"
            or "(sent through discord_relay.ps1 - the launcher starts it for you)",
        POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    if relaysOff then set_style(w.lblDiscordHint, "ForeColor", M.THEME.accent) end
    top = end_section(discForm, top, y + 16)

    y = begin_section(discForm, top, "PING")
    w.chkPingUser = popup_checkbox(discForm, "Ping user or role", POPUP_X, y, 150, w._savedPingEnabled)
    w.txtPingId = popup_textbox(discForm, w._savedPingIdText, 190, POPUP_X + 155, y - 2)
    y = y + 22
    w.lblPingIdHint1 = forms.label(discForm, "User ID for a user ping (e.g. 123456789012345678).", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 16
    w.lblPingIdHint2 = forms.label(discForm, "For a role/group ping, put && in front (e.g. &&123456789012345678).", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 16
    w.lblPingIdHint3 = forms.label(discForm, "Right-click the user/role in Discord (Developer Mode on) > Copy ID.", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    top = end_section(discForm, top, y + 16)

    add_save_button(discForm, top, function()
        if save_discord_settings(w) then
            forms.destroy(discForm)
        end
    end)

    w._discordForm = discForm

    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

local function save_general_settings(w)
    w._savedStopPerfect = forms.ischecked(w.chkStopPerfect)
    w._savedStopNegative = forms.ischecked(w.chkStopNegative)
    w._savedStopSpeciesEnabled = forms.ischecked(w.chkStopSpecies)
    w._savedSpeciesIdText = forms.gettext(w.txtSpeciesId)
    w._savedStopOnShiny = forms.ischecked(w.chkStopOnShiny)
    w._savedKillModeEnabled = forms.ischecked(w.chkKillMode)
    w._savedKillFilterText = forms.gettext(w.txtKillFilter)
    persist_popup_settings(w, "general")
end

-- General Settings popup - the stop conditions and Kill mode, which used
-- to sit on the main window itself. Same lazy-build/Save-only/nil-out
-- pattern as Advanced Settings above (see its onclose comment for why
-- closing via X discards edits instead of saving them).
function M.open_general_settings(w)
    if w._generalForm ~= nil then
        return
    end

    local genForm = new_popup("General Settings", function()
        w._generalForm = nil
        w.chkStopPerfect = nil
        w.chkStopNegative = nil
        w.chkStopSpecies = nil
        w.txtSpeciesId = nil
        w.chkStopOnShiny = nil
        w.chkKillMode = nil
        w.lblKillFilter = nil
        w.txtKillFilter = nil
    end)
    local top = 6
    local y = begin_section(genForm, top, "STOP CONDITIONS")
    w.chkStopPerfect = popup_checkbox(genForm, "Stop on Perfect DVs (15/15/15/15)", POPUP_X, y, 390, w._savedStopPerfect)
    y = y + 23
    w.chkStopNegative = popup_checkbox(genForm, "Stop on Perfect Negative DVs (0/0/0/0)", POPUP_X, y, 390, w._savedStopNegative)
    y = y + 23
    w.chkStopSpecies = popup_checkbox(genForm, "Stop on specific Species ID:", POPUP_X, y, 200, w._savedStopSpeciesEnabled)
    w.txtSpeciesId = popup_textbox(genForm, w._savedSpeciesIdText, 60, POPUP_X + 205, y - 2)
    y = y + 23
    w.chkStopOnShiny = popup_checkbox(genForm, "Stop on ANY shiny (manual mode - overrides Auto-Catch)", POPUP_X, y, 390, w._savedStopOnShiny)
    top = end_section(genForm, top, y + 22)

    y = begin_section(genForm, top, "KILL MODE")
    w.chkKillMode = popup_checkbox(genForm, "Kill non-shiny (use first move)", POPUP_X, y, 390, w._savedKillModeEnabled)
    y = y + 22
    w.lblKillFilter = forms.label(genForm, "Only kill IDs or names (comma-sep, blank=all):", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 18
    w.txtKillFilter = popup_textbox(genForm, w._savedKillFilterText, 320, POPUP_INDENT_X, y)
    top = end_section(genForm, top, y + 20)

    add_save_button(genForm, top, function()
        save_general_settings(w)
        forms.destroy(genForm)
    end)

    w._generalForm = genForm

    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

-- rootDir (optional): the bot's base folder, for the sprite files - see
-- MODULE_DIR above for the fallback.
function M.create(existingForm, yOffset, disabledFields, rootDir)
    local widgets = { frm = existingForm, yOffset = yOffset }

    -- Seed every popup setting from disk - M.create() only ever runs once
    -- per BizHawk session (see launcher.lua's "if sharedHud == nil"
    -- guard), so this is the one correct place to load them: before
    -- that, no popup has been opened yet, so every getter would
    -- otherwise fall back to a nil _savedXxx (blank/unchecked) even
    -- though a value was saved last time.
    GuiSettings.load()
    load_popup_settings(widgets)
    -- Whether the relays are actually running right now - launcher.lua
    -- starts them at startup only when this is false. See
    -- save_advanced_settings() for why this is tracked separately.
    widgets._relaysAppliedDisabled = widgets._savedRelaysDisabled or false

    widgets._rootDir = rootDir or (MODULE_DIR .. "../")
    widgets._spriteBoxes = {}
    widgets._shownSprite = nil

    -- Four framed panels, top to bottom. Each panel's content is created
    -- before its frame - see the theme notes above for why nothing may
    -- overlap.
    local panelX, panelW = M.PANEL_X, M.PANEL_W
    local x = panelX + 8 -- content inset, clear of M.draw_frame's lines
    local textW = panelW - 16
    local y = yOffset

    -- 1) Running totals + status.
    widgets.lblEncounters        = forms.label(existingForm, "TOTAL ENCOUNTERS: 0", x, y + 10, textW, 16)
    widgets.lblSessionEncounters = forms.label(existingForm, "SESSION ENCOUNTERS: 0", x, y + 28, textW, 16)
    widgets.lblShinies           = forms.label(existingForm, "SHINIES: 0", x, y + 46, textW, 16)
    widgets.lblSinceShiny        = forms.label(existingForm, "SINCE LAST SHINY: -", x, y + 64, textW, 16)
    widgets.lblRuntime           = forms.label(existingForm, "RUNTIME: 00:00:00", x, y + 82, textW, 16)
    widgets.lblStatus            = forms.label(existingForm, "STATUS: Starting...", x, y + 100, textW, 16)
    M.draw_frame(existingForm, panelX, y, panelW, 126)
    y = y + 126 + PANEL_GAP

    -- 2) Last encounter, with the species' sprite on a card at the right -
    -- the panel tall enough for the enlarged sprites.
    local lastPanelH = 162
    -- 16 from the panel's right edge: the card gets its own frame (6px of
    -- rings outside the card), plus a 6px gap to the panel's frame.
    local cardX = panelX + panelW - 16 - SPRITE_CARD_SIZE
    local cardY = y + math.floor((lastPanelH - SPRITE_CARD_SIZE) / 2)
    -- 300px: the longest getting-started line (set_idle_help) is 216px.
    local lastTextW = cardX - 10 - x
    widgets.lblLastHeader  = forms.label(existingForm, "LAST ENCOUNTER:", x, y + 10, lastTextW, 16)
    M.style_header(widgets.lblLastHeader)
    widgets.lblLastSpecies = forms.label(existingForm, "Species: -", x, y + 38, lastTextW, 16)
    widgets.lblLastStats   = forms.label(existingForm, "Atk/Def/Spe/Spc: -", x, y + 64, lastTextW, 16)
    widgets.lblLastItem    = forms.label(existingForm, "Held Item: -", x, y + 90, lastTextW, 16)
    widgets.lblLastShiny   = forms.label(existingForm, "Shiny: -", x, y + 116, lastTextW, 16)
    widgets._spriteX, widgets._spriteY = cardX, cardY
    widgets.lblSpriteCard = filled_label(existingForm, cardX, cardY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE, M.THEME.card)
    -- Same frame as the panels, sized so its black ring hugs the card.
    M.draw_frame(existingForm, cardX - 4, cardY - 4, SPRITE_CARD_SIZE + 8, SPRITE_CARD_SIZE + 8)
    M.draw_frame(existingForm, panelX, y, panelW, lastPanelH)
    y = y + lastPanelH + PANEL_GAP

    -- 3) Recent encounters.
    widgets.lblHistHeader = forms.label(existingForm, "RECENT ENCOUNTERS:", x, y + 10, textW, 16)
    M.style_header(widgets.lblHistHeader)
    widgets.history = {}
    widgets._historyData = {}
    for i = 1, 8 do
        widgets.history[i] = forms.label(existingForm, "", x, y + 12 + i * 18, textW, 16)
    end
    -- The guide link, on history line 8's row - see set_idle_help(). Opens
    -- in the default browser; "start" via os.execute is fine from a click
    -- callback (only emu.frameadvance() isn't).
    widgets.lblGuideLink = forms.label(existingForm, (M.GUIDE_URL:gsub("^https://", "")), x, y + 12 + 8 * 18, textW, 16)
    set_style(widgets.lblGuideLink, "ForeColor", M.THEME.link)
    set_style(widgets.lblGuideLink, "Visible", false)
    pcall(forms.addclick, widgets.lblGuideLink, function()
        pcall(os.execute, 'start "" "' .. M.GUIDE_URL .. '"')
    end)
    M.draw_frame(existingForm, panelX, y, panelW, 180)
    y = y + 180 + PANEL_GAP

    widgets.encounterCount = 0
    widgets.shinyCount = 0
    widgets.encountersSinceShiny = 0
    widgets.sessionEncounterCount = 0
    widgets.status = "Starting..."
    widgets._startTime = os.time()

    -- 4) Settings popups, 2x2. Every setting lives in one of these popup
    -- windows instead of cluttering the main form - built lazily on first
    -- click, not at startup, so they're genuinely hidden until asked for.
    local buttonW = math.floor((panelW - 16 - 8) / 2)
    local col2 = x + buttonW + 8
    widgets.btnGeneralSettings = forms.button(existingForm, "General Settings...", function()
        M.open_general_settings(widgets)
    end, x, y + 10, buttonW, 25)
    widgets.btnAutoCatchSettings = forms.button(existingForm, "Auto-Catch Settings...", function()
        M.open_autocatch_settings(widgets)
    end, col2, y + 10, buttonW, 25)
    widgets.btnDiscordSettings = forms.button(existingForm, "Discord Settings...", function()
        M.open_discord_settings(widgets)
    end, x, y + 41, buttonW, 25)
    widgets.btnAdvancedSettings = forms.button(existingForm, "Advanced Settings...", function()
        M.open_advanced_settings(widgets)
    end, col2, y + 41, buttonW, 25)
    for _, btn in ipairs({widgets.btnGeneralSettings, widgets.btnAutoCatchSettings, widgets.btnDiscordSettings, widgets.btnAdvancedSettings}) do
        M.style_button(btn)
    end
    M.draw_frame(existingForm, panelX, y, panelW, 76)
    y = y + 76

    -- The last frame reaches 2px below y; the rest is bottom margin (with
    -- launcher.lua's +30 for the title bar, too little here makes the
    -- AutoScroll window show a scrollbar for a pixel or two).
    widgets.bottomY = y + 18

    set_idle_help(widgets, true)

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
    set_idle_help(w, false)
    forms.settext(w.lblLastSpecies, string.format("Species: %s (#%d)", speciesName, species))
    forms.settext(w.lblLastStats, string.format("Atk/Def/Spe/Spc: %d/%d/%d/%d", atk, def, spe, spc))
    forms.settext(w.lblLastItem, "Held Item: " .. (itemName or "-"))
    forms.settext(w.lblLastShiny, "Shiny: " .. (isShiny and "YES!" or "no"))
    set_style(w.lblLastShiny, "ForeColor", isShiny and M.THEME.accent or M.THEME.text)
    show_sprite(w, get_sprite_box(w, species, isShiny))

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
    set_idle_help(w, false)
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
    set_idle_help(w, false)
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
    set_idle_help(w, false)
    w._historyData = {}
    for i = 1, 8 do
        w._historyData[i] = lines[i]
        forms.settext(w.history[i], lines[i] or "")
    end
end

-- The General Settings getters below use the same nil-safe saved-value
-- fallback as every other popup getter in this file - their widgets only
-- exist while that popup happens to be open.
function M.stop_on_perfect(w)
    if w.chkStopPerfect == nil then return w._savedStopPerfect or false end
    local enabled = forms.ischecked(w.chkStopPerfect)
    w._savedStopPerfect = enabled
    return enabled
end

function M.stop_on_perfect_negative(w)
    if w.chkStopNegative == nil then return w._savedStopNegative or false end
    local enabled = forms.ischecked(w.chkStopNegative)
    w._savedStopNegative = enabled
    return enabled
end

function M.stop_on_species(w)
    local enabled, raw
    if w.chkStopSpecies == nil then
        enabled = w._savedStopSpeciesEnabled or false
        raw = w._savedSpeciesIdText
    else
        enabled = forms.ischecked(w.chkStopSpecies)
        raw = forms.gettext(w.txtSpeciesId)
        w._savedStopSpeciesEnabled = enabled
        w._savedSpeciesIdText = raw
    end
    local targetId = tonumber(raw)
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
    if w.chkKillMode == nil then return w._savedKillModeEnabled or false end
    local enabled = forms.ischecked(w.chkKillMode)
    w._savedKillModeEnabled = enabled
    return enabled
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
    if w.chkStopOnShiny == nil then return w._savedStopOnShiny or false end
    local enabled = forms.ischecked(w.chkStopOnShiny)
    w._savedStopOnShiny = enabled
    return enabled
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
    local raw
    if w.txtKillFilter == nil then
        raw = w._savedKillFilterText
    else
        raw = forms.gettext(w.txtKillFilter)
        w._savedKillFilterText = raw
    end
    return parse_filter_tokens(raw)
end

-- Thief mode now lives in Advanced Settings (a lazily-created popup, see
-- open_advanced_settings) instead of the always-visible main form, so it
-- needs the same nil-safe saved-value fallback every other Advanced/
-- Auto-Catch/Discord getter in this file uses - the widget only exists
-- while that popup happens to be open.
function M.thief_mode_enabled(w)
    if w.chkThiefMode == nil then return w._savedThiefModeEnabled or false end
    local enabled = forms.ischecked(w.chkThiefMode)
    w._savedThiefModeEnabled = enabled
    return enabled
end

-- Same nil-safe saved-value fallback pattern as thief_mode_enabled above,
-- but defaults to true (notify) rather than false when nothing's been
-- saved yet - see this checkbox's own creation comment for why (matches
-- the original always-on behavior for anyone who hasn't touched this new
-- setting).
function M.thief_notify_enabled(w)
    if w.chkThiefNotify == nil then
        if w._savedThiefNotifyEnabled == nil then return true end
        return w._savedThiefNotifyEnabled
    end
    local enabled = forms.ischecked(w.chkThiefNotify)
    w._savedThiefNotifyEnabled = enabled
    return enabled
end

-- Blank = steal any held item. Otherwise only bother using Thief when
-- the wild Pokemon's held item matches one of these (name or ID,
-- comma-separated) - same token format/parsing as every other filter
-- in this file, matched via wild.lua's own species_matches_filter
-- (already generic over "id + name", used the same way for the
-- Auto-Catch-on-item filter).
function M.thief_item_filter(w)
    local raw
    if w.txtThiefFilter == nil then
        raw = w._savedThiefFilterText
    else
        raw = forms.gettext(w.txtThiefFilter)
        w._savedThiefFilterText = raw
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

-- Advanced Settings' "Don't run the Discord relays". Read by launcher.lua
-- at startup (whether to start them at all) and by discord_enabled()
-- below; the relays themselves read the saved value from the settings file.
function M.relays_disabled(w)
    if w.chkRelaysDisabled == nil then return w._savedRelaysDisabled or false end
    local disabled = forms.ischecked(w.chkRelaysDisabled)
    w._savedRelaysDisabled = disabled
    return disabled
end

-- Set by launcher.lua: called with true/false after Advanced Settings'
-- Save changes whether the relays should run (see save_advanced_settings).
M.on_relays_toggled = nil

function M.discord_enabled(w)
    -- No relay, nothing to send through - skip the attempt entirely
    -- rather than have every notification fail against a closed port.
    if M.relays_disabled(w) then return false end
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

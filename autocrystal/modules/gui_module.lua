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
ShinyHistory = ShinyHistory or require("data.shiny_history")
PokemonNames = PokemonNames or require("data.pokemon_names")

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
        {field = "_savedUsePotions", key = "usepotions", kind = "bool"},
    },
    advanced = {
        {field = "_savedStopItemEnabled", key = "stopitem", kind = "bool"},
        {field = "_savedItemFilterText", key = "itemfilter", kind = "text"},
        {field = "_savedOverrideCritSafety", key = "overridecritsafety", kind = "bool"},
        {field = "_savedCustomHpTargetText", key = "customhptarget", kind = "text"},
        {field = "_savedVerbose", key = "verbose", kind = "bool"},
        {field = "_savedTreeOverlay", key = "treeoverlay", kind = "bool"},
        {field = "_savedDarkMode", key = "darkmode", kind = "bool"},
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
        {field = "_savedCatchRetry", key = "catchretry", kind = "bool"},
        {field = "_savedCatchRetryCountText", key = "catchretrycount", kind = "text"},
        {field = "_savedCatchRetryAlways", key = "catchretryalways", kind = "bool"},
        {field = "_savedCatchSendNext", key = "catchsendnext", kind = "bool"},
        {field = "_savedShinySavestate", key = "shinysavestate", kind = "bool"},
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

-- Advanced Settings' dark mode: the same roles, dark. Applied once, at the
-- launcher's start (launcher.lua calls M.apply_theme() before it builds
-- anything), since every control takes its colors when it's made. No white
-- sprite card: the animated sprites are transparent, and the still ones
-- come from their first frames (M.still_sprite()).
local LIGHT_THEME, DARK_THEME = {}, {
    background = "#23252B",
    text = "#E6E6E6",
    border = "#A0A0A0",
    frameLight = "#5A5D66",
    frameDark = "#9A9DA6",
    button = "#33363D",
    header = "#F0A860",
    accent = "#FF8C2A",
    selected = "#B8642A",
    link = "#7FB0FF",
    card = "#23252B",
}
for k, v in pairs(M.THEME) do LIGHT_THEME[k] = v end
M.dark = false

function M.apply_theme(dark)
    M.dark = dark == true
    for k, v in pairs(M.dark and DARK_THEME or LIGHT_THEME) do M.THEME[k] = v end
end

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
    set_style(handle, "ForeColor", M.THEME.text)
end

-- Text boxes keep their default border (see popup_textbox()) - only their
-- colors follow dark mode.
function M.style_textbox(handle)
    if not M.dark then return end
    set_style(handle, "BackColor", M.THEME.button)
    set_style(handle, "ForeColor", M.THEME.text)
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
-- Adds its four lines to `lines` ({h, x, y} each), so a folding panel can
-- move them.
local function frame_ring(form, x, y, w, h, t, topLeft, bottomRight, notched, lines)
    local n = notched and 1 or 0
    local function line(lx, ly, lw, lh, color)
        lines[#lines + 1] = {h = filled_label(form, lx, ly, lw, lh, color), x = lx, y = ly}
    end
    line(x + w - t, y + n, t, h - n, bottomRight) -- right
    line(x + n, y + h - t, w - n, t, bottomRight) -- bottom
    line(x, y, w - n, t, topLeft)                 -- top
    line(x, y, t, h - n, topLeft)                 -- left
end

-- The PokeGear clock box's frame, measured pixel by pixel from a real
-- screenshot: three rings, each 2 GBC pixels thick - outside, light grey
-- along the top/left and dark grey along the bottom/right; then the same
-- two greys swapped; then solid black against the inside. The swap is
-- what makes it look raised.
--
-- Drawn 2px OUTSIDE (x, y, w, h), so the black ring's inner edge sits 4px
-- inside the rect: content at x + 8 / y + 8 keeps a 4px gap from it, and
-- nothing ever overlaps the rings. Returns its lines ({h, x, y} each).
function M.draw_frame(form, x, y, w, h)
    local t, lines = 2, {}
    local fx, fy, fw, fh = x - 2, y - 2, w + 4, h + 4
    frame_ring(form, fx, fy, fw, fh, t, M.THEME.frameLight, M.THEME.frameDark, true, lines)
    frame_ring(form, fx + t, fy + t, fw - 2 * t, fh - 2 * t, t, M.THEME.frameDark, M.THEME.frameLight, false, lines)
    frame_ring(form, fx + 2 * t, fy + 2 * t, fw - 4 * t, fh - 4 * t, t, M.THEME.border, M.THEME.border, false, lines)
    return lines
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

-- Frame rollback's tries per encounter while its Tries box is blank.
local DEFAULT_CATCH_TRIES = 20

-- A popup window in the PokeGear style. Created short on purpose -
-- add_save_button() sizes it to fit once everything is in it. Hidden while
-- it's built (a shown window paints every control as it arrives - about a
-- second for Advanced Settings); add_save_button() shows it, complete.
local function new_popup(title, onclose)
    local form = forms.newform(POPUP_W, 100, title, onclose)
    set_style(form, "Visible", false)
    M.style_window(form)
    return form
end

-- A popup section's frame: the same three rings as M.draw_frame(), drawn
-- into one picture instead of made of 12 line labels each (creating a
-- control is the slow part of building a window). Made after the
-- section's controls, so it sits behind them; its inside is the window's
-- background.
-- The three rings of an fw x fh frame, drawn into picturebox `box` whose
-- top-left sits at (ox, oy) inside the frame - the box shows (clips to)
-- whatever part of the frame it covers.
local function draw_frame_rings(box, ox, oy, fw, fh)
    local t = 2
    pcall(forms.clear, box, M.THEME.background)
    local function rect(rx, ry, rw, rh, color)
        pcall(forms.drawRectangle, box, rx - ox, ry - oy, rw - 1, rh - 1, color, color)
    end
    -- frame_ring()'s lines, drawn in reverse of the order it makes them
    -- (it relies on z-order, the first one on top; here the last one
    -- drawn is on top): left, top, bottom, right.
    local function ring(rx, ry, rw, rh, topLeft, bottomRight, notched)
        local n = notched and 1 or 0
        rect(rx, ry, t, rh - n, topLeft)
        rect(rx, ry, rw - n, t, topLeft)
        rect(rx + n, ry + rh - t, rw - n, t, bottomRight)
        rect(rx + rw - t, ry + n, t, rh - n, bottomRight)
    end
    ring(0, 0, fw, fh, M.THEME.frameLight, M.THEME.frameDark, true)
    ring(t, t, fw - 2 * t, fh - 2 * t, M.THEME.frameDark, M.THEME.frameLight, false)
    ring(2 * t, 2 * t, fw - 4 * t, fh - 4 * t, M.THEME.border, M.THEME.border, false)
    pcall(forms.refresh, box)
end

local function popup_frame(form, x, y, w, h)
    local fx, fy, fw, fh = x - 2, y - 2, w + 4, h + 4
    local box = forms.pictureBox(form, fx, fy, fw, fh)
    draw_frame_rings(box, 0, 0, fw, fh)
    return box
end

-- M.draw_frame() as four pictures - one per edge, 6px (the three rings)
-- thick - instead of 12 line labels: same look, a third of the controls
-- (making a control is the slow part of opening a window). Edges only, so
-- unlike popup_frame() it never hides anything made inside it later
-- (later controls go behind earlier ones). Top and bottom carry the
-- corners. Returns its pieces as {h, x, y}, like M.draw_frame().
function M.draw_frame_fast(form, x, y, w, h)
    local t3 = 6
    local fx, fy, fw, fh = x - 2, y - 2, w + 4, h + 4
    local pieces = {}
    local function strip(sx, sy, sw, sh)
        if sw <= 0 or sh <= 0 then return end
        local box = forms.pictureBox(form, sx, sy, sw, sh)
        draw_frame_rings(box, sx - fx, sy - fy, fw, fh)
        pieces[#pieces + 1] = {h = box, x = sx, y = sy}
    end
    strip(fx, fy, fw, t3)                               -- top
    strip(fx, fy + fh - t3, fw, t3)                     -- bottom
    strip(fx, fy + t3, t3, fh - 2 * t3)                 -- left
    strip(fx + fw - t3, fy + t3, t3, fh - 2 * t3)       -- right
    return pieces
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
    popup_frame(form, POPUP_FRAME_X, top, POPUP_W - 2 * POPUP_FRAME_X, h)
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
    local box = forms.textbox(form, text or "", width, 20, nil, x, y)
    M.style_textbox(box)
    return box
end

-- The Save button at y (under the last section), then the window resized
-- to fit. forms.setsize() takes the OUTER size, so this adds the borders
-- and title bar of a FixedDialog window at 100% scaling (+16/+39) - on
-- other scaling, AutoScroll covers any difference.
local function add_save_button(form, y, onSave)
    M.style_button(forms.button(form, "Save", onSave, POPUP_X, y, 100, 25))
    forms.setsize(form, POPUP_W + 16, y + 25 + 10 + 39)
    -- Safety net from the main shell window (a real user report of
    -- controls being cut off with no way to reach them on a scaled
    -- display) - does nothing when everything already fits. Turned on
    -- last: on while controls arrive, it lays the window out again for
    -- each one.
    forms.setproperty(form, "AutoScroll", true)
    set_style(form, "Visible", true)
end

-- ===== "?" help =====
-- BizHawk's Lua forms have no tooltips and no hover events - only clicks -
-- so an option that needs explaining gets a small "?" button at the right
-- end of its row instead. Clicking it shows the explanation in the popup's
-- help line, just above Save (add_help_line()); clicking it again hides it.
local HELP_SIZE = 20
local HELP_X = POPUP_W - POPUP_FRAME_X - 8 - HELP_SIZE -- inside the frame's right edge
local HELP_LINE_H = 64                                 -- four lines of text
local HELP_PROMPT = "Click a ? to see what that option does."

-- The "?" for the row at y. Make it BEFORE the row's own checkbox: WinForms
-- puts a control created later behind the earlier ones, and the checkboxes
-- reach all the way across. help: the popup's own table, filled in by
-- add_help_line() at the end.
local function help_button(form, help, y, text)
    M.style_button(forms.button(form, "?", function()
        if not help.label then return end
        if help.shown == text then
            help.shown = nil
            forms.settext(help.label, HELP_PROMPT)
            set_style(help.label, "ForeColor", M.THEME.frameDark)
        else
            help.shown = text
            forms.settext(help.label, text)
            set_style(help.label, "ForeColor", M.THEME.text)
        end
    end, HELP_X, y - 1, HELP_SIZE, HELP_SIZE))
end

-- The help line under the last section, at y. Returns where Save goes.
local function add_help_line(form, help, y)
    help.label = forms.label(form, HELP_PROMPT, POPUP_X, y, POPUP_W - 2 * POPUP_X, HELP_LINE_H)
    set_style(help.label, "ForeColor", M.THEME.frameDark)
    return y + HELP_LINE_H + 4
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
-- (download_sprites.ps1), at about 1.54x on a white card (a touch smaller
-- than the launcher artwork), preferring the animated Crystal GIFs:
--   data/sprites/animated_card/{normal,shiny}/<dex>.gif - 86px, made by
--     tools/scale_sprites.ps1 nearest-neighbor, so they stay sharp (a
--     picturebox can only scale a GIF smoothly, which blurs it);
--   else data/sprites/animated/{normal,shiny}/<dex>.gif, scaled up;
--   else data/sprites/{normal,shiny}/<dex>.png, scaled up.
-- A missing file just means no sprite for that species. An unhatched Egg
-- (species 253) shows data/sprites/egg_card.gif instead (animated) - made
-- from data/sprites/normal/egg.gif by tools/make_egg_sprites.ps1.
local SPRITE_CARD_SIZE = 98
-- The Current Encounter card stays white in dark mode too (the user's
-- pick); the other windows' sprites sit on the dark background.
local ENCOUNTER_CARD = "#FFFFFF"
-- How much bigger than the 56px Crystal sprites they're shown - the same
-- scale tools/scale_sprites.ps1 makes the card GIFs at (43/28: 56 -> 86px).
local SPRITE_SCALE = 43 / 28
local CARD_GIF_SIZE = 86
-- What the game holds as the species of an Egg that hasn't hatched yet.
local EGG_SPECIES = 0xFD

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- A species' still sprite file. In dark mode the transparent one made from
-- the animated sprite's first frame (data/sprites/still/, made by
-- tools/scale_sprites.ps1), so it sits on the dark background; otherwise,
-- or before those exist, the downloaded PNG with its white background.
function M.still_sprite(rootDir, species, shiny)
    local set = shiny and "shiny" or "normal"
    if M.dark then
        local path = string.format("%sdata/sprites/still/%s/%d.png", rootDir, set, species)
        if file_exists(path) then return path end
    end
    return string.format("%sdata/sprites/%s/%d.png", rootDir, set, species)
end

-- A GIF's canvas width, from its header (bytes 7-8, little-endian).
local function gif_width(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local header = f:read(8)
    f:close()
    if header == nil or #header < 8 or header:sub(1, 3) ~= "GIF" then return nil end
    return header:byte(7) + 256 * header:byte(8)
end

-- True when sprites were downloaded but the card GIFs are missing or still
-- at an older size (91px before CARD_GIF_SIZE) - launcher.lua then runs
-- tools/scale_sprites.ps1, which remakes just those. Bulbasaur, normal and
-- shiny, stands in for the whole set. Same when the still sprites
-- (M.still_sprite()) aren't made yet.
function M.card_sprites_need_rescale(rootDir)
    for _, set in ipairs({"normal", "shiny"}) do
        if file_exists(string.format("%sdata/sprites/animated/%s/1.gif", rootDir, set)) then
            local width = gif_width(string.format("%sdata/sprites/animated_card/%s/1.gif", rootDir, set))
            if width ~= CARD_GIF_SIZE then return true end
            if not file_exists(string.format("%sdata/sprites/still/%s/1.png", rootDir, set)) then return true end
        end
    end
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
        local path = w._rootDir .. "data/sprites/egg_card.gif"
        if file_exists(path) then return path, "egg", "center" end
        return nil
    end
    if type(species) ~= "number" or species < 1 or species > 251 then return nil end
    local shinyOptions = isShiny and {true, false} or {false}
    for _, shiny in ipairs(shinyOptions) do
        for i, kind in ipairs(SPRITE_KINDS) do
            local path = kind.ext == "png" and M.still_sprite(w._rootDir, species, shiny)
                or string.format("%sdata/sprites/%s%s/%d.%s", w._rootDir, kind.dir, shiny and "shiny" or "normal", species, kind.ext)
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
        set_style(box, "BackColor", ENCOUNTER_CARD)
        set_style(box, "SizeMode", show == "zoom" and "Zoom" or "CenterImage")
        set_style(box, "WaitOnLoad", true)
        set_style(box, "ImageLocation", path)
    else
        local width, height = png_size(path)
        if width == nil then return nil end
        width = math.min(math.floor(width * SPRITE_SCALE + 0.5), SPRITE_CARD_SIZE)
        height = math.min(math.floor(height * SPRITE_SCALE + 0.5), SPRITE_CARD_SIZE)
        box = forms.pictureBox(w.frm, w._spriteX, w._spriteY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE)
        pcall(forms.clear, box, ENCOUNTER_CARD)
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
-- which is why it has to be hidden rather than just covered. While its
-- panel is folded (w._cardHidden) neither shows.
local function show_sprite(w, box)
    if w._shownSprite == box then return end
    if w._shownSprite then set_style(w._shownSprite, "Visible", false) end
    if box and not w._cardHidden then set_style(box, "Visible", true) end
    set_style(w.lblSpriteCard, "Visible", box == nil and not w._cardHidden)
    w._shownSprite = box
end

-- The getting-started card's sprite: a shiny Mew (data/idle_card.gif, a
-- copy of the card set's own, so it's there before any sprite download).
local function idle_sprite_box(w)
    if w._idleBox ~= nil then return w._idleBox or nil end
    w._idleBox = false
    local path = w._rootDir .. "data/idle_card.gif"
    if not file_exists(path) then return nil end
    local box = forms.pictureBox(w.frm, w._spriteX, w._spriteY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE)
    set_style(box, "BackColor", ENCOUNTER_CARD)
    set_style(box, "SizeMode", "CenterImage")
    set_style(box, "WaitOnLoad", true)
    set_style(box, "ImageLocation", path)
    set_style(box, "Visible", false)
    w._idleBox = box
    return box
end

-- ===== Getting-started text =====
-- Until the first module starts there's nothing to show in Last/Recent
-- Encounters, so they hold a short how-to and the guide link instead.
-- set_idle_help(w, false) puts them back; every function below that writes
-- into those panels does that first, so the how-to can never get mixed in
-- with real encounters.
M.GUIDE_URL = "https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit"

local IDLE_LAST_LINES = {
    "1. Click Open ROM above and pick",
    "    Gold, Silver or Crystal.",
    "2. Select a module above, then click Start.",
    "",
}
-- Seven lines - the link takes the eighth row, right under the last one.
local IDLE_HISTORY_LINES = {
    "Your encounters will show up here - from a module, or while you play.",
}

local function set_idle_help(w, on)
    if w._idleHelp == on then return end
    w._idleHelp = on
    forms.settext(w.lblLastHeader, on and "GETTING STARTED:" or "CURRENT ENCOUNTER:")
    show_sprite(w, on and idle_sprite_box(w) or nil)
    if on then
        forms.settext(w.lblLastSpecies, IDLE_LAST_LINES[1])
        forms.settext(w.lblLastStats, IDLE_LAST_LINES[2])
        forms.settext(w.lblLastItem, IDLE_LAST_LINES[3])
        forms.settext(w.lblLastShiny, IDLE_LAST_LINES[4])
        for i = 1, 7 do
            forms.settext(w.history[i], IDLE_HISTORY_LINES[i] or "")
        end
    end
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
    "chkKillMode", "txtKillFilter", "chkUsePotions",
    "chkThiefMode", "txtThiefFilter", "chkThiefNotify",
    "chkStopPerfect", "chkStopNegative",
    "chkAutoCatch",
    "txtCatchFilter",
    "chkSkipAlreadyCaught",
    "chkStopAutoCatchException", "txtStopAutoCatchException",
    "chkOverrideCritSafety", "txtCustomHpTarget",
    "chkCatchOnItem", "txtCatchItemFilter",
    "chkStopOnShiny",
    "chkCatchOnPerfect", "chkCatchOnPerfectNegative",
    "chkCatchRetry", "txtCatchRetryCount", "chkCatchRetryAlways",
    "chkCatchSendNext", "chkShinySavestate",
}

-- Frame rollback's options that only mean something one way: Tries and
-- "Always retry" only with rollback on (Tries not with "Always retry"
-- either). Rollback and "send out the next Pokemon" rule each other out:
-- rollback already restarts the battle when yours faints. Run when the
-- Auto-Catch popup opens, whenever one of those checkboxes is clicked, and
-- after M.reconfigure() - a field the active module greys out stays grey.
local function update_rollback_controls(w)
    if w.chkCatchRetry == nil then return end
    local moduleOff = {}
    for _, key in ipairs(w._lastDisabledFields or {}) do moduleOff[key] = true end
    local rollback = forms.ischecked(w.chkCatchRetry)
    local always = forms.ischecked(w.chkCatchRetryAlways)
    local sendNext = w.chkCatchSendNext ~= nil and forms.ischecked(w.chkCatchSendNext)
    local function enable(key, on)
        if w[key] then set_style(w[key], "Enabled", on and not moduleOff[key]) end
    end
    -- Both ticked (saved before they ruled each other out): rollback wins,
    -- as in the catch code, and stays clickable.
    enable("chkCatchRetry", rollback or not sendNext)
    enable("chkCatchRetryAlways", rollback)
    enable("lblCatchRetryCount", rollback and not always)
    enable("txtCatchRetryCount", rollback and not always)
    enable("chkCatchSendNext", not rollback)
end

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
    update_rollback_controls(w)
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
    w._savedTreeOverlay = forms.ischecked(w.chkTreeOverlay)
    w._savedDarkMode = forms.ischecked(w.chkDarkMode)
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
    w._savedCatchRetry = forms.ischecked(w.chkCatchRetry)
    w._savedCatchRetryCountText = forms.gettext(w.txtCatchRetryCount)
    w._savedCatchRetryAlways = forms.ischecked(w.chkCatchRetryAlways)
    w._savedCatchSendNext = forms.ischecked(w.chkCatchSendNext)
    w._savedShinySavestate = forms.ischecked(w.chkShinySavestate)
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
        w.chkTreeOverlay = nil
        w.chkDarkMode = nil
        w.chkThiefMode = nil
        w.txtThiefFilter = nil
        w.chkThiefNotify = nil
        w.chkRelaysDisabled = nil
    end)
    local top = 6
    local help = {}
    local y = begin_section(advForm, top, "HELD ITEMS")
    help_button(advForm, help, y, "Stops the bot when a wild Pokemon is holding an item. Put an item's ID or name in the box to stop only for that item, or leave it blank for any item.")
    w.chkStopItem = popup_checkbox(advForm, "Stop on held item:", POPUP_X, y, 150, w._savedStopItemEnabled)
    w.txtItemFilter = popup_textbox(advForm, w._savedItemFilterText, 190, POPUP_X + 155, y - 2)
    top = end_section(advForm, top, y + 20)

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
    help_button(advForm, help, y, "Normally the bot stops weakening once one more hit - a critical hit included - could knock the target out. Tick this to weaken it down to your own HP % instead: riskier, but fewer balls wasted.")
    w.chkOverrideCritSafety = popup_checkbox(advForm, "Override crit-safety - use a custom HP% target instead", POPUP_X, y, 390, w._savedOverrideCritSafety)
    y = y + 24
    w.lblCustomHpTarget = forms.label(advForm, "Custom target HP% (e.g. 40):", POPUP_INDENT_X, y + 2, 200, 16)
    w.txtCustomHpTarget = popup_textbox(advForm, w._savedCustomHpTargetText or "40", 60, POPUP_INDENT_X + 202, y)
    top = end_section(advForm, top, y + 20)

    -- For anyone who'd rather not have the two relays (small local web
    -- listeners) running at all - see M.relays_disabled().
    y = begin_section(advForm, top, "DISCORD RELAYS")
    help_button(advForm, help, y, "The relays are two small helpers that pass the bot's messages on to Discord. They only listen on this PC (127.0.0.1) and only ever send to Discord. Turned off: no notifications and no Rich Presence. Saving stops or starts them right away.")
    w.chkRelaysDisabled = popup_checkbox(advForm, "Don't run the Discord relays", POPUP_X, y, 390, w._savedRelaysDisabled)
    top = end_section(advForm, top, y + 22)

    -- Colored text on the game screen - see data/tree_overlay.lua.
    y = begin_section(advForm, top, "HEADBUTT")
    help_button(advForm, help, y, "Shows on the game screen what the tree in front of you is (rare, common or weak, with its Pokemon) and whether battles where you stand get their DVs pinned. Only while Headbutt is picked.")
    w.chkTreeOverlay = popup_checkbox(advForm, "Show tree overlay on the game screen", POPUP_X, y, 390, w._savedTreeOverlay ~= false)
    top = end_section(advForm, top, y + 22)

    y = begin_section(advForm, top, "WINDOWS")
    help_button(advForm, help, y, "Dark colors for the launcher and all of the bot's windows. Every window takes its colors when it opens, so this switches the next time you start the bot.")
    w.chkDarkMode = popup_checkbox(advForm, "Dark mode (from the next start)", POPUP_X, y, 390, w._savedDarkMode)
    top = end_section(advForm, top, y + 22)

    y = begin_section(advForm, top, "DEBUG")
    -- The log file is always written - this adds the console and the extra
    -- detail (data/debug_log.lua).
    help_button(advForm, help, y, "Shows everything the bot does in BizHawk's Lua Console, plus extra detail. The log in autocrystal/logs/autocrystal_log.txt is kept either way - send it along with a bug report.")
    w.chkVerbose = popup_checkbox(advForm, "Verbose Logging (for debugging)", POPUP_X, y, 390, w._savedVerbose)
    top = end_section(advForm, top, y + 22)

    -- Save reads the controls while they're definitely still alive,
    -- then closes the window itself (forms.destroy() re-enters the
    -- onclose callback above synchronously, but that callback no longer
    -- reads anything - it just nils the handles - so nothing gets
    -- overwritten).
    top = add_help_line(advForm, help, top)
    add_save_button(advForm, top, function()
        save_advanced_settings(w)
        forms.destroy(advForm)
    end)

    w._advancedForm = advForm

    -- These widgets didn't exist the last time M.reconfigure() actually
    -- ran (e.g. egg.lua greying out Kill mode) - re-apply whatever was last requested now
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
        w.chkCatchRetry = nil
        w.txtCatchRetryCount = nil
        w.chkCatchRetryAlways = nil
        w.chkCatchSendNext = nil
        w.chkShinySavestate = nil
    end)
    local top = 6
    local help = {}
    local y = begin_section(acForm, top, "SHINIES")
    help_button(acForm, help, y, "Catches shinies automatically. With IDs or names in the box, only those get caught; any other shiny is skipped - the hunt goes on, and Discord still hears about it.")
    w.chkAutoCatch = popup_checkbox(acForm, "Auto-catch on shiny", POPUP_X, y, 390, w._savedAutoCatchEnabled)
    y = y + 22
    w.lblCatchFilter = forms.label(acForm, "Only auto-catch IDs or names (comma-sep, blank=all):", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 18
    w.txtCatchFilter = popup_textbox(acForm, w._savedCatchFilterText, 320, POPUP_INDENT_X, y)
    y = y + 26

    help_button(acForm, help, y, "Living dex mode: each species is caught only the first time. Remembered across sessions - a shiny of a species you already caught is skipped.")
    w.chkSkipAlreadyCaught = popup_checkbox(acForm, "Only auto-catch a species the FIRST time (living dex mode)", POPUP_X, y, 390, w._savedSkipAlreadyCaught)
    y = y + 24

    help_button(acForm, help, y, "Stops for these shinies instead of catching them - e.g. to keep a rare one for yourself while the bot auto-catches the rest.")
    w.chkStopAutoCatchException = popup_checkbox(acForm, "EXCEPT stop (don't auto-catch) these specific shinies:", POPUP_X, y, 390, w._savedStopAutoCatchException)
    y = y + 22
    w.txtStopAutoCatchException = popup_textbox(acForm, w._savedStopAutoCatchExceptionText, 320, POPUP_INDENT_X, y)
    top = end_section(acForm, top, y + 20)

    y = begin_section(acForm, top, "ALSO CATCH (SHINY OR NOT)")
    help_button(acForm, help, y, "Catches any Pokemon holding this item (its ID or name), whatever the species, shiny or not.")
    w.chkCatchOnItem = popup_checkbox(acForm, "Auto-catch on held item:", POPUP_X, y, 150, w._savedCatchOnItemEnabled)
    w.txtCatchItemFilter = popup_textbox(acForm, w._savedCatchItemFilterText, 190, POPUP_X + 155, y - 2)
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

    -- No setting: the catch code only attacks with a move that can't knock
    -- the target out (data/move_choice.lua) - a crit allowed with frame
    -- rollback on, since that only means a reset.
    help_button(acForm, help, y, "Attacks first with the strongest move that can't knock it out (worked out from both Pokemon); if every move could, it throws straight away. With Frame Rollback on, a crit knocking it out is fine - that only means a reset.")
    forms.label(acForm, "Only attacks with moves that can't knock it out.", POPUP_X, y + 2, 360, 16)
    y = y + 24

    -- The no-rollback alternative: see data/next_pokemon.lua. Greyed out
    -- with rollback on and the other way round (update_rollback_controls()).
    help_button(acForm, help, y, "If your Pokemon faints, the bot sends out the next healthy one and keeps throwing balls, never attacking - never your last healthy one, though (you'd white out). Not with Frame Rollback: that restarts the battle instead.")
    w.chkCatchSendNext = popup_checkbox(acForm, "Send out the next Pokemon if yours faints", POPUP_X, y, 390, w._savedCatchSendNext)
    top = end_section(acForm, top, y + 22)

    y = begin_section(acForm, top, "FRAME ROLLBACK IF CATCH FAILS")
    -- Wild/fishing/headbutt/static: when the target flees, faints or the
    -- catch gets stuck (our own Pokemon down), go back to a snapshot of
    -- the battle menu - shiny on screen, team as it was - and try again,
    -- up to M.catch_retry_attempts() tries; see do_catch_sequence /
    -- static's catch_with_retries. Off = the natural way: it's gone.
    help_button(acForm, help, y, "If it flees or faints, or your own Pokemon faints, the bot goes back to the start of the battle and tries again - as many times as Tries says, or until it's caught with Always retry. Not with Send out the next Pokemon.")
    w.chkCatchRetry = popup_checkbox(acForm, "Roll back to the start of the battle and catch again", POPUP_X, y, 390, w._savedCatchRetry)
    y = y + 24
    w.lblCatchRetryCount = forms.label(acForm, "Tries:", POPUP_INDENT_X, y + 2, 40, 16)
    w.txtCatchRetryCount = popup_textbox(acForm, w._savedCatchRetryCountText or tostring(DEFAULT_CATCH_TRIES), 50, POPUP_INDENT_X + 42, y)
    w.chkCatchRetryAlways = popup_checkbox(acForm, "Always retry (no limit)", POPUP_INDENT_X + 110, y + 1, 250, w._savedCatchRetryAlways)
    y = y + 28

    -- Any module, shiny or not caught: see data/shiny_savestate.lua.
    help_button(acForm, help, y, "In any module, saves a savestate the moment a shiny appears: autocrystal/autosaves/shiny_<name>_<time>.State. Load it with File > Load State > Load Named State.")
    w.chkShinySavestate = popup_checkbox(acForm, "Save a savestate file when a shiny appears", POPUP_X, y, 390, w._savedShinySavestate)
    top = end_section(acForm, top, y + 22)

    top = add_help_line(acForm, help, top)
    add_save_button(acForm, top, function()
        save_autocatch_settings(w)
        forms.destroy(acForm)
    end)

    w._autoCatchForm = acForm

    for _, key in ipairs({"chkCatchRetry", "chkCatchRetryAlways", "chkCatchSendNext"}) do
        pcall(forms.addclick, w[key], function() update_rollback_controls(w) end)
    end
    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    else
        update_rollback_controls(w)
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
    local help = {}
    local y = begin_section(discForm, top, "WEBHOOK")
    -- 2px higher than a checkbox row's, clear of the textbox under it.
    help_button(discForm, help, y - 2, "Where to get one: in Discord, Server Settings (or a channel's Edit Channel) > Integrations > Webhooks > New Webhook, then Copy Webhook URL. Shown as stars - anyone with the URL can post to your channel.")
    forms.label(discForm, "Webhook URL:", POPUP_X, y, 200, 16)
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
    help_button(discForm, help, y, "Sends a Discord message for every shiny and whenever the bot stops. It goes through discord_relay.ps1, which the launcher starts for you.")
    w.chkDiscord = popup_checkbox(discForm, "Send Discord notification (shiny/stop)", POPUP_X, y, 390, w._savedDiscordEnabled)
    -- Not a hint but a warning, so it stays on show.
    if M.relays_disabled(w) then
        y = y + 22
        w.lblDiscordHint = forms.label(discForm, "(the relays are off in Advanced Settings - nothing gets sent)", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
        set_style(w.lblDiscordHint, "ForeColor", M.THEME.accent)
        top = end_section(discForm, top, y + 16)
    else
        top = end_section(discForm, top, y + 22)
    end

    y = begin_section(discForm, top, "PING")
    help_button(discForm, help, y, "Mentions someone with every message. A user: their ID (e.g. 123456789012345678). A role or group: && and its ID (e.g. &&123456789012345678). Right-click the user or role in Discord (Developer Mode on) > Copy ID.")
    w.chkPingUser = popup_checkbox(discForm, "Ping user or role", POPUP_X, y, 150, w._savedPingEnabled)
    w.txtPingId = popup_textbox(discForm, w._savedPingIdText, 190, POPUP_X + 155, y - 2)
    top = end_section(discForm, top, y + 20)

    top = add_help_line(discForm, help, top)
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
    w._savedUsePotions = forms.ischecked(w.chkUsePotions)
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
        w.chkUsePotions = nil
    end)
    local top = 6
    local help = {}
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
    -- Kill mode's move and its matchup check: data/move_choice.lua's
    -- M.kill() (super_effective_threat()).
    help_button(genForm, help, y, "Knocks out non-shiny Pokemon with your best move for it. Only good matchups: if it knows a move super effective against yours (Peck against your Bug Pokemon), or no move can hurt it, the bot runs.")
    w.chkKillMode = popup_checkbox(genForm, "Kill non-shiny (best of its moves)", POPUP_X, y, 390, w._savedKillModeEnabled)
    y = y + 22
    w.lblKillFilter = forms.label(genForm, "Only kill IDs or names (comma-sep, blank=all):", POPUP_INDENT_X, y, POPUP_TEXT_W, 16)
    y = y + 18
    w.txtKillFilter = popup_textbox(genForm, w._savedKillFilterText, 320, POPUP_INDENT_X, y)
    y = y + 26
    -- data/potions.lua, from each battle module's Kill mode block.
    help_button(genForm, help, y, "After a battle, if the Pokemon that fights next is at 25% HP or less, it is healed from the Items pocket: the smallest potion that heals it fully, else the biggest, then more while a whole potion is missing. Never Berries. None left: it runs at low HP.")
    w.chkUsePotions = popup_checkbox(genForm, "Use potions after battles (HP 25% or less)", POPUP_X, y, 390, w._savedUsePotions)
    top = end_section(genForm, top, y + 22)

    top = add_help_line(genForm, help, top)
    add_save_button(genForm, top, function()
        save_general_settings(w)
        forms.destroy(genForm)
    end)

    w._generalForm = genForm

    if w._lastDisabledFields then
        M.reconfigure(w, w._lastDisabledFields)
    end
end

-- ===== Folding panels =====
-- Every main-window panel but the settings buttons folds down to its first
-- row with its -/+ button, remembered as gui_settings.txt's
-- launchercollapsed (all open to start). Every control is made
-- once; folding only moves the panels below and shows or hides things, so
-- it's instant.
local FOLDED_H = 28

local function panel_begin(w, key, y, height, foldable)
    local p = {key = key, top0 = y, height = height, foldable = foldable, items = {}, frames = {}}
    w._panels[#w._panels + 1] = p
    w._building = p
    return p
end

-- A control of the panel being built (its first one is the row that stays
-- when it's folded).
local function track(w, handle, x, y)
    local p = w._building
    p.items[#p.items + 1] = {h = handle, x = x, y = y, dy = y - p.top0}
    if p.title == nil then p.title = handle end
    return handle
end

-- A frame inside the panel (the sprite card's), hidden when it's folded.
local function track_frame(w, lines)
    for _, line in ipairs(lines) do track(w, line.h, line.x, line.y) end
end

local function panel_end(w, p)
    local form, panelX, panelW = w.frm, M.PANEL_X, M.PANEL_W
    p.frameOpen = M.draw_frame(form, panelX, p.top0, panelW, p.height)
    if p.foldable then
        p.frameFolded = M.draw_frame(form, panelX, p.top0, panelW, FOLDED_H)
        local tx, ty = panelX + panelW - 30, p.top0 + 6
        p.toggle = forms.button(form, "-", function() M.toggle_panel(w, p.key) end, tx, ty, 22, 20)
        M.style_button(p.toggle)
        p.items[#p.items + 1] = {h = p.toggle, x = tx, y = ty, dy = ty - p.top0}
    end
    w._building = nil
end

-- Places every panel below the last - open, or folded to its first row -
-- and sizes the window to them. The Current Encounter sprite card is moved
-- too (with every sprite box made so far - see get_sprite_box()).
local function relayout(w)
    local y = w.yOffset
    for _, p in ipairs(w._panels) do
        local open = not (p.foldable and w._folded[p.key])
        for _, item in ipairs(p.items) do
            if item.y ~= y + item.dy then
                item.y = y + item.dy
                forms.setlocation(item.h, item.x, item.y)
            end
            -- own: shown only while it's in use (RECENT SHINIES' sprites).
            if p.foldable and item.h ~= p.title and item.h ~= p.toggle then
                set_style(item.h, "Visible", open and (not item.own or item.shown))
            end
        end
        for _, frame in ipairs({{p.frameOpen, open}, {p.frameFolded or {}, not open}}) do
            for _, line in ipairs(frame[1]) do
                local ly = line.y - p.top0 + y
                if line.at ~= ly then
                    line.at = ly
                    forms.setlocation(line.h, line.x, ly)
                end
                set_style(line.h, "Visible", frame[2])
            end
        end
        if p.toggle then forms.settext(p.toggle, open and "-" or "+") end
        p.top = y
        if p.key == "current" then
            local cardY = y + p.cardDy
            if w._spriteY ~= cardY then
                w._spriteY = cardY
                forms.setlocation(w.lblSpriteCard, w._spriteX, cardY)
                for _, box in pairs(w._spriteBoxes) do forms.setlocation(box, w._spriteX, cardY) end
                if w._idleBox then forms.setlocation(w._idleBox, w._spriteX, cardY) end
            end
            w._cardHidden = not open
            if w._shownSprite then set_style(w._shownSprite, "Visible", open) end
            set_style(w.lblSpriteCard, "Visible", open and w._shownSprite == nil)
        end
        y = y + (open and p.height or FOLDED_H) + PANEL_GAP
    end
    -- The last frame reaches 2px below its panel; the rest is bottom margin
    -- (with the +30 for the title bar, too little here makes the AutoScroll
    -- window show a scrollbar for a pixel or two). Docked,
    -- arrange_windows.ps1 sizes BizHawk to this height.
    w.bottomY = y - PANEL_GAP + 18
    forms.setsize(w.frm, 460, w.bottomY + 30)
end

-- A panel's -/+ button.
function M.toggle_panel(w, key)
    w._folded[key] = not w._folded[key] or nil
    local keys = {}
    for _, p in ipairs(w._panels) do
        if w._folded[p.key] then keys[#keys + 1] = p.key end
    end
    GuiSettings.set("launchercollapsed", table.concat(keys, ","))
    GuiSettings.save()
    relayout(w)
end

-- ===== Recent shinies =====
-- Five rows, newest first, each with the shiny's sprite (M.still_sprite(),
-- 24px) left of its line.
local SHINY_ROWS, SHINY_ROWS_Y, SHINY_ROW_STEP, SHINY_ICON = 5, 30, 26, 24
local SHINY_PANEL_H = SHINY_ROWS_Y + SHINY_ROWS * SHINY_ROW_STEP + 4

-- A row's sprite: made the first time that species lands in that row (a
-- picturebox is only ever drawn once), then just shown and hidden. Joins
-- the panel's items so folding moves and hides it too.
local function shiny_icon(w, row, species)
    w._shinyIcons = w._shinyIcons or {}
    local key = species .. ":" .. row
    local item = w._shinyIcons[key]
    if item then return item end
    local panel
    for _, p in ipairs(w._panels) do if p.key == "shinies" then panel = p end end
    -- A shiny egg is recorded before it hatches, without a species: the egg.
    local path = species == "egg" and (w._rootDir .. "data/sprites/egg_card.png") or M.still_sprite(w._rootDir, species, true)
    if panel == nil or panel.top == nil or not file_exists(path) then return nil end
    local x, dy = M.PANEL_X + 8, SHINY_ROWS_Y + (row - 1) * SHINY_ROW_STEP
    local box = forms.pictureBox(w.frm, x, panel.top + dy, SHINY_ICON, SHINY_ICON)
    pcall(forms.clear, box, M.THEME.card)
    pcall(forms.drawImage, box, path, 0, 0, SHINY_ICON, SHINY_ICON)
    if not M.dark then pcall(forms.drawRectangle, box, 0, 0, SHINY_ICON - 1, SHINY_ICON - 1, M.THEME.border) end
    pcall(forms.refresh, box)
    set_style(box, "Visible", false)
    item = {h = box, x = x, y = panel.top + dy, dy = dy, own = true, shown = false}
    panel.items[#panel.items + 1] = item
    w._shinyIcons[key] = item
    return item
end

local function thousands(n)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Redraws RECENT SHINIES when data/shiny_history.lua has a new one (ticked
-- from launcher.lua's main loop - cheap when nothing changed).
function M.update_recent_shinies(w)
    if w.shinyRows == nil then return end
    if not ShinyHistory.loaded then ShinyHistory.load() end
    if w._shinyVersion == ShinyHistory.version then return end
    w._shinyVersion = ShinyHistory.version
    local entries = ShinyHistory.entries
    for _, item in pairs(w._shinyIcons or {}) do item.shown = false end
    for i = 1, SHINY_ROWS do
        local e = entries[i]
        local icon = e and shiny_icon(w, i, e.species or "egg")
        if icon then icon.shown = true end
    end
    local open = not w._folded.shinies
    for _, item in pairs(w._shinyIcons or {}) do set_style(item.h, "Visible", open and item.shown) end
    for i = 1, SHINY_ROWS do
        local e, text = entries[i], ""
        if e then
            local name = e.species and (PokemonNames[e.species] or ("#" .. e.species)) or "Egg"
            text = string.format("%s   %-10s  after %s encounters", os.date("%d %b %H:%M", e.time), name,
                thousands(e.encounters or 0))
        elseif i == 1 then
            text = "None yet - every shiny you find shows up here."
        end
        forms.settext(w.shinyRows[i], text)
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

    -- Five framed panels, top to bottom - all but the settings buttons
    -- fold (see "Folding panels" above). Each panel's content is created
    -- before its frame - see the theme notes above for why nothing may
    -- overlap; the first row's text stops short of the -/+ button.
    local panelX, panelW = M.PANEL_X, M.PANEL_W
    local x = panelX + 8 -- content inset, clear of M.draw_frame's lines
    local textW = panelW - 16
    local titleW = textW - 30
    local y = yOffset
    local form = existingForm
    widgets._panels = {}
    widgets._folded = {}
    local saved = GuiSettings.get_text("launchercollapsed") or ""
    for key in saved:gmatch("[%a]+") do widgets._folded[key] = true end
    local function label(text, lx, ly, lw)
        return track(widgets, forms.label(form, text, lx, ly, lw, 16), lx, ly)
    end

    -- 1) Running totals + status.
    local p = panel_begin(widgets, "totals", y, 126, true)
    widgets.lblEncounters        = label("TOTAL ENCOUNTERS: 0", x, y + 10, titleW)
    widgets.lblSessionEncounters = label("SESSION ENCOUNTERS: 0", x, y + 28, textW)
    widgets.lblShinies           = label("SHINIES: 0", x, y + 46, textW)
    widgets.lblSinceShiny        = label("SINCE LAST SHINY: -", x, y + 64, textW)
    widgets.lblRuntime           = label("RUNTIME: 00:00:00", x, y + 82, textW)
    widgets.lblStatus            = label("STATUS: Starting...", x, y + 100, textW)
    panel_end(widgets, p)
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
    p = panel_begin(widgets, "current", y, lastPanelH, true)
    p.cardDy = cardY - y
    widgets.lblLastHeader  = label("CURRENT ENCOUNTER:", x, y + 10, lastTextW)
    M.style_header(widgets.lblLastHeader)
    widgets.lblLastSpecies = label("Species: -", x, y + 38, lastTextW)
    widgets.lblLastStats   = label("Atk/Def/Spe/Spc: -", x, y + 64, lastTextW)
    widgets.lblLastItem    = label("Held Item: -", x, y + 90, lastTextW)
    widgets.lblLastShiny   = label("Shiny: -", x, y + 116, lastTextW)
    widgets._spriteX, widgets._spriteY = cardX, cardY
    -- Not tracked: relayout() moves the card with the sprite boxes.
    widgets.lblSpriteCard = filled_label(form, cardX, cardY, SPRITE_CARD_SIZE, SPRITE_CARD_SIZE, ENCOUNTER_CARD)
    -- Same frame as the panels, sized so its black ring hugs the card.
    track_frame(widgets, M.draw_frame(form, cardX - 4, cardY - 4, SPRITE_CARD_SIZE + 8, SPRITE_CARD_SIZE + 8))
    panel_end(widgets, p)
    y = y + lastPanelH + PANEL_GAP

    -- 3) Recent encounters.
    p = panel_begin(widgets, "recent", y, 180, true)
    widgets.lblHistHeader = label("RECENT ENCOUNTERS:", x, y + 10, titleW)
    M.style_header(widgets.lblHistHeader)
    widgets.history = {}
    widgets._historyData = {}
    for i = 1, 8 do
        widgets.history[i] = label("", x, y + 12 + i * 18, textW)
    end
    panel_end(widgets, p)
    y = y + 180 + PANEL_GAP

    -- 4) Recent shinies (data/shiny_history.lua), newest first.
    p = panel_begin(widgets, "shinies", y, SHINY_PANEL_H, true)
    widgets.lblShinyHeader = label("RECENT SHINIES:", x, y + 10, titleW)
    M.style_header(widgets.lblShinyHeader)
    widgets.shinyRows = {}
    for i = 1, SHINY_ROWS do
        widgets.shinyRows[i] = label("", x + SHINY_ICON + 6, y + SHINY_ROWS_Y + (i - 1) * SHINY_ROW_STEP + 4, textW - SHINY_ICON - 6)
    end
    panel_end(widgets, p)
    y = y + SHINY_PANEL_H + PANEL_GAP

    widgets.encounterCount = 0
    widgets.shinyCount = 0
    widgets.encountersSinceShiny = 0
    widgets.sessionEncounterCount = 0
    widgets.status = "Starting..."
    widgets._startTime = os.time()

    -- 5) Settings popups, 2x2. Every setting lives in one of these popup
    -- windows instead of cluttering the main form - built lazily on first
    -- click, not at startup, so they're genuinely hidden until asked for.
    -- Never folds (it's what you need to get anywhere).
    p = panel_begin(widgets, "settings", y, 138, false)
    local buttonW = math.floor((panelW - 16 - 8) / 2)
    local col2 = x + buttonW + 8
    local function button(text, onclick, bx, by, bw)
        local b = forms.button(form, text, onclick, bx, by, bw, 25)
        M.style_button(b)
        return track(widgets, b, bx, by)
    end
    widgets.btnGeneralSettings = button("General Settings", function()
        M.open_general_settings(widgets)
    end, x, y + 10, buttonW)
    widgets.btnAutoCatchSettings = button("Auto-Catch Settings", function()
        M.open_autocatch_settings(widgets)
    end, col2, y + 10, buttonW)
    widgets.btnDiscordSettings = button("Discord Settings", function()
        M.open_discord_settings(widgets)
    end, x, y + 41, buttonW)
    widgets.btnAdvancedSettings = button("Advanced Settings", function()
        M.open_advanced_settings(widgets)
    end, col2, y + 41, buttonW)
    -- The two extra windows, on their own row. Required on click: both
    -- require this file themselves.
    widgets.btnStats = button("Stats", function()
        require("stats_window").open(widgets._rootDir)
    end, x, y + 72, buttonW)
    widgets.btnLiveView = button("Game Assistant", function()
        require("live_view").open(widgets._rootDir)
    end, col2, y + 72, buttonW)
    -- The guide, always there (link-blue, like a link). A button: clicks on a
    -- label never arrived. os.execute is fine from a click callback (only
    -- emu.frameadvance() isn't).
    widgets.btnGuide = button("Open the guide on GitHub", function()
        pcall(os.execute, 'start "" "' .. M.GUIDE_URL .. '"')
    end, x, y + 103, buttonW * 2 + 8)
    set_style(widgets.btnGuide, "ForeColor", M.THEME.link)
    panel_end(widgets, p)

    -- Folds what's remembered folded, and sizes the window (bottomY).
    relayout(widgets)
    M.update_recent_shinies(widgets)

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
    -- Every module shows its encounters through here, so Game Assistant hears
    -- about the ones the bot runs through within a single step too.
    if LiveView and LiveView.note_encounter then
        pcall(LiveView.note_encounter, species, atk, def, spe, spc)
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

function M.use_potions(w)
    if w.chkUsePotions == nil then return w._savedUsePotions or false end
    local enabled = forms.ischecked(w.chkUsePotions)
    w._savedUsePotions = enabled
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
function M.catch_retry_enabled(w)
    if w.chkCatchRetry == nil then return w._savedCatchRetry or false end
    local enabled = forms.ischecked(w.chkCatchRetry)
    w._savedCatchRetry = enabled
    return enabled
end

function M.crit_safety_override_enabled(w)
    if w.chkOverrideCritSafety == nil then return w._savedOverrideCritSafety or false end
    local enabled = forms.ischecked(w.chkOverrideCritSafety)
    w._savedOverrideCritSafety = enabled
    return enabled
end

-- Frame rollback: tries per encounter, the first one included - the Tries
-- box (1-999; DEFAULT_CATCH_TRIES when blank or not a number), or
-- math.huge with "Always retry". Only counts with M.catch_retry_enabled().
function M.catch_retry_attempts(w)
    local always
    if w.chkCatchRetryAlways == nil then
        always = w._savedCatchRetryAlways
    else
        always = forms.ischecked(w.chkCatchRetryAlways)
        w._savedCatchRetryAlways = always
    end
    if always then return math.huge end
    local raw = w._savedCatchRetryCountText
    if w.txtCatchRetryCount ~= nil then
        raw = forms.gettext(w.txtCatchRetryCount)
        w._savedCatchRetryCountText = raw
    end
    local asNumber = tonumber((raw or ""):match("^%s*(%d+)%s*$"))
    if asNumber == nil or asNumber < 1 then return DEFAULT_CATCH_TRIES end
    return math.min(asNumber, 999)
end

function M.catch_send_next_enabled(w)
    if w.chkCatchSendNext == nil then return w._savedCatchSendNext or false end
    local enabled = forms.ischecked(w.chkCatchSendNext)
    w._savedCatchSendNext = enabled
    return enabled
end

function M.shiny_savestate_enabled(w)
    if w.chkShinySavestate == nil then return w._savedShinySavestate or false end
    local enabled = forms.ischecked(w.chkShinySavestate)
    w._savedShinySavestate = enabled
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

-- On unless it was saved off.
function M.tree_overlay_enabled(w)
    if w.chkTreeOverlay == nil then return w._savedTreeOverlay ~= false end
    local enabled = forms.ischecked(w.chkTreeOverlay)
    w._savedTreeOverlay = enabled
    return enabled
end

return M

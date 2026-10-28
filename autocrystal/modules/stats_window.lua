-- stats_window.lua
-- "Encounter Stats" popup, with two tabs:
--   Total   - every species ever encountered, ranked by lifetime
--             encounter count (most encountered = #1), with shinies,
--             shiny rate, Perfect DVs and Perfect Negative DVs.
--   Session - the same per-species breakdown for just this session
--             (since launcher.lua was loaded), plus each species' share
--             of this session's encounters (its encounter rate) and the
--             overall encounters/hour of active hunting.
-- Both have a search box and the species' Crystal sprite on each row.
--
-- Data comes straight from data/stats.lua's in-memory tables (the same
-- ones every module records into), combined across every module. Lifetime
-- numbers live on Stats itself; session numbers on Stats.session, which
-- uses the same table names, so one code path renders either tab.
--
-- LIVE UPDATES: launcher.lua's main loop calls M.tick() every frame; at
-- most once per second it re-reads Stats and updates the open window in
-- place. While a module is mid-sequence (a long battle/catch or a static
-- reset runs its own frame loop inside M.step()), the main loop - and so
-- this - only gets back control once that sequence returns, so updates
-- can lag a few seconds behind during those.
--
-- In-place updates use only operations already proven reliable in this
-- project (see gui_module.lua's and launcher.lua's design notes):
--   * forms.settext on labels (how the main window's live counters work);
--   * one picturebox per sprite, drawn exactly ONCE right after it's
--     created - never redrawn (repeated redraws onto the same picturebox
--     were unreliable). Reordering just MOVES it (forms.setlocation);
--   * no labels inside a picturebox's bounds (they got painted over);
--   * AutoScroll on the form for scrolling.
-- So each species gets one persistent "slot" (sprite + label) the first
-- time it needs to be shown; after that it's only re-texted, moved, or
-- shown/hidden as rankings, search and tabs change.
--
-- Positions: on a scrolled AutoScroll form, WinForms takes a control's
-- Location in VISIBLE (scrolled) coordinates, not content coordinates -
-- placing something at y=168 while scrolled down 500px would land it at
-- content y=668. Every placement here is therefore made relative to the
-- Total tab button's CURRENT Top (it lives at content y=TAB_BUTTON_Y),
-- which tracks the scroll offset exactly.
--
-- Sprites are the regular (non-shiny) local PNGs in
-- data/sprites/normal/<dex>.png, whether or not a species has had a shiny
-- - the Shinies count says that. They don't ship with the bot - the
-- window offers a "Download sprites..." button that runs
-- download_sprites.ps1 (same PokeAPI/jsdelivr source the Discord embeds
-- use); they appear by themselves once downloaded. Any missing sprite
-- just means that row shows text only.

local M = {}

Stats = Stats or require("data.stats")
PokemonNames = PokemonNames or require("data.pokemon_names")
-- PokeGear theme helpers (colors, flat buttons, frames) - same look as
-- the main launcher window.
Gui = Gui or require("gui_module")

local FORM_W = 500
local FORM_H = 660
local ROW_H = 54
local SPRITE_SIZE = 48
local ROWS_TOP = 184
local TAB_BUTTON_Y = 12 -- content y of the Total button = scroll reference
-- Frame around everything above the species rows (tabs, headers, search,
-- status, sprite banner) - gui_module.lua's M.draw_frame(), whose rings
-- reach 2px outside this rect. Everything inside starts at x/y = 12
-- (8 in from the rect, clear of the rings); rows start below it at
-- ROWS_TOP so they never overlap it.
local HEADER_FRAME_X, HEADER_FRAME_Y, HEADER_FRAME_W, HEADER_FRAME_H = 4, 4, 474, 172

local state = {
    form = nil,
    rootDir = nil,
    mode = "total", -- "total" or "session"
    query = "",
    lastTick = nil,
    haveSprites = false,
    controls = {}, -- named fixed controls (header labels, buttons, ...)
    texts = {},    -- control handle -> last text set, to skip no-op settext
    slots = {},    -- species id -> {label, pic, y, visible}
}

-- 1234567 -> "1,234,567"
local function fmt(n)
    local s = tostring(math.floor(n))
    local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (formatted:gsub("^,", ""))
end

-- 3725 -> "1h 02m", 125 -> "2m 05s"
local function fmt_duration(seconds)
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm %02ds", m, seconds % 60)
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function sprite_path(dex)
    return string.format("%sdata/sprites/normal/%d.png", state.rootDir, dex)
end

local function trim(s)
    return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function set_text(handle, text)
    if state.texts[handle] ~= text then
        forms.settext(handle, text)
        state.texts[handle] = text
    end
end

-- Current scroll offset: how far the visible area has moved, as a value
-- to ADD to a content-space y to get the y WinForms expects right now.
local function scroll_offset()
    local top = tonumber(forms.getproperty(state.controls.btnTotal, "Top")) or TAB_BUTTON_Y
    return top - TAB_BUTTON_Y
end

local function place(handle, x, contentY)
    forms.setlocation(handle, x, contentY + scroll_offset())
end

-- Lifetime numbers live directly on Stats; this session's on
-- Stats.session - same field names in both.
local function source_for(mode)
    return mode == "session" and Stats.session or Stats
end

-- Every real species with at least one encounter in the chosen tab,
-- ranked by encounters (ties broken by dex number so the order never
-- shuffles needlessly). Rank is assigned BEFORE search filtering, so
-- searching "pidgey" still shows Pidgey's real rank, not "#1". Also
-- returns the summed species encounters - the denominator for each
-- species' share (encounter rate) on the Session tab.
local function build_ranked_rows(mode)
    local src = source_for(mode)
    local rows, speciesTotal = {}, 0
    for id, count in pairs(src.speciesEncounters) do
        if Stats.is_valid_species(id) and count > 0 then
            speciesTotal = speciesTotal + count
            rows[#rows + 1] = {
                id = id,
                name = PokemonNames[id] or ("#" .. id),
                encounters = count,
                shinies = src.speciesShinies[id] or 0,
                perfect = src.speciesPerfect[id] or 0,
                perfectNeg = src.speciesPerfectNegative[id] or 0,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.encounters ~= b.encounters then return a.encounters > b.encounters end
        return a.id < b.id
    end)
    for i, row in ipairs(rows) do row.rank = i end
    return rows, speciesTotal
end

-- Name substring (case-insensitive), or an exact dex number if the
-- query is purely numeric ("16" -> Pidgey only, not every species with
-- a 16 somewhere in its count).
local function matches(row, query)
    if query == "" then return true end
    local asNumber = tonumber(query)
    if asNumber then return row.id == asNumber end
    return row.name:lower():find(query:lower(), 1, true) ~= nil
end

-- speciesTotal is only passed on the Session tab, where each row also
-- shows its share of the session's encounters.
local function row_text(row, speciesTotal)
    local shinyPart
    if row.shinies > 0 then
        shinyPart = string.format("Shinies: %d (1 in %s)", row.shinies,
            fmt(math.floor(row.encounters / row.shinies + 0.5)))
    else
        shinyPart = "Shinies: 0"
    end
    local encounterPart = "Encounters: " .. fmt(row.encounters)
    if speciesTotal and speciesTotal > 0 then
        encounterPart = string.format("%s (%.1f%%)", encounterPart, row.encounters * 100 / speciesTotal)
    end
    return string.format("%d. %s (#%03d)\r\n%s   %s\r\nPerfect DVs: %d   Perfect Negative: %d",
        row.rank, row.name, row.id, encounterPart, shinyPart, row.perfect, row.perfectNeg)
end

-- Creates a sprite picturebox at content y and draws it exactly once.
-- Returns nil if the file isn't there.
local function create_sprite(dex, contentY)
    local path = sprite_path(dex)
    if not file_exists(path) then return nil end
    local canvas = forms.pictureBox(state.form, 10, contentY + scroll_offset(), SPRITE_SIZE, SPRITE_SIZE)
    pcall(forms.setproperty, canvas, "SizeMode", "StretchImage")
    pcall(forms.drawImage, canvas, path, 0, 0, SPRITE_SIZE, SPRITE_SIZE)
    -- The sprite PNGs have opaque white backgrounds - a thin border makes
    -- that a deliberate card on the cream rather than a white blotch.
    -- Drawn into the picture rather than set as its BorderStyle: that
    -- recreates the picturebox's handle, and every forms.* call on it
    -- after that (this drawImage, showing/hiding it) silently does nothing.
    pcall(forms.drawRectangle, canvas, 0, 0, SPRITE_SIZE - 1, SPRITE_SIZE - 1, Gui.THEME.border)
    pcall(forms.refresh, canvas)
    return canvas
end

local function show(handle, visible)
    if handle then forms.setproperty(handle, "Visible", visible) end
end

-- Gives this species' slot its sprite at content y, the first time only.
-- A sprite file that isn't there yet is simply looked for again next
-- update - so rows fill in by themselves while download_sprites.ps1 is
-- still running.
local function update_slot_sprite(slot, row, contentY)
    if not state.haveSprites or slot.pic then return end
    slot.pic = create_sprite(row.id, contentY)
end

local function update()
    if state.form == nil then return end
    local isSession = (state.mode == "session")
    local c = state.controls

    if not state.haveSprites and file_exists(sprite_path(1)) then
        state.haveSprites = true
        show(c.spriteBanner, false)
        show(c.spriteButton, false)
    end

    local allRows, speciesTotal = build_ranked_rows(state.mode)

    if isSession then
        local rate = Stats.session_encounters_per_hour()
        set_text(c.header1, string.format("This session: %s encounters  |  %d %s  |  %d species",
            fmt(Stats.session.encounters), Stats.session.shinies,
            Stats.session.shinies == 1 and "shiny" or "shinies", #allRows))
        set_text(c.header2, string.format("Active hunting time: %s  |  %s",
            fmt_duration(Stats.session_active_seconds()),
            rate and (fmt(rate) .. " encounters/hour") or "rate: not enough data yet"))
    else
        local totalPerfect, totalPerfectNeg = 0, 0
        for _, row in ipairs(allRows) do
            totalPerfect = totalPerfect + row.perfect
            totalPerfectNeg = totalPerfectNeg + row.perfectNeg
        end
        set_text(c.header1, string.format("Lifetime: %s encounters  |  %d shinies  |  %d species",
            fmt(Stats.totalEncounters), Stats.totalShinies, #allRows))
        set_text(c.header2, string.format("Perfect DVs: %d  |  Perfect Negative DVs: %d",
            totalPerfect, totalPerfectNeg))
    end

    local visible = {}
    for _, row in ipairs(allRows) do
        if matches(row, state.query) then visible[#visible + 1] = row end
    end

    local status
    if #allRows == 0 then
        status = isSession and "No encounters yet this session." or "No encounters recorded yet."
    elseif #visible == 0 then
        status = string.format('No species match "%s".', state.query)
    elseif state.query ~= "" then
        status = string.format('%d of %d species match "%s".', #visible, #allRows, state.query)
    else
        status = string.format("%d species, most encountered first.", #allRows)
    end
    set_text(c.status, status)

    local shownIds = {}
    for i, row in ipairs(visible) do
        local contentY = ROWS_TOP + (i - 1) * ROW_H
        shownIds[row.id] = true
        local slot = state.slots[row.id]
        if slot == nil then
            slot = {
                label = forms.label(state.form, "", 66, contentY + 2 + scroll_offset(), 410, 48, true),
                y = contentY,
                visible = true,
            }
            state.slots[row.id] = slot
        elseif slot.y ~= contentY then
            place(slot.label, 66, contentY + 2)
            if slot.pic then place(slot.pic, 10, contentY) end
            slot.y = contentY
        end
        if not slot.visible then
            show(slot.label, true)
            if slot.pic then show(slot.pic, true) end
            slot.visible = true
        end
        update_slot_sprite(slot, row, contentY)
        set_text(slot.label, row_text(row, isSession and speciesTotal or nil))
    end

    for id, slot in pairs(state.slots) do
        if slot.visible and not shownIds[id] then
            show(slot.label, false)
            if slot.pic then show(slot.pic, false) end
            slot.visible = false
        end
    end
end

-- Runs update() but never lets a problem in this window take the bot
-- down with it (it's called from launcher.lua's main loop).
local warnedUpdateError = false
local function safe_update()
    local ok, err = pcall(update)
    if not ok and not warnedUpdateError then
        warnedUpdateError = true
        print("Encounter Stats window: update failed (" .. tostring(err) .. ") - close and reopen it.")
    end
end

-- The active tab is the disabled button (see build()); it's also tinted
-- the PokeGear's "selected" peach so it reads as the current tab.
local function style_tabs()
    local c = state.controls
    pcall(forms.setproperty, c.btnTotal, "BackColor", state.mode == "total" and Gui.THEME.selected or Gui.THEME.button)
    pcall(forms.setproperty, c.btnSession, "BackColor", state.mode == "session" and Gui.THEME.selected or Gui.THEME.button)
end

local function set_mode(mode)
    if state.form == nil or state.mode == mode then return end
    state.mode = mode
    forms.setproperty(state.controls.btnTotal, "Enabled", mode ~= "total")
    forms.setproperty(state.controls.btnSession, "Enabled", mode ~= "session")
    style_tabs()
    safe_update()
end

local function apply_search()
    if state.form == nil then return end
    state.query = trim(forms.gettext(state.controls.searchBox))
    safe_update()
end

local function start_sprite_download()
    local scriptPath = state.rootDir .. "download_sprites.ps1"
    if not file_exists(scriptPath) then
        set_text(state.controls.spriteBanner, "download_sprites.ps1 is missing from the bot folder.")
        return
    end
    local cmd = string.format('start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', scriptPath)
    local ok = pcall(function() os.execute(cmd) end)
    if ok then
        set_text(state.controls.spriteBanner, "Downloading... sprites show up here by themselves when done.")
    else
        set_text(state.controls.spriteBanner, "Couldn't start download_sprites.ps1 - run it manually.")
    end
end

local function build()
    if not Stats.loaded then Stats.load() end

    local form = forms.newform(FORM_W, FORM_H, "Encounter Stats", function()
        -- Only drop our own handles here - per gui_module.lua's onclose
        -- notes, reading controls during close is unreliable.
        state.form = nil
        state.controls = {}
        state.texts = {}
        state.slots = {}
    end)
    state.form = form
    state.controls = {}
    state.texts = {}
    state.slots = {}
    state.lastTick = nil
    forms.setproperty(form, "AutoScroll", true)
    Gui.style_window(form)
    local c = state.controls

    -- Tabs: BizHawk's forms API has no tab control, so these are two
    -- buttons with the active one disabled (which also shows which tab
    -- you're on).
    c.btnTotal = forms.button(form, "Total", function() set_mode("total") end, 12, TAB_BUTTON_Y, 90, 24)
    c.btnSession = forms.button(form, "Session", function() set_mode("session") end, 107, TAB_BUTTON_Y, 90, 24)
    Gui.style_button(c.btnTotal)
    Gui.style_button(c.btnSession)
    forms.setproperty(state.mode == "session" and c.btnSession or c.btnTotal, "Enabled", false)
    style_tabs()

    c.header1 = forms.label(form, "", 12, 44, 458, 18)
    c.header2 = forms.label(form, "", 12, 64, 458, 18)
    Gui.style_header(c.header1)

    -- Typing filters by itself within a second while the emulator is
    -- running; Search applies it immediately (e.g. while paused).
    forms.label(form, "Search (name or Dex #):", 12, 93, 150, 18)
    -- Default border on purpose: a new BorderStyle recreates the textbox's
    -- handle, and forms.gettext() on the old one then always reads ""
    -- (see gui_module.lua's popup_textbox()).
    c.searchBox = forms.textbox(form, state.query, 150, 20, nil, 162, 90)
    Gui.style_button(forms.button(form, "Search", apply_search, 317, 88, 70, 24))
    Gui.style_button(forms.button(form, "Clear", function()
        if state.form == nil then return end
        forms.settext(c.searchBox, "")
        apply_search()
    end, 392, 88, 70, 24))

    c.status = forms.label(form, "", 12, 119, 450, 18)

    state.haveSprites = file_exists(sprite_path(1))
    -- The animated ones are only for the launcher's Last Encounter card,
    -- but they come from the same download.
    local haveAnimated = file_exists(state.rootDir .. "data/sprites/animated/normal/1.gif")
    if not state.haveSprites or not haveAnimated then
        c.spriteBanner = forms.label(form,
            state.haveSprites and "Animated sprites aren't downloaded yet (one-time, ~500 small files)."
                or "Sprites aren't downloaded yet (one-time, ~1000 small files).",
            12, 145, 300, 18)
        c.spriteButton = forms.button(form, "Download sprites...", start_sprite_download, 317, 142, 145, 24)
        Gui.style_button(c.spriteButton)
    end

    Gui.draw_frame(form, HEADER_FRAME_X, HEADER_FRAME_Y, HEADER_FRAME_W, HEADER_FRAME_H)

    safe_update()
end

-- Entry point for the launcher's "Stats..." button. rootDir is the bot's
-- base folder (launcher.lua's script_dir, trailing separator included).
-- Opening while already open does nothing, same as the settings popups.
-- Reopens on whichever tab/search was last shown.
function M.open(rootDir)
    state.rootDir = rootDir or state.rootDir or "./"
    if state.form ~= nil then return end
    build()
end

-- Called by launcher.lua's main loop every frame. Cheap when the window
-- is closed; otherwise refreshes at most once per second (os.time()
-- granularity), picking up new numbers and anything typed in the search
-- box since the last update.
function M.tick()
    if state.form == nil then return end
    local now = os.time()
    if now == state.lastTick then return end
    state.lastTick = now
    local ok, typed = pcall(forms.gettext, state.controls.searchBox)
    if ok and typed ~= nil then state.query = trim(typed) end
    safe_update()
end

return M

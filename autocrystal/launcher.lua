-- launcher.lua
-- The ONLY script you load into BizHawk's Lua Console. This is the one
-- true persistent window and the one true main loop.
--
-- IMPORTANT: BizHawk does not allow emu.frameadvance() to be called from
-- within a UI callback (confirmed directly from BizHawk's own error:
-- "emu.frameadvance() is not allowed during any callbacks"). Because of
-- this, button click handlers below do NOT do any real work themselves -
-- they only set a flag. All actual logic (loading a module, calling
-- init/step) happens from the main loop at the bottom of this file,
-- which is the one place we know for certain is safe to call
-- emu.frameadvance() and everything that depends on it.
--
-- Folder layout expected:
--   launcher.lua          (this file, base folder)
--   modules/wild.lua, gui_module.lua, (future: fishing.lua, egg.lua, etc.)
--   data/memory.lua, pokemon_names.lua, item_names.lua, wild_stats.txt,
--        launcher_art.png, launcher_art1.png ... launcher_art6.png

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "modules/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

Gui = require("gui_module")
Presence = require("data.presence")
-- logs/ and autosaves/ in this folder - see data/paths.lua. Both made in
-- one go, before anything writes to them (the very first time, that's one
-- mkdir).
local Paths = require("data.paths")
Paths.ensure(Paths.LOG_DIR, Paths.AUTOSAVE_DIR)
local DebugLog = require("data.debug_log")
local TreeOverlay = require("data.tree_overlay")

-- `art` = artwork filename (in data/) to show while this mode is selected
-- in the dropdown. Modules without a confirmed art mapping yet just fall
-- back to the base launcher_art.png.
local MODULES = {
    { name = "Wild", module = "wild", available = true, art = "launcher_art1.png" },
    { name = "Egg", module = "egg", available = true, art = "launcher_art2.png" },
    { name = "Static", module = "static", available = true, art = "launcher_art3.png" },
    { name = "Starters", module = "starters", available = true, art = "launcher_art4.png" },
    { name = "Fishing", module = "fishing", available = true, art = "launcher_art5.png" },
    { name = "Headbutt", module = "headbutt", available = true, art = "launcher_art6.png" },
    { name = "Friendship", module = "friendship", available = true, art = "launcher_art8.png" },
    { name = "Game Corner", module = "gamecorner", available = true, art = "launcher_art9.png" },
}

-- Advanced Settings' dark mode, before anything is built - every control
-- takes its colors when it's made.
GuiSettings.load()
Gui.apply_theme(GuiSettings.get_bool("darkmode") == true)

-- The starting height doesn't matter - forms.setsize gives the window its
-- real height right after the shared HUD is built further down, from where
-- gui_module.lua's panels actually end.
local shell = forms.newform(460, 178, "autocrystal Launcher")
forms.setlocation(shell, 100, 100)
-- PokeGear colors - see gui_module.lua's THEME notes (and why nothing on
-- this window may overlap anything else).
Gui.style_window(shell)

-- Everything from here down to the Stats button sits inside one framed
-- top panel (drawn right after the Stats button), kept separate from
-- gui_module.lua's panels below it. x=14 = content inset inside the frame.
Gui.style_header(forms.label(shell, "Select a module:", 14, 12, 200, 20))

local PLACEHOLDER_TEXT = "-- Select a module --"

local dropdownItems = { PLACEHOLDER_TEXT }
for _, entry in ipairs(MODULES) do
    table.insert(dropdownItems, entry.name)
end
local dropdown = forms.dropdown(shell, dropdownItems, 14, 32, 280, 20)
Gui.style_dropdown(dropdown)

local statusLabel = forms.label(shell, "Idle - click Open ROM, then select a module.", 14, 92, 300, 20)

-- Static target picker - built here, eagerly, at launcher startup,
-- specifically so it EXISTS and is already selectable before the first
-- Start click for static.lua. It used to be created inside static.lua's
-- own M.init(), but that only runs as part of the Start button's click
-- handler itself - by the time it existed, static.lua was already
-- mashing A with whatever the default happened to be, with no chance to
-- pick "Shuckle" first. Global (not local), not module-scoped, so
-- static.lua (a separate required file) can read it directly - same
-- pattern as ActiveModuleName/AutocrystalGlobalStopRequested below.
--
-- Only relevant to the Static module, so it stays hidden (not just
-- greyed out - actually invisible) until "Static" is the selected
-- entry in the module dropdown, same as the live-preview art switching
-- further down toggles per-module state every frame. Starts hidden here
-- since the module dropdown starts on the placeholder text.
-- IMPORTANT: forms.dropdown() SORTS its items alphabetically, so
-- "SelectedIndex" points into the sorted list, not the order written
-- here - index 0 below used to pick "Celebi" (Static), "Odd Egg" (Egg),
-- and the slot defaults landed one too low ("10" sorts right after "1").
-- Pick items by their text instead.
local function select_dropdown_item(handle, text)
    pcall(forms.setproperty, handle, "SelectedItem", text)
end

local staticTargetLabel = forms.label(shell, "Static target:", 14, 114, 90, 16)
forms.setproperty(staticTargetLabel, "Visible", false)
-- Every static target searches frame by frame - see frame_search_step()
-- in modules/static.lua.
StaticTargetDropdown = forms.dropdown(shell, {"Static (open world)", "Sudowoodo", "Eevee", "Shuckle", "Spearow", "Celebi", "Lapras", "Suicune", "Snorlax"}, 109, 112, 160, 20)
Gui.style_dropdown(StaticTargetDropdown)
select_dropdown_item(StaticTargetDropdown, "Static (open world)")
forms.setproperty(StaticTargetDropdown, "Visible", false)

-- Egg source picker - same pattern/reasoning as StaticTargetDropdown right
-- above (built eagerly here so it exists before the first Start click),
-- same screen position (only one of the two is ever visible at a time,
-- since only one module is active). Added specifically to isolate a
-- confirmed-broken read (bogus instant-shiny reports, real repro evidence
-- in hand) on the "Odd Egg" special-delivery NPC from the "Togepi" path,
-- which the user has confirmed is working correctly and must NOT be
-- touched by ongoing Odd Egg debugging - see egg.lua for how the two
-- selections branch to genuinely separate code paths, not just a label.
local eggTargetLabel = forms.label(shell, "Egg source:", 14, 114, 90, 16)
forms.setproperty(eggTargetLabel, "Visible", false)
EggTargetDropdown = forms.dropdown(shell, {"Togepi", "Odd Egg"}, 109, 112, 160, 20)
Gui.style_dropdown(EggTargetDropdown)
select_dropdown_item(EggTargetDropdown, "Togepi")
forms.setproperty(EggTargetDropdown, "Visible", false)

-- Savestate slot picker - lets a tester/user choose which BizHawk
-- savestate slot (1-10) a reset-based module loads/saves to, instead of
-- the old hardcoded-per-module constant (Starters=3, Egg=4, Static=5,
-- Game Corner=6 - see each module's own SAVESTATE_SLOT comment). Those
-- numbers are now just DEFAULTS, kept here in one place instead of
-- scattered across 4 files, and used to pre-select this dropdown the
-- moment a relevant module is chosen. Built eagerly here, same reasoning
-- as StaticTargetDropdown/EggTargetDropdown right above: it needs to
-- exist and be readable before the first Start click, since each
-- module's M.init() reads it once (via AutocrystalGetSavestateSlot()
-- below) to fix the slot for that run.
--
-- Only Wild/Fishing/Headbutt/Friendship don't use a savestate slot at
-- all (they don't reset from a savestate the same way), so this stays
-- hidden for those - see MODULE_DEFAULT_SAVESTATE_SLOT below for exactly
-- which modules it applies to.
MODULE_DEFAULT_SAVESTATE_SLOT = {
    ["Starters"] = 3,
    ["Egg"] = 4,
    ["Static"] = 5,
    ["Game Corner"] = 6,
}
local savestateSlotLabel = forms.label(shell, "Savestate slot:", 14, 138, 90, 16)
forms.setproperty(savestateSlotLabel, "Visible", false)
local savestateSlotItems = {}
for i = 1, 10 do
    table.insert(savestateSlotItems, tostring(i))
end
SavestateSlotDropdown = forms.dropdown(shell, savestateSlotItems, 109, 136, 160, 20)
Gui.style_dropdown(SavestateSlotDropdown)
select_dropdown_item(SavestateSlotDropdown, "1")
forms.setproperty(SavestateSlotDropdown, "Visible", false)

-- Global helper so any module's M.init() can read the chosen slot
-- without needing to know about the dropdown's existence or guard
-- against it being missing/blank. fallbackSlot is that module's own
-- historical default (3/4/5/6) - used if the dropdown somehow can't be
-- read, or (defensively) returns something outside 1-10.
function AutocrystalGetSavestateSlot(fallbackSlot)
    if SavestateSlotDropdown == nil then return fallbackSlot end
    local ok, text = pcall(forms.gettext, SavestateSlotDropdown)
    if not ok or text == nil then return fallbackSlot end
    local n = tonumber(text)
    if n == nil or n < 1 or n > 10 then return fallbackSlot end
    return math.floor(n)
end

-- Where gui_module.lua's panels start: just below this top panel's rect
-- (y=4..168, sized to fit the Savestate slot row at y=136-156), plus the
-- same gap gui_module.lua leaves between its own panels.
local TOP_PANEL_Y, TOP_PANEL_H = 4, 164
local CONTENT_Y_OFFSET = TOP_PANEL_Y + TOP_PANEL_H + Gui.PANEL_GAP

-- Artwork switching: rather than redrawing ONE picturebox with a new
-- image each time the selection changes (repeated draws onto the same
-- picturebox proved unreliable elsewhere in this project - see
-- gui_module.lua's design notes), we create ONE picturebox PER distinct
-- artwork file, draw each exactly once (the "first draw always works"
-- pattern that's been reliable throughout), and just toggle which one
-- is Visible - a simple boolean property, not a repeated draw.
-- 84px (15% under the 99px it was; 94px, and 110px before that), kept
-- centered on the same spot (373, 69) so it still sits in the same place
-- in the top panel.
local ART_X, ART_Y, ART_W, ART_H = 331, 27, 84, 84
local artCanvases = {} -- filename -> picturebox handle
local currentArtFile = nil

local function get_or_create_art_canvas(filename)
    if artCanvases[filename] then return artCanvases[filename] end

    local canvas = forms.pictureBox(shell, ART_X, ART_Y, ART_W, ART_H)

    -- Force the underlying PictureBox control itself to stretch whatever
    -- gets loaded into it to exactly fill ART_W x ART_H, instead of relying
    -- on drawImage's own width/height args to scale correctly. This is a
    -- belt-and-suspenders fix: a source file that's already the "right"
    -- size (like the centered/padded icons this project ships with) and a
    -- raw, unscaled sprite crop someone drops in by hand (e.g. straight
    -- from a pokecrystal front.png frame, native 40-56px depending on
    -- species) both end up displayed at the same fixed size either way,
    -- rather than the small ones appearing tiny in a mostly-empty box.
    pcall(forms.setproperty, canvas, "SizeMode", "StretchImage")
    -- The artwork PNGs are transparent only around the Pokemon (the
    -- Crystal sprites ones made from the animated sprites' first frames),
    -- so they sit on the window's own background, cream or dark.
    pcall(forms.setproperty, canvas, "BackColor", Gui.THEME.background)

    local path = script_dir .. "data/" .. filename
    local ok, err = pcall(forms.drawImage, canvas, path, 0, 0, ART_W, ART_H)
    if not ok then
        print("Couldn't load " .. path .. " (" .. tostring(err) .. ")")
    end
    artCanvases[filename] = canvas
    return canvas
end

local function show_art(filename)
    if filename == currentArtFile then return end
    for existingFile, canvas in pairs(artCanvases) do
        forms.setproperty(canvas, "Visible", existingFile == filename)
    end
    if artCanvases[filename] == nil then
        get_or_create_art_canvas(filename)
        forms.setproperty(artCanvases[filename], "Visible", true)
    end
    currentArtFile = filename
end

-- Per-static-target artwork: while the Static module is selected, swap
-- the icon based on which specific target is picked in StaticTargetDropdown
-- (built above) instead of always showing the Static module's generic art.
-- Eevee already IS the Static module's default art (launcher_art3.png), so
-- only species that need a distinct sprite get an entry here.
local STATIC_TARGET_ART = {
    ["Shuckle"] = "launcher_art_shuckle.png",
    -- "Static (open world)" keeps the Lugia art it's always had - it's
    -- the generic click-to-encounter target (Lugia, Electrode's disguised
    -- Voltorb room, and any future one like them, see static.lua's
    -- BATTLE_TARGET_EXPECTED_SPECIES comment block for the reasoning),
    -- and Lugia remains a reasonable representative icon for that mode.
    ["Static (open world)"] = "launcher_art_lugia.png",
    -- "Sudowoodo" is the separate, explicitly-named target for the
    -- Squirtbottle dialogue flow this module was originally tuned
    -- around - split out from "Static (open world)" specifically so
    -- that generic target could be freed up for true click-to-encounter
    -- targets instead of being implicitly Sudowoodo-shaped.
    ["Sudowoodo"] = "launcher_art_sudowoodo.png",
    ["Celebi"] = "launcher_art_celebi.png",
    ["Lapras"] = "launcher_art_lapras.png",
    ["Suicune"] = "launcher_art_suicune.png",
    -- Shiny Crystal sprites like the rest: the animated sprite's first
    -- frame, trimmed, scaled nearest-neighbour to 92px tall, centered in
    -- 115x100, transparent around the Pokemon.
    ["Spearow"] = "launcher_art_spearow.png",
    ["Snorlax"] = "launcher_art_snorlax.png",
    -- "Eevee" intentionally omitted - no dedicated sprite asset, falls
    -- through to the Static module's own default art below
    -- (launcher_art3.png).
}

-- Cache of filename -> whether data/<filename> exists on disk, so this
-- doesn't hit disk every single frame (art_for_selection is polled in the
-- main loop, same as everything else in this live-preview block).
local artFileExistsCache = {}

local function art_file_exists(filename)
    local cached = artFileExistsCache[filename]
    if cached ~= nil then return cached end
    local f = io.open(script_dir .. "data/" .. filename, "rb")
    local exists = f ~= nil
    if f then f:close() end
    artFileExistsCache[filename] = exists
    return exists
end

-- Picks which art file to show for the current selection. Static gets
-- special-cased: prefer a target-specific sprite when STATIC_TARGET_ART
-- names one AND it actually exists on disk, otherwise fall back to the
-- module's default art - the same fallback every other module already
-- uses, so a missing sprite file just means no icon swap, never a broken
-- picturebox.
local function art_for_selection(selectedEntry, staticTargetText)
    if selectedEntry and selectedEntry.module == "static" then
        local override = STATIC_TARGET_ART[staticTargetText]
        if override and art_file_exists(override) then
            return override
        end
    end
    return (selectedEntry and selectedEntry.art) or "launcher_art.png"
end

-- Pre-load the base artwork immediately so something shows before any
-- selection is made.
show_art("launcher_art.png")

-- Global (not local) so every module's ROM hooks can check "am I
-- actually the active one right now?" - hooks never get unregistered
-- once a module has been used, so without this check, a PREVIOUSLY-used
-- module's stale hooks would keep firing alongside the currently active
-- one's, corrupting its state.
ActiveModuleName = nil

-- Global (not local), optionally set by wild.lua (the only module that
-- currently tracks a real map location via location_name()) so the
-- Discord Rich Presence status line can show it - e.g. "Wild - Route
-- 32" instead of just "Wild". Every other module just leaves this nil,
-- in which case the presence status line below falls back to the
-- module's plain display name.
AutocrystalCurrentLocation = nil

local running = false
local sharedHud = nil
local initializedModules = {} -- module name -> the required module table
local loadedModule = nil
local loadedModuleName = nil
local btnStart, btnStop

-- Tracks which module the savestate-slot dropdown last auto-defaulted
-- for, so that default-setting only fires once on a fresh transition
-- INTO a relevant module - not every single frame - otherwise a user's
-- manual override would get stomped back to the default 60 times a
-- second the instant they picked something else.
local lastSavestateSlotModuleName = nil

-- Flags set by button callbacks (safe: just a variable write), consumed
-- by the main loop (safe: not a callback context).
local startRequestedEntry = nil
local stopRequested = false

-- Global (not local) and distinctively named, deliberately - modules
-- like wild.lua's auto-catch sequence run long, blocking loops entirely
-- within a single M.step() call (throwing up to 20 balls, each with
-- several sub-waits), so the Stop button needs to be pollable directly
-- from inside that code, not just checkable here between M.step() calls
-- once the whole sequence has already finished.
AutocrystalGlobalStopRequested = false

local function on_start()
    local selectedText = forms.gettext(dropdown)
    if selectedText == PLACEHOLDER_TEXT then
        startRequestedEntry = "placeholder"
        return
    end
    for _, entry in ipairs(MODULES) do
        if entry.name == selectedText then
            startRequestedEntry = entry
            break
        end
    end
end

local function on_stop()
    stopRequested = true
    AutocrystalGlobalStopRequested = true
end

-- Every module reads game memory straight away (in init/on_resume, then
-- every step), and with no ROM open BizHawk runs its stand-in "NullHawk"
-- core, which has no memory at all - the first read throws ("NullHawk does
-- not implement memory domains") and takes the whole launcher script down
-- with it. So nothing starts, or keeps running, without a ROM.
local function rom_loaded()
    local ok, system = pcall(emu.getsystemid)
    return ok and system ~= nil and system ~= "NULL"
end
local romClosedWhileRunning = false
local liveViewWarned = false

-- ===== Open ROM =====
-- BizHawk stops and restarts every Lua script whenever a game loads
-- (LuaConsole.Restart), which closes this window and builds it again -
-- unless the script loads the game itself with client.openrom(): then
-- BizHawk keeps it running. So this button picks the ROM (the same file
-- dialog BizHawk's File > Open ROM shows) and loads it, and the launcher
-- stays as it is.
-- Loaded right in the click, not handed to the main loop: that only runs
-- while frames do, so with the emulator paused the ROM sometimes never
-- loaded at all. client.openrom() is fine from a form callback (only input
-- and memory callbacks are refused).
local ROM_FILTER = "Game Boy ROMs (*.gbc;*.gb)|*.gbc;*.gb|All Files (*.*)|*.*"

local function on_open_rom()
    if running then return end
    local okPick, path = pcall(forms.openfile, "", GuiSettings.get_text("romdir") or "", ROM_FILTER)
    if not okPick or type(path) ~= "string" or path == "" then return end
    local ok, err = pcall(client.openrom, path)
    if ok and rom_loaded() then
        forms.settext(statusLabel, "Loaded. Select a module, then click Start.")
        local dir = path:match("^(.*)[/\\]")
        if dir then
            GuiSettings.set("romdir", dir)
            GuiSettings.save()
        end
        DebugLog.note("===== Opened " .. path .. " =====")
    else
        forms.settext(statusLabel, "Couldn't open that ROM.")
        print("Open ROM: " .. tostring(err))
    end
end

btnStart = forms.button(shell, "Start", on_start, 14, 57, 96, 25)
btnStop  = forms.button(shell, "Stop", on_stop, 114, 57, 96, 25)
local btnOpenRom = forms.button(shell, "Open ROM", on_open_rom, 214, 57, 96, 25)
Gui.style_button(btnStart)
Gui.style_button(btnStop)
Gui.style_button(btnOpenRom)
forms.setproperty(btnStop, "Enabled", false)

-- The game changed under the launcher (Open ROM above): every module set up
-- for the old one is set up again on its next Start - addresses, version
-- and memory hooks (each re-registered by name, replacing the old ones).
local lastRomHash = nil
local function forget_modules_on_new_rom()
    local ok, hash = pcall(gameinfo.getromhash)
    hash = ok and hash or ""
    if lastRomHash ~= nil and hash ~= lastRomHash then
        for name in pairs(initializedModules) do
            initializedModules[name] = nil
            package.loaded[name] = nil
        end
        loadedModule, loadedModuleName, ActiveModuleName = nil, nil, nil
    end
    lastRomHash = hash
end

-- Encounter Stats popup (see modules/stats_window.lua) - lifetime
-- per-species encounters/shinies/Perfect DVs, combined across every
-- module - and Game Assistant (modules/live_view.lua), what's going on in the
-- game right now. Their buttons sit with the settings buttons (see
-- gui_module.lua's M.create()); both work any time, before any module has
-- been started too. Ticked from the main loop below.
StatsWindow = require("stats_window")
LiveView = require("live_view")

-- The top panel's frame, around everything above (module picker,
-- Start/Stop, per-module pickers, artwork).
Gui.draw_frame(shell, Gui.PANEL_X, TOP_PANEL_Y, Gui.PANEL_W, TOP_PANEL_H)

-- ===== Shared HUD =====
-- Built right away rather than on the first Start, so the window has its
-- final size from the moment it opens (arrange_windows.ps1, below, sizes
-- BizHawk to match it) and the lifetime totals and settings buttons work
-- before any module runs. Every module shares this ONE Gui.create() (each
-- just enables/disables fields), so sizing once from bottomY - where
-- gui_module.lua's panels actually end - is right for all of them.
sharedHud = Gui.create(shell, CONTENT_Y_OFFSET, nil, script_dir)
-- Its Current/Recent Encounters keep filling while you play yourself.
LiveView.attach(sharedHud)
-- Everything printed goes to logs/autocrystal_log.txt; the Lua Console only
-- shows it with Advanced Settings' Verbose Logging ticked - see
-- data/debug_log.lua.
DebugLog.install(function() return Gui.verbose_logging(sharedHud) end)
forms.setsize(shell, 460, sharedHud.bottomY + 30)
-- A real user report: on their display the bottom of the window was cut
-- off with no way to reach it - Windows can render less than the asked-for
-- height (DPI scaling inflating controls, or a short screen), and a plain
-- forms.newform has no scrollbar to fall back on. AutoScroll adds one only
-- when the content doesn't fit, so it's safe to always enable.
forms.setproperty(shell, "AutoScroll", true)
Stats = Stats or require("data.stats")
if not Stats.loaded then Stats.load() end
Gui.update_counts(sharedHud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, 0, "Idle")

-- ===== Background helpers =====
-- Started once, here - after the window has its final size - so nobody
-- who downloads autocrystal has to run anything else by hand:
--   * discord_presence_relay.ps1 - Discord Rich Presence ("Playing
--     autocrystal" on your profile). Already defaults ClientId to
--     autocrystal's own Discord Application, so it needs no arguments.
--   * discord_relay.ps1 - the shiny/stop notifications, forwarded to the
--     Discord webhook pasted into Discord Settings (it re-reads that for
--     every message, so a new one needs no restart).
--   Both relays are skipped if Advanced Settings says not to run them -
--   and stop, or get started again, the moment that's saved.
--   * set_window_icon.ps1 - this window's icon, and the settings popups'
--     and Encounter Stats' (by title - see OTHER_WINDOW_TITLES) whenever
--     they open. forms.newform() always uses the stock Windows icon and
--     forms.setproperty() can't replace it (it only converts to simple
--     types, not an Icon), but the handle newform() returns IS the
--     window's real Win32 handle, so this sets launcher_art.png on it from
--     outside. It stays running while this window is open (Windows deletes
--     an icon once the process that made it exits) and quits when the
--     window closes.
--   * minimize_lua_console.ps1 - minimizes BizHawk's Lua Console to the
--     taskbar once, so only BizHawk and this window stay on screen (set
--     MINIMIZE_LUA_CONSOLE below to false to keep it open instead).
--   * arrange_windows.ps1 - puts BizHawk and this window side by side at
--     the same height and keeps them docked: drag either one and the other
--     follows, resize BizHawk and this window matches its height (set
--     ARRANGE_WINDOWS below to false to place them yourself, or add
--     -NoDock to its args to only line them up at start). Game Assistant and
--     Encounter Stats dock to the group too while open, found by their
--     titles (their Detach buttons change them). BizHawk's Lua API can read
--     its window position but not move it, hence a helper.
-- The relays get -ExitWhenProcessGone EmuHawk, so they close themselves
-- once BizHawk does instead of lingering hidden, and -LogFile, since a
-- hidden window can't show you anything: their output goes to
-- logs/discord_relay_log.txt and presence_relay_log.txt instead.
-- If one's already running (started by hand, or from before a script
-- reload), the new copy can't take the port and simply exits.
--
-- All launched by ONE os.execute: each call briefly flashes a console
-- window. Deliberately best-effort: pcall-wrapped, and any script that
-- isn't present (deleted to opt out, or an older download) is skipped -
-- none of these may ever block the bot itself. start_relay.bat /
-- start_presence_relay.bat stay as manual fallbacks (with visible
-- windows, handy for seeing what went wrong).
local MINIMIZE_LUA_CONSOLE = true
local ARRANGE_WINDOWS = true
-- The bot's other windows' titles, exactly as gui_module.lua's popups and
-- stats_window.lua name them - these get the launcher's icon too.
local OTHER_WINDOW_TITLES = {
    "General Settings", "Auto-Catch Settings", "Discord Settings", "Advanced Settings", "Encounter Stats",
    "Game Assistant",
}

local function relay_args(logName)
    return string.format('-ExitWhenProcessGone EmuHawk -LogFile "%s"', Paths.log_path(logName))
end
local function window_args()
    return string.format("-Hwnd %d", shell)
end
local RELAY_HELPERS = {
    {file = "discord_presence_relay.ps1", args = relay_args("presence_relay_log.txt"), name = "Discord Rich Presence relay"},
    {file = "discord_relay.ps1", args = relay_args("discord_relay_log.txt"), name = "Discord notification relay"},
}

-- Starts the given helpers (see above), all with one os.execute.
local function start_helpers(helpers)
    local commands, started = {}, {}
    for _, helper in ipairs(helpers) do
        local path = script_dir .. helper.file
        local f = io.open(path, "r")
        if f then
            f:close()
            local args = type(helper.args) == "function" and helper.args() or helper.args
            table.insert(commands, string.format(
                'start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s" %s',
                path, args))
            if helper.name then table.insert(started, helper.name) end
        end
    end
    if #commands > 0 then
        local ok = pcall(function() os.execute(table.concat(commands, " & ")) end)
        if ok and #started > 0 then
            print("Started in the background: " .. table.concat(started, ", ") .. ".")
        elseif not ok then
            print("Couldn't start the Discord relays - run start_presence_relay.bat / start_relay.bat by hand if you want them.")
        end
    end
end

do
    local helpers = {}
    if Gui.relays_disabled(sharedHud) then
        print("Discord relays are turned off in Advanced Settings - not starting them.")
    else
        for _, relay in ipairs(RELAY_HELPERS) do table.insert(helpers, relay) end
    end
    table.insert(helpers, {file = "set_window_icon.ps1", args = function()
        return string.format('-Hwnd %d -ImagePath "%s" -AlsoTitles "%s"', shell,
            script_dir .. "data/launcher_art.png", table.concat(OTHER_WINDOW_TITLES, ";"))
    end})
    if MINIMIZE_LUA_CONSOLE then
        table.insert(helpers, {file = "minimize_lua_console.ps1", args = window_args})
    end
    if ARRANGE_WINDOWS then
        table.insert(helpers, {file = "arrange_windows.ps1", args = window_args})
    end
    -- Card sprites made at an older size (or missing) get remade now,
    -- before any is on screen - BizHawk keeps a shown GIF open.
    if Gui.card_sprites_need_rescale(script_dir) then
        table.insert(helpers, {file = "tools/scale_sprites.ps1", args = ""})
    end
    start_helpers(helpers)
end

-- Advanced Settings' Save just switched the relays back on - start them.
-- (Switching them off needs nothing here: both watch the settings file and
-- quit by themselves within a couple of seconds.) Runs from that Save
-- button's click callback, which is fine for os.execute.
Gui.on_relays_toggled = function(disabled)
    if not disabled then start_helpers(RELAY_HELPERS) end
end

-- For the debug log's Start line: the module plus whatever its pickers in
-- this window are set to.
local function start_description(entry)
    local parts = {entry.name}
    if entry.name == "Static" then
        table.insert(parts, "target " .. tostring(forms.gettext(StaticTargetDropdown)))
    elseif entry.name == "Egg" then
        table.insert(parts, "source " .. tostring(forms.gettext(EggTargetDropdown)))
    end
    if MODULE_DEFAULT_SAVESTATE_SLOT[entry.name] ~= nil then
        table.insert(parts, "slot " .. tostring(forms.gettext(SavestateSlotDropdown)))
    end
    return table.concat(parts, ", ")
end

while true do
    emu.frameadvance()

    -- Live-preview the artwork for whatever's currently selected in the
    -- dropdown, even before Start is clicked. Polled each frame - cheap,
    -- and matches the safe "check in the main loop" pattern used
    -- throughout this file.
    do
        local selectedText = forms.gettext(dropdown)
        local selectedEntry = nil
        for _, entry in ipairs(MODULES) do
            if entry.name == selectedText then
                selectedEntry = entry
                break
            end
        end

        local staticTargetText = forms.gettext(StaticTargetDropdown)
        show_art(art_for_selection(selectedEntry, staticTargetText))

        -- Headbutt's tree overlay (Advanced Settings) - drawn every frame by
        -- its own frame-end callback, so it keeps showing while a module's
        -- step runs; see data/tree_overlay.lua. Never allowed to stop the bot.
        pcall(TreeOverlay.set_wanted,
            selectedText == "Headbutt" and Gui.tree_overlay_enabled(sharedHud) and rom_loaded())

        -- Static target picker only makes sense for the Static module -
        -- show it the instant "Static" is picked in the dropdown above
        -- (well before Start is clicked), hide it otherwise.
        local staticSelected = (selectedText == "Static")
        forms.setproperty(StaticTargetDropdown, "Visible", staticSelected)
        forms.setproperty(staticTargetLabel, "Visible", staticSelected)

        -- Egg source picker - same visibility pattern, shown only while
        -- the Egg module is selected.
        local eggSelected = (selectedText == "Egg")
        forms.setproperty(EggTargetDropdown, "Visible", eggSelected)
        forms.setproperty(eggTargetLabel, "Visible", eggSelected)

        -- Savestate slot picker - shown only for modules that actually
        -- use a savestate slot (see MODULE_DEFAULT_SAVESTATE_SLOT
        -- above). Auto-selects that module's historical default the
        -- instant the user switches INTO it (tracked via
        -- lastSavestateSlotModuleName so it only happens once per
        -- transition, not every frame - letting the user freely change
        -- it afterwards without it snapping back).
        local savestateSlotDefault = MODULE_DEFAULT_SAVESTATE_SLOT[selectedText]
        local savestateSlotRelevant = savestateSlotDefault ~= nil
        forms.setproperty(SavestateSlotDropdown, "Visible", savestateSlotRelevant)
        forms.setproperty(savestateSlotLabel, "Visible", savestateSlotRelevant)
        if savestateSlotRelevant and lastSavestateSlotModuleName ~= selectedText then
            select_dropdown_item(SavestateSlotDropdown, tostring(savestateSlotDefault))
        end
        lastSavestateSlotModuleName = selectedText
    end

    if not running then forget_modules_on_new_rom() end

    if startRequestedEntry ~= nil then
        local chosen = startRequestedEntry
        startRequestedEntry = nil

        if chosen == "placeholder" then
            forms.settext(statusLabel, "Please select a module first.")
        elseif not chosen.available then
            forms.settext(statusLabel, chosen.name .. " isn't built yet.")
        elseif not rom_loaded() then
            forms.settext(statusLabel, "Open a supported ROM first (Open ROM).")
        else
            DebugLog.on_start(start_description(chosen))
            if initializedModules[chosen.module] == nil then
                local mod = DebugLog.call("require " .. chosen.module, require, chosen.module)

                -- sharedHud already exists - it's built at startup, see
                -- "Shared HUD" above the main loop.
                local ok = DebugLog.call(chosen.module .. ".init", mod.init, shell, CONTENT_Y_OFFSET, sharedHud)
                if ok == false then
                    -- Every module's init returns false for a game it
                    -- doesn't recognize (not Gold/Silver/Crystal, or an
                    -- unsupported region) and prints why in the console.
                    forms.settext(statusLabel, "Unsupported ROM - see autocrystal/logs/autocrystal_log.txt.")
                else
                    initializedModules[chosen.module] = mod
                end
            end

            local mod = initializedModules[chosen.module]
            if mod ~= nil then
                loadedModule = mod
                loadedModuleName = chosen.module
                ActiveModuleName = chosen.module
                -- Clear any location text left over from a previous
                -- module - every module sets this itself on its own
                -- first M.step(), so this just avoids showing a stale
                -- route from whatever module ran before, for the one
                -- frame or two before the newly-active module's own
                -- first update lands.
                AutocrystalCurrentLocation = nil

                -- Every time a module becomes active - whether for the
                -- first time or returning to one already used before -
                -- let it reconfigure which settings apply and clear out
                -- stale data from whatever was previously showing.
                if mod.on_switch_to then
                    DebugLog.call(chosen.module .. ".on_switch_to", mod.on_switch_to)
                end
                if mod.on_resume then
                    AutocrystalGlobalStopRequested = false
                    DebugLog.call(chosen.module .. ".on_resume", mod.on_resume)
                end

                running = true
                forms.setproperty(dropdown, "Enabled", false)
                -- Lock the savestate slot picker for the duration of the
                -- run too - added after a real user data-loss incident
                -- where a slot got overwritten with the dropdown showing
                -- an unexpected value. The auto-backup fix already
                -- protects against that specific scenario, but locking
                -- this out entirely while running removes the
                -- possibility altogether: there's no legitimate reason to
                -- change the target slot mid-hunt, and doing so while
                -- SAVESTATE_SLOT is actively being read/written every
                -- reset cycle could only cause confusion.
                forms.setproperty(SavestateSlotDropdown, "Enabled", false)
                forms.setproperty(btnStart, "Enabled", false)
                forms.setproperty(btnOpenRom, "Enabled", false)
                forms.setproperty(btnStop, "Enabled", true)
                forms.settext(statusLabel, "Running: " .. chosen.name)
            end
        end
    end

    -- ROM closed (File > Close ROM) while a module runs - stop exactly as
    -- if Stop had been pressed, before its next step's memory read throws.
    if running and not rom_loaded() then
        stopRequested = true
        romClosedWhileRunning = true
    end

    if stopRequested then
        stopRequested = false
        AutocrystalGlobalStopRequested = false
        running = false
        forms.setproperty(dropdown, "Enabled", true)
        forms.setproperty(SavestateSlotDropdown, "Enabled", true)
        forms.setproperty(btnStart, "Enabled", true)
        forms.setproperty(btnOpenRom, "Enabled", true)
        forms.setproperty(btnStop, "Enabled", false)
        forms.settext(statusLabel, romClosedWhileRunning and "Stopped - the ROM was closed." or "Stopped. Pick a module and click Start.")
        DebugLog.note(romClosedWhileRunning and "===== Stopped: the ROM was closed =====" or "===== Stopped with the Stop button =====")
        romClosedWhileRunning = false
    end

    if running and loadedModule ~= nil then
        local done = DebugLog.call(loadedModuleName .. ".step", loadedModule.step)

        -- Discord Rich Presence: one call, here, covers every module -
        -- see data/presence.lua for why no per-module wiring is needed
        -- beyond this. AutocrystalCurrentLocation is only ever set by
        -- wild.lua/static.lua; every other module shows just its own
        -- display name.
        do
            local displayName = loadedModuleName
            for _, entry in ipairs(MODULES) do
                if entry.module == loadedModuleName then
                    displayName = entry.name
                    break
                end
            end

            -- Static gets one extra bit of detail: what it's hunting, so the
            -- presence line reads "Static (Shuckle)" instead of just
            -- "Static". For "Static (open world)" (the literal dropdown text
            -- would be redundant next to the module name) that's the species
            -- frame search found rolling there (AutocrystalHuntedSpecies,
            -- set by modules/static.lua) - plain "Static" until the first roll.
            if loadedModuleName == "static" and StaticTargetDropdown then
                local hunted = forms.gettext(StaticTargetDropdown)
                if hunted == "Static (open world)" then hunted = AutocrystalHuntedSpecies end
                if hunted then
                    displayName = displayName .. " (" .. hunted .. ")"
                end
            end

            local stateLabel = displayName
            if AutocrystalCurrentLocation ~= nil then
                stateLabel = displayName .. " - " .. AutocrystalCurrentLocation
            end
            Presence.tick(stateLabel)
        end

        if done then
            running = false
            forms.setproperty(dropdown, "Enabled", true)
            forms.setproperty(SavestateSlotDropdown, "Enabled", true)
            forms.setproperty(btnStart, "Enabled", true)
            forms.setproperty(btnOpenRom, "Enabled", true)
            forms.setproperty(btnStop, "Enabled", false)
            forms.settext(statusLabel, "Finished. Pick a module and click Start.")
            DebugLog.note("===== Finished: the module stopped by itself =====")
        end
    end

    -- Live-updates the Encounter Stats window if it's open (no-op when
    -- closed; at most one real update per second - see
    -- stats_window.lua's M.tick()). Outside the `running` block so it
    -- keeps updating its search filter even while no module is running.
    StatsWindow.tick()
    -- RECENT SHINIES, redrawn once a module records a new one.
    pcall(Gui.update_recent_shinies, sharedHud)
    -- Keeps reading the game (for its recent list) even while closed; never
    -- allowed to stop the bot.
    local okLive, liveErr = pcall(LiveView.tick, rom_loaded(), running)
    if not okLive and not liveViewWarned then
        liveViewWarned = true
        print("Game Assistant: " .. tostring(liveErr))
    end
end

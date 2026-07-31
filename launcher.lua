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

-- ===== Discord Rich Presence: auto-launch the relay =====
-- Runs once, right here, the moment this script loads - so nobody who
-- downloads autocrystal has to manually run a second script or fill in
-- any Discord config themselves (see discord_presence_setup.md). It
-- just spawns discord_presence_relay.ps1 detached and hidden; that
-- script already defaults ClientId to autocrystal's own Discord
-- Application, so it works with zero arguments.
--
-- Deliberately best-effort: wrapped in pcall, and skipped entirely if
-- the relay script isn't even present (e.g. someone deleted it to opt
-- out, or an older download without it) - Rich Presence is a nice-to-
-- have that should never be able to block the bot itself from running.
-- If auto-launch ever fails for some reason, start_presence_relay.bat
-- is still there as a manual fallback (and shows a visible window,
-- useful for debugging what went wrong).
do
    local relayScriptPath = script_dir .. "discord_presence_relay.ps1"
    local relayFile = io.open(relayScriptPath, "r")
    if relayFile then
        relayFile:close()
        local launchCmd = string.format(
            'start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s"',
            relayScriptPath)
        local ok = pcall(function() os.execute(launchCmd) end)
        if ok then
            print("Discord Rich Presence relay launched in the background.")
        else
            print("Couldn't auto-launch the Discord Rich Presence relay - run start_presence_relay.bat manually if you want it.")
        end
    end
end

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

-- Height here only needs to fit the dropdown/buttons/status/artwork
-- shown before any module is picked - forms.setsize grows this once a
-- module actually starts and Gui.create()'s real content exists (see
-- below), rather than guessing the final size upfront.
local shell = forms.newform(460, 260, "autocrystal Launcher")
forms.setlocation(shell, 100, 100)

forms.label(shell, "Select a module:", 10, 10, 200, 20)

local PLACEHOLDER_TEXT = "-- Select a module --"

local dropdownItems = { PLACEHOLDER_TEXT }
for _, entry in ipairs(MODULES) do
    table.insert(dropdownItems, entry.name)
end
local dropdown = forms.dropdown(shell, dropdownItems, 10, 30, 280, 20)

local statusLabel = forms.label(shell, "Idle - pick a module and click Start.", 10, 90, 300, 20)

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
local staticTargetLabel = forms.label(shell, "Static target:", 10, 112, 90, 16)
forms.setproperty(staticTargetLabel, "Visible", false)
StaticTargetDropdown = forms.dropdown(shell, {"Static (open world)", "Eevee", "Shuckle", "Spearow"}, 105, 110, 160, 20)
forms.setproperty(StaticTargetDropdown, "SelectedIndex", 0)
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
local eggTargetLabel = forms.label(shell, "Egg source:", 10, 112, 90, 16)
forms.setproperty(eggTargetLabel, "Visible", false)
EggTargetDropdown = forms.dropdown(shell, {"Togepi", "Odd Egg"}, 105, 110, 160, 20)
forms.setproperty(EggTargetDropdown, "SelectedIndex", 0)
forms.setproperty(EggTargetDropdown, "Visible", false)

-- Bumped 130 -> 140 so the shared Gui content (TOTAL ENCOUNTERS, etc.)
-- doesn't crowd/overlap the Static target row right above it at y=110-130.
local CONTENT_Y_OFFSET = 140

-- Artwork switching: rather than redrawing ONE picturebox with a new
-- image each time the selection changes (repeated draws onto the same
-- picturebox proved unreliable elsewhere in this project - see
-- gui_module.lua's design notes), we create ONE picturebox PER distinct
-- artwork file, draw each exactly once (the "first draw always works"
-- pattern that's been reliable throughout), and just toggle which one
-- is Visible - a simple boolean property, not a repeated draw.
local ART_X, ART_Y, ART_W, ART_H = 335, 10, 110, 110
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
    ["Static (open world)"] = "launcher_art_lugia.png",
    -- "Eevee" intentionally omitted - falls through to the Static module's
    -- own default art below (launcher_art3.png).
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

btnStart = forms.button(shell, "Start", on_start, 10, 55, 100, 25)
btnStop  = forms.button(shell, "Stop", on_stop, 120, 55, 100, 25)
forms.setproperty(btnStop, "Enabled", false)

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
    end

    if startRequestedEntry ~= nil then
        local chosen = startRequestedEntry
        startRequestedEntry = nil

        if chosen == "placeholder" then
            forms.settext(statusLabel, "Please select a module first.")
        elseif not chosen.available then
            forms.settext(statusLabel, chosen.name .. " isn't built yet.")
        else
            if initializedModules[chosen.module] == nil then
                local mod = require(chosen.module)

                if sharedHud == nil then
                    sharedHud = Gui.create(shell, CONTENT_Y_OFFSET)
                    -- The shell's height was a fixed guess (1020) sized
                    -- for the old, longer inline layout. Every module
                    -- shares this ONE Gui.create() call (just enables/
                    -- disables fields per module - it doesn't add more
                    -- widgets), so resizing once here based on
                    -- bottomY (where gui_module.lua's own widgets
                    -- actually end) is correct for every module, not
                    -- just Wild - and stays correct automatically if
                    -- that layout changes again later.
                    forms.setsize(shell, 460, sharedHud.bottomY + 30)
                end

                local ok = mod.init(shell, CONTENT_Y_OFFSET, sharedHud)
                if ok == false then
                    forms.settext(statusLabel, "Failed to initialize " .. chosen.name .. " - check the Lua console.")
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
                    mod.on_switch_to()
                end
                if mod.on_resume then
                    AutocrystalGlobalStopRequested = false
                    mod.on_resume()
                end

                running = true
                forms.setproperty(dropdown, "Enabled", false)
                forms.setproperty(btnStart, "Enabled", false)
                forms.setproperty(btnStop, "Enabled", true)
                forms.settext(statusLabel, "Running: " .. chosen.name)
            end
        end
    end

    if stopRequested then
        stopRequested = false
        AutocrystalGlobalStopRequested = false
        running = false
        forms.setproperty(dropdown, "Enabled", true)
        forms.setproperty(btnStart, "Enabled", true)
        forms.setproperty(btnStop, "Enabled", false)
        forms.settext(statusLabel, "Stopped. Pick a module and click Start.")
    end

    if running and loadedModule ~= nil then
        local done = loadedModule.step()

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

            -- Static gets one extra bit of detail: which specific target
            -- is selected (Shuckle/Eevee), so the presence line reads
            -- "Static (Shuckle)" instead of just "Static" for those -
            -- but "Static (open world)" (the literal dropdown text) is
            -- deliberately NOT shown here, since that's redundant/awkward
            -- next to the module name itself; plain "Static" covers it.
            if loadedModuleName == "static" and StaticTargetDropdown then
                local targetText = forms.gettext(StaticTargetDropdown)
                if targetText == "Shuckle" or targetText == "Eevee" or targetText == "Spearow" then
                    displayName = displayName .. " (" .. targetText .. ")"
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
            forms.setproperty(btnStart, "Enabled", true)
            forms.setproperty(btnStop, "Enabled", false)
            forms.settext(statusLabel, "Finished. Pick a module and click Start.")
        end
    end
end

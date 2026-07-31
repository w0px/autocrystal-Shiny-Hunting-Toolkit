-- presence.lua (lives in data/)
-- Feeds Discord Rich Presence (the "Playing autocrystal" card on your
-- profile) with live stats. This is completely separate from the
-- existing webhook notification system (send_discord_embed/discord_relay.
-- ps1 in the other modules, which post messages into a channel) - Rich
-- Presence instead talks to your own local Discord client over its IPC
-- named pipe, which BizHawk's Lua sandbox can't do directly. So this
-- module just builds a small JSON summary and POSTs it (via the same
-- comm.httpPost used everywhere else) to a SECOND local relay -
-- discord_presence_relay.ps1 - which is the piece that actually speaks
-- to Discord. Run that relay alongside discord_relay.ps1 for both
-- systems to work at once.
--
-- Deliberately requires almost no per-module wiring: Stats
-- (data/stats.lua) is already shared/global across every hunting module,
-- so totalEncounters/totalShinies/lastShinySpeciesId are read straight
-- from there. The only external hook is launcher.lua calling
-- Presence.tick(stateLabel) once per frame while a module is running -
-- see launcher.lua for that one-line integration.

local M = {}

-- Deliberately does NOT touch package.path itself (unlike the hunting
-- modules) - this file only ever gets loaded via require() from a
-- module that already configured package.path for its own location
-- (launcher.lua, or one of the hunting modules), and since package.path
-- is one shared global, those existing entries already resolve both
-- "data.stats" (modules/data/stats.lua) and "data.pokemon_names"
-- (the top-level data/pokemon_names.lua) correctly. Adding another
-- rewrite here would only risk fighting with whichever one ran first.
Stats = Stats or require("data.stats")
PokemonNames = PokemonNames or require("data.pokemon_names")

-- ===== Config =====
-- Only the relay's own address lives here - Discord-specific config
-- (Client ID, button label/URL, fallback image) all lives in
-- discord_presence_relay.ps1 itself, same split as the existing webhook
-- system (Lua only ever knows about a local HTTP address, never
-- Discord's actual endpoints/credentials).
local PRESENCE_RELAY_URL = "http://127.0.0.1:5001/"

-- Don't hammer Discord's IPC - it rate-limits SET_ACTIVITY updates.
-- Everything still updates on-screen (the GUI) in real time; this only
-- throttles how often the Rich Presence card itself refreshes.
local MIN_SEND_INTERVAL_SECONDS = 15

-- Game/region identity, read from the ROM header - like the reference
-- bot's "LeafGreen (E)" - so the card shows Gold/Silver/Crystal (plus a
-- region letter) alongside whatever location/mode text the caller
-- passes in. 0x141 is this project's "version" byte (which cartridge),
-- 0x142 is the last byte of the internal title, which Pokémon ROMs use
-- as a region letter. Values cross-checked against pret/pokegold's and
-- pret/pokecrystal's actual `rgbfix -i` build flags (Crystal='T'/0x54
-- was already known-correct in this project; Gold='U'/0x55 and
-- Silver='X'/0x58 were verified against those same Makefiles).
local GAME_VERSION_NAMES = {
    [0x54] = "Crystal",
    [0x55] = "Gold",
    [0x58] = "Silver",
}
local REGION_LETTERS = {
    [0x45] = "E", [0x4A] = "J", [0x44] = "D",
    [0x46] = "F", [0x49] = "I", [0x53] = "S", [0x4B] = "K",
}

-- Read lazily (on first tick) and memoized rather than at module-load
-- time, since a ROM may not be loaded into BizHawk yet the instant this
-- module gets require()'d.
local gameVersionLabel = nil
local function get_game_version_label()
    if gameVersionLabel then return gameVersionLabel end
    local ok, versionByte = pcall(memory.readbyte, 0x141)
    if not ok then return "Pokémon" end
    local ok2, regionByte = pcall(memory.readbyte, 0x142)
    local name = GAME_VERSION_NAMES[versionByte] or "Pokémon"
    if ok2 and REGION_LETTERS[regionByte] then
        name = name .. " (" .. REGION_LETTERS[regionByte] .. ")"
    end
    gameVersionLabel = name
    return gameVersionLabel
end

-- NOTE: deliberately no per-user dynamic "last shiny" image (no
-- shiny_sprite_url() here) - that would need discord_presence_relay.ps1
-- to carry this application's Client Secret in every copy anyone
-- downloads, which would leak it. The relay always shows one fixed
-- image instead; this module still sends image_text below so the
-- tooltip over that fixed image varies per user even though the image
-- itself doesn't.

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function json_escape(value)
    local str = tostring(value)
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    str = str:gsub('\n', '\\n')
    str = str:gsub('\r', '\\r')
    str = str:gsub('\t', '\\t')
    return str
end

-- Adds thousands separators (e.g. 197638 -> "197,638") - purely cosmetic,
-- matching the reference card's formatting.
local function with_commas(n)
    local s = tostring(math.floor(n))
    local sign = ""
    if s:sub(1, 1) == "-" then
        sign = "-"
        s = s:sub(2)
    end
    local reversed = s:reverse()
    local withCommas = reversed:gsub("(%d%d%d)", "%1,")
    withCommas = withCommas:reverse()
    if withCommas:sub(1, 1) == "," then
        withCommas = withCommas:sub(2)
    end
    return sign .. withCommas
end

-- Session-lifetime state: captured lazily, on the FIRST real M.tick()
-- call, rather than the instant this module is require()'d.
--
-- require() happens the moment launcher.lua loads, at the very top of
-- the file - well before Stats.load() has ever run (that only happens
-- inside a hunting module's own M.init(), which fires once you actually
-- click Start). So at require() time, Stats.totalEncounters/totalShinies
-- are still their fresh-require defaults of 0, not the real persisted
-- lifetime totals from wild_stats.txt. Capturing encountersAtSessionStart
-- (and lastSeenShinyCount below) against that stale 0 baseline meant the
-- very first real stats update - the moment Stats.load() populated the
-- real totals - looked like the bot's ENTIRE lifetime encounter count
-- had just happened in the last couple of real-world seconds, producing
-- an absurdly huge rate/hour that only slowly crept back down toward
-- reality as elapsed time grew. That's the "starts at a crazy high
-- number, then goes down" bug reported. Deferring the whole snapshot to
-- the first M.tick() call (which never fires until AFTER the active
-- module's M.init()/Stats.load() has already run - see launcher.lua's
-- main loop) fixes both the encounters count AND the elapsed-time clock
-- at once, since it's the same lazy snapshot.
local sessionStartTime = nil
local encountersAtSessionStart = nil
-- Declared here (rather than down by lastSendTime, where it logically
-- groups with the send-throttling state) so ensure_session_baseline can
-- assign it below without accidentally creating a stray global - Lua
-- locals aren't visible until after their own declaration line.
local lastSeenShinyCount = nil

local function ensure_session_baseline()
    if sessionStartTime ~= nil then return end
    sessionStartTime = os.time()
    encountersAtSessionStart = Stats.totalEncounters
    lastSeenShinyCount = Stats.totalShinies
end

-- FPS estimate: sampled every tick() call via a wall-clock/frame-count
-- delta, independent of the (much less frequent) actual send cadence -
-- so whatever value we DO send is always fresh, not stale from up to
-- MIN_SEND_INTERVAL_SECONDS ago.
--
-- Deliberately uses os.time() rather than os.clock(): every other
-- timing check in this whole project (stuck detection, reset timeouts,
-- etc across every module) already uses os.time() exclusively, and
-- os.clock() (CPU time, not necessarily wall-clock under whatever host
-- runs BizHawk's Lua) has never been exercised anywhere in this
-- codebase - not worth the risk of it behaving unexpectedly here. The
-- tradeoff is only 1-second integer resolution, so this samples over a
-- longer FPS_SAMPLE_WINDOW_SECONDS window to keep the estimate stable
-- rather than jittering between e.g. a 1s and 2s window from rounding.
local FPS_SAMPLE_WINDOW_SECONDS = 3
local lastFpsSampleTime = os.time()
local lastFpsSampleFrame = emu.framecount()
local currentFpsEstimate = 0

local function update_fps_estimate()
    local now = os.time()
    local elapsed = now - lastFpsSampleTime
    if elapsed >= FPS_SAMPLE_WINDOW_SECONDS then
        local nowFrame = emu.framecount()
        local frameDelta = nowFrame - lastFpsSampleFrame
        currentFpsEstimate = math.floor((frameDelta / elapsed) + 0.5)
        lastFpsSampleTime = now
        lastFpsSampleFrame = nowFrame
    end
end

local lastSendTime = 0

local function send_presence_update(stateLabel)
    local elapsedHours = math.max((os.time() - sessionStartTime) / 3600, 1 / 3600)
    local sessionEncounters = Stats.totalEncounters - encountersAtSessionStart
    local ratePerHour = math.floor((sessionEncounters / elapsedHours) + 0.5)

    local imageText
    if Stats.lastShinySpeciesId ~= nil then
        imageText = get_pokemon_name(Stats.lastShinySpeciesId) .. " (shiny)"
    else
        imageText = "autocrystal"
    end

    local fullState = (stateLabel or "autocrystal") .. " | " .. get_game_version_label()

    local parts = {}
    table.insert(parts, string.format('"state": "%s"', json_escape(fullState)))
    table.insert(parts, string.format('"encounters": %d', Stats.totalEncounters))
    table.insert(parts, string.format('"encounters_display": "%s"', json_escape(with_commas(Stats.totalEncounters))))
    table.insert(parts, string.format('"shinies": %d', Stats.totalShinies))
    table.insert(parts, string.format('"rate_per_hour": %d', ratePerHour))
    table.insert(parts, string.format('"fps": %d', currentFpsEstimate))
    table.insert(parts, string.format('"session_start": %d', sessionStartTime))
    table.insert(parts, string.format('"image_text": "%s"', json_escape(imageText)))

    local payload = "{" .. table.concat(parts, ",") .. "}"

    local ok, response = pcall(comm.httpPost, PRESENCE_RELAY_URL, payload)
    if not ok then
        -- Deliberately quiet by default - if discord_presence_relay.ps1
        -- isn't running, this would otherwise print every single tick.
        -- Uncomment for troubleshooting:
        -- print("Presence update failed: " .. tostring(response))
    end
end

-- Call once per frame from launcher.lua's main loop while a module is
-- running. stateLabel is whatever short "what's happening" text the
-- caller wants shown (e.g. "Wild - Route 32", or just "Starters") -
-- everything else (encounters, shinies, rate, fps, image tooltip text)
-- is derived automatically from the shared Stats module, with zero
-- per-hunting-module wiring required.
function M.tick(stateLabel)
    ensure_session_baseline()
    update_fps_estimate()

    local now = os.time()
    local newShinyFound = Stats.totalShinies ~= lastSeenShinyCount
    if newShinyFound then
        lastSeenShinyCount = Stats.totalShinies
    end

    -- Send immediately on a brand new shiny (so the tooltip text over
    -- the card's image updates right away) or once the normal throttle
    -- window has passed - whichever comes first.
    if newShinyFound or (now - lastSendTime) >= MIN_SEND_INTERVAL_SECONDS then
        lastSendTime = now
        send_presence_update(stateLabel)
    end
end

return M

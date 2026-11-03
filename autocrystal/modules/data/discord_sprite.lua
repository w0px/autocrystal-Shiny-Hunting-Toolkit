-- discord_sprite.lua (lives in data/)
-- The Pokemon sprite in a Discord message's corner (the embed thumbnail),
-- for every module's notifications.
--
-- Discord shows that corner at 80x80 at most, and the plain 56px Crystal
-- sprites leave most of it empty - many Pokemon fill only 35-40px of their
-- canvas. tools/scale_sprites.ps1 (run by "Download sprites...") makes
-- data/sprites/animated_discord/{normal,shiny}/<dex>.gif for that: the
-- animated sprite with its empty border trimmed off, scaled
-- nearest-neighbor until its longer side is 72px (80 looked a bit too
-- big) - about 1.8x for most Pokemon, 1.29x for the ones that already fill
-- the whole 56px. There's
-- no public URL for those, so the message asks discord_relay.ps1 to
-- upload the file with it ("attachment://shiny_101.gif" means
-- animated_discord/shiny/101.gif). Not made yet (sprites never
-- downloaded): the plain sprite's public URL instead, as before.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local SPRITE_DIR = script_dir .. "../../data/sprites/animated_discord/"

function M.url(dexNumber, isShiny)
    local set = isShiny and "shiny" or "normal"
    local f = io.open(string.format("%s%s/%d.gif", SPRITE_DIR, set, dexNumber), "rb")
    if f then
        f:close()
        return string.format("attachment://%s_%d.gif", set, dexNumber)
    end
    return string.format(
        "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal/animated/%s%d.gif",
        isShiny and "shiny/" or "", dexNumber)
end

return M

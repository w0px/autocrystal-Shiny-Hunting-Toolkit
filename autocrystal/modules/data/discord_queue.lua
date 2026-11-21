-- discord_queue.lua (lives in modules/data/)
-- Discord messages handed to discord_relay.ps1 as files instead of a web
-- call the emulator waits on: comm.httpPost holds the whole game until the
-- relay has talked to Discord (up to the 3 s timeout - a stutter, and a
-- missed encounter frame here and there). The relay picks the files up in
-- its own process, sends them in order, tries again later when Discord
-- fails, and never sends one twice.
--
-- M.DIR: the folder (the launcher sets it once it has started the relay with
-- -SpoolDir on that folder). nil: off - M.post falls back to the web call,
-- exactly as before (relays turned off, or started by hand).
--
-- M.post(url, payload) -> ok, response   (the shape of pcall(comm.httpPost))
-- M.put(action, channel, key, json) -> "queued", or nil and why. A file
--   discord_<time>_<n>_<send|edit>_<channel>_<key>.json in M.DIR, written
--   under a .tmp name and renamed when whole (the relay never reads half).

local M = {}

M.DIR = nil
local seq = 0

function M.put(action, channel, key, json)
    if not M.DIR then return nil, "no queue folder" end
    if action ~= "send" and action ~= "edit" then return nil, "bad action" end
    if not tostring(channel):match("^[a-z]+$") or not tostring(key):match("^[%w_%-]+$") then return nil, "bad channel or key" end
    seq = seq + 1
    local name = string.format("discord_%d_%06d_%s_%s_%s.json", os.time(), seq % 1000000, action, channel, key)
    local path = M.DIR .. name
    local f, err = io.open(path .. ".tmp", "wb")
    if not f then return nil, tostring(err) end
    f:write(json)
    f:close()
    local ok, why = os.rename(path .. ".tmp", path)
    if not ok then os.remove(path .. ".tmp"); return nil, tostring(why) end
    return "queued"
end

-- A hunting module's message (the launcher's own webhook: channel "main").
function M.post(url, payload)
    if M.DIR then
        local key = string.format("m%d_%d", os.time(), seq + 1)
        local res, why = M.put("send", "main", key, payload)
        if res then return true, "queued for the relay" end
        -- (the folder can't be written: the web call, as before)
        print("Discord queue: " .. tostring(why) .. " - sending directly instead.")
    end
    return pcall(comm.httpPost, url, payload)
end

return M

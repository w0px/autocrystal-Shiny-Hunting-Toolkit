-- relay_watch.lua (lives in data/)
-- The relays look after themselves for a run of years (the user, 2026-11-20:
-- "goal is to have it running for years with only minor restarts"). Each
-- relay writes "<unix time> <pid> <version>" into its heartbeat file every
-- couple of seconds (-HeartbeatFile). M.due() says which ones to start again:
-- no heartbeat, one older than M.STALE seconds (died or hung), or an older
-- version (BizHawk not restarted since an update). The new one is started
-- with -Takeover: it stops the old copy on its port itself - PowerShell's
-- work, never the emulator's. At most one start per relay every M.GAP s.
--
-- M.due(now, relays, read) -> {name, ...}. relays: {{name, file, version,
-- startedAt (when this launcher last started it)}}; read(file) -> text|nil.
-- Plain - tested offline; the launcher does the starting.

local M = {}

M.STALE = 45          -- s without a heartbeat: dead or hung
M.GAP = 120           -- s at least between two starts of one relay (it needs time to come up)

function M.parse(text)
    local t, pid, ver = tostring(text or ""):match("^(%d+)%s+(%d+)%s+(%d+)")
    if not t then return nil end
    return {time = tonumber(t), pid = tonumber(pid), version = tonumber(ver)}
end

-- Why a relay needs starting (nil: it's fine).
function M.why(now, r, read)
    if r.startedAt and now - r.startedAt < M.GAP then return nil end
    local hb = M.parse(read(r.file))
    if not hb then return "no heartbeat" end
    if now - hb.time > M.STALE then return string.format("no heartbeat for %d s", now - hb.time) end
    if (hb.version or 0) < (r.version or 0) then return string.format("an old version (%d, %d wanted)", hb.version or 0, r.version) end
    return nil
end

function M.due(now, relays, read)
    local out = {}
    for _, r in ipairs(relays) do
        local why = M.why(now, r, read)
        if why then out[#out + 1] = {name = r.name, why = why} end
    end
    return out
end

return M

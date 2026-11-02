-- Veltrix v2.5: bounded, passive evidence correlation.
-- This module NEVER awards points or punishes users. It consumes existing log events.
if not SERVER then return end

Veltrix.Evidence = Veltrix.Evidence or {}
local Evidence = Veltrix.Evidence
local players = {}
local WINDOW = 180 -- seconds, sliding window
local MAX_EVENTS = 120 -- per player
local REPORT_GAP = 180

local function classify(source)
    source = string.lower(tostring(source or "unknown"))
    if string.find(source, "client", 1, true) or string.find(source, "heartbeat", 1, true)
        or string.find(source, "hook_change", 1, true) then
        return "client_report", "client-reported (untrusted)"
    end
    if string.find(source, "rage", 1, true) or string.find(source, "aim", 1, true)
        or string.find(source, "angle", 1, true) then
        return "aim", "server-observed heuristic"
    end
    if string.find(source, "behavior", 1, true) or string.find(source, "cmd", 1, true)
        or string.find(source, "antiaim", 1, true) then
        return "command", "server-observed heuristic"
    end
    if string.find(source, "decoy", 1, true) or string.find(source, "honeypot", 1, true) then
        return "decoy", "server-observed heuristic"
    end
    if string.find(source, "move", 1, true) or string.find(source, "speed", 1, true) then
        return "movement", "server-observed heuristic"
    end
    if string.find(source, "net", 1, true) then return "network", "server-observed heuristic" end
    return "other", "source requires review"
end

local function prune(state, now)
    local out = {}
    for _, e in ipairs(state.events) do
        if now - e.seen <= WINDOW then out[#out + 1] = e end
    end
    while #out > MAX_EVENTS do table.remove(out, 1) end
    state.events = out
end

local function summarize(state)
    local categories, sources = {}, {}
    local trustworthy = 0
    for _, e in ipairs(state.events) do
        sources[e.src] = (sources[e.src] or 0) + 1
        if e.category ~= "client_report" then
            categories[e.category] = true
            trustworthy = trustworthy + 1
        end
    end
    local distinct = 0
    for _ in pairs(categories) do distinct = distinct + 1 end
    return distinct, trustworthy, sources
end

function Evidence.Record(e)
    if not Veltrix.Cfg("evidence_enabled") or type(e) ~= "table" then return end
    if e.src == "evidence_correlation" then return end
    local sid = tostring(e.sid or "")
    if sid == "" then return end
    local now = CurTime()
    local st = players[sid] or { events = {}, lastReport = -1e9 }
    players[sid] = st
    local category, trust = classify(e.src)
    st.name = tostring(e.name or st.name or "unknown")
    st.events[#st.events + 1] = {
        seen = now, timestamp = tonumber(e.t) or os.time(), src = tostring(e.src or "unknown"),
        category = category, trust = trust, info = e.info == true,
        detail = string.sub(tostring(e.detail or ""), 1, 200),
    }
    prune(st, now)
    local distinct, count = summarize(st)
    -- This is an alert about diverse server-side observations, not a cheat verdict.
    if distinct >= Veltrix.Cfg("evidence_min_categories") and count >= 5
        and now - st.lastReport >= REPORT_GAP then
        st.lastReport = now
        local msg = string.format("Evidence review: %s (%s) — %d events across %d categories in %ds. No automatic action.",
            st.name, sid, count, distinct, WINDOW)
        Veltrix.Notify(msg, false)
        ServerLog("[Veltrix] " .. msg .. "\n")
    end
end

function Evidence.Summary(sid)
    local st = players[tostring(sid)]
    if not st then return nil end
    prune(st, CurTime())
    local categories, count, sources = summarize(st)
    local recent = {}
    for i = math.max(1, #st.events - 49), #st.events do
        local e = st.events[i]
        recent[#recent + 1] = {
            t = e.timestamp, src = e.src, category = e.category,
            trust = e.trust, info = e.info, detail = e.detail,
        }
    end
    return { name = st.name, sid = tostring(sid), window_seconds = WINDOW,
        event_count = #st.events, server_event_count = count,
        independent_categories = categories, sources = sources, events = recent,
        warning = "Heuristic/correlated signals are not proof of cheating. Client reports are untrusted." }
end

-- Server console only; writes sanitized SteamID-specific evidence into data/veltrix/.
concommand.Add("veltrix_evidence_export", function(ply, _, args)
    if IsValid(ply) then
        if not Veltrix.IsSuper(ply) then return end
    end
    local sid = tostring(args[1] or "")
    if not string.match(sid, "^STEAM_%d:%d:%d+$") and not string.match(sid, "^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        if IsValid(ply) then ply:ChatPrint("Usage: veltrix_evidence_export <SteamID or SteamID64>") end
        return
    end
    local report = Evidence.Summary(sid)
    if not report then
        if IsValid(ply) then ply:ChatPrint("No evidence currently in memory for " .. sid) end
        return
    end
    local safe = string.gsub(sid, "[^%w_]", "_")
    local path = "veltrix/evidence_" .. safe .. ".json"
    file.Write(path, util.TableToJSON(report, true))
    ServerLog("[Veltrix] Exported evidence to data/" .. path .. "\n")
    if IsValid(ply) then ply:ChatPrint("Exported data/" .. path) end
end)

-- Wrap the canonical logging sink, preserving its original behavior.
local originalAddLog = Veltrix.AddLog
function Veltrix.AddLog(event)
    originalAddLog(event)
    Evidence.Record(event)
end

-- Clean disconnected-player histories after the review window has elapsed.
timer.Create("Veltrix_EvidencePrune", 60, 0, function()
    local now = CurTime()
    for sid, st in pairs(players) do
        prune(st, now)
        if #st.events == 0 then players[sid] = nil end
    end
end)

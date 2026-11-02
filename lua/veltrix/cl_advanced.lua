-- Veltrix client diagnostics
-- This script is advisory. A modified client can forge, omit or suppress every report.
if not CLIENT then return end

local REPORT_INTERVAL = 15
local MAX_NAMES = 24
local seq = 0
local previous = {}
local started = false

local WATCHED_EVENTS = {
    CreateMove = true,
    StartCommand = true,
    InputMouseApply = true,
    CalcView = true,
    Think = true,
    HUDPaint = true,
    PreDrawHalos = true,
    RenderScreenspaceEffects = true,
    PostDrawOpaqueRenderables = true,
}

local function snapshotHooks()
    local snapshot = {}
    local count = 0
    for event, entries in pairs(hook.GetTable()) do
        for name in pairs(entries) do
            count = count + 1
            if WATCHED_EVENTS[event] and type(name) == "string" then
                snapshot[event .. "/" .. name] = true
            end
        end
    end
    return snapshot, count
end

local function changesSince(current, old)
    local changes = {}
    for name in pairs(current) do
        if not old[name] then changes[#changes + 1] = "+" .. name end
    end
    for name in pairs(old) do
        if not current[name] then changes[#changes + 1] = "-" .. name end
    end
    table.sort(changes)
    return changes
end

local function sendDiagnostics()
    if not IsValid(LocalPlayer()) then return end
    if not net or not net.Start then return end

    seq = (seq + 1) % 65536
    local current, total = snapshotHooks()
    local changes = changesSince(current, previous)
    local baseline = not started
    previous = current
    started = true

    -- Preserve the existing heartbeat wire format for compatibility.
    net.Start("Veltrix_ClientPulse")
        net.WriteUInt(seq, 16)
        net.WriteFloat(math.Clamp(FrameTime(), 0, 10))
        net.WriteUInt(math.min(total, 4095), 12)
    net.SendToServer()

    -- Never send an arbitrary Lua dump or function source. Names are bounded.
    net.Start("Veltrix_ClientHooks")
        net.WriteUInt(seq, 16)
        net.WriteBool(baseline)
        net.WriteUInt(math.min(#changes, MAX_NAMES), 5)
        for i = 1, math.min(#changes, MAX_NAMES) do
            net.WriteString(string.sub(changes[i], 1, 120))
        end
    net.SendToServer()
end

timer.Create("Veltrix_ClientDiagnostics", REPORT_INTERVAL, 0, sendDiagnostics)

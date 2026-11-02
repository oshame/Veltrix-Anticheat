-- Veltrix server diagnostics
-- User commands are server-observed; client hook names and heartbeat are NOT trusted.
if not SERVER then return end

util.AddNetworkString("Veltrix_ClientPulse")
util.AddNetworkString("Veltrix_ClientHooks")

local C = Veltrix.Cfg
local state = setmetatable({}, { __mode = "k" })
local COMMAND_REPORT_COOLDOWN = 15
local CLIENT_REPORT_COOLDOWN = 45
local MAX_HOOK_CHANGES = 24

local function playerState(ply)
    local item = state[ply]
    if not item then
        item = { invalidStreak = 0, lastCommandReport = 0, lastHookLog = 0, gaps = 0 }
        state[ply] = item
    end
    return item
end

local function eligible(ply)
    return IsValid(ply) and ply:IsPlayer() and not ply:IsBot()
        and ply:Alive() and not ply:InVehicle()
        and ply:GetObserverMode() == OBS_MODE_NONE
        and ply:GetMoveType() == MOVETYPE_WALK
end

-- Information is logged without adding suspicion or triggering punishments.
local function diagnostic(ply, source, detail)
    if not IsValid(ply) or ply:IsBot() then return end
    if not C("diagnostics_enabled") then return end
    Veltrix.AddLog({
        t = os.time(), name = ply:Nick(), sid = ply:SteamID(),
        src = source, pts = 0, score = math.Round(Veltrix.GetState(ply).score, 2),
        detail = string.sub(detail or "", 1, 200), info = true,
    })
end

-- Runs on the SERVER for each received user command, not inside the client's Lua runtime.
hook.Add("StartCommand", "Veltrix_AdvancedCommand", function(ply, cmd)
    if not eligible(ply) then state[ply] = nil return end

    local number = cmd:CommandNumber()
    if number <= 0 then return end

    local now = CurTime()
    local s = playerState(ply)
    local angles = cmd:GetViewAngles()
    local finite = angles.p == angles.p and angles.y == angles.y and angles.r == angles.r
    local invalid = not finite or math.abs(angles.p) > 89.1 or math.abs(angles.r) > 1.5

    if invalid then
        s.invalidStreak = s.invalidStreak + 1
    else
        s.invalidStreak = math.max(0, s.invalidStreak - 1)
    end

    if s.invalidStreak >= 8 and now - s.lastCommandReport >= COMMAND_REPORT_COOLDOWN then
        s.lastCommandReport = now
        diagnostic(ply, "usercmd_angles", "Repeated abnormal pitch/roll in server-received commands")
        if C("advanced_antiaim") and not Veltrix.NoScore(ply) then
            Veltrix.Suspect(ply, "antiaim", C("advanced_antiaim_points"),
                "Repeated abnormal server-received usercmd pitch/roll")
        end
    end

    -- These discontinuities also occur during loss/choke/tickbase changes. Log only.
    if s.command and number > s.command + 1 and number - s.command < 128 then
        s.gaps = s.gaps + (number - s.command - 1)
    end
    if s.sampleAt and now - s.sampleAt >= 60 then
        if s.gaps > 0 then
            diagnostic(ply, "usercmd_gaps", "Command sequence gaps in last minute: " .. s.gaps)
        end
        s.gaps, s.sampleAt = 0, now
    end

    s.command = number
    s.sampleAt = s.sampleAt or now
end)

net.Receive("Veltrix_ClientPulse", function(_, ply)
    if not IsValid(ply) or ply:IsBot() then return end
    local s = playerState(ply)
    local now = CurTime()
    if s.pulseAt and now - s.pulseAt < 1 then return end
    s.pulseAt = now
    s.clientNonce = net.ReadUInt(16)
    s.clientFrame = net.ReadFloat()
    s.clientHooks = net.ReadUInt(12)
    s.everPulsed = true
end)

local function allowedName(name)
    return type(name) == "string" and #name <= 120
        and #name >= 3 and not string.find(name, "[%c]", 1)
end

net.Receive("Veltrix_ClientHooks", function(_, ply)
    if not IsValid(ply) or ply:IsBot() then return end
    local s = playerState(ply)
    local now = CurTime()
    if s.hookPacketAt and now - s.hookPacketAt < 5 then return end
    s.hookPacketAt = now

    local seq = net.ReadUInt(16)
    local baseline = net.ReadBool()
    local count = net.ReadUInt(5)
    if count > MAX_HOOK_CHANGES then return end

    local changes = {}
    for i = 1, count do
        local name = net.ReadString()
        if allowedName(name) then changes[#changes + 1] = name end
    end

    -- Initial baseline can include many ordinary addon hooks: never flag it.
    if not baseline and #changes > 0 and now - s.lastHookLog >= CLIENT_REPORT_COOLDOWN then
        s.lastHookLog = now
        diagnostic(ply, "client_hook_change",
            string.format("Untrusted client-reported hook changes (seq %d): %s", seq,
                table.concat(changes, ", ")))
    end
end)

timer.Create("Veltrix_ClientHealth", 30, 0, function()
    if not C("advanced_heartbeat") then return end
    for _, ply in ipairs(player.GetHumans()) do
        local s = state[ply]
        -- Only warn for previously observed heartbeats; joining alone proves nothing.
        if s and s.everPulsed and CurTime() - (s.pulseAt or 0) > 90 and not s.heartbeatWarned then
            s.heartbeatWarned = true
            diagnostic(ply, "heartbeat_missing", "Client diagnostics stopped responding (informational)")
            Veltrix.Notify("[Veltrix] Client diagnostics missing for " .. ply:Nick()
                .. " (informational only)", false)
        elseif s and s.pulseAt and CurTime() - s.pulseAt < 40 then
            s.heartbeatWarned = false
        end
    end
end)

hook.Add("PlayerDisconnected", "Veltrix_AdvancedCleanup", function(ply)
    state[ply] = nil
end)

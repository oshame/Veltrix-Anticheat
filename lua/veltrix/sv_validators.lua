if not SERVER then return end
-- Defense in depth. All checks are server-observed; no client telemetry is trusted.
local C = Veltrix.Cfg
local players = setmetatable({}, {__mode = "k"})
local function state(p)
    local d = players[p]
    if not d then d = {fire = {}, mismatch = 0, movement = 0, net = 0} players[p] = d end
    return d
end
local function eligible(p)
    return IsValid(p) and p:IsPlayer() and not p:IsBot() and p:Alive() and not Veltrix.NoScore(p)
end
local function diff(a, b)
    return math.deg(math.acos(math.Clamp(a:GetNormalized():Dot(b:GetNormalized()), -1, 1)))
end
-- EntityFireBullets sees server-side trajectories even when the client restores its
-- camera angle before the next usercmd. Some SWEPs deliberately bend trajectories.
hook.Add("EntityFireBullets", "Veltrix_Ballistics", function(ent, bullet)
    if not eligible(ent) or not C("ballistics_enabled") then return end
    local d = state(ent)
    local now = CurTime()
    d.fire[#d.fire + 1] = now
    while #d.fire > 0 and d.fire[1] < now - 1 do table.remove(d.fire, 1) end
    if C("fire_enabled") and #d.fire > C("fire_max_per_second") and now > (d.fireCD or 0) then
        d.fireCD = now + 5
        Veltrix.Suspect(ent, "fire_rate", 0.5, "Excessive server-observed bullet events; verify weapon fire mode")
    end
    local sample = Veltrix.AimSamples and Veltrix.AimSamples[ent]
    if not sample or not sample.lastCmdAngle or now - (sample.lastCmdAt or 0) > 0.15 then return end
    if not bullet or not isvector(bullet.Dir) or bullet.Dir:LengthSqr() < 0.5 then return end
    if ent:InVehicle() or ent:GetMoveType() == MOVETYPE_NOCLIP or now < (ent.VeltrixIgnoreUntil or 0) then return end
    local divergence = diff(sample.lastCmdAngle:Forward(), bullet.Dir)
    if divergence > C("ballistics_angle") then
        d.mismatch = d.mismatch + 1
        if d.mismatch >= 4 and now > (d.ballisticCD or 0) then
            d.ballisticCD, d.mismatch = now + 8, 0
            Veltrix.Suspect(ent, "bullet_direction", C("ballistics_points"),
                string.format("Repeated bullet/command mismatch (latest %.1f deg); possible pSilent or custom SWEP", divergence))
        end
    else
        d.mismatch = math.max(0, d.mismatch - 1)
    end
end)
-- Position sampling avoids interpreting a server-side teleport as client cheating.
-- Ignore outliers after spawn and only score multiple consecutive bursts.
hook.Add("PlayerSpawn", "Veltrix_MovementSpawn", function(p)
    local d = state(p); d.pos = nil; d.movement = 0; d.moveIgnore = CurTime() + 4
end)
timer.Create("Veltrix_MovementValidation", 0.25, 0, function()
    if not C("movement_enabled") then return end
    local now = CurTime()
    for _, p in ipairs(player.GetHumans()) do
        local d = state(p)
        local pos = p:GetPos()
        if not eligible(p) or p:InVehicle() or p:GetMoveType() ~= MOVETYPE_WALK or p:GetObserverMode() ~= OBS_MODE_NONE or now < (d.moveIgnore or 0) then
            d.pos, d.moveAt, d.movement = pos, now, 0
        elseif d.pos and d.moveAt then
            local dt = now - d.moveAt
            if dt > 0.1 and dt < 1 then
                local speed = pos:Distance(d.pos) / dt
                if speed > C("movement_speed") then
                    d.movement = d.movement + 1
                    if d.movement >= 3 and now > (d.moveCD or 0) then
                        d.moveCD, d.movement = now + 10, 0
                        Veltrix.Suspect(p, "movement", C("movement_points"),
                            string.format("Repeated position bursts; last %.0f units/sec (check teleports)", speed))
                    end
                else d.movement = math.max(0, d.movement - 1) end
            end
            d.pos, d.moveAt = pos, now
        else d.pos, d.moveAt = pos, now end
    end
end)
-- Passive network audit. net.Incoming is wrapped rather than replacing receivers;
-- do not block legitimate addon traffic. Detects registered message floods only.
local originalIncoming = net.Incoming
if type(originalIncoming) == "function" then
    net.Incoming = function(len, client)
        if C("net_guard_enabled") and IsValid(client) and client:IsPlayer() and not client:IsBot() then
            local d = state(client)
            local now = CurTime()
            if now - (d.netStart or 0) >= 1 then d.netStart, d.net = now, 0 end
            d.net = d.net + 1
            if d.net > C("net_guard_rate") and now > (d.netCD or 0) then
                d.netCD = now + 10
                Veltrix.Suspect(client, "net_flood", C("net_guard_points"),
                    "High inbound net message rate (review addon network handlers)")
            end
        end
        return originalIncoming(len, client)
    end
end
hook.Add("PlayerDisconnected", "Veltrix_ValidatorCleanup", function(p) players[p] = nil end)

-- Veltrix v2.4: passive, server-observed command behaviour telemetry.
-- Do NOT punish solely on these signals: scripted weapons, packet loss,
-- accessibility devices, macros and gamemode mechanics may resemble cheats.
if not SERVER then return end

local C = Veltrix.Cfg
local states = setmetatable({}, { __mode = "k" })
local REPORT_INTERVAL = 30
local SAMPLE_RESET = 0.35

local function getState(ply)
    local s = states[ply]
    if not s then
        s = { streak = {}, reports = {}, counts = {}, recent = {} }
        states[ply] = s
    end
    return s
end

local function eligible(ply)
    return IsValid(ply) and ply:IsPlayer() and not ply:IsBot()
        and ply:Alive() and ply:GetObserverMode() == OBS_MODE_NONE
        and not ply:InVehicle() and ply:GetMoveType() == MOVETYPE_WALK
        and CurTime() >= (ply.VeltrixIgnoreUntil or 0)
end

local function log(ply, tag, detail)
    if not C("behavior_monitor_enabled") or not C("diagnostics_enabled") then return end
    Veltrix.AddLog({
        t = os.time(), name = ply:Nick(), sid = ply:SteamID(),
        src = "behavior_" .. tag, pts = 0, info = true,
        score = math.Round(Veltrix.GetState(ply).score, 2),
        detail = string.sub(detail, 1, 200),
    })
end

local function signal(ply, s, key, observed, minimum, detail)
    s.streak[key] = observed and math.min((s.streak[key] or 0) + 1, minimum + 4)
        or math.max((s.streak[key] or 0) - 2, 0)
    local now = CurTime()
    if s.streak[key] >= minimum and now >= (s.reports[key] or 0) then
        s.reports[key] = now + REPORT_INTERVAL
        log(ply, key, detail)
    end
end

local function finite(x)
    return x == x and x ~= math.huge and x ~= -math.huge
end

local function reset(ply)
    states[ply] = nil
end
hook.Add("PlayerSpawn", "Veltrix_BehaviorSpawn", reset)
hook.Add("PlayerDisconnected", "Veltrix_BehaviorDisconnect", reset)

hook.Add("StartCommand", "Veltrix_BehaviorCommands", function(ply, cmd)
    if not C("behavior_monitor_enabled") then return end
    if not eligible(ply) then reset(ply) return end
    local id = cmd:CommandNumber()
    if id <= 0 then return end -- ignore synthetic/engine commands

    local s = getState(ply)
    local now = CurTime()
    local a = cmd:GetViewAngles()
    local fwd, side, up = cmd:GetForwardMove(), cmd:GetSideMove(), cmd:GetUpMove()
    local mx, my = cmd:GetMouseX(), cmd:GetMouseY()
    local attacking, jumping, ducking = cmd:KeyDown(IN_ATTACK), cmd:KeyDown(IN_JUMP), cmd:KeyDown(IN_DUCK)
    local moving = math.abs(fwd) + math.abs(side) > 80

    -- Do not assume all anomalies are cheats; malformed angles can be caused by addons.
    signal(ply, s, "nonfinite_input",
        not (finite(a.p) and finite(a.y) and finite(a.r)
            and finite(fwd) and finite(side) and finite(up)),
        2, "Non-finite command angle or movement input (verify gamemode/addons)")
    if not (finite(a.p) and finite(a.y) and finite(a.r)) then return end

    -- Command numbering anomalies are often network symptoms, so advisory only.
    if s.id and id <= s.id and id > 0 and now - (s.time or now) < 0.2 then
        signal(ply, s, "cmd_regression", true, 3,
            string.format("Repeated out-of-order usercmd: previous=%d current=%d", s.id, id))
    else
        signal(ply, s, "cmd_regression", false, 3, "")
    end

    local consecutive = s.id and id == s.id + 1 and now - (s.time or 0) <= SAMPLE_RESET
    if not consecutive then
        s.streak = {} -- break macro/rotation streaks across dropped commands
        s.prevYaw = nil
        s.prevJump = jumping
        s.prevDuck = ducking
        s.lastAngle = Angle(a.p, a.y, a.r)
        s.id, s.time = id, now
        return
    end

    local yaw = math.AngleDifference(a.y, s.lastAngle.y)
    local pitch = math.AngleDifference(a.p, s.lastAngle.p)
    local turn = math.abs(yaw) + math.abs(pitch)
    local mouse = math.abs(mx) + math.abs(my)

    -- Distinct from the existing anti-aim yaw-spin / jitter detectors.
    signal(ply, s, "angle_mouse_mismatch", turn > 38 and mouse == 0, 7,
        string.format("Large view changes without reported mouse deltas (last %.0f deg)", turn))
    signal(ply, s, "movement_nonfinite",
        not (finite(fwd) and finite(side) and finite(up)), 2,
        "Non-finite forward/side/up usercmd movement")
    signal(ply, s, "movement_outlier",
        finite(fwd) and finite(side) and finite(up)
            and (math.abs(fwd) > 20000 or math.abs(side) > 20000 or math.abs(up) > 20000),
        5, "Repeated extreme usercmd movement values; custom movement controllers may do this")
    signal(ply, s, "attack_without_view_variation",
        attacking and moving and mouse > 6 and turn < 0.001, 18,
        "Prolonged attack/movement with mouse delta but unchanged command view angles")

    -- Alternating input patterns: heuristic macro indicators, not cheat proof.
    local jumpEdge = jumping and not s.prevJump
    local duckEdge = ducking ~= s.prevDuck
    if jumpEdge then
        local since = now - (s.lastJumpAt or 0)
        if since > 0.05 and since < 0.3 then
            s.jumpPattern = (s.jumpPattern or 0) + 1
        else
            s.jumpPattern = math.max(0, (s.jumpPattern or 0) - 2)
        end
        s.lastJumpAt = now
    end
    if duckEdge then
        local since = now - (s.lastDuckAt or 0)
        if since > 0.02 and since < 0.2 then
            s.duckPattern = (s.duckPattern or 0) + 1
        else
            s.duckPattern = math.max(0, (s.duckPattern or 0) - 2)
        end
        s.lastDuckAt = now
    end
    if (s.jumpPattern or 0) >= 15 and now >= (s.reports.jump_macro or 0) then
        s.reports.jump_macro = now + 45
        s.jumpPattern = 0
        log(ply, "jump_macro", "Frequent rapid jump-button rising edges; review movement mode")
    end
    if (s.duckPattern or 0) >= 25 and now >= (s.reports.duck_macro or 0) then
        s.reports.duck_macro = now + 45
        s.duckPattern = 0
        log(ply, "duck_macro", "Frequent crouch toggles at short intervals; possible macro")
    end
    -- Inconsistent direction changes may signal scripted anti-aim or unusual input controllers.
    if s.prevYaw and math.abs(yaw) > 20 and math.abs(s.prevYaw) > 20
        and yaw * s.prevYaw < 0 and attacking then
        s.fireReversals = (s.fireReversals or 0) + 1
    else
        s.fireReversals = math.max(0, (s.fireReversals or 0) - 1)
    end
    if (s.fireReversals or 0) >= 12 and now >= (s.reports.fire_reversals or 0) then
        s.reports.fire_reversals = now + 30
        log(ply, "fire_reversals", "Sustained alternating view direction while attack held")
    end

    s.prevYaw, s.prevJump, s.prevDuck = yaw, jumping, ducking
    s.lastAngle = Angle(a.p, a.y, a.r)
    s.id, s.time = id, now
end)

-- Correlate actual damage and input activity without trusting client messages.
hook.Add("EntityTakeDamage", "Veltrix_BehaviorDamage", function(victim, dmg)
    if not C("behavior_monitor_enabled") or not C("diagnostics_enabled") then return end
    if not IsValid(victim) or not victim:IsPlayer() then return end
    local attacker = dmg:GetAttacker()
    if not eligible(attacker) or attacker == victim then return end
    local s = getState(attacker)
    local now = CurTime()
    -- Count very dense damage events only; multi-pellet SWEPs and explosives can do this.
    if now - (s.damageWindow or 0) >= 1 then
        s.damageWindow, s.damageHits = now, 0
    end
    s.damageHits = s.damageHits + 1
    if s.damageHits >= 100 and now >= (s.reports.damage_burst or 0) then
        s.reports.damage_burst = now + 45
        log(attacker, "damage_burst", "100+ damage callbacks against players within one second; inspect weapon")
    end
end)

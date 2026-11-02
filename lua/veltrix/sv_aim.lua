-- @dankor : REFACTOR THIS SLOP
if not SERVER then return end

local C = Veltrix.Cfg
local data = setmetatable({}, { __mode = "k" })
Veltrix.AimSamples = data

---------------------------------------------------------------- ignoring legitimate server-side angle changes
function Veltrix.IgnoreAim(ply, secs)
	ply.VeltrixIgnoreUntil = math.max(ply.VeltrixIgnoreUntil or 0, CurTime() + (secs or 1))
end

local PLY = FindMetaTable("Player")
for _, name in ipairs({ "SetEyeAngles", "SnapEyeAngles" }) do
	local key = "VeltrixOrig" .. name
	if PLY[name] and not PLY[key] then
		PLY[key] = PLY[name]
		PLY[name] = function(self, a)
			Veltrix.IgnoreAim(self, 1)
			return PLY[key](self, a)
		end
	end
end

hook.Add("PlayerSpawn", "Veltrix_AimSpawn", function(ply) Veltrix.IgnoreAim(ply, 1.5) end)
hook.Add("PlayerEnteredVehicle", "Veltrix_AimVehIn", function(ply) Veltrix.IgnoreAim(ply, 1.5) end)
hook.Add("PlayerLeaveVehicle", "Veltrix_AimVehOut", function(ply) Veltrix.IgnoreAim(ply, 1.5) end)

---------------------------------------------------------------- analysis
local function AngDelta(a, b)
	local dp = math.AngleDifference(a.p, b.p)
	local dy = math.AngleDifference(a.y, b.y)
	return math.sqrt(dp * dp + dy * dy)
end

hook.Add("StartCommand", "Veltrix_Aim", function(ply, cmd)
	if ply.VeltrixDecoy or ply:IsBot() or not ply:Alive() then return end

	local now = CurTime()
	local d = data[ply]
	if not d then d = { snapT = 0, snapDeg = 0, cdSilent = 0, cdMouse = 0 } data[ply] = d end

	local ang = cmd:GetViewAngles()
	d.lastCmdAngle = Angle(ang.p, ang.y, ang.r)
	d.lastCmdAt = now
	local cn = cmd:CommandNumber()
	local attack = cmd:KeyDown(IN_ATTACK)

	if Veltrix.HP and Veltrix.HP.OnCmd then Veltrix.HP.OnCmd(ply, cmd, ang, attack, now) end

	local ignored = now < (ply.VeltrixIgnoreUntil or 0) or ply:InVehicle()
		or ply:GetMoveType() == MOVETYPE_NOCLIP or ply:GetObserverMode() ~= OBS_MODE_NONE
	local a1, a2 = d.a1, d.a2

	-- reset history on ignored windows or gaps in command numbers (dropped/choked packets)
	if ignored or cn == 0 or not a1 or (d.cn and cn ~= d.cn + 1) then
		d.a1, d.a2, d.f1, d.cn = ang, nil, attack, cn
		return
	end

	local delta = AngDelta(ang, a1)

	-- 2. angle change with no mouse input
	if C("aim_nomouse") and delta >= C("aim_nomouse_min") and cmd:GetMouseX() == 0 and cmd:GetMouseY() == 0
	   and now >= d.cdMouse then
		d.cdMouse = now + 1
		Veltrix.Suspect(ply, "aimbot", C("aim_nomouse_pts"),
			string.format("View turned %.1f degrees in one tick with no mouse movement", delta))
	end

	-- 1. silent aim: a2 -> a1 (spike, firing) -> ang (back where it started)
	if C("aim_silent") and a2 and d.f1 and now >= d.cdSilent then
		local out, net = AngDelta(a1, a2), AngDelta(ang, a2)
		if out >= C("aim_silent_min") and delta >= C("aim_silent_min") and net <= math.max(0.35, out * 0.15) then
			d.cdSilent = now + 0.5
			Veltrix.Suspect(ply, "silent", C("aim_silent_pts"),
				string.format("Silent aim pattern: %.1f degree one-tick spike while firing, returned to start next tick", out))
		end
	end

	-- 3. snap tracking for the hit check below
	if delta >= C("aim_snap") then
		d.snapT, d.snapDeg = now, delta
	end

	d.a2, d.a1, d.f1, d.cn = a1, ang, attack, cn
end)

hook.Add("EntityTakeDamage", "Veltrix_AimHit", function(victim, dmg)
	if not C("aim_enabled") then return end
	local atk = dmg:GetAttacker()
	if not (IsValid(atk) and atk:IsPlayer() and victim:IsPlayer() and victim ~= atk) then return end
	if not dmg:IsBulletDamage() then return end

	local d = data[atk]
	if not d then return end
	local dt = CurTime() - d.snapT
	if dt < 0.12 then
		d.snapT = 0
		Veltrix.Suspect(atk, "aim", C("aim_points"),
			string.format("View snapped %.0f degrees then hit %s %dms later", d.snapDeg, victim:Nick(), math.floor(dt * 1000)))
	end
end)

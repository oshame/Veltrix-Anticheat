if not SERVER then return end

-- @note: anti esp for every viewer, do a real line-of-sight check on top of the engine PVS. (https://gamebanana.com/articles/72)
-- If the target is not visible, Entity:SetPreventTransmit (https://wiki.facepunch.com/gmod/Entity:SetPreventTransmit) 
-- stops the server sending it to that viewer, so a wallhack has nothing to read.

local C = Veltrix.Cfg
local WEAK = { __mode = "k" }

local lastSeen = setmetatable({}, WEAK)   -- [viewer][target] = CurTime()
local hidden   = setmetatable({}, WEAK)   -- [viewer][target] = bool
local cursor, nextRun, nTraces, active = 0, 0, 0, false

local trOut  = {}
local FILTER = {}
local trace  = { filter = FILTER, mask = MASK_OPAQUE, output = trOut }

local function Try(from, to)
	trace.start, trace.endpos = from, to
	util.TraceLine(trace)
	nTraces = nTraces + 1
	return not trOut.Hit
end

local function BuildPoints(ent)
	local pos = ent:GetPos()
	local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
	local h = maxs.z
	local mid = h * 0.5
	return {
		pos + Vector(0, 0, h - 4),            -- head
		pos + Vector(0, 0, mid),              -- chest
		pos + Vector(0, 0, 6),                -- feet
		pos + Vector(maxs.x, maxs.y, mid),    -- edges
		pos + Vector(mins.x, mins.y, mid),
		pos + Vector(maxs.x, mins.y, mid),
		pos + Vector(mins.x, maxs.y, mid),
	}
end

local function CanSee(viewer, target, pts, look)
	FILTER[1], FILTER[2], FILTER[3], FILTER[4] = viewer, target, nil, nil
	local n = 2
	local vv = viewer:GetVehicle()
	if IsValid(vv) then n = n + 1 FILTER[n] = vv end
	local tv = target:GetVehicle()
	if IsValid(tv) then n = n + 1 FILTER[n] = tv end

	local eye = viewer:EyePos()
	for i = 1, #pts do
		if Try(eye, pts[i]) then return true end
	end

	local tvel, vvel = target:GetVelocity(), viewer:GetVelocity()
	local tMoving = tvel:LengthSqr() > 2500
	local vMoving = vvel:LengthSqr() > 2500
	local shift = tvel * look

	if tMoving then
		for i = 1, 3 do
			if Try(eye, pts[i] + shift) then return true end
		end
	end
	if vMoving then
		local eye2 = eye + vvel * look
		for i = 1, 3 do
			if Try(eye2, pts[i]) then return true end
			if tMoving and Try(eye2, pts[i] + shift) then return true end
		end
	end
	return false
end

local function SetHidden(viewer, target, state)
    if not state and C("spectator_privacy_transmit")
        and Veltrix.ShouldHideObserver and Veltrix.ShouldHideObserver(target, viewer) then
        state = true
    end
	if not (IsValid(viewer) and IsValid(target)) then return end
	local h = hidden[viewer]
	if not h then h = setmetatable({}, WEAK) hidden[viewer] = h end
	if (h[target] or false) == state then return end
	h[target] = state

	target:SetPreventTransmit(viewer, state)
	for _, wep in ipairs(target:GetWeapons()) do
		if IsValid(wep) then wep:SetPreventTransmit(viewer, state) end
	end

	local extra = hook.Run("Veltrix_GetAttached", target)
	if istable(extra) then
		for _, e in ipairs(extra) do
			if IsValid(e) then e:SetPreventTransmit(viewer, state) end
		end
	end
end

local function ProcessViewer(viewer, players, pcache, now, hasForce)
	if Veltrix.SeesAll(viewer) then
		local h = hidden[viewer]
		if h then
			for target, st in pairs(h) do
				if st then SetHidden(viewer, target, false) end
			end
		end
		return
	end

	local ls = lastSeen[viewer]
	if not ls then ls = setmetatable({}, WEAK) lastSeen[viewer] = ls end

	local ping = C("occ_pingcomp") and math.min(viewer:Ping(), 300) / 2000 or 0
	local look = C("occ_lookahead") + ping
	local hold = C("occ_hold")
	local pvsOn = C("occ_pvs")
	local teams = C("occ_teammates")
	local vTeam = viewer:Team()

	for _, target in ipairs(players) do
		if target ~= viewer then
			if not target:Alive() or (teams and vTeam == target:Team() and vTeam < 1000) then
				SetHidden(viewer, target, false)
			else
				local seen = false
				if hasForce and hook.Run("Veltrix_ForceVisible", viewer, target) == true then
					seen = true
				elseif (not pvsOn) or target:TestPVS(viewer) then
					local pts = pcache[target]
					if not pts then pts = BuildPoints(target) pcache[target] = pts end
					seen = CanSee(viewer, target, pts, look)
				end
				if seen then ls[target] = now end
				local t = ls[target]
				SetHidden(viewer, target, not (t and now - t < hold))
			end
		end
	end
end

local function Step()
	local players = {}
	for _, p in ipairs(player.GetAll()) do
		if not p.VeltrixDecoy then players[#players + 1] = p end -- decoys are handled by sv_honeypot
	end
	local n = #players
	if n < 2 then return end

	local t0 = SysTime()
	nTraces = 0
	local now = CurTime()
	local per = math.max(1, math.ceil(n / C("occ_slices")))
	local budget = C("occ_budget")
	local pcache = {}
	local hasForce = hook.GetTable()["Veltrix_ForceVisible"] ~= nil

	for _ = 1, per do
		cursor = cursor % n + 1
		ProcessViewer(players[cursor], players, pcache, now, hasForce)
		if nTraces >= budget then break end
	end

	local S = Veltrix.Stats
	S.occMs   = Lerp(0.1, S.occMs, (SysTime() - t0) * 1000)
	S.traces  = Lerp(0.1, S.traces, nTraces)
end

function Veltrix.OcclusionReset()
	for viewer, h in pairs(hidden) do
		for target, st in pairs(h) do
			if st then SetHidden(viewer, target, false) end
		end
	end
	hidden   = setmetatable({}, WEAK)
	lastSeen = setmetatable({}, WEAK)
end

-- Unhide one entity for everyone (use for custom weapon drops etc.)
function Veltrix.RevealEntity(ent)
	if not IsValid(ent) then return end
	for _, p in ipairs(player.GetAll()) do
		ent:SetPreventTransmit(p, false)
	end
end

local function Reveal(target)
	for viewer, h in pairs(hidden) do
		if h[target] then SetHidden(viewer, target, false) end
	end
end

hook.Add("Think", "Veltrix_Occlusion", function()
	local now = CurTime()
	if now < nextRun then return end
	nextRun = now + C("occ_interval")

	if not C("occ_enabled") then
		if active then Veltrix.OcclusionReset() active = false end
		return
	end
	active = true
	Step()
end)

hook.Add("PlayerDeath", "Veltrix_OccDeath", function(ply) Reveal(ply) end)
hook.Add("PlayerSilentDeath", "Veltrix_OccSilentDeath", function(ply) Reveal(ply) end)
hook.Add("PlayerDroppedWeapon", "Veltrix_OccDrop", function(_, wep) Veltrix.RevealEntity(wep) end)

hook.Add("WeaponEquip", "Veltrix_OccWeapon", function(wep, owner)
	timer.Simple(0, function()
		if not (IsValid(wep) and IsValid(owner)) then return end
		for viewer, h in pairs(hidden) do
			if IsValid(viewer) and h[owner] then wep:SetPreventTransmit(viewer, true) end
		end
	end)
end)

hook.Add("PlayerDisconnected", "Veltrix_OccCleanup", function(ply)
	hidden[ply], lastSeen[ply] = nil, nil
end)

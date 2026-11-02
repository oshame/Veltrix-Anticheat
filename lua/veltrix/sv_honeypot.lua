if not SERVER then return end

-- Honeypot decoys. Two modes:
--  hp_mode 1 (default): roaming BOT players. Each bot is placed in open space near ONE player at a time,
--     out of that player's line of sight but inside their PVS, and transmitted only to them. Cheats that draw
--     players see a "player" behind a wall. The bot rotates through all players.
--  hp_mode 0: static prop decoys at admin-placed spots (only catches entity/prop ESP).
-- Detection runs on every usercmd (not 10Hz), so single-tick silent aim (psilent) is caught when it shoots at a decoy.

Veltrix.HP = Veltrix.HP or {}
local HP = Veltrix.HP
local C = Veltrix.Cfg
local WEAK = { __mode = "k" }

HP.Spots  = HP.Spots or {}
HP.Decoys = HP.Decoys or {}

local track = setmetatable({}, WEAK)
local rr, nextMove, nextEnsure, warned = 0, 0, 0, false
local CHEST = Vector(0, 0, 36)
local HIT_RADIUS = 30

local MODELS = {
	"models/player/kleiner.mdl", "models/player/police.mdl", "models/player/combine_soldier.mdl",
	"models/player/alyx.mdl", "models/player/odessa.mdl", "models/player/barney.mdl",
	"models/player/breen.mdl", "models/player/eli.mdl", "models/player/mossman.mdl",
	"models/player/group01/male_01.mdl", "models/player/group01/female_02.mdl", "models/player/group03/male_05.mdl",
}

local NAMES = {
	"Dylan", "jakeyboy", "Sarah", "Callum", "NoScope_Nick", "Tom", "Alfie", "mia.", "Kyle_", "Ryan",
	"Luna", "bigmike", "Sam", "Josh", "Ellie", "xx_Reece_xx", "Harvey", "Connor", "Zoe", "Liam",
}

local OFFSETS = {
	Vector(0, 0, 8), Vector(0, 0, 36), Vector(0, 0, 68),
	Vector(14, 0, 36), Vector(-14, 0, 36), Vector(0, 14, 36), Vector(0, -14, 36),
}

function Veltrix.IsDecoy(ent)
	return IsValid(ent) and ent.VeltrixDecoy == true
end

---------------------------------------------------------------- spots (static mode)
local function SpotsPath() return "veltrix/spots_" .. game.GetMap() .. ".json" end

function HP.LoadSpots()
	HP.Spots = {}
	for _, s in ipairs(Veltrix.ReadJSON(SpotsPath(), {})) do
		if type(s) == "table" and tonumber(s[1]) and tonumber(s[2]) and tonumber(s[3]) then
			HP.Spots[#HP.Spots + 1] = Vector(s[1], s[2], s[3])
		end
	end
end

function HP.SaveSpots()
	local out = {}
	for _, v in ipairs(HP.Spots) do out[#out + 1] = { v.x, v.y, v.z } end
	Veltrix.WriteJSON(SpotsPath(), out)
end

---------------------------------------------------------------- line of sight
local trOut = {}
local trData = { mask = MASK_OPAQUE, output = trOut, filter = {} }

local function Line(from, to, a, b)
	trData.start, trData.endpos = from, to
	trData.filter[1], trData.filter[2] = a, b
	util.TraceLine(trData)
	return not trOut.Hit
end

-- true if `ply` could see a standing player at `base` now, or within the next ~0.4s of movement
local function HasLOS(ply, base, ent)
	local eye = ply:EyePos()
	local vel = ply:GetVelocity()
	local e2, e3 = eye + vel * 0.2, eye + vel * 0.4
	for i = 1, #OFFSETS do
		local p = base + OFFSETS[i]
		if Line(eye, p, ply, ent) or Line(e2, p, ply, ent) or Line(e3, p, ply, ent) then return true end
	end
	return false
end

local function SetHiddenFor(d, ply, state)
	if d.Hidden[ply] == state then return end
	d.Hidden[ply] = state
	d:SetPreventTransmit(ply, state)
end

local function HideFromAll(d)
	for _, ply in ipairs(player.GetAll()) do
		d.Hidden[ply] = true
		d:SetPreventTransmit(ply, true)
	end
end

---------------------------------------------------------------- bot decoys
local function ConfigureBot(bot)
	bot:SetMoveType(MOVETYPE_NONE)
	bot:SetNotSolid(true)      -- no collisions, bullets and traces pass through: zero gameplay impact
	bot:SetNoTarget(true)
	bot:GodEnable()
	bot:StripWeapons()
	bot:SetModel(MODELS[math.random(#MODELS)])
end

local function CreateBot()
	local bot = player.CreateNextBot(NAMES[math.random(#NAMES)])
	if not IsValid(bot) then return nil end
	bot.VeltrixDecoy = true
	bot.Hidden = setmetatable({}, WEAK)
	HideFromAll(bot)
	timer.Simple(0, function() if IsValid(bot) then ConfigureBot(bot) end end)
	return bot
end

hook.Add("StartCommand", "Veltrix_DecoyCmd", function(ply, cmd)
	if ply.VeltrixDecoy then
		cmd:ClearMovement()
		cmd:ClearButtons()
	end
end)

hook.Add("PlayerSpawn", "Veltrix_DecoySpawn", function(ply)
	if ply.VeltrixDecoy then
		timer.Simple(0, function() if IsValid(ply) then ConfigureBot(ply) end end)
	end
end)

hook.Add("PlayerShouldTakeDamage", "Veltrix_DecoyGod", function(ply)
	if ply.VeltrixDecoy then return false end
end)

hook.Add("PlayerDeath", "Veltrix_DecoyRespawn", function(ply)
	if ply.VeltrixDecoy then
		timer.Simple(1, function() if IsValid(ply) and not ply:Alive() then ply:Spawn() end end)
	end
end)

-- Find open floor near `viewer` that is inside their PVS but has no line of sight to them.
local function FindSpot(viewer)
	local origin = viewer:GetPos()
	local minD = C("hp_radius")
	local maxD = math.max(minD + 100, math.min(C("hp_range"), 1500))

	for _ = 1, 14 do
		local a = math.Rand(0, math.pi * 2)
		local dist = math.Rand(minD, maxD)
		local p = origin + Vector(math.cos(a) * dist, math.sin(a) * dist, 64)

		local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.StartSolid and not tr.HitSky and tr.HitNormal.z > 0.7 then
			local pos = tr.HitPos + Vector(0, 0, 2)
			local hull = util.TraceHull({
				start = pos, endpos = pos, mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72), mask = MASK_PLAYERSOLID,
			})
			if not hull.Hit and util.IsInWorld(pos) and viewer:TestPVS(pos) and not HasLOS(viewer, pos, nil) then
				return pos
			end
		end
	end
	return nil
end

local function Eligible(p)
	return IsValid(p) and not p:IsBot() and not p.VeltrixDecoy and not Veltrix.SeesAll(p) and not Veltrix.NoScore(p)
end

local function Taken(p, me)
	for _, d in ipairs(HP.Decoys) do
		if d ~= me and IsValid(d) and d.Viewer == p then return true end
	end
	return false
end

local function AssignViewer(d, now)
	local players = player.GetAll()
	local n = #players
	d.Viewer = nil
	for _ = 1, n do
		rr = rr % n + 1
		local p = players[rr]
		if Eligible(p) and not Taken(p, d) then d.Viewer = p break end
	end
	d.Until = now + C("hp_rotate")
	for _, p in ipairs(players) do SetHiddenFor(d, p, true) end
end

local function TickBot(d, now)
	local v = d.Viewer
	if not Eligible(v) or now >= (d.Until or 0) then
		AssignViewer(d, now)
		v = d.Viewer
	end

	for _, p in ipairs(player.GetAll()) do
		if p ~= v then SetHiddenFor(d, p, true) end
	end
	if not IsValid(v) then return end

	local pos = d:GetPos()
	local good = v:GetPos():DistToSqr(pos) >= C("hp_radius") ^ 2 and v:TestPVS(pos) and not HasLOS(v, pos, d)
	if not good then
		SetHiddenFor(d, v, true)
		local np = FindSpot(v)
		if np then
			d:SetPos(np)
			d:SetEyeAngles(Angle(0, math.random(0, 359), 0))
			SetHiddenFor(d, v, false)
		end
	else
		SetHiddenFor(d, v, false)
	end
end

---------------------------------------------------------------- prop decoys (static mode)
local function SpawnProps()
	if #HP.Spots == 0 then return end
	local pool = {}
	for i, v in ipairs(HP.Spots) do pool[i] = v end

	for _ = 1, math.min(C("hp_count"), #pool) do
		local pos = table.remove(pool, math.random(#pool))
		local e = ents.Create("prop_dynamic")
		if IsValid(e) then
			e:SetModel(MODELS[math.random(#MODELS)])
			e:SetPos(pos)
			e:SetAngles(Angle(0, math.random(0, 359), 0))
			e:Spawn()
			e:SetSolid(SOLID_NONE)
			local seq = e:LookupSequence("idle_all_01")
			if seq >= 0 then e:ResetSequence(seq) end
			e.Hidden = setmetatable({}, WEAK)
			e.VeltrixDecoy = true
			HideFromAll(e)
			HP.Decoys[#HP.Decoys + 1] = e
		end
	end
end

local function TickProps(now)
	if now >= nextMove then
		nextMove = now + C("hp_move")
		for _, d in ipairs(HP.Decoys) do
			if IsValid(d) and #HP.Spots > 0 then
				HideFromAll(d)
				d:SetPos(HP.Spots[math.random(#HP.Spots)])
				d:SetAngles(Angle(0, math.random(0, 359), 0))
			end
		end
	end

	local radiusSq = C("hp_radius") ^ 2
	for _, ply in ipairs(player.GetAll()) do
		if not ply.VeltrixDecoy then
			local sees = Veltrix.SeesAll(ply)
			for _, d in ipairs(HP.Decoys) do
				if IsValid(d) then
					local hide = true
					if not sees then
						local dpos = d:GetPos()
						hide = ply:GetPos():DistToSqr(dpos) < radiusSq or HasLOS(ply, dpos, d)
					end
					SetHiddenFor(d, ply, hide)
				end
			end
		end
	end
end

---------------------------------------------------------------- lifecycle
function HP.RemoveDecoys()
	for _, d in ipairs(HP.Decoys) do
		if IsValid(d) then
			if d:IsPlayer() then d:Kick("Veltrix decoy removed") else d:Remove() end
		end
	end
	HP.Decoys = {}
end

function HP.ActiveCount()
	local n = 0
	for _, d in ipairs(HP.Decoys) do if IsValid(d) then n = n + 1 end end
	return n
end

function HP.Refresh()
	HP.RemoveDecoys()
	if not C("hp_enabled") then return end

	if C("hp_mode") == 1 then
		local made = 0
		for _ = 1, C("hp_count") do
			local b = CreateBot()
			if b then HP.Decoys[#HP.Decoys + 1] = b made = made + 1 end
		end
		if made < C("hp_count") and not warned then
			warned = true
			local msg = string.format("Honeypot: created %d of %d decoy bots. Bot decoys need free player slots (raise maxplayers).", made, C("hp_count"))
			Veltrix.Notify(msg, true)
			ServerLog("[Veltrix] " .. msg .. "\n")
		elseif made >= C("hp_count") then
			warned = false
		end
	else
		SpawnProps()
	end
end

local function HumanCount()
	local n = 0
	for _, p in ipairs(player.GetAll()) do
		if not p:IsBot() then n = n + 1 end
	end
	return n
end

timer.Create("Veltrix_HoneypotTick", 0.05, 0, function()
	if not C("hp_enabled") then
		if #HP.Decoys > 0 then HP.RemoveDecoys() end
		return
	end

	local now = CurTime()
	if HumanCount() == 0 then
		if #HP.Decoys > 0 then HP.RemoveDecoys() end
		return
	end

	-- (re)create decoys when missing, e.g. after a map change, a kicked bot, or the first player joining
	local want = C("hp_mode") == 1 and C("hp_count") or math.min(C("hp_count"), #HP.Spots)
	if HP.ActiveCount() < want and now >= nextEnsure then
		nextEnsure = now + 5
		HP.Refresh()
	end

	if C("hp_mode") == 1 then
		for _, d in ipairs(HP.Decoys) do
			if IsValid(d) then TickBot(d, now) end
		end
	else
		TickProps(now)
	end
end)

---------------------------------------------------------------- per-usercmd detection
-- Called from sv_aim.lua's StartCommand for every command a player sends, using the angles in the usercmd itself.
-- That is what the server actually uses to fire, so a one-tick silent-aim shot at a hidden decoy is visible here.
function HP.OnCmd(ply, cmd, ang, attack, now)
	if ply.VeltrixDecoy or #HP.Decoys == 0 then return end

	local t = track[ply]
	if not t then t = { lockStart = nil, lastIn = 0, cd = 0, fireCd = 0 } track[ply] = t end

	local eye = ply:EyePos()
	local fwd = ang:Forward()
	local rangeSq = C("hp_range") ^ 2
	local cosA = math.cos(math.rad(C("hp_angle")))
	local inCone, fired, dist = false, false, 0

	for _, d in ipairs(HP.Decoys) do
		if IsValid(d) and d.Hidden and d.Hidden[ply] == false then
			local to = d:GetPos() + CHEST - eye
			local dsq = to:LengthSqr()
			if dsq > 1 and dsq < rangeSq and d:TestPVS(ply) then
				local len = math.sqrt(dsq)
				local dot = fwd:Dot(to) / len
				if dot > cosA then inCone, dist = true, len end
				if attack and dot > 0 and len * math.sqrt(math.max(0, 1 - dot * dot)) < HIT_RADIUS then
					fired, dist = true, len
				end
			end
		end
	end

	if fired and C("decoy_fire_enabled") and (not C("decoy_require_attack_edge") or (attack and not t.wasAttack)) and now >= t.fireCd then
		t.fireCd = now + 1
		Veltrix.Suspect(ply, "decoy", C("hp_fire_points"),
			string.format("Fired at a hidden decoy through walls (%dm away)", math.floor(dist / 52.49)))
	end

	if inCone and C("decoy_track_enabled") then
		t.lastIn = now
		t.lockStart = t.lockStart or now
		if now >= t.cd and now - t.lockStart >= C("hp_lock") then
			t.lockStart, t.cd = nil, now + C("hp_cooldown")
			Veltrix.Suspect(ply, "decoy", C("hp_points"),
				string.format("Tracked a hidden decoy through walls for %.1fs (%dm away)", C("hp_lock"), math.floor(dist / 52.49)))
		end
	elseif t.lockStart and now - t.lastIn > 0.15 then
		t.lockStart = nil
	end
	t.wasAttack = attack and true or false
end

---------------------------------------------------------------- hooks
hook.Add("InitPostEntity", "Veltrix_HPInit", function()
	HP.LoadSpots()
	nextMove = CurTime() + C("hp_move")
end)

hook.Add("PostCleanupMap", "Veltrix_HPCleanup", function()
	HP.Decoys = {}
end)

hook.Add("PlayerInitialSpawn", "Veltrix_HPJoin", function(ply)
	for _, d in ipairs(HP.Decoys) do
		if IsValid(d) and d.Hidden then
			d.Hidden[ply] = true
			d:SetPreventTransmit(ply, true)
		end
	end
end)

hook.Add("PlayerDisconnected", "Veltrix_HPLeave", function(ply)
	track[ply] = nil
	for _, d in ipairs(HP.Decoys) do
		if IsValid(d) and d.Hidden then d.Hidden[ply] = nil end
	end
end)

if CurTime() > 5 then HP.LoadSpots() end

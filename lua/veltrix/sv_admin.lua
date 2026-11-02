if not SERVER then return end

local function Limiter(gap)
	local last = setmetatable({}, { __mode = "k" })
	return function(ply)
		local now = CurTime()
		if (last[ply] or 0) > now then return false end
		last[ply] = now + gap
		return true
	end
end

local reqLimit, doLimit = Limiter(0.4), Limiter(0.15)

---------------------------------------------------------------- opening the menu
local function Open(ply)
	if not Veltrix.IsAdmin(ply) then
		ply:ChatPrint("[Veltrix] You do not have access.")
		return
	end
	net.Start("Veltrix_Open")
	net.Send(ply)
end

concommand.Add("veltrix", function(ply) if IsValid(ply) then Open(ply) end end)
concommand.Add("veltrix_menu", function(ply) if IsValid(ply) then Open(ply) end end)

hook.Add("PlayerSay", "Veltrix_ChatCmd", function(ply, text)
	local t = string.lower(string.Trim(text))
	if t == "!veltrix" or t == "/veltrix" then
		Open(ply)
		return ""
	end
end)

---------------------------------------------------------------- state sync
local function BuildState(ply)
	local plist = {}
	for _, p in ipairs(player.GetAll()) do
		local st = Veltrix.GetState(p)
		Veltrix.Decay(st)
		plist[#plist + 1] = {
			id = p:UserID(), name = p:Nick(), sid = p:SteamID(), ping = p:Ping(),
			score = math.Round(st.score, 2), flags = st.flags,
			wl = Veltrix.IsWhitelisted(p), bot = p:IsBot(), decoy = p.VeltrixDecoy == true,
		}
	end

	local log, buf = {}, Veltrix.LogBuf
	for i = #buf, math.max(1, #buf - 99), -1 do log[#log + 1] = buf[i] end

	local spots = {}
	for i, v in ipairs(Veltrix.HP.Spots) do spots[i] = { v.x, v.y, v.z } end

	return {
		version = Veltrix.Version, map = game.GetMap(), super = Veltrix.IsSuper(ply),
		players = plist, log = log, spots = spots, cfg = Veltrix.Config,
		decoys = Veltrix.HP.ActiveCount(),
		stats = { occMs = Veltrix.Stats.occMs, traces = Veltrix.Stats.traces },
	}
end

local function SendState(ply)
	local s = BuildState(ply)
	local json = util.Compress(util.TableToJSON(s))
	if #json > 60000 then
		s.log = {}
		json = util.Compress(util.TableToJSON(s))
	end
	net.Start("Veltrix_State")
		net.WriteUInt(#json, 16)
		net.WriteData(json, #json)
	net.Send(ply)
end

net.Receive("Veltrix_Req", function(_, ply)
	if not Veltrix.IsAdmin(ply) or not reqLimit(ply) then return end
	SendState(ply)
end)

---------------------------------------------------------------- actions
local Actions = {}

local function ByUserID(id)
	id = tonumber(id)
	if not id then return nil end
	for _, p in ipairs(player.GetAll()) do
		if p:UserID() == id then return p end
	end
end

local function Audit(ply, text)
	ServerLog(string.format("[Veltrix] %s (%s): %s\n", ply:Nick(), ply:SteamID(), text))
end

local function CanModerate(ply, target)
	if target == ply then
		Veltrix.Notify("You can't do that to yourself.", false, { ply })
		return false
	end
	if Veltrix.IsAdmin(target) and not Veltrix.IsSuper(ply) then
		Veltrix.Notify("Only superadmins can act on other admins.", false, { ply })
		return false
	end
	return true
end

local function NeedSuper(ply)
	if Veltrix.IsSuper(ply) then return true end
	Veltrix.Notify("That action needs superadmin.", false, { ply })
	return false
end

Actions.reset_score = function(ply, a)
	local t = ByUserID(a.id)
	if not t then return end
	Veltrix.GetState(t).score = 0
	Audit(ply, "reset score of " .. t:Nick())
end

Actions.whitelist = function(ply, a)
	local t = ByUserID(a.id)
	if not t then return end
	local state = not Veltrix.IsWhitelisted(t)
	Veltrix.SetWhitelisted(t, state)
	if state then Veltrix.GetState(t).score = 0 end
	Audit(ply, (state and "whitelisted " or "un-whitelisted ") .. t:Nick())
end

Actions.kick = function(ply, a)
	local t = ByUserID(a.id)
	if not t or not CanModerate(ply, t) then return end
	Audit(ply, "kicked " .. t:Nick())
	t:Kick("Kicked by " .. ply:Nick() .. " (Veltrix)")
end

Actions.ban = function(ply, a)
	if not NeedSuper(ply) then return end
	local t = ByUserID(a.id)
	local mins = tonumber(a.minutes)
	if not t or not mins or not CanModerate(ply, t) then return end
	mins = math.Clamp(math.floor(mins), 1, 525600)
	Audit(ply, string.format("banned %s for %d minutes", t:Nick(), mins))
	t:Ban(mins, true)
end

Actions.clear_log = function(ply)
	if not NeedSuper(ply) then return end
	Veltrix.LogBuf = {}
	file.Delete("veltrix/log.txt")
	Audit(ply, "cleared the log")
end

Actions.cfg = function(ply, a)
	if not NeedSuper(ply) then return end
	local hpChanged, occOff = false, false
	for k, v in pairs(a) do
		local s = Veltrix.SchemaByKey[k]
		if s then
			local nv = Veltrix.Sanitize(s, v)
			if nv ~= nil and Veltrix.Config[k] ~= nv then
				Veltrix.Config[k] = nv
				if string.sub(k, 1, 3) == "hp_" then hpChanged = true end
				if k == "occ_enabled" and nv == false then occOff = true end
			end
		end
	end
	Veltrix.SaveConfig()
	if occOff then Veltrix.OcclusionReset() end
	if hpChanged then Veltrix.HP.Refresh() end
	Audit(ply, "changed settings")
	Veltrix.Notify("Settings saved.", false, { ply })
end

Actions.spot_add = function(ply, a)
	if not NeedSuper(ply) then return end
	local pos
	if a.mode == "aim" then
		local tr = ply:GetEyeTrace()
		if not tr.Hit then return end
		pos = tr.HitPos
	else
		pos = ply:GetPos()
	end
	table.insert(Veltrix.HP.Spots, pos)
	Veltrix.HP.SaveSpots()
	Veltrix.HP.Refresh()
	Audit(ply, "added a decoy spot")
end

Actions.spot_remove = function(ply, a)
	if not NeedSuper(ply) then return end
	local i = tonumber(a.index)
	if not i or not Veltrix.HP.Spots[math.floor(i)] then return end
	table.remove(Veltrix.HP.Spots, math.floor(i))
	Veltrix.HP.SaveSpots()
	Veltrix.HP.Refresh()
	Audit(ply, "removed a decoy spot")
end

Actions.hp_respawn = function(ply)
	if not NeedSuper(ply) then return end
	Veltrix.HP.Refresh()
end

net.Receive("Veltrix_Do", function(_, ply)
	if not Veltrix.IsAdmin(ply) or not doLimit(ply) then return end
	local act = net.ReadString()
	local arg = net.ReadTable()
	if type(arg) ~= "table" then arg = {} end
	local handler = Actions[act]
	if not handler then return end
	handler(ply, arg)
	SendState(ply)
end)

if not SERVER then return end

for _, n in ipairs({ "Veltrix_Open", "Veltrix_Req", "Veltrix_State", "Veltrix_Alert", "Veltrix_Do" }) do
	util.AddNetworkString(n)
end

file.CreateDir("veltrix")

local LOG_MAX = 300

Veltrix.Whitelist = {}
Veltrix.History   = {}
Veltrix.LogBuf    = {}
Veltrix.State     = setmetatable({}, { __mode = "k" })
Veltrix.Stats     = { occMs = 0, traces = 0 }

---------------------------------------------------------------- storage
function Veltrix.ReadJSON(path, default)
	if not file.Exists(path, "DATA") then return default end
	local t = util.JSONToTable(file.Read(path, "DATA") or "")
	if type(t) ~= "table" then return default end
	return t
end

function Veltrix.WriteJSON(path, t)
	file.Write(path, util.TableToJSON(t, true))
end

---------------------------------------------------------------- config
-- Returns a clamped value of the right type, or nil if v is the wrong type.
function Veltrix.Sanitize(s, v)
	if s.type == "bool" then
		if type(v) == "boolean" then return v end
		return nil
	end
	if type(v) ~= "number" or v ~= v then return nil end
	return math.Round(math.Clamp(v, s.min, s.max), s.dec or 0)
end

function Veltrix.LoadConfig()
	local saved = Veltrix.ReadJSON("veltrix/config.json", {})
	for _, s in ipairs(Veltrix.Schema) do
		local v = Veltrix.Sanitize(s, saved[s.key])
		if v == nil then v = s.def end
		Veltrix.Config[s.key] = v
	end
end

function Veltrix.SaveConfig()
	Veltrix.WriteJSON("veltrix/config.json", Veltrix.Config)
end

---------------------------------------------------------------- permissions
-- Integrate with ULX/SAM/CAMI by returning true/false from this hook:
--   hook.Add("Veltrix_CanAccess", "mine", function(ply, level) return ply:query("veltrix") end)
-- level is "admin" (view/moderate) or "super" (change settings, ban, edit spots).
function Veltrix.IsAdmin(ply)
	if not IsValid(ply) then return false end
	local r = hook.Run("Veltrix_CanAccess", ply, "admin")
	if r ~= nil then return r and true or false end
	return ply:IsAdmin()
end

function Veltrix.IsSuper(ply)
	if not IsValid(ply) then return false end
	local r = hook.Run("Veltrix_CanAccess", ply, "super")
	if r ~= nil then return r and true or false end
	return ply:IsSuperAdmin()
end

function Veltrix.GetAdmins()
	local out = {}
	for _, p in ipairs(player.GetAll()) do
		if Veltrix.IsAdmin(p) then out[#out + 1] = p end
	end
	return out
end

---------------------------------------------------------------- exemptions
function Veltrix.IsWhitelisted(ply)
	return Veltrix.Whitelist[ply:SteamID()] ~= nil
end

function Veltrix.SetWhitelisted(ply, state)
	Veltrix.Whitelist[ply:SteamID()] = state and ply:Nick() or nil
	Veltrix.WriteJSON("veltrix/whitelist.json", Veltrix.Whitelist)
end

-- Players who should receive everything (dead, spectating, noclip, camera view, exempt admins)
function Veltrix.SeesAll(ply)
	if not ply:Alive() then return true end
	if ply:GetObserverMode() ~= OBS_MODE_NONE then return true end
	if ply:GetMoveType() == MOVETYPE_NOCLIP and not ply:InVehicle() then return true end
	if ply:GetViewEntity() ~= ply then return true end
	if Veltrix.Cfg("exempt_admins") and Veltrix.IsAdmin(ply) then return true end
	return false
end

-- Players who never accumulate suspicion
function Veltrix.NoScore(ply)
	if ply:IsBot() then return true end
	if Veltrix.IsWhitelisted(ply) then return true end
	if Veltrix.Cfg("exempt_admins") and Veltrix.IsAdmin(ply) then return true end
	return false
end

---------------------------------------------------------------- notifications
function Veltrix.Notify(text, alarm, targets)
	targets = targets or Veltrix.GetAdmins()
	if #targets == 0 then return end
	net.Start("Veltrix_Alert")
		net.WriteString(text)
		net.WriteBool(alarm or false)
	net.Send(targets)
end

---------------------------------------------------------------- log
function Veltrix.AddLog(e)
	local buf = Veltrix.LogBuf
	buf[#buf + 1] = e
	if #buf > LOG_MAX then table.remove(buf, 1) end
	file.Append("veltrix/log.txt", util.TableToJSON(e) .. "\n")
end

local function LoadLog()
	if not file.Exists("veltrix/log.txt", "DATA") then return end
	local lines = string.Split(file.Read("veltrix/log.txt", "DATA") or "", "\n")
	for i = math.max(1, #lines - LOG_MAX + 1), #lines do
		local e = util.JSONToTable(lines[i] or "")
		if type(e) == "table" then Veltrix.LogBuf[#Veltrix.LogBuf + 1] = e end
	end
	-- rotate: rewrite the file with only the kept entries once it gets large
	if file.Size("veltrix/log.txt", "DATA") > 512 * 1024 then
		file.Delete("veltrix/log.txt")
		for _, e in ipairs(Veltrix.LogBuf) do
			file.Append("veltrix/log.txt", util.TableToJSON(e) .. "\n")
		end
	end
end

---------------------------------------------------------------- suspicion
function Veltrix.GetState(ply)
	local st = Veltrix.State[ply]
	if not st then
		local h = Veltrix.History[ply:SteamID()]
		st = { score = 0, flags = h and h.flags or 0, lastAlert = -1e9, decayAt = CurTime() }
		Veltrix.State[ply] = st
	end
	return st
end

function Veltrix.Decay(st)
	local now = CurTime()
	st.score = math.max(0, st.score - Veltrix.Cfg("flag_decay") * (now - st.decayAt) / 60)
	st.decayAt = now
end

function Veltrix.Punish(ply, act)
	local st = Veltrix.GetState(ply)
	st.score = 0
	local what = act == 2 and "banned" or "kicked"
	Veltrix.Notify(string.format("Automatically %s %s (%s) for suspicious activity.", what, ply:Nick(), ply:SteamID()), true)
	ServerLog(string.format("[Veltrix] auto-%s %s (%s)\n", what, ply:Nick(), ply:SteamID()))
	if act == 2 then
		ply:Ban(Veltrix.Cfg("flag_ban_minutes"), true)
	else
		ply:Kick("Kicked by Veltrix anti-cheat (suspicious activity)")
	end
end

-- Every detector reports through this. src = short tag, pts = suspicion points, detail = human readable.
function Veltrix.Suspect(ply, src, pts, detail)
	if not IsValid(ply) or Veltrix.NoScore(ply) then return end

	local st = Veltrix.GetState(ply)
	Veltrix.Decay(st)
	st.score = st.score + pts

	local e = {
		t = os.time(), name = ply:Nick(), sid = ply:SteamID(), src = src, pts = pts,
		score = math.Round(st.score, 2), detail = string.sub(detail or "", 1, 200),
	}
	Veltrix.AddLog(e)
	hook.Run("Veltrix_Event", ply, e)

	local now = CurTime()
	if st.score >= Veltrix.Cfg("flag_alert") and now - st.lastAlert > 120 then
		st.lastAlert = now
		st.flags = st.flags + 1
		Veltrix.History[e.sid] = { name = e.name, flags = st.flags, last = e.t }
		Veltrix.WriteJSON("veltrix/history.json", Veltrix.History)

		local msg = string.format("%s (%s) reached suspicion score %.1f. Latest: [%s] %s", e.name, e.sid, st.score, src, e.detail)
		Veltrix.Notify(msg, true)
		ServerLog("[Veltrix] " .. msg .. "\n")
		hook.Run("Veltrix_Flagged", ply, st.score, e)
	end

	local act = Veltrix.Cfg("flag_action")
	if act > 0 and st.score >= Veltrix.Cfg("flag_action_at") then
		Veltrix.Punish(ply, act)
	end
end

hook.Add("PlayerDisconnected", "Veltrix_CoreCleanup", function(ply)
	Veltrix.State[ply] = nil
end)

---------------------------------------------------------------- init
Veltrix.LoadConfig()
Veltrix.Whitelist = Veltrix.ReadJSON("veltrix/whitelist.json", {})
Veltrix.History   = Veltrix.ReadJSON("veltrix/history.json", {})
LoadLog()

MsgC(Color(90, 170, 255), "[Veltrix] ", color_white, "Anti-cheat v" .. Veltrix.Version .. " loaded. Type !veltrix in chat as an admin.\n")

if not CLIENT then return end

Veltrix = Veltrix or {}

local State, Frame
local BLUE = Color(65, 150, 235)
local BG = Color(23, 28, 37)
local CARD = Color(34, 41, 53)
local MUTED = Color(169, 184, 201)

local function SectionTitle(parent, heading, subtitle)
    local title = vgui.Create("DLabel", parent)
    title:Dock(TOP)
    title:DockMargin(12, 10, 12, 0)
    title:SetFont("DermaLarge")
    title:SetTextColor(BLUE)
    title:SetText(heading)
    title:SizeToContents()
    if subtitle then
        local note = vgui.Create("DLabel", parent)
        note:Dock(TOP)
        note:DockMargin(12, 3, 12, 10)
        note:SetDark(true)
        note:SetWrap(true)
        note:SetAutoStretchVertical(true)
        note:SetText(subtitle)
    end
end

local function BuildOverview(parent, frame)
    local pnl = vgui.Create("DScrollPanel", parent)
    SectionTitle(pnl, "Security overview", "Live server snapshot. Select a tab to investigate players, view detections, or change configuration.")
    local cards = {}
    for _, item in ipairs({
        { "Players online", "players" },
        { "Players over alert level", "alerts" },
        { "Recent event records", "events" },
        { "Active decoys", "decoys" }
    }) do
        local card = vgui.Create("DPanel", pnl)
        card:Dock(TOP)
        card:DockMargin(12, 4, 12, 4)
        card:SetTall(65)
        card.Paint = function(_, w, h)
            draw.RoundedBox(8, 0, 0, w, h, CARD)
            surface.SetDrawColor(60, 100, 145, 120)
            surface.DrawRect(0, 0, 4, h)
        end
        local label = vgui.Create("DLabel", card)
        label:Dock(LEFT)
        label:SetWide(250)
        label:DockMargin(16, 0, 4, 0)
        label:SetFont("DermaDefaultBold")
        label:SetTextColor(MUTED)
        label:SetText(item[1])
        local count = vgui.Create("DLabel", card)
        count:Dock(FILL)
        count:SetFont("DermaLarge")
        count:SetTextColor(color_white)
        count:SetText("—")
        cards[item[2]] = count
    end
    local help = vgui.Create("DLabel", pnl)
    help:Dock(TOP)
    help:DockMargin(12, 12, 12, 8)
    help:SetWrap(true)
    help:SetAutoStretchVertical(true)
    help:SetDark(true)
    help:SetText("Detection signals are not conclusive proof of cheating. Review server-side evidence and rule out gamemode conflicts before taking action. Settings changes require superadmin permissions.")
    return pnl, function()
        if not State then return end
        local players, alerts = 0, 0
        for _, player in ipairs(State.players or {}) do
            if not player.decoy then
                players = players + 1
                if (player.score or 0) >= ((State.cfg or {}).flag_alert or math.huge) then alerts = alerts + 1 end
            end
        end
        cards.players:SetText(tostring(players))
        cards.alerts:SetText(tostring(alerts))
        cards.events:SetText(tostring(#(State.log or {})))
        cards.decoys:SetText(tostring(State.decoys or 0))
    end
end
local UNIT_TO_M = 52.49

---------------------------------------------------------------- net
local function Send(act, args)
	net.Start("Veltrix_Do")
		net.WriteString(act)
		net.WriteTable(args or {})
	net.SendToServer()
end

local function Request()
	net.Start("Veltrix_Req")
	net.SendToServer()
end

net.Receive("Veltrix_State", function()
	local len = net.ReadUInt(16)
	local raw = net.ReadData(len)
	local json = raw and util.Decompress(raw)
	State = json and util.JSONToTable(json) or State
	if State and IsValid(Frame) then Frame:Refresh() end
end)

net.Receive("Veltrix_Alert", function()
	local txt, alarm = net.ReadString(), net.ReadBool()
	chat.AddText(Color(90, 170, 255), "[Veltrix] ", alarm and Color(255, 200, 80) or color_white, txt)
	if alarm then surface.PlaySound("buttons/button10.wav") end
end)

net.Receive("Veltrix_Open", function() Veltrix.OpenMenu() end)

---------------------------------------------------------------- helpers
local function Info(parent, text)
	local l = vgui.Create("DLabel", parent)
	l:SetDark(true)
	l:SetWrap(true)
	l:SetAutoStretchVertical(true)
	l:SetText(text)
	l:Dock(TOP)
	l:DockMargin(6, 6, 6, 2)
	return l
end

local function Button(parent, text, dock, fn, w)
	local b = vgui.Create("DButton", parent)
	b:SetText(text)
	b:Dock(dock)
	b:SetWide(w or 150)
	b:DockMargin(2, 2, 2, 2)
	b.DoClick = fn
	return b
end

---------------------------------------------------------------- players tab
local function BuildPlayers(sheet, frame)
	local pnl = vgui.Create("DPanel", sheet)
	pnl:SetPaintBackground(false)

	SectionTitle(pnl, "Player monitoring", "Right-click a player to inspect events or perform an admin action. Red rows indicate the configured alert threshold, not a confirmed cheat.")

	local list = vgui.Create("DListView", pnl)
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list:AddColumn("Player")
	list:AddColumn("SteamID"):SetFixedWidth(150)
	list:AddColumn("Ping"):SetFixedWidth(50)
	list:AddColumn("Score"):SetFixedWidth(60)
	list:AddColumn("Flags"):SetFixedWidth(50)
	list:AddColumn("Status"):SetFixedWidth(100)
	list.byId = {}

	list.OnRowRightClick = function(_, _, line)
		local p = line.p
		if not p then return end
		local m = DermaMenu()
		m:AddOption("Copy SteamID", function() SetClipboardText(p.sid) end):SetIcon("icon16/page_copy.png")
		m:AddOption("View events", function()
			frame.logFilter:SetValue(p.name)
			frame.sheet:SetActiveTab(frame.logTab.Tab)
			frame.logKey = nil
			frame:Refresh()
		end):SetIcon("icon16/book_open.png")
		m:AddOption("Reset score", function() Send("reset_score", { id = p.id }) end):SetIcon("icon16/arrow_refresh.png")
		m:AddOption(p.wl and "Remove from whitelist" or "Whitelist (never scored)", function()
			Send("whitelist", { id = p.id })
		end):SetIcon("icon16/shield.png")
		m:AddSpacer()
		m:AddOption("Kick", function()
			Derma_Query("Kick " .. p.name .. "?", "Confirm", "Kick", function() Send("kick", { id = p.id }) end, "Cancel")
		end):SetIcon("icon16/door_out.png")
		if State and State.super then
			m:AddOption("Ban...", function()
				Derma_StringRequest("Ban " .. p.name, "Ban length in minutes:", "60", function(txt)
					local n = tonumber(txt)
					if n then Send("ban", { id = p.id, minutes = n }) end
				end)
			end):SetIcon("icon16/cancel.png")
		end
		m:Open()
	end

	local function refresh()
		local seen = {}
		for _, p in ipairs(State.players) do
			seen[p.id] = true
			local line = list.byId[p.id]
			if not IsValid(line) then
				line = list:AddLine(p.name, p.sid, tostring(p.ping), "", tostring(p.flags), "")
				list.byId[p.id] = line
				line.PaintOver = function(s, w, h)
					if s.p and State and State.cfg and s.p.score >= State.cfg.flag_alert then
						surface.SetDrawColor(255, 40, 40, 45)
						surface.DrawRect(0, 0, w, h)
					end
				end
			end
			line.p = p
			line:SetColumnText(1, p.name)
			line:SetColumnText(2, p.sid)
			line:SetColumnText(3, tostring(p.ping))
			line:SetColumnText(4, string.format("%.1f", p.score))
			line:SetColumnText(5, tostring(p.flags))
			line:SetColumnText(6, p.decoy and "Decoy bot" or (p.wl and "Whitelisted" or (p.bot and "Bot" or "")))
			line:SetSortValue(3, p.ping)
			line:SetSortValue(4, p.score)
			line:SetSortValue(5, p.flags)
		end
		for id, line in pairs(list.byId) do
			if not seen[id] then
				if IsValid(line) then list:RemoveLine(line:GetID()) end
				list.byId[id] = nil
			end
		end
	end

	return pnl, refresh
end

---------------------------------------------------------------- log tab
local function BuildLog(sheet, frame)
	local pnl = vgui.Create("DPanel", sheet)
	pnl:SetPaintBackground(false)

	SectionTitle(pnl, "Detection events", "Search event history and inspect evidence before taking action.")
	local bar = vgui.Create("DPanel", pnl)
	bar:Dock(TOP)
	bar:SetTall(32)
	bar:SetPaintBackground(false)

	local clear = Button(bar, "Clear log", RIGHT, function()
		Derma_Query("Delete the whole event log?", "Confirm", "Delete", function() Send("clear_log") end, "Cancel")
	end, 90)

	local filter = vgui.Create("DTextEntry", bar)
	filter:Dock(FILL)
	filter:SetPlaceholderText("Filter by player, SteamID, source or detail...")
	filter.OnChange = function() frame.logKey = nil frame:Refresh() end
	frame.logFilter = filter

	local list = vgui.Create("DListView", pnl)
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list:AddColumn("Time"):SetFixedWidth(110)
	list:AddColumn("Player"):SetFixedWidth(130)
	list:AddColumn("SteamID"):SetFixedWidth(140)
	list:AddColumn("Source"):SetFixedWidth(70)
	list:AddColumn("Pts"):SetFixedWidth(40)
	list:AddColumn("Score"):SetFixedWidth(50)
	list:AddColumn("Detail")
	list.OnRowRightClick = function(_, _, line)
		local m = DermaMenu()
		m:AddOption("Copy SteamID", function() SetClipboardText(line:GetColumnText(3)) end):SetIcon("icon16/page_copy.png")
		m:AddOption("Copy detail", function() SetClipboardText(line:GetColumnText(7)) end):SetIcon("icon16/page_copy.png")
		m:Open()
	end

	local function refresh()
		local f = string.lower(filter:GetValue() or "")
		local key = #State.log .. ":" .. (State.log[1] and (State.log[1].t .. State.log[1].score) or "") .. "|" .. f
		if frame.logKey == key then return end
		frame.logKey = key

		list:Clear()
		for _, e in ipairs(State.log) do
			local hay = string.lower(e.name .. " " .. e.sid .. " " .. e.src .. " " .. e.detail)
			if f == "" or string.find(hay, f, 1, true) then
				list:AddLine(os.date("%d/%m %H:%M:%S", e.t), e.name, e.sid, e.src, tostring(e.pts), string.format("%.1f", e.score), e.detail)
			end
		end
		clear:SetEnabled(State.super)
	end

	return pnl, refresh
end

---------------------------------------------------------------- settings tab
local function BuildSettings(sheet, frame)
	local pnl = vgui.Create("DPanel", sheet)
	pnl:SetPaintBackground(false)

	local note = Info(pnl, "")
    local tools = vgui.Create("DPanel", pnl)
    tools:Dock(TOP)
    tools:SetTall(34)
    tools:SetPaintBackground(false)
    local categories = { "All categories" }
    local known = {}
    for _, setting in ipairs(Veltrix.Schema) do
        if not known[setting.cat] then
            categories[#categories + 1] = setting.cat
            known[setting.cat] = true
        end
    end
    local category = vgui.Create("DComboBox", tools)
    category:Dock(LEFT)
    category:SetWide(230)
    category:DockMargin(6, 2, 5, 2)
    category:SetValue("All categories")
    for _, name in ipairs(categories) do category:AddChoice(name) end
    local search = vgui.Create("DTextEntry", tools)
    search:Dock(FILL)
    search:DockMargin(0, 2, 6, 2)
    search:SetPlaceholderText("Search settings by name, category or description...")
    local scroll = vgui.Create("DScrollPanel", pnl)
	scroll:Dock(FILL)

	local pending, ctls, loading = {}, {}, false
    local sections = {}
    local lastCat

	for _, s in ipairs(Veltrix.Schema) do
		if s.cat ~= lastCat then
			lastCat = s.cat
			local h = vgui.Create("DLabel", scroll)
			h:Dock(TOP)
			h:DockMargin(6, 12, 6, 4)
			h:SetFont("DermaDefaultBold")
			h:SetTextColor(BLUE)
			h:SetText(s.cat)
			h:SizeToContents()
            sections[s.cat] = { header = h, controls = {} }
		end

		local ctl
		if s.type == "bool" then
			ctl = vgui.Create("DCheckBoxLabel", scroll)
			ctl:SetText(s.label)
			ctl:SetDark(true)
			ctl:SetValue(s.def)
			ctl:Dock(TOP)
			ctl:DockMargin(10, 4, 6, 4)
			ctl.OnChange = function(_, v) if not loading then pending[s.key] = v end end
		else
			ctl = vgui.Create("DNumSlider", scroll)
			ctl:SetText(s.label)
			ctl:SetDark(true)
			ctl:SetMin(s.min)
			ctl:SetMax(s.max)
			ctl:SetDecimals(s.dec or 0)
			ctl:SetValue(s.def)
			ctl:SetTall(24)
			ctl:Dock(TOP)
			ctl:DockMargin(10, 0, 6, 0)
			ctl.OnValueChanged = function(_, v)
				if not loading then pending[s.key] = math.Round(v, s.dec or 0) end
			end
		end
		if s.help and s.help ~= "" then ctl:SetTooltip(s.help) end
		ctls[s.key] = ctl
        sections[s.cat].controls[#sections[s.cat].controls + 1] = { panel = ctl, schema = s }
	end

    local function updateVisibility()
        local query = string.Trim(string.lower(search:GetValue() or ""))
        local selected = category:GetValue() or "All categories"
        for name, section in pairs(sections) do
            local any = false
            local categoryMatch = selected == "All categories" or selected == name
            for _, item in ipairs(section.controls) do
                local schema = item.schema
                local hay = string.lower((schema.label or "") .. " " .. (schema.help or "") .. " " .. name .. " " .. schema.key)
                local visible = categoryMatch and (query == "" or string.find(hay, query, 1, true) ~= nil)
                item.panel:SetVisible(visible)
                if visible then any = true end
            end
            section.header:SetVisible(any)
        end
        scroll:InvalidateLayout(true)
    end
    search.OnChange = updateVisibility
    category.OnSelect = function() updateVisibility() end

	local bottom = vgui.Create("DPanel", pnl)
	bottom:Dock(BOTTOM)
	bottom:SetTall(32)
	bottom:SetPaintBackground(false)

	local function apply()
		loading = true
		for key, ctl in pairs(ctls) do
			local v = State.cfg[key]
			if v ~= nil then ctl:SetValue(v) end
		end
		loading = false
		pending = {}
	end

	local save = Button(bottom, "Save settings", LEFT, function()
		if table.Count(pending) == 0 then return end
		Send("cfg", pending)
		pending = {}
	end, 150)
	Button(bottom, "Discard changes", LEFT, function() if State then apply() end end, 150)

	local first = true
	local function refresh()
		if first then apply() first = false end
		save:SetEnabled(State.super and table.Count(pending) > 0)
        note:SetText(State.super and ("Settings / " .. tostring(table.Count(pending)) .. " unsaved change(s). Hover an option for help; click Save to apply.")
            or "View only — a superadmin is required to modify settings.")
	end

	return pnl, refresh
end

---------------------------------------------------------------- decoy tab
local function BuildDecoy(sheet, frame)
	local pnl = vgui.Create("DPanel", sheet)
	pnl:SetPaintBackground(false)

	local info = Info(pnl, "")
	local status = Info(pnl, "")

	local bar = vgui.Create("DPanel", pnl)
	bar:Dock(BOTTOM)
	bar:SetTall(32)
	bar:SetPaintBackground(false)

	local list = vgui.Create("DListView", pnl)
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list:AddColumn("#"):SetFixedWidth(40)
	list:AddColumn("Position")
	list:AddColumn("Distance from you"):SetFixedWidth(130)

	Button(bar, "Add at my position", LEFT, function() Send("spot_add", { mode = "pos" }) end, 140)
	Button(bar, "Add at crosshair", LEFT, function() Send("spot_add", { mode = "aim" }) end, 130)
	Button(bar, "Remove selected", LEFT, function()
		local id = list:GetSelectedLine()
		local line = id and list:GetLine(id)
		if line then Send("spot_remove", { index = tonumber(line:GetColumnText(1)) }) end
	end, 130)
	Button(bar, "Respawn decoys", LEFT, function() Send("hp_respawn") end, 120)

	local show = vgui.Create("DCheckBoxLabel", bar)
	show:Dock(RIGHT)
	show:SetWide(190)
	show:DockMargin(4, 8, 4, 4)
	show:SetText("Show spots in world")
	show:SetDark(true)
	show:SetValue(Veltrix.ShowSpots and 1 or 0)
	show.OnChange = function(_, v) Veltrix.ShowSpots = v end

	local function refresh()
		local flat = {}
		for _, s in ipairs(State.spots) do flat[#flat + 1] = s[1] .. "," .. s[2] .. "," .. s[3] end
		local key = table.concat(flat, ";")
		if frame.hpKey ~= key then
			frame.hpKey = key
			list:Clear()
			local me = LocalPlayer():GetPos()
			for i, s in ipairs(State.spots) do
				local d = math.floor(me:Distance(Vector(s[1], s[2], s[3])) / UNIT_TO_M)
				list:AddLine(tostring(i), string.format("%d, %d, %d", s[1], s[2], s[3]), d .. " m")
			end
		end
		local msg = string.format("Map: %s | Spots: %d | Active decoys: %d", State.map, #State.spots, State.decoys)
		if #State.spots == 0 then msg = msg .. " | Add at least one spot to enable decoys on this map." end
		status:SetText(msg)
		if State.cfg.hp_mode == 1 then
			info:SetText("Bot mode: decoy bots roam the map automatically, testing one player at a time, placed out of that player's sight but inside their PVS. No setup needed. The bots take player slots and show as 'Decoy bot' in the Players tab. Spots below are not used in this mode.")
		else
			info:SetText("Static mode: decoy props sit at the spots below. Put spots in OPEN space the players can't see (hidden rooms, behind map geometry), never inside solid walls, because the engine does not network entities that are inside solid space.")
		end
	end

	return pnl, refresh
end

---------------------------------------------------------------- frame
function Veltrix.OpenMenu()
	if IsValid(Frame) then Frame:Remove() end

	Frame = vgui.Create("DFrame")
	Frame:SetTitle("Veltrix Anti-Cheat v" .. Veltrix.Version)
	Frame:SetSize(math.min(ScrW() - 40, 920), math.min(ScrH() - 40, 600))
	Frame:SetMinWidth(720)
	Frame:SetMinHeight(420)
	Frame:SetSizable(true)
	Frame:Center()
	Frame:MakePopup()

	Frame.Paint = function(_, w, h)
        draw.RoundedBox(8, 0, 0, w, h, BG)
        draw.RoundedBox(0, 0, 0, w, 27, Color(31, 47, 68))
    end
    Frame:SetTitle("Veltrix  /  Security Administration  /  v" .. Veltrix.Version)
    local sheet = vgui.Create("DPropertySheet", Frame)
	sheet:Dock(FILL)
	Frame.sheet = sheet

	local status = vgui.Create("DLabel", Frame)
	status:Dock(BOTTOM)
	status:SetText("Waiting for server...")
	status:DockMargin(4, 4, 4, 0)
	Frame.status = status

	local oPnl, oRef = BuildOverview(sheet, Frame)
    sheet:AddSheet("Overview", oPnl, "icon16/chart_bar.png")
    local pPnl, pRef = BuildPlayers(sheet, Frame)
	sheet:AddSheet("Players", pPnl, "icon16/user.png")
	local lPnl, lRef = BuildLog(sheet, Frame)
	Frame.logTab = sheet:AddSheet("Events", lPnl, "icon16/book.png")
	local hPnl, hRef = BuildDecoy(sheet, Frame)
	sheet:AddSheet("Decoy", hPnl, "icon16/bug.png")
	local sPnl, sRef = BuildSettings(sheet, Frame)
	sheet:AddSheet("Settings", sPnl, "icon16/wrench.png")

	function Frame:Refresh()
		if not State then return end
		oRef() pRef() lRef() hRef() sRef()
		status:SetText(string.format("Anti-ESP: %.2f ms/step, %.0f traces/step   |   Decoys: %d   |   Map: %s",
			(State.stats or {}).occMs or 0, (State.stats or {}).traces or 0, State.decoys or 0, State.map or "unknown"))
	end

	Frame.OnClose = function() timer.Remove("Veltrix_Poll") end
	timer.Create("Veltrix_Poll", 3, 0, function()
		if not IsValid(Frame) then timer.Remove("Veltrix_Poll") return end
		Request()
	end)

	if State then Frame:Refresh() end
	Request()
end

---------------------------------------------------------------- world debug draw
hook.Add("PostDrawTranslucentRenderables", "Veltrix_DrawSpots", function()
	if not Veltrix.ShowSpots or not State or not State.spots then return end
	for _, s in ipairs(State.spots) do
		render.DrawWireframeBox(Vector(s[1], s[2], s[3]), angle_zero, Vector(-16, -16, 0), Vector(16, 16, 72), Color(255, 60, 60), true)
	end
end)

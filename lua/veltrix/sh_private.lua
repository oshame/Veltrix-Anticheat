-- Public API for need-to-know networking.
-- Use instead of SetNWString/SetNWInt for anything a cheat should not be able to read about other players.
--   Veltrix.PD.Set(owner, "role", "traitor")              -- owner only
--   Veltrix.PD.Set(owner, "role", "traitor", {p1, p2})    -- owner's chosen recipients
--   Veltrix.PD.Get(ent, "role", default)                  -- client side
Veltrix.PD = Veltrix.PD or {}
local PD = Veltrix.PD

if SERVER then
	util.AddNetworkString("Veltrix_PD")

	function PD.Set(owner, key, value, recipients)
		if not IsValid(owner) then return end
		owner.VeltrixPD = owner.VeltrixPD or {}
		owner.VeltrixPD[key] = value

		net.Start("Veltrix_PD")
			net.WriteEntity(owner)
			net.WriteString(key)
			net.WriteType(value)
		net.Send(recipients or owner)
	end

	-- Re-sends a player's own owner-only values (late join / respawn)
	function PD.Resync(ply)
		for k, v in pairs(ply.VeltrixPD or {}) do
			PD.Set(ply, k, v, ply)
		end
	end

	hook.Add("PlayerInitialSpawn", "Veltrix_PDResync", function(ply)
		timer.Simple(3, function()
			if IsValid(ply) then PD.Resync(ply) end
		end)
	end)
else
	PD.Data = PD.Data or setmetatable({}, { __mode = "k" })

	net.Receive("Veltrix_PD", function()
		local ent, key, val = net.ReadEntity(), net.ReadString(), net.ReadType()
		if not IsValid(ent) then return end
		PD.Data[ent] = PD.Data[ent] or {}
		PD.Data[ent][key] = val
	end)

	function PD.Get(ent, key, default)
		local t = PD.Data[ent]
		if t and t[key] ~= nil then return t[key] end
		return default
	end
end

Veltrix = Veltrix or {}

if SERVER then
	-- CLIENT SIDED FILES 
	AddCSLuaFile("veltrix/sh_config.lua")
	AddCSLuaFile("veltrix/sh_private.lua")
	AddCSLuaFile("veltrix/cl_panel.lua")
	AddCSLuaFile("veltrix/cl_advanced.lua")

	-- SERVER SIDED FILES
	include("veltrix/sh_config.lua")
	include("veltrix/sh_private.lua")
	include("veltrix/sv_core.lua")
	include("veltrix/sv_occlusion.lua")
	include("veltrix/sv_honeypot.lua")
	include("veltrix/sv_aim.lua")
	include("veltrix/sv_validators.lua")
	include("veltrix/sv_admin.lua")
	include("veltrix/sv_integrity.lua")
	include("veltrix/sv_advanced.lua")
	include("veltrix/sv_rage.lua")
	include("veltrix/sv_behavior.lua")
	include("veltrix/sv_spectator_privacy.lua")
	include("veltrix/sv_evidence.lua")
else
	include("veltrix/sh_config.lua")
	include("veltrix/sh_private.lua")
	include("veltrix/cl_panel.lua")
	include("veltrix/cl_advanced.lua")
end

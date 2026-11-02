-- Check whether Veltrix's own SERVER hooks have been replaced or removed.
-- This cannot authenticate or enumerate arbitrary client-side hooks.
if not SERVER then return end

local PROTECTED = {
    StartCommand = { "Veltrix_DecoyCmd", "Veltrix_Aim", "Veltrix_AdvancedCommand" },
    PlayerSpawn = { "Veltrix_DecoySpawn", "Veltrix_AimSpawn" },
    PlayerShouldTakeDamage = { "Veltrix_DecoyGod" },
    PlayerDeath = { "Veltrix_DecoyRespawn" },
}

local baseline = {}
local lastChanged = {}
local CHECK_INTERVAL = 15
local LOG_COOLDOWN = 120

local function captureBaseline()
    local hooks = hook.GetTable()
    for event, names in pairs(PROTECTED) do
        baseline[event] = baseline[event] or {}
        for _, name in ipairs(names) do
            local fn = hooks[event] and hooks[event][name]
            if type(fn) == "function" then baseline[event][name] = fn end
        end
    end
end

local function logChange(event, name, action)
    local key = event .. "/" .. name
    local now = CurTime()
    if now - (lastChanged[key] or -1e9) < LOG_COOLDOWN then return end
    lastChanged[key] = now

    local detail = string.format("Protected server hook %s: %s (%s)", action, key,
        Veltrix.Cfg("integrity_restore") and "restore enabled" or "restore disabled")
    ServerLog("[Veltrix] " .. detail .. "\n")
    if Veltrix.Cfg("diagnostics_enabled") then
        Veltrix.AddLog({
            t = os.time(), name = "SERVER", sid = "SERVER",
            src = "server_hook_integrity", pts = 0, score = 0,
            detail = detail, info = true,
        })
    end
end

timer.Simple(10, captureBaseline)
timer.Create("Veltrix_HookIntegrity", CHECK_INTERVAL, 0, function()
    if not Veltrix.Cfg("integrity_enabled") then return end

    local hooks = hook.GetTable()
    for event, entries in pairs(baseline) do
        for name, original in pairs(entries) do
            local current = hooks[event] and hooks[event][name]
            if current ~= original then
                logChange(event, name, current and "replaced" or "removed")
                if Veltrix.Cfg("integrity_restore") then
                    hook.Add(event, name, original)
                end
            end
        end
    end
end)

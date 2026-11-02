if not SERVER then return end

local C = Veltrix.Cfg
local managed = setmetatable({}, { __mode = "k" })
local function privileged(p)
    return Veltrix.IsAdmin(p)
end

function Veltrix.IsStealthObserver(p)
    if not C("spectator_privacy_enabled") or not IsValid(p) or not privileged(p) then return false end
    -- Explicit server integrations can set or clear this flag for ULX/SAM/etc.
    if p.VeltrixStealthObserver == true then return true end
    if p.VeltrixStealthObserver == false then return false end
    return p:GetObserverMode() ~= OBS_MODE_NONE or p:GetMoveType() == MOVETYPE_NOCLIP
end

function Veltrix.ShouldHideObserver(observer, viewer)
    if not IsValid(observer) or not IsValid(viewer) or observer == viewer then return false end
    if privileged(viewer) then return false end
    return Veltrix.IsStealthObserver(observer)
end

local function audit()
    if not C("spectator_privacy_enabled") or not C("spectator_privacy_transmit") then
        for target, viewers in pairs(managed) do
            if IsValid(target) then
                for viewer in pairs(viewers) do
                    if IsValid(viewer) then target:SetPreventTransmit(viewer, false) end
                end
            end
        end
        managed = setmetatable({}, { __mode = "k" })
        return
    end
    for _, target in ipairs(player.GetHumans()) do
        local viewers = managed[target]
        if not viewers then viewers = setmetatable({}, { __mode = "k" }); managed[target] = viewers end
        for _, viewer in ipairs(player.GetHumans()) do
            if viewer ~= target then
                local hide = Veltrix.ShouldHideObserver(target, viewer)
                if hide and not viewers[viewer] then
                    target:SetPreventTransmit(viewer, true)
                    viewers[viewer] = true
                elseif not hide and viewers[viewer] then
                    viewers[viewer] = nil
                    if not C("occ_enabled") then target:SetPreventTransmit(viewer, false) end
                end
            end
        end
    end
end

timer.Create("Veltrix_SpectatorPrivacy", 0.4, 0, audit)
hook.Add("PlayerDisconnected", "Veltrix_SpectatorPrivacyCleanup", function(p)
    managed[p] = nil
    for _, viewers in pairs(managed) do viewers[p] = nil end
end)

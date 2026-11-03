--[[ OffGrid -- keeping the charge controller off Knox Power's panels.

     Knox Power (Workshop 3814302595, mod id KnoxPower) adds wall power
     panels: a generator connected to one powers its whole building, and every
     game hour Knox takes the building's use off that generator's tank. Its
     "Connect to power panel" row is offered on every IsoGenerator
     (KP_PanelMenu.lua, onFillContext and addGeneratorMenu), and a charge
     controller is one (OG_Place, G.makeController). Connected, a running
     controller lit every room of the house for nothing, because Off-Grid
     rewrites the controller's tank from the battery charge every minute
     (OG_System, driveGenerator), and at low charge Knox's hourly draw could
     empty that tank and switch the controller off until the next minute
     (KP_Panels.lua, Panels.chargeFuel). Knox also marks the generator
     connected (setConnected), which Off-Grid never does. Off-Grid wires
     buildings itself, from the controller and from transformers.

     So a controller is never connected. The row stays on the menu, greyed
     with the reason (N.onFill), and the connection itself is refused where it
     is made: KnoxPower.Panels.connectGenerator, which Knox's timed action
     calls where the action completes, the server in multiplayer (N.guard).
     A controller connected before this keeps Knox's Disconnect row. Nothing
     here does anything without Knox Power. Found 2026-10-18 after a Workshop
     question (DankBroadcaster, 2026-10-18).
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Knox = OffGrid.Knox or {}
local N = OffGrid.Knox
local P = OffGrid.Parts

N.REFUSAL = "Tooltip_OffGrid_KnoxController"

--- Knox Power's panel module, or nil when it is not loaded.
local function panels()
    local kp = KnoxPower
    if type(kp) ~= "table" or type(kp.Panels) ~= "table" then return nil end
    return kp.Panels
end

--- Why `generator` may not go on a Knox panel, or nil: an Off-Grid charge
--  controller, or an Onan Off-Grid runs as a backup (OG_Onan), which Knox
--  would switch on and draw fuel from like any generator.
local function refusalFor(generator)
    if generator == nil then return nil end
    local part = P.partOf(generator)
    if part == "controller" then return N.REFUSAL end
    local ON = OffGrid.Onan
    if part == "backup" and ON and ON.isUnit and ON.isUnit(generator) then return ON.REFUSAL end
    return nil
end

--- Refuse a controller in Knox's own connect. Knox reports a refusal by
--  returning a translation key, which its action says over the player
--  (KPPanelActions.lua, KPConnectGeneratorAction:complete; Panels.tell). Every
--  other argument goes through untouched. Returns whether the guard is on.
local guarded = false
function N.guard()
    if guarded then return true end
    local Panels = panels()
    local orig = Panels and Panels.connectGenerator
    if type(orig) ~= "function" then return false end
    Panels.connectGenerator = function(character, panel, generator, ...)
        local why = refusalFor(generator)
        if why then return why end
        return orig(character, panel, generator, ...)
    end
    guarded = true
    return true
end

--- Grey Knox's Connect row on a controller, with the reason.
--
--  Knox builds its rows for the first IsoGenerator among the clicked objects
--  (KP_PanelMenu.lua, onFillContext), so this looks at the same one. It runs
--  after Knox's own handler: registered once a game has started, by which time
--  every mod's file-load registrations are in, whatever the mod order. The
--  submenu goes: vanilla still opens the submenu of a greyed row.
function N.onFill(playerNum, context, worldObjects, test)
    if test or not context or not panels() then return end
    local gen = nil
    for _, o in ipairs(worldObjects or {}) do
        if instanceof(o, "IsoGenerator") then gen = o; break end
    end
    local why = refusalFor(gen)
    if not why then return end
    local opt = context.getOptionFromName
                and context:getOptionFromName(getText("IGUI_KnoxPower_Connect"))
    if not opt then return end
    opt.notAvailable = true
    opt.subOption = nil
    local C = OffGrid.Context
    if C and C.tip then
        opt.toolTip = C.tip(getText(why))
    end
end

if Events then
    -- Knox may load before or after Off-Grid; the guard goes on once both are
    -- in, on every machine that runs Knox's action.
    local function guard() N.guard() end
    if Events.OnGameBoot then Events.OnGameBoot.Add(guard) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(guard) end
    if Events.OnGameStart then
        local added = false
        Events.OnGameStart.Add(function()
            guard()
            if not added and not isServer() and Events.OnFillWorldObjectContextMenu then
                added = true
                Events.OnFillWorldObjectContextMenu.Add(N.onFill)
            end
        end)
    end
end

return N

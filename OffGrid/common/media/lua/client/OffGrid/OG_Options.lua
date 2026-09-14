--[[ OffGrid -- the player's own settings.

     Client-side preferences, kept in the player's own ModOptions.ini through
     the engine's PZAPI.ModOptions page, which is the right store for a HUD
     choice: a sandbox option is world-wide and set by the host, and a player
     on somebody else's server cannot touch it.

     Registered at file load, not on an event: MainOptions builds its Mods
     page when the main screen is constructed (OnMainMenuEnter), and only if
     PZAPI.ModOptions.Data is non-empty at that moment. Vanilla loads
     PZAPI/ModOptions.lua before any mod file, so the table exists here.
     MainOptions reads ModOptions.ini itself before any world is entered, so
     a value is in place before the sidebar exists.

     A tick box only. The keybind widget throws on rebind for any mod that
     ships translations (its rebind handler matches the translated label
     against the raw name), which is why no hotkey is offered.
]]

OffGrid = OffGrid or {}
OffGrid.Options = OffGrid.Options or {}
local O = OffGrid.Options

O.ID = "OffGrid"
O.SIDEBAR = "SidebarAlmanac"

local function register()
    if not (PZAPI and PZAPI.ModOptions) then return end
    -- Never a second page: a re-run of this file would otherwise insert a
    -- duplicate section into the Mods tab.
    if PZAPI.ModOptions:getOptions(O.ID) then return end
    local page = PZAPI.ModOptions:create(O.ID, "IGUI_OffGrid_Options")
    local opt = page:addTickBox(O.SIDEBAR, "IGUI_OffGrid_OptSidebar", true,
                                "IGUI_OffGrid_OptSidebarTip")
    -- Applied the moment the player presses Apply, rather than on the next
    -- minute tick of the sidebar.
    -- MainOptions calls this BEFORE it stores the new value (the tick box's
    -- gameOption.apply runs onChangeApply(newValue), then option.value =
    -- newValue), so the value handed in has to be written here or the refresh
    -- reads the old one and the button only follows a minute later.
    opt.onChangeApply = function(self, value)
        if value ~= nil then self.value = value end
        if OffGrid.Sidebar and OffGrid.Sidebar.refresh then
            OffGrid.Sidebar.refresh()
        end
    end
end

--- Does this player want the almanac button on the sidebar? True unless the
--  option exists and is unticked, so a missing page changes nothing.
function O.sidebar()
    if not (PZAPI and PZAPI.ModOptions) then return true end
    local page = PZAPI.ModOptions:getOptions(O.ID)
    local opt = page and page:getOption(O.SIDEBAR)
    if not opt then return true end
    return opt:getValue() ~= false
end

register()

return O

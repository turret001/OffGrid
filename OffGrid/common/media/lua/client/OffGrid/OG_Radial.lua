--[[ OffGrid -- the almanac on the hold-Q wheel.

     Holding Q opens ISEmoteRadialMenu (the "Emote" binding; tapping the same
     key shouts). A slice is added there rather than a keybind of its own,
     because the wheel is where players already reach for something they do
     occasionally and it costs no key.

     The injection has to happen in fillMenu and not once at boot. Opening the
     wheel constructs a fresh ISEmoteRadialMenu, whose :new calls
     ISUIEmoteConfig:readFile, which calls ISEmoteRadialMenu:init, which starts
     with `defaultMenu = {}` and ends with `menu = defaultMenu`. So the whole
     table is thrown away and rebuilt every single time the wheel is opened.
     Anything written into it earlier is gone. Wrapping fillMenu, which runs
     after all of that, is the only placement that survives -- and it is
     self-cleaning for the same reason.

     A top-level entry with no subMenu is dispatched to ISEmoteRadialMenu:emote
     rather than to a submenu, so the slice's own key is intercepted there.
     Passing it through would ask the engine to play an animation that does not
     exist.
]]

require "ISUI/ISEmoteRadialMenu"
require "OffGrid/OG_Almanac"
require "OffGrid/OG_Forecast"

OffGrid = OffGrid or {}
OffGrid.Radial = OffGrid.Radial or {}
local R = OffGrid.Radial

-- Namespaced, because this key shares a table with every emote name and is
-- compared against them.
R.SLICE = "offgrid_almanac"

local originalFill = ISEmoteRadialMenu.fillMenu
local originalEmote = ISEmoteRadialMenu.emote

function ISEmoteRadialMenu:fillMenu(submenu)
    -- Only for somebody who has read the almanac. Nobody who has not gets a
    -- sidebar button either, and a wheel slice that does nothing would be
    -- worse than no slice at all.
    if ISEmoteRadialMenu.menu and self.character
            and OffGrid.Almanac.knows(self.character) then
        ISEmoteRadialMenu.menu[R.SLICE] = {
            name = getText("IGUI_OffGrid_Almanac"),
        }
        ISEmoteRadialMenu.icons[R.SLICE] =
            getTexture("media/ui/OffGrid/almanac.png")
    end
    originalFill(self, submenu)
end

function ISEmoteRadialMenu:emote(emote)
    if emote == R.SLICE then
        -- Already a toggle: opening it while it is open closes it.
        OffGrid.Forecast.open(self.character)
        return
    end
    return originalEmote(self, emote)
end

return R

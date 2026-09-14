--[[ OffGrid -- click a part to open its screen.

     A rack and a controller both have a window worth reading, and reaching it
     through Off-Grid > Batteries on the right-click menu is three actions for
     something that should be one. So a left click on either opens it.

     The context rows stay. They are how the feature is discoverable, they are
     the only route for a player on a controller pad, and a mod that can ONLY
     be operated by clicking exactly the right pixel of a tile is worse than
     one with a menu.

     A CLICK is a press and a release on the same part. The engine raises its
     "up" event on every frame the button was down the frame before
     (UIManager.java:613-616, whichKeyWasDown), not once on the release, so
     acting on that event alone rebuilt the window every frame the button was
     held -- and a held button is also how a player aims and swings. The press
     is latched here the way vanilla's own click handler latches it, and the
     window opens once, on the release.
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Click = OffGrid.Click or {}
local P = OffGrid.Parts

-- The same two tiles the context menu and the panel use.
local REACH = 2

--- Deliberately NOT a walk-and-open.
--
--  luautils.walkAdj would carry the player over, and the panel now waits for
--  them to arrive, so it would work. It is still wrong: a left click in this
--  game is also how you swing, shove and move, and turning every click on a
--  rack from across the room into a walk order would take the click away from
--  the player at exactly the moment they were doing something else with it.
--  In arm's reach the click is unambiguous; further out, leave it alone.
local function inReach(playerObj, object)
    local sq = object and object:getSquare()
    if not sq or not playerObj then return false end
    return math.abs(sq:getX() - playerObj:getX()) <= REACH
       and math.abs(sq:getY() - playerObj:getY()) <= REACH
       and sq:getZ() == playerObj:getZ()
end

local function busy(playerObj)
    if not playerObj or playerObj:isDead() then return true end
    if playerObj.isAiming and playerObj:isAiming() then return true end
    -- Placing or rotating a moveable owns the cursor; do not take its click.
    local cell = getCell and getCell()
    if cell and cell.getDrag and cell:getDrag(0) then return true end
    return false
end

function OffGrid.Click.onObjectDown(object, x, y)
    OffGrid.Click.down = nil
    if not object or not P.partOf(object) then return end
    if busy(getSpecificPlayer(0)) then return end
    OffGrid.Click.down = object
end

function OffGrid.Click.onObjectUp(object, x, y)
    local down = OffGrid.Click.down
    if not down then return end
    -- Still held: this is the engine repeating the event, not the release.
    if isMouseButtonDown and isMouseButtonDown(0) then return end
    OffGrid.Click.down = nil
    if object ~= down then return end

    local playerObj = getSpecificPlayer(0)
    if busy(playerObj) then return end

    local kind = P.partOf(object)
    if not kind then return end
    if not inReach(playerObj, object) then return end

    if kind == "bank" and OffGrid.Bank and OffGrid.Bank.open then
        OffGrid.Bank.open(playerObj, object)
    elseif kind == "controller" and OffGrid.Window and OffGrid.Window.open then
        OffGrid.Window.open(playerObj, object)
    end
end

Events.OnObjectLeftMouseButtonDown.Add(OffGrid.Click.onObjectDown)
Events.OnObjectLeftMouseButtonUp.Add(OffGrid.Click.onObjectUp)

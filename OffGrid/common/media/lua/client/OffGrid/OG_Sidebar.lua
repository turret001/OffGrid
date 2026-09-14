--[[ OffGrid -- the almanac button in the sidebar.

     The panel is worth opening about once a game day, so it does not deserve
     screen furniture of its own. It goes on the end of the vanilla left
     sidebar, the column that already holds inventory, health, crafting,
     building and the map, and it only appears once the player has read the
     almanac. Somebody who never finds the book never sees a new button.

     Being a child of that panel also buys the whole death and respawn
     lifecycle for free: vanilla tears the sidebar down in destroyPlayerData on
     OnPlayerDeath and builds a new one on the respawn path, and the button
     goes with it both ways. A free-floating element would have to handle that
     itself.

     Four things about the column are not guessable and each of them breaks a
     naive implementation:

     * Everything is built inside ISEquippedItem:initialise, which ends with
       shrinkWrap(). shrinkWrap recomputes the panel's bounds from every child
       whose Type is "ISButton". Without calling it again the button still
       DRAWS -- nothing clips a child to its parent unless the parent turns
       renderClippedChildren off -- but UIElement.isPointOver falls through to
       the parent's rect, so a button outside it is visible and completely
       dead to the mouse. That failure looks like a broken click handler.
     * The whole panel is thrown away and rebuilt when the player changes the
       sidebar size option: checkSidebarSizeOption runs every frame and does a
       removeFromUIManager plus a fresh launchEquippedItem. A button attached
       once to the old instance vanishes with no error.
     * ISEquippedItem.instance is NOT player zero's panel. :new assigns it for
       every panel it constructs, and createPlayerData rebuilds the interface
       for every active player in a loop, so in split screen it ends up
       pointing at the last player built. getPlayerData(0).equipped is the
       accessor that stays correct, and it is the one checkSidebarSizeOption
       itself uses to check identity.
     * That same loop means player zero's sidebar is REPLACED when a second
       player joins. So OnCreatePlayer must re-attach whatever the player
       number is, rather than ignoring everything but zero.

     OnCreateUI is the wrong event, incidentally: it fires at the end of
     UIManager.init(), one line BEFORE the caller fires OnCreatePlayer, and the
     vanilla Lua HUD is built on OnCreatePlayer. At OnCreateUI time there is no
     sidebar to attach to.
]]

require "OffGrid/OG_Almanac"
require "OffGrid/OG_Forecast"
require "OffGrid/OG_Options"

OffGrid = OffGrid or {}
OffGrid.Sidebar = OffGrid.Sidebar or {}
local S = OffGrid.Sidebar
local A = OffGrid.Almanac

-- The vanilla buttons, by field name. The button goes under the lowest of
-- THESE and nothing else. It used to go under the lowest ISButton child of
-- any owner and then shrinkWrap the panel around every child, and that is a
-- leapfrog waiting for a partner: another mod that hangs its own button under
-- the lowest child, or off the panel height, ends up anchored to ours and we
-- to theirs, and both walk down the screen one stride per minute until they
-- are gone. The 2026-09 "the icon starts to fall down and disappears in MP"
-- report is that, on a server whose mod list holds such a partner. Measured
-- regardless of visibility: vanilla only ever toggles setVisible on the
-- admin, safety and war buttons and never reflows the column, so a hidden
-- slot is still a slot, exactly as vanilla's own shrinkWrap counts it.
local ANCHORS = { "warManagerBtn", "adminBtn", "clientBtn", "safetyBtn",
                  "arfBtn", "debugBtn", "mapBtn", "zoneBtn", "searchBtn",
                  "movableBtn", "buildBtn", "craftingBtn", "healthBtn",
                  "invBtn" }

local function anchorBottom(panel)
    local b = 0
    for _, name in ipairs(ANCHORS) do
        local btn = panel[name]
        if btn and btn.Type == "ISButton" then
            b = math.max(b, btn:getBottom())
        end
    end
    return b
end

-- The sizes vanilla ships under media/ui/Sidebar/. A mod cannot read the
-- current one -- it is a file-local upvalue -- so it measures a sibling.
local SIZES = { 48, 64, 80, 96, 128 }

local function textureFor(width)
    local best = SIZES[1]
    for i = 1, #SIZES do
        if math.abs(SIZES[i] - width) < math.abs(best - width) then
            best = SIZES[i]
        end
    end
    return getTexture("media/ui/OffGrid/Sidebar/" .. best
                      .. "/Almanac_" .. best .. ".png")
end

local function onClick()
    local pl = getSpecificPlayer(0)
    if pl then OffGrid.Forecast.open(pl) end
end

--- Take the button off the panel again: the player unticked it, or this is a
--  character who has not read the almanac.
--
--  removeChild, not setVisible. shrinkWrap sizes the panel from every child
--  whose Type is ISButton with no visibility test, so a hidden button keeps
--  the panel tall, and the tooltip row addMouseOverToolTipItem filed keeps
--  answering hover for a button that is not drawn.
function S.detach(panel)
    local btn = panel and panel.offGridAlmanacBtn
    if not btn then return end
    panel:removeChild(btn)
    if panel.mouseOverList then
        for i = #panel.mouseOverList, 1, -1 do
            if panel.mouseOverList[i].object == btn then
                table.remove(panel.mouseOverList, i)
            end
        end
    end
    panel.offGridAlmanacBtn = nil
    panel:shrinkWrap()
end

--- Put the button on the panel, or move it back under the vanilla column.
--  Safe to call as often as you like: it builds at most one button per panel
--  and otherwise only corrects its position.
function S.attach(panel)
    -- invBtn is the tell that this is the button column at all. Vanilla only
    -- builds it for player zero, so a split-screen panel legitimately has none
    -- and shrinkWrap there would size the panel around the mod button alone.
    if not panel or not panel.invBtn then return end
    local O = OffGrid.Options
    if not A.knows(getSpecificPlayer(0)) or (O and not O.sidebar()) then
        S.detach(panel)
        return
    end

    local size = panel.invBtn:getWidth()
    local base = anchorBottom(panel)

    local btn = panel.offGridAlmanacBtn
    if not btn then
        -- Foreign buttons are measured ONCE, here, when ours is built, and
        -- never again. A mod that already sits under the vanilla column gets
        -- stepped over, as 2.9.0 did; the offset is then kept relative to the
        -- vanilla anchor, so ours follows vanilla's own reflows and ignores
        -- any partner that moves later, which is what the leapfrog needed.
        -- The sidebar's own spacing between buttons: UI_BORDER_SPACING plus
        -- five.
        local low = base
        for _, child in pairs(panel:getChildren()) do
            if child.Type == "ISButton" then low = math.max(low, child:getBottom()) end
        end
        local y = low + 15
        btn = ISButton:new(0, y, size, size * 0.75, "", panel, onClick)
        btn.offGridOffset = y - base
        btn:initialise()
        btn:instantiate()
        btn:setImage(textureFor(size))
        btn:setDisplayBackground(false)
        -- Without these the button resizes itself to its label, which is empty.
        btn:ignoreWidthChange()
        btn:ignoreHeightChange()
        panel:addChild(btn)
        panel:addMouseOverToolTipItem(btn, getText("IGUI_OffGrid_Almanac"))
        panel.offGridAlmanacBtn = btn
    else
        local y = base + (btn.offGridOffset or 15)
        if btn:getY() ~= y then btn:setY(y) end
    end

    -- Grow-only, and only to reach our own button. The panel has to cover it
    -- or the mouse never finds it: UIElement.isPointOver falls through to the
    -- parent's rect. shrinkWrap would do that too, but it re-measures every
    -- ISButton child including other mods', which is the other half of the
    -- leapfrog described above.
    if btn:getBottom() > panel:getHeight() then panel:setHeight(btn:getBottom()) end
    if btn:getRight() > panel:getWidth() then panel:setWidth(btn:getRight()) end
end

local function sidebar()
    local pd = getPlayerData and getPlayerData(0)
    return pd and pd.equipped or nil
end

local function attachToCurrent()
    S.attach(sidebar())
end

--- For the options page: apply a change the moment it is made.
S.refresh = attachToCurrent

--- Wrap the sidebar's own initialise so every instance of it gets the button,
--  including the one rebuilt after a sidebar-size change.
local function patch()
    if not ISEquippedItem or ISEquippedItem.offGridPatched then return end
    ISEquippedItem.offGridPatched = true
    local original = ISEquippedItem.initialise
    function ISEquippedItem:initialise()
        original(self)
        -- The wrapper has no playerNum argument of its own; it has to come off
        -- the panel. Player zero only, because that is the only one vanilla
        -- gives a button column to.
        if self.chr and self.chr:getPlayerNum() == 0 then
            S.attach(self)
        end
    end
end

Events.OnGameStart.Add(patch)
-- No player-number filter. createPlayerData rebuilds EVERY player's interface,
-- so OnCreatePlayer(1) is exactly the moment player zero's sidebar has just
-- been replaced by a new one with no button on it.
Events.OnCreatePlayer.Add(attachToCurrent)
-- The ability can be learned in the middle of a session. One check a minute
-- settles that without a per-frame hook. (Hiding the admin or safety button
-- does not shuffle the column; vanilla leaves the slot in place.)
Events.EveryOneMinute.Add(attachToCurrent)

return S

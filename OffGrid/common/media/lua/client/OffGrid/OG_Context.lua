--[[ OffGrid -- the right-click menus.

     Note the safehouse trap: OnFillWorldObjectContextMenu is fired inside
     `if fetch.safehouseAllowInteract then` in ISWorldObjectContextMenu.lua,
     so a mod whose only entry point hangs off this event disappears entirely
     inside a safehouse the player may not interact with. That is correct
     behaviour here -- you should not be able to service someone else's
     array -- but it is worth knowing it is the engine's doing, not a bug.
]]

require "OffGrid/OG_Parts"
require "OffGrid/OG_Actions"
require "OffGrid/OG_Almanac"
require "OffGrid/OG_Coverage"
require "OffGrid/OG_Buildings"
require "OffGrid/OG_Lamps"
-- OG_Info requires this file back, so it cannot be required here.
-- It registers itself on OffGrid.Info and is reached through that. The
-- forecast window is reached the same way: OG_Forecast loads after this file
-- and a hard require here would be the first cycle in the tree.

OffGrid = OffGrid or {}
OffGrid.Context = OffGrid.Context or {}
local C = OffGrid.Context
local P = OffGrid.Parts
local M = OffGrid.Model

--- How many buildings a part wires. OG_Buildings is looked up when asked, not
--  held from file load, so a harness or a load order that brings this file in
--  without it reads "none" instead of failing the whole menu.
local function wiredCount(d)
    local Bd = OffGrid.Buildings
    return (Bd and Bd.decodeTargets) and #Bd.decodeTargets(d.bw) or 0
end

------------------------------------------------------------------ row icons

--- The Off-Grid menu's row icons (Can, 2026-09-26: line pictures coloured by
--  group). Tabler Icons (MIT, v3.48.0; the licence ships beside them), drawn
--  white by tools/build_menu_icons.py at these sizes. Each row tints its icon
--  with its group's colour: ISContextMenu.renderOptionTextureOrColor draws
--  the texture multiplied by option.color and uses the colour for nothing
--  else. A row the player cannot use yet shows its icon grey.
C.ICON_DIR = "media/ui/OffGrid/Menu/"
C.ICON_SIZES = { 16, 20, 24, 32, 48 }
C.ICON_GROUP = {
    info  = { r = 133 / 255, g = 183 / 255, b = 235 / 255 },   -- Info, System monitor
    sky   = { r = 239 / 255, g = 159 / 255, b = 39 / 255 },    -- Off-Grid, Almanac, the sky
    reach = { r = 93 / 255, g = 202 / 255, b = 165 / 255 },    -- coverage and buildings
    power = { r = 151 / 255, g = 196 / 255, b = 89 / 255 },    -- switch on, batteries
    off   = { r = 226 / 255, g = 75 / 255, b = 74 / 255 },     -- switch off
    cable = { r = 240 / 255, g = 153 / 255, b = 123 / 255 },   -- cables
    care  = { r = 175 / 255, g = 169 / 255, b = 236 / 255 },   -- snow, cleaning, repair
    take  = { r = 180 / 255, g = 178 / 255, b = 169 / 255 },   -- Take down
}
C.ICON_DIM = { r = 111 / 255, g = 110 / 255, b = 105 / 255 }

-- Every row's icon and group, in one place: { Tabler icon, group }.
C.ROW_ICONS = {
    offgrid         = { "solar-panel", "sky" },
    info            = { "info-circle", "info" },
    monitor         = { "device-desktop-analytics", "info" },
    almanac         = { "book-2", "sky" },
    readSky         = { "cloud", "sky" },
    coverageShow    = { "radar-2", "reach" },
    coverageHide    = { "radar-off", "reach" },
    wireBuilding    = { "home-bolt", "reach" },
    chooseBuildings = { "building-community", "reach" },
    unwireBuildings = { "home-off", "reach" },
    switchOn        = { "power", "power" },
    reset           = { "refresh", "power" },
    cells           = { "battery-automotive", "power" },
    equalise        = { "battery-charging-2", "power" },
    equaliseStop    = { "battery-off", "power" },
    switchOff       = { "power", "off" },
    wireFrom        = { "plug", "cable" },
    wireTo          = { "plug-connected", "cable" },
    wireCancel      = { "plug-x", "cable" },
    wireCut         = { "scissors", "cable" },
    clearSnow       = { "snowflake", "care" },
    repair          = { "tool", "care" },
    clean           = { "droplet", "care" },
    takeDown        = { "hand-grab", "take" },
}

--- The drawn size for a menu: the smallest at least as tall as its icon
--  slot, which is the menu's font height (ISContextMenu:render: iconSize =
--  itemHgt - 12, and itemHgt = fontHgt + 12), so the game scales an icon down,
--  and only a little. Past the largest, the largest.
function C.iconSize(menu)
    local want = (menu and type(menu.fontHgt) == "number") and menu.fontHgt or 18
    for i = 1, #C.ICON_SIZES do
        if C.ICON_SIZES[i] >= want then return C.ICON_SIZES[i] end
    end
    return C.ICON_SIZES[#C.ICON_SIZES]
end

local iconTextures = {}

local function iconTexture(name, size)
    local path = C.ICON_DIR .. size .. "/" .. name .. ".png"
    local t = iconTextures[path]
    if t == nil then
        t = getTexture(path) or false
        iconTextures[path] = t
    end
    return t or nil
end

--- Give a menu row its icon: `row` a key of C.ROW_ICONS. Returns the row,
--  so it can wrap addOption. A picture the game cannot find leaves the row as
--  it was.
function C.icon(option, menu, row)
    local spec = C.ROW_ICONS[row]
    if type(option) ~= "table" or not spec then return option end
    local tex = iconTexture(spec[1], C.iconSize(menu))
    if not tex then return option end
    option.iconTexture = tex
    local c = C.ICON_GROUP[spec[2]]
    option.color = c and { r = c.r, g = c.g, b = c.b } or nil
    return option
end

--- Grey the icon of every row in `menu` the player cannot use yet. Run once
--  the menu is built: several rows are marked notAvailable after they are
--  added.
function C.dimUnavailable(menu)
    local opts = menu and menu.options
    if type(opts) ~= "table" then return end
    local d = C.ICON_DIM
    for _, o in ipairs(opts) do
        if o.notAvailable and o.iconTexture then
            o.color = { r = d.r, g = d.g, b = d.b }
        end
    end
end

--- Ask the authority to do something. On a multiplayer client that is a
--  packet; in single player the simulation is loaded in this process, so it is
--  a direct call. Same validation runs at the far end either way.
function C.send(playerObj, command, args)
    if isClient() then
        sendClientCommand(playerObj, "OffGrid", command, args)
    elseif OffGrid.System and OffGrid.System.onCommand then
        OffGrid.System.onCommand(command, playerObj, args)
    end
end

--- Walk to a square NEXT TO an object, and say whether that is possible.
--
--  ISWalkToTimedAction aimed at the object's OWN square looks right and is
--  wrong for half of what this mod places. A ground array carries solidtrans,
--  so the pathfinder can never arrive on its tile: the walk fails, the whole
--  queued action goes with it, and what the player sees is a progress bar that
--  flickers once and then nothing. It only happens when they are not already
--  standing next to the thing, which is why it survived until somebody tried
--  to wire a panel from across the yard. A battery bank is IsLow and walkable,
--  so banks worked and arrays did not.
--
--  luautils.walkAdj finds an adjacent free tile instead, returns true when the
--  player is already close enough, and returns false when there is genuinely
--  nowhere to stand. It also clears the action queue, so it has to run BEFORE
--  anything is queued rather than after.
function C.approach(playerObj, object)
    local sq = object and object:getSquare()
    if not sq then return false end
    if not luautils or not luautils.walkAdj then return true end
    return luautils.walkAdj(playerObj, sq, false) and true or false
end

local function reachable(playerObj, object)
    local sq = object and object:getSquare()
    if not sq then return false end
    return playerObj:getCurrentSquare()
        and math.abs(sq:getX() - playerObj:getX()) <= 2
        and math.abs(sq:getY() - playerObj:getY()) <= 2
        and sq:getZ() == playerObj:getZ()
end

-- ItemContainer.getAllTag takes an ItemTag, never a String, so the tag has to
-- come from the exposed ItemTag container rather than a literal. Matching the
-- tag rather than Base.CarBattery1/2/3 means a modded battery works too.
local function predicateCarBattery(item)
    return item ~= nil and item:hasTag(ItemTag.CAR_BATTERY)
end

--- Exported so the bank panel's slot predicate and this menu agree on what
--  counts as a car battery, rather than each carrying its own copy.
function C.isCarBattery(item)
    return predicateCarBattery(item)
end

local function predicateWater(item)
    return item:isWaterSource() and item:getCurrentUses() > 0
end

local function predicateScrap(item)
    return item ~= nil and item:getFullType() == "Base.ElectronicsScrap"
end

local function predicateScrews(item)
    return item ~= nil and item:getFullType() == "Base.Screws"
end

--- A screwdriver, by tag, so a modded one works.
--  Shared with the pickup gate: see P.hasScrewdriver for why this is one
--  function and not two.
local function hasScrewdriver(playerObj)
    return P.hasScrewdriver(playerObj)
end

local function findRepairParts(playerObj)
    local inv = playerObj:getInventory()
    return inv:getFirstEvalRecurse(predicateScrap),
           inv:getFirstEvalRecurse(predicateScrews)
end

local function findRagAndWater(playerObj)
    local inv = playerObj:getInventory()
    local rag = inv:getItemFromType("RippedSheets", true, true)
    if not rag then rag = inv:getItemFromType("DishCloth", true, true) end
    local water = inv:getFirstEvalRecurse(predicateWater)
    return rag, water
end

--- The system key this part can honestly claim, or nil.
--
--  `d.sys` is a server-maintained cache, and a cache can outlive its truth:
--  before 2026-08-28 picking a controller up never cleared it from the parts
--  it owned, and a member whose chunk was unloaded at that moment still
--  misses the sweep today. A part carrying a stale sys was locked out of the
--  whole wiring menu -- no "Run cable from here" because it looked wired, no
--  cut rows because its controller resolved to nothing. So the menu checks
--  the claim before honouring it: if the controller's square is LOADED and
--  no controller stands there, the claim is dead and the part is loose. Only
--  ever read here; the authoritative clear stays on the server.
local function liveSys(d)
    local sys = d.sys
    if not sys then return nil end
    local cx, cy, cz = M.parseNodeKey(sys)
    if not cx then return nil end
    local sq = getSquare(cx, cy, cz)
    if sq and not P.objectAt(cx, cy, cz, "controller") then return nil end
    return sys
end

--- One line of status for the tooltip, so the common case needs no window.
local function statusText(obj, part)
    local d = P.data(obj)
    -- Membership comes first, because an unwired part makes nothing and every
    -- other number on the line is beside the point until it is connected.
    local loose = (part ~= "controller") and not liveSys(d)
    if part == "array" then
        local bits = {}
        if loose then bits[#bits + 1] = getText("IGUI_OffGrid_NotWired") end
        -- Second only to being unwired: an array under a roof makes nothing
        -- whatever its snow, dust or condition say. OG_System's own test.
        local E, sq = OffGrid.Env, obj:getSquare()
        if E and E.isSunlit and sq and not E.isSunlit(sq) then
            bits[#bits + 1] = getText("IGUI_OffGrid_UnderRoof")
        end
        if (d.snow or 0) > 0.02 then
            bits[#bits + 1] = P.txt("IGUI_OffGrid_SnowPct",
                                      math.floor((d.snow or 0) * 100))
        end
        if (d.soiling or 0) > 0.05 then
            bits[#bits + 1] = P.txt("IGUI_OffGrid_DirtPct",
                                      math.floor((d.soiling or 0) * 100))
        end
        bits[#bits + 1] = P.txt("IGUI_OffGrid_ConditionPct",
                                  math.floor(d.condition or 100))
        return table.concat(bits, "   ")
    elseif part == "bank" then
        local info = P.describe(obj)
        -- The same capacity the simulation uses: BankScale in, the day's real
        -- temperature in, and the ratio clamped. Against the old unscaled
        -- 20 C figure a cold morning read over 100% charged.
        local scale = P.bankScale()
        local tempC = (OffGrid.Env and OffGrid.Env.read().temperature) or 20
        tempC = (OffGrid.Env and OffGrid.Env.tempAt(obj, tempC)) or tempC
        local cap = M.bankCapacity({ tier = info and info.tier,
                                     cellSum = P.cellSum(d),
                                     scale = scale }, tempC)
        local soc = cap > 0 and M.clamp((d.charge or 0) / cap, 0, 1) or 0
        local line = P.txt("IGUI_OffGrid_BankStatus", d.cells or 0,
                           P.cellCap(obj), math.floor(soc * 100))
        if loose then
            return getText("IGUI_OffGrid_NotWired") .. "   " .. line
        end
        return line
    elseif part == "transformer" then
        -- Unwired first, as for every part: a transformer lights nothing
        -- until a power line joins it to a controller.
        if loose then return getText("IGUI_OffGrid_NotWired") end
        local info = P.describe(obj)
        local bits = { getText((info and info.state == "on") and "IGUI_OffGrid_GridOn"
                                                             or "IGUI_OffGrid_GridOff") }
        local n = wiredCount(d)
        if n > 0 then bits[#bits + 1] = P.txt("IGUI_OffGrid_BuildingsWired", n) end
        return table.concat(bits, "   ")
    end
    return nil
end

--- Strip vanilla's generator submenu when the generator it was built for is ours.
--
--  The Java menu keys purely on `instanceof IsoGenerator`, so the controller
--  inherits Add Fuel (which has no skill gate and writes the state-of-charge
--  gauge), Connect, Turn On/Off, Fix, Take and a
--  petrol readout. None of it belongs on a solar controller and Off-Grid's own
--  submenu already covers everything that does.
--
--  Keyed on the generator the Java menu was actually BUILT for. The fetch
--  keeps exactly one (ISWorldObjectContextMenuLogic.java:326-327), and it
--  walks every object on the clicked square, not only the clicked object: a
--  right-click on the floor or wall a controller stands on, and the joypad
--  prompt, which hands the floor over first, built the full submenu with
--  Take in it while this file only looked at `worldobjects` and found no
--  part of ours there. When the fetched generator is a real one, its menu
--  stays, controller beside it or not.
local function stripGeneratorMenu(context, test)
    if test or not context or not context.removeOptionByName then return end
    local fv = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
    local g = fv and fv.generator
    if g and P.partOf(g) == "controller" then
        context:removeOptionByName(getText("ContextMenu_Generator"))
    end
end

--- Strip vanilla's Remove Battery when the light it was built for is one of
--  the solar lamps, whose battery is built in. Keyed on the light switch the
--  menu was actually BUILT for, as stripGeneratorMenu is on the generator:
--  vanilla fetches every object on the clicked square, so a right-click on
--  the ground beside the stake or pole, and the joypad, built the row while
--  `worldobjects` held no lamp (review, 2026-09-26). OG_Lamps refuses the
--  action itself as well.
local function stripLampBattery(context, test)
    if test or not context or not context.removeOptionByName then return end
    local fv = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
    local l = fv and fv.lightSwitch
    if l and P.partOf(l) == "lamp" then
        context:removeOptionByName(getText("ContextMenu_Remove_Battery"))
    end
end

--- A solar lamp's menu. The switch, the bulb and the light are vanilla's
--  own rows (Turn On / Turn Off, Remove Light Bulb): the lamp IS a vanilla
--  light. This adds one line saying how charged it is and what it will do.
--  Vanilla's Remove Battery goes in stripLampBattery, keyed on the light the
--  rows were built for: removed here by its label, it took the row of another
--  battery lamp vanilla had fetched instead (review, 2026-09-26).
function C.lampMenu(context, worldobjects, target)
    local sub = C.icon(context:addOption(getText("ContextMenu_OffGrid"), worldobjects, nil),
                       context, "offgrid")
    local menu = ISContextMenu:getNew(context)
    context:addSubMenu(sub, menu)
    local line = menu:addOption(OffGrid.Lamps.status(target), nil, nil)
    line.notAvailable = true
    return true
end

function C.onFill(playerNum, context, worldobjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    stripGeneratorMenu(context, test)
    stripLampBattery(context, test)

    local target, part = nil, nil
    for _, o in ipairs(worldobjects) do
        local p = P.partOf(o)
        if p then target, part = o, p break end
    end
    if not target then return end
    if test then return true end

    if part == "lamp" then return C.lampMenu(context, worldobjects, target) end

    local sub = C.icon(context:addOption(getText("ContextMenu_OffGrid"), worldobjects, nil),
                       context, "offgrid")
    local menu = ISContextMenu:getNew(context)
    context:addSubMenu(sub, menu)

    local status = statusText(target, part)
    if status then
        local line = menu:addOption(status, nil, nil)
        line.notAvailable = true
    end

    C.icon(menu:addOption(getText("ContextMenu_OffGrid_Info"), worldobjects,
                          C.onInfo, target, playerObj), menu, "info")

    -- The almanac, on every part, once the sky can be read. The sidebar
    -- button is one route to the same window and can be switched off in the
    -- player's options; this row is the one that reads like the vanilla
    -- generator's own Info entry, which is what was asked for.
    if OffGrid.Almanac and OffGrid.Almanac.knows(playerObj)
            and OffGrid.Forecast and OffGrid.Forecast.open then
        C.icon(menu:addOption(getText("ContextMenu_OffGrid_Almanac"), worldobjects,
                              C.onAlmanac, playerObj), menu, "almanac")
        -- Taking a reading without the window: the window's button is mouse
        -- only, so this row is how a controller player reads the sky at all.
        local why = OffGrid.Almanac.blocked(playerObj)
        local read = C.icon(menu:addOption(getText("IGUI_OffGrid_ReadSky"), worldobjects,
                                           C.onReadSky, playerObj), menu, "readSky")
        if why then
            read.notAvailable = true
            local tip = ISWorldObjectContextMenu.addToolTip()
            tip.description = getText(why)
            read.toolTip = tip
        end
    end

    if part == "controller" then
        C.icon(menu:addOption(getText("ContextMenu_OffGrid_Monitor"), worldobjects,
                              C.onMonitor, target, playerObj),
               menu, "monitor")
        C.coverageMenu(menu, target, playerObj)
        C.buildingMenu(menu, worldobjects, target, playerObj, part)
        local d = P.data(target)
        if d.trip then
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_Reset"), worldobjects,
                                  C.onBreaker, target, playerObj, true), menu, "reset")
        elseif d.online then
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_SwitchOff"), worldobjects,
                                  C.onBreaker, target, playerObj, false), menu, "switchOff")
        else
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_SwitchOn"), worldobjects,
                                  C.onBreaker, target, playerObj, true), menu, "switchOn")
        end

        -- Equalisation. Only offered when there is something it can actually
        -- fix, so it is not a permanent switch nobody understands: a sealed
        -- cabinet must never be equalised and a healthy bank has nothing to
        -- gain, which between them means the row appears exactly when it is
        -- the right thing to do.
        if d.canEqualise then
            local key = d.equalise and "ContextMenu_OffGrid_EqualiseStop"
                                    or "ContextMenu_OffGrid_Equalise"
            local opt = C.icon(menu:addOption(getText(key), worldobjects, C.onEqualise,
                                              target, playerObj, not d.equalise),
                               menu, d.equalise and "equaliseStop" or "equalise")
            -- The server refuses this command beyond arm's reach and says
            -- nothing; a row that works at 2 tiles and silently does not at 4
            -- reads as a broken switch. Grey it out where it will not work,
            -- and say so in its own words: it borrowed the cable's "Too far
            -- for one run of cable", and there is no cable here.
            if not reachable(playerObj, target) then
                opt.notAvailable = true
                opt.toolTip = C.tip(getText("Tooltip_OffGrid_EqualiseReach"))
            end
        end

    elseif part == "transformer" then
        -- A transformer in a system shows the system's coverage and wires
        -- buildings of its own; a loose one only offers its cable rows.
        if liveSys(P.data(target)) then
            C.coverageMenu(menu, target, playerObj)
            C.buildingMenu(menu, worldobjects, target, playerObj, part)
        end

    elseif part == "bank" then
        -- One row. The install and remove rows it replaces were two more code
        -- paths into the same mutation, and the panel does both with the cells
        -- visible instead of guessing which battery the player meant.
        C.icon(menu:addOption(getText("ContextMenu_OffGrid_Cells"), worldobjects,
                              C.onCells, target, playerObj), menu, "cells")

    elseif part == "array" then
        local d = P.data(target)
        if (d.snow or 0) > 0.01 then
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_ClearSnow"), worldobjects,
                                  C.onClear, target, playerObj, "snow"), menu, "clearSnow")
        end
        -- Repair. Condition only ever fell before this: a frame left out in a
        -- wet autumn walked down to a quarter of its output with no way back.
        if (d.condition or 100) < 100 then
            local scrap, screws = findRepairParts(playerObj)
            local opt = C.icon(menu:addOption(getText("ContextMenu_OffGrid_Repair"),
                                              worldobjects, C.onRepair, target,
                                              playerObj, scrap, screws), menu, "repair")
            if not (scrap and screws) then
                opt.notAvailable = true
                opt.toolTip = C.tip(getText("Tooltip_OffGrid_NeedParts"))
            elseif not hasScrewdriver(playerObj) then
                opt.notAvailable = true
                opt.toolTip = C.tip(getText("Tooltip_OffGrid_NeedScrewdriver"))
            end
        end

        local rag, water = findRagAndWater(playerObj)
        local opt = C.icon(menu:addOption(getText("ContextMenu_OffGrid_Clean"),
                                          worldobjects, C.onClear, target, playerObj,
                                          "dirt", rag, water), menu, "clean")
        if (d.soiling or 0) <= 0.01 then
            opt.notAvailable = true
            opt.toolTip = C.tip(getText("Tooltip_OffGrid_AlreadyClean"))
        elseif not rag or not water then
            opt.notAvailable = true
            opt.toolTip = C.tip(getText("Tooltip_OffGrid_NeedRagWater"))
        end
    end

    -- Wiring is offered on every kind, because every kind is either a loose
    -- end, something to land a cable on, or both.
    C.wireMenu(menu, worldobjects, target, playerObj, P.describe(target))

    -- Last row, because it is the one that ends the conversation.
    C.takeDownMenu(menu, worldobjects, target, playerObj)

    C.dimUnavailable(menu)
end

--- Take the part down, without having to see it.
--
--  A Workshop report, 2026-09-21: an enclosed battery cabinet put in a bad
--  spot "cannot be picked up removed or destroyed with a sledge hammer". That
--  is accurate, it is only that one part, and the mod's own permission gate is
--  not what blocks it.
--
--  The sealed cabinet is the ONE thing this mod places that carries `solid`
--  rather than `solidtrans` -- deliberately, as the price of the best storage
--  in the game (tools/build_tiles.py). A solid object blocks line of sight to
--  its own square, and both vanilla ways of removing a placed object are
--  gated on seeing the square, independently and for different reasons:
--
--    * ISMoveableCursor:shouldAddObject returns false for anything that is
--      not a wall or a door on a square failing isCouldSee, so the cabinet
--      never enters the pick-up list and the cursor finds nothing there.
--    * ISDestroyCursor:isValid refuses on the same test, with an exception
--      only for walls and windows reached from the opposite square.
--
--  So a lone cabinet is unreachable from every angle, and the harder the
--  player tries the more it looks like a bug in this mod. The context menu is
--  built from the objects the click hit and asks nothing about vision, which
--  is why this row works where those two cannot.
--
--  It does not reimplement removal. It asks G.mayTake -- the same owner, tool
--  and switch-off rule the cursor asks -- and then queues the engine's own
--  pick-up action, so emptying a rack's batteries onto the floor, unplugging
--  the node, retiring a controller's system and building the item all happen
--  exactly as they do from the cursor, through the hooks already in OG_Place.
function C.takeDownMenu(menu, worldobjects, target, playerObj)
    if not ISMoveableSpriteProps or not ISMoveableSpriteProps.fromObject then
        return
    end
    local sq = target and target:getSquare()
    if not sq or not playerObj then return end

    local props = ISMoveableSpriteProps.fromObject(target)
    if not props or not props.isMoveable then return end

    -- QUIET. The menu is rebuilt as the cursor moves over it, and a refusal
    -- halo per frame is how the pick-up lock earned its rate limit in the
    -- first place. A part this character may not lift simply has no row, the
    -- same as it has no cursor.
    if OffGrid.Place and OffGrid.Place.mayTake
            and not OffGrid.Place.mayTake(playerObj, sq, target, true) then
        return
    end

    local opt = C.icon(menu:addOption(getText("ContextMenu_OffGrid_TakeDown"),
                                      worldobjects, C.onTakeDown, target, playerObj),
                       menu, "takeDown")

    -- The one refusal worth showing rather than hiding: a full bag. Hiding it
    -- would read as the same silence the cabinet already gives.
    local inv = playerObj.getInventory and playerObj:getInventory()
    if inv and inv.hasRoomFor
            and not inv:hasRoomFor(playerObj, props.weight or 0) then
        opt.notAvailable = true
        opt.toolTip = C.tip(getText("Tooltip_OffGrid_TooHeavy"))
    end
end

function C.onTakeDown(worldobjects, object, playerObj)
    if not object or not playerObj then return end
    local sq = object:getSquare()
    if not sq then return end
    -- The menu can outlive what it was built on: another player, a fire or a
    -- zombie can take the part off the square while it is open.
    local objs = sq:getObjects()
    if not objs or not objs:contains(object) then return end

    local props = ISMoveableSpriteProps.fromObject(object)
    if not props or not props.isMoveable then return end

    -- NOT quiet, unlike the menu: this is the moment the player asked, so a
    -- refusal has to explain itself. canPickUpMoveable runs through
    -- canPickUpMoveableInternal, which OG_Place hooks, so the owner lock, the
    -- screwdriver lock and the running-controller rule all answer here.
    if not props:canPickUpMoveable(playerObj, sq, object) then return end

    -- walkToAndEquip is the preamble both vanilla routes use
    -- (ISMoveableCursor:create and ISDisassembleMenu.disassemble). It walks to
    -- a square BESIDE the object, which matters more here than anywhere else:
    -- a sealed cabinet's own square is solid and a ground array's is
    -- solidtrans, so neither can ever be stood on, and a walk aimed at the
    -- object's own tile would fail and take the queued action with it.
    if not (ISMoveableDefinitions and ISMoveableDefinitions.cheat)
            and not props:walkToAndEquip(playerObj, sq, "pickup",
                                         props.spriteName) then
        return
    end

    -- The facing the action puts back on the item, read from the sprite the
    -- part is actually wearing rather than from its ModData: a panel under
    -- snow and the same panel swept are different sprites of the same facing.
    local facing = props.sprite
                   and props:getFaceDirectionFromSpriteName(props.sprite:getName())
    local found = props:findOnSquare(sq, props.spriteName)
    ISTimedActionQueue.add(ISMoveablesAction:new(playerObj, sq, "pickup",
                                                 props.spriteName,
                                                 found or object, facing,
                                                 nil, nil))
end

function C.tip(text)
    local t = ISWorldObjectContextMenu.addToolTip()
    t:setName("")
    t.description = text
    return t
end

function C.onInfo(worldobjects, object, playerObj)
    if OffGrid.Info and OffGrid.Info.open then
        OffGrid.Info.open(playerObj, object)
    end
end

function C.onMonitor(worldobjects, object, playerObj)
    -- No walk. This is a screen to read, and walkAdj would clear whatever the
    -- player already had queued just to open a window.
    OffGrid.Window.open(playerObj, object)
end

function C.onAlmanac(worldobjects, playerObj)
    -- Same rule as the monitor: a window, not a job. A menu row opens, it
    -- never closes: an almanac already up is reopened, so it also takes the
    -- system from where the player stands now. (The sidebar button and the
    -- radial slice toggle, which is what a button does.)
    local F = OffGrid.Forecast
    local cur = F.windowFor and F.windowFor(playerObj)
    if cur then cur:close() end
    F.open(playerObj)
end

function C.onReadSky(worldobjects, playerObj)
    if not OffGrid.Almanac or OffGrid.Almanac.blocked(playerObj) then return end
    ISTimedActionQueue.add(OG_ReadSky:new(playerObj))
end

function C.onBreaker(worldobjects, object, playerObj, on)
    if not C.approach(playerObj, object) then return end
    ISTimedActionQueue.add(OG_ResetBreaker:new(playerObj, object, on))
end

function C.onCells(worldobjects, object, playerObj)
    if not C.approach(playerObj, object) then return end
    OffGrid.Bank.open(playerObj, object)
end

function C.onClear(worldobjects, object, playerObj, mode, rag, water)
    if not C.approach(playerObj, object) then return end
    ISTimedActionQueue.add(OG_ClearArray:new(playerObj, object, mode, rag, water))
end

--- Start or stop an equalisation charge.
--  A flag on the controller rather than a timed action: it runs for days off
--  surplus that would otherwise be clipped, so there is nothing to stand and
--  watch.
----------------------------------------------------------------- wiring

--  A connection is made in two steps because there is nothing to click on in
--  between them. A cable exists only as data: it has no IsoObject and no
--  square, so it can never be hovered, outlined or right-clicked. Every
--  selection path in the game ends at an object on a tile.
--
--  So the interaction is anchored at the ENDS. Pick a part, then pick what to
--  wire it to. The pending choice is a client-side upvalue and nothing more,
--  which is also why it is dropped the moment anything about it stops making
--  sense.

local pending = nil        -- { obj, kind, name }

local function pendingValid(playerObj)
    if not pending then return false end
    if not pending.obj or pending.obj:getObjectIndex() == -1 then
        pending = nil
        return false
    end
    -- Wired by somebody else, or by this player from another menu, since the
    -- source was chosen. Through liveSys, not the raw field: a part carrying a
    -- DEAD claim is exactly the part most in need of being wired, and the raw
    -- check silently cancelled it as the player walked toward the controller.
    if liveSys(P.data(pending.obj)) then
        pending = nil
        return false
    end
    return true
end

function C.onPickSource(worldobjects, object, playerObj)
    local info = P.describe(object)
    if not info then return end
    pending = { obj = object, kind = info.kind,
                name = getItemNameFromFullType(P.itemFor(info.kind, info.mount,
                                                         info.tier) or "") }
end

function C.onClearSource()
    pending = nil
end

function C.onRunCable(worldobjects, target, playerObj)
    if not pendingValid(playerObj) then return end
    local src = pending.obj
    -- Walk to the end the player JUST CLICKED, not the one they marked earlier.
    -- Marking a panel on a roof and then walking downstairs to the controller
    -- is exactly how somebody would really do this, and sending the character
    -- back up the stairs to start the job is the opposite of what they asked
    -- for. The server accepts either end, so standing here is legitimate.
    if not C.approach(playerObj, target) then return end
    pending = nil
    ISTimedActionQueue.add(OG_RunCable:new(playerObj, src, target, false, target))
end

function C.onCutCable(worldobjects, object, playerObj, other)
    if not C.approach(playerObj, object) then return end
    ISTimedActionQueue.add(OG_RunCable:new(playerObj, object, other, true, object))
end

--- Everything this part is wired to, as world objects.
function C.connectionsOf(object, info)
    local out = {}
    local sq = object:getSquare()
    if not sq then return out end
    local d = P.data(object)
    local sysKey = (info.kind == "controller")
        and M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "controller") or liveSys(d)
    if not sysKey then return out end
    local cx, cy, cz = M.parseNodeKey(sysKey)
    if not cx then return out end
    local ctrl = (info.kind == "controller") and object
                 or P.objectAt(cx, cy, cz, "controller")
    if not ctrl then return out end
    local edges = M.wireParse(P.data(ctrl).wire)
    local me = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), info.kind)
    local near = M.wireNeighbours(edges, me)
    for i = 1, #near do
        local x, y, z, kind = M.parseNodeKey(near[i])
        local o = x and P.objectAt(x, y, z, kind)
        if o then out[#out + 1] = { obj = o, kind = kind } end
    end
    return out
end

--- One connection in words, as seen from this part: its name and how to get
--  there ("Solar Array, 3 tiles east, 1 tile south"). The Info panel's Wired
--  to list and the cut menu print the same line, so the row a player cuts is
--  the one they read.
function C.linkText(object, other)
    local li = other and P.describe(other)
    local name = li and getItemNameFromFullType(
        P.itemFor(li.kind, li.mount, li.tier) or "") or "?"
    local sq, osq = object and object:getSquare(), other and other:getSquare()
    if not (sq and osq) then return name end
    return P.txt("IGUI_OffGrid_InfoLink", name,
                 P.offsetText(sq:getX(), sq:getY(), sq:getZ(),
                              osq:getX(), osq:getY(), osq:getZ()))
end

--- The wiring rows for one part.
function C.wireMenu(menu, worldobjects, target, playerObj, info)
    local d = P.data(target)
    local sysKey = (info.kind == "controller") and "self" or liveSys(d)

    -- Step one: choose this part as the loose end.
    if info.kind ~= "controller" and not sysKey then
        if pending and pending.obj == target then
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_WireCancel"),
                                  worldobjects, C.onClearSource), menu, "wireCancel")
        else
            C.icon(menu:addOption(getText("ContextMenu_OffGrid_WireFrom"),
                                  worldobjects, C.onPickSource, target, playerObj),
                   menu, "wireFrom")
        end
    end

    -- Step two: land it on something that is already part of a system.
    if pendingValid(playerObj) and pending.obj ~= target and sysKey
            and M.wireLegal(pending.kind, info.kind) then
        local sq, ps = target:getSquare(), pending.obj:getSquare()
        local far = false
        if sq and ps then
            local dx, dy = sq:getX() - ps:getX(), sq:getY() - ps:getY()
            -- The same rule the server applies (S.connect): a power line to
            -- or from a transformer runs further than a panel or battery lead.
            local reach = M.cableReach(pending.kind, info.kind, P.sandbox("LinkRadius"),
                                       P.sandbox("GridLinkRadius"))
            far = (dx * dx + dy * dy) > reach * reach
        end
        local opt = C.icon(menu:addOption(
            P.txt("ContextMenu_OffGrid_WireTo", pending.name or "?"),
            worldobjects, C.onRunCable, target, playerObj), menu, "wireTo")
        if far then
            opt.notAvailable = true
            local tip = ISWorldObjectContextMenu.addToolTip()
            tip.description = getText("IGUI_OffGrid_WireFar")
            opt.toolTip = tip
        end
    end

    -- And cutting, one row per connection, anchored at this end because the
    -- cable itself can never be the thing you click. Each row says where the
    -- other end is: two arrays wired to one controller were two rows reading
    -- "Solar Array" and nothing else.
    local links = C.connectionsOf(target, info)
    if #links > 0 then
        local sub = C.icon(menu:addOption(getText("ContextMenu_OffGrid_WireCut")),
                           menu, "wireCut")
        local ctx = ISContextMenu:getNew(menu)
        menu:addSubMenu(sub, ctx)
        for i = 1, #links do
            ctx:addOption(C.linkText(target, links[i].obj), worldobjects,
                          C.onCutCable, target, playerObj, links[i].obj)
        end
    end
end

function C.onEqualise(worldobjects, object, playerObj, on)
    if not object then return end
    local sq = object:getSquare()
    if not sq then return end
    -- Never written here. A client's transmitModData() replaces the object's
    -- whole ModData table on the server, so setting one flag from the client
    -- would also clobber the live charge the server has been keeping.
    C.send(playerObj, "equalise",
           { x = sq:getX(), y = sq:getY(), z = sq:getZ(),
             on = on and true or false })
end

function C.onRepair(worldobjects, object, playerObj, scrap, screws)
    if not object or not scrap or not screws then return end
    if not C.approach(playerObj, object) then return end
    ISTimedActionQueue.add(OG_RepairArray:new(playerObj, object, scrap, screws))
end

------------------------------------------------------- coverage and buildings

--- Show / Hide power coverage: the whole system's reach, from the controller
--  or from any transformer in it.
function C.coverageMenu(menu, target, playerObj)
    local coverage = OffGrid.Coverage
    if not coverage then return end
    local shown = coverage.isSelected(target, playerObj)
    local key = shown and "ContextMenu_OffGrid_HideCoverage" or "ContextMenu_OffGrid_ShowCoverage"
    local option = C.icon(menu:addOption(getText(key), target, coverage.toggle, playerObj),
                          menu, shown and "coverageHide" or "coverageShow")
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = getText("Tooltip_OffGrid_Coverage")
    option.toolTip = tip
end

--- Wire up the building, Choose buildings..., Unwire the buildings.
--
--  Sent to the authority, which resolves the building, checks the reach and
--  stores the footprint; never written here (see C.onEqualise for why a
--  client must not push a part's ModData). The server accepts these from
--  anywhere within the part's own reach, so there is no walk: the player is
--  on site, and the Building Picker is used from where they stand.
function C.buildingMenu(menu, worldobjects, target, playerObj, part)
    local n = wiredCount(P.data(target))
    if n == 0 then
        local opt = C.icon(menu:addOption(getText("ContextMenu_OffGrid_WireBuilding"), worldobjects,
                                          C.onWireBuilding, target, playerObj),
                           menu, "wireBuilding")
        opt.toolTip = C.tip(getText("Tooltip_OffGrid_WireBuilding"))
    end
    local pick = C.icon(menu:addOption(getText("ContextMenu_OffGrid_ChooseBuildings"), worldobjects,
                                       C.onChooseBuildings, target, playerObj),
                        menu, "chooseBuildings")
    pick.toolTip = C.tip(getText("Tooltip_OffGrid_ChooseBuildings"))
    if n > 0 then
        local opt = C.icon(menu:addOption(P.txt("ContextMenu_OffGrid_UnwireBuildings", n), worldobjects,
                                          C.onUnwireBuildings, target, playerObj),
                           menu, "unwireBuildings")
        opt.toolTip = C.tip(getText("Tooltip_OffGrid_UnwireBuildings"))
    end
end

local function partArgs(object)
    local sq = object and object:getSquare()
    if not sq then return nil end
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ(), kind = P.partOf(object) }
end

function C.onWireBuilding(worldobjects, object, playerObj)
    local args = partArgs(object)
    if args then C.send(playerObj, "bwDefault", args) end
end

function C.onUnwireBuildings(worldobjects, object, playerObj)
    local args = partArgs(object)
    if args then C.send(playerObj, "bwClear", args) end
end

function C.onChooseBuildings(worldobjects, object, playerObj)
    -- OG_Picker loads after this file (see the note on OG_Info at the top),
    -- so it is reached through its table, not required.
    if OffGrid.Picker and OffGrid.Picker.open then OffGrid.Picker.open(playerObj, object) end
end

Events.OnFillWorldObjectContextMenu.Add(C.onFill)

return C

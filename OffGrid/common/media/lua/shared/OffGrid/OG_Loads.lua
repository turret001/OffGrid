--[[ OffGrid -- what a light or appliance draws.

     The load model the simulation bills (OG_System's sweep, OG_Distrib's
     buildings) and the coverage overlay lights (OG_Coverage): which objects
     count, under what kind, at how many watts, and whether they are running.
     Shared, because a multiplayer client never loads OG_System past its
     isClient guard and the overlay has to answer with the same rules, so
     every glow on screen is a line on the LOADS page (2026-09-26). Moved
     here verbatim from OG_System.lua.
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Loads = OffGrid.Loads or {}
local L = OffGrid.Loads
local P = OffGrid.Parts
local try = P.try

-- Watts drawn by each kind of appliance while it is actually running. These
-- are the mod's own numbers: vanilla's getGeneratorPowerConsumption() only
-- ever returns non-zero for fridges, freezers and fuel pumps, so it is no use
-- as a load model.
local DRAW = {
    fridge = 120, freezer = 150, fridgefreezer = 200,
    light = 55, stove = 1400, microwave = 900,
    toaster = 800, coffeemaker = 1000, pump = 500,
    washer = 480, dryer = 1800, washerdryer = 1200,
    radio = 22, tv = 95, charger = 250,
}

-------------------------------------------------------------------- helpers

-- An appliance nothing here recognises still draws something. The engine's own
-- figure is a balance scale rather than watts (a light switch is 0.002 and a
-- fridge 0.08, which no real pair of appliances is), so there is no honest
-- conversion. This is the median of the mappings below, used only so a modded
-- appliance costs a plausible amount instead of nothing.
local UNKNOWN_WATTS_PER_UNIT = 5000

--- What kind of appliance is this, whether or not it is running.
--
--  Classification is separate from activation so the LOADS page can list
--  a switched-off TV the way a real install sheet would: present, rated,
--  drawing nothing. Fridges and freezers first: the engine collapses both
--  into one constant and the mod wants to tell them apart. Returns kind,
--  rated watts, and whether the kind is refrigeration; nil for anything
--  the ladder cannot name (those still bill as "other" when running, but
--  an unknown idle object has no rated number worth printing).
-- Countertop cooking appliances the engine calls IsoStove. They carry
-- IsoType = IsoStove and NO container at all, so CellLoader's own isStove test
-- never sees them but ISMoveableSpriteProps does: put one down and it bills at
-- the oven's 1400 W. isMicrowave() cannot tell them apart either, because it
-- reads getContainer():isMicrowave() and their container is nil. The tile's own
-- GroupName and CustomName are the only thing left, and they are raw tiledef
-- data rather than anything translated, so they are safe to match on.
local COUNTERTOP = {
    ["Small Chrome Toaster"] = "toaster",
    ["Coffee X-press"]       = "coffeemaker",
    ["Espresso Deluxe"]      = "coffeemaker",
}

--- One sprite property of a world object, or nil.
local function spriteProp(obj, name)
    local spr = try(obj, "getSprite")
    local props = spr and try(spr, "getProperties")
    if not props or not try(props, "has", name) then return nil end
    return try(props, "get", name)
end

--- The name a tile gives itself: "GroupName CustomName", the same pair the
--  game builds its moveable display name from.
local function tileName(obj)
    local g = spriteProp(obj, "GroupName")
    local c = spriteProp(obj, "CustomName")
    if not g and not c then return nil end
    return ((g or "") .. " " .. (c or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

--- The room a wall switch lights, as "x,y,z", or nil.
--
--  A lightswitch tile without `lightR` is a room switch: every one in a room
--  shares the room's one light (room.def.lightsActive; IsoLightSwitch.java:
--  72-96, 513-520), so LOADS bills the room once, by this key, however many
--  switches it has (Can, 2026-10-02: hotel rooms have two). A lamp carries
--  `lightR` and a light of its own; a switch with no room keeps its own
--  state. Both answer nil and bill per object. The key is the room's first
--  rect origin, a square of that room and no other: a RoomDef ID is
--  (cellY<<16|cellX)<<32|index (RoomID.makeID), past 2^53 on most of the
--  map, where Kahlua's doubles merge neighbouring rooms.
local function roomKey(obj)
    if spriteProp(obj, "lightR") ~= nil then return nil end
    local sq = try(obj, "getSquare")
    local room = sq and try(sq, "getRoom")
    local def = room and try(room, "getRoomDef")
    local rects = def and try(def, "getRects")
    if not rects or (try(rects, "size") or 0) < 1 then return nil end
    local r = rects:get(0)
    local x, y, z = try(r, "getX"), try(r, "getY"), try(def, "getZ")
    if not (x and y and z) then return nil end
    return x .. "," .. y .. "," .. z
end

--- A wall switch on a square with no room: the engine makes it a room switch
--  with no room (CellLoader.java:105-125), keeps it on for good and lights
--  nothing with it (switchLight lights a room or the switch's own lamp, and
--  it has neither; IsoLightSwitch.java:72-96, 513-540). 1,438 on the map,
--  most of them signs. It was billed 55 W for ever; it is not a light.
--  Asked only where the sprite and the square answer, so an object the
--  engine cannot describe keeps its bill.
local function deadSwitch(obj)
    local spr = try(obj, "getSprite")
    local props = spr and try(spr, "getProperties")
    if not props or try(props, "has", "lightR") then return false end
    local sq = try(obj, "getSquare")
    return sq ~= nil and try(sq, "getRoom") == nil
end

--- A lamp nobody can switch: no room, and not a moveable, so the engine
--  refuses every setActive (IsoLightSwitch.java:484-495). Theatre lights,
--  mostly: 1,387 on the map. It burns while it has power and is billed, but
--  LIGHTS OFF cannot put it out (OG_System S.lightsOff).
local function fixedLight(obj)
    if spriteProp(obj, "lightR") == nil then return false end
    local sq = try(obj, "getSquare")
    if not sq or try(sq, "getRoom") ~= nil then return false end
    return try(obj, "getCanBeModified") == false
end

local function classify(obj)
    local fridge = try(obj, "getContainerByType", "fridge")
    local freezer = try(obj, "getContainerByType", "freezer")
    if fridge and freezer then return "fridgefreezer", DRAW.fridgefreezer, true end
    if fridge then return "fridge", DRAW.fridge, true end
    if freezer then return "freezer", DRAW.freezer, true end
    -- The third thing vanilla itself bills, after fridges and freezers: piped
    -- fuel makes couldBePoweredByGenerator true and getGeneratorPowerConsumption
    -- answer 0.03, so a gas pump always reached the page, but as OTHER, which
    -- tells the player nothing. A gas station is a common base.
    if (try(obj, "getPipedFuelAmount") or 0) > 0 then
        return "pump", DRAW.pump, false
    end
    if instanceof(obj, "IsoLightSwitch") then return "light", DRAW.light, false end
    if instanceof(obj, "IsoStove") then
        -- A microwave is an IsoStove too, so this test has to come first or
        -- every microwave bills at the oven's rate under the oven's name.
        -- Worse than the wrong number: the LOADS row is keyed by kind, and an
        -- idle kind is hidden whenever that kind also has something running
        -- (writePages), so a microwave sharing "stove" with a lit oven
        -- disappears from the page entirely. Both tiles are IsoStove by the
        -- tiledefs' own IsoType, which ISMoveableSpriteProps honours on
        -- placement (corpus lua, line 2161); CellLoader's narrower isStove
        -- test does not, which is why a map-spawned microwave draws nothing
        -- and the same microwave put down by a player draws 1400 W.
        if try(obj, "isMicrowave") then return "microwave", DRAW.microwave, false end

        -- No container at all is what marks the countertop appliances out: an
        -- oven has a stove container and a microwave has a microwave one.
        if not try(obj, "getContainer") then
            local kind = COUNTERTOP[tileName(obj) or ""]
            if kind then return kind, DRAW[kind], false end
            -- Something else small enough to stand on a worktop, which this
            -- list has never heard of. Naming it an oven would be a guess with
            -- a 1400 W price on it, so let it fall through to "other", where
            -- the bill is scaled from what the engine actually reports rather
            -- than from a nameplate we made up. A floor-standing IsoStove with
            -- no container is a real oven (Bake-O-Matic) and keeps its name.
            if spriteProp(obj, "IsTableTop") ~= nil then return nil end
        end

        return "stove", DRAW.stove, false
    end
    if instanceof(obj, "IsoStackedWasherDryer") then
        return "washerdryer", DRAW.washerdryer, false
    end
    if instanceof(obj, "IsoCombinationWasherDryer") then
        return "washerdryer", DRAW.washerdryer, false
    end
    if instanceof(obj, "IsoClothingDryer") then return "dryer", DRAW.dryer, false end
    if instanceof(obj, "IsoClothingWasher") then return "washer", DRAW.washer, false end
    if instanceof(obj, "IsoCarBatteryCharger") then return "charger", DRAW.charger, false end
    if instanceof(obj, "IsoTelevision") then return "tv", DRAW.tv, false end
    if instanceof(obj, "IsoRadio") then return "radio", DRAW.radio, false end
    return nil
end

--- Watts a single world object draws from THIS system right now.
--
--  Returns watts, cold?, kind, rated watts, units. Kind and rated come back
--  even at zero draw, so the caller can tell "idle appliance" from "not an
--  appliance"; a bare 0 is not an appliance at all. `units` is the engine's
--  own getGeneratorPowerConsumption for everything that is billed, and nil
--  whenever nothing is: what a vanilla generator burns petrol for, and so
--  what a backup generator is billed (OG_BackupSys, 2026-09-27). Sixth,
--  for a wall switch, the room whose one light it switches (roomKey), lit or
--  not; nil for anything else.
--
--  The three questions the engine answers better than a hand-written ladder:
--    couldBePoweredByGenerator()   is this a candidate at all
--    ItemContainer.isObjectPowered(obj, false)  is the town grid still paying
--    getGeneratorPowerConsumption() > 0         is it switched on right now
--  This is verbatim the combination IsoGenerator.setSurroundingElectricity
--  uses. Everything a mod subclasses off those nine appliance classes is
--  counted for free, which the old ladder scored as zero.
local function objectDraw(obj)
    if not obj then return 0 end
    if not try(obj, "couldBePoweredByGenerator") then return 0 end

    -- A battery radio is not on your supply and never will be. IsoRadio
    -- answers 0.01 only when the set is on AND not battery powered
    -- (IsoRadio.java:29-31), so without this it sits on the LOADS page for
    -- ever, dim, at a rated draw it can never take, and switching it on does
    -- nothing. A bare 0 keeps it off the page entirely, the way anything that
    -- is not an appliance is kept off. Deliberately narrow: IsoTelevision
    -- ignores the battery flag and bills whenever it is on
    -- (IsoTelevision.java:225-227), so a set that is not a radio is left alone.
    if instanceof(obj, "IsoRadio") then
        local dd = try(obj, "getDeviceData")
        if dd and try(dd, "getIsBatteryPowered") then return 0 end
    end
    -- The same for a light on its own battery: the solar lamps, and a vanilla
    -- lamp fitted with a battery connector. The engine lights it from that
    -- battery alone (canSwitchLight), yet counts it as a generator load
    -- whenever it is on (IsoLightSwitch.getGeneratorPowerConsumption), so each
    -- lit solar lamp in reach was billed as a 55 W light, and an idle one sat
    -- on LOADS (review, 2026-09-26). A petrol generator in reach still counts
    -- it; that is the engine's own accounting and not ours to change.
    if instanceof(obj, "IsoLightSwitch") and try(obj, "getUseBattery") == true then
        return 0
    end
    -- A wall switch with no room lights nothing (deadSwitch): not a load,
    -- and so not listed and no glow (2026-10-02).
    if instanceof(obj, "IsoLightSwitch") and deadSwitch(obj) then return 0 end
    local kind, rated, coldKind = classify(obj)
    -- A wall switch's room (roomKey): readSquare bills the room once.
    local rk = kind == "light" and roomKey(obj) or nil

    -- Before the hydro shutoff the grid is still paying for this appliance, so
    -- billing it to the bank would invent a load that is not there. Passing
    -- includeGenerators = false is what makes this "grid only".
    if ItemContainer and ItemContainer.isObjectPowered then
        local ok, onGrid = pcall(ItemContainer.isObjectPowered, obj, false)
        if ok and onGrid then return 0, false, kind, rated, nil, rk end
    end

    -- The engine's own on/off answer. A switched-off light, stove, TV, radio,
    -- washer, dryer or charger all return 0 here, which is the half of the old
    -- ladder that was wrong for the charger and missing for stacked units.
    local raw = try(obj, "getGeneratorPowerConsumption") or 0
    if raw <= 0 then return 0, false, kind, rated, nil, rk end

    -- Mirror the engine's own exterior gate. setSurroundingElectricity only
    -- powers an exterior appliance when AllowExteriorGenerator is on
    -- (IsoGenerator.java:315), so with the option off an outdoor floodlight
    -- was BILLED to the bank while drawing nothing the engine would honour --
    -- phantom load, wrong runtime forecast.
    local so = getSandboxOptions and getSandboxOptions()
    local allowExt = so and so:getOptionByName("AllowExteriorGenerator")
    if allowExt and allowExt.getValue and allowExt:getValue() == false then
        local osq = try(obj, "getSquare")
        if osq and try(osq, "isOutside") then return 0, false, kind, rated, nil, rk end
    end

    if kind == "washerdryer" and instanceof(obj, "IsoStackedWasherDryer") then
        -- The only class whose draw is a SUM rather than a ternary: each half
        -- runs independently, so the engine returns 0, 0.9 or 1.8.
        local n = 0
        if try(obj, "isWasherActivated") then n = n + 1 end
        if try(obj, "isDryerActivated") then n = n + 1 end
        if n == 0 then return 0, false, "washerdryer", rated end
        -- raw is the engine's sum of both halves, what vanilla bills
        return n == 2 and DRAW.washerdryer or DRAW.washer,
               false, n == 2 and "washerdryer" or "washer", rated, raw
    end
    if kind then return rated, coldKind, kind, rated, raw, rk end

    return raw * UNKNOWN_WATTS_PER_UNIT, false, "other", nil, raw
end

L.DRAW = DRAW
L.classify = classify
L.objectDraw = objectDraw
L.fixedLight = fixedLight
-- One number: a backup generator's charging and every load watt with no
-- engine unit are billed at this rate too (OG_BackupSys hands it to M.step).
L.WATTS_PER_UNIT = UNKNOWN_WATTS_PER_UNIT

return L

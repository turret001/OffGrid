--[[ OffGrid -- the backup generator: what both sides agree on.

     A backup generator is an Off-Grid part of its own (kind "backup"), made
     by converting a vanilla generator. To the engine it is a plain IsoObject,
     never an IsoGenerator, so no vanilla action and no mod keyed on
     IsoGenerator can switch it on, fuel it or give it a circle of its own:
     it only ever feeds the controller it is cabled to.

     This file is everything about a backup that the menus (client) and the
     authority (timed actions, commands, the tick) must answer alike:

       * the numbers: the tank, the barrels, Auto's timers, and each brand's
         output, noise and wear (noise and wear are its vanilla item's own);
       * which vanilla generators convert, and to which brand and facing;
       * the two strings a backup keeps: the barrels a unit draws from
         (`feeds`, on the unit) and the controller's copy of every unit it
         runs (`bkMirror`). Strings, because a pick-up copy drops every
         table field, and a rotation is a pick-up;
       * barrels: which object on a square is one, how much petrol it holds
         and whether that is all it holds, and which unit holds it;
       * every refusal. Each returns a translation key, or nil when the thing
         may be done, and only reads: the greyed menu row and the authority's
         check before it acts ask the same function and give the same reason.

     Loaded on both sides, after OG_Model and OG_Parts. Nothing of OG_Place's
     or the server's is required: OffGrid.Place, OffGrid.System and
     OffGrid.Buildings are looked up when a function runs, and a missing one
     reads as "not available", because the headless suites load subsets of
     the tree.
]]

require "OffGrid/OG_Model"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Buildings"

OffGrid = OffGrid or {}
OffGrid.Backup = OffGrid.Backup or {}
local K = OffGrid.Backup
local P = OffGrid.Parts
local M = OffGrid.Model
local try = P.try
local floor = math.floor

---------------------------------------------------------------- the numbers

-- The tank, in litres: a vanilla generator's (IsoGenerator.getMaxFuel), so
-- a unit converted back hands all of it to the generator it becomes.
K.TANK = 10
-- The barrels top the tank up while it holds less than this.
K.TOPUP_BELOW = 9
-- Units one controller runs, and barrels one unit draws from.
K.MAX_UNITS = 4
K.MAX_FEEDS = 8
-- One Rubber Hose reaches a barrel this many tiles away in a straight line
-- (dx*dx + dy*dy <= 25), on the unit's own level.
K.FEED_RANGE = 5
-- Auto's timers, in world hours: the shortest run, how long the sun must
-- carry the house before Auto stops a unit, and the rest after Auto stops
-- one. The first two, and the idle burn below, are the model's numbers
-- (M.autoPlan and M.fuelUse read them there, and OG_Model loads first), so
-- each exists once; the figure after `or` only keeps this file whole on a
-- tree whose model does not carry them yet.
K.MIN_RUN = M.AUTO_MIN_RUN or 0.5
K.SUN_HOLD = M.AUTO_SUN_HOLD or 0.5
K.REST = 0.5
-- The vanilla units a running generator burns before any appliance, times
-- the server's Generator Fuel Consumption (IsoGenerator's own sum).
K.IDLE_UNITS = M.BACKUP_IDLE_UNITS or 0.02
-- Charging, and loads with no vanilla figure, are billed at OG_Loads' one
-- vanilla unit per 5 kW (OffGrid.Loads.WATTS_PER_UNIT). It is read there,
-- not copied here.
--
-- A tank at or below this is empty. Fuel is a Lua number, never the
-- engine's float, but a subtraction can still leave a crumb, and a crumb
-- that let a unit start would only see it stop again for NO FUEL.
K.DRY = 1e-6
K.HOSE = "Base.RubberHose"
K.SCRAP = "Base.ElectronicsScrap"
-- Backfire, as vanilla rolls it (IsoGenerator.update): at or below each
-- condition, 1 in N per running hour. A sound and nothing else: Can ruled
-- out fire and explosion from wear.
K.BACKFIRE = { { 20, 5 }, { 30, 10 }, { 40, 15 } }
-- The sound a backfire makes for zombies: vanilla's radius and volume.
K.WORLD_SOUND_BACKFIRE = { radius = 40, volume = 60 }
-- How far from a running unit a player still hears it.
K.EMITTER_RANGE = 30

------------------------------------------------------------------ the brands

--- The four vanilla generators, keyed by the taxonomy's backup tiers.
--
--  `item` is the vanilla item a unit was converted from and goes back to.
--  `rating` is its output in watts: Claude's figures, which Can accepted as
--  adjustable. The rest is vanilla's: `radius` and `volume` are the item's
--  SoundRadius and SoundVolume and `wearN` its ConditionLowerChanceOneIn
--  (media/scripts/generated/items/normal.txt), and `sound` is its tiles'
--  GeneratorSound prefix, which names the Loop, Starting, Stopping and
--  Backfire sounds. `lcd` is the brand on the OG-1200's screen, `name` in
--  menus and cards. tests/test_backup.py holds each vanilla figure to the
--  game's own files.
K.BRANDS = {
    valutech  = { item = "Base.Generator_Blue", rating = 2500, radius = 23, volume = 1,
                  wearN = 24, sound = "Generator",
                  lcd = "IGUI_OffGrid_BrandValuTech", name = "IGUI_OffGrid_BrandNameValuTech" },
    old       = { item = "Base.Generator_Old", rating = 3000, radius = 25, volume = 1,
                  wearN = 25, sound = "OldGenerator",
                  lcd = "IGUI_OffGrid_BrandOld", name = "IGUI_OffGrid_BrandNameOld" },
    lectromax = { item = "Base.Generator", rating = 4000, radius = 20, volume = 1,
                  wearN = 30, sound = "Generator",
                  lcd = "IGUI_OffGrid_BrandLectromax", name = "IGUI_OffGrid_BrandNameLectromax" },
    premium   = { item = "Base.Generator_Yellow", rating = 5000, radius = 20, volume = 1,
                  wearN = 36, sound = "Generator",
                  lcd = "IGUI_OffGrid_BrandPremium", name = "IGUI_OffGrid_BrandNamePremium" },
}

--- The brand behind each vanilla item.
K.BRAND_OF_ITEM = {
    ["Base.Generator_Blue"] = "valutech",
    ["Base.Generator_Old"] = "old",
    ["Base.Generator"] = "lectromax",
    ["Base.Generator_Yellow"] = "premium",
}

--- The sprites a vanilla generator stands on (the appliances_misc_01
--  tileset in newtiledefinitions), with the brand and the facing each shows.
--  Three groups run E, S, W, N. The Blue one does not: 12 is S, 13 E, 14 N,
--  15 W.
K.VANILLA_SPRITES = {
    ["appliances_misc_01_0"]  = { tier = "lectromax", facing = "E" },
    ["appliances_misc_01_1"]  = { tier = "lectromax", facing = "S" },
    ["appliances_misc_01_2"]  = { tier = "lectromax", facing = "W" },
    ["appliances_misc_01_3"]  = { tier = "lectromax", facing = "N" },
    ["appliances_misc_01_4"]  = { tier = "old", facing = "E" },
    ["appliances_misc_01_5"]  = { tier = "old", facing = "S" },
    ["appliances_misc_01_6"]  = { tier = "old", facing = "W" },
    ["appliances_misc_01_7"]  = { tier = "old", facing = "N" },
    ["appliances_misc_01_8"]  = { tier = "premium", facing = "E" },
    ["appliances_misc_01_9"]  = { tier = "premium", facing = "S" },
    ["appliances_misc_01_10"] = { tier = "premium", facing = "W" },
    ["appliances_misc_01_11"] = { tier = "premium", facing = "N" },
    ["appliances_misc_01_12"] = { tier = "valutech", facing = "S" },
    ["appliances_misc_01_13"] = { tier = "valutech", facing = "E" },
    ["appliances_misc_01_14"] = { tier = "valutech", facing = "N" },
    ["appliances_misc_01_15"] = { tier = "valutech", facing = "W" },
}

-------------------------------------------- generators, and who may convert

--- An object's ModData, or nil while it has none. getModData() CREATES an
--  empty table on an object that had none, and asking a question of a
--  vanilla generator or a barrel should leave it as it was.
local function modDataOf(obj)
    if not obj or not obj.getModData then return nil end
    if obj.hasModData and try(obj, "hasModData") ~= true then return nil end
    return try(obj, "getModData")
end

--- Does this character know generators well enough to convert or repair
--  one? Vanilla's own test for fixing a generator
--  (ISWorldObjectContextMenuLogic): Electrical 3, or the Generator recipe
--  that "Magazine: How to Use Generators" teaches. isRecipeActuallyKnown, as
--  vanilla asks it, so the admin know-all-recipes cheat passes here as it
--  does there.
function K.knows(character)
    if not character then return false end
    local perk = Perks and Perks.Electricity
    local lvl = perk and try(character, "getPerkLevel", perk)
    if type(lvl) == "number" and lvl >= 3 then return true end
    return try(character, "isRecipeActuallyKnown", "Generator") == true
end

--- Are backup generators allowed on this server ("Allow backup
--  generators")? Off stops the running ones and refuses conversion;
--  converting one back to a normal generator still works.
function K.allowed()
    return P.sandbox("AllowBackup") ~= false
end

--- The brand and facing of a vanilla generator that may be converted, or
--  nil.
--
--  The sprite names both, and the engine's item type must agree with it.
--  getGeneratorItemType() looks the CURRENT sprite up in a map built from one
--  WorldObjectSprite per generator item and answers "Base.Generator" for any
--  sprite that is not in it (IsoGenerator.java:147-156): every facing but
--  each brand's default, and a save can hold a generator on one. So the
--  brand's own item or that fallback is accepted; any other type is a modded
--  item that claims a vanilla sprite. The generatorFullType the engine
--  stamps on a generator built from an item (setInfoFromItem) must not name
--  another item either. An Off-Grid controller wears the mod's own sprite
--  and never matches.
function K.brandOfGenerator(gen)
    if not gen or not instanceof(gen, "IsoGenerator") then return nil end
    local spr = try(gen, "getSprite")
    local name = spr and try(spr, "getName")
    local v = type(name) == "string" and K.VANILLA_SPRITES[name] or nil
    if not v then return nil end
    local brand = K.BRANDS[v.tier]
    local typ = try(gen, "getGeneratorItemType")
    if typ ~= brand.item and typ ~= "Base.Generator" then return nil end
    local md = modDataOf(gen)
    local full = md and md.generatorFullType
    if type(full) == "string" and full ~= brand.item then return nil end
    return v.tier, v.facing
end

--------------------------------------------------------- the stored strings

--- A finite number: not nil, not a string, not NaN, not infinite. Only
--  these are written into a stored string, and only these read back out.
local function finite(v)
    return type(v) == "number" and v == v and v - v == 0
end

-- The feeds: the barrels a unit draws from, kept on the unit as
-- "x,y,z;x,y,z", whole positions in connect order, no repeats, at most
-- K.MAX_FEEDS.

--- A list { { x, y, z }, ... } as the feed string, or nil for none, so the
--  field goes away rather than holding an empty string. A position whose
--  coordinates are not all finite numbers is skipped.
function K.encodeFeeds(list)
    if type(list) ~= "table" then return nil end
    local bits, seen = {}, {}
    for i = 1, #list do
        local p = list[i]
        if #bits < K.MAX_FEEDS and type(p) == "table"
                and finite(p.x) and finite(p.y) and finite(p.z) then
            -- math.floor first: every Kahlua number is a double, and a
            -- position that came out of arithmetic must still be written as
            -- a whole number, which is all decodeFeeds reads.
            local s = floor(p.x) .. "," .. floor(p.y) .. "," .. floor(p.z)
            if not seen[s] then
                seen[s] = true
                bits[#bits + 1] = s
            end
        end
    end
    if #bits == 0 then return nil end
    return table.concat(bits, ";")
end

--- The feed string back as { { x, y, z }, ... }. Anything but a whole
--  position is dropped, and so are repeats and everything past K.MAX_FEEDS:
--  the string comes out of save data, and a damaged one must not feed a unit
--  from more barrels than it may have.
function K.decodeFeeds(str)
    local out, seen = {}, {}
    if type(str) ~= "string" or str == "" then return out end
    for part in string.gmatch(str, "[^;]+") do
        if #out >= K.MAX_FEEDS then break end
        local x, y, z = string.match(part, "^(-?%d+),(-?%d+),(-?%d+)$")
        if x then
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            -- A repeat is the same POSITION, however it was written
            -- ("01,1,0" is "1,1,0").
            local s = x .. "," .. y .. "," .. z
            if not seen[s] then
                seen[s] = true
                out[#out + 1] = { x = x, y = y, z = z }
            end
        end
    end
    return out
end

-- The mirror: the controller's copy of every unit it runs, so a unit whose
-- square is not loaded still runs on paper, and one that comes back is
-- settled from it. One entry per unit, ";" between entries, sorted by node
-- key:
--
--     nodeKey=fuel,cond,run,fault,wear,at,auto,since,rest,feedL
--
-- Numbers to five decimals; since and rest empty when nil; run and auto 1
-- or 0; fault one word or empty. A string, not a table, because a
-- controller's rotation is a pick-up copy, and the copy drops every table
-- field.

local MIRROR_FIELDS = 10

local function num5(v)
    if finite(v) then return string.format("%.5f", v) end
    return ""
end

--- One unit's entry, or nil when its fuel, condition or time is not a
--  finite number: an entry that would not read back is not written.
local function mirrorEntry(k, e)
    if type(e) ~= "table" or not (finite(e.fuel) and finite(e.cond) and finite(e.at)) then
        return nil
    end
    local fault = ""
    if type(e.fault) == "string" and string.match(e.fault, "^%a+$") then fault = e.fault end
    return k .. "=" .. table.concat({
        num5(e.fuel), num5(e.cond), e.run == "on" and "1" or "0", fault,
        num5(e.wear or 0), num5(e.at), e.auto == false and "0" or "1",
        num5(e.since), num5(e.rest), num5(e.feedL or 0),
    }, ",")
end

--- map[nodeKey] = { fuel, cond, run, fault, wear, at, auto, since, rest,
--  feedL } as the mirror string, or nil when there is no unit to write.
--  Only backup node keys are written.
function K.encodeMirror(map)
    if type(map) ~= "table" then return nil end
    local keys = {}
    for k in pairs(map) do
        local _, _, _, kind = M.parseNodeKey(k)
        if kind == "backup" then keys[#keys + 1] = k end
    end
    -- A controller runs at most K.MAX_UNITS units, so a plain insertion sort
    -- does, and it cannot recurse the way Kahlua's table.sort does.
    for i = 2, #keys do
        local k, j = keys[i], i - 1
        while j >= 1 and keys[j] > k do
            keys[j + 1] = keys[j]
            j = j - 1
        end
        keys[j + 1] = k
    end
    local out = {}
    for i = 1, #keys do
        local s = mirrorEntry(keys[i], map[keys[i]])
        if s then out[#out + 1] = s end
    end
    if #out == 0 then return nil end
    return table.concat(out, ";")
end

--- An optional number field: empty is nil, anything else must be a finite
--  number. Returns ok, value.
local function optNum(s)
    if s == "" then return true, nil end
    local v = tonumber(s)
    if finite(v) then return true, v end
    return false, nil
end

--- One entry's ten fields as a table, or nil when any is malformed.
local function mirrorFields(f)
    local fuel, cond, at = tonumber(f[1]), tonumber(f[2]), tonumber(f[6])
    if not (finite(fuel) and finite(cond) and finite(at)) then return nil end
    local run
    if f[3] == "1" then run = "on" elseif f[3] == "0" then run = "off" else return nil end
    local auto
    if f[7] == "1" then auto = true elseif f[7] == "0" then auto = false else return nil end
    local fault = nil
    if f[4] ~= "" then
        if not string.match(f[4], "^%a+$") then return nil end
        fault = f[4]
    end
    local okW, wear = optNum(f[5])
    local okS, since = optNum(f[8])
    local okR, rest = optNum(f[9])
    local okF, feedL = optNum(f[10])
    if not (okW and okS and okR and okF) then return nil end
    return { fuel = fuel, cond = cond, run = run, fault = fault, wear = wear or 0, at = at,
             auto = auto, since = since, rest = rest, feedL = feedL or 0 }
end

--- The mirror string back as map[nodeKey] = { fuel, cond, run ("on" or
--  "off"), fault, wear, at, auto (a boolean), since, rest, feedL }. An entry
--  that is not a backup's node key with ten well-formed fields is dropped,
--  and a unit named twice keeps its first entry.
function K.decodeMirror(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for entry in string.gmatch(str, "[^;]+") do
        local k, body = string.match(entry, "^([^=]+)=(.*)$")
        local _, _, _, kind = M.parseNodeKey(k)
        if kind == "backup" and out[k] == nil then
            -- Split keeping EMPTY fields: a nil `since` is an empty field,
            -- and dropping it would shift every field after it.
            local f = {}
            for v in string.gmatch(body .. ",", "([^,]*),") do f[#f + 1] = v end
            local e = (#f == MIRROR_FIELDS) and mirrorFields(f) or nil
            if e then out[k] = e end
        end
    end
    return out
end

------------------------------------------------------------------- barrels

--- v when it is a finite number, else `default`. A unit's fields are read
--  through this: a field never written, or written by hand, is not one.
local function numOr(v, default)
    if finite(v) then return v end
    return default
end

--- A part's `offgrid` table as it stands, or an empty table. Unlike P.data
--  it fills in no defaults, so a question never writes, not even into a
--  client's own copy; a missing field is read with its default where it is
--  read.
local function unitData(obj)
    local md = modDataOf(obj)
    local d = md and md.offgrid
    if type(d) ~= "table" then return {} end
    return d
end

--- Is this a gas-station pump? Map pumps carry the sprite property
--  "fuelAmount" and keep their fuel in ModData (getPipedFuelAmount), not in a
--  fluid container. The property is asked FIRST, and getPipedFuelAmount only
--  of an object without it: on a pump that getter rolls the fuel the pump
--  starts with, writes it into ModData, sends it and may put a sign up
--  beside it (IsoObject.getPipedFuelAmount), which a question must never do.
--  On anything else it only reads what ModData holds.
function K.isPump(obj)
    if not obj then return false end
    local spr = try(obj, "getSprite")
    local props = spr and try(spr, "getProperties")
    local has = props and try(props, "has", "fuelAmount")
    if has == true then return true end
    -- Unread (no sprite, or the property API failed): the getter below could
    -- be a pump's, so it is not asked either.
    if has ~= false then return false end
    local n = try(obj, "getPipedFuelAmount")
    return type(n) == "number" and n > 0
end

--- The barrel at a position: the first object on that square that holds a
--  fluid container and is not a pump, and that container; nil when the
--  square is not loaded or holds none. An item lying on the floor (a petrol
--  can put down) is passed over: it is an item, carried off in one click,
--  and its fluid travels with it.
function K.findBarrel(x, y, z)
    local sq = getSquare(x, y, z)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and not instanceof(o, "IsoWorldInventoryObject") then
            local fc = try(o, "getFluidContainer")
            if fc and not K.isPump(o) then return o, fc end
        end
    end
    return nil
end

--- The petrol in a fluid container, in litres, and whether petrol is all it
--  holds. Only a pure container feeds a unit; one holding anything else is
--  skipped until it holds only petrol again. An empty container counts as
--  pure, so an empty barrel reads as empty, not as a mix.
function K.petrolIn(fc)
    if not fc or not Fluid or not Fluid.Petrol then return 0, false end
    local n = try(fc, "getSpecificFluidAmount", Fluid.Petrol)
    if not finite(n) or n < 0 then n = 0 end
    if try(fc, "isPureFluid", Fluid.Petrol) == true then return n, true end
    local all = try(fc, "getAmount")
    return n, finite(all) and all <= 0
end

--- Is a barrel at (fx, fy, fz) within a hose of a unit at (ux, uy, uz)? The
--  same level, and K.FEED_RANGE tiles in a straight line.
function K.inFeedRange(ux, uy, uz, fx, fy, fz)
    if uz ~= fz then return false end
    local dx, dy = fx - ux, fy - uy
    return dx * dx + dy * dy <= K.FEED_RANGE * K.FEED_RANGE
end

--- Which unit holds this barrel, as its node key, or nil. A claim is the
--  barrel's ModData `offgridFeed`, written when a hose is connected. It
--  holds only while the unit it names stands on a loaded square and still
--  lists this barrel among its feeds. Any other claim is dead and may be
--  written over: its unit was picked up, converted back or cut loose where
--  nobody could clear the barrel.
function K.feedClaim(barrel)
    local md = modDataOf(barrel)
    local key = md and md.offgridFeed
    local ux, uy, uz, kind = M.parseNodeKey(key)
    if not ux or kind ~= "backup" then return nil end
    local unit = P.objectAt(ux, uy, uz, "backup")
    local sq = unit and try(barrel, "getSquare")
    if not sq then return nil end
    local bx, by, bz = sq:getX(), sq:getY(), sq:getZ()
    local feeds = K.decodeFeeds(unitData(unit).feeds)
    for i = 1, #feeds do
        local f = feeds[i]
        if f.x == bx and f.y == by and f.z == bz then return key end
    end
    return nil
end

--- A unit's tank, and the pure petrol its loaded feeds within a hose hold,
--  in litres. A feed that is not loaded, holds nothing or is mixed adds
--  nothing.
function K.totalFuel(unit)
    local d = unitData(unit)
    local tank = numOr(d.fuel, 0)
    if tank < 0 then tank = 0 end
    local feedL = 0
    local sq = try(unit, "getSquare")
    if not sq then return tank, feedL end
    local ux, uy, uz = sq:getX(), sq:getY(), sq:getZ()
    local feeds = K.decodeFeeds(d.feeds)
    for i = 1, #feeds do
        local f = feeds[i]
        if K.inFeedRange(ux, uy, uz, f.x, f.y, f.z) then
            local _, fc = K.findBarrel(f.x, f.y, f.z)
            local n, pure = K.petrolIn(fc)
            if pure then feedL = feedL + n end
        end
    end
    return tank, feedL
end

------------------------------------------------------ what a player carries

--- A container a unit can be refuelled from: vanilla's own test
--  (predicatePetrol in ISWorldObjectContextMenu), so the can that fills a
--  vanilla generator fills a backup. Only the petrol in it is poured.
function K.predicatePetrol(item)
    if not item or not Fluid or not Fluid.Petrol then return false end
    local fc = try(item, "getFluidContainer")
    if not fc or try(fc, "contains", Fluid.Petrol) ~= true then return false end
    local n = try(fc, "getAmount")
    return finite(n) and n >= 0.099
end

--- Scrap Electronics, the one thing a repair uses.
function K.predicateScrap(item)
    return item ~= nil and try(item, "getFullType") == K.SCRAP
end

----------------------------------------------------------- links and state

--- The controller a unit is cabled to, when it stands on a loaded square, or
--  nil. The menu's liveSys rule made strict: a unit is only started through
--  a controller that is really there.
function K.linkedController(unit)
    local cx, cy, cz, kind = M.parseNodeKey(unitData(unit).sys)
    if not cx or kind ~= "controller" then return nil end
    return P.objectAt(cx, cy, cz, "controller")
end

--- What a unit is doing, as one word for the GEN page, the menus and the
--  card: "running"; "standby" (stopped, and Auto may start it: its own AUTO
--  and the controller's master Auto both on); "off" (stopped, and it will
--  not start by itself); or the fault that stopped it: "nofuel", "fault"
--  (worn out, and a fire, which a repair clears the same way), "indoors",
--  "server". `masterOn` is the controller's Auto; nil reads as on, as an
--  unset bkAuto does.
--
--  A stopped unit whose tank and own barrels hold nothing reads "nofuel"
--  too, whether it ran dry or was never filled: nothing can start it, Auto
--  or a hand (K.startRefusal, "Refuel it first."). Live campaign on 42.21
--  (2026-09-28): a unit that had never run dry read STANDBY with its tank
--  empty while its Start row was grey for want of petrol. Only the word
--  changes; the stored fault, and when Auto may start it, do not.
--  `feedL` is the petrol its own barrels hold, in litres, as the caller
--  knows it (the tick's top-up; K.totalFuel on a client); nil is none, as
--  for a unit whose barrels are out of reach.
function K.unitState(d, masterOn, feedL)
    if type(d) ~= "table" then d = {} end
    local f = d.fault
    if f == "server" then return "server" end
    if f == "indoors" then return "indoors" end
    if f == "fault" or f == "fire" then return "fault" end
    if f == "nofuel" then return "nofuel" end
    if d.run == "on" then return "running" end
    if math.max(0, numOr(d.fuel, 0)) + math.max(0, numOr(feedL, 0)) <= K.DRY then
        return "nofuel"
    end
    if masterOn ~= false and d.auto ~= false then return "standby" end
    return "off"
end

------------------------------------------------------------------ refusals

--  Each returns the translation key of the FIRST reason the thing may not be
--  done, or nil when it may. A menu greys its row with that reason and never
--  hides it (Can: "people should know why they can't convert"), and the
--  authority asks the same function again before it acts, so the two cannot
--  disagree. Within each, the order is the design's: what nobody at the
--  unit can change first (the server's switch), then the object, then the
--  player.

--- Is this square inside a building? B.enclosedAt answers: a map room, or a
--  player-built region that is enclosed and at least half roofed. A load
--  without OG_Buildings answers no, and the tick asks again while a unit
--  runs.
local function enclosed(sq)
    local B = OffGrid.Buildings
    if not sq or not B or not B.enclosedAt then return false end
    local ok, v = pcall(B.enclosedAt, sq:getX(), sq:getY(), sq:getZ())
    return ok and v == true
end

--- Does a backup already stand on this square?
local function backupOn(sq)
    local objs = sq and try(sq, "getObjects")
    if not objs then return false end
    for i = 0, objs:size() - 1 do
        if P.partOf(objs:get(i)) == "backup" then return true end
    end
    return false
end

--- Does this part still honestly claim a controller? The menu's rule
--  (OG_Context liveSys): a claim on a loaded square with no controller on
--  it is dead; one on a square that is not loaded cannot be checked, so it
--  holds.
local function liveClaim(d)
    local cx, cy, cz = M.parseNodeKey(d.sys)
    if not cx then return false end
    if getSquare(cx, cy, cz) and not P.objectAt(cx, cy, cz, "controller") then
        return false
    end
    return true
end

--- Converting a vanilla generator into a backup. An Off-Grid controller is
--  never offered the row; asked anyway, it is a model that cannot be
--  converted, since it wears the mod's own sprite.
function K.convertRefusal(character, gen)
    if not K.allowed() then return "Tooltip_OffGrid_BkServerOff" end
    if not K.brandOfGenerator(gen) then return "Tooltip_OffGrid_BkModded" end
    if try(gen, "isActivated") == true then return "Tooltip_OffGrid_BkTurnOff" end
    -- Unplugged, as vanilla's own Take asks: a mod that plumbs generators
    -- lets go of it through vanilla's Disconnect first.
    if try(gen, "isConnected") == true then return "Tooltip_OffGrid_BkUnplug" end
    local sq = try(gen, "getSquare")
    if enclosed(sq) then return "Tooltip_OffGrid_BkOutside" end
    if backupOn(sq) then return "Tooltip_OffGrid_BkHere" end
    if not K.knows(character) then return "Tooltip_OffGrid_BkSkill" end
    if not P.hasScrewdriver(character) then return "Tooltip_OffGrid_NeedScrewdriver" end
    return nil
end

--- Converting a backup back into a normal generator. The server's pick-up
--  lock first, the same answer Pick up gets (G.takeRefusal: by default the
--  converter, their safehouse and staff), whenever OG_Place is loaded; then
--  the unit must be stopped and uncabled, so no controller loses a unit it
--  is running.
function K.restoreRefusal(character, unit)
    local G = OffGrid.Place
    if G and G.takeRefusal then
        local k = G.takeRefusal(character, try(unit, "getSquare"), unit)
        if k then return k end
    end
    local d = unitData(unit)
    if d.run == "on" then return "Tooltip_OffGrid_BkStopFirst" end
    if liveClaim(d) then return "Tooltip_OffGrid_BkCutFirst" end
    return nil
end

--- Starting a unit, by hand or by Auto: only through a controller that is
--  there, outdoors, with no fire on its square, not broken, and with petrol
--  in its tank or its barrels. A fault the tick clears by itself (nofuel,
--  indoors, server) is judged by its cause, not by the stored word.
function K.startRefusal(unit)
    if not K.allowed() then return "Tooltip_OffGrid_BkServerOff" end
    if not K.linkedController(unit) then return "Tooltip_OffGrid_BkNoLink" end
    local sq = try(unit, "getSquare")
    if sq and try(sq, "haveFire") == true then return "Tooltip_OffGrid_BkFireOut" end
    if enclosed(sq) then return "Tooltip_OffGrid_BkMoveOut" end
    local d = unitData(unit)
    if d.fault == "fault" or d.fault == "fire" or numOr(d.condition, 100) <= 0 then
        return "Tooltip_OffGrid_BkRepairFirst"
    end
    local tank, feedL = K.totalFuel(unit)
    if tank + feedL <= K.DRY then return "Tooltip_OffGrid_BkRefuelFirst" end
    return nil
end

--- Using `obj`'s controls: a unit's AUTO, ON/OFF, Start and Stop, its fuel
--  barrels and its cable, or a controller's GEN master Auto and Start at /
--  Stop at. Can, 2026-09-29 ("Owner's group only (Recommended)"): they
--  follow the pick-up lock's people (G.useRefusal: the owner, their
--  safehouse, staff, and whoever the server's Pick-up option lets lift it),
--  whenever OG_Place is loaded; singleplayer admits anyone. Refuel and
--  Repair never ask it. The menu greys its rows with it, the GEN page its
--  switches, and the authority asks it again first, before any other reason.
function K.lockRefusal(character, obj)
    local G = OffGrid.Place
    if not (G and G.useRefusal and obj) then return nil end
    return G.useRefusal(character, try(obj, "getSquare"), obj)
end

--- Starting or stopping a unit BY HAND: only while its own AUTO is off (Can,
--  2026-09-28: the ON/OFF switch is greyed "until AUTO is disabled for that
--  generator"). Asked before anything else of a hand start or stop, by the
--  GEN page, the menu's Start and Stop rows and the authority (BK.cmdRun),
--  so all three give the same answer. `d` is the unit's ModData, where nil
--  reads as on, or its controller's mirror entry. Only the unit's own AUTO
--  counts, never the controller's master. Auto's own starts and stops never
--  ask it.
function K.handRefusal(d)
    if type(d) == "table" and d.auto ~= false then return "Tooltip_OffGrid_BkAutoFirst" end
    return nil
end

--- Refuelling from `petrol`, the container the player would pour from (nil
--  when they carry none). Allowed while the unit runs, as a vanilla
--  generator is.
function K.refuelRefusal(character, unit, petrol)
    if not K.predicatePetrol(petrol) then return "Tooltip_OffGrid_BkNeedPetrol" end
    if numOr(unitData(unit).fuel, 0) >= K.TANK - 0.01 then
        return "Tooltip_OffGrid_BkTankFull"
    end
    return nil
end

--- Repairing with `scrap`, one Scrap Electronics (nil when the player has
--  none): vanilla's skill rule, and the unit stopped. There must be
--  something to repair: condition under 100, or the fault a repair clears
--  (worn out, or burnt). An empty tank is not a repair.
--
--  Never while its square burns, the first reason, as Start gives it (live
--  campaign on 42.21, 2026-09-28: Start was grey "Put the fire out first."
--  while Repair took the scrap and left the fire fault standing).
function K.repairRefusal(character, unit, scrap)
    local sq = try(unit, "getSquare")
    if sq and try(sq, "haveFire") == true then return "Tooltip_OffGrid_BkFireOut" end
    if not K.knows(character) then return "Tooltip_OffGrid_BkSkill" end
    if not K.predicateScrap(scrap) then return "Tooltip_OffGrid_BkRepairNeedScrap" end
    local d = unitData(unit)
    if d.run == "on" then return "Tooltip_OffGrid_BkStopFirst" end
    if numOr(d.condition, 100) >= 100 and d.fault ~= "fault" and d.fault ~= "fire" then
        return "Tooltip_OffGrid_BkRepairNone"
    end
    return nil
end

--- Connecting `barrel` to a unit with a Rubber Hose from the player's
--  inventory. One barrel feeds one unit, and a gas-station pump never does.
function K.feedRefusal(character, unit, barrel)
    local inv = try(character, "getInventory")
    if try(inv, "containsTypeRecurse", K.HOSE) ~= true then
        return "Tooltip_OffGrid_BkNeedHose"
    end
    if #K.decodeFeeds(unitData(unit).feeds) >= K.MAX_FEEDS then
        return "Tooltip_OffGrid_BkFeedsFull"
    end
    if K.isPump(barrel) then return "Tooltip_OffGrid_BkPump" end
    local us, bs = try(unit, "getSquare"), try(barrel, "getSquare")
    if not us or not bs or not K.inFeedRange(us:getX(), us:getY(), us:getZ(),
                                              bs:getX(), bs:getY(), bs:getZ()) then
        return "Tooltip_OffGrid_BkBarrelFar"
    end
    if K.feedClaim(barrel) then return "Tooltip_OffGrid_BkBarrelTaken" end
    local n, pure = K.petrolIn(try(barrel, "getFluidContainer"))
    if n <= 0 then return "Tooltip_OffGrid_BkBarrelEmpty" end
    if not pure then return "Tooltip_OffGrid_BkBarrelMixed" end
    return nil
end

--- Placing a backup with the moveable cursor: never inside a building, the
--  rule that also stops one running there.
function K.placeRefusal(square)
    if enclosed(square) then return "IGUI_OffGrid_BkIndoors" end
    return nil
end

------------------------------------------------ conversion, on the authority

--- Put `n` Rubber Hoses on the floor of `square`: the hoses a unit's barrels
--  were connected with. The four-argument AddWorldInventoryItem sends each to
--  the clients (IsoGridSquare.java:6525-6527), as G.giveBackCell's batteries
--  are sent. Returns how many it put down, or nil and "client".
function K.dropHoses(square, n)
    if isClient() then return nil, "client" end
    local dropped = 0
    if not square or type(n) ~= "number" then return dropped end
    for _ = 1, math.floor(n) do
        local item = instanceItem(K.HOSE)
        if item then
            square:AddWorldInventoryItem(item, 0.5, 0.5, 0.0)
            dropped = dropped + 1
        end
    end
    return dropped
end

--- Let go of every barrel this unit was fed from, before it leaves: a pick-up
--  (G.stow) or Convert to normal generator. Each loaded barrel whose claim
--  names this unit is freed and pushed; a barrel out of the loaded area keeps
--  a claim that K.feedClaim already reads as dead once the unit is gone (3.5).
--  The unit's feed list is emptied. Returns how many feeds it had, which is
--  how many hoses come back; the caller drops them.
function K.releaseFeeds(unit, square)
    local d = P.data(unit)
    local feeds = type(d.feeds) == "string" and K.decodeFeeds(d.feeds) or {}
    local sq = square or P.try(unit, "getSquare")
    if sq and not isClient() then
        local me = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup")
        for i = 1, #feeds do
            local f = feeds[i]
            local barrel = K.findBarrel(f.x, f.y, f.z)
            local md = barrel and barrel.getModData and barrel:getModData()
            if md and md.offgridFeed == me then
                md.offgridFeed = nil
                if barrel.transmitModData then barrel:transmitModData() end
            end
        end
    end
    d.feeds = nil
    return #feeds
end

--- Convert to Off-Grid backup: a native generator becomes a backup unit.
--
--  Everything is checked, and everything the unit keeps is read, BEFORE the
--  generator leaves its square: a failure after the swap would strand the
--  player's generator. The unit is built the way OG_Seed builds a part: the
--  three-argument IsoObject.new (the two-argument form makes an anonymous
--  sprite, see P.describe), its ModData written and its owner stamped before
--  transmitAddObjectToSquare, so the one packet that sends it carries both
--  (IsoGridSquare.java:6375-6381). Never a lowercase addTileObject, which
--  vanilla's MOGenerator map hook answers by building a fresh generator on a
--  vanilla sprite, and never a second transmitCompleteItemToClients.
--
--  The ModData is an allowlist. Nothing is copied from the generator's own
--  ModData: other mods keep state there (one reads a key named conGenerator
--  on whatever it finds), and none of it describes a backup.
--
--  Returns the unit, or nil and the reason: a refusal key, or "client".
function K.toBackup(gen, character)
    if isClient() then return nil, "client" end
    if not gen or not instanceof(gen, "IsoGenerator") or P.partOf(gen) then
        return nil, "Tooltip_OffGrid_BkModded"
    end
    local refusal = K.convertRefusal(character, gen)
    if refusal then return nil, refusal end
    local tier, facing = K.brandOfGenerator(gen)
    local sq = P.try(gen, "getSquare")
    local at = P.try(gen, "getObjectIndex")
    local name = tier and P.sprite("backup", "ground", tier, "off", facing)
    if not sq or not name or type(at) ~= "number" or at < 0
            or not IsoObject or not IsoObject.new then
        return nil
    end
    -- The tank is a Lua number from here on, never the engine's float, whose
    -- spacing near 10 L swallows a small debit. Vanilla's tank holds 10 L
    -- (IsoGenerator.getMaxFuel), and so does the unit's.
    local fuel = M.clamp(tonumber(P.try(gen, "getFuel")) or 0, 0, K.TANK)
    local condition = M.clamp(tonumber(P.try(gen, "getCondition")) or 100, 0, 100)
    local now = OffGrid.Env and OffGrid.Env.worldHours and OffGrid.Env.worldHours() or 0

    sq:transmitRemoveItemFromSquare(gen)
    local o = IsoObject.new(sq, name, name)
    -- A generator worn to nothing is a unit worn to nothing: FAULT from the
    -- start, which a repair clears, not STANDBY until its first tick.
    o:getModData().offgrid = { kind = "backup", mount = "ground", tier = tier,
                               facing = facing, state = "off", fuel = fuel,
                               condition = condition, auto = true, run = "off",
                               fault = (condition <= 0) and "fault" or nil,
                               at = now }
    if OffGrid.Place and OffGrid.Place.stamp then OffGrid.Place.stamp(o, character) end
    sq:transmitAddObjectToSquare(o, -1)
    sq:RecalcProperties()
    if OffGrid.System and OffGrid.System.register then OffGrid.System.register(o) end
    -- The sound module (singleplayer): AddTileObject fires no event there. A
    -- multiplayer client hears of the unit by OnObjectAdded, and a dedicated
    -- server has no sound module.
    local BS = OffGrid.BackupSound
    if BS and BS.found then BS.found(o) end
    return o
end

--- Convert to normal generator: a backup unit becomes a generator of its brand.
--
--  Refused as K.restoreRefusal says (the server's pickup lock, running, still
--  cabled), and the item the generator is built from must exist, all before
--  anything moves. It is unplugged from any graph that still names it, its
--  barrels are let go and one Rubber Hose per feed goes on the floor; then
--  the unit leaves and the generator is built from an item
--  carrying its condition and tank, the road G.makeController takes: the
--  IsoGenerator constructor reads the condition from the item and only `fuel`
--  from its ModData, and only when that is a Lua number
--  (IsoGenerator.setInfoFromItem, java:124-130). The constructor also puts the
--  generator on the square and, on a server, sends it (java:96-107), so
--  nothing here sends it again. It stands on its brand's default sprite, which
--  the engine picks, and carries no Off-Grid ModData.
--
--  Returns the generator, or nil and the reason: a refusal key, or "client".
function K.toGenerator(unit, character)
    if isClient() then return nil, "client" end
    local info = unit and P.describe(unit)
    if not info or info.kind ~= "backup" then return nil end
    local refusal = K.restoreRefusal(character, unit)
    if refusal then return nil, refusal end
    local brand = K.BRANDS[info.tier]
    local sq = P.try(unit, "getSquare")
    local at = P.try(unit, "getObjectIndex")
    if not brand or not sq or type(at) ~= "number" or at < 0
            or not IsoGenerator or not IsoGenerator.new then
        return nil
    end
    local item = instanceItem(brand.item)
    if not item then return nil end
    local d = P.data(unit)
    item:setCondition(math.floor(M.clamp(tonumber(d.condition) or 100, 0, 100)))
    item:getModData().fuel = M.clamp(tonumber(d.fuel) or 0, 0, K.TANK)

    -- Out of every graph that holds it, while it still stands on its square,
    -- as a pick-up unplugs a part (OG_Place pickUpMoveableInternal). A unit
    -- that gets here claims no controller still standing (K.restoreRefusal
    -- refuses that, and a claim on an area that is not loaded), but its claim
    -- may be a dead one while a graph still names its node; left there, a
    -- backup converted on this square later would be walked straight back
    -- into that system.
    if OffGrid.System and OffGrid.System.unplug then
        OffGrid.System.unplug(M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup"), d.sys)
    end
    K.dropHoses(sq, K.releaseFeeds(unit, sq))
    sq:transmitRemoveItemFromSquare(unit)
    local cell = (getWorld and getWorld() and getWorld():getCell()) or getCell()
    local gen = IsoGenerator.new(item, cell, sq)
    if IsoGenerator.updateGenerator then IsoGenerator.updateGenerator(sq) end
    return gen
end

return K

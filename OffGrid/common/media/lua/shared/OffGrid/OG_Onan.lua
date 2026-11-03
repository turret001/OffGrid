--[[ OffGrid -- the Cummins Onan 12.5JC as a backup generator.

     Carver's Onan 12.5JC GenSet (Workshop 3812222734, mod id OnanGenSet) is
     vanilla's IsoGenerator on its control-box square, with a plain engine
     half beside it, and keeps its fuel in the generator's ModData `onan`: a
     208 L belly tank (`store`) and an attached propane tank's fill (`cyl`,
     0..1, or -1), burnt propane first (OnanServer.lua, reconcileOnan). Its
     server deletes the engine half once the generator is gone, so Off-Grid
     cannot swap it for a part of its own as it does a vanilla generator.

     It is LINKED instead (design, docs/design/2026-11-03-onan-backup.md):
     "Convert to Off-Grid backup" stamps Off-Grid's ModData on the Onan
     itself, and P.describe finds it as a backup of tier "onan" by that
     ModData. Off-Grid never switches it on the vanilla way, so it never
     lights a circle of its own; it only feeds the controller it is cabled
     to. Off-Grid's copy of its fuel and condition (`d.fuel`, `d.condition`)
     is taken from the Onan at the start of every tick (ON.pull) and written
     back after it (ON.push), propane first, then the belly tank. Carver's
     menus keep filling it.

     Nothing here is held at file load: mods run their Lua in the player's
     mod order, so OnanGenSet may load before or after Off-Grid. Without it,
     every answer here is "not an Onan". No file of Carver's is copied.
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Onan = OffGrid.Onan or {}
local ON = OffGrid.Onan
local P = OffGrid.Parts
local try = P.try

ON.TIER = "onan"
-- The anchor sprites, east-west and north-south (OnanCore O.LAYOUT), and the
-- Facing each tile carries (onan_genset.tiles).
ON.SPRITES = { "onan_genset_01_1", "onan_genset_01_2" }
ON.FACING = { [0] = "E", [1] = "S" }
ON.ITEM = "Base.Generator_Onan"
-- 12.5 kW, the figure in its name.
ON.RATING = 12500
-- Carver's figures, for while his sandbox cannot be read: the belly tank, a
-- propane tank's worth, fuel use, wear (1 in N per running hour) and noise.
ON.TANK = 208
ON.PROPANE = 20
ON.FUEL_USE = 0.8
ON.WEAR_N = 54
ON.LOUDNESS = 25
-- His recordings (OnanGenSet_sounds.txt): the start runs up to speed, and his
-- own player starts the loop RUN_AT seconds in (OnanSound.lua, START_LEN 2.4
-- less its 0.75 s crossfade). The backfire is vanilla's event.
ON.SOUNDS = { start = "OnanGenStart", loop = "OnanGenRun", stop = "OnanGenStop",
              backfire = "OnanGeneratorBackfire", runAt = 1.65 }

-- What a linked Onan answers instead of vanilla's generator controls, and
-- instead of Off-Grid's Refuel and fuel barrels.
ON.REFUSAL = "Tooltip_OffGrid_BkOnanLinked"
ON.REFUSAL_FUEL = "Tooltip_OffGrid_BkOnanFuel"

--- Carver's table, or nil while OnanGenSet is not loaded.
function ON.api()
    local O = OnanGenSet
    if type(O) ~= "table" or type(O.isOnan) ~= "function"
            or type(O.orientation) ~= "function" then
        return nil
    end
    return O
end

--- A number from one of his functions, or `default` when it is missing or
--  fails (his sandbox reads raise nothing, but a later version may differ).
local function call(O, name, default, ...)
    local fn = O and O[name]
    if type(fn) ~= "function" then return default end
    local ok, v = pcall(fn, ...)
    v = ok and tonumber(v) or nil
    if v == nil or v ~= v then return default end
    return v
end

--- Is `obj` an Onan's generator (its control-box square)?
function ON.isOnan(obj)
    local O = ON.api()
    if not O or not obj then return false end
    local ok, v = pcall(O.isOnan, obj)
    return ok and v == true
end

--- Off-Grid's ModData on an object, without creating any.
local function stamp(obj)
    if not obj or not obj.getModData then return nil end
    if obj.hasModData and try(obj, "hasModData") ~= true then return nil end
    local md = try(obj, "getModData")
    local d = md and md.offgrid
    if type(d) == "table" then return d end
    return nil
end

--- Is `obj` an Onan that Off-Grid runs as a backup?
function ON.isUnit(obj)
    local d = stamp(obj)
    return d ~= nil and d.kind == "backup" and d.tier == ON.TIER and ON.isOnan(obj)
end

--- The Onan generator behind a clicked object: the generator itself, or the
--  one an engine half belongs to. Nil for anything else.
function ON.generatorOf(obj)
    if ON.isOnan(obj) then return obj end
    local O = ON.api()
    if not O or not obj or type(O.anchorOf) ~= "function" then return nil end
    local ok, gen = pcall(O.anchorOf, obj)
    if ok and gen and ON.isOnan(gen) then return gen end
    return nil
end

--- The facing Off-Grid keeps for an Onan: its tile's.
function ON.facing(gen)
    local O = ON.api()
    if not O then return nil end
    local ok, o = pcall(O.orientation, gen)
    return ok and ON.FACING[o] or nil
end

------------------------------------------------------------------ the brand

local BRAND = { item = ON.ITEM, rating = ON.RATING, radius = ON.LOUDNESS, volume = 1,
                wearN = ON.WEAR_N, sounds = ON.SOUNDS, linked = true,
                fuelFactor = ON.FUEL_USE,
                lcd = "IGUI_OffGrid_BrandOnan", name = "IGUI_OffGrid_BrandNameOnan" }

--- The Onan as OG_Backup's brands read (K.brand), or nil while OnanGenSet is
--  not loaded or `tier` is not the Onan's. Wear, noise and fuel use are his
--  sandbox's, read each time.
function ON.brand(tier)
    if tier ~= ON.TIER then return nil end
    local O = ON.api()
    if not O then return nil end
    BRAND.wearN = math.max(1, math.floor(call(O, "durability", ON.WEAR_N)))
    BRAND.radius = math.max(1, math.floor(call(O, "loudness", ON.LOUDNESS)))
    BRAND.fuelFactor = math.max(0, call(O, "fuelUse", ON.FUEL_USE, ON.ITEM))
    return BRAND
end

------------------------------------------------------------- fuel, condition

--- His fuel state as it stands, never created: a question must not write.
local function fuelState(gen)
    local md = gen and try(gen, "getModData")
    local st = md and md.onan
    if type(st) == "table" then return st end
    return nil
end

local function num(v)
    v = tonumber(v)
    if v == nil or v ~= v or v - v ~= 0 then return 0 end
    return v
end

--- Belly tank litres, propane litres, whether a propane tank is on, and the
--  size of the belly tank and of a propane tank.
function ON.levels(gen)
    local O = ON.api()
    local tank = call(O, "tankLitres", ON.TANK)
    local per = call(O, "propanePerTank", ON.PROPANE)
    local st = fuelState(gen)
    if not st then return 0, 0, false, tank, per end
    local cyl = tonumber(st.cyl)
    local has = cyl ~= nil and cyl >= 0
    return math.max(0, num(st.store)), has and math.max(0, num(cyl)) * per or 0, has, tank, per
end

--- All the fuel it holds, in litres: the propane tank's and the belly tank's.
function ON.fuel(gen)
    local store, cyl = ON.levels(gen)
    return store + cyl
end

--- What it holds when full: the belly tank, and a propane tank while one is on.
function ON.capacity(gen)
    local _, _, has, tank, per = ON.levels(gen)
    return tank + (has and per or 0)
end

--- Set its fuel to `litres`, on the authority. What goes comes out of the
--  propane first, then the belly tank, the order his own server burns them
--  in; what comes back goes into the belly tank, up to its size. His engine
--  tank is his server's to top up (reconcileOnan): the generator is never
--  switched on, so it burns nothing from it. Returns whether it changed.
function ON.setFuel(gen, litres)
    local O = ON.api()
    if not O or type(O.state) ~= "function" then return false end
    local ok, st = pcall(O.state, gen)
    if not ok or type(st) ~= "table" then return false end
    local store, cyl, has, tank, per = ON.levels(gen)
    local want = math.max(0, num(litres))
    local delta = store + cyl - want
    -- Exactly: the next tick's pull overwrites Off-Grid's copy with his, so a
    -- small debit skipped here would be lost for good (review, 2026-11-03).
    if delta == 0 then return false end
    if delta > 0 then
        local fromCyl = math.min(cyl, delta)
        if has and per > 0 then st.cyl = math.max(0, (cyl - fromCyl) / per) end
        st.store = math.max(0, store - (delta - fromCyl))
    else
        st.store = math.min(tank, store - delta)
    end
    return true
end

--- Its condition, 0..100, the generator's own.
function ON.condition(gen)
    local c = tonumber(try(gen, "getCondition"))
    if c == nil then return nil end
    return c
end

--- Set its condition, on the authority. IsoGenerator.setCondition sends the
--  generator on a server (IsoGenerator.java:566-575), so only a change of a
--  whole point is written.
function ON.setCondition(gen, c)
    local want = math.max(0, math.min(100, math.floor(num(c) + 0.5)))
    if ON.condition(gen) == want then return false end
    try(gen, "setCondition", want)
    return true
end

--- Off-Grid's copy of its fuel and condition, from the Onan.
function ON.pull(gen, d)
    if not (gen and d) then return end
    d.fuel = ON.fuel(gen)
    local c = ON.condition(gen)
    if c then d.condition = c end
end

--- A newer entry from the controller's mirror (it ran the Onan on paper
--  while its square was away), settled onto the Onan as a CHANGE: `before` is
--  Off-Grid's copy of its fuel before the entry was applied, which is what his
--  tanks held when it left. Fuel poured in by his menus since it came back, in
--  the minute before a tick applies the entry, is kept (review, 2026-11-03).
--  Condition is the entry's: only Off-Grid repairs a linked Onan.
function ON.settle(gen, d, before)
    if not (gen and d) or isClient() then return end
    d.fuel = math.max(0, ON.fuel(gen) + (num(d.fuel) - num(before)))
    ON.push(gen, d)
end

--- And back onto the Onan, on the authority: what Off-Grid burned, wore,
--  repaired or settled on paper.
function ON.push(gen, d)
    if not (gen and d) or isClient() then return end
    ON.setFuel(gen, d.fuel)
    ON.setCondition(gen, d.condition)
end

--- A linked Onan switched on by anything else (another mod, an admin) is
--  switched off again: running, it would light its own circle and burn its
--  engine tank. Returns whether it did.
function ON.keepOff(gen)
    if isClient() or try(gen, "isActivated") ~= true then return false end
    try(gen, "setActivated", false)
    return true
end

------------------------------------------------- vanilla's generator controls

--  Plug in, Turn on and Take are vanilla's way of running it as a normal
--  generator, so they are refused while it is linked, in the actions'
--  isValid (shared: vanilla's timed actions load before any mod's shared
--  Lua, and Carver wraps Take's later or earlier without breaking the chain).
--  Unplugging and turning off stay allowed.

local guarded = false

local function refuse(class, name, when)
    if type(class) ~= "table" or type(class[name]) ~= "function" then return end
    local orig = class[name]
    class[name] = function(self, ...)
        if type(self) == "table" and when(self) and ON.isUnit(self.generator) then
            return false
        end
        return orig(self, ...)
    end
end

function ON.guardActions()
    if guarded then return true end
    guarded = true
    refuse(ISPlugGenerator, "isValid", function(a) return a.plug == true end)
    refuse(ISActivateGenerator, "isValid", function(a) return a.activate == true end)
    refuse(ISTakeGenerator, "isValid", function() return true end)
    return true
end

ON.guardActions()

--  On a server complete() runs without the Lua isValid (OG_Place,
--  G.liveGenerator), so the same three are refused where they complete, as a
--  no-op. Carver's server wraps Take's complete and, for an Onan, packs it
--  without calling what was there before, so this guard has to sit on top of
--  his: it is put back on top once every mod's Lua is in (his server file
--  loads after every shared file), and again whenever another wrapper has
--  covered it. A second copy below another wrapper only refuses twice.

local onTop = {}

local function refuseComplete(class, name, when)
    if type(class) ~= "table" or type(class.complete) ~= "function" then return end
    if class.complete == onTop[name] then return end
    local orig = class.complete
    local mine = function(self, ...)
        if type(self) == "table" and when(self) and ON.isUnit(self.generator) then
            return true
        end
        return orig(self, ...)
    end
    onTop[name] = mine
    class.complete = mine
end

function ON.guardCompletes()
    refuseComplete(ISPlugGenerator, "plug", function(a) return a.plug == true end)
    refuseComplete(ISActivateGenerator, "activate", function(a) return a.activate == true end)
    refuseComplete(ISTakeGenerator, "take", function() return true end)
end

ON.guardCompletes()
if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(ON.guardCompletes) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(ON.guardCompletes) end
end

--- The linked Onan a right-click was about: vanilla's fetched generator, or
--  one among the clicked objects, or the generator of a clicked engine half.
function ON.clickedUnit(worldObjects)
    local fv = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
    local g = fv and fv.generator
    if g and ON.isUnit(g) then return g end
    for _, o in ipairs(worldObjects or {}) do
        local gen = ON.generatorOf(o)
        if gen and ON.isUnit(gen) then return gen end
    end
    return nil
end

--- Grey vanilla's Plug in, Turn on and Take on a linked Onan, with the
--  reason, and drop its Fix (Off-Grid's Repair the generator is the one).
--  Runs after every other handler, Carver's included: registered once a game
--  has started, when every mod's file-load handlers are in.
function ON.onFill(playerNum, context, worldObjects, test)
    if test or not context or not context.getOptionFromName then return end
    if not ON.clickedUnit(worldObjects) then return end
    local opt = context:getOptionFromName(getText("ContextMenu_Generator"))
    local sub = opt and opt.subOption and context.getSubMenu
                and context:getSubMenu(opt.subOption)
    if not sub or not sub.getOptionFromName then return end
    local C = OffGrid.Context
    local keys = { "ContextMenu_GeneratorPlug", "ContextMenu_Turn_On", "ContextMenu_GeneratorTake" }
    for i = 1, #keys do
        local row = sub:getOptionFromName(getText(keys[i]))
        if row then
            row.notAvailable = true
            if C and C.tip then row.toolTip = C.tip(getText(ON.REFUSAL)) end
        end
    end
    if sub.removeOptionByName then sub:removeOptionByName(getText("ContextMenu_GeneratorFix")) end
end

if Events and Events.OnGameStart then
    local added = false
    Events.OnGameStart.Add(function()
        if not added and not isServer() and Events.OnFillWorldObjectContextMenu then
            added = true
            Events.OnFillWorldObjectContextMenu.Add(ON.onFill)
        end
    end)
end

return ON

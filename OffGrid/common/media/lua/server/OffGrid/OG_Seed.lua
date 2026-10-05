--[[ OffGrid -- the houses that already had solar.

     Some people in Knox County were running panels before the outbreak, and
     the world should say so. A fraction of residential buildings get a rig in
     the yard: a row of ground arrays, one or two battery racks, and a
     controller, wired together the way the household left it.

     EVERY seeded rig is complete, and that is a rule rather than a tendency
     (Can, 2026-09-21). People were LIVING with these things; a solar array
     wired to nothing is not a story, it is a bug. So the hardware is always
     all there. What the world took is the CHARGE: the racks are mostly full
     of batteries that are mostly finished, and the first array a player ever
     touches is one they can see working and cannot yet feed. A small fraction
     still hold enough to run something, and finding one of those is the
     moment.

     Where the parts stand is not decided here. OG_Yard plans the row against
     the house's own walls and this file installs what it is handed, which is
     what lets the same placement run offline over the real map files.

     THE HOOK, AND WHY IT IS THE ONLY ONE.

     Events.LoadChunk gated on chunk:isNewChunk() is the only Lua-reachable
     hook in 42.20 that the engine guarantees fires exactly once per chunk per
     save. Everything nearby is a trap:

       * LoadGridsquare, LoadChunk ungated and OnLoadWithSprite all fire again
         on EVERY reload, and objects added with AddTileObject are written into
         the chunk file, so naive code doubles its rig every time the player
         walks away and comes back.
       * The engine's own randomized building stories cannot be extended from
         Lua. The list is thirty-two hard-coded Java classes on IsoWorld and
         randomizeBuilding has no Lua seam; the only opening is the item
         clutter string lists.
       * MapObjects.OnNewWithSprite IS a genuine first-generation hook, but it
         needs an anchor sprite that already exists on the square, and there is
         no vanilla sprite that means "a house that would have had solar".

     Since 2026-10-05 (Can: "let's also add a new feature so that people can
     seed existing saves if they add the mod mid-game") OLD chunks reach the
     gate too, once a session each, for the houses the ledger has never
     decided; there the LEDGER is what stops a rig being built twice. A NEW
     chunk decides every house on it again, ledger or not, because a known
     house on fresh ground means a wipe or a reset; S.DECIDED keeps that to
     once a session (a dedicated server fires a whole cell's LoadChunk events
     after all of it is readable, so one house's two chunks would otherwise
     each serve it), and S.taken keeps a second rig off a house whose old one
     survived, and every rig off a player's base.

     One caveat on isNewChunk that is worth knowing before trusting it: it
     returns IsoChunk.addZombies, which is set in exactly one place and gated
     on `!GameClient.client && Core.addZombieOnCellLoad` (IsoChunk.java:2258).
     So it is permanently FALSE on a multiplayer client, which is why the
     server does the seeding and this file returns early above; and it is
     false in the Tutorial and Last Stand game modes, where
     addZombieOnCellLoad is switched off (Core.java:751). There every chunk
     reaches the gate as an old one since 2026-10-05, so those modes are
     seeded too, once a session per chunk.
]]

if isClient() then return end

require "OffGrid/OG_Parts"
require "OffGrid/OG_Model"
require "OffGrid/OG_Yard"

OffGrid = OffGrid or {}
OffGrid.Seed = OffGrid.Seed or {}
local S = OffGrid.Seed
local P = OffGrid.Parts
local M = OffGrid.Model
local try = P.try

-- One residential building in this many gets a rig: the default of the
-- sandbox's RigChance, which is what decides (S.rigChance).
S.CHANCE = 15
-- And one rig in this many is still working when it is found.
S.LIVE = 8
-- There is no dead-controller roll any more, and no S.DEAD_CTRL_*.
--
-- 2.10.0 placed a controller only on a live rig, which put 15 seeded rigs in
-- Muldraugh and not one controller: players met piles of panels and racks
-- with nothing to run them from. The fix then was to let a stripped rig keep
-- its controller two times in seven. The fix now is that the question cannot
-- arise -- a plan carries one controller field and the install places it, so
-- a rig without one is not a thing this file can build. S.LIVE no longer
-- gates hardware, only what is left in the batteries.
--
-- Every seeded rig is WIRED too. A household that ran on this wired it, and
-- the wire is written by the plan over the squares it placed rather than
-- found by radius, so a controller can never pick up next door's panels.

-- The condition a weathered frame is found at. The same band the salvage loot
-- uses, so a panel out of a yard and a panel out of a barn read the same.
S.COND_MIN, S.COND_MAX = 15, 45

S.LEDGER = "OffGridSeededBuildings"

--- STORAGE BARNS. Can, 2026-09-26: "especially none in barns", and then
--  which barns: not the livestock barns ("feeders should not have solar
--  parts"), but the ones used for hay storage only -- "an empty barn with hay
--  in it. The farmer would've stored his surplus solar panels and battery
--  banks in it." So a storage barn in this many holds a few of them as tiles,
--  placed like the yard rigs: once, the first time its ground is generated.
--  One in two by default, Can's choice: there are only about 50 storage
--  barns on the map. The sandbox's BarnStockChance decides (S.barnChance).
--  Farm-storage rooms get items in their containers instead (OG_Loot).
--
--  A storage barn is a building with a barn or hay-storage room, no feeding
--  trough anywhere in those rooms, and no room where animals or people live.
--  The map has about 50 of them against 132 livestock barns (troughs).
S.BARN_CHANCE = 2
S.BARN_ROOMS = { "barn", "haystorage" }
S.NOT_STORAGE = { "chickencoop", "pigsty", "stable", "horsebox", "kennels",
                  "bedroom", "kitchen", "livingroom" }
--- The stock: panels and battery racks, alternating, two to four of them,
--  standing as tiles. Stored indoors, so in better shape than a rig left in
--  the yard.
S.STASH_MIN, S.STASH_MAX = 2, 4
S.STASH_COND_MIN, S.STASH_COND_MAX = 35, 75
--- Barn jobs share the ledger and the waiting list with the rigs, under
--  their own key, so a building can be decided for both.
S.BARN_KEY = "barn:"

--- A stable pseudo-random value for a building, in 0..modulus-1.
--
--  Deterministic on purpose. The same house must reach the same answer however
--  many times the question is asked, because two chunks of one building can
--  both be new in the same session and a coin flip would give them different
--  rigs. Kahlua is Lua 5.1 and has no bitwise operators, so this is plain
--  arithmetic on the building's own metaId.
function S.roll(def, salt, modulus)
    if not def then return 0 end
    return M.placeRoll(def:getX(), def:getY(), salt, modulus)
end

--- Like S.roll, but not linear in the salt: for every roll taken AFTER the
--  seeding and live gates.
--
--  placeRoll is linear, so on the population that passed the gate (salt-3
--  value a multiple of 15, and for a live rig salt-7 a multiple of 8) every
--  later roll is that same value plus a constant, and a modulus sharing a
--  factor with 15 or 8 collapses onto a few residues. Measured on seeded rigs
--  only: array conditions came from 4 values out of 30, a live rig never had a
--  standard array, and 97% had two arrays rather than two or three. Squaring
--  the value before reducing it breaks that; every term stays far below 2^53,
--  so the arithmetic is exact in a double. The gate rolls keep S.roll: they
--  decide which houses are seeded, and existing worlds have already seen them.
function S.draw(def, salt, modulus)
    if not def then return 0 end
    local h = M.placeRoll(def:getX(), def:getY(), salt, 1000003)
    h = (h * h + salt * 7919 + 12345) % 1000003
    return h % math.max(1, math.floor(modulus or 1))
end

--- How rare the finds are, from the sandbox (a suggestion-board request,
--  2026-09-26): one house in RigChance gets a yard rig, one storage barn in
--  BarnStockChance holds spare gear, and 0 turns either off. Read at every
--  decision, so a changed setting applies to the next ground generated.
local function chance(name, default)
    local n = tonumber(P.sandbox(name)) or default
    if n < 0 then n = 0 end
    return math.floor(n)
end

function S.rigChance() return chance("RigChance", S.CHANCE) end
function S.barnChance() return chance("BarnStockChance", S.BARN_CHANCE) end

--- Vanilla's own definition of a residential building: somewhere to sleep,
--  somewhere to wash, and somewhere to cook or sit.
function S.isResidential(def)
    if not def or not def.getRoom then return false end
    if not def:getRoom("bedroom") then return false end
    if not def:getRoom("bathroom") then return false end
    return def:getRoom("kitchen") ~= nil or def:getRoom("livingroom") ~= nil
end

------------------------------------------------- the building, as plain data

--- The ground-floor rooms of a building def, as plain tables.
--
--  OG_Yard takes no engine objects, so everything it needs about the house
--  arrives like this. A def whose rooms cannot be read comes back empty and
--  the planner falls back to the bounding box, which it flags.
function S.rooms(def, z)
    local out = {}
    local list = try(def, "getRooms")
    if not list or not list.size then return out end
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        -- getZ, not getLevel: RoomDef has no getLevel, and `try` would have
        -- returned nil for it forever, so every room would have passed the
        -- floor filter and upstairs rooms would have joined the footprint.
        if (try(r, "getZ") or 0) == z then
            local name = try(r, "getName")
            -- A room is a LIST OF RECTANGLES. getX/getY/getW/getH on RoomDef
            -- is the room's bounding box, so an L-shaped room claims ground
            -- it does not stand on -- the same inflation this whole rewrite
            -- exists to get rid of, one level down.
            local rects = try(r, "getRects")
            local n = (rects and rects.size) and rects:size() or 0
            for j = 0, n - 1 do
                local q = rects:get(j)
                local x, y = try(q, "getX"), try(q, "getY")
                local w, h = try(q, "getW"), try(q, "getH")
                if x and y and w and h and w > 0 and h > 0 then
                    out[#out + 1] = { x = x, y = y, w = w, h = h,
                                      level = z, name = name }
                end
            end
            if n == 0 then
                local x, y = try(r, "getX"), try(r, "getY")
                local w, h = try(r, "getW"), try(r, "getH")
                if x and y and w and h and w > 0 and h > 0 then
                    out[#out + 1] = { x = x, y = y, w = w, h = h,
                                      level = z, name = name }
                end
            end
        end
    end
    return out
end

--- The ledger key for a building.
--
--  The old key was the bounding-box corner, def:getX()..","..def:getY(), and
--  it COLLIDES: 21 pairs of buildings map-wide share a corner, 7 of them
--  residential. A collision is not cosmetic -- the loser is recorded as
--  already served and can never be seeded, for the life of the save.
--
--  The lowest ground-floor room origin plus the ground-floor room area
--  separates them: two buildings can share a corner, but not a corner AND an
--  interior. Falls back to the old key for a def with no readable rooms,
--  which is the only case where nothing better is available.
function S.key(def, rooms)
    rooms = rooms or S.rooms(def, 0)
    local bx, by, area = nil, nil, 0
    for i = 1, #rooms do
        local r = rooms[i]
        area = area + r.w * r.h
        if not bx or r.x < bx or (r.x == bx and r.y < by) then
            bx, by = r.x, r.y
        end
    end
    if not bx then return S.legacyKey(def) end
    return bx .. "," .. by .. ":" .. area
end

--- What the ledger used to be keyed on.
--
--  Still CHECKED, never written. A save made before the key changed has its
--  seeded houses recorded under these, and reading both is what stops every
--  one of them being served a second rig the next time its chunk loads.
function S.legacyKey(def)
    return def:getX() .. "," .. def:getY()
end

------------------------------------------------------------- the world, asked

--- Squares this session has already given to a rig.
--
--  Belt and braces. Every part the seeder places carries solid or solidtrans
--  in its tile properties, so the next house's survey rejects the square on
--  its own; this covers the window between planning and placing, and any part
--  whose properties change later.
S.CLAIMED = {}

--- Whether the engine's own arbiter of building ownership is reachable.
--  nil = not yet asked, false = not available on this build.
S.ownerProbe = nil

--- Which building the engine thinks an OUTDOOR square belongs to.
--
--  getSquare():getBuilding() is nil for every square a rig can stand on, so
--  it cannot answer this. IsoMetaGrid does. Measured over 29,183 apron
--  squares on 233 houses, 2.4% are nearer a neighbour than their own house --
--  small, but it is exactly the 2.4% that produces a rig in the wrong garden.
--
--  Returns nil when the call is unavailable, and nil means "no objection":
--  the wall-anchored survey already keeps candidates within three squares of
--  a wall this house owns, so losing this costs a refinement, not the rule.
function S.owner(x, y, z)
    if S.ownerProbe == false then return nil end
    local world = getWorld and getWorld()
    local mg = world and try(world, "getMetaGrid")
    if not mg or not mg.getAssociatedBuildingAt then
        S.ownerProbe = false
        return nil
    end
    S.ownerProbe = true
    -- It returns a BuildingDef DIRECTLY, not an IsoBuilding, so there is no
    -- getDef() to call on the result -- doing so returned nil every time and
    -- the ownership veto silently never fired. Two overloads in the jar,
    -- (int,int) and (int,int,IsoDirections); neither takes a z.
    local d = try(mg, "getAssociatedBuildingAt", x, y)
    if not d then return nil end
    return S.key(d)
end

--- The world as OG_Yard asks about it.
function S.env()
    return {
        getSquare = function(x, y, z) return getSquare(x, y, z) end,
        owner = S.owner,
        claimed = function(x, y, z)
            return S.CLAIMED[x .. "," .. y .. "," .. z] == true
        end,
    }
end

--- How far around a building's bounding box must be loaded before it is
--  planned: every square the planner can read (OG_Yard's READS). It used to
--  be REACH + 1, which covered the side survey but not the panel-field walk,
--  so a field could be refused for ground that simply had not streamed in
--  yet and the rig came out different depending on how the player arrived.
function S.pad()
    local Y = OffGrid.Yard
    return (Y and Y.READS) or ((Y and Y.REACH or 3) + 1)
end

--- Is the whole working area of this building streamed in yet?
--
--  THE bug behind "most of them are incomplete". LoadChunk fires per 8x8
--  chunk and a house's yard usually spans several, so an install run from the
--  first chunk to arrive saw only the fraction of the yard that happened to
--  be loaded and getSquare returned nil for the rest. Replaying one real
--  house at 10745,9525, whose surroundings span six chunks, over six
--  different chunk-entry orders produced three different rigs on three
--  different sides and three that produced nothing at all.
--
--  So nothing is planned until every square the planner could look at exists.
function S.streamed(def, z, pad)
    -- The engine's own answer first, and it is a fast NO for most of the
    -- calls this makes. Not sufficient on its own: it speaks for the
    -- building's OWN squares, and the planner also reads the ground around
    -- it, which belongs to other chunks.
    local inner = try(def, "isFullyStreamedIn")
    if inner == false then return false end

    pad = pad or S.pad()
    local bx, by = def:getX(), def:getY()
    local bw, bh = def:getW(), def:getH()
    -- The four corners first. A yard still arriving is almost always missing
    -- one, and this is asked every time a chunk around a waiting house loads.
    if not (getSquare(bx - pad, by - pad, z) and getSquare(bx + bw + pad, by - pad, z)
            and getSquare(bx - pad, by + bh + pad, z)
            and getSquare(bx + bw + pad, by + bh + pad, z)) then
        return false
    end
    for x = bx - pad, bx + bw + pad do
        for y = by - pad, by + bh + pad do
            -- When the engine has vouched for the building's own squares,
            -- only the ground AROUND it still has to be walked. That is most
            -- of the box for a large house.
            local vouched = (inner == true)
                            and x >= bx and x < bx + bw
                            and y >= by and y < by + bh
            if not vouched and not getSquare(x, y, z) then return false end
        end
    end
    return true
end

--- Put one Off-Grid object on a square and make the world notice.
function S.place(sq, kind, mount, tier, state, facing, house)
    local name = P.sprite(kind, mount, tier, state, facing)
    if not name then return nil end
    -- The three-argument form. The two-argument one builds an ANONYMOUS
    -- sprite whose getName() is nil, which would take the tile properties and
    -- this mod's whole identity scheme with it.
    local o = IsoObject.new(sq, name, name)
    if isServer() and sq.transmitAddObjectToSquare then
        sq:transmitAddObjectToSquare(o, -1)
    else
        sq:AddTileObject(o)
    end
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    -- Which house (or barn) it was seeded for (S.taken): a neighbour's rig
    -- standing in this yard is then never taken for this house's own.
    if house then P.data(o).seededFor = house end
    if OffGrid.System then OffGrid.System.register(o) end
    return o
end

--- Build one house's rig from the plan OG_Yard hands back.
--
--  Nothing here chooses a square. If there is no plan the house gets NOTHING:
--  a rig is complete or it does not exist, so there is no path through this
--  function that leaves panels standing with no controller.
function S.install(def, z)
    local id = def
    local Y = OffGrid.Yard
    local rooms = S.rooms(def, z)
    -- what every part placed here records (S.place, S.taken)
    local house = S.key(def, rooms)
    local b = { x = def:getX(), y = def:getY(), w = def:getW(), h = def:getH(),
                z = z, id = S.key(def, rooms), rooms = rooms }

    -- How big a rig this household built. Both are clamped by the planner,
    -- and both are cut down by it when the wall is too short for the row.
    local want = {
        arrays = Y.MIN_ARRAYS + S.draw(id, 11, Y.MAX_ARRAYS - Y.MIN_ARRAYS + 1),
        banks  = Y.MIN_BANKS  + S.draw(id, 13, Y.MAX_BANKS - Y.MIN_BANKS + 1),
    }
    local plan, reasons = Y.plan(b, S.env(), want)
    if not plan then return 0, false, reasons end

    if S.DEBUG then
        print(string.format(
            "OG_Seed: plan at %d,%d -- %s wall, %d panels, %d rack(s)",
            def:getX(), def:getY(), plan.dir, #plan.arrays, #plan.banks))
    end

    -- Whether the batteries still hold anything. The hardware is not in
    -- question; S.LIVE decides the charge and nothing else.
    local live = S.roll(id, 7, S.LIVE) == 0
    local made = 0

    ------------------------------------------------------------- the panels
    local placedArrays = {}
    for i = 1, #plan.arrays do
        local p = plan.arrays[i]
        local sq = getSquare(p.x, p.y, p.z)
        local tier = (S.draw(id, 20 + i, 4) == 0) and "standard" or "makeshift"
        -- Work out the state BEFORE placing and place that sprite directly.
        -- A P.setState swap afterwards happens inside Events.LoadChunk on an
        -- object the chunk has already taken, and does not reach the save: 28
        -- seeded arrays in the live world came out pristine when the
        -- condition roll says about 70% should be cracked.
        local spec = {
            condition = S.COND_MIN + S.draw(id, 30 + i, S.COND_MAX - S.COND_MIN),
            soiling   = 0.35 + S.draw(id, 40 + i, 40) / 100,
            snow      = 0,
        }
        local state = P.arrayState(spec)
        local o = sq and S.place(sq, "array", "ground", tier, state, p.facing, house)
        if o then
            local d = P.data(o)
            d.condition = spec.condition
            d.panels = M.baseArraySpec(tier).panels
            d.soiling = spec.soiling
            d.snow = spec.snow
            d.state = state
            o:transmitModData()
            placedArrays[#placedArrays + 1] = p
            made = made + 1
        end
    end

    -------------------------------------------------------------- the racks
    --
    -- Usually holding cells, and those cells usually nearly finished. The
    -- numbers live in Y.CELLS with the rest of the rig's composition. One
    -- rack in EMPTY_IN is bare, because sometimes somebody did get here first.
    local C = Y.CELLS
    local placedBanks, cellTotal = {}, 0
    for i = 1, #plan.banks do
        local p = plan.banks[i]
        local sq = getSquare(p.x, p.y, p.z)
        local bare = S.draw(id, 70 + i, C.EMPTY_IN) == 0
        local cells = bare and 0 or (2 + S.draw(id, 51 + i, 2))
        local state = P.bankState({ mount = "ground", tier = "makeshift",
                                    cells = cells })
        local o = sq and S.place(sq, "bank", "ground", "makeshift", state,
                                 p.facing, house)
        if o then
            local d = P.data(o)
            d.condition = S.COND_MIN + S.draw(id, 50 + i, S.COND_MAX - S.COND_MIN)
            d.cells = cells
            d.cellList = {}
            for j = 1, cells do
                -- Mostly dead, with the occasional one that outlived the rest.
                local h
                if S.draw(id, 120 + i * 8 + j, C.SPARED_IN) == 0 then
                    h = C.MAX + S.draw(id, 160 + i * 8 + j,
                                       C.SPARED_MAX - C.MAX + 1)
                else
                    h = C.MIN + S.draw(id, 80 + i * 8 + j, C.MAX - C.MIN + 1)
                end
                d.cellList[j] = { id = j, type = "Base.CarBattery1",
                                  health = M.clamp(h / 100, 0.01, 1) }
            end
            d.nextCellId = cells + 1
            if live and cells > 0 then
                -- Scaled the way the live simulation scales it, or a server
                -- running BankScale 50 spawns racks holding twice what they
                -- can keep and the first tick clips the surplus into nothing.
                local cap = M.bankCapacity({ tier = "makeshift",
                                             cellSum = M.cellSum(d.cellList),
                                             scale = P.bankScale() }, 20)
                d.charge = cap * (0.2 + S.draw(id, 52 + i, 40) / 100)
            else
                d.charge = 0
            end
            d.state = state
            o:transmitModData()
            placedBanks[#placedBanks + 1] = p
            cellTotal = cellTotal + cells
            made = made + 1
        end
    end

    --------------------------------------------------------- the controller
    --
    -- Always. That is the rule, and it is why the plan carries one controller
    -- FIELD rather than a count: there is no branch here that can decide not
    -- to place it, only an engine failure that can stop it.
    local cp = plan.controller
    local csq = getSquare(cp.x, cp.y, cp.z)
    local c = csq and OffGrid.Place and OffGrid.Place.makeController(
        csq, nil,
        { kind = "controller", mount = "ground", tier = "basic",
          facing = cp.facing }, nil)
    if c then
        local d = P.data(c)
        d.seededFor = house
        d.online = live and cellTotal > 0
        d.trip = false
        -- WIRED, over exactly the squares this plan placed, and never found
        -- by radius. That is what makes it impossible for this controller to
        -- pick up the house next door's panels, whatever stands between them.
        local root = M.nodeKey(cp.x, cp.y, cp.z, "controller")
        local w = ""
        for n = 1, #placedArrays do
            local a = placedArrays[n]
            w = M.wireAdd(w, M.nodeKey(a.x, a.y, a.z, "array"), root)
        end
        for n = 1, #placedBanks do
            local k = placedBanks[n]
            w = M.wireAdd(w, M.nodeKey(k.x, k.y, k.z, "bank"), root)
        end
        d.wire = w
        c:transmitModData()
        made = made + 1
    end

    -- Hold the ground, so a house planned later in the same pass cannot be
    -- handed a square this one is standing on.
    for i = 1, #plan.squares do
        local sq = plan.squares[i]
        S.CLAIMED[sq.x .. "," .. sq.y .. "," .. sq.z] = true
    end

    return made, live, reasons
end


------------------------------------------------------------------- barns

--- Could this building be a storage barn? Rooms only: a barn or hay-storage
--  room, and nowhere animals or people live. Troughs need the squares, so
--  they are looked for when the barn is stocked.
function S.isStorageBarn(def)
    if not def or not def.getRoom then return false end
    local barn = false
    for i = 1, #S.BARN_ROOMS do
        if def:getRoom(S.BARN_ROOMS[i]) ~= nil then barn = true end
    end
    if not barn then return false end
    for i = 1, #S.NOT_STORAGE do
        if def:getRoom(S.NOT_STORAGE[i]) ~= nil then return false end
    end
    return true
end

--- A feeding trough on this square, as the map placed it or as the engine
--  turned it into a feeding-trough object.
function S.hasTrough(sq)
    local objs = try(sq, "getObjects")
    for i = 0, (objs and objs:size() or 0) - 1 do
        local o = objs:get(i)
        if instanceof and instanceof(o, "IsoFeedingTrough") then return true end
        local spr = try(o, "getSprite")
        local props = spr and try(spr, "getProperties")
        if props and try(props, "get", "container") == "trough" then return true end
    end
    return false
end

--- A square a part can lie on: open floor with nothing standing on it and no
--  container, so never a trough, a crate or a stall wall.
function S.floorFree(sq)
    if try(sq, "isFree", false) ~= true then return false end
    local objs = try(sq, "getObjects")
    for i = 0, (objs and objs:size() or 0) - 1 do
        local o = objs:get(i)
        if try(o, "getContainer") ~= nil then return false end
    end
    return true
end

--- Is there a door on any edge of this square? Stock is stood out of the
--  way, never across somebody's way in or out.
local function besideDoor(env, x, y)
    for _, d in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
        if OffGrid.Yard.doorBetween(env, x, y, x + d[1], y + d[2], 0) then
            return true
        end
    end
    return false
end

--- Stock a storage barn with Off-Grid TILES: surplus panels and battery
--  racks standing in a row along one wall, from a corner, the way stock is
--  put away. Can, 2026-09-26: hay storage gets the tiles, and farm storage
--  rooms get items in their containers (OG_Loot's CrateFarming). What, how
--  many, where and how worn are all drawn from the building, so the same barn
--  always holds the same stock.
--
--  Returns the parts placed, or nil and a reason: "livestock" when a feeding
--  trough stands in the barn, "full" when no corner has room.
function S.stockBarn(def)
    local house = S.BARN_KEY .. S.key(def, S.rooms(def, 0))
    local open, rects = {}, {}
    local isBarnRoom = {}
    for i = 1, #S.BARN_ROOMS do isBarnRoom[S.BARN_ROOMS[i]] = true end
    local list = try(def, "getRooms")
    for i = 0, (list and list.size and list:size() or 0) - 1 do
        local r = list:get(i)
        if isBarnRoom[try(r, "getName") or ""] and (try(r, "getZ") or 0) == 0 then
            local rs = try(r, "getRects")
            for j = 0, (rs and rs.size and rs:size() or 0) - 1 do
                local q = rs:get(j)
                local x0, y0 = try(q, "getX"), try(q, "getY")
                local w, h = try(q, "getW"), try(q, "getH")
                if x0 and y0 and w and h then
                    rects[#rects + 1] = { x0, y0, w, h }
                    for x = x0, x0 + w - 1 do
                        for y = y0, y0 + h - 1 do
                            local sq = getSquare(x, y, 0)
                            if sq then
                                if S.hasTrough(sq) then return nil, "livestock" end
                                if S.floorFree(sq) then open[x .. "," .. y] = sq end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Runs along the walls of the barn rooms, facing into the room: from a
    -- corner if any corner has room, otherwise from anywhere along a wall
    -- (hay is usually stacked into the corners). The longest the barn allows,
    -- up to the stock this household had, is used.
    local env = S.env()
    local want = S.STASH_MIN + S.draw(def, 93, S.STASH_MAX - S.STASH_MIN + 1)
    local runs = nil
    for n = want, 1, -1 do
        local found = {}
        for pass = 1, 2 do
            for i = 1, #rects do
                local x0, y0, w, h = rects[i][1], rects[i][2], rects[i][3], rects[i][4]
                local x1, y1 = x0 + w - 1, y0 + h - 1
                -- corner, direction along the wall, facing, wall length
                local walks = {
                    { x0, y0, 1, 0, "S", w }, { x0, y0, 0, 1, "E", h },
                    { x1, y0, -1, 0, "S", w }, { x1, y0, 0, 1, "W", h },
                    { x0, y1, 1, 0, "N", w }, { x0, y1, 0, -1, "E", h },
                    { x1, y1, -1, 0, "N", w }, { x1, y1, 0, -1, "W", h },
                }
                for k = 1, #walks do
                    local wk = walks[k]
                    local last = (pass == 1) and 0 or (wk[6] - n)
                    for st = (pass == 1) and 0 or 1, last do
                        local run = {}
                        for s = st, st + n - 1 do
                            local x, y = wk[1] + wk[3] * s, wk[2] + wk[4] * s
                            local sq = open[x .. "," .. y]
                            if not sq or besideDoor(env, x, y) then break end
                            run[#run + 1] = sq
                        end
                        if #run == n then
                            found[#found + 1] = { squares = run, facing = wk[5] }
                        end
                    end
                end
            end
            if #found > 0 then break end
        end
        if #found > 0 then
            runs = found
            break
        end
    end
    if not runs then return nil, "full" end
    local run = runs[1 + S.draw(def, 90, #runs)]

    local placed = {}
    for i = 1, #run.squares do
        local sq = run.squares[i]
        local o
        if i % 2 == 1 then
            -- a panel
            local tier = (S.draw(def, 94 + i, 4) == 0) and "standard" or "makeshift"
            local spec = {
                condition = S.STASH_COND_MIN + S.draw(def, 100 + i,
                                S.STASH_COND_MAX - S.STASH_COND_MIN + 1),
                soiling = 0.05 + S.draw(def, 104 + i, 20) / 100,
                snow = 0,
            }
            local state = P.arrayState(spec)
            o = S.place(sq, "array", "ground", tier, state, run.facing, house)
            if o then
                local d = P.data(o)
                d.condition, d.soiling, d.snow, d.state = spec.condition, spec.soiling, 0, state
                d.panels = M.baseArraySpec(tier).panels
                o:transmitModData()
            end
        else
            -- a battery rack, usually with a battery or two left in it
            local cells = S.draw(def, 120 + i, 3)
            local state = P.bankState({ mount = "ground", tier = "makeshift", cells = cells })
            o = S.place(sq, "bank", "ground", "makeshift", state, run.facing, house)
            if o then
                local d = P.data(o)
                d.condition = S.STASH_COND_MIN + S.draw(def, 130 + i,
                                  S.STASH_COND_MAX - S.STASH_COND_MIN + 1)
                d.cells, d.cellList = cells, {}
                for j = 1, cells do
                    d.cellList[j] = { id = j, type = "Base.CarBattery1",
                                      health = (20 + S.draw(def, 140 + i * 4 + j, 41)) / 100 }
                end
                d.nextCellId, d.charge, d.state = cells + 1, 0, state
                o:transmitModData()
            end
        end
        if o then placed[#placed + 1] = o end
    end
    if #placed == 0 then return nil, "full" end
    return placed
end

--------------------------------------------------------------------- driver

local function ledger()
    if not ModData or not ModData.getOrCreate then return nil end
    return ModData.getOrCreate(S.LEDGER)
end

--- Houses that passed the gate and are waiting for their yard to load.
--
--  IN THE SAVE, keyed like the ledger, each holding "ax,ay,x,y,w,h": a ground
--  square of the building, to find it again, and its bounding box. On old
--  ground a key is either waiting here or recorded in the ledger, never both.
--  Fresh ground can queue a house the ledger knows (a wipe made its ground
--  new; S.onLoadChunk), and S.taken is then what keeps it to one rig.
--
--  The first queue lived in memory and gave a house up, into the ledger,
--  after twelve chunk events of any kind. The engine loads 169 chunks around
--  a player at once and 13 more at every chunk-boundary step, so nearly every
--  house was burned before its own yard arrived: in the live test of
--  2026-09-26 a teleport into Louisville queued a street of chosen houses and
--  built none. A house now waits for as long as it takes, across saves, and
--  is looked at again whenever a chunk its working area touches loads. A
--  building whose ground never exists (the map edge) just stays here.
S.WAITING = "OffGridSeedWaiting"

local function waitingBook()
    if not ModData or not ModData.getOrCreate then return nil end
    return ModData.getOrCreate(S.WAITING)
end

--- Chunk "kx,ky" -> { [house key] = true }, for every chunk a waiting house's
--  working area touches. Memory only: rebuilt from the save the first time a
--  chunk loads, so a house still waiting when the game was saved is watched
--  again.
S.INDEX = nil

--- This session's building defs by key, so a house found here is not looked
--  up again from its square.
S.DEFS = {}

--- Old chunks already scanned this session ("kx,ky"), so one streaming in and
--  out is looked at once a session, not at every load (S.onLoadChunk). Memory
--  only: a reload looks again, and finds what the ledger has decided since.
S.SCANNED = {}

--- Houses (and barns, by their own key) decided this session. A NEW chunk
--  decides a house the ledger knows again, but only once a session: a
--  dedicated server makes a whole cell readable before it fires its chunks'
--  LoadChunk events one by one (ServerMap.RecalcAll2), so a chosen house
--  spanning two fresh chunks is served in the first event and would be
--  decided again in the second. Memory only.
S.DECIDED = {}

--- "ax,ay,x,y,w,h": a ground square of the building and its bounding box,
--  as the waiting list keeps them (parseWait).
local function spot(sq, def)
    return sq:getX() .. "," .. sq:getY() .. "," .. def:getX() .. "," .. def:getY()
           .. "," .. def:getW() .. "," .. def:getH()
end

local floor = math.floor

local function parseWait(v)
    if type(v) ~= "string" then return nil end
    local ax, ay, x, y, w, h = string.match(v,
        "^(-?%d+),(-?%d+),(-?%d+),(-?%d+),(%d+),(%d+)$")
    if not ax then return nil end
    return tonumber(ax), tonumber(ay), tonumber(x), tonumber(y),
           tonumber(w), tonumber(h)
end

local function isBarnKey(key)
    return string.sub(key, 1, #S.BARN_KEY) == S.BARN_KEY
end

--- How much ground around the building a job needs loaded: a rig reads its
--  yard, a barn part only needs the barn.
local function padFor(key)
    if isBarnKey(key) then return 0 end
    return S.pad()
end

--- Every chunk the working area of a waiting job touches: the box
--  S.streamed walks, in chunks.
local function eachChunk(v, fn, pad)
    local ax, ay, x, y, w, h = parseWait(v)
    if not ax then return false end
    for kx = floor((x - pad) / 8), floor((x + w + pad) / 8) do
        for ky = floor((y - pad) / 8), floor((y + h + pad) / 8) do
            fn(kx .. "," .. ky)
        end
    end
    return true
end

local function indexAdd(key, v)
    return eachChunk(v, function(ck)
        local set = S.INDEX[ck]
        if not set then
            set = {}
            S.INDEX[ck] = set
        end
        set[key] = true
    end, padFor(key))
end

local function indexRemove(key, v)
    eachChunk(v, function(ck)
        local set = S.INDEX[ck]
        if set then set[key] = nil end
    end, padFor(key))
end

local function index(wait)
    if S.INDEX then return S.INDEX end
    S.INDEX = {}
    local bad = {}
    for key, v in pairs(wait) do
        if not indexAdd(key, v) then bad[#bad + 1] = key end
    end
    -- Save data is untrusted input: a malformed entry is dropped, never fatal.
    for i = 1, #bad do wait[bad[i]] = nil end
    return S.INDEX
end

--- A waiting house's building, from this session or found again from the
--  ground square it was queued from. Nil while that square is not loaded.
local function defOf(key, v)
    local def = S.DEFS[key]
    if def then return def end
    local ax, ay = parseWait(v)
    local sq = ax and getSquare(ax, ay, 0)
    local b = sq and sq:getBuilding()
    def = b and b:getDef()
    if def then S.DEFS[key] = def end
    return def
end

--- Tiles the map's own converters turn into IsoThumpables that carry build
--  materials: rain barrels (MORainCollectorBarrel, rebuilt as 02_54 and
--  02_122), lamps on pillars (MOLampOnPillar) and wooden wall frames
--  (MOWoodenWallFrame). They write their counts as text ("4"); a player's
--  build writes numbers (ISBuildingObject:updateModData). One of these tiles
--  with only text counts was put there by the map, not by a player.
S.MAP_THUMPABLES = {
    carpentry_02_54 = true, carpentry_02_122 = true,
    carpentry_02_59 = true, carpentry_02_60 = true, carpentry_02_61 = true,
    carpentry_02_62 = true, carpentry_02_100 = true, carpentry_02_101 = true,
}

--- Did a player build this? An IsoThumpable carrying build materials, the
--  dismantle refund (the marker the zomboid unit's save scans use), less the
--  map-converted ones above.
local function playerBuilt(o)
    if not (instanceof and instanceof(o, "IsoThumpable")) then return false end
    if try(o, "hasBuildMaterials") ~= true then return false end
    local spr = try(o, "getSprite")
    local name = spr and try(spr, "getName")
    if name and S.MAP_THUMPABLES[name] then
        local mats = try(o, "getBuildMaterials")
        local text = true
        if mats then
            for _, v in pairs(mats) do
                if type(v) ~= "string" then
                    text = false
                    break
                end
            end
        end
        if text then return false end
    end
    return true
end

--- A sign of a player's base on one object, or nil: something built, a
--  barricade, or a generator that is not an Off-Grid part. Moved furniture
--  leaves no mark the engine keeps, so it is not seen.
local function baseSign(o)
    if playerBuilt(o) then return "built by a player" end
    if instanceof and instanceof(o, "IsoBarricade") then return "barricaded" end
    if instanceof and instanceof(o, "IsoGenerator") and not P.partOf(o) then
        return "a generator"
    end
    return nil
end

--- Why a house's ground must be left as it is, or nil (Can, 2026-10-05).
--
--  Two jobs. Fresh ground decides every house again (S.onLoadChunk), so a
--  house whose rig survived a partial wipe must not get a second one; and
--  old ground is seeded too, so a player's base must not get one at all.
--  Asked once the job's whole working area is in memory (serve), over the
--  same box S.streamed waited for, at ground level, and over the building's
--  own box on its other floors:
--    * a safehouse over any of it (none in singleplayer);
--    * a sign of a base (baseSign): built, barricaded, a generator;
--    * an Off-Grid part that is this house's own or a player's: one seeded
--      for this house (seededFor, since 2026-10-05), one a player owns
--      (owner, on a server), or an untagged one within two squares of the
--      house's ground-floor rooms (a rig seeded before the tag existed, or a
--      singleplayer player's). A part seeded for another house is that
--      house's, and never takes this one's chance. A barn asks for any part
--      on its own floor.
function S.taken(def, pad, key)
    local bx, by, bw, bh = def:getX(), def:getY(), def:getW(), def:getH()
    local x0, y0, x1, y1 = bx - pad, by - pad, bx + bw + pad, by + bh + pad
    local SH = SafeHouse
    if SH and SH.getSafehouseOverlapping then
        -- [x, x2) in the engine (SafeHouse.java:183): the box's last column
        -- and row are x1 and y1, so the far edges go one past them
        local ok, sh = pcall(SH.getSafehouseOverlapping, x0, y0, x1 + 1, y1 + 1)
        if ok and sh then return "a safehouse" end
    end
    local barn = isBarnKey(key)
    local rooms = not barn and S.rooms(def, 0) or nil
    local function againstHouse(x, y)
        if barn then return true end
        if not rooms or #rooms == 0 then
            return x >= bx - 2 and x < bx + bw + 2 and y >= by - 2 and y < by + bh + 2
        end
        for i = 1, #rooms do
            local r = rooms[i]
            if x >= r.x - 2 and x < r.x + r.w + 2 and y >= r.y - 2 and y < r.y + r.h + 2 then
                return true
            end
        end
        return false
    end
    local function partSign(o, x, y)
        local d = P.data(o)
        if d.seededFor ~= nil then
            if d.seededFor == key then return "its own Off-Grid parts" end
            return nil
        end
        if d.owner ~= nil then return "a player's Off-Grid part" end
        if againstHouse(x, y) then return "an Off-Grid part against it" end
        return nil
    end
    local function look(x, y, z, parts)
        local sq = getSquare(x, y, z)
        local objs = sq and sq:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            local why = baseSign(o)
            if not why and parts and P.partOf(o) then why = partSign(o, x, y) end
            if why then return why end
        end
        return nil
    end
    for x = x0, x1 do
        for y = y0, y1 do
            local why = look(x, y, 0, true)
            if why then return why end
        end
    end
    -- the building's other floors, basements too, inside its own box
    local lo, hi = try(def, "getMinLevel") or 0, try(def, "getMaxLevel") or 0
    for z = lo, hi do
        if z ~= 0 then
            for x = bx, bx + bw - 1 do
                for y = by, by + bh - 1 do
                    local why = look(x, y, z, false)
                    if why then return why end
                end
            end
        end
    end
    return nil
end

--- Serve one waiting house if its whole working area has loaded.
--
--  The ledger is written AFTER the work, not before. What shipped once marked
--  the house first, so a rig that failed for any reason burned the house for
--  good: recorded as served, never retried. A house S.taken refuses is
--  recorded too: it is somebody's, or has its rig.
local function serve(book, wait, key)
    local v = wait[key]
    if not v then return end
    local def = defOf(key, v)
    if not def or not S.streamed(def, 0, padFor(key)) then return end
    indexRemove(key, v)
    wait[key] = nil
    book[key] = true
    S.DEFS[key] = nil
    local taken = S.taken(def, padFor(key), key)
    if taken then
        if S.DEBUG then
            print(string.format("OG_Seed: left alone at %d,%d -- %s",
                                def:getX(), def:getY(), taken))
        end
        return
    end
    if isBarnKey(key) then
        local parts, why = S.stockBarn(def)
        if parts then
            local sq = parts[1]:getSquare()
            print(string.format("OffGrid: stored %d surplus parts in the barn at %d,%d",
                                #parts, sq:getX(), sq:getY()))
        elseif S.DEBUG then
            print(string.format("OG_Seed: no stock in the barn at %d,%d -- %s",
                                def:getX(), def:getY(), tostring(why)))
        end
        return
    end
    local made, live, reasons = S.install(def, 0)
    if made and made > 0 then
        print(string.format(
            "OffGrid: seeded a %s rig at %d,%d (%d parts)",
            live and "working" or "flat", def:getX(), def:getY(), made))
    elseif S.DEBUG and reasons then
        local out = {}
        for why, n in pairs(reasons) do out[#out + 1] = why .. "=" .. n end
        table.sort(out)
        print(string.format("OG_Seed: no room at %d,%d -- %s",
                            def:getX(), def:getY(), table.concat(out, " ")))
    end
end

function S.onLoadChunk(chunk)
    if not chunk or not chunk.isNewChunk or not chunk.getGridSquare then
        return
    end
    local book, wait = ledger(), waitingBook()
    if not book or not wait then return end
    local idx = index(wait)

    -- IsoChunk has NO world-coordinate GETTERS. It carries the chunk indices as
    -- public int FIELDS, wx and wy, and the only exposed way in is
    -- getGridSquare(localX 0-7, localY 0-7, z), which is what this wants
    -- anyway. Calling a getter that does not exist throws once per new chunk
    -- and the seeding never runs.
    local origin = chunk:getGridSquare(0, 0, 0) or chunk:getGridSquare(7, 7, 0)
    local ck = origin and (floor(origin:getX() / 8) .. "," .. floor(origin:getY() / 8)) or nil

    -- Which chunks bring houses to the gate (Can, 2026-10-05). A NEW chunk
    -- always does, and decides every house on it, ledger or not: ground made
    -- now, for the first time or again after a wipe or a reset, and the roll
    -- is the house's own, so a known house gets the answer it had. S.taken
    -- keeps a second rig off a house whose old one survived. An OLD chunk
    -- does once a session, for the houses the ledger has never decided: a
    -- save that added the mod mid-game, or ground explored before the
    -- seeding existed. The ledger is what stops a rig being rebuilt every
    -- time an old chunk streams back in.
    local isNew = chunk:isNewChunk()
    local scan = isNew
    if ck then
        if not isNew and not S.SCANNED[ck] then scan = true end
        S.SCANNED[ck] = true
    end
    if scan then
        -- Fresh ground decides a house again, once a session (S.DECIDED); old
        -- ground only what the ledger has never decided. The legacy key is
        -- asked as well as the new one, so a save written before the key
        -- changed does not have every house it already served handed a
        -- second rig.
        local function open(k, known)
            if wait[k] then return false end
            if isNew then return not S.DECIDED[k] end
            return not known
        end
        local done = {}
        for dy = 0, 7 do
            for dx = 0, 7 do
                local sq = chunk:getGridSquare(dx, dy, 0)
                local b = sq and sq:getBuilding()
                local def = b and b:getDef()
                -- Once per building, not once per square: a chunk inside a
                -- big building meets the same def 64 times, and S.rooms
                -- builds a table for every room rect.
                if def and not done[def] then
                    done[def] = true
                    local key = S.key(def, S.rooms(def, 0))
                    if open(key, book[key] or book[S.legacyKey(def)]) then
                        S.DECIDED[key] = true
                        local n = S.rigChance()
                        if n > 0 and S.isResidential(def)
                                and S.roll(def, 3, n) == 0 then
                            -- Waiting, not served: its yard probably spans
                            -- chunks that have not arrived.
                            local v = spot(sq, def)
                            wait[key] = v
                            S.DEFS[key] = def
                            indexAdd(key, v)
                        else
                            book[key] = true
                        end
                    end
                    -- A barn is decided separately, under its own key, and
                    -- only a building that has a barn room is written down.
                    local bkey = S.BARN_KEY .. key
                    if open(bkey, book[bkey]) and S.isStorageBarn(def) then
                        S.DECIDED[bkey] = true
                        local n = S.barnChance()
                        if n > 0 and S.roll(def, 5, n) == 0 then
                            local v = spot(sq, def)
                            wait[bkey] = v
                            S.DEFS[bkey] = def
                            indexAdd(bkey, v)
                        else
                            book[bkey] = true
                        end
                    end
                end
            end
        end
    end

    -- Any chunk, new or not, may be the last piece of a waiting house's yard.
    -- Its own squares are already readable during its own LoadChunk (measured
    -- live, 169 chunks of 169), so the house is served from this very event.
    if not ck then return end
    local set = idx[ck]
    if not set then return end
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    -- A fixed order, so two neighbours finishing on the same chunk claim
    -- their shared ground the same way every time.
    table.sort(keys)
    for i = 1, #keys do serve(book, wait, keys[i]) end
end

Events.LoadChunk.Add(S.onLoadChunk)

return S

--[[ OffGrid -- the houses that already had solar.

     Some people in Knox County were running panels before the outbreak, and
     the world should say so. A fraction of residential buildings get a small
     rig in the yard: two or three ground arrays, a battery rack, and, rarely,
     a controller still wired to it.

     Almost all of them are stripped. Cracked frames, an empty rack, the
     controller long gone. That is the point: the first array a player ever
     touches should be one they dragged home and could not yet build, and the
     repair loop is what makes that a hook rather than a dead end. A small
     fraction are still live, and finding one of those is a real moment.

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

     The ledger is belt and braces. isNewChunk alone already makes double
     firing impossible, but a building straddles chunks, and two adjacent new
     chunks would otherwise each serve the same house.

     One caveat on isNewChunk that is worth knowing before trusting it: it
     returns IsoChunk.addZombies, which is set in exactly one place and gated
     on `!GameClient.client && Core.addZombieOnCellLoad` (IsoChunk.java:2258).
     So it is permanently FALSE on a multiplayer client, which is why the
     server does the seeding and this file returns early above; and it is
     false in the Tutorial and Last Stand game modes, where
     addZombieOnCellLoad is switched off (Core.java:751). Neither matters for
     survival play, but a feature that silently does nothing in a whole game
     mode is worth writing down rather than rediscovering.
]]

if isClient() then return end

require "OffGrid/OG_Parts"
require "OffGrid/OG_Model"

OffGrid = OffGrid or {}
OffGrid.Seed = OffGrid.Seed or {}
local S = OffGrid.Seed
local P = OffGrid.Parts
local M = OffGrid.Model
local try = P.try

-- One residential building in this many gets a rig.
S.CHANCE = 15
-- And one rig in this many is still working when it is found.
S.LIVE = 8
-- A stripped rig keeps its controller standing, switched off and wired to
-- nothing, DEAD_CTRL_HIT times in DEAD_CTRL_MOD (2 in 7, about 29%). 2.10.0:
-- replaying the roll over the real map put 15 seeded rigs in Muldraugh and
-- not one controller, because a controller was only ever placed on a live
-- rig, so players met piles of panels and racks and nothing to run them from.
-- Rolled with S.draw, like every roll taken after the gates: the first cut
-- used the linear S.roll with a modulus of 3, which divides S.CHANCE, and it
-- fired for 95.5% of seeded houses instead of a third (see S.draw).
S.DEAD_CTRL_MOD = 7
S.DEAD_CTRL_HIT = 2

-- The condition a weathered frame is found at. The same band the salvage loot
-- uses, so a panel out of a yard and a panel out of a barn read the same.
S.COND_MIN, S.COND_MAX = 15, 45

S.LEDGER = "OffGridSeededBuildings"

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

--- Vanilla's own definition of a residential building: somewhere to sleep,
--  somewhere to wash, and somewhere to cook or sit.
function S.isResidential(def)
    if not def or not def.getRoom then return false end
    if not def:getRoom("bedroom") then return false end
    if not def:getRoom("bathroom") then return false end
    return def:getRoom("kitchen") ~= nil or def:getRoom("livingroom") ~= nil
end

--- Would a part on this ring square stand in a doorway?
--
--  The ring runs right along the walls, and every part the seeder places is
--  solid, so a rig laid along a wall with a door in it walled the door off:
--  isFree only asks about the square itself, not about the edge it shares
--  with the house. The square one step into the footprint is the other side
--  of that edge; a corner of the ring touches the house at a point, not an
--  edge. A door, a door frame with no door in it, or a neighbour that is not
--  streamed in yet all rule the square out.
function S.facesDoor(sq, x, y, z, x1, y1, x2, y2)
    local nx, ny = x, y
    if x == x1 then nx = x + 1 elseif x == x2 then nx = x - 1 end
    if y == y1 then ny = y + 1 elseif y == y2 then ny = y - 1 end
    if (nx ~= x) == (ny ~= y) then return false end
    local inner = getSquare(nx, ny, z)
    if not inner then return true end
    if try(sq, "isDoorTo", inner) or try(sq, "getDoorTo", inner)
            or try(sq, "getDoorFrameTo", inner) then
        return true
    end
    -- An empty doorway is a wall piece flagged as a door frame, owned by the
    -- square to the south or east of the edge.
    local owner = (nx > x or ny > y) and inner or sq
    local props = try(owner, "getProperties")
    if props and IsoFlagType then
        local flag = (nx ~= x) and IsoFlagType.DoorWallW or IsoFlagType.DoorWallN
        if flag and try(props, "has", flag) then return true end
    end
    return false
end

--- Somewhere outdoors, on the ground, immediately around the building.
--  Walks the ring just outside the footprint so the rig reads as being in the
--  garden or on the drive rather than dropped in the street.
function S.yardSquares(def, z, want)
    local out = {}
    local x1, y1 = def:getX() - 1, def:getY() - 1
    local x2, y2 = def:getX() + def:getW(), def:getY() + def:getH()
    for y = y1, y2 do
        for x = x1, x2 do
            local edge = (x == x1 or x == x2 or y == y1 or y == y2)
            if edge then
                local sq = getSquare(x, y, z)
                if sq and sq:isOutside() and sq:getRoom() == nil
                        and sq:hasFloor() and sq:isFree(false)
                        and sq:getBuilding() == nil
                        and not S.facesDoor(sq, x, y, z, x1, y1, x2, y2) then
                    out[#out + 1] = sq
                    if #out >= want then return out end
                end
            end
        end
    end
    return out
end

--- Put one Off-Grid object on a square and make the world notice.
function S.place(sq, kind, mount, tier, state, facing)
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
    if OffGrid.System then OffGrid.System.register(o) end
    return o
end

--- Build one house's rig.
function S.install(def, z)
    local id = def
    local squares = S.yardSquares(def, z, 5)
    if #squares < 2 then return 0 end

    if S.DEBUG then
        print(string.format("OG_Seed: install at %d,%d -- %d yard squares",
                            def:getX(), def:getY(), #squares))
    end
    -- A controller needs a square of its own beside the arrays and the rack,
    -- so a yard with fewer than three free squares holds neither a working
    -- rig nor a dead controller, whatever the rolls say. A "working" rig
    -- there used to be a charged rack beside one array with nothing to run
    -- them from.
    local roomForController = #squares >= 3
    local live = roomForController and S.roll(id, 7, S.LIVE) == 0
    local deadCtrl = roomForController and not live
                     and S.draw(id, 9, S.DEAD_CTRL_MOD) < S.DEAD_CTRL_HIT
    local arrays = 2 + S.draw(id, 11, 2)          -- two or three
    local made = 0

    -- Leave the tail of the list for the rack and, when a controller stands
    -- (working or dead), for the controller. The old bound (#squares - 1) let
    -- a three-square yard put the controller on top of array two:
    -- makeController swaps sprites on whatever it is given, so the collision
    -- was silent and the rig looked like a controller standing in a hole in
    -- its own array row. At least one array always fits: a controller is
    -- only reserved for when there are three squares, and a yard of fewer
    -- than two was turned away above.
    local reserve = (live or deadCtrl) and 2 or 1
    local placedArrays = {}
    for i = 1, math.min(arrays, #squares - reserve) do
        local sq = squares[i]
        local tier = (S.draw(id, 20 + i, 4) == 0) and "standard" or "makeshift"
        -- Work out the state BEFORE placing, and place that sprite directly.
        --
        -- What shipped placed "clear" and then called P.setState to swap it,
        -- and every seeded array in the live world came out pristine: 28 of
        -- them, 0 cracked, where the condition roll says about 70% should be.
        -- The swap happens inside Events.LoadChunk, on an object the chunk has
        -- already taken via transmitAddObjectToSquare, and it does not reach
        -- the save. Building the right sprite up front removes the question
        -- rather than answering it, and it is one write instead of three.
        local spec = {
            condition = S.COND_MIN + S.draw(id, 30 + i, S.COND_MAX - S.COND_MIN),
            soiling   = 0.35 + S.draw(id, 40 + i, 40) / 100,
            snow      = 0,
        }
        local state = P.arrayState(spec)
        local o = S.place(sq, "array", "ground", tier, state, "S")
        if o then
            local d = P.data(o)
            d.condition = spec.condition
            d.panels = M.arraySpec(tier).panels
            d.soiling = spec.soiling
            d.snow = spec.snow
            d.state = state
            o:transmitModData()
            placedArrays[#placedArrays + 1] = sq
            if S.DEBUG then
                print(string.format("OG_Seed: array %d cond=%s (read back %s)",
                                    i, tostring(d.condition),
                                    tostring(P.data(o).condition)))
            end
            made = made + 1
        end
    end

    -- The rack. Empty in almost every case: whoever lived here took the
    -- batteries, or somebody else did.
    local bankSq = squares[#squares]
    -- "off" is NOT a bank state and never was. A rack's states are its cell
    -- counts, c0..c3, so P.sprite returned nil, S.place returned nil, and this
    -- whole block was skipped: no seeded house ever got its battery rack. It
    -- failed silently because a missing sprite is a nil return, not an error.
    -- Same shape as the array above: derive the state, then place it.
    local cells = live and (2 + S.draw(id, 51, 2)) or 0
    local spec  = { mount = "ground", tier = "makeshift", cells = cells }
    local state = P.bankState(spec)
    local o = S.place(bankSq, "bank", "ground", "makeshift", state, "S")
    if o then
        local d = P.data(o)
        d.condition = S.COND_MIN + S.draw(id, 50, S.COND_MAX - S.COND_MIN)
        d.cells = cells
        -- Health lives on the cells now. Each one gets its own draw around
        -- the rack's old flat figure, so a scavenged rack is a mix rather than
        -- six identically tired batteries, and the mean still lands where the
        -- single number used to be.
        local base = live and 0.7 or 0.55
        d.cellList = {}
        d.nextCellId = 1
        if live then
            for i = 1, cells do
                d.cellList[i] = {
                    id = i, type = "Base.CarBattery1",
                    health = M.clamp(base - 0.10 + S.draw(id, 60 + i, 21) / 100,
                                     0.25, 1),
                }
            end
            d.nextCellId = cells + 1
            -- Scaled like the live simulation scales it, or a server running
            -- BankScale 50 spawns racks holding twice what they can keep and
            -- the first tick clips the surplus into nothing.
            local cap = M.bankCapacity({ tier = "makeshift",
                                         cellSum = M.cellSum(d.cellList),
                                         scale = P.bankScale() }, 20)
            d.charge = cap * (0.3 + S.draw(id, 52, 40) / 100)
        else
            d.charge = 0
        end
        d.state = state
        o:transmitModData()
        made = made + 1
    end

    -- The controller only survives on a rig that still works. Everywhere else
    -- it is the one piece worth taking, and somebody took it.
    if live then
        local c = OffGrid.Place and OffGrid.Place.makeController(
            squares[#squares - 1], nil,
            { kind = "controller", mount = "ground", tier = "basic",
              facing = "S" }, nil)
        if c then
            local d = P.data(c)
            d.online = true
            d.trip = false
            -- WIRED, which is the whole point of finding one still standing.
            -- The seed set online=true and a charged rack and never wrote a
            -- single edge, so the flagship find was a controller powering
            -- nothing: the first relink walked an empty graph, claimed
            -- nothing, and the player met a dead rig sold as a live one.
            local csq = c:getSquare()
            local root = M.nodeKey(csq:getX(), csq:getY(), csq:getZ(),
                                   "controller")
            local w = ""
            for n = 1, #placedArrays do
                local aq = placedArrays[n]
                w = M.wireAdd(w, M.nodeKey(aq:getX(), aq:getY(), aq:getZ(),
                                           "array"), root)
            end
            if o then
                w = M.wireAdd(w, M.nodeKey(bankSq:getX(), bankSq:getY(),
                                           bankSq:getZ(), "bank"), root)
            end
            d.wire = w
            c:transmitModData()
            made = made + 1
        end
    elseif deadCtrl then
        -- Somebody took the batteries, not the box. Off, unwired, and
        -- worth carrying home: the one part of a stripped rig a player
        -- cannot build for weeks.
        local c = OffGrid.Place and OffGrid.Place.makeController(
            squares[#squares - 1], nil,
            { kind = "controller", mount = "ground", tier = "basic",
              facing = "S" }, nil)
        if c then
            local d = P.data(c)
            d.online = false
            d.trip = false
            d.wire = ""
            c:transmitModData()
            made = made + 1
        end
    end

    return made, live
end

--------------------------------------------------------------------- driver

local function ledger()
    if not ModData or not ModData.getOrCreate then return nil end
    return ModData.getOrCreate(S.LEDGER)
end

function S.onLoadChunk(chunk)
    if not chunk or not chunk.isNewChunk or not chunk.getGridSquare then
        return
    end
    -- The whole feature hangs off this one call. Without it the rig is rebuilt
    -- every time the chunk streams back in.
    if not chunk:isNewChunk() then return end

    local book = ledger()
    if not book then return end

    -- IsoChunk has NO world-coordinate GETTERS. It carries the chunk indices as
    -- public int FIELDS, wx and wy, and the only exposed way in is
    -- getGridSquare(localX 0-7, localY 0-7, z), which is what this wants
    -- anyway. Calling a getter that does not exist throws once per new chunk
    -- and the seeding never runs.
    local seen = {}

    for dy = 0, 7 do
        for dx = 0, 7 do
            local sq = chunk:getGridSquare(dx, dy, 0)
            local b = sq and sq:getBuilding()
            local def = b and b:getDef()
            if def then
                -- Keyed on coordinates, not on the metaId: see M.placeRoll for why
                -- a long that large is not safe to work with in Lua.
                local key = def:getX() .. "," .. def:getY()
                if not seen[key] and not book[key] then
                    seen[key] = true
                    if S.isResidential(def)
                            and S.roll(def, 3, S.CHANCE) == 0 then
                        -- Marked before the work, not after. A house whose
                        -- yard turns out to be unusable must not be retried
                        -- from the next chunk and end up with two rigs.
                        book[key] = true
                        local made, live = S.install(def, 0)
                        if made and made > 0 then
                            print(string.format(
                                "OffGrid: seeded a %s rig at %d,%d (%d parts)",
                                live and "working" or "stripped",
                                def:getX(), def:getY(), made))
                        end
                    else
                        book[key] = true
                    end
                end
            end
        end
    end
end

Events.LoadChunk.Add(S.onLoadChunk)

return S

--[[ OffGrid -- deciding where a house's rig stands.

     Shared, and deliberately free of dependencies: the offline bench loads
     THIS FILE ALONE against map data pulled out of the .lotpack files, so a
     placement change can be replayed over all 4,607 residential buildings in
     Knox County without starting the game. That is only true while this file
     requires nothing and touches no global except OffGrid and a guarded
     IsoFlagType, so keep it that way -- the local `try` below exists rather
     than reusing P.try for exactly this reason.

     Everything the planner learns about the world arrives through `env`, so
     the same shipped code runs against real IsoGridSquares in game and
     against a table of flags in the bench.

     Two rules from Can, 2026-09-21, and both are load-bearing here:

       1. No seeded rig may be missing its controller or its battery bank.
          People were LIVING with these things before the outbreak; a solar
          array wired to nothing is not a story, it is a bug. So this planner
          is all-or-nothing: it returns a plan holding every part or it
          returns nil. There is no shape of the return value that describes a
          half rig, which is a better guarantee than a check downstream.

       2. Panels must not stand in front of doors, garage doors or roads.
          Handled as vetoes rather than as penalties, because a penalty only
          loses when something better exists, and the whole complaint is
          about the houses where it did not.

     What it replaces: S.yardSquares walked the bounding box and returned the
     first five squares in raster order. The north row is long enough on 100%
     of residential buildings, so 98.8% of rigs landed on the N or NW edge
     whatever the yard actually looked like, 11.2% of them on pavement, while
     the median house had 42 acceptable squares it never examined. Roles were
     assigned by list index -- squares[#squares] was the rack, [#squares-1]
     the controller -- so the parts scattered wherever the raster walk had
     happened to end.
]]

OffGrid = OffGrid or {}
OffGrid.Yard = OffGrid.Yard or {}
local Y = OffGrid.Yard

------------------------------------------------------------------- tunables

--- How far out from a wall the survey looks. Parts always stand at depth 1
--  (see Y.layout), so this is not a placement reach -- it is how much open
--  ground a side is credited with in `room` scoring. Three is enough to tell
--  a garden from a gap between two houses, and past that the ground stops
--  belonging to this house in any meaningful sense.
Y.REACH = 3

--- Clear corridor kept outside every door: three deep and one square either
--  side, which is enough to step out and turn either way.
Y.DOOR_CLEAR = 3
Y.DOOR_WIDE = 1

--- A garage needs the whole width of its wall kept clear. That is a
--  driveway, and a car has to be able to come out of it.
Y.GARAGE_CLEAR = 4

--- THE PANEL FIELD.
--
--  A rig is two masses, not a line: a SERVICE CLUSTER of controller and racks
--  against the house, and a FIELD of panels standing off in the yard, joined
--  by a cable run. Can's own hand-placed example is the specification --
--  panels out in the garden, controller on the wall, racks down the side, and
--  nothing collinear.
--
--  FIELD_REACH is how far the yard flood walks from the wall. It is NOT
--  Y.REACH: that one is the side-survey depth and also the `room` score, so
--  redefining it would silently retune every side score and the wall
--  histogram the bench gates on.
Y.FIELD_REACH = 6     -- walk steps from a wall seat
Y.FIELD_GAP   = 3     -- preferred clear squares between house and panels
Y.FIELD_FAR   = 6     -- where the stand-off reward stops growing
Y.FIELD_BUDGET = 420  -- hard cap on square probes per plan
Y.LINK        = 9     -- max EUCLIDEAN controller to nearest panel

--- How far past the building's bounding box the planner ever reads a square:
--  the wall shell one past the south and east rooms, a seat against it, the
--  yard walk FIELD_REACH steps further, and the door test one square beyond
--  that. The seeder waits for all of it to be loaded before it plans, because
--  a square not loaded yet reads as refused, and a rig must not depend on
--  which way the player happened to arrive.
Y.READS = Y.FIELD_REACH + 3

--- WHICH PLANNER PRODUCED A PLAN.
--
--  Stamped onto every verdict, because a verdict is an opinion about a
--  specific proposal. Bump it by hand whenever the SHAPE of a plan changes --
--  not for a weight tweak, but for anything that moves parts around. A
--  verdict taken against an older version still says "this house should have
--  a rig", which is enough to gate seeding, but it is not an opinion about
--  the rig now on screen.
--
--    1  the single row against one wall
--    2  cluster against the wall, panel field standing off in the yard
Y.VERSION = 2

--- What a complete rig is made of.
--
--  ONE controller, always, and never more than one: a second charge
--  controller on a domestic rig is not a thing anybody built, and the wire
--  graph has one root. Arrays and banks are plural because a household that
--  ran on this would have added to it -- another pair of panels one summer, a
--  second rack when the first stopped holding a night.
--
--  Exactly one controller is enforced by the plan's shape rather than by a
--  count, the same way completeness is: there is one `controller` field.
Y.MIN_ARRAYS = 2
Y.MAX_ARRAYS = 4
Y.MIN_BANKS = 1
Y.MAX_BANKS = 2

--- What is left in the racks, per Can, 2026-09-21: usually something, and
--  what is there is usually nearly finished. An empty rack is fine and
--  common -- somebody got here first -- but the default story is a household
--  whose batteries died slowly rather than a looted one.
--
--  Read by the seeder when it fills a rack. Kept here with the rest of the
--  rig's composition so "what a seeded rig is" lives in one file.
Y.CELLS = {
    EMPTY_IN  = 4,          -- one rack in this many is bare
    MIN       = 3,          -- per-cell health, percent
    MAX       = 32,
    SPARED_IN = 8,          -- one cell in this many outlived the rest
    SPARED_MAX = 60,
}

--- Scoring weights. These are taste, not measurement, and they are exactly
--  what Can's good/bad pass is meant to correct. Kept together in one table
--  so the bench can sweep them without hunting through the body.
Y.W = {
    south     = 40,   -- a panel row that faces south is the whole point
    east      = 10,   -- east and west are workable
    west      = 10,
    north     = 0,    -- a north wall is a last resort, not a veto
    room      = 3,    -- per accepted square on the side: room to breathe
    roadNear  = -18,  -- kerbside: legal, ugly, and full of the dead
    window    = -12,  -- do not board up somebody's living room window
    perSquare = 2,    -- prefer a side that can hold the whole row
    -- the field terms
    sun       = 7,    -- per open square to the south of the panel block
    gap       = 6,    -- per square of stand-off from the house, to FIELD_FAR
    wire      = -2,   -- per step of cable back to the controller
    hug       = 4,    -- per panel backing onto a fence or hedge
    block     = 12,   -- a square block reads better than a line
    frontDoor = -30,  -- panels belong in the BACK garden, not on the lawn
}

--- Why a square was turned away. The testbed paints these on the ground, so
--  they are stable strings rather than numbers: a screenshot of a rejected
--  yard should be readable without a decoder ring.
Y.R = {
    NOSQUARE = "nosquare",   -- not streamed in, or off the map
    INDOOR   = "indoor",     -- inside, or under a roof
    NOFLOOR  = "nofloor",
    BLOCKED  = "blocked",    -- solid, hoppable, tree, vehicle
    DOOR     = "door",       -- shares an edge with a door, anyone's door
    DOORWAY  = "doorway",    -- stands in the corridor outside a door
    GARAGE   = "garage",     -- stands on the drive
    ROAD     = "road",
    FOREIGN  = "foreign",    -- the engine says this square is next door's
    CLAIMED  = "claimed",    -- an earlier house in this pass took it
    NOROOM   = "noroom",     -- nothing rejected it; the row just did not fit
    NOWALL   = "nowall",     -- no run of wall long enough for the cluster
    NOFIELD  = "nofield",    -- a cluster, but nowhere to stand the panels
}

------------------------------------------------------------------- plumbing

--- Call an optional method: nil when the object is nil, lacks the method, or
--  throws. Duplicated from OG_Parts on purpose -- see the header.
local function try(obj, method, ...)
    if not obj or not obj[method] then return nil end
    local ok, v = pcall(obj[method], obj, ...)
    if ok then return v end
    return nil
end

local DIRS = {
    N = { dx =  0, dy = -1, axis = "y", along = "x" },
    S = { dx =  0, dy =  1, axis = "y", along = "x" },
    W = { dx = -1, dy =  0, axis = "x", along = "y" },
    E = { dx =  1, dy =  0, axis = "x", along = "y" },
}
local ORDER = { "S", "E", "W", "N" }
local WEIGHT_OF = { S = "south", N = "north", E = "east", W = "west" }

local function key(x, y) return x .. "," .. y end

------------------------------------------------------------------ footprint

--- The squares the house actually stands on, from its ground-floor rooms.
--
--  NOT the bounding box. 24.1% of bounding-box ring squares are two or more
--  tiles from the nearest ground-floor room, which is how rigs ended up
--  across the street from an L-shaped house, or inside its courtyard.
--
--  Falls back to the bounding box when a def carries no usable rooms; the
--  caller gets `boxed` so the bench can count those rather than let them hide
--  in the averages.
function Y.footprint(b, env)
    local fp = { set = {}, n = 0, boxed = false, garage = {}, shell = {} }
    local z = b.z or 0

    local function add(x1, y1, w, h, isGarage)
        for x = x1, x1 + w - 1 do
            for y = y1, y1 + h - 1 do
                local k = key(x, y)
                if not fp.set[k] then fp.n = fp.n + 1 end
                fp.set[k] = true
                if isGarage then fp.garage[k] = true end
            end
        end
    end

    local rooms = b.rooms
    if rooms then
        for i = 1, #rooms do
            local r = rooms[i]
            if (r.level or z) == z and r.w and r.h and r.w > 0 and r.h > 0 then
                local name = r.name and string.lower(r.name) or ""
                add(r.x, r.y, r.w, r.h,
                    string.find(name, "garage", 1, true) ~= nil)
            end
        end
    end

    if fp.n == 0 then
        fp.boxed = true
        add(b.x, b.y, b.w or 1, b.h or 1, false)
    end

    -- THE WALL SHELL, and it is the difference between using half a house and
    -- using all of it.
    --
    -- A wall in this engine belongs to the NORTH or WEST edge of the square
    -- it stands on. So a room's north and west walls sit on the room's own
    -- first row and column -- already inside the rects above -- while its
    -- south and east walls sit on the squares one PAST the rects. Those
    -- squares are the building, not the garden.
    --
    -- Without this the apron on the south and east sides starts ON the
    -- house's own wall, which Y.clear rejects as blocked, and because each
    -- ray stops at its first obstruction the two depths behind it are never
    -- reached either. Replaying the real map said it plainly: over 105 houses
    -- with a rig, the south side was chosen ZERO times and the east side
    -- zero times, while every one of them had open ground there.
    --
    -- Only squares that really carry the wall are taken, so a room open to
    -- the sky on its south side keeps its ground.
    if env and env.getSquare then
        local pend = {}
        for k in pairs(fp.set) do
            local cx, cy = string.match(k, "^(-?%d+),(-?%d+)$")
            cx, cy = tonumber(cx), tonumber(cy)
            for _, step in ipairs({ { 0, 1, "WallN" }, { 1, 0, "WallW" } }) do
                local nx, ny = cx + step[1], cy + step[2]
                if not fp.set[key(nx, ny)] then
                    local pr = try(env.getSquare(nx, ny, z), "getProperties")
                    if pr and try(pr, "has", step[3]) then
                        pend[key(nx, ny)] = fp.garage[k] or false
                    end
                end
            end
        end
        for k, isGarage in pairs(pend) do
            if not fp.set[k] then
                fp.set[k] = true
                fp.shell[k] = true
                fp.n = fp.n + 1
                if isGarage then fp.garage[k] = true end
            end
        end
    end
    return fp
end

--- Every (cell, outward direction) pair where the house meets open ground.
function Y.faces(fp)
    local out = {}
    for k in pairs(fp.set) do
        local cx, cy = string.match(k, "^(-?%d+),(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        for i = 1, #ORDER do
            local d = ORDER[i]
            local v = DIRS[d]
            if not fp.set[key(cx + v.dx, cy + v.dy)] then
                out[#out + 1] = { x = cx, y = cy, dir = d,
                                  garage = fp.garage[k] or false }
            end
        end
    end
    -- Deterministic: the bench replays a building many times and must get the
    -- same plan every time, and pairs() over a hash is not ordered.
    table.sort(out, function(p, q)
        if p.x ~= q.x then return p.x < q.x end
        if p.y ~= q.y then return p.y < q.y end
        return p.dir < q.dir
    end)
    return out
end

---------------------------------------------------------------------- doors

--- Is there a door, or an empty door frame, on the edge between these two?
--
--  isDoorTo and getDoorTo find a door that is hung there, open or shut. An
--  empty doorway has no door object at all: it is a wall piece flagged as a
--  door frame, which only the flag test below finds. The flag belongs to the
--  square to the south or east of the edge, so asking the wrong square
--  returns nothing and the rig walls up the opening. (getDoorFrameTo, asked
--  here once, only ever found the same hung doors as getDoorTo, and 42.21
--  removed it.)
local function doorBetween(env, ax, ay, bx, by, z)
    local a, b = env.getSquare(ax, ay, z), env.getSquare(bx, by, z)
    if not a or not b then return false end
    if try(a, "isDoorTo", b) or try(a, "getDoorTo", b) then
        return true
    end
    local owner = (bx > ax or by > ay) and b or a
    local props = try(owner, "getProperties")
    if props and IsoFlagType then
        local flag = (ax ~= bx) and IsoFlagType.DoorWallW
                                or IsoFlagType.DoorWallN
        if flag and try(props, "has", flag) then return true end
    end
    return false
end
-- The seeder's storage-barn stash keeps its tiles off doorways with it too.
Y.doorBetween = doorBetween

--- Squares that must stay clear because somebody has to walk or drive there.
--
--  Built once per building and consulted per candidate. This covers the
--  house's OWN doors and garages. A neighbour's door is caught separately,
--  by testing all four edges of each candidate in Y.check: the shipped
--  S.facesDoor tested one inner edge only, so a neighbour's front door was
--  never examined at all and a rig could be laid straight across it.
function Y.aprons(b, fp, faces, env)
    local z = b.z or 0
    local out = {}
    local function mark(x, y, why)
        local k = key(x, y)
        if not out[k] then out[k] = why end
    end

    for i = 1, #faces do
        local f = faces[i]
        local v = DIRS[f.dir]
        local isDoor = doorBetween(env, f.x, f.y, f.x + v.dx, f.y + v.dy, z)
        if isDoor or f.garage then
            local deep = f.garage and Y.GARAGE_CLEAR or Y.DOOR_CLEAR
            local wide = f.garage and 0 or Y.DOOR_WIDE
            local why  = f.garage and Y.R.GARAGE or Y.R.DOORWAY
            for step = 1, deep do
                local bx, by = f.x + v.dx * step, f.y + v.dy * step
                mark(bx, by, why)
                -- Widen sideways so you can step out of a door and turn.
                for w = 1, wide do
                    if v.along == "x" then
                        mark(bx - w, by, why)
                        mark(bx + w, by, why)
                    else
                        mark(bx, by - w, why)
                        mark(bx, by + w, why)
                    end
                end
            end
        end
    end
    return out
end

--------------------------------------------------------------------- vetoes

--- Does this square read as public road or pavement?
--
--  Tarmac is flat, empty and enormous, so it wins every geometric test going,
--  and it is also the middle of the street. Lifted from the testbed, where it
--  was written after a run dropped the character on a road.
function Y.roadish(sq)
    local objs = try(sq, "getObjects")
    if not objs then return false end
    for i = 0, objs:size() - 1 do
        local sp = try(objs:get(i), "getSprite")
        local n = sp and try(sp, "getName")
        if n and (string.find(n, "blends_street", 1, true)
                  or string.find(n, "street_", 1, true)
                  or string.find(n, "sidewalk", 1, true)) then
            return true
        end
    end
    return false
end

--- Is anything already standing here?
--
--  isFree(false) is not enough on its own: fences, low walls, gates and
--  tennis nets do not report as solid, so a yard can pass every test the
--  engine offers and still have something strung across the middle of it.
function Y.clear(sq)
    if try(sq, "isVehicleIntersecting") then return false end
    local objs = try(sq, "getObjects")
    if not objs then return true end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local sp = try(o, "getSprite")
        local pr = sp and try(sp, "getProperties")
        if pr and (try(pr, "has", "solid") or try(pr, "has", "solidtrans")
                   or try(pr, "has", "WallN") or try(pr, "has", "WallW")
                   or try(pr, "has", "doorN") or try(pr, "has", "doorW")
                   or try(pr, "has", "WindowN") or try(pr, "has", "WindowW")
                   or try(pr, "has", "HoppableN")
                   or try(pr, "has", "HoppableW")) then
            return false
        end
        if instanceof and instanceof(o, "IsoTree") then return false end
    end
    return true
end

--- Everything that rules a single square out, cheapest test first. Returns
--  nil when the square is acceptable, or the reason code when it is not.
function Y.check(b, fp, aprons, env, x, y)
    local z = b.z or 0
    if fp.set[key(x, y)] then return Y.R.INDOOR end

    local a = aprons[key(x, y)]
    if a then return a end

    local sq = env.getSquare(x, y, z)
    if not sq then return Y.R.NOSQUARE end
    if try(sq, "isOutside") == false then return Y.R.INDOOR end
    if try(sq, "getRoom") ~= nil then return Y.R.INDOOR end
    if try(sq, "getBuilding") ~= nil then return Y.R.INDOOR end
    if not try(sq, "hasFloor") then return Y.R.NOFLOOR end
    if try(sq, "isFree", false) == false then return Y.R.BLOCKED end
    if not Y.clear(sq) then return Y.R.BLOCKED end
    if Y.roadish(sq) then return Y.R.ROAD end

    -- All four edges, not one. This is what catches the neighbour's door.
    for i = 1, #ORDER do
        local v = DIRS[ORDER[i]]
        if doorBetween(env, x, y, x + v.dx, y + v.dy, z) then
            return Y.R.DOOR
        end
    end

    if env.owner and b.id ~= nil then
        local id = env.owner(x, y, z)
        if id ~= nil and id ~= b.id then return Y.R.FOREIGN end
    end
    if env.claimed and env.claimed(x, y, z) then return Y.R.CLAIMED end
    return nil
end

--------------------------------------------------- one probe per square

--- Y.check, memoised, budgeted, and counted.
--
--  The flood asks about the same square from several directions and Y.sides
--  re-asks per side, so without this the yard walk would pay two or three
--  times over for probes it already made. The budget is a hard stop: a house
--  on open farmland would otherwise flood until it ran out of reach.
function Y.probe(ctx, x, y)
    local k = key(x, y)
    local hit = ctx.memo[k]
    if hit ~= nil then return hit or nil end
    if ctx.spent >= Y.FIELD_BUDGET then return Y.R.NOSQUARE end
    ctx.spent = ctx.spent + 1
    local why = Y.check(ctx.b, ctx.fp, ctx.aprons, ctx.env, x, y)
    ctx.memo[k] = why or false
    return why
end

--- A deterministic value in 0..n-1 from a building's identity.
--
--  Local on purpose: this file requires nothing, so it cannot reach the
--  seeder's S.draw. Only ever used to choose between candidates that already
--  scored within a whisker of each other, so a weak hash is fine -- what
--  matters is that the SAME house makes the SAME choice every time, in game
--  and in the bench.
function Y.spin(id, salt, n)
    if n <= 1 then return 0 end
    local h = 5381 + (salt or 0) * 131
    local s = tostring(id or "")
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 16777213
    end
    return h % n
end

---------------------------------------------------------------------- sides

--- A straight stretch of wall facing one way, with its apron surveyed.
--
--  Keyed by direction AND by the line the wall sits on, so the two north
--  walls of an L-shaped house are two different sides and a panel row never
--  jumps the gap between them.
function Y.sides(b, fp, aprons, env, reasons, memo)
    local z = b.z or 0
    local faces = Y.faces(fp)
    local byKey, out = {}, {}

    for i = 1, #faces do
        local f = faces[i]
        local v = DIRS[f.dir]
        local line = (v.axis == "y") and f.y or f.x
        local k = f.dir .. ":" .. line
        local s = byKey[k]
        if not s then
            s = { dir = f.dir, line = line, ok = {}, n = 0,
                  road = 0, window = 0, door = 0 }
            byKey[k] = s
            out[#out + 1] = s
        end

        -- Survey outward from this face square, and STOP at the first thing
        -- in the way. The apron is what you can see from the wall: if a road
        -- runs along the house then the ground beyond it is across the
        -- street, and if a fence stands at depth one then depth two is the
        -- next garden along. Walking past the obstruction was how a rig ended
        -- up on the far kerb of its own street.
        for depth = 1, Y.REACH do
            local x, y = f.x + v.dx * depth, f.y + v.dy * depth
            local along = (v.along == "x") and x or y
            local ak = along .. ":" .. depth
            if s.ok[ak] == nil then
                local why = Y.check(b, fp, aprons, env, x, y)
                if memo then memo[key(x, y)] = why or false end
                if why then
                    s.ok[ak] = false
                    if reasons then
                        reasons[why] = (reasons[why] or 0) + 1
                    end
                    break
                else
                    s.ok[ak] = { x = x, y = y, depth = depth, along = along }
                    s.n = s.n + 1
                    for j = 1, #ORDER do
                        local nv = DIRS[ORDER[j]]
                        if Y.roadish(env.getSquare(x + nv.dx,
                                                   y + nv.dy, z)) then
                            s.road = s.road + 1
                            break
                        end
                    end
                end
            end
        end

        -- A window on this wall face is a view the rig should not board up.
        local pr = try(env.getSquare(f.x, f.y, z), "getProperties")
        if pr and (try(pr, "has", "WindowN") or try(pr, "has", "WindowW")) then
            s.window = s.window + 1
        end

        -- And a DOOR on this face makes this the front of the house. The
        -- planner had no front/back signal at all, so "put the panels in the
        -- back garden" was not expressible -- on a house whose door faces
        -- south the sun term would have put the block on the front lawn,
        -- which is the exact inverse of what was asked for.
        if doorBetween(env, f.x, f.y, f.x + v.dx, f.y + v.dy, z) then
            s.door = s.door + 1
        end
    end

    for i = 1, #out do
        local s = out[i]
        s.score = (Y.W[WEIGHT_OF[s.dir]] or 0)
                + s.n * Y.W.room
                + s.road * Y.W.roadNear
                + s.window * Y.W.window
    end
    table.sort(out, function(p, q)
        if p.score ~= q.score then return p.score > q.score end
        if p.dir ~= q.dir then return p.dir < q.dir end
        return p.line < q.line
    end)
    return out
end

--------------------------------------------------------------------- layout

--- THE FALLBACK: one straight row, racks then controller then panels.
--
--  Kept verbatim as the last rung of the ladder. When no field fits -- a
--  terrace with a two-square yard, a house hemmed in on every side -- a row
--  against the wall is still better than no rig, and keeping this code
--  untouched means the houses that fall through reproduce exactly what they
--  produced before.
--
--  The order is not decoration. It is the order the current runs in -- panels
--  into the controller, controller into the batteries -- so the controller
--  ends up between the thing that charges and the thing being charged, with
--  the shortest run to both. The racks take the sheltered end against the
--  house, where the heavy thing nobody moved would have been put.
--
--      B B C # # #
--
--  Roles come out of that geometry instead of out of a list index, which is
--  what scattered them before.
--  The row always goes at depth 1, and there is no search over depth, because
--  there is nothing to search: the survey stops each ray at its first
--  obstruction, so a square at depth 2 exists only when the square at depth 1
--  in front of it was clear. The accepted set at depth 2 is therefore a
--  SUBSET of the one at depth 1, and its longest run can never be longer. A
--  loop over depths could only ever return on its first pass. An earlier cut
--  had one anyway, along with a score term that -- through a flipped sign --
--  paid a bonus for standing further out in the garden.
function Y.layoutRow(side, arrays, banks)
    local need = arrays + banks + 1
    do
        local depth = 1
        local line = {}
        for _, v in pairs(side.ok) do
            if v and v.depth == depth then line[#line + 1] = v end
        end
        if #line >= need then
            table.sort(line, function(p, q) return p.along < q.along end)
            -- The longest consecutive stretch at this depth.
            local best, run = nil, { line[1] }
            for i = 2, #line do
                if line[i].along == line[i - 1].along + 1 then
                    run[#run + 1] = line[i]
                else
                    if not best or #run > #best then best = run end
                    run = { line[i] }
                end
            end
            if not best or #run > #best then best = run end

            if best and #best >= need then
                local plan = {
                    dir = side.dir, depth = depth, arrays = {}, banks = {},
                    score = side.score + #best * Y.W.perSquare,
                }
                for i = 1, banks do
                    plan.banks[#plan.banks + 1] =
                        { x = best[i].x, y = best[i].y, facing = side.dir }
                end
                plan.controller = { x = best[banks + 1].x,
                                    y = best[banks + 1].y,
                                    facing = side.dir }
                for i = banks + 2, need do
                    plan.arrays[#plan.arrays + 1] =
                        { x = best[i].x, y = best[i].y, facing = side.dir }
                end
                return plan
            end
        end
    end
    return nil
end


---------------------------------------------------------------- the field

--- Where a rack or a controller can stand: an accepted square touching the
--  house, grouped into the straight runs a cluster can occupy.
--
--  A cluster needs banks+1 consecutive squares, NOT arrays+banks+1. That is
--  the whole reason this shape fits more houses than the row it replaces: a
--  two or three square stretch against a wall exists where a six or seven
--  square one does not.
function Y.seats(ctx, sides)
    local out, runs = {}, {}
    for _, s in ipairs(sides) do
        local v = DIRS[s.dir]
        local byAlong = {}
        local alongs = {}
        for _, q in pairs(s.ok) do
            if q and q.depth == 1 then
                byAlong[q.along] = q
                alongs[#alongs + 1] = q.along
            end
        end
        table.sort(alongs)
        local i = 1
        while i <= #alongs do
            local j = i
            while j < #alongs and alongs[j + 1] == alongs[j] + 1 do j = j + 1 end
            local run = { dir = s.dir, line = s.line, side = s, seats = {} }
            for k = i, j do
                local q = byAlong[alongs[k]]
                run.seats[#run.seats + 1] = q
                out[#out + 1] = { x = q.x, y = q.y, run = run,
                                  along = q.along, dir = s.dir }
            end
            runs[#runs + 1] = run
            i = j + 1
        end
    end
    -- One stable order for everything downstream.
    table.sort(out, function(p, q)
        if p.x ~= q.x then return p.x < q.x end
        return p.y < q.y
    end)
    return out, runs
end

--- Walk the yard outward from the wall, over ACCEPTED ground only.
--
--  4-connected, so the walk cannot step diagonally past a fence post, and it
--  stops at anything Y.check refuses -- a road, a hedge, a tree, a
--  neighbour's wall. That is what keeps a panel field in THIS garden without
--  needing a radius: ground you cannot walk to from this house's own wall is
--  not this house's yard, whatever the straight-line distance says.
--
--  Refusals met on the way are counted, and INDOOR refusals on squares
--  outside this footprint are recorded: those are a NEIGHBOUR'S walls, and
--  the halfway rule below is built from them.
function Y.flood(ctx, seats)
    local dist, order, foreign = {}, {}, {}
    local why = {}
    local head, tail = 1, 0
    for i = 1, #seats do
        local k = key(seats[i].x, seats[i].y)
        if dist[k] == nil then
            dist[k] = 0
            tail = tail + 1
            order[tail] = { x = seats[i].x, y = seats[i].y }
        end
    end
    while head <= tail do
        local cur = order[head]
        head = head + 1
        local d = dist[key(cur.x, cur.y)]
        if d < Y.FIELD_REACH then
            for i = 1, #ORDER do
                local v = DIRS[ORDER[i]]
                local nx, ny = cur.x + v.dx, cur.y + v.dy
                local nk = key(nx, ny)
                if dist[nk] == nil and not ctx.fp.set[nk] then
                    local refused = Y.probe(ctx, nx, ny)
                    if refused then
                        dist[nk] = false
                        why[refused] = (why[refused] or 0) + 1
                        if refused == Y.R.INDOOR then
                            foreign[#foreign + 1] = { x = nx, y = ny }
                        end
                    else
                        dist[nk] = d + 1
                        tail = tail + 1
                        order[tail] = { x = nx, y = ny }
                    end
                end
            end
        end
    end
    return dist, order, foreign, why
end

--- The house's squares by column, parsed once per plan and kept on the
--  footprint: cols[x][y] is true for every square of the house.
local function footprintColumns(fp)
    local cols = fp.cols
    if cols then return cols end
    cols = {}
    local any = false
    for k in pairs(fp.set) do
        local cx, cy = string.match(k, "^(-?%d+),(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        local col = cols[cx]
        if not col then
            col = {}
            cols[cx] = col
        end
        col[cy] = true
        any = true
    end
    fp.cols, fp.colsAny = cols, any
    return cols
end

--- Chebyshev distance from a square to the nearest square of this house.
--
--  Found by looking outward one ring at a time: the first ring that touches
--  the house is the distance, which is exactly the minimum over every square
--  of the house. The first form measured to EVERY square, parsing each one's
--  key, for every yard square on every rung of the ladder in Y.plan: 1.4
--  million string matches on a 36 x 11 house, 3.4 seconds of frozen game in
--  Kahlua, and minutes on the largest (live test, 2026-09-26).
local function chebToFootprint(fp, x, y)
    local cols = footprintColumns(fp)
    if not fp.colsAny then return 999 end
    local r = 0
    while true do
        for cx = x - r, x + r do
            local col = cols[cx]
            if col then
                if cx == x - r or cx == x + r then
                    for cy = y - r, y + r do
                        if col[cy] then return r end
                    end
                elseif col[y - r] or col[y + r] then
                    return r
                end
            end
        end
        r = r + 1
    end
end

local function chebToList(list, x, y)
    local best = nil
    for i = 1, #list do
        local dx, dy = list[i].x - x, list[i].y - y
        if dx < 0 then dx = -dx end
        if dy < 0 then dy = -dy end
        local d = (dx > dy) and dx or dy
        if not best or d < best then best = d end
    end
    return best
end

--- THE HALFWAY RULE, and it is the price of admission for decoupling.
--
--  A field standing off three to six squares from the wall can easily be
--  standing in the garden next door: the walk reached it because there is no
--  fence between, not because it belongs here. Measured over 400 real houses,
--  decoupling without this put 6.1% of rigs within two squares of a
--  neighbour's interior, against 1.4% for the old row.
--
--  The fix costs nothing and needs no new information. A square is ours only
--  if it is closer to OUR walls than to a neighbour's -- the midline between
--  the two buildings. The neighbour's walls are already known: the flood met
--  them as INDOOR refusals on squares outside our own footprint. Measured
--  again with the rule in: 0.0%, with no loss of fit.
function Y.halfway(ctx, dist, order, foreign)
    local kept = {}
    -- Every rung of the ladder asks about the same yard, and the house does
    -- not move between them, so each square's distance is worked out once.
    local near = ctx.fp.near
    if not near then
        near = {}
        ctx.fp.near = near
    end
    for i = 1, #order do
        local s = order[i]
        local k = key(s.x, s.y)
        local d = dist[k]
        if d then
            local dfp = near[k]
            if dfp == nil then
                dfp = chebToFootprint(ctx.fp, s.x, s.y)
                near[k] = dfp
            end
            local dnb = (#foreign > 0) and chebToList(foreign, s.x, s.y) or nil
            if dnb and dfp >= dnb then
                dist[k] = false
            else
                kept[#kept + 1] = { x = s.x, y = s.y, d = d, dfp = dfp }
            end
        end
    end
    return kept
end

--- Cable cost: walk steps from every seat, over the pruned yard.
function Y.wireField(ctx, dist, seats)
    local dc = {}
    local order, head, tail = {}, 1, 0
    for i = 1, #seats do
        local k = key(seats[i].x, seats[i].y)
        if dc[k] == nil and dist[k] then
            dc[k] = 0
            tail = tail + 1
            order[tail] = { x = seats[i].x, y = seats[i].y }
        end
    end
    while head <= tail do
        local cur = order[head]
        head = head + 1
        local d = dc[key(cur.x, cur.y)]
        for i = 1, #ORDER do
            local v = DIRS[ORDER[i]]
            local nx, ny = cur.x + v.dx, cur.y + v.dy
            local nk = key(nx, ny)
            if dc[nk] == nil and dist[nk] then
                dc[nk] = d + 1
                tail = tail + 1
                order[tail] = { x = nx, y = ny }
            end
        end
    end
    return dc
end

--- The shapes a panel field may take, best first for each count.
--  A block reads as a deliberate installation; a line reads as a fence.
local SHAPES = {
    [2] = { { 2, 1 }, { 1, 2 } },
    [3] = { { 3, 1 }, { 1, 3 } },
    [4] = { { 2, 2 }, { 4, 1 }, { 1, 4 } },
}

--- Pick where the panels stand.
--
--  Every candidate rectangle is scored, never sorted: a running best with a
--  total order, because Kahlua's table.sort is a recursive Lua quicksort that
--  overflows on a list this size.
--- ALTERNATIVES, in scoring order.
--
--  A score is a guess about taste, and the second-best answer is often the
--  one a person would have picked. Keeping a handful lets the viewer offer
--  "show me another" instead of making the reviewer hand-place a rig the
--  planner had already thought of and ranked second.
--
--  A small insertion into a fixed-length array, never table.sort: Kahlua
--  implements sort as a recursive Lua quicksort and there are hundreds of
--  candidate rectangles on an open lot.
Y.VARIANTS = 6

local function offer(top, cand)
    for i = 1, #top do
        if cand.score > top[i].score then
            table.insert(top, i, cand)
            if #top > Y.VARIANTS then table.remove(top) end
            return
        end
    end
    if #top < Y.VARIANTS then top[#top + 1] = cand end
end

function Y.field(ctx, kept, dist, dc, seatSet, n, gap, frontDir, variant)
    if not SHAPES[n] then return nil end
    local inField = {}
    local minx, miny, maxx, maxy
    for i = 1, #kept do
        local s = kept[i]
        inField[key(s.x, s.y)] = s
        minx = math.min(minx or s.x, s.x)
        miny = math.min(miny or s.y, s.y)
        maxx = math.max(maxx or s.x, s.x)
        maxy = math.max(maxy or s.y, s.y)
    end
    if not minx then return nil end

    local top = {}
    for si = 1, #SHAPES[n] do
        local w, h = SHAPES[n][si][1], SHAPES[n][si][2]
        for fx = minx, maxx - w + 1 do
            for fy = miny, maxy - h + 1 do
                local ok, dfpMin, dcMin = true, nil, nil
                for cx = fx, fx + w - 1 do
                    for cy = fy, fy + h - 1 do
                        local k = key(cx, cy)
                        local s = inField[k]
                        if not s or seatSet[k] then ok = false break end
                        if not dfpMin or s.dfp < dfpMin then dfpMin = s.dfp end
                        local d = dc[k]
                        if d and (not dcMin or d < dcMin) then dcMin = d end
                    end
                    if not ok then break end
                end
                if ok and dfpMin and dfpMin >= gap and dcMin then
                    -- can these panels see the sun? south is +y
                    local sunOpen = 0
                    for cx = fx, fx + w - 1 do
                        local k = key(cx, fy + h)
                        if inField[k] or (not ctx.fp.set[k]
                                          and ctx.memo[k] == false) then
                            sunOpen = sunOpen + 1
                        end
                    end
                    -- something solid at its back reads as deliberate
                    local backing = 0
                    for cx = fx, fx + w - 1 do
                        for cy = fy, fy + h - 1 do
                            for i = 1, #ORDER do
                                local v = DIRS[ORDER[i]]
                                local nk = key(cx + v.dx, cy + v.dy)
                                local m = ctx.memo[nk]
                                if m == Y.R.BLOCKED or m == Y.R.FOREIGN then
                                    backing = backing + 1
                                    break
                                end
                            end
                        end
                    end
                    local fdir = Y.sideOf(ctx.b, fx, fy, w, h)
                    local score = (Y.W[WEIGHT_OF[fdir]] or 0)
                        + Y.W.sun * sunOpen
                        + Y.W.gap * math.min(dfpMin, Y.FIELD_FAR)
                        + Y.W.wire * dcMin
                        + Y.W.hug * backing
                        + Y.W.block * ((w == h) and 1 or 0)
                        + ((fdir == frontDir) and Y.W.frontDoor or 0)
                    offer(top, { x = fx, y = fy, w = w, h = h,
                                 dir = fdir, score = score, dfp = dfpMin,
                                 dc = dcMin, sun = sunOpen })
                end
            end
        end
    end
    local pick = top[((variant or 0) % math.max(1, #top)) + 1]
    if pick then pick.alternatives = #top end
    return pick
end

--- Which side of the house a rectangle sits on.
function Y.sideOf(b, x, y, w, h)
    local cx = x * 2 + w - 1
    local cy = y * 2 + h - 1
    local bx1, bx2 = b.x * 2, (b.x + b.w) * 2
    local by1, by2 = b.y * 2, (b.y + b.h) * 2
    if cy < by1 then return "N" end
    if cy > by2 then return "S" end
    if cx < bx1 then return "W" end
    if cx > bx2 then return "E" end
    return (cy - by1 < by2 - cy) and "N" or "S"
end

--- Walk the cable back from the field to the wall it will be served from.
--
--  Follow the cable-distance gradient downhill: every step lands on a square
--  one closer to a seat, so after dc steps the walk is standing on one. The
--  squares it crossed are the visible cable run.
function Y.walkBack(ctx, dist, dc, fx, fy, fw, fh)
    local sx, sy, sd = nil, nil, nil
    for cx = fx, fx + fw - 1 do
        for cy = fy, fy + fh - 1 do
            local d = dc[key(cx, cy)]
            if d and (not sd or d < sd
                      or (d == sd and (cx < sx or (cx == sx and cy < sy)))) then
                sx, sy, sd = cx, cy, d
            end
        end
    end
    if not sx then return nil end
    local route = {}
    local cx, cy, d = sx, sy, sd
    local guard = 0
    while d and d > 0 and guard < 64 do
        guard = guard + 1
        local moved = false
        for i = 1, #ORDER do
            local v = DIRS[ORDER[i]]
            local nk = key(cx + v.dx, cy + v.dy)
            if dc[nk] == d - 1 then
                cx, cy, d = cx + v.dx, cy + v.dy, d - 1
                route[#route + 1] = { x = cx, y = cy }
                moved = true
                break
            end
        end
        if not moved then return nil end
    end
    return cx, cy, route
end

--- Assemble a two-mass plan: panels out in the yard, controller and racks on
--  the wall the cable walks back to.
function Y.layoutField(ctx, sides, arrays, banks, gap, variant)
    local seats, runs = Y.seats(ctx, sides)
    if #seats == 0 then return nil, Y.R.NOWALL end
    local roomy = false
    for i = 1, #runs do
        if #runs[i].seats >= banks + 1 then roomy = true break end
    end
    if not roomy then return nil, Y.R.NOWALL end

    local seatSet = {}
    for i = 1, #seats do seatSet[key(seats[i].x, seats[i].y)] = true end

    local dist, order, foreign = Y.flood(ctx, seats)
    local kept = Y.halfway(ctx, dist, order, foreign)
    if #kept == 0 then return nil, Y.R.NOFIELD end
    local dc = Y.wireField(ctx, dist, seats)

    -- which way is the front of the house?
    local frontDir, frontDoors = nil, 0
    for _, s in ipairs(sides) do
        if s.door and s.door > frontDoors then
            frontDoors = s.door
            frontDir = s.dir
        end
    end

    local rect = Y.field(ctx, kept, dist, dc, seatSet, arrays, gap, frontDir,
                         variant)
    if not rect then return nil, Y.R.NOFIELD end

    local cx, cy, route = Y.walkBack(ctx, dist, dc, rect.x, rect.y,
                                     rect.w, rect.h)
    if not cx then return nil, Y.R.NOFIELD end

    -- the run this seat belongs to, and room for the racks beside it
    local run = nil
    for i = 1, #seats do
        if seats[i].x == cx and seats[i].y == cy then run = seats[i].run break end
    end
    if not run or #run.seats < banks + 1 then return nil, Y.R.NOWALL end
    local idx = nil
    for i = 1, #run.seats do
        if run.seats[i].x == cx and run.seats[i].y == cy then idx = i break end
    end
    if not idx then return nil, Y.R.NOWALL end
    -- racks step away from the field along the wall; flip if there is no room
    local step = (idx > banks) and -1 or 1
    if step == -1 and idx - banks < 1 then step = 1 end
    if step == 1 and idx + banks > #run.seats then step = -1 end
    if idx + step * banks < 1 or idx + step * banks > #run.seats then
        return nil, Y.R.NOWALL
    end

    local plan = { dir = run.dir, depth = 1, shape = "field",
                   arrays = {}, banks = {}, route = route,
                   fieldRect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h },
                   fieldDir = rect.dir, score = rect.score,
                   variant = variant or 0, alternatives = rect.alternatives or 1 }
    plan.controller = { x = cx, y = cy, facing = run.dir }
    for i = 1, banks do
        local q = run.seats[idx + step * i]
        plan.banks[#plan.banks + 1] = { x = q.x, y = q.y, facing = run.dir }
    end
    -- One facing for the whole block: that is what makes it read as a block.
    local face = (rect.sun > 0) and "S" or rect.dir
    if face == "N" then face = "S" end
    for cx2 = rect.x, rect.x + rect.w - 1 do
        for cy2 = rect.y, rect.y + rect.h - 1 do
            plan.arrays[#plan.arrays + 1] = { x = cx2, y = cy2, facing = face }
        end
    end

    -- the cable has to reach: EUCLIDEAN, as the engine measures it
    local nearest = nil
    for i = 1, #plan.arrays do
        local dx = plan.arrays[i].x - cx
        local dy = plan.arrays[i].y - cy
        local d2 = dx * dx + dy * dy
        if not nearest or d2 < nearest then nearest = d2 end
    end
    if nearest and nearest > Y.LINK * Y.LINK then return nil, Y.R.NOFIELD end
    return plan
end

------------------------------------------------------------------- the plan

--- Plan one house's rig, or decide it has nowhere to put one.
--
--  b    { x, y, w, h, z, id, rooms = { { x, y, w, h, level, name }, ... } }
--  env  { getSquare(x,y,z), owner(x,y,z), claimed(x,y,z) }
--       owner and claimed are optional. owner is the engine's own arbiter of
--       which building a square belongs to, and is what stops house A's rig
--       reaching into house B's garden.
--  want { arrays = n, banks = m }  -- both clamped to their MIN/MAX
--
--  Returns plan, reasons -- or nil, reasons when no complete rig fits. The
--  plan carries one `controller`, a list of `banks` and a list of `arrays`,
--  and `squares` holding all of them for the caller to claim.
function Y.plan(b, env, want)
    local reasons = {}
    if not b or not env or not env.getSquare then return nil, reasons end

    local function clamp(v, lo, hi)
        return math.max(lo, math.min(hi, v or hi))
    end
    local wantA = clamp(want and want.arrays, Y.MIN_ARRAYS, Y.MAX_ARRAYS)
    local wantB = clamp(want and want.banks, Y.MIN_BANKS, Y.MAX_BANKS)

    local fp = Y.footprint(b, env)
    if fp.n == 0 then return nil, reasons end
    local aprons = Y.aprons(b, fp, Y.faces(fp), env)
    local memo0 = {}
    local sides = Y.sides(b, fp, aprons, env, reasons, memo0)

    -- Best side first, and a full row before a short one: three panels on the
    -- south wall beats two on the south wall, which beats three on the east.
    --
    -- Panels before racks when the room runs short: four panels and one rack
    -- still reads as a household's rig, where two panels and two racks reads
    -- as a junk pile. A house with no side long enough for the smallest
    -- complete rig gets none.
    --
    -- Every side is tried. An earlier cut broke out as soon as a side's own
    -- score fell below a plan already found, which is not a sound bound --
    -- the layout score also carries the length of the run, so a lower-scoring
    -- side with a much longer wall can still win.
    -- THE LADDER. A two-mass rig first, at the stand-off Can asked for, then
    -- at progressively less; a single row against the wall only when no field
    -- fits at all. The rungs are not compared against each other -- a field
    -- score and a row score are not on one scale -- so this is a fallback,
    -- never a competition, and the houses that fall to the last rung
    -- reproduce exactly what they produced before.
    local ctx = { b = b, fp = fp, aprons = aprons, env = env, z = z,
                  memo = {}, spent = 0 }
    for k, v in pairs(memo0) do ctx.memo[k] = v end

    local best, lastWhy = nil, nil
    for _, gap in ipairs({ Y.FIELD_GAP, 2, 1 }) do
        for na = wantA, Y.MIN_ARRAYS, -1 do
            for nb = wantB, Y.MIN_BANKS, -1 do
                local p, why = Y.layoutField(ctx, sides, na, nb, gap,
                                             want and want.variant)
                if p then best = p break end
                lastWhy = why or lastWhy
            end
            if best then break end
        end
        if best then break end
    end

    if not best then
        if lastWhy then reasons[lastWhy] = (reasons[lastWhy] or 0) + 1 end
        for i = 1, #sides do
            local p = nil
            for na = wantA, Y.MIN_ARRAYS, -1 do
                for nb = wantB, Y.MIN_BANKS, -1 do
                    p = Y.layoutRow(sides[i], na, nb)
                    if p then break end
                end
                if p then break end
            end
            if p and (not best or p.score > best.score) then
                p.shape = "row"
                best = p
            end
        end
    end

    if not best then
        reasons[Y.R.NOROOM] = (reasons[Y.R.NOROOM] or 0) + 1
        return nil, reasons
    end

    local z = b.z or 0
    best.z = z
    best.controller.z = z
    best.squares = { best.controller }
    for i = 1, #best.banks do
        best.banks[i].z = z
        best.squares[#best.squares + 1] = best.banks[i]
    end
    for i = 1, #best.arrays do
        best.arrays[i].z = z
        best.squares[#best.squares + 1] = best.arrays[i]
    end
    best.complete = true
    best.shape = best.shape or "row"
    return best, reasons
end

return Y

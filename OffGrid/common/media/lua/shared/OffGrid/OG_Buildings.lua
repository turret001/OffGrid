--[[ OffGrid -- which squares a building is.

     The Building Picker hands this file a clicked square, and Wire up the
     building hands it where a part stands. It answers with a TARGET: a map
     building or a player-built structure, and the footprint that goes with it.
     A backup generator asks it one smaller question about the square it
     stands on: is that square indoors (B.enclosedAt)?

     MAP BUILDINGS are the predefined BuildingDefs of the metagrid, which every
     side has: their rooms are LISTS of rects on a level (RoomDef.getRects,
     RoomDef.getZ -- there is no getLevel), and a procedural basement is its
     own BuildingDef under the house, never merged into it (skill:
     basements.md 6.1). Wiring a house wires its basement.

     PLAYER-BUILT STRUCTURES cannot be read the same way, for two reasons the
     engine gives:

       * a dedicated server never turns player-built rooms into buildings:
         IsoRegions.update calls clientProcessBuildings only when
         !GameServer.server (IsoRegions.java:212);
       * a structure standing against a map building never becomes one
         anywhere: isAdjacentToOrOverlappingAPredefinedBuilding discards it
         (WorldRegionToMetaGrid.java:100). That is exactly a player's
         extension of an existing house.

     What every side DOES have is the region data those buildings are made
     from: IsoWorldRegions -- connected floor areas bounded by walls, with an
     enclosed flag and a roofed share -- which the server computes and saves
     and sends to clients. A structure here is the enclosed, at-least-half-
     roofed regions reached from the clicked square (the same test the engine
     uses to make a user-defined building), through neighbours and up and down
     stacked floors. It never includes a square of a map room: the flood stops
     at a map building, and a room knocked through into one brings only its
     new squares. So a player-built extension is its own pick, and never part
     of the house's default.

     Engine calls go through `try`, the same guarded call OG_Parts.try is: a
     missing method or an engine error answers nil instead of throwing.
]]

require "OffGrid/OG_Reach"

OffGrid = OffGrid or {}
OffGrid.Buildings = OffGrid.Buildings or {}
local B = OffGrid.Buildings
local R = OffGrid.Reach

local floor = math.floor

local function try(obj, method, ...)
    if not obj or not obj[method] then return nil end
    local ok, v = pcall(obj[method], obj, ...)
    if ok then return v end
    return nil
end

-- The engine's own threshold for a region to count as a room of a building
-- (WorldRegionToMetaGrid.java:184, 246, 358).
B.ROOFED = 0.5

local function metaGrid()
    local w = getWorld and getWorld()
    return w and try(w, "getMetaGrid")
end

local function each(list, fn)
    local n = list and list.size and list:size() or 0
    for i = 0, n - 1 do fn(list:get(i)) end
end

---------------------------------------------------------------- map buildings

--- The predefined room at a square, or nil. A user-defined room (a player's
--  building, turned into one on a client) is never a map room.
function B.predefinedRoomAt(x, y, z)
    local mg = metaGrid()
    if not mg then return nil end
    local rd = try(mg, "getRoomAt", x, y, z)
    if not rd or try(rd, "isUserDefined") then return nil end
    local def = try(rd, "getBuilding")
    if def and try(def, "isUserDefined") then return nil end
    return rd
end

function B.defAt(x, y, z)
    local rd = B.predefinedRoomAt(x, y, z)
    return rd and try(rd, "getBuilding") or nil
end

--- A def's rooms as plain rects: { x, y, w, h, z }.
local function rectsOfDef(def)
    local out = {}
    each(try(def, "getRooms"), function(rd)
        local z = try(rd, "getZ") or 0
        each(try(rd, "getRects"), function(q)
            local x, y = try(q, "getX"), try(q, "getY")
            local w, h = try(q, "getW"), try(q, "getH")
            if x and y and w and h and w > 0 and h > 0 then
                out[#out + 1] = { x = x, y = y, w = w, h = h, z = z }
            end
        end)
    end)
    return out
end

local function isBasement(def)
    if try(def, "isBasement") == true then return true end
    local hi = try(def, "getMaxLevel")
    return hi ~= nil and hi < 0
end

--- The key the seeder has always used for a building (OG_Seed.key): the
--  lowest ground-floor rect origin plus the ground-floor area, which no two
--  of the map's 9,108 buildings share. A def with no ground floor (a
--  basement) is keyed on its lowest level instead. Returns the key and the
--  square it names, which is inside the building and serves as its seed.
function B.defKey(def)
    local rects = rectsOfDef(def)
    local level = nil
    for i = 1, #rects do
        if rects[i].z == 0 then level = 0 break end
        if level == nil or rects[i].z < level then level = rects[i].z end
    end
    local bx, by, area = nil, nil, 0
    for i = 1, #rects do
        local r = rects[i]
        if r.z == level then
            area = area + r.w * r.h
            if not bx or r.x < bx or (r.x == bx and r.y < by) then bx, by = r.x, r.y end
        end
    end
    if not bx then
        local x, y = try(def, "getX") or 0, try(def, "getY") or 0
        return x .. "," .. y, x, y, 0
    end
    return bx .. "," .. by .. ":" .. area, bx, by, level
end

--- The map buildings whose bounding boxes meet a rectangle.
local function defsIn(x, y, w, h)
    local out = {}
    local mg = metaGrid()
    if not mg or not ArrayList then return out end
    local list = ArrayList.new()
    try(mg, "getBuildingsIntersecting", x, y, w, h, list)
    each(list, function(def)
        if def and not try(def, "isUserDefined") then out[#out + 1] = def end
    end)
    return out
end

--- The house a basement sits under, or nil.
local function houseAbove(cellar)
    local under = {}
    local rs = rectsOfDef(cellar)
    for i = 1, #rs do
        local r = rs[i]
        for x = r.x, r.x + r.w - 1 do
            for y = r.y, r.y + r.h - 1 do under[R.sqKey(x, y)] = true end
        end
    end
    local bx, by = try(cellar, "getX") or 0, try(cellar, "getY") or 0
    local bw, bh = try(cellar, "getW") or 1, try(cellar, "getH") or 1
    local cands = defsIn(bx - 1, by - 1, bw + 2, bh + 2)
    for i = 1, #cands do
        local d = cands[i]
        if d ~= cellar and not isBasement(d) then
            local hr = rectsOfDef(d)
            for j = 1, #hr do
                local r = hr[j]
                for x = r.x, r.x + r.w - 1 do
                    for y = r.y, r.y + r.h - 1 do
                        if under[R.sqKey(x, y)] then return d end
                    end
                end
            end
        end
    end
    return nil
end

--- A basement answers for the house above it, when there is one.
local function building(def)
    if def and isBasement(def) then return houseAbove(def) or def end
    return def
end

--- Every square of a map building: every room rect on every level, the
--  basements under it, and the wall shell on the south and east sides, which
--  in this engine sits one square OUTSIDE the rects (a wall belongs to the
--  north or west edge of the square it stands on; see the seeding study).
function B.defFootprint(def)
    local fp = R.fpNew()
    local function addRects(rs)
        for i = 1, #rs do
            local r = rs[i]
            for x = r.x, r.x + r.w - 1 do
                for y = r.y, r.y + r.h - 1 do R.fpAdd(fp, x, y, r.z) end
            end
        end
    end
    addRects(rectsOfDef(def))

    if not isBasement(def) then
        local xy = {}
        for _, set in pairs(fp.levels) do
            for k in pairs(set) do xy[k] = true end
        end
        local bx, by = try(def, "getX") or 0, try(def, "getY") or 0
        local bw, bh = try(def, "getW") or 1, try(def, "getH") or 1
        local cands = defsIn(bx - 1, by - 1, bw + 2, bh + 2)
        for i = 1, #cands do
            local d = cands[i]
            if d ~= def and isBasement(d) then
                local rs = rectsOfDef(d)
                local under = false
                for j = 1, #rs do
                    local r = rs[j]
                    for x = r.x, r.x + r.w - 1 do
                        for y = r.y, r.y + r.h - 1 do
                            if xy[R.sqKey(x, y)] then under = true end
                        end
                    end
                end
                if under then addRects(rs) end
            end
        end
    end

    local shell = {}
    for z, set in pairs(fp.levels) do
        for k in pairs(set) do
            local x, y = R.sqXY(k)
            if not set[R.sqKey(x + 1, y)] then shell[#shell + 1] = { x + 1, y, z } end
            if not set[R.sqKey(x, y + 1)] then shell[#shell + 1] = { x, y + 1, z } end
        end
    end
    for i = 1, #shell do R.fpAdd(fp, shell[i][1], shell[i][2], shell[i][3]) end
    return fp
end

--- The nearest map building with a room square inside a part's reach: within
--  r of it and on a level its band lights. Returns the def and the squared
--  distance, or nil.
function B.nearestDef(px, py, pz, r, v)
    local lo, hi = R.band(pz, v)
    local best, bestD, bestKey = nil, nil, nil
    local cands = defsIn(px - r, py - r, 2 * r + 1, 2 * r + 1)
    for i = 1, #cands do
        local def = cands[i]
        local rs = rectsOfDef(def)
        local d = nil
        for j = 1, #rs do
            local q = rs[j]
            if q.z >= lo and q.z <= hi then
                local cx = math.max(q.x, math.min(px, q.x + q.w - 1))
                local cy = math.max(q.y, math.min(py, q.y + q.h - 1))
                local dd = (cx - px) * (cx - px) + (cy - py) * (cy - py)
                if dd <= r * r and (d == nil or dd < d) then d = dd end
            end
        end
        if d then
            local key = B.defKey(def)
            if bestD == nil or d < bestD or (d == bestD and key < bestKey) then
                best, bestD, bestKey = def, d, key
            end
        end
    end
    return best, bestD
end

------------------------------------------------------ player-built structures

--- The region map covers levels 0 to 31 only: its DataChunk holds one layer per
--  level and indexes it by z, so asking about a basement level throws
--  (ArrayIndexOutOfBoundsException, DataChunk.getSquare). A pcall catches that,
--  but the engine still counts and logs every one with its stack trace, and the
--  flood below asks about the level under every ground-floor square. Seen live,
--  2026-09-24: 83 logged errors from a handful of look-ups at one small room.
local function regionAt(x, y, z)
    if z < 0 or z > 31 then return nil end
    if not IsoRegions or not IsoRegions.getIsoWorldRegion then return nil end
    local ok, wr = pcall(IsoRegions.getIsoWorldRegion, x, y, z)
    if ok then return wr end
    return nil
end

--- Does a region count as a room of a building? The engine's own test for a
--  user-defined building: enclosed, and at least half roofed.
local function qualifies(wr)
    if not try(wr, "isEnclosed") then return false end
    local roofed = try(wr, "getRoofedPercentage") or 0
    return roofed >= B.ROOFED
end

--- Is a square indoors? A backup generator will not run there (OG_Backup).
--  Indoors is a map room, or a region that passes the building test above:
--  walled in AND at least half roofed. So a walled yard with no roof is
--  outdoors, and so is a carport, roofed but open at the sides. getBuilding()
--  is not asked: a dedicated server never makes a player's rooms into
--  buildings, and every side must give the same answer. One metagrid look-up
--  and one region look-up, no flood: cheap enough for every tick a unit runs.
function B.enclosedAt(x, y, z)
    return B.predefinedRoomAt(x, y, z) ~= nil or qualifies(regionAt(x, y, z))
end

--- The player-built structure at a square: its footprint, or nil and why.
--    "map"  the square is in a map room (pick the building instead)
--    "none" there is no region data here
--    "open" the region is not enclosed, or not half roofed
--    "big"  the structure is larger than R.MAX_STRUCTURE squares
function B.structureAt(x, y, z)
    if B.predefinedRoomAt(x, y, z) then return nil, "map" end
    local first = regionAt(x, y, z)
    if not first then return nil, "none" end
    if not qualifies(first) then return nil, "open" end

    local fp = R.fpNew()
    local seen = { [first] = true }
    local queue = { first }
    local head = 1
    while head <= #queue do
        local wr = queue[head]
        head = head + 1
        local touchesMap = false
        local crs = try(wr, "getDebugIsoChunkRegionCopy")
        local n = crs and crs.size and crs:size() or 0
        for i = 0, n - 1 do
            local cr = crs:get(i)
            local dc = try(cr, "getDataChunk")
            local cz = try(cr, "getzLayer")
            if dc and cz then
                local ox, oy = (try(dc, "getChunkX") or 0) * 8, (try(dc, "getChunkY") or 0) * 8
                for lx = 0, 7 do
                    for ly = 0, 7 do
                        local flags = try(dc, "getSquare", lx, ly, cz) or 0
                        if flags > 0 and try(dc, "getIsoChunkRegion", lx, ly, cz) == cr then
                            local sx, sy = ox + lx, oy + ly
                            if B.predefinedRoomAt(sx, sy, cz) then
                                touchesMap = true
                            elseif R.fpAdd(fp, sx, sy, cz) then
                                if fp.count > R.MAX_STRUCTURE then return nil, "big" end
                                -- Up and down: a player's second storey is a
                                -- region of its own on the level above.
                                for dz = -1, 1, 2 do
                                    local st = regionAt(sx, sy, cz + dz)
                                    if st and not seen[st] and qualifies(st) then
                                        seen[st] = true
                                        queue[#queue + 1] = st
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        -- A region that holds any map-room square belongs, at least in part,
        -- to a map building: its own new squares are taken, but the flood
        -- does not run on through it into the rest of the house, or out the
        -- other side into somebody else's extension.
        if not touchesMap then
            each(try(wr, "getNeighbors"), function(nb)
                if nb and not seen[nb] and qualifies(nb) then
                    seen[nb] = true
                    queue[#queue + 1] = nb
                end
            end)
        end
    end
    if fp.count == 0 then return nil, "map" end
    return fp
end

--------------------------------------------------------------------- targets

local function buildingTarget(def)
    local id, sx, sy, sz = B.defKey(def)
    return { k = "b", x = sx, y = sy, z = sz, id = id, def = def }
end

local function structureTarget(fp)
    local x0, y0, _, _, z0 = R.fpBounds(fp)
    local rects = R.rectsOf(fp)
    local seed = rects[1]
    return { k = "s", x = seed.x, y = seed.y, z = seed.z,
             id = x0 .. "," .. y0 .. "," .. z0 .. ":" .. fp.count, fp = fp }
end

--- What a click on x, y, z picks: the map building whose room it is, else the
--  player-built structure it stands in, else the map building whose wall row
--  it is (the south and east walls stand outside the rects). Returns the
--  target, or nil and why.
function B.targetAt(x, y, z)
    local def = B.defAt(x, y, z)
    if def then return buildingTarget(building(def)) end
    local fp, why = B.structureAt(x, y, z)
    if fp then return structureTarget(fp) end
    local ns = { { 0, -1 }, { -1, 0 }, { 0, 1 }, { 1, 0 } }
    for i = 1, #ns do
        local d = B.defAt(x + ns[i][1], y + ns[i][2], z)
        if d then return buildingTarget(building(d)) end
    end
    return nil, why
end

--- What Wire up the building means for a part standing at px, py, pz with
--  reach r and band v: the map building it stands in; else the nearest map
--  building it reaches; else the player-built structure it stands in. A
--  structure against a map building is never the default -- Can's rule; it
--  is the Building Picker's to add.
function B.defaultTarget(px, py, pz, r, v)
    local def = B.defAt(px, py, pz)
    if def then return buildingTarget(building(def)) end
    local near = B.nearestDef(px, py, pz, r, v)
    if near then return buildingTarget(building(near)) end
    local fp = B.structureAt(px, py, pz)
    if fp then return structureTarget(fp) end
    return nil, "none"
end

--- Re-read a stored target from its seed square.
function B.resolve(k, x, y, z)
    if k == "b" then
        local def = B.defAt(x, y, z)
        if not def then return nil, "gone" end
        return buildingTarget(building(def))
    elseif k == "s" then
        local fp, why = B.structureAt(x, y, z)
        if not fp then return nil, why end
        return structureTarget(fp)
    end
    return nil, "gone"
end

--- A target's footprint.
function B.footprintOf(t)
    if not t then return nil end
    if t.fp then return t.fp end
    if t.def then
        t.fp = B.defFootprint(t.def)
        return t.fp
    end
    return nil
end

--- Does a part at px, py, pz reach any square of a footprint?
function B.reaches(fp, px, py, pz, r, v)
    if not fp then return false end
    local lo, hi = R.band(pz, v)
    local r2 = r * r
    for z, set in pairs(fp.levels) do
        if z >= lo and z <= hi then
            for k in pairs(set) do
                local x, y = R.sqXY(k)
                local dx, dy = x - px, y - py
                if dx * dx + dy * dy <= r2 then return true end
            end
        end
    end
    return false
end

------------------------------------------------------------------ the codec

--  A part's targets live in its ModData as one STRING (table fields are
--  dropped when a part is picked up or rotated; see OG_Reach):
--      "b@104,103,0@100,100:88;s@103,111,0@100,109,0:42"
--  kind @ seed square @ id.

function B.encodeTargets(list)
    local bits = {}
    for i = 1, #(list or {}) do
        local t = list[i]
        bits[#bits + 1] = t.k .. "@" .. t.x .. "," .. t.y .. "," .. t.z .. "@" .. t.id
    end
    return table.concat(bits, ";")
end

function B.decodeTargets(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for part in string.gmatch(str, "[^;]+") do
        local k, x, y, z, id = string.match(part, "^([bs])@(-?%d+),(-?%d+),(-?%d+)@([%d,:%-]+)$")
        if k then
            out[#out + 1] = { k = k, x = tonumber(x), y = tonumber(y), z = tonumber(z), id = id }
        end
    end
    return out
end

return B

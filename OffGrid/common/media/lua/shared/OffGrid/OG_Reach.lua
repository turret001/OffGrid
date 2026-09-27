--[[ OffGrid -- where the extra power goes: the arithmetic of reach.

     Pure. Numbers and tables in, numbers and tables out, no engine calls, so
     every rule here is asserted headlessly (tests/test_reach.py) and again
     inside the game's own Kahlua VM (tests/test_kahlua.py).

     THE ONE ENGINE FACT EVERYTHING HERE RESTS ON. A square has generator
     power when its OWN chunk lists a generator position that reaches it:
     IsoGridSquare.haveElectricity asks chunk.isGeneratorPoweringSquare, which
     walks that chunk's generatorsTouchingThisChunk and applies
     IsoGenerator.isPoweringSquare -- centre distance squared at most
     GeneratorTileRange squared, level within GeneratorVerticalPowerRange of
     the registered level. Nothing on that path looks for an object at the
     position. So a REGISTRATION is a position and a chunk, and it lights the
     squares of that chunk within reach of that position.

     Two shapes are built out of registrations:

       * a CIRCLE: one position registered on every chunk its bounding box
         touches (IsoGenerator.touchesChunk). This is exactly what a real
         generator does, so a transformer lights exactly a generator's circle.
       * a RELAY: one position registered on its OWN chunk only. At the
         default range of 20 it lights its whole chunk, because the furthest
         two squares of an 8x8 chunk are 9.9 apart. A wired building is lit
         by one relay per chunk it occupies and per vertical band it needs.

     A relay always stands on a footprint square, never on thin air. The
     engine's missing-generator purge (IsoChunk.checkForMissingGenerators)
     keeps an entry whose square does not exist, saves it into the chunk file
     and lights the ground with it for ever; an entry on a real square is
     purged at the next load once nothing re-adds it, which is what lets the
     mod be removed cleanly.

     The billing sweep walks the same shapes. A square two shapes share is
     owned, and billed, by the first of them (R.owner), so one system never
     counts an appliance twice.
]]

OffGrid = OffGrid or {}
OffGrid.Reach = OffGrid.Reach or {}
local R = OffGrid.Reach

local floor, sqrt = math.floor, math.sqrt

R.CHUNK = 8
R.ZMIN, R.ZMAX = -32, 31
-- The most squares one player-built structure may bring in, and the most a
-- whole system may wire. The first stops a flood through a fenced pasture
-- from wiring a field; the second keeps a sweep and a registry bounded.
R.MAX_STRUCTURE = 4096
R.MAX_WIRED = 60000

-- A square key is one number, not a string: a big building is thousands of
-- squares and a string each would be thousands of allocations per plan. Map
-- coordinates are never negative, and 100000 is above any of them.
local SQ = 100000

------------------------------------------------------------------ basics

function R.chunkOf(x, y)
    return floor(x / 8), floor(y / 8)
end

function R.chunkKey(kx, ky)
    return kx .. "," .. ky
end

function R.sqKey(x, y)
    return x * SQ + y
end

function R.sqXY(k)
    local x = floor(k / SQ)
    return x, k - x * SQ
end

--- The levels a registration at level z lights, clamped to the engine's own
--  limits (IsoGenerator.getMinAffectedLevel / getMaxAffectedLevel).
function R.band(z, v)
    local lo, hi = z - v, z + v
    if lo < R.ZMIN then lo = R.ZMIN end
    if hi > R.ZMAX then hi = R.ZMAX end
    return lo, hi
end

--- Every chunk a circle registers on: the engine's touchesChunk, which is a
--  bounding-box test, so the answer is the chunks the box spans. Ordered by
--  kx, then ky, so every side builds the same list.
function R.circleChunks(x, y, r)
    local out = {}
    for kx = floor((x - r) / 8), floor((x + r) / 8) do
        for ky = floor((y - r) / 8), floor((y + r) / 8) do
            out[#out + 1] = { kx = kx, ky = ky }
        end
    end
    return out
end

--- A stable merge sort. Kahlua's table.sort is a recursive quicksort that
--  overflows the stack on a few thousand entries, and a footprint can hold
--  that many.
function R.sort(list, less)
    local n = #list
    if n < 2 then return list end
    local src, dst = list, {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + 2 * width, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if less(src[b], src[a]) then
                    dst[k] = src[b]; b = b + 1
                else
                    dst[k] = src[a]; a = a + 1
                end
                k = k + 1
            end
            while a < mid do dst[k] = src[a]; a = a + 1; k = k + 1 end
            while b < hi do dst[k] = src[b]; b = b + 1; k = k + 1 end
            i = i + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= list then
        for i = 1, n do list[i] = src[i] end
    end
    return list
end

--------------------------------------------------------------- footprints

--- A footprint: the squares of a target, by level.
--    { levels = { [z] = { [sqKey] = true } }, count = n }
function R.fpNew()
    return { levels = {}, count = 0 }
end

function R.fpAdd(fp, x, y, z)
    local set = fp.levels[z]
    if not set then
        set = {}
        fp.levels[z] = set
    end
    local k = x * SQ + y
    if set[k] then return false end
    set[k] = true
    fp.count = fp.count + 1
    return true
end

function R.fpHas(fp, x, y, z)
    local set = fp and fp.levels[z]
    return set ~= nil and set[x * SQ + y] == true
end

function R.fpCount(fp)
    return fp and fp.count or 0
end

function R.fpMerge(into, other)
    for z, set in pairs(other.levels) do
        for k in pairs(set) do
            local x, y = R.sqXY(k)
            R.fpAdd(into, x, y, z)
        end
    end
    return into
end

function R.fpLevels(fp)
    local out = {}
    for z in pairs(fp.levels) do out[#out + 1] = z end
    return R.sort(out, function(a, b) return a < b end)
end

--- Bounds over every level: x0, y0, x1, y1, z0, z1, or nil when empty.
function R.fpBounds(fp)
    local x0, y0, x1, y1, z0, z1
    for z, set in pairs(fp.levels) do
        for k in pairs(set) do
            local x, y = R.sqXY(k)
            if not x0 then
                x0, y0, x1, y1, z0, z1 = x, y, x, y, z, z
            else
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
                if z < z0 then z0 = z end
                if z > z1 then z1 = z end
            end
        end
    end
    return x0, y0, x1, y1, z0, z1
end

--- One level's bounds, or nil.
local function levelBounds(set)
    local x0, y0, x1, y1
    for k in pairs(set) do
        local x, y = R.sqXY(k)
        if not x0 then
            x0, y0, x1, y1 = x, y, x, y
        else
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
    end
    return x0, y0, x1, y1
end

--- A footprint as rectangles: runs along each row, merged down the rows while
--  they line up exactly. Deterministic -- rects come out by level, then by
--  the row and column they start on -- so the same footprint always encodes
--  to the same string, on every side.
function R.rectsOf(fp)
    local out = {}
    local levels = R.fpLevels(fp)
    for li = 1, #levels do
        local z = levels[li]
        local set = fp.levels[z]
        local x0, y0, x1, y1 = levelBounds(set)
        if x0 then
            local open = {}
            for y = y0, y1 do
                local nextOpen = {}
                local x = x0
                while x <= x1 do
                    if set[x * SQ + y] then
                        local a = x
                        while x + 1 <= x1 and set[(x + 1) * SQ + y] do x = x + 1 end
                        local runKey = a * SQ + x
                        local rect = open[runKey]
                        if rect then
                            rect.h = rect.h + 1
                        else
                            rect = { x = a, y = y, w = x - a + 1, h = 1, z = z }
                            out[#out + 1] = rect
                        end
                        nextOpen[runKey] = rect
                    end
                    x = x + 1
                end
                open = nextOpen
            end
        end
    end
    return out
end

function R.fpOfRects(rects, into)
    local fp = into or R.fpNew()
    for i = 1, #(rects or {}) do
        local r = rects[i]
        for x = r.x, r.x + r.w - 1 do
            for y = r.y, r.y + r.h - 1 do
                R.fpAdd(fp, x, y, r.z)
            end
        end
    end
    return fp
end

------------------------------------------------------------------- codecs

--  Strings, not tables, wherever these are kept on a part. An IsoObject's
--  ModData is copied onto the item when it is picked up, and that copy drops
--  every table-valued field (OG_Place); a string survives, and survives the
--  rotate path that rebuilds the object too.

local SEP = ";"

function R.encodeRects(rects)
    local bits = {}
    for i = 1, #(rects or {}) do
        local r = rects[i]
        bits[#bits + 1] = r.x .. "," .. r.y .. "," .. r.w .. "," .. r.h .. "," .. r.z
    end
    return table.concat(bits, SEP)
end

--- Save data is untrusted input: anything malformed is dropped, never fatal.
function R.decodeRects(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for part in string.gmatch(str, "[^" .. SEP .. "]+") do
        local x, y, w, h, z = string.match(part, "^(-?%d+),(-?%d+),(%d+),(%d+),(-?%d+)$")
        if x then
            w, h = tonumber(w), tonumber(h)
            if w >= 1 and h >= 1 and w <= 2000 and h <= 2000 then
                out[#out + 1] = { x = tonumber(x), y = tonumber(y), w = w, h = h, z = tonumber(z) }
            end
        end
    end
    return out
end

function R.encodePositions(list)
    local bits = {}
    for i = 1, #(list or {}) do
        local p = list[i]
        bits[#bits + 1] = p.x .. "," .. p.y .. "," .. p.z
    end
    return table.concat(bits, SEP)
end

function R.decodePositions(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for part in string.gmatch(str, "[^" .. SEP .. "]+") do
        local x, y, z = string.match(part, "^(-?%d+),(-?%d+),(-?%d+)$")
        if x then
            out[#out + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        end
    end
    return out
end

----------------------------------------------------------------- planning

--- Does a registration at p reach square t? Centre distance and band, the
--  engine's own test; the chunk half is implied, because a relay is only ever
--  asked about squares of its own chunk.
local function reaches(p, t, r2, v)
    local dz = t.z - p.z
    if dz < -v or dz > v then return false end
    local dx, dy = t.x - p.x, t.y - p.y
    return dx * dx + dy * dy <= r2
end

-- Registration checks one plan may spend choosing the best host for each
-- relay. Past it, each relay goes on the first host that reaches the next dark
-- square: more relays, but the plan still covers everything it can and the
-- server never stalls on it. Only a tiny range and a huge building get there.
R.PLAN_WORK = 400000

--- Cover `targets` from `cands`. The first target still dark gets a relay,
--  on the host that reaches it and reaches the most other dark targets, so
--  every relay pays for itself and the search only looks at hosts that can
--  light that one square (a handful at a small range, not the whole chunk).
--  Appends to `relays`; returns the targets nothing reaches.
--  `work` is { n = checks so far }, shared by the whole plan.
local function cover(targets, cands, r2, v, relays, work)
    local remaining, dark = targets, {}
    while #remaining > 0 do
        local t = remaining[1]
        local best, bestN = nil, -1
        local cheap = work.n > R.PLAN_WORK
        for i = 1, #cands do
            local c = cands[i]
            if reaches(c, t, r2, v) then
                if cheap then
                    best = c
                    break
                end
                local n = 0
                for j = 2, #remaining do
                    if reaches(c, remaining[j], r2, v) then n = n + 1 end
                end
                work.n = work.n + #remaining
                if n > bestN then best, bestN = c, n end
            end
        end
        work.n = work.n + #cands
        local left = {}
        if best then
            relays[#relays + 1] = { x = best.x, y = best.y, z = best.z }
            for j = 2, #remaining do
                if not reaches(best, remaining[j], r2, v) then left[#left + 1] = remaining[j] end
            end
            work.n = work.n + #remaining
        else
            -- Nothing here reaches it: it stays dark, and the rest go on.
            dark[#dark + 1] = t
            for j = 2, #remaining do left[#left + 1] = remaining[j] end
        end
        remaining = left
    end
    return dark
end

--- Where the relays go for one footprint.
--
--  Per chunk, the footprint's levels are cut into vertical bands: the lowest
--  level not yet lit, then the HIGHEST footprint level within reach of it
--  hosts the band, so one relay covers as many floors as the vertical range
--  allows and the slack below it reaches a cellar. Within a band, at a range
--  of 10 or more one relay on any square of the chunk lights all of it; at 7
--  or more the host nearest the chunk's centre usually does, and is checked;
--  otherwise `cover` places relays until every square is lit.
--
--  `avoid(x, y, z)` refuses a square as a host (one holding a generator or an
--  Off-Grid part: removing our entry there would take theirs with it). When a
--  band's own level has nowhere to stand, any footprint square in the chunk
--  that reaches is used instead; what nothing can reach is counted and
--  returned, never silently dropped.
--
--  Returns the relays (each { x, y, z } inside its own chunk, on a footprint
--  square), the number of footprint squares left dark, and the checks spent.
function R.planRelays(fp, r, v, avoid)
    local r2 = r * r
    local relays, uncovered = {}, 0
    local work = { n = 0 }

    -- Group by chunk.
    local chunks, order = {}, {}
    for z, set in pairs(fp.levels) do
        for k in pairs(set) do
            local x, y = R.sqXY(k)
            local kx, ky = floor(x / 8), floor(y / 8)
            local ck = kx * SQ + ky
            local c = chunks[ck]
            if not c then
                c = { kx = kx, ky = ky, levels = {} }
                chunks[ck] = c
                order[#order + 1] = c
            end
            local lv = c.levels[z]
            if not lv then
                lv = {}
                c.levels[z] = lv
            end
            lv[#lv + 1] = { x = x, y = y, z = z }
        end
    end
    R.sort(order, function(a, b)
        if a.kx ~= b.kx then return a.kx < b.kx end
        return a.ky < b.ky
    end)

    local function sqLess(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end

    for ci = 1, #order do
        local c = order[ci]
        local levels = {}
        for z, lv in pairs(c.levels) do
            levels[#levels + 1] = z
            R.sort(lv, sqLess)
        end
        R.sort(levels, function(a, b) return a < b end)

        local top = nil               -- highest level lit so far in this chunk
        for li = 1, #levels do
            local l = levels[li]
            if top == nil or l > top then
                -- The band's host: the highest footprint level within reach
                -- of l. l itself always qualifies, so there is one.
                local zb = l
                for lj = li, #levels do
                    if levels[lj] <= l + v then zb = levels[lj] end
                end
                top = zb + v

                -- Dark squares in the band: l .. zb + v (anything below l
                -- was lit by the band before).
                local targets = {}
                for lj = li, #levels do
                    local z = levels[lj]
                    if z > top then break end
                    local lv = c.levels[z]
                    for i = 1, #lv do targets[#targets + 1] = lv[i] end
                end

                local hosts = {}
                local lv = c.levels[zb]
                for i = 1, #lv do
                    local s = lv[i]
                    if not (avoid and avoid(s.x, s.y, s.z)) then hosts[#hosts + 1] = s end
                end

                local left
                -- The host nearest the chunk's centre: at a range of 10 or
                -- more it lights the whole chunk from anywhere in it, and at 7
                -- or more it usually does from near the middle, which one pass
                -- over the band confirms.
                local centre = nil
                if r2 >= 49 and #hosts > 0 then
                    local cx, cy = c.kx * 8 + 3.5, c.ky * 8 + 3.5
                    local bestD = nil
                    for i = 1, #hosts do
                        local h = hosts[i]
                        local d = (h.x - cx) * (h.x - cx) + (h.y - cy) * (h.y - cy)
                        if not bestD or d < bestD then centre, bestD = h, d end
                    end
                end
                if centre and r2 >= 98 then
                    relays[#relays + 1] = { x = centre.x, y = centre.y, z = centre.z }
                    left = {}
                else
                    local all = centre ~= nil
                    if all then
                        for i = 1, #targets do
                            if not reaches(centre, targets[i], r2, v) then
                                all = false
                                break
                            end
                        end
                        work.n = work.n + #targets
                    end
                    if all then
                        relays[#relays + 1] = { x = centre.x, y = centre.y, z = centre.z }
                        left = {}
                    else
                        left = cover(targets, hosts, r2, v, relays, work)
                    end
                end

                if #left > 0 then
                    -- Nowhere on the band's own level can light these. Any
                    -- allowed footprint square in the chunk, at any level.
                    local any = {}
                    for lj = 1, #levels do
                        local lv2 = c.levels[levels[lj]]
                        for i = 1, #lv2 do
                            local s = lv2[i]
                            if not (avoid and avoid(s.x, s.y, s.z)) then any[#any + 1] = s end
                        end
                    end
                    left = cover(left, any, r2, v, relays, work)
                    uncovered = uncovered + #left
                end
            end
        end
    end
    return relays, uncovered, work.n
end

------------------------------------------------------------------- shapes

--- A generator's own circle: the cylinder a position registered on every
--  chunk it touches lights.
function R.circleShape(x, y, z, r, v)
    local lo, hi = R.band(z, v)
    return { t = "c", x = x, y = y, z = z, r = r, r2 = r * r, zlo = lo, zhi = hi,
             x0 = x - r, y0 = y - r, x1 = x + r, y1 = y + r }
end

--- An own-chunk relay: its circle, clipped to its own chunk.
function R.relayShape(x, y, z, r, v)
    local lo, hi = R.band(z, v)
    local kx, ky = floor(x / 8), floor(y / 8)
    local cx0, cy0 = kx * 8, ky * 8
    return { t = "r", x = x, y = y, z = z, r = r, r2 = r * r, zlo = lo, zhi = hi,
             kx = kx, ky = ky,
             x0 = math.max(cx0, x - r), y0 = math.max(cy0, y - r),
             x1 = math.min(cx0 + 7, x + r), y1 = math.min(cy0 + 7, y + r) }
end

function R.contains(s, x, y, z)
    if z < s.zlo or z > s.zhi then return false end
    if x < s.x0 or x > s.x1 or y < s.y0 or y > s.y1 then return false end
    local dx, dy = x - s.x, y - s.y
    return dx * dx + dy * dy <= s.r2
end

--- The columns of one row of a shape, inclusive, or nil when the row is
--  empty. The half-width is the largest w with w*w + dy*dy <= r2, found
--  exactly rather than trusted to a floating square root.
function R.rowSpan(s, y)
    if y < s.y0 or y > s.y1 then return nil end
    local dy = y - s.y
    local rem = s.r2 - dy * dy
    if rem < 0 then return nil end
    local w = floor(sqrt(rem))
    while (w + 1) * (w + 1) <= rem do w = w + 1 end
    while w * w > rem do w = w - 1 end
    local xa, xb = math.max(s.x0, s.x - w), math.min(s.x1, s.x + w)
    if xa > xb then return nil end
    return xa, xb
end

--- How many squares a shape holds, over all its levels.
function R.shapeSquares(s)
    local n = 0
    for y = s.y0, s.y1 do
        local xa, xb = R.rowSpan(s, y)
        if xa then n = n + (xb - xa + 1) end
    end
    return n * (s.zhi - s.zlo + 1)
end

--- The chunks a shape can light: every chunk a circle registers on, or a
--  relay's own chunk.
function R.chunksOf(s)
    if s.t == "r" then return { { kx = s.kx, ky = s.ky } } end
    return R.circleChunks(s.x, s.y, s.r)
end

--- Chunk key -> the indices of the shapes that touch that chunk, ascending.
function R.chunkIndex(shapes)
    local ix = {}
    for i = 1, #shapes do
        local list = R.chunksOf(shapes[i])
        for j = 1, #list do
            local ck = list[j].kx .. "," .. list[j].ky
            local l = ix[ck]
            if not l then
                l = {}
                ix[ck] = l
            end
            l[#l + 1] = i
        end
    end
    return ix
end

--- Is shape i the first shape that contains x, y, z? The square belongs to
--  it for billing, and to nothing after it.
function R.owner(shapes, ix, i, x, y, z)
    if not R.contains(shapes[i], x, y, z) then return false end
    local list = ix[floor(x / 8) .. "," .. floor(y / 8)]
    if not list then return true end
    for n = 1, #list do
        local j = list[n]
        if j >= i then break end
        if R.contains(shapes[j], x, y, z) then return false end
    end
    return true
end

return R

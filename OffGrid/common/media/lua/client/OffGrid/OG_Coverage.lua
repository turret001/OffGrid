-- A system's reach: faint full-area fill, strong boundary tiles and an outer
-- edge, on the floor the player stands on.
--
-- The controller's own circle is read from the engine predicate, and
-- everything the system adds -- transformer circles and wired buildings -- from
-- the registrations OG_Grid applies (the same registry the power itself comes
-- from), so the overlay shows what is actually lit rather than a picture of
-- it. Chosen from the controller or from any transformer in its system; a
-- controller with nothing extra draws exactly the circle it always did.
--
-- While it shows, every light and appliance the system reaches glows in the
-- colour of its line on the LOADS page: green when it is switched on and
-- billed (even while the battery protection holds the power off), faint white
-- when it is switched off and listed idle. What the page leaves out -- a solar
-- lamp, a battery radio, anything that is not an appliance -- does not glow.
require "OffGrid/OG_Parts"
require "OffGrid/OG_Interop"
require "OffGrid/OG_Reach"
require "OffGrid/OG_Loads"

OffGrid.Coverage = OffGrid.Coverage or {}
local V = OffGrid.Coverage
local selected = {}

local floor = math.floor

-------------------------------------------------------------------- the glow

-- The engine blends a highlighted object toward its highlight colour by the
-- alpha, over whatever light the object is standing in. Green at full
-- strength reads in a dark room and in daylight; white at a third lifts an
-- idle object out of the dark without repainting it.
V.LOAD_ON = { r = 0.25, g = 0.95, b = 0.35, a = 1.0 }
V.LOAD_OFF = { r = 1.0, g = 1.0, b = 1.0, a = 0.35 }
-- The engine's own highlight colour (IsoObject's constructor), put back when
-- a glow goes, so a vanilla highlight that sets no colour of its own looks as
-- it always did.
local PLAIN = { r = 0.9, g = 1.0, b = 0.0, a = 1.0 }
-- Squares read per frame, and the least time between the starts of two
-- passes. The default reach is about 9,000 squares over seven floors, so a
-- pass takes a few frames and a light switched on glows within a second.
V.GLOW_BUDGET = 1500
V.GLOW_EVERY_MS = 500

local function paint(obj, index, c)
    obj:setHighlightColor(index, c.r, c.g, c.b, c.a)
    obj:setHighlighted(index, true, false)
end

local function unpaint(obj, index)
    obj:setHighlighted(index, false, false)
    obj:setHighlightColor(index, PLAIN.r, PLAIN.g, PLAIN.b, PLAIN.a)
end

--- Take a selection's glow off everything it lit.
local function unglow(state, index)
    local g = state and state.glow
    if not g then return end
    for obj in pairs(g.lit) do pcall(unpaint, obj, index) end
    state.glow = nil
end

--- What a world object shows: "on", "off", or nil for no glow. The LOADS
--  page's own rule (OG_Loads.objectDraw), so a glow is always a line there.
local function loadState(obj)
    local ok, w, _, kind, rated = pcall(OffGrid.Loads.objectDraw, obj)
    if not ok or type(w) ~= "number" then return nil end
    if w > 0 then return "on" end
    if kind and rated then return "off" end
    return nil
end

--- The shapes the system lights, in the order its billing sweep walks them
--  (OG_Distrib's plan): the controller's own circle, each transformer's
--  circle, then the relays of its wired buildings.
local function glowShapes(state, sysKey, radius, vertical)
    local R = OffGrid.Reach
    local shapes = { R.circleShape(state.x, state.y, state.z, radius, vertical) }
    local G = OffGrid.Grid
    local e = G and G.entry and G.entry(sysKey)
    if e and not e.dead then
        local circles = R.decodePositions(e.c)
        for i = 1, #circles do
            local c = circles[i]
            shapes[#shapes + 1] = R.circleShape(c.x, c.y, c.z, radius, vertical)
        end
        local relays = R.decodePositions(e.r)
        for i = 1, #relays do
            local p = relays[i]
            shapes[#shapes + 1] = R.relayShape(p.x, p.y, p.z, radius, vertical)
        end
    end
    return shapes, R.chunkIndex(shapes)
end

--- Read one square's objects into the pass, glowing each as it is found.
local function readGlow(g, sq, index)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local st = obj and loadState(obj)
        if st then
            g.seen[obj] = st
            -- Painted again when the state changed, or when something else
            -- took the highlight off (a vanilla hover highlight that rendered
            -- once clears every player's flag with it).
            if g.lit[obj] ~= st or not obj:isHighlighted(index) then
                paint(obj, index, st == "on" and V.LOAD_ON or V.LOAD_OFF)
            end
            g.lit[obj] = st
        end
    end
end

--- One shape's part of one chunk: every square in reach there that belongs
--  to this shape and to no earlier one (R.owner), as billing reads it.
--  Returns the squares looked at.
local function glowUnit(g, p, ch, index)
    local R = OffGrid.Reach
    local s = p.shapes[p.si]
    local x0, y0 = ch.kx * 8, ch.ky * 8
    local cost = 0
    for y = math.max(s.y0, y0), math.min(s.y1, y0 + 7) do
        local xa, xb = R.rowSpan(s, y)
        if xa then
            if xa < x0 then xa = x0 end
            if xb > x0 + 7 then xb = x0 + 7 end
            for x = xa, xb do
                for z = s.zlo, s.zhi do
                    cost = cost + 1
                    if p.si == 1 or R.owner(p.shapes, p.ix, p.si, x, y, z) then
                        local sq = getSquare(x, y, z)
                        if sq then readGlow(g, sq, index) end
                    end
                end
            end
        end
    end
    return cost
end

--- A glow pass over the whole reach, a budget of squares a frame. Anything
--  lit that the finished pass did not find again (switched to a battery,
--  taken away, streamed out, out of reach) loses its glow then, not before,
--  so nothing flickers while a pass is part way round.
local function glowStep(state, index, sysKey, radius, vertical)
    if not (OffGrid.Reach and OffGrid.Loads and OffGrid.Loads.objectDraw) then return end
    local g = state.glow
    if not g then
        g = { lit = {} }
        state.glow = g
    end
    local p = g.pass
    if not p then
        local now = getTimestampMs()
        if g.started and now - g.started < V.GLOW_EVERY_MS then return end
        local shapes, ix = glowShapes(state, sysKey, radius, vertical)
        p = { shapes = shapes, ix = ix, si = 1, ci = 1 }
        g.pass, g.seen, g.started = p, {}, now
    end
    local budget = V.GLOW_BUDGET
    while budget > 0 do
        local s = p.shapes[p.si]
        if not s then
            local gone = {}
            for obj in pairs(g.lit) do
                if not g.seen[obj] then gone[#gone + 1] = obj end
            end
            for i = 1, #gone do
                pcall(unpaint, gone[i], index)
                g.lit[gone[i]] = nil
            end
            g.pass, g.seen = nil, nil
            return
        end
        s.chunks = s.chunks or OffGrid.Reach.chunksOf(s)
        local ch = s.chunks[p.ci]
        if not ch then
            p.si, p.ci = p.si + 1, 1
        else
            p.ci = p.ci + 1
            budget = budget - glowUnit(g, p, ch, index)
        end
    end
end

--- End one player's selection, glow and all.
local function forget(index)
    unglow(selected[index], index)
    selected[index] = nil
end

function V.clear()
    for index in pairs(selected) do unglow(selected[index], index) end
    selected = {}
end

--- The controller square of the system a part belongs to: its own for a
--  controller, the one a transformer's claim names.
local function systemOf(object)
    local P = OffGrid.Parts
    local kind = object and P.partOf(object)
    if kind == "controller" then
        local sq = object:getSquare()
        if not sq then return nil end
        return sq:getX(), sq:getY(), sq:getZ()
    elseif kind == "transformer" and OffGrid.Model and P.data then
        return OffGrid.Model.parseNodeKey(P.data(object).sys)
    end
    return nil
end

function V.isSelected(object, player)
    local s = player and selected[player:getPlayerNum()]
    if not s then return false end
    local x, y, z = systemOf(object)
    return x ~= nil and s.x == x and s.y == y and s.z == z
end

function V.toggle(object, player)
    if not player then return end
    local index = player:getPlayerNum()
    if V.isSelected(object, player) then
        forget(index)
        return
    end
    local x, y, z = systemOf(object)
    if not x then return end
    local P = OffGrid.Parts
    local ctrl = (P.partOf(object) == "controller") and object
                 or (P.objectAt and P.objectAt(x, y, z, "controller")) or nil
    forget(index)
    selected[index] = { object = ctrl, x = x, y = y, z = z }
end

-- Cache horizontal runs so the geometry is not recalculated every frame. The
-- engine predicate is authoritative: a decorative circle rounds the edge wrong.
local function spans(x0, y0, x1, y1, inside)
    local rows, edges = {}, {}
    for y = y0, y1 do
        local first, runKind = nil, 0
        for x = x0, x1 + 1 do
            local isIn = x <= x1 and inside(x, y)
            local kind = 0
            if isIn then
                local west = not inside(x - 1, y)
                local east = not inside(x + 1, y)
                local north = not inside(x, y - 1)
                local south = not inside(x, y + 1)
                kind = (west or east or north or south) and 2 or 1
                if west then edges[#edges + 1] = {x, y, x, y + 1} end
                if east then edges[#edges + 1] = {x + 1, y, x + 1, y + 1} end
                if north then edges[#edges + 1] = {x, y, x + 1, y} end
                if south then edges[#edges + 1] = {x, y + 1, x + 1, y + 1} end
            end
            if first and kind ~= runKind then
                rows[#rows + 1] = {first, y, x, y + 1, runKind == 2}
                first = nil
            end
            if kind > 0 and not first then first, runKind = x, kind end
        end
    end
    return rows, edges
end

--- What the system adds, on floor z: its registrations grouped by the chunk
--  they light, and the bounding box they widen the drawing to.
local function added(key, z, radius, vertical, x0, y0, x1, y1)
    local G = OffGrid.Grid
    local e = G and G.entry and G.entry(key)
    if not e or e.dead or not G.expand then return nil, x0, y0, x1, y1, e end
    local byChunk, any = {}, false
    local regs = G.expand(key, e)
    for i = 1, #regs do
        local rg = regs[i]
        if z >= rg.z - vertical and z <= rg.z + vertical then
            local ck = rg.kx .. "," .. rg.ky
            local l = byChunk[ck]
            if not l then
                l = {}
                byChunk[ck] = l
            end
            l[#l + 1] = rg
            any = true
            local cx0, cy0 = rg.kx * 8, rg.ky * 8
            x0 = math.min(x0, math.max(cx0, rg.x - radius))
            y0 = math.min(y0, math.max(cy0, rg.y - radius))
            x1 = math.max(x1, math.min(cx0 + 7, rg.x + radius))
            y1 = math.max(y1, math.min(cy0 + 7, rg.y + radius))
        end
    end
    return any and byChunk or nil, x0, y0, x1, y1, e
end

function V.onUI()
    -- The pause UI consumes Escape before OnKeyPressed. The UI still draws,
    -- so observe the held key here as well, without consuming it ourselves.
    if isKeyDown(Keyboard.KEY_ESCAPE) then V.clear() end
end

local function screen(x, y, z)
    return IsoUtils.XToScreenExact(x, y, z, 0), IsoUtils.YToScreenExact(x, y, z, 0)
end

--- Is the selection still something to draw? A controller object that left
--  its square, or streamed out, ends it, as it always did. With no controller
--  object in reach (chosen from a far transformer) the registry speaks for the
--  system, and a system that is gone from it ends the selection too.
local function live(state, player)
    if not player or player:isDead() then return false end
    local object = state.object
    if object then
        local sq = object:getSquare()
        return sq ~= nil and object:getObjectIndex() >= 0
            and getSquare(sq:getX(), sq:getY(), sq:getZ()) == sq
            and OffGrid.Parts.partOf(object) == "controller"
    end
    local G = OffGrid.Grid
    local e = G and G.entry and G.entry(state.x .. "," .. state.y .. "," .. state.z)
    return e ~= nil and not e.dead
end

function V.render()
    V.onUI()
    local viewport = IsoPlayer.getPlayerIndex()
    for index, state in pairs(selected) do
        local player = getSpecificPlayer(index)
        if not live(state, player) then
            forget(index)
        elseif index == viewport then
            local x, y, cz = state.x, state.y, state.z
            local z = floor(player:getZ())
            local radius = OffGrid.Interop.generatorRange()
            local vertical = OffGrid.Interop.generatorVerticalRange()
            local sysKey = x .. "," .. y .. "," .. cz
            -- What the drawing depends on, compared before any work is done:
            -- this runs every frame. A removed system counts as having added
            -- nothing, so its relays stop being drawn the moment it goes.
            local G = OffGrid.Grid
            local entry = G and G.entry and G.entry(sysKey)
            local ec, er = "", ""
            if entry and not entry.dead then ec, er = entry.c or "", entry.r or "" end
            if state.kz ~= z or state.kr ~= radius or state.kv ~= vertical
                    or state.kc ~= ec or state.kre ~= er or not state.rows then
                local byChunk, x0, y0, x1, y1 =
                    added(sysKey, z, radius, vertical, x - radius, y - radius, x + radius, y + radius)
                local r2 = radius * radius
                local function inside(px, py)
                    if IsoGenerator.isPoweringSquare(x, y, cz, px, py, z) then return true end
                    local list = byChunk and byChunk[floor(px / 8) .. "," .. floor(py / 8)]
                    if not list then return false end
                    for i = 1, #list do
                        local dx, dy = px - list[i].x, py - list[i].y
                        if dx * dx + dy * dy <= r2 then return true end
                    end
                    return false
                end
                state.rows, state.edges = spans(x0, y0, x1, y1, inside)
                state.kz, state.kr, state.kv, state.kc, state.kre = z, radius, vertical, ec, er
            end
            -- Activation is the actual power-delivery switch, unlike online
            -- (which can remain true while the battery protection is open).
            -- With no controller object in reach, the registry's switch.
            local on
            if state.object then on = state.object:isActivated()
            else on = entry ~= nil and entry.on == true end
            local r, g, b = 0.85, 0.55, 0.15
            if on then r, g, b = 0.15, 0.75, 0.35 end
            local renderer = SpriteRenderer.instance
            for _, row in ipairs(state.rows) do
                local x1s, y1s = screen(row[1], row[2], z)
                local x2s, y2s = screen(row[3], row[2], z)
                local x3s, y3s = screen(row[3], row[4], z)
                local x4s, y4s = screen(row[1], row[4], z)
                renderer:renderPoly(x1s, y1s, x2s, y2s, x3s, y3s, x4s, y4s,
                                    r, g, b, row[5] and 0.32 or 0.10)
            end
            for _, edge in ipairs(state.edges) do
                local ax, ay = screen(edge[1], edge[2], z)
                local bx, by = screen(edge[3], edge[4], z)
                renderer:renderlinef(nil, ax, ay, bx, by, r, g, b, 0.90, 2)
            end
            glowStep(state, index, sysKey, radius, vertical)
        end
    end
end

function V.onKeyPressed(key)
    if key == Keyboard.KEY_ESCAPE then V.clear() end
end

-- Draw in the current world viewport, before UI, with world camera/zoom handling.
-- Native area highlights cannot fill this shape without outlining every strip.
Events.OnPostRender.Add(V.render)
Events.OnPreUIDraw.Add(V.onUI)
Events.OnKeyPressed.Add(V.onKeyPressed)
Events.OnGameStart.Add(V.clear)

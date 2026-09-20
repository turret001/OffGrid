-- Controller reach: faint full-area fill, strong boundary tiles and an outer edge.
require "OffGrid/OG_Parts"
require "OffGrid/OG_Interop"

OffGrid.Coverage = OffGrid.Coverage or {}
local V = OffGrid.Coverage
local selected = {}

function V.clear()
    selected = {}
end

function V.isSelected(object, player)
    local s = player and selected[player:getPlayerNum()]
    return s ~= nil and s.object == object
end

function V.toggle(object, player)
    if not player then return end
    local index = player:getPlayerNum()
    if V.isSelected(object, player) then
        selected[index] = nil
    elseif object and OffGrid.Parts.partOf(object) == "controller" then
        selected[index] = { object = object }
    end
end

-- Cache horizontal runs so the geometry is not recalculated every frame. The
-- engine predicate is authoritative: a decorative circle rounds the edge wrong.
local function spans(cx, cy, cz, z, radius)
    local rows, edges = {}, {}
    for y = cy - radius, cy + radius do
        local first, runKind = nil, 0
        for x = cx - radius, cx + radius + 1 do
            local inside = x <= cx + radius
                and IsoGenerator.isPoweringSquare(cx, cy, cz, x, y, z)
            local kind = 0
            if inside then
                local west = not IsoGenerator.isPoweringSquare(cx, cy, cz, x - 1, y, z)
                local east = not IsoGenerator.isPoweringSquare(cx, cy, cz, x + 1, y, z)
                local north = not IsoGenerator.isPoweringSquare(cx, cy, cz, x, y - 1, z)
                local south = not IsoGenerator.isPoweringSquare(cx, cy, cz, x, y + 1, z)
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

function V.onUI()
    -- The pause UI consumes Escape before OnKeyPressed. The UI still draws,
    -- so observe the held key here as well, without consuming it ourselves.
    if isKeyDown(Keyboard.KEY_ESCAPE) then V.clear() end
end

local function screen(x, y, z)
    return IsoUtils.XToScreenExact(x, y, z, 0), IsoUtils.YToScreenExact(x, y, z, 0)
end

function V.render()
    V.onUI()
    local viewport = IsoPlayer.getPlayerIndex()
    for index, state in pairs(selected) do
        local player = getSpecificPlayer(index)
        local object = state.object
        local sq = object:getSquare()
        if not player or player:isDead() or not sq or object:getObjectIndex() < 0
                or getSquare(sq:getX(), sq:getY(), sq:getZ()) ~= sq
                or OffGrid.Parts.partOf(object) ~= "controller" then
            selected[index] = nil
        elseif index == viewport then
            local x, y, cz = sq:getX(), sq:getY(), sq:getZ()
            local z = math.floor(player:getZ())
            local radius = OffGrid.Interop.generatorRange()
            local vertical = OffGrid.Interop.generatorVerticalRange()
            local key = table.concat({x, y, cz, z, radius, vertical}, ":")
            if state.key ~= key then
                state.rows, state.edges = spans(x, y, cz, z, radius)
                state.key = key
            end
            -- Activation is the actual power-delivery switch, unlike online
            -- (which can remain true while the battery protection is open).
            local r, g, b = 0.85, 0.55, 0.15
            if object:isActivated() then r, g, b = 0.15, 0.75, 0.35 end
            local renderer = SpriteRenderer.instance
            for _, row in ipairs(state.rows) do
                local x1, y1 = screen(row[1], row[2], z)
                local x2, y2 = screen(row[3], row[2], z)
                local x3, y3 = screen(row[3], row[4], z)
                local x4, y4 = screen(row[1], row[4], z)
                renderer:renderPoly(x1, y1, x2, y2, x3, y3, x4, y4,
                                    r, g, b, row[5] and 0.32 or 0.10)
            end
            for _, edge in ipairs(state.edges) do
                local x1, y1 = screen(edge[1], edge[2], z)
                local x2, y2 = screen(edge[3], edge[4], z)
                renderer:renderlinef(nil, x1, y1, x2, y2, r, g, b, 0.90, 2)
            end
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

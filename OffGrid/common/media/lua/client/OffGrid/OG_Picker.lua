--[[ OffGrid -- the Building Picker.

     Off-Grid > Choose buildings... on a controller or a transformer opens a
     small window and an overlay. Every building and player-built structure
     that part wires is shaded green on the floor the player is standing on.
     The one under the cursor is shaded yellow when a click would add it, blue
     when a click would take it away, green when another part of the same
     system already wires it, and red when the part does not reach it or
     another system wires it. A click sends the square to the authority
     (bwPick), which decides:
     the client never writes a part's ModData, because a client's
     transmitModData replaces the server's whole table.

     The preview under the cursor is resolved HERE, with the same resolver the
     server uses (OG_Buildings), so what lights up is what a click will pick.
     The green is not resolved here at all: it is the footprint the server
     stored on the part (`bwr`), so every client draws exactly what the server
     wired -- a player-built structure included, which a dedicated server
     knows only as regions.

     One window per player, closed by Done, by Escape, by walking out of the
     part's reach, or by the part leaving the world. The world click reaches
     Lua only when no window took it (UIManager fires OnMouseDown only for an
     unconsumed click), so the window's own buttons never pick a building.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Reach"
require "OffGrid/OG_Buildings"
require "OffGrid/OG_Interop"

OffGrid = OffGrid or {}
OffGrid.Picker = OffGrid.Picker or {}
local K = OffGrid.Picker
local P = OffGrid.Parts
local R = OffGrid.Reach
local B = OffGrid.Buildings

local floor = math.floor

-- Font-derived, like every other Off-Grid window (see OG_Bank).
local FH_S = getTextManager():getFontHeight(UIFont.Small)
local SCALE = math.max(1, FH_S / 16)
local function px(v) return floor(v * SCALE + 0.5) end
local W, PAD, BTN = px(300), px(10), px(24)
local LIST_MAX = 8

local GREEN = { 0.20, 0.80, 0.40 }
local ADD   = { 0.95, 0.80, 0.20 }
local TAKE  = { 0.35, 0.60, 0.95 }
local FAR   = { 0.90, 0.30, 0.25 }

local states = {}          -- player number -> picker state

--------------------------------------------------------------------- basics

local function send(playerObj, command, args)
    if OffGrid.Context and OffGrid.Context.send then
        OffGrid.Context.send(playerObj, command, args)
    end
end

--- Why this player may not change what the part wires, or nil: the part's
--  pick-up lock (Can, 2026-09-29: "Lock them in 3.0.0"), OG_Place's
--  G.useRefusal, the question the authority asks again (OG_Distrib). The
--  picker opens only from Choose buildings..., which is greyed with it, so
--  this is a player whose lock changed while the picker was up.
local function lockOf(st)
    local G = OffGrid.Place
    if not (st and st.player and st.part and G and G.useRefusal) then return nil end
    return G.useRefusal(st.player, P.try(st.part, "getSquare"), st.part)
end

--- A click the lock refuses: the reason above the player, in the warning
--  colour, and nothing sent. True when refused.
local function refused(st)
    local why = lockOf(st)
    if not why then return false end
    P.haloNote(st.player, getText(why), true)
    return true
end

local function range()
    local I = OffGrid.Interop
    local r = I and I.generatorRange and I.generatorRange() or 20
    local v = I and I.generatorVerticalRange and I.generatorVerticalRange() or 3
    return r, v
end

--- What the part wires, with every footprint decoded. Cached on the two
--  strings it is read from, so a frame costs nothing until the server
--  changes them.
local function wired(st)
    local d = P.data(st.part)
    if st.cacheBw == (d.bw or "") and st.cacheBwr == (d.bwr or "") and st.cacheList then
        return st.cacheList
    end
    local list = B.decodeTargets(d.bw)
    local rects, i = {}, 1
    for seg in string.gmatch((d.bwr or "") .. "|", "([^|]*)|") do
        rects[i] = seg
        i = i + 1
    end
    for n = 1, #list do
        local t = list[n]
        t.rects = R.decodeRects(rects[n] or "")
        t.fp = R.fpOfRects(t.rects)
        local _, _, _, _, z0, z1 = R.fpBounds(t.fp)
        t.floors = z0 and (z1 - z0 + 1) or 0
    end
    st.cacheBw, st.cacheBwr, st.cacheList = d.bw or "", d.bwr or "", list
    -- What the hover shows depends on what is wired: look again, from scratch.
    st.hoverKey, st.hover = nil, nil
    return list
end
K.wired = wired

--- The square under the mouse, on the floor the player is looking at.
--  screenToIsoX/Y take window pixels (what getMouseX returns) and apply the
--  zoom themselves; see OGTB_Yard for the two pixel spaces and why drawing
--  and picking must not share one.
function K.mouseSquare(pn, z)
    if not (getMouseX and screenToIsoX and screenToIsoY) then return nil end
    local mx, my = getMouseX(), getMouseY()
    local ok1, wx = pcall(screenToIsoX, pn, mx, my, z)
    local ok2, wy = pcall(screenToIsoY, pn, mx, my, z)
    if not (ok1 and ok2 and wx and wy) then return nil end
    return floor(wx), floor(wy)
end

--- The registry key of the system the part belongs to: the controller's own
--  square, or the one a transformer's claim names. Nil for a transformer in
--  no system.
local function systemKey(st)
    if P.partOf(st.part) == "controller" then return st.x .. "," .. st.y .. "," .. st.z end
    local M = OffGrid.Model
    if not (M and M.parseNodeKey) then return nil end
    local x, y, z = M.parseNodeKey(P.data(st.part).sys)
    if not x then return nil end
    return x .. "," .. y .. "," .. z
end

--- The target under the cursor, resolved only when the square changes.
local function hover(st, pn, z)
    local sx, sy = K.mouseSquare(pn, z)
    if not sx then
        st.hover, st.hoverKey = nil, nil
        return
    end
    local hk = sx .. "," .. sy .. "," .. z
    if st.hoverKey == hk then return end
    st.hoverKey = hk
    -- Still over the same target: keep it. Resolving a player-built
    -- structure reads its regions, and the mouse crosses a room square by
    -- square.
    if st.hover and st.hover.fp and R.fpHas(st.hover.fp, sx, sy, z) then return end
    st.hover = nil
    local list = wired(st)
    for n = 1, #list do
        local w = list[n]
        if R.fpHas(w.fp, sx, sy, z) then
            st.hover = { rects = w.rects, mode = "take", fp = w.fp }
            return
        end
    end
    local t = B.targetAt(sx, sy, z)
    if not t then return end
    for n = 1, #list do
        if list[n].k == "b" and t.k == "b" and list[n].id == t.id then
            st.hover = { rects = list[n].rects, mode = "take", fp = list[n].fp }
            return
        end
    end
    local fp = B.footprintOf(t)
    if not fp then return end
    -- Wired by another part of this system, or by another system: a click
    -- adds nothing, and the preview said "add" (live, 2026-09-24). Read off
    -- the registry every side holds, with the server's own test.
    local G, own = OffGrid.Grid, systemKey(st)
    local mode
    if G and G.wires and own and G.wires(G.entry(own), t, fp) then
        mode = "wired"
    elseif G and G.wiredBy and G.wiredBy(t, fp, own) then
        mode = "taken"
    else
        local r, v = range()
        mode = B.reaches(fp, st.x, st.y, st.z, r, v) and "add" or "far"
    end
    st.hover = { rects = R.rectsOf(fp), fp = fp, mode = mode }
end

----------------------------------------------------------------- the overlay

local function screen(x, y, z)
    return IsoUtils.XToScreenExact(x, y, z, 0), IsoUtils.YToScreenExact(x, y, z, 0)
end

local function drawRect(rc, z, col, fill)
    local renderer = SpriteRenderer.instance
    local x1, y1 = screen(rc.x, rc.y, z)
    local x2, y2 = screen(rc.x + rc.w, rc.y, z)
    local x3, y3 = screen(rc.x + rc.w, rc.y + rc.h, z)
    local x4, y4 = screen(rc.x, rc.y + rc.h, z)
    renderer:renderPoly(x1, y1, x2, y2, x3, y3, x4, y4, col[1], col[2], col[3], fill)
end

--- The outline of a footprint on one floor: every square edge that has no
--  neighbour of the footprint on the other side.
--- The outline of a footprint on one floor, as straight runs of edge.
--  Worked out once per target and floor and kept on its rects list: it is
--  drawn every frame the picker is open, and a 30 by 30 house is 900 squares
--  to sort into inside and outside but only a handful of straight runs.
local function edgesOf(rects, z)
    local cache = rects.edges
    if not cache then
        cache = {}
        rects.edges = cache
    end
    if cache[z] then return cache[z] end
    local set = {}
    local x0, y0, x1, y1
    for _, rc in ipairs(rects) do
        if rc.z == z then
            for x = rc.x, rc.x + rc.w - 1 do
                for y = rc.y, rc.y + rc.h - 1 do set[R.sqKey(x, y)] = true end
            end
            local rx1, ry1 = rc.x + rc.w - 1, rc.y + rc.h - 1
            if not x0 then
                x0, y0, x1, y1 = rc.x, rc.y, rx1, ry1
            else
                x0, y0 = math.min(x0, rc.x), math.min(y0, rc.y)
                x1, y1 = math.max(x1, rx1), math.max(y1, ry1)
            end
        end
    end
    local runs = {}
    if x0 then
        -- Along each row, the top and bottom sides of the squares whose
        -- neighbour that way is outside; a run ends at the first square it
        -- does not cover.
        for y = y0, y1 do
            local top, bottom = nil, nil
            for x = x0, x1 + 1 do
                local inside = x <= x1 and set[R.sqKey(x, y)]
                local t = inside and not set[R.sqKey(x, y - 1)]
                local b = inside and not set[R.sqKey(x, y + 1)]
                if t and not top then top = x end
                if not t and top then
                    runs[#runs + 1] = { top, y, x, y }
                    top = nil
                end
                if b and not bottom then bottom = x end
                if not b and bottom then
                    runs[#runs + 1] = { bottom, y + 1, x, y + 1 }
                    bottom = nil
                end
            end
        end
        -- Down each column, the left and right sides the same way.
        for x = x0, x1 do
            local left, right = nil, nil
            for y = y0, y1 + 1 do
                local inside = y <= y1 and set[R.sqKey(x, y)]
                local l = inside and not set[R.sqKey(x - 1, y)]
                local rt = inside and not set[R.sqKey(x + 1, y)]
                if l and not left then left = y end
                if not l and left then
                    runs[#runs + 1] = { x, left, x, y }
                    left = nil
                end
                if rt and not right then right = y end
                if not rt and right then
                    runs[#runs + 1] = { x + 1, right, x + 1, y }
                    right = nil
                end
            end
        end
    end
    cache[z] = runs
    return runs
end

local function outline(rects, z, col)
    local renderer = SpriteRenderer.instance
    local runs = edgesOf(rects, z)
    for i = 1, #runs do
        local e = runs[i]
        local ax, ay = screen(e[1], e[2], z)
        local bx, by = screen(e[3], e[4], z)
        renderer:renderlinef(nil, ax, ay, bx, by, col[1], col[2], col[3], 0.85, 2)
    end
end

local function drawFootprint(rects, z, col, fill)
    for _, rc in ipairs(rects) do
        if rc.z == z then drawRect(rc, z, col, fill) end
    end
    outline(rects, z, col)
end

--- The part's own reach on this floor, as its outer edge only: the thing the
--  red means.
local function reachEdge(st, z)
    local r, v = range()
    if z < st.z - v or z > st.z + v then return end
    local key = r .. ":" .. z
    if st.edgeKey ~= key then
        st.edgeKey = key
        local edges = {}
        local function inside(x, y)
            local dx, dy = x - st.x, y - st.y
            return dx * dx + dy * dy <= r * r
        end
        for y = st.y - r, st.y + r do
            for x = st.x - r, st.x + r do
                if inside(x, y) then
                    if not inside(x, y - 1) then edges[#edges + 1] = { x, y, x + 1, y } end
                    if not inside(x, y + 1) then edges[#edges + 1] = { x, y + 1, x + 1, y + 1 } end
                    if not inside(x - 1, y) then edges[#edges + 1] = { x, y, x, y + 1 } end
                    if not inside(x + 1, y) then edges[#edges + 1] = { x + 1, y, x + 1, y + 1 } end
                end
            end
        end
        st.edges = edges
    end
    local renderer = SpriteRenderer.instance
    for _, e in ipairs(st.edges or {}) do
        local ax, ay = screen(e[1], e[2], z)
        local bx, by = screen(e[3], e[4], z)
        renderer:renderlinef(nil, ax, ay, bx, by, 1, 1, 1, 0.45, 1)
    end
end

local function stillValid(st, player)
    if not player or player:isDead() then return false end
    local part = st.part
    if not part or part:getObjectIndex() < 0 then return false end
    local sq = part:getSquare()
    if not sq or getSquare(sq:getX(), sq:getY(), sq:getZ()) ~= sq then return false end
    -- Walked out of the part's reach: the server would refuse every click.
    local r = range()
    local dx, dy = player:getX() - st.x, player:getY() - st.y
    return dx * dx + dy * dy <= (r + 2) * (r + 2)
end

function K.render()
    local viewport = IsoPlayer.getPlayerIndex()
    for pn, st in pairs(states) do
        local player = getSpecificPlayer(pn)
        if not stillValid(st, player) then
            K.close(pn)
        elseif pn == viewport then
            local z = floor(player:getZ())
            reachEdge(st, z)
            local list = wired(st)
            for n = 1, #list do drawFootprint(list[n].rects, z, GREEN, 0.28) end
            hover(st, pn, z)
            local h = st.hover
            if h then
                local col = (h.mode == "take" and TAKE) or (h.mode == "add" and ADD)
                            or (h.mode == "wired" and GREEN) or FAR
                drawFootprint(h.rects, z, col, 0.22)
            end
        end
    end
end

------------------------------------------------------------------- clicks

function K.onMouseDown()
    for pn, st in pairs(states) do
        local player = getSpecificPlayer(pn)
        if player and stillValid(st, player) then
            local z = floor(player:getZ())
            local sx, sy = K.mouseSquare(pn, z)
            if sx and not refused(st) then
                send(player, "bwPick", { x = st.x, y = st.y, z = st.z, kind = st.kind,
                                         sx = sx, sy = sy, sz = z })
                st.hoverKey = nil
            end
        end
    end
end

function K.onUI()
    -- The pause UI consumes Escape before OnKeyPressed; the held key is still
    -- visible here (the coverage overlay does the same).
    if isKeyDown and isKeyDown(Keyboard.KEY_ESCAPE) then K.closeAll() end
end

------------------------------------------------------------------- window

OG_Picker = ISCollapsableWindow:derive("OG_Picker")

--- Break a sentence into lines that fit the window. The legend ran off its
--  right edge in English (live, 2026-09-24).
local function wrap(text, width)
    local out, line = {}, ""
    local tm = getTextManager()
    for word in string.gmatch(text or "", "%S+") do
        local try = (line == "") and word or (line .. " " .. word)
        if tm:MeasureStringX(UIFont.Small, try) > width and line ~= "" then
            out[#out + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then out[#out + 1] = line end
    return out
end

function OG_Picker:createChildren()
    ISCollapsableWindow.createChildren(self)
    local half = floor((W - PAD * 3) / 2)
    local y = self:getHeight() - PAD - BTN
    self.bClear = ISButton:new(PAD, y, half, BTN, getText("IGUI_OffGrid_PickClear"), self, OG_Picker.onClear)
    self.bClear:initialise()
    self.bClear:instantiate()
    self.bClear.tooltip = getText("Tooltip_OffGrid_UnwireBuildings")
    self:addChild(self.bClear)
    self.bDone = ISButton:new(PAD * 2 + half, y, half, BTN, getText("IGUI_OffGrid_PickDone"), self, OG_Picker.onDone)
    self.bDone:initialise()
    self.bDone:instantiate()
    self:addChild(self.bDone)
end

function OG_Picker:onClear()
    local st = self.state
    if st and st.player and not refused(st) then
        send(st.player, "bwClear", { x = st.x, y = st.y, z = st.z, kind = st.kind })
    end
end

function OG_Picker:onDone()
    if self.state then K.close(self.state.pn) end
end

function OG_Picker:close()
    self:onDone()
end

--- One line per wired target: what it is and how big.
local function describe(t)
    local key = (t.k == "b") and "IGUI_OffGrid_PickBuilding" or "IGUI_OffGrid_PickStructure"
    -- Counted pieces, so a one-storey shed reads "1 floor" (live, 2026-09-24).
    return P.txt(key, P.count("IGUI_OffGrid_TileCount", R.fpCount(t.fp)),
                 P.count("IGUI_OffGrid_FloorCount", t.floors))
end

function OG_Picker:prerender()
    ISCollapsableWindow.prerender(self)
    local st = self.state
    if not st then return end
    local list = wired(st)
    local y = self:titleBarHeight() + PAD
    local lh = FH_S + px(3)
    for i = 1, #self.help do
        self:drawText(self.help[i], PAD, y, 0.90, 0.90, 0.90, 1, UIFont.Small)
        y = y + lh
    end
    for i = 1, #self.legend do
        self:drawText(self.legend[i], PAD, y, 0.65, 0.70, 0.75, 1, UIFont.Small)
        y = y + lh
    end
    y = y + px(4)
    self:drawText(P.txt("IGUI_OffGrid_PickCount", #list), PAD, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    y = y + lh
    for n = 1, math.min(#list, LIST_MAX) do
        self:drawText("  " .. describe(list[n]), PAD, y, GREEN[1], GREEN[2], GREEN[3], 1, UIFont.Small)
        y = y + lh
    end
    -- Remove all: greyed with nothing wired, and for a player the part's
    -- lock refuses, with the reason for its tooltip (never hidden).
    if self.bClear then
        local why = lockOf(st)
        self.bClear:setEnable(#list > 0 and not why)
        self.bClear.tooltip = getText(why or "Tooltip_OffGrid_UnwireBuildings")
    end
end

function OG_Picker:new(st)
    local lh = FH_S + px(3)
    local sw = (getCore and getCore() and getCore():getScreenWidth()) or 1920
    -- On the right: the game's icon column runs the full height of the left
    -- edge and has sat on top of a window put there twice before (OGTB_YardUI).
    local o = ISCollapsableWindow.new(self, sw - W - px(24), px(110), W, 10)
    o:setResizable(false)
    o.state = st
    o.title = getText("IGUI_OffGrid_PickTitle")
    o.pin = true
    o.help = wrap(getText("IGUI_OffGrid_PickHelp"), W - PAD * 2)
    o.legend = wrap(getText("IGUI_OffGrid_PickLegend"), W - PAD * 2)
    o:setHeight(o:titleBarHeight() + PAD + lh * (#o.help + #o.legend + 1 + LIST_MAX)
                + px(4) + PAD + BTN + PAD)
    return o
end

-------------------------------------------------------------------- the API

function K.stateFor(playerObj)
    return playerObj and states[playerObj:getPlayerNum()] or nil
end

function K.isOpen(playerObj)
    return K.stateFor(playerObj) ~= nil
end

function K.close(pn)
    local st = states[pn]
    if not st then return end
    states[pn] = nil
    if st.window then st.window:removeFromUIManager() end
end

function K.closeAll()
    for pn in pairs(states) do K.close(pn) end
end

--- Open the picker for a controller or a transformer.
function K.open(playerObj, part)
    if not playerObj or not part then return nil end
    local kind = P.partOf(part)
    if kind ~= "controller" and kind ~= "transformer" then return nil end
    local sq = part:getSquare()
    if not sq then return nil end
    local pn = playerObj:getPlayerNum()
    K.close(pn)
    local st = { part = part, kind = kind, x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                 player = playerObj, pn = pn }
    states[pn] = st
    local win = OG_Picker:new(st)
    win:initialise()
    -- addToUIManager instantiates a window that has not been, which builds
    -- its children once (the pattern OG_Bank uses).
    win:addToUIManager()
    st.window = win
    return st
end

Events.OnPostRender.Add(K.render)
Events.OnPreUIDraw.Add(K.onUI)
Events.OnMouseDown.Add(K.onMouseDown)
Events.OnGameStart.Add(K.closeAll)

return K

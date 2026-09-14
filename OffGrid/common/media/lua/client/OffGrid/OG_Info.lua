--[[ OffGrid -- the device info panel.

     One window that answers "what is this thing, what can it do, and what is
     it plugged into", for any of the mod's objects.

     It exists because the mod grew a lot of numbers that only ever appeared
     inside the controller's monitor, and a panel sitting on its own in a field
     could not tell you its own efficiency, its own tilt, or whether it was
     even part of a system. That last one matters most now that wiring is a
     thing the player does rather than something that happens to them.

     Its own ISCollapsableWindow, with its own drawing helpers. It used to
     derive from OG_Window to share that window's card/label/text helpers,
     which broke the day OG_Window became the OG-1200 machine face: the new
     window is an ISPanel with none of those helpers and none of this
     palette, so inheriting from it meant opening Info threw before the
     window existed. The dozen lines of helper are cheaper than the coupling.

     No live tick, no day curve, no snapshot. It reads the object once when
     it opens and again if the object changes under it.
]]

require "ISUI/ISCollapsableWindow"
require "OffGrid/OG_Context"

OffGrid = OffGrid or {}
OffGrid.Info = OffGrid.Info or {}

OG_Info = ISCollapsableWindow:derive("OG_Info")

local P = OffGrid.Parts
local M = OffGrid.Model
local E = OffGrid.Env

-- Font-derived, because the game has no UI scale: Options > Font Size swaps
-- the font set and every UIFont grows with it, so a row pitch fixed at 19
-- stacked 4x text on top of itself. Taken at file load, which is safe since
-- fonts only change through a full Lua reset. At the base 16 px Small this
-- is exactly the fixed layout it replaces (ROW 19, WIDTH 430, PAD 12).
local FH = getTextManager():getFontHeight(UIFont.Small)
local S = math.max(1, FH / 16)
local function px(v) return math.floor(v * S + 0.5) end

local WIDTH = px(430)
local PAD = px(12)
local ROW = FH + 3

-- The 2.8.x window palette, kept by this panel when the monitor moved on.
local COL = {
    panel = { 0.14, 0.15, 0.18 },
    line  = { 0.28, 0.30, 0.34 },
    text  = { 0.86, 0.88, 0.91 },
    dim   = { 0.55, 0.58, 0.63 },
    good  = { 0.42, 0.78, 0.48 },
    warn  = { 0.85, 0.65, 0.28 },
    bad   = { 0.80, 0.35, 0.30 },
    sun   = { 0.95, 0.78, 0.32 },
    load  = { 0.42, 0.62, 0.88 },
}

-- A Lua multi-return collapses to its first value anywhere but the final
-- argument slot, so c() is only safe as the LAST argument (drawRect takes
-- colour last; drawText does not, hence text()/textRight()).
local function c(name) local k = COL[name]; return k[1], k[2], k[3] end

function OG_Info:card(x, y, w, h)
    self:drawRect(x, y, w, h, 0.9, c("panel"))
    self:drawRectBorder(x, y, w, h, 0.5, c("line"))
end

function OG_Info:label(text, x, y)
    self:drawText(text, x, y, COL.dim[1], COL.dim[2], COL.dim[3], 1,
                  UIFont.Small)
end

function OG_Info:text(str, x, y, col, font)
    local k = COL[col or "text"] or COL.text
    self:drawText(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

function OG_Info:textRight(str, x, y, col, font)
    local k = COL[col or "text"] or COL.text
    self:drawTextRight(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

--- Break a sentence into lines that fit. The engine measures, we split.
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

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

--- The item description the mod already ships, in the player's language.
--
--  Every item record gets a Tooltip_<ShortName> key generated from the same
--  taxonomy the item itself comes from, so there is no new copy to write here
--  and no way for the two to disagree.
local function describeText(info)
    local full = P.itemFor(info.kind, info.mount, info.tier)
    if not full then return nil end
    local short = string.match(full, "^Base%.(.+)$") or full
    local txt = getText("Tooltip_" .. short)
    if txt == "Tooltip_" .. short then return nil end
    return txt
end

--- Label and value rows for whatever this thing is.
local function specRows(obj, info, d)
    local rows = {}
    local function add(k, v, col) rows[#rows + 1] = { k = k, v = v, col = col } end

    if info.kind == "array" then
        local spec = M.arraySpec(info.tier)
        local mount = M.mountSpec(info.mount)
        add(getText("IGUI_OffGrid_InfoModules"), tostring(d.panels or spec.panels))
        add(getText("IGUI_OffGrid_InfoEff"), pct(spec.eff))
        add(getText("IGUI_OffGrid_InfoTilt"),
            string.format("%d deg", math.floor(mount.tilt + 0.5)))
        add(getText("IGUI_OffGrid_InfoFacing"), tostring(info.facing or "S"))
        add(getText("IGUI_OffGrid_InfoCondition"),
            pct((d.condition or 100) / 100),
            (d.condition or 100) < 60 and "warn" or nil)
        if (d.snow or 0) > 0.01 then
            add(getText("IGUI_OffGrid_InfoSnow"), pct(d.snow), "bad")
        end
        if (d.soiling or 0) > 0.01 then
            add(getText("IGUI_OffGrid_InfoDirt"), pct(d.soiling), "warn")
        end
        add(getText("IGUI_OffGrid_InfoBlocks"),
            getText(info.mount == "ground" and "IGUI_OffGrid_InfoYes"
                                           or "IGUI_OffGrid_InfoNo"))
        -- What it is making at this instant, which is the number the player
        -- actually came to look at.
        local sq = obj:getSquare()
        -- Under a roof the controller still counts it and it makes nothing,
        -- and a card that only said "Making now 0 W" left the player to guess
        -- why (live test, 2026-09-14). The simulation's own test (OG_System's
        -- gather), so the card and the controller agree.
        local sunlit = not (sq and E and E.isSunlit) or E.isSunlit(sq)
        if not sunlit then
            add(getText("IGUI_OffGrid_InfoSky"), getText("IGUI_OffGrid_UnderRoof"), "bad")
        end
        if E and E.read and sq then
            local env = E.read()
            env.outputScale = P.sandbox("OutputScale") / 100
            local w = 0
            if sunlit then
                w = M.arrayOutput({ tier = info.tier, mount = info.mount,
                                    facing = info.facing,
                                    panels = d.panels, condition = d.condition,
                                    soiling = d.soiling, snow = d.snow }, env)
            end
            add(getText("IGUI_OffGrid_InfoNow"),
                string.format("%d W", math.floor(w + 0.5)),
                w > 0 and "sun" or "dim")
        end

    elseif info.kind == "bank" then
        local spec = M.bankSpec(info.tier)
        -- Scale and the real temperature, or the card lies twice: with
        -- BankScale under 100 the shown capacity exceeded what the sim
        -- maintains (so Holding read past Capacity), and at -10 C the shown
        -- figure was the summer one.
        local scale = P.bankScale()
        local tempC = (OffGrid.Env and OffGrid.Env.read().temperature) or 20
        add(getText("IGUI_OffGrid_InfoCells"),
            string.format("%d / %d", d.cells or 0, P.cellCap(obj)))
        add(getText("IGUI_OffGrid_InfoPerCell"), string.format("%d Wh", spec.wh))
        -- Capacity and Holding are both what the cells hold, the figure the
        -- charge is shared by and handed back against. Capacity used to be
        -- the cold figure, and in a frost a hard-derating rack in a mixed
        -- system holds more than that, which is right (the cold limits what
        -- a rack takes, not what it keeps) and read as an overfull rack with
        -- Holding printed under it (live test N17, 2026-09-14).
        local nominal = M.bankNominal({ tier = info.tier, scale = scale,
                                        cellList = d.cellList })
        add(getText("IGUI_OffGrid_InfoCapacity"),
            string.format("%.2f kWh", nominal / 1000))
        add(getText("IGUI_OffGrid_InfoCharge"),
            string.format("%.2f / %.2f kWh", (d.charge or 0) / 1000, nominal / 1000),
            "good")
        -- The cold on a line of its own: the capacity the simulation fills
        -- the rack to now. Only while the cold takes something off, so never
        -- from 15 C up and never the Capacity figure over again.
        local cap = M.bankCapacity({ tier = info.tier,
                                     cellSum = P.cellSum(d),
                                     scale = scale }, tempC)
        local takes = string.format("%.2f", cap / 1000)
        if M.coldFactor(tempC, spec.cold) < 1
                and takes ~= string.format("%.2f", nominal / 1000) then
            add(getText("IGUI_OffGrid_InfoColdLimit"),
                P.txt("IGUI_OffGrid_InfoColdLimitValue", takes), "warn")
        end
        add(getText("IGUI_OffGrid_InfoRoundTrip"), pct(spec.eff))
        add(getText("IGUI_OffGrid_InfoCold"), pct(spec.cold))
        add(getText("IGUI_OffGrid_InfoFloor"), pct(spec.dod))
        local bh = P.bankHealth(d)
        add(getText("IGUI_OffGrid_InfoHealth"), pct(bh), bh < 0.95 and "warn" or nil)

    elseif info.kind == "controller" then
        local spec = M.ctrlSpec(info.tier)
        add(getText("IGUI_OffGrid_InfoInverter"), pct(spec.eff))
        add(getText("IGUI_OffGrid_InfoHarvest"),
            spec.harvest > 1 and ("+" .. pct(spec.harvest - 1))
                              or getText("IGUI_OffGrid_InfoNone"))
        local key = d.trip and "IGUI_OffGrid_InfoTripped"
                    or (d.online and d.lvd and "IGUI_OffGrid_InfoLowBatt")
                    or (d.online and "IGUI_OffGrid_InfoOnline"
                                  or "IGUI_OffGrid_InfoOffline")
        add(getText("IGUI_OffGrid_InfoState"), getText(key),
            d.trip and "bad" or (d.online and d.lvd and "warn")
                              or (d.online and "good" or "dim"))
        -- The controller writes these on every tick; they are the same
        -- counts the monitor prints, read from the same fields. d.panels is
        -- the modules that see the sky, and d.shaded the wired arrays under a
        -- roof, which are counted and make nothing: said right under them, or
        -- "3 arrays, 4 modules" read like a rig that should be working (live
        -- test, 2026-09-14). Its own row: on the end of the Arrays line, two-
        -- digit counts ran into the label, and past the window in Turkish.
        add(getText("IGUI_OffGrid_InfoArrays"),
            P.arrayLine(d.arrayCount or 0, d.panels or 0))
        local shaded = math.floor(tonumber(d.shaded) or 0)
        if shaded > 0 then
            add(getText("IGUI_OffGrid_InfoShaded"),
                P.count("IGUI_OffGrid_ArrayCount", shaded), "warn")
        end
        add(getText("IGUI_OffGrid_InfoBanks"),
            P.count("IGUI_OffGrid_BankLine", d.bankCount or 0))
    end

    return rows
end

--- Who this thing is wired to, in words.
local function wiringLines(obj, info, d)
    local out = {}
    local sq = obj:getSquare()
    if not sq then return out end

    local rooted = (info.kind == "controller")
    local sysKey = rooted
        and M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "controller") or d.sys

    if not sysKey then
        out[#out + 1] = { text = getText("IGUI_OffGrid_InfoNoWire"), col = "bad" }
        return out
    end

    -- The level too, whenever the controller stands on another one than this
    -- part: a part wired to a controller on the roof sent a player on the
    -- ground floor to an empty square (live test, 2026-09-14). Said from the
    -- part, "1 floor up", because a z number is shown nowhere else in the game.
    local cx, cy, cz = M.parseNodeKey(sysKey)
    local text
    if rooted then
        text = getText("IGUI_OffGrid_InfoIsSystem")
    elseif cz and cz ~= sq:getZ() then
        text = P.txt("IGUI_OffGrid_InfoSystemAtLevel", cx or 0, cy or 0,
                     P.offsetText(0, 0, sq:getZ(), 0, 0, cz))
    else
        text = P.txt("IGUI_OffGrid_InfoSystemAt", cx or 0, cy or 0)
    end
    out[#out + 1] = { text = text, col = "good" }

    local links = OffGrid.Context.connectionsOf(obj, info)
    if #links == 0 then
        out[#out + 1] = { text = getText("IGUI_OffGrid_InfoNoLinks"), col = "dim" }
        return out
    end
    out[#out + 1] = { text = getText("IGUI_OffGrid_InfoConnected"), col = "dim" }
    for i = 1, #links do
        out[#out + 1] = { text = OffGrid.Context.linkText(obj, links[i].obj),
                          col = "text", indent = true }
    end
    return out
end

function OG_Info:close()
    self:removeFromUIManager()
    OffGrid.Info.current = nil
end

function OG_Info:update()
    ISCollapsableWindow.update(self)
    if not self.object or self.object:getObjectIndex() == -1 then
        self:close()
        return
    end
    self.tick = (self.tick or 0) + 1
    if self.tick % 30 == 0 then self:refresh() end
end

function OG_Info:refresh()
    local info = P.describe(self.object)
    if not info then self:close() return end
    local d = P.data(self.object)

    self.info = info
    self.desc = wrap(describeText(info), WIDTH - PAD * 2 - px(16))
    self.rows = specRows(self.object, info, d)
    -- Wrapped to the card like the description. A connection's line names
    -- the way there now ("Monocrystalline Roof Panel, 1 tile south, 3 tiles
    -- east, 1 floor down"), which runs past the window's edge in one line. A
    -- wrapped connection's later lines sit one step further in.
    self.wired = wiringLines(self.object, info, d)
    self.wiring = {}
    for i = 1, #self.wired do
        local ln = self.wired[i]
        local lines = wrap(ln.text, WIDTH - PAD * 2 - px(16)
                                    - (ln.indent and px(24) or px(12)))
        for n = 1, #lines do
            self.wiring[#self.wiring + 1] = { text = lines[n], col = ln.col,
                                              indent = ln.indent, more = n > 1 }
        end
    end

    -- Grow to whatever this device turned out to have to say. The first
    -- card sits px(13) under the title bar, which is the 30 px top the
    -- fixed layout had (a 17 px bar at the base font) now following the
    -- bar as it grows.
    local h = self:titleBarHeight() + px(13) + PAD
    if #self.desc > 0 then h = h + px(14) + #self.desc * ROW + PAD end
    h = h + px(22) + #self.rows * ROW + PAD
    h = h + px(22) + #self.wiring * ROW + PAD
    self:setHeight(h)
end

function OG_Info:prerender()
    local w = self:getWidth()
    self:drawRect(0, 0, w, self:getHeight(), 0.92, 0.09, 0.10, 0.12)
    ISCollapsableWindow.prerender(self)
    if not self.rows then return end

    local y = self:titleBarHeight() + px(13)
    local inset = PAD + px(8)

    if #self.desc > 0 then
        self:card(PAD, y, w - PAD * 2, px(14) + #self.desc * ROW)
        local ty = y + px(6)
        for i = 1, #self.desc do
            self:text(self.desc[i], inset, ty, "dim")
            ty = ty + ROW
        end
        y = y + px(14) + #self.desc * ROW + PAD
    end

    self:card(PAD, y, w - PAD * 2, px(22) + #self.rows * ROW)
    self:label(getText("IGUI_OffGrid_InfoSpecs"), inset, y + px(5))
    local ry = y + px(22)
    for i = 1, #self.rows do
        self:text(self.rows[i].k, inset, ry, "dim")
        self:textRight(self.rows[i].v, w - inset, ry, self.rows[i].col or "text")
        ry = ry + ROW
    end
    y = y + px(22) + #self.rows * ROW + PAD

    self:card(PAD, y, w - PAD * 2, px(22) + #self.wiring * ROW)
    self:label(getText("IGUI_OffGrid_InfoWiring"), inset, y + px(5))
    local wy = y + px(22)
    for i = 1, #self.wiring do
        local ln = self.wiring[i]
        self:text(ln.text, inset + (ln.indent and px(12) or 0)
                                 + (ln.more and px(12) or 0), wy, ln.col)
        wy = wy + ROW
    end
end

function OG_Info:render()
    -- The parent's render is what puts the title bar and the close button on
    -- screen. An empty override looks harmless and quietly removes both.
    ISCollapsableWindow.render(self)
end

function OG_Info:new(x, y, object)
    local o = ISCollapsableWindow.new(self, x, y, WIDTH, 200)
    o.object = object
    local ci = P.describe(object)
    o.title = ci and getItemNameFromFullType(
        P.itemFor(ci.kind, ci.mount, ci.tier) or "") or getText("ContextMenu_OffGrid")
    o:setResizable(false)
    o.tick = 0
    return o
end

function OffGrid.Info.open(playerObj, object)
    if OffGrid.Info.current then OffGrid.Info.current:close() end
    local x = getPlayerScreenLeft(0) + 90
    local y = getPlayerScreenTop(0) + 90
    local win = OG_Info:new(x, y, object)
    win:initialise()
    win:addToUIManager()
    win:refresh()
    OffGrid.Info.current = win
    return win
end

return OG_Info

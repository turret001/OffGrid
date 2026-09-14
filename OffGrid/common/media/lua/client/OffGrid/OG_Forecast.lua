--[[ OffGrid -- the almanac panel.

     Thirty columns, one per day, drawn in kilowatt-hours rather than in cloud
     fractions. The forecast goes through the same OG_Model the live simulation
     does, fed a different sky, so what the panel promises and what the monitor
     later reports are the same physics and cannot drift apart.

     The horizon is the honest part. A reading is anchored to the day it was
     taken, so the window shrinks by a day per day and the tail is drawn as
     empty slots rather than quietly stopping short. Reading the sky again
     pushes it back out.

     What the bars are measured against depends on what is standing nearby: the
     arrays actually within reach if there are any, and otherwise a single
     standard south-facing ground array as a yardstick. Either way the unit is
     the same and the basis is named on screen.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Env"
require "OffGrid/OG_Almanac"
require "OffGrid/OG_Actions"

OffGrid = OffGrid or {}
local P = OffGrid.Parts
local M = OffGrid.Model
local E = OffGrid.Env
local A = OffGrid.Almanac
local sandbox = P.sandbox

OG_Forecast = ISCollapsableWindow:derive("OG_Forecast")
OffGrid.Forecast = OffGrid.Forecast or {}

-- Laid out from the font heights, like the monitor and the Info panel. B42
-- has no UI scale: a 4K player's fonts come up at 2x to 4x and the window
-- used to stay 520 by 344, stacking the header, the day numbers, the detail
-- card and the Read button on top of one another. Taken at file load, which
-- is safe since fonts only change through a full Lua reset.
local FH = getTextManager():getFontHeight(UIFont.Small)
local FM = getTextManager():getFontHeight(UIFont.Medium)
local S = math.max(1, FH / 16)
local function px(v) return math.floor(v * S + 0.5) end

local WIDTH = px(520)
local PAD = px(12)
local GAP = px(8)
-- ISCollapsableWindow:titleBarHeight() is max(16, Small + 1)
local TITLE = math.max(16, FH + 1)
local HDR = FH + px(18)                      -- header card
local CHART = px(128) + FH + px(12)          -- bars, then the day numbers
local PLOT = CHART - FH - px(12)
local DETAIL = px(8) + FM + px(4) + FH + px(8)
local BTN_H = FH + px(8)
local BASIS_Y = TITLE + GAP + HDR + GAP + CHART + GAP + DETAIL + GAP
local HEIGHT = BASIS_Y + FH + GAP + BTN_H + PAD

local COL = {
    bg    = { 0.09, 0.10, 0.12 },
    panel = { 0.14, 0.15, 0.18 },
    line  = { 0.28, 0.30, 0.34 },
    text  = { 0.86, 0.88, 0.91 },
    dim   = { 0.55, 0.58, 0.63 },
    good  = { 0.42, 0.78, 0.48 },
    warn  = { 0.85, 0.65, 0.28 },
    bad   = { 0.80, 0.35, 0.30 },
    sun   = { 0.95, 0.78, 0.32 },
    cool  = { 0.42, 0.62, 0.88 },
}

-- Same rule as the monitor: a Lua multi-return collapses to one value anywhere
-- but the final argument slot, so c() is only ever safe as the last thing
-- passed. drawRect and drawRectBorder take colour last. drawText does not.
local function c(name) local k = COL[name]; return k[1], k[2], k[3] end

local function fmtWh(wh)
    if wh >= 1000 then return string.format("%.1f kWh", wh / 1000) end
    return string.format("%d Wh", math.floor(wh + 0.5))
end

----------------------------------------------------------------- the basis

-- The yardstick when nothing is wired in nearby: one standard ground array,
-- pointed south, in perfect condition. A real object the player can build, so
-- the number means something rather than being a bare irradiance figure.
local function yardstick()
    return {
        arrays = { { facing = "S", mount = "ground", tier = "standard",
                     panels = M.arraySpec("standard").panels,
                     condition = 100, soiling = 0, snow = 0 } },
        inverterEff = M.ctrlSpec("basic").eff,
        harvest = M.ctrlSpec("basic").harvest,
        own = false,
    }
end

--- The system within reach of the player: its arrays, and its own controller.
--  Resolved once when the panel opens: a square sweep is not something to run
--  every frame, and the answer cannot change while the player stands reading.
--
--  ONE system. The sweep is a net: it used to credit every wired array in
--  reach whichever controller it fed, next door's included, and to take the
--  MPPT harvest if any controller in reach was an MPPT, so two neighbouring
--  rigs each saw the pair's output with the better controller's gain on top.
--  The arrays are grouped by the system they report, the largest group is
--  the basis, and its tier is read off that system's controller.
--
--  An array under a roof is counted and forecast nothing, as the simulation
--  counts it (OG_System gather, E.isSunlit) and the controller's card prints
--  it: the almanac used to forecast its modules as if it saw the sky, so it
--  promised more than the monitor's DAY page then recorded, beside a card
--  saying "Under a roof: 1 array" (review, 2026-09-14).
local function systemNear(playerObj)
    local sq = playerObj and playerObj:getCurrentSquare()
    if not sq then return yardstick() end
    local radius = sandbox("LinkRadius")

    local found = P.findParts(sq, radius, 1, "array")
    if not found or #found == 0 then return yardstick() end

    local groups, order = {}, {}
    for i = 1, #found do
        local ai = P.describe(found[i])
        local ad = P.data(found[i])
        -- Only what is wired into a system: loose panels feed nothing.
        local key = ad.sys
        local cx, cy, cz = M.parseNodeKey(key)
        local ctrl = cx and P.objectAt(cx, cy, cz, "controller")
        -- a square that is loaded and holds no controller: a stale claim
        local stale = cx and getSquare and getSquare(cx, cy, cz) and not ctrl
        if ai and cx and not stale then
            local grp = groups[key]
            if not grp then
                local ci = ctrl and P.describe(ctrl)
                grp = { arrays = {}, panels = 0, count = 0,
                        tier = (ci and ci.tier == "mppt") and "mppt" or "basic" }
                groups[key] = grp
                order[#order + 1] = key
            end
            grp.count = grp.count + 1
            if E.isSunlit(found[i]:getSquare()) then
                local n = ad.panels or M.arraySpec(ai.tier).panels
                grp.arrays[#grp.arrays + 1] = {
                    facing = ai.facing, mount = ai.mount, tier = ai.tier,
                    panels = n, condition = ad.condition or 100,
                    soiling = ad.soiling or 0, snow = ad.snow or 0 }
                grp.panels = grp.panels + n
            end
        end
    end
    local best = nil
    for k = 1, #order do
        local grp = groups[order[k]]
        if not best or grp.panels > best.panels then best = grp end
    end
    if not best then return yardstick() end

    local spec = M.ctrlSpec(best.tier)
    return { arrays = best.arrays, inverterEff = spec.eff, harvest = spec.harvest,
             own = true, count = best.count, panels = best.panels }
end

----------------------------------------------------------------- lifecycle

function OG_Forecast:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.closeButton:setOnClick(function() self:close() end)

    local label = getText("IGUI_OffGrid_ReadSky")
    local bw = math.max(px(130),
                        getTextManager():MeasureStringX(UIFont.Small, label) + px(20))
    local bh = BTN_H
    self.readBtn = ISButton:new(WIDTH - PAD - bw, HEIGHT - PAD - bh, bw, bh,
                                label, self, OG_Forecast.onRead)
    self.readBtn:initialise()
    self.readBtn:instantiate()
    self:addChild(self.readBtn)
end

function OG_Forecast:close()
    self:removeFromUIManager()
    local t = OffGrid.Forecast.byPlayer
    if t and self.playerNum ~= nil and t[self.playerNum] == self then
        t[self.playerNum] = nil
    end
end

function OG_Forecast:onRead()
    local pl = self.player
    if not pl or A.blocked(pl) then return end
    ISTimedActionQueue.add(OG_ReadSky:new(pl))
    self:close()
end

function OG_Forecast:update()
    ISCollapsableWindow.update(self)
    if not self.player or self.player:isDead() then
        self:close()
        return
    end
    self.tick = (self.tick or 0) + 1
    -- Thirty days of the full irradiance model is not free: 30 days of 24
    -- hourly steps per array, which on a large rig cost tens to hundreds of
    -- milliseconds. It used to be rebuilt every 60 frames regardless, a stall
    -- every second for as long as the window stayed open. Now the slow beat
    -- only ASKS whether anything it reads has changed.
    if not self.snap or (self.tick % 60 == 0 and self:inputKey() ~= self.snapKey) then
        self:refresh()
    end
    local why = A.blocked(self.player)
    self.readBtn:setEnable(why == nil)
    self.readBtn.tooltip = why and getText(why) or nil
end

--- Everything refresh() reads that can change while the window is open: the
--  reading itself (a new one is a new table), the calendar day the horizon
--  slides by, the ground snow the model's albedo takes, the sandbox output
--  scale, and the season settings every card's engine day is built from
--  (latitude, configured noon, the day-night cycle; an admin can change the
--  cycle on a live server, GameServer.java:1690-1703). The system is fixed
--  when the window opens.
function OG_Forecast:inputKey()
    local pl = self.player
    local rec = A.record(pl)
    local base = E.read()
    local lat, noon, cycle = E.skyParams()
    return table.concat({
        rec and tostring(rec) or "none",
        tostring(rec and rec.day or -1),
        tostring(E.dayIndex()),
        tostring(math.floor((base.groundSnow or 0) * 20 + 0.5)),
        tostring(sandbox("OutputScale")),
        tostring(lat), tostring(noon), tostring(cycle),
    }, "|")
end

function OG_Forecast:refresh()
    self.snapKey = self:inputKey()
    local pl = self.player
    local reach = A.reach(pl)
    local sys = self.sys or yardstick()
    local base = E.read()
    base.outputScale = sandbox("OutputScale") / 100

    local days, total, peak, known = {}, 0, 0, 0
    for off = 0, M.FORECAST_SPAN do
        local sky = (off <= reach) and A.skyAt(pl, off) or nil
        local wh = 0
        if sky then
            wh = M.forecastYield(sys, sky, base, 60)
            total = total + wh
            known = known + 1
            if wh > peak then peak = wh end
        end
        local y, m, d = E.dateAt(off)
        days[off + 1] = { sky = sky, wh = wh, year = y, month = m, day = d }
    end

    self.snap = { days = days, total = total, peak = peak,
                  known = known, reach = reach, age = A.age(pl) }
end

------------------------------------------------------------------- drawing

function OG_Forecast:card(x, y, w, h)
    self:drawRect(x, y, w, h, 0.9, c("panel"))
    self:drawRectBorder(x, y, w, h, 0.5, c("line"))
end

function OG_Forecast:text(str, x, y, col, font)
    local k = COL[col or "text"]
    self:drawText(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

function OG_Forecast:textRight(str, x, y, col, font)
    local k = COL[col or "text"]
    self:drawTextRight(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

--- Which colour a day reads as at a glance.
--
--  Deliberately not a cloud ramp. The bar's HEIGHT already says how much sun
--  a day carries, so shading clear against partly cloudy would repeat that in
--  a second channel and leave the chart looking busy. What colour is for here
--  is the kind of day it is: a wet one, or one to keep the bank full for.
local function skyColour(sky)
    if not sky then return "dim" end
    if sky.blizzard or sky.tropical or sky.storm then return "bad" end
    if sky.rain then return "cool" end
    if (sky.cloud or 0) > 0.65 then return "dim" end
    return "sun"
end

function OG_Forecast:prerender()
    ISCollapsableWindow.prerender(self)
    local s = self.snap
    if not s then return end

    local w = self:getWidth()
    local y = self:titleBarHeight() + GAP
    local inner = w - PAD * 2
    local ink = px(8)
    local ty = math.floor((HDR - FH) / 2)

    ------------------------------------------------------------------ header
    self:card(PAD, y, inner, HDR)
    if s.reach < 0 then
        self:text(getText("IGUI_OffGrid_AlmanacEmpty"), PAD + ink, y + ty, "dim")
    else
        self:text(P.count("IGUI_OffGrid_AlmanacAhead", s.reach), PAD + ink, y + ty,
                  s.reach <= 3 and "warn" or "text")
        self:textRight(P.count("IGUI_OffGrid_AlmanacTotal", s.known,
                               fmtWh(s.total), s.known),
                       w - PAD - ink, y + ty, "dim")
    end
    y = y + HDR + GAP

    ------------------------------------------------------------------- chart
    local gh = CHART
    local gx, gy = PAD, y
    local gw = inner
    self:drawRect(gx, gy, gw, gh, 1, 0.06, 0.07, 0.09)

    local n = M.FORECAST_SPAN + 1
    local colw = gw / n
    local scale = math.max(1, s.peak)
    local plot = PLOT

    local mx, my = self:getMouseX(), self:getMouseY()
    local hover = nil
    if self:isMouseOver() and my >= gy and my <= gy + gh
            and mx >= gx and mx < gx + gw then
        hover = math.floor((mx - gx) / colw) + 1
        if hover < 1 or hover > n then hover = nil end
    end
    self.hover = hover

    for i = 1, n do
        local dd = s.days[i]
        local x = gx + (i - 1) * colw
        local bw = math.max(2, colw - 2)
        if dd.sky then
            local h = (dd.wh / scale) * plot
            local col = COL[skyColour(dd.sky)]
            self:drawRect(x + 1, gy + plot - h + 4, bw, math.max(1, h), 0.92,
                          col[1], col[2], col[3])
        else
            -- Past the horizon. An empty slot, not a missing column: the
            -- almanac should look like it stops rather than like it ends.
            self:drawRectBorder(x + 1, gy + plot - px(6) + 4, bw, px(6), 0.35, c("line"))
        end
        if hover == i then
            self:drawRect(x, gy, colw, gh, 0.10, c("text"))
        end
    end

    -- Today, and the week marks after it.
    for i = 1, n, 5 do
        local x = gx + (i - 1) * colw
        self:drawRect(x, gy + plot + 4, 1, px(5), 0.6, c("line"))
        self:text(tostring(s.days[i].day), x + 2, gy + plot + px(7), "dim")
    end
    self:drawRectBorder(gx, gy, gw, gh, 0.6, c("line"))
    y = y + gh + GAP

    ------------------------------------------------------------------ detail
    local pick = s.days[self.hover or 1]
    self:card(PAD, y, inner, DETAIL)
    local title = P.txt("IGUI_OffGrid_AlmanacDate", pick.day,
                        E.monthName(pick.month))
    if (self.hover or 1) == 1 then
        title = title .. "   " .. getText("IGUI_OffGrid_AlmanacToday")
    end
    local line2 = y + px(8) + FM + px(4)
    self:text(title, PAD + ink, y + px(8), "text", UIFont.Medium)
    if pick.sky then
        self:text(getText(A.skyLabel(pick.sky)), PAD + ink, line2,
                  skyColour(pick.sky))
        self:textRight(fmtWh(pick.wh), w - PAD - ink, y + px(8), "sun", UIFont.Medium)
        self:textRight(P.txt("IGUI_OffGrid_AlmanacTemp",
                             math.floor((pick.sky.tempMin or 0) + 0.5),
                             math.floor((pick.sky.tempMax or 0) + 0.5)),
                       w - PAD - ink, line2, "dim")
    else
        self:text(getText("IGUI_OffGrid_SkyUnknown"), PAD + ink, line2, "dim")
    end
    y = y + DETAIL + GAP

    ------------------------------------------------------------------- basis
    if self.sys and self.sys.own then
        self:text(P.arrayLine(self.sys.count, self.sys.panels),
                  PAD + px(2), y, "dim")
    else
        self:text(getText("IGUI_OffGrid_AlmanacYardstick"), PAD + px(2), y, "dim")
    end
end

function OG_Forecast:render()
    ISCollapsableWindow.render(self)
end

------------------------------------------------------------------- opening

function OG_Forecast:new(x, y, playerObj)
    local o = ISCollapsableWindow.new(self, x, y, WIDTH, HEIGHT)
    o.player = playerObj
    o.title = getText("IGUI_OffGrid_Almanac")
    o:setResizable(false)
    o.backgroundColor = { r = COL.bg[1], g = COL.bg[2], b = COL.bg[3], a = 0.92 }
    o.borderColor = { r = COL.line[1], g = COL.line[2], b = COL.line[3], a = 1 }
    o.tick = 0
    o.sys = systemNear(playerObj)
    return o
end

OG_Forecast.LAYOUT = { WIDTH = WIDTH, HEIGHT = HEIGHT, PAD = PAD,
                       BASIS_Y = BASIS_Y, BTN_H = BTN_H, SCALE = S }

--- The open window for a player, if there is one.
function OffGrid.Forecast.windowFor(playerObj)
    local t = OffGrid.Forecast.byPlayer
    local n = playerObj and playerObj.getPlayerNum and playerObj:getPlayerNum() or 0
    return t and t[n] or nil
end

--- Toggle the almanac for THIS player. Split screen has one per player, on
--  that player's own quarter of the screen: a single shared window used to
--  open on player one's screen and a second player's button closed it.
function OffGrid.Forecast.open(playerObj)
    local n = playerObj and playerObj.getPlayerNum and playerObj:getPlayerNum() or 0
    OffGrid.Forecast.byPlayer = OffGrid.Forecast.byPlayer or {}
    local cur = OffGrid.Forecast.byPlayer[n]
    if cur then
        cur:close()
        return nil
    end
    local x = getPlayerScreenLeft(n) + px(80)
    local y = getPlayerScreenTop(n) + px(80)
    -- Pulled back on screen when the scaled window would run off it, as
    -- OffGrid.Window.open does. getCore is engine-only, hence the guard.
    if getCore and getCore() then
        local ok, sw, sh = pcall(function()
            return getCore():getScreenWidth(), getCore():getScreenHeight()
        end)
        if ok and sw and sh then
            x = math.max(0, math.min(x, sw - WIDTH))
            y = math.max(0, math.min(y, sh - HEIGHT))
        end
    end
    local win = OG_Forecast:new(x, y, playerObj)
    win.playerNum = n
    win:initialise()
    win:addToUIManager()
    win:refresh()
    OffGrid.Forecast.byPlayer[n] = win
    return win
end

--- Register the taught token in vanilla's own list of non-craft abilities.
--
--  ISLiteratureUI.miscRecipes is exactly this case: a table of things a book
--  can teach that are not recipes, keyed by the taught string and carrying an
--  icon and a tooltip. Herbalist, Generator and the three Mechanics tiers all
--  live here. Without a row, the almanac's tooltip and the read-book menu show
--  the raw token instead.
local function registerMiscRecipe()
    if not ISLiteratureUI or not ISLiteratureUI.miscRecipes then return end
    ISLiteratureUI.miscRecipes[A.TOKEN] = {
        tooltip = "Tooltip_Recipe_OffGridSkyReading",
        icon = "Item_OffGridAlmanac",
    }
end

Events.OnGameStart.Add(registerMiscRecipe)

return OG_Forecast

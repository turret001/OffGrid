--[[ OffGrid -- the OG-1200 panel.

     The controller's screen, built as the machine it claims to be: a charcoal
     bezel with corner screws, a five-lamp LED cluster, a green STN LCD with
     four membrane keys under it, and the rotary main isolator on its own pale
     plate. 1:1 with the approved mockup (docs: the OG-1200 artifact), which
     is why there is no vanilla title bar -- the bezel IS the chrome, dragging
     comes from ISPanel.moveWithMouse, and closing is the drawn X.

     Reading order for anyone changing this file:
       * Everything visual happens in prerender(); the only children are
         INVISIBLE ISButtons laid over drawn controls for clicks. Draw first,
         click surfaces on top, never the other way around.
       * All LCD text uses the Code* fonts, which are the engine's monospace
         family -- that is what makes the screen read as a screen.
       * A Lua multi-return collapses to its first value anywhere but the
         final argument slot, so c() is only ever safe as the LAST argument
         (drawRect takes colour last; drawText does not, hence text()).
       * The DAY page is HISTORY. A controller records what it received; the
         forecasting fiction belongs to the almanac and stays there.
       * Every pixel literal goes through px(). The face is laid out in the
         base font set's pixels and scaled by S, so a 4K player on the 4x
         fonts gets the same face at the size their text already is.
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Env"

OffGrid = OffGrid or {}
local P = OffGrid.Parts
local M = OffGrid.Model
local E = OffGrid.Env

OG_Window = ISPanel:derive("OG_Window")
OffGrid.Window = OffGrid.Window or {}

------------------------------------------------------------------- palette

local COL = {
    abs      = { 0.149, 0.157, 0.172 },      -- bezel body
    absdk    = { 0.106, 0.110, 0.122 },      -- recesses
    edge     = { 0.063, 0.067, 0.075 },      -- bezel outline
    hi       = { 0.30, 0.31, 0.34 },         -- top highlight line
    label    = { 0.784, 0.792, 0.816 },      -- stamped labels
    dim      = { 0.482, 0.494, 0.525 },      -- secondary labels
    amber    = { 0.957, 0.725, 0.259 },      -- brand accent / warnings
    lcd      = { 0.059, 0.110, 0.063 },      -- screen ground
    lcdoff   = { 0.043, 0.071, 0.047 },      -- screen ground, dark
    ink      = { 0.620, 0.890, 0.490 },      -- screen phosphor
    inkdim   = { 0.620, 0.890, 0.490 },      -- used at low alpha
    platein  = { 0.149, 0.153, 0.169 },      -- text on the pale plate
}

local function c(name) local k = COL[name]; return k[1], k[2], k[3] end

local TEXCACHE = {}
local function tex(name)
    local t = TEXCACHE[name]
    if t == nil then
        t = getTexture("media/ui/OffGrid/" .. name) or false
        TEXCACHE[name] = t
    end
    return t or nil
end

------------------------------------------------------------------- layout

-- The game has no UI scale. Options > Font Size loads a different font set
-- and every UIFont grows with it (CodeSmall is 16 px in the base set, 38 in
-- the 4x set a 4K player defaults to), so a face fixed in base pixels put
-- 4x text on top of itself. S is the ratio the loaded fonts bear to the base
-- set, taken at file load, which is safe because fonts only change through
-- a full Lua reset. At the base size S is 1 and px() is the identity, so
-- the approved face is untouched there.
local S = math.max(1, getTextManager():getFontHeight(UIFont.CodeSmall) / 16)
local function px(v) return math.floor(v * S + 0.5) end

local W = px(560)
local PAD = px(26)                  -- bezel inset
local BRAND_H = px(44)
local LCD_W, LCD_H = px(372), px(252)
local KEY_W, KEY_H, KEY_GAP = px(84), px(30), px(8)
local COLX = PAD + LCD_W + px(18)   -- right column x
local COL_W = px(116)
local MID_Y = px(18) + BRAND_H
local KEYS_Y = MID_Y + LCD_H + px(10)
local SERIAL_Y = KEYS_Y + KEY_H + px(14)
local H = SERIAL_Y + px(24)

-- Read by the headless suite, so its bounds follow the face instead of
-- repeating the base-size numbers.
OG_Window.SCALE = S
OG_Window.LAYOUT = { W = W, H = H, PAD = PAD, LCD_W = LCD_W, LCD_H = LCD_H,
                     MID_Y = MID_Y, KEYS_Y = KEYS_Y }

local PAGES = { "status", "loads", "batt", "day" }
local PAGE_KEY = {
    status = "IGUI_OffGrid_PgStatus", loads = "IGUI_OffGrid_PgLoads",
    batt = "IGUI_OffGrid_PgBatt", day = "IGUI_OffGrid_PgDay",
}

------------------------------------------------------------------- helpers

local function fmtW(w)
    if w >= 10000 then return string.format("%.1f kW", w / 1000) end
    return string.format("%d W", math.floor(w + 0.5))
end

local function fmtWh(wh)
    if wh >= 10000 then return string.format("%.1f kWh", wh / 1000) end
    return string.format("%d Wh", math.floor(wh + 0.5))
end

function OG_Window:text(str, x, y, col, font, alpha)
    local k = COL[col or "ink"]
    self:drawText(str, x, y, k[1], k[2], k[3], alpha or 1, font or UIFont.CodeSmall)
end

function OG_Window:textRight(str, x, y, col, font, alpha)
    local k = COL[col or "ink"]
    self:drawTextRight(str, x, y, k[1], k[2], k[3], alpha or 1,
                       font or UIFont.CodeSmall)
end

function OG_Window:textCentre(str, x, y, col, font, alpha)
    local k = COL[col or "ink"]
    self:drawTextCentre(str, x, y, k[1], k[2], k[3], alpha or 1,
                        font or UIFont.CodeSmall)
end

local function fontH(font)
    return getTextManager():getFontHeight(font)
end

-- The hero figure. CodeLarge is 26 px in the base font set and the approved
-- face reads at 40, so the digits are baked white (num_0..num_9) and tinted
-- here like any other lamp; they scale with S like the rest of the face.
-- Digits only; the units next to it stay real text.
local NUM_W, NUM_H = px(24), px(40)
function OG_Window:bigNum(str, x, y, col, alpha)
    local k = COL[col or "ink"]
    local cx = x
    for i = 1, #str do
        local t = tex("num_" .. str:sub(i, i) .. ".png")
        if t then
            self:drawTextureScaled(t, cx, y, NUM_W, NUM_H, alpha or 1,
                                   k[1], k[2], k[3])
            cx = cx + NUM_W
        else
            self:text(str:sub(i, i), cx, y + NUM_H - fontH(UIFont.CodeLarge),
                      col, UIFont.CodeLarge, alpha)
            cx = cx + getTextManager():MeasureStringX(UIFont.CodeLarge,
                                                      str:sub(i, i))
        end
    end
    return cx
end

----------------------------------------------------------------- lifecycle

function OG_Window:createChildren()
    -- Invisible click surfaces only; every visible pixel is prerender's.
    local function ghost(x, y, w, h, fn)
        local b = ISButton:new(x, y, w, h, "", self, fn)
        b:initialise()
        b:instantiate()
        b.background = false
        -- background=false is NOT enough: ISButton:prerender gates on
        -- displayBackground, and on mouseOver shouldDrawBackground ignores
        -- `background` entirely and paints backgroundColorMouseOver -- an
        -- opaque grey box that swallowed the knob and keys under the cursor.
        b.displayBackground = false
        b.isHighlightedBackgroundVisible = false
        b.backgroundColorMouseOver = { r = 0, g = 0, b = 0, a = 0 }
        b.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        b.textColor = { r = 0, g = 0, b = 0, a = 0 }
        self:addChild(b)
        return b
    end

    self.closeBtn = ghost(W - px(30), 0, px(30), px(26), OG_Window.onClose)
    self.knobBtn = ghost(COLX, MID_Y, COL_W, px(112), OG_Window.onPowerToggle)
    self.keyBtns = {}
    for i = 1, #PAGES do
        local b = ghost(PAD + (i - 1) * (KEY_W + KEY_GAP), KEYS_Y,
                        KEY_W, KEY_H, OG_Window.onPageKey)
        b.pageName = PAGES[i]
        self.keyBtns[i] = b
    end
end

function OG_Window:onClose()
    self:close()
end

function OG_Window:close()
    self:removeFromUIManager()
    OffGrid.Window.current = nil
end

function OG_Window:onPowerToggle()
    local playerObj = getSpecificPlayer(0)
    if not playerObj or not self.object then return end
    local on = not (self.snap and self.snap.online)
    if OffGrid.Context and OffGrid.Context.onBreaker then
        OffGrid.Context.onBreaker(nil, self.object, playerObj, on)
    end
end

function OG_Window:onPageKey(button)
    self.page = button.pageName or "status"
end

function OG_Window:update()
    ISPanel.update(self)
    if not self.object or self.object:getObjectIndex() == -1 then
        self:close()
        return
    end
    self.tick = (self.tick or 0) + 1
    if self.tick % 6 == 0 or not self.snap then
        self:refresh()
    end
end

--- Pull the live numbers off the controller's ModData.
--  Everything the pages draw is read here, ONCE per beat, never mid-draw.
function OG_Window:refresh()
    local d = P.data(self.object)
    local env = E.read()
    local snap = {
        online = d.online and not d.trip,
        powered = d.powered == true,
        trip = d.trip or false,
        lvd = d.lvd == true,
        -- Only a shed the bank really ran into is stamped. A rig with no
        -- cells is shed too, but it comes back the moment cells go in, so
        -- promising "back at 25%" there was simply untrue.
        lvdAt = d.lvdAt,
        lvdSoc = d.lvdSoc or M.lvdThreshold(d.dod),
        gen = d.gen or 0,
        load = d.load or 0,
        demand = d.demand or 0,
        soc = d.soc or 0,
        charge = d.charge or 0,
        capacity = d.capacity or 0,
        health = d.health or 1,
        equalise = d.equalise or false,
        equaliseToday = d.equaliseToday or 0,
        cells = d.cells or 0,
        cellCap = d.cellCap or 0,
        -- The floor on the gauge's own scale, which the controller writes
        -- every tick: the grade's floor from 15 C up, higher in the cold,
        -- where the load really drops (OG_Model.step). A controller that has
        -- not ticked under this build yet has only its grade's floor.
        dod = d.floorSoc or d.dod or M.DAMAGE_SOC,
        coldWatts = d.coldWatts or 0,
        coldHours = d.coldHours or 0,
        coldSafe = d.coldSafe ~= false,
        loadList = d.loadList,
        bankCells = d.bankCells,
        dayHist = d.dayHist,
        env = env,
    }
    snap.net = snap.gen - snap.load
    -- Charging is the model's own rule: a surplus, and room in the bank for
    -- it. A full bank clips its surplus and charges nothing.
    snap.charging = snap.net > 0 and (snap.capacity - snap.charge) > 0.01
    -- The tick's own want-predicate, so STARTING UP is only ever promised
    -- when the system can actually deliver a start.
    snap.starting = snap.online and not snap.powered and not snap.lvd
        and snap.cells > 0 and (snap.gen > 0 or snap.charge > 0)
    self.snap = snap
end

------------------------------------------------------------------ the face

function OG_Window:prerender()
    local s = self.snap
    if not s then return end
    self.blink = math.floor((self.tick or 0) / 18) % 2 == 0

    -- bezel
    self:drawRect(0, 0, W, H, 1, c("abs"))
    self:drawRectBorder(0, 0, W, H, 1, c("edge"))
    self:drawRect(px(1), px(1), W - px(2), px(1), 0.5, c("hi"))
    local sc = tex("screw.png")
    if sc then
        local sw = px(14)
        self:drawTextureScaled(sc, px(8), px(8), sw, sw, 1, 1, 1, 1)
        self:drawTextureScaled(sc, px(8), H - px(22), sw, sw, 1, 1, 1, 1)
        self:drawTextureScaled(sc, W - px(22), H - px(22), sw, sw, 1, 1, 1, 1)
    end
    -- The close X owns the top-right corner where the fourth screw would
    -- sit. Drawn anywhere nearer the lamps it reads as a sixth indicator
    -- ("X FAULT"), which is exactly what it did on the first shoot.
    self:text("X", W - px(20), px(6), "dim", UIFont.Small)

    self:drawBrand(s)
    self:drawLCD(s)
    self:drawKeys(s)
    self:drawColumn(s)

    -- serial strip; the model follows the actual tier like the brand row
    local ser = (self.tier == "mppt") and "OG-1200-MPPT" or "OG-1200"
    self:text(ser .. "  SER 2026-0248", PAD, SERIAL_Y, "dim",
              UIFont.CodeSmall, 0.7)
    self:textRight("12/24V  60A  IP54", W - PAD, SERIAL_Y, "dim",
                   UIFont.CodeSmall, 0.7)
end

--- The LED cluster's lamps, left to right, for a snapshot.
--
--  Each lamp says one thing about the machine. SOLAR, CHARGE and EQUAL used
--  to light only while the house had power, so a shed bank charging in full
--  sun showed a dark cluster, and a player asking "is it charging?" was told
--  no (live test, 2026-09-14). They follow the arrays, the bank and the
--  equaliser now; only LOAD waits on the house, and only a switched-off face
--  is dark, as its LCD is. BOOT blinks amber through the start-up hold so the
--  wait reads as the machine working, not broken; FAULT means faults and
--  nothing else.
function OG_Window.lamps(s)
    return {
        { lab = "BOOT",   lit = s.starting, col = "a", blink = true },
        { lab = "SOLAR",  lit = s.online and s.gen > 0, col = "g" },
        { lab = "CHARGE", lit = s.online and s.charging, col = "g" },
        { lab = "LOAD",   lit = s.powered and s.load > 0, col = "g" },
        { lab = "EQUAL",  lit = s.online and s.equalise, col = "a" },
        { lab = "FAULT",  lit = s.trip, col = "r", blink = true },
    }
end

function OG_Window:drawBrand(s)
    self:text("OFF-GRID SYSTEMS", PAD, px(10), "dim", UIFont.Small)
    -- the model stamp, white with the amber tier suffix, as approved
    self:text("OG-1200", PAD, px(22), "label", UIFont.Large)
    if self.tier == "mppt" then
        local mw = getTextManager():MeasureStringX(UIFont.Large, "OG-1200 ")
        self:text("MPPT", PAD + mw, px(22), "amber", UIFont.Large)
    end

    -- The LED cluster, right-aligned.
    local lamps = OG_Window.lamps(s)
    local pitch, led = px(44), px(21)
    local x0 = W - PAD - #lamps * pitch
    for i = 1, #lamps do
        local L = lamps[i]
        local lx = x0 + (i - 1) * pitch + px(22)
        local lit = L.lit and (not L.blink or self.blink)
        local t = tex(lit and ("led_" .. L.col .. ".png") or "led_off.png")
        if t then
            self:drawTextureScaled(t, lx - px(10), px(10), led, led, 1, 1, 1, 1)
        end
        self:textCentre(L.lab, lx, px(32), "dim", UIFont.NewSmall)
    end
end

------------------------------------------------------------------ the LCD

function OG_Window:drawLCD(s)
    local x, y = PAD, MID_Y
    local litGround = s.online and "lcd" or "lcdoff"
    self:drawRect(x, y, LCD_W, LCD_H, 1, c(litGround))
    self:drawRectBorder(x, y, LCD_W, LCD_H, 1, 0, 0, 0)

    if s.online then
        local page = self.page or "status"
        local ix, iy = x + px(14), y + px(12)
        if page == "status" then self:pageStatus(s, ix, iy)
        elseif page == "loads" then self:pageLoads(s, ix, iy)
        elseif page == "batt" then self:pageBatt(s, ix, iy)
        else self:pageDay(s, ix, iy) end
    end

    local ov = tex("lcd_overlay.png")
    if ov then
        self:drawTextureScaled(ov, x, y, LCD_W, LCD_H, 1, 1, 1, 1)
    end
end

--- The LCD header line every page shares: state left, clock right, unless
--  a page has something better than the clock (BATT shows its cell count).
function OG_Window:lcdHeader(s, x, y, titleKey, rightStr)
    local iw = LCD_W - px(28)
    self:text(getText(titleKey), x, y, "ink", UIFont.CodeSmall, 0.85)
    self:textRight(rightStr or string.format("%02d:%02d",
                                             math.floor(s.env.hour),
                                             math.floor((s.env.hour % 1) * 60)),
                   x + iw, y, "ink", UIFont.CodeSmall)
    return y + fontH(UIFont.CodeSmall) + px(4)
end

function OG_Window:stateKey(s)
    -- The LCD's own copy: drawn in a Code font, see build_translations.py.
    if s.trip then return "IGUI_OffGrid_TrippedLcd" end
    if not s.online then return "IGUI_OffGrid_Offline" end
    if s.lvd then return "IGUI_OffGrid_LowBatt" end
    if s.starting then return "IGUI_OffGrid_StartingUp" end
    if s.gen > 0 then return "IGUI_OffGrid_Generating" end
    return "IGUI_OffGrid_OnBattery"
end

function OG_Window:pageStatus(s, x, y)
    local iw = LCD_W - px(28)
    y = self:lcdHeader(s, x, y, self:stateKey(s))

    -- The disconnect says WHY and WHEN, where FAULT alone said nothing.
    if s.lvd and s.lvdAt ~= nil then
        self:text(P.txt("IGUI_OffGrid_LoadShed",
                        math.floor(s.lvdSoc * 100 + 0.5)),
                  x, y, "ink", UIFont.CodeSmall, 0.85)
        y = y + fontH(UIFont.CodeSmall) + px(2)
    end

    -- the big number: load being served
    local big = tostring(math.floor(s.load + 0.5))
    local cx = self:bigNum(big, x, y + px(2), "ink")
    local uy = y + px(2) + NUM_H - fontH(UIFont.CodeMedium) - px(4)
    self:text(getText("IGUI_OffGrid_WLoad"), cx + px(10), uy,
              "ink", UIFont.CodeMedium, 0.8)
    self:textRight(string.format("%+d W", math.floor(s.net + 0.5)), x + iw,
                   uy, "ink", UIFont.CodeMedium)
    y = y + NUM_H + px(10)

    -- the flow nodes: PV >> BATT / LOADS << EQ
    local nw = math.floor((iw - px(60)) / 2)
    local nh = px(40)
    local function node(nx, ny, lab, val)
        self:drawRectBorder(nx, ny, nw, nh, 0.25, c("ink"))
        self:textCentre(lab, nx + nw / 2, ny + px(4), "ink", UIFont.CodeSmall, 0.8)
        self:textCentre(val, nx + nw / 2, ny + px(4) + fontH(UIFont.CodeSmall),
                        "ink", UIFont.CodeMedium)
    end
    local function wire(nx, ny, live, flip)
        local a = live and 0.9 or 0.25
        -- The guillemets exist in the Code faces (char 171/187), but the
        -- lexer buffers string BYTES and decodes them as UTF-8
        -- (LexState.newstring), so a bare \187 is malformed and renders
        -- as '?'. Escape the UTF-8 byte pair instead.
        self:textCentre(flip and "\194\171\194\171\194\171"
                        or "\194\187\194\187\194\187", nx, ny,
                        "ink", UIFont.CodeSmall, a)
    end
    node(x, y, "PV", fmtW(s.gen))
    wire(x + nw + px(30), y + px(12), s.gen > 0, false)
    node(x + nw + px(60), y, "BATT", string.format("%d %%",
         math.floor(s.soc * 100 + 0.5)))
    y = y + nh + px(8)
    node(x, y, "LOADS", fmtW(s.load))
    wire(x + nw + px(30), y + px(12), s.load > 0, true)
    node(x + nw + px(60), y, "EQ", s.equalise
         and fmtWh(s.equaliseToday) or "--")
end

local COMPRESSOR = { fridge = true, freezer = true, fridgefreezer = true }

function OG_Window:pageLoads(s, x, y)
    local iw = LCD_W - px(28)
    y = self:lcdHeader(s, x, y, "IGUI_OffGrid_PgLoads")
    local list = s.loadList
    local rowH = fontH(UIFont.CodeSmall) + px(3)
    local starred = false
    local I = OffGrid.Interop
    if (not list or #list == 0) and I and I.lgeeTakeover and I.lgeeTakeover() then
        -- Nothing in reach because another mod took the reach away: LG
        -- Extended Electricity's range takeover leaves the controller one tile
        -- (OG_Interop). Said where the empty list is, or the page reads as a
        -- broken monitor, which is how it was reported (2026-09-15).
        y = y + px(6)
        for _, key in ipairs({ "IGUI_OffGrid_LgeeReach", "IGUI_OffGrid_LgeeSets",
                               "IGUI_OffGrid_LgeeSeeInfo" }) do
            self:text(getText(key), x, y, "ink", UIFont.CodeSmall,
                      key == "IGUI_OffGrid_LgeeReach" and 0.9 or 0.7)
            y = y + rowH
        end
    elseif not list or #list == 0 then
        -- Nothing listed yet, or nothing in reach. The mark takes its own
        -- line: drawn in place in the taller CodeMedium, it sat on top of
        -- TOTAL on the rail below.
        self:text("--", x, y + px(6), "ink", UIFont.CodeMedium, 0.6)
        y = y + px(6) + fontH(UIFont.CodeMedium)
    else
        for i = 1, math.min(#list, 9) do
            local e = list[i]
            local lab = getText("IGUI_OffGrid_Load_" .. tostring(e.k))
            -- refrigeration never idles by choice; the star says so
            if COMPRESSOR[e.k] then
                lab = lab .. " *"
                starred = true
            end
            local a = e.idle and 0.45 or 1
            self:text(e.idle and "[ ]" or "[#]", x, y, "ink",
                      UIFont.CodeSmall, e.idle and 0.45 or 0.8)
            self:text(lab, x + px(34), y, "ink", UIFont.CodeSmall, a)
            self:textRight(fmtW(e.w), x + iw, y, "ink", UIFont.CodeSmall, a)
            y = y + rowH
        end
    end
    -- total rail
    y = y + px(3)
    self:drawRect(x, y, iw, px(1), 0.35, c("ink"))
    y = y + px(4)
    -- The pages only draw while the switch is on, so an unpowered TOTAL is a
    -- shed or a start-up far more often than anything else, and OFFLINE said
    -- neither.
    local why = (s.lvd and "IGUI_OffGrid_LowBatt")
        or (s.starting and "IGUI_OffGrid_StartingUp")
        or (not s.powered and "IGUI_OffGrid_Offline") or nil
    local tot = getText("IGUI_OffGrid_Total")
        .. (why and (" (" .. getText(why) .. ")") or "")
    self:text(tot, x, y, "ink", UIFont.CodeSmall)
    self:textRight(fmtW(s.demand), x + iw, y, "ink", UIFont.CodeSmall)
    if starred then
        y = y + rowH
        self:textRight(getText("IGUI_OffGrid_Compressor"), x + iw, y,
                       "ink", UIFont.CodeSmall, 0.55)
    end
end

function OG_Window:pageBatt(s, x, y)
    local iw = LCD_W - px(28)
    y = self:lcdHeader(s, x, y, "IGUI_OffGrid_BattHeader",
                       P.txt("IGUI_OffGrid_CellCount", s.cells))

    local big = tostring(math.floor(s.soc * 100 + 0.5))
    local cx2 = self:bigNum(big, x, y + px(2), "ink")
    self:text("% SOC", cx2 + px(10),
              y + px(2) + NUM_H - fontH(UIFont.CodeMedium) - px(4),
              "ink", UIFont.CodeMedium, 0.8)
    -- one unit for the pair, the way the approved face prints it
    local wh
    if s.capacity < 10000 then
        wh = string.format("%d / %d Wh", math.floor(s.charge + 0.5),
                           math.floor(s.capacity + 0.5))
    else
        wh = fmtWh(s.charge) .. " / " .. fmtWh(s.capacity)
    end
    self:textRight(wh, x + iw, y + px(2) + NUM_H - fontH(UIFont.CodeSmall) - px(4),
                   "ink", UIFont.CodeSmall)
    y = y + NUM_H + px(8)

    -- SOC bar with the DOD floor tick
    self:drawRectBorder(x, y, iw, px(14), 0.9, c("ink"))
    self:drawRect(x + px(1), y + px(1),
                  math.max(0, (iw - px(2)) * M.clamp(s.soc, 0, 1)),
                  px(12), 0.85, c("ink"))
    local dx = x + math.floor(iw * M.clamp(s.dod, 0, 1))
    self:drawRect(dx, y - px(3), px(1), px(20), 0.8, c("ink"))
    y = y + px(20)
    self:text(P.txt("IGUI_OffGrid_DodFloor",
                    math.floor(s.dod * 100 + 0.5)), x, y, "ink",
              UIFont.CodeSmall, 0.7)
    y = y + fontH(UIFont.CodeSmall) + px(8)

    -- per-cell condition blocks
    local cells = s.bankCells
    if cells and #cells > 0 then
        local n = #cells
        local gap = px(5)
        local cw = math.floor((iw - (n - 1) * gap) / n)
        for i = 1, n do
            local ccx = x + (i - 1) * (cw + gap)
            self:drawRectBorder(ccx, y, cw, px(30), 0.25, c("ink"))
            self:textCentre(tostring(cells[i]), ccx + cw / 2, y + px(2), "ink",
                            UIFont.CodeSmall)
            local fw = math.floor((cw - px(8)) * M.clamp(cells[i] / 100, 0, 1))
            self:drawRect(ccx + px(4), y + px(22), fw, px(3), 0.9, c("ink"))
        end
    else
        self:text(P.txt("IGUI_OffGrid_BankHeader", s.cells, s.cellCap),
                  x, y, "ink", UIFont.CodeSmall, 0.7)
    end
    -- bottom-right of the LCD, like the approved face
    self:textRight(getText("IGUI_OffGrid_CellCond"), x + iw,
                   MID_Y + LCD_H - px(14) - fontH(UIFont.CodeSmall), "ink",
                   UIFont.CodeSmall, 0.5)
end

function OG_Window:pageDay(s, x, y)
    local iw = LCD_W - px(28)
    y = self:lcdHeader(s, x, y, "IGUI_OffGrid_ReceivedToday")

    -- What actually came in, hour bucket by hour bucket, midnight to now.
    -- Nothing past the marker is drawn, because nothing past the marker has
    -- happened: a controller records, it does not forecast.
    local hist = s.dayHist or {}
    local nowH = s.env.hour
    local ch = px(128)
    local peak = 1
    for i = 1, 24 do
        local v = hist[i]
        if type(v) == "number" and v > peak then peak = v end
    end
    local base = y + ch
    -- The filled trace, like the approved face: 2 px columns under a bright
    -- edge, linearly interpolated between the hourly bucket centres, and
    -- nothing at all past the marker -- history stops where the day has.
    local function at(hour)
        local u = hour - 0.5
        local i0 = math.floor(u) + 1
        local f = u - math.floor(u)
        local v0 = (i0 >= 1 and i0 <= 24) and (hist[i0] or 0) or 0
        local v1 = (i0 + 1 >= 1 and i0 + 1 <= 24) and (hist[i0 + 1] or 0) or 0
        return v0 + (v1 - v0) * f
    end
    local span = math.floor(iw * M.clamp(nowH / 24, 0, 1))
    local cw = px(2)
    for tx = 0, span - cw, cw do
        local v = at((tx + cw / 2) / iw * 24)
        local hgt = math.floor(ch * M.clamp(v / peak, 0, 1))
        if hgt > 0 then
            self:drawRect(x + tx, base - hgt, cw, hgt, 0.3, c("ink"))
            self:drawRect(x + tx, base - hgt - px(1), cw, cw, 0.9, c("ink"))
        end
    end
    -- baseline and the now-marker
    self:drawRect(x, base, iw, px(1), 0.45, c("ink"))
    local mx = x + math.floor(iw * M.clamp(nowH / 24, 0, 1))
    for my = y, base, px(4) do
        self:drawRect(mx, my, px(1), px(2), 0.8, c("ink"))
    end
    y = base + px(4)
    for i, lab in ipairs({ "00", "06", "12", "18", "24" }) do
        local lx = x + math.floor(iw * (i - 1) / 4)
        if i == 1 then self:text(lab, lx, y, "ink", UIFont.CodeSmall, 0.75)
        elseif i == 5 then self:textRight(lab, lx, y, "ink", UIFont.CodeSmall, 0.75)
        else self:textCentre(lab, lx, y, "ink", UIFont.CodeSmall, 0.75) end
    end
    y = y + fontH(UIFont.CodeSmall) + px(2)
    local total = 0
    for i = 1, 24 do total = total + (hist[i] or 0) end
    self:text(P.txt("IGUI_OffGrid_SinceMidnight", fmtWh(total)), x, y,
              "ink", UIFont.CodeSmall, 0.85)
end

------------------------------------------------------------------ the keys

function OG_Window:drawKeys(s)
    local page = self.page or "status"
    for i = 1, #PAGES do
        local kx = PAD + (i - 1) * (KEY_W + KEY_GAP)
        local lit = PAGES[i] == page
        local t = tex(lit and "key_lit.png" or "key_norm.png")
        if t then
            self:drawTextureScaled(t, kx, KEYS_Y, KEY_W, KEY_H, 1, 1, 1, 1)
        else
            self:drawRect(kx, KEYS_Y, KEY_W, KEY_H, 1, c("absdk"))
        end
        self:textCentre(getText(PAGE_KEY[PAGES[i]]), kx + KEY_W / 2,
                        KEYS_Y + math.floor((KEY_H - fontH(UIFont.NewSmall)) / 2),
                        lit and "label" or "dim", UIFont.NewSmall)
    end
end

--------------------------------------------------------------- the column

function OG_Window:drawColumn(s)
    -- the isolator plate: one baked frame per state
    local t = tex(s.online and "plate_on.png" or "plate_off.png")
    if t then
        self:drawTextureScaled(t, COLX, MID_Y, COL_W, px(112), 1, 1, 1, 1)
    end
    self:textCentre(getText("IGUI_OffGrid_Isolator"), COLX + COL_W / 2,
                    MID_Y + px(114), "dim", UIFont.NewSmall)

    -- the trip lamp: a square window, like the approved face
    local ty = MID_Y + px(132)
    local th, sq = px(30), px(10)
    self:drawRect(COLX, ty, COL_W, th, 1, c("absdk"))
    self:drawRectBorder(COLX, ty, COL_W, th, 1, c("edge"))
    local lit = s.trip and self.blink
    self:drawRect(COLX + px(8), ty + sq, sq, sq, 1,
                  lit and 0.898 or 0.23, lit and 0.282 or 0.24,
                  lit and 0.302 or 0.26)
    self:drawRectBorder(COLX + px(8), ty + sq, sq, sq, 1, c("edge"))
    self:text(getText("IGUI_OffGrid_Tripped"), COLX + px(26),
              ty + math.floor((th - fontH(UIFont.NewSmall)) / 2), "dim",
              UIFont.NewSmall)

    -- the sticker
    local sy = ty + px(38)
    local st = tex("sticker.png")
    if st then
        self:drawTextureScaled(st, COLX, sy, COL_W, px(34), 1, 1, 1, 1)
    end
    local ink = COL.platein
    self:drawTextCentre(getText("IGUI_OffGrid_Sticker1"), COLX + COL_W / 2,
                        sy + px(4), ink[1], ink[2], ink[3], 1, UIFont.NewSmall)
    self:drawTextCentre(getText("IGUI_OffGrid_Sticker2"), COLX + COL_W / 2,
                        sy + px(16), ink[1], ink[2], ink[3], 1, UIFont.NewSmall)
end

------------------------------------------------------------------- opening

function OG_Window:new(x, y, object)
    local o = ISPanel.new(self, x, y, W, H)
    o.object = object
    o.moveWithMouse = true
    o.background = false
    local ci = P.describe(object)
    o.tier = ci and ci.tier or "basic"
    o.page = "status"
    o.tick = 0
    return o
end

function OffGrid.Window.open(playerObj, object)
    if OffGrid.Window.current then
        OffGrid.Window.current:close()
    end
    local x = getPlayerScreenLeft(0) + px(60)
    local y = getPlayerScreenTop(0) + px(60)
    -- The 4x face is 1330 px wide, so on anything under the full screen it
    -- is pulled back until the keys and the close X are on screen. getCore
    -- is engine-only and the headless suite has none, hence the guard.
    if getCore and getCore() then
        local ok, sw, sh = pcall(function()
            return getCore():getScreenWidth(), getCore():getScreenHeight()
        end)
        if ok and sw and sh then
            x = math.max(0, math.min(x, sw - W))
            y = math.max(0, math.min(y, sh - H))
        end
    end
    local win = OG_Window:new(x, y, object)
    win:initialise()
    win:addToUIManager()
    win:refresh()
    OffGrid.Window.current = win
    return win
end

return OG_Window

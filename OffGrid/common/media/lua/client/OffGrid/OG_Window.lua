--[[ OffGrid -- the OG-1200 panel.

     The controller's screen, built as the machine it claims to be: a charcoal
     bezel with corner screws, a five-lamp LED cluster, a green STN LCD with
     five membrane keys under it, and the rotary main isolator on its own pale
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
       * The GEN page's buttons are the only click surfaces that come and
         go: genVisibility shows them on that page of a live controller
         only, over switches and boxes drawn from the same GEN rectangles.
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
local KEY_H, KEY_GAP = px(30), px(8)
-- Five keys and four gaps span the LCD exactly: 5 x 68 + 4 x 8 = 372 at the
-- base size. Worked out from the LCD, not written as px(68): rounding at the
-- 4x set makes px(68) 162 and px(8) 19, a row of 886 under an 884 px screen.
-- Floored, a scaled row can only come out a pixel or two short. The 84x30
-- key texture is drawn at this width (drawKeys scales it).
local KEY_W = math.floor((LCD_W - 4 * KEY_GAP) / 5)
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

-- GEN is last, so the four older keys keep their places (and the panel test
-- its child indices). It is always there, with or without a generator.
local PAGES = { "status", "loads", "batt", "day", "gen" }
local PAGE_KEY = {
    status = "IGUI_OffGrid_PgStatus", loads = "IGUI_OffGrid_PgLoads",
    batt = "IGUI_OffGrid_PgBatt", day = "IGUI_OffGrid_PgDay",
    gen = "IGUI_OffGrid_PgGen",
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

--- How wide a string actually is in a font.
--
--  The engine measures it; the fallback is the same glyph model the panel test
--  uses, for a headless run where getTextManager is stubbed out. Layout that
--  guesses at this is layout that crams: the cell grid sized its blocks from a
--  hand-picked 24 px and drew 24.1 px blocks under 27 px numbers.
local function textW(str, font)
    local tm = getTextManager and getTextManager()
    if tm and tm.MeasureStringX then
        local ok, w = pcall(tm.MeasureStringX, tm, font or UIFont.CodeSmall,
                            tostring(str))
        if ok and type(w) == "number" and w > 0 then return w end
    end
    local tm2 = getTextManager and getTextManager()
    local h = tm2 and tm2:getFontHeight(font or UIFont.CodeSmall) or 12
    return #tostring(str) * math.floor(h * 0.6)
end

local function fontH(font)
    return getTextManager():getFontHeight(font)
end

-------------------------------------------------------------- the GEN page

-- The GEN page's controls, laid out once at file load like the keys, as Can
-- signed them off on the GEN mockup and revised them on 2026-09-28 ("Add
-- horizontal lines between generators"; "one button for Auto and one button
-- for Start/Stop ... They should work like switches"; "instead of run, it
-- should be ON/OFF"): the invisible buttons (createChildren) and the
-- switches and boxes pageGen draws under them have to be the same
-- rectangles, so both read them from here. All of it is px() and the Code
-- font's own height, so it scales with the face.
--
--   GENERATORS                                          [AUTO [==#]]
--   START AT 35%   [-][+]      STOP AT 90%                    [-][+]
--   ----------------------------------------------------------------
--   LECTROMAX  RUNNING                    3120 W   [AUTO] [ ON/OFF ]
--   7.5 L +40.0 L  0.21 L/h  226 h  COND 88%       [ ==#] [    ==# ]
--   ................................................................
--   VALUTECH  STANDBY                              [AUTO] [ ON/OFF ]
--   10.0 L +0.0 L  0.00 L/h  -- h  COND 100%       [ ==#] [ #      ]
--   (two lines and two switches per generator, a fainter rule between
--    one generator and the next, four generators at most)
--   ----------------------------------------------------------------
--   TODAY 4200 Wh  0.9 L
--
-- A switch spans both of its generator's lines: its fixed label on top, the
-- slider under it (knob right on a lit track: ON; knob left: OFF). The
-- master AUTO is one line high, its slider beside its label. A whole switch
-- glows while it is ON and dims while it is OFF, and a generator's ON/OFF
-- is greyed, fainter still, while that generator's own AUTO is on
-- (genSwitch).
local GEN = {}
do
    local fh = fontH(UIFont.CodeSmall)
    local x0, y0 = PAD + px(14), MID_Y + px(12)     -- every page's origin
    local iw = LCD_W - px(28)
    local boxH = fh + px(2)
    GEN.x, GEN.iw, GEN.fh = x0, iw, fh
    GEN.headY = y0
    GEN.frame = px(2)                               -- a switch's border
    GEN.master = { x = x0 + iw - px(84), y = y0 - px(1), w = px(84), h = boxH }
    GEN.levelY = y0 + fh + px(8)
    local half, bw, gap = math.floor(iw / 2), px(22), px(4)
    local by = GEN.levelY - px(1)
    GEN.startMinus = { x = x0 + half - px(8) - 2 * bw - gap, y = by, w = bw, h = boxH }
    GEN.startPlus = { x = x0 + half - px(8) - bw, y = by, w = bw, h = boxH }
    GEN.stopX = x0 + half + px(8)
    GEN.stopMinus = { x = x0 + iw - 2 * bw - gap, y = by, w = bw, h = boxH }
    GEN.stopPlus = { x = x0 + iw - bw, y = by, w = bw, h = boxH }
    GEN.ruleY = GEN.levelY + fh + px(4)
    -- Every rule, the levels' and the ones between generators, has the same
    -- air each side, so a generator's lines and switches sit between two.
    local air = px(3)
    GEN.rowsY = GEN.ruleY + px(1) + air
    GEN.lineB = fh + px(2)                          -- a row's second line
    GEN.swH = GEN.lineB + fh                        -- a switch: both lines
    GEN.rowH = GEN.swH + air + px(1) + air
    -- Each switch holds the longest label it carries in either language
    -- inside its frame at the game's own glyph widths (6 px a glyph at the
    -- base size, 14 at the 4x set). ON/OFF is as wide as the Turkish AC/KAPA
    -- with its C-cedilla (7 glyphs; ON/OFF is 6). AUTO is px(34), the width
    -- Can approved in the first round: at px(28) AUTO (4 glyphs; the Turkish
    -- OTO is 3) filled the frame edge to edge and looked cramped at the 38
    -- px set; at px(34) it keeps at least half a glyph of air either side.
    -- The pair is 12 px wider than the AUTO and RUN pair of the first round,
    -- so the fullest lines lose trailing figures: genLine drops what does
    -- not fit, and tests/test_machine.py pins exactly which at the base and
    -- 4x sizes. The switch `run` is the ON/OFF one (it sends bkRun).
    local autoW, powerW, swGap = px(34), px(46), px(4)
    GEN.rows = {}
    for i = 1, 4 do
        local ry = GEN.rowsY + (i - 1) * GEN.rowH
        local runX = x0 + iw - powerW
        local autoX = runX - swGap - autoW
        GEN.rows[i] = {
            y = ry,
            auto = { x = autoX, y = ry, w = autoW, h = GEN.swH },
            run = { x = runX, y = ry, w = powerW, h = GEN.swH },
            textR = autoX - px(6),                  -- where its lines end
            ruleY = ry + GEN.swH + air,             -- the rule under it
        }
    end
    GEN.footY = MID_Y + LCD_H - px(12) - fh
end

-- LIGHTS OFF on the LOADS page (Can, 2026-10-02), where the other pages keep
-- the clock: on GEN's master switch's row, wide enough for IŞIKLARI KAPAT.
local LIGHTS = { x = GEN.x + GEN.iw - px(112), y = GEN.headY - px(1),
                 w = px(112), h = GEN.fh + px(2) }

-- A generator's state word (K.unitState, as the server's bkRows carry it)
-- and the LCD's word for it.
local GEN_STATE = {
    running = "IGUI_OffGrid_GenRun", standby = "IGUI_OffGrid_GenStandby",
    off = "IGUI_OffGrid_GenOff", nofuel = "IGUI_OffGrid_GenNoFuel",
    fault = "IGUI_OffGrid_GenFault", indoors = "IGUI_OffGrid_GenIndoors",
    server = "IGUI_OffGrid_GenServer",
}
-- The brands' LCD names: the keys OffGrid.Backup.BRANDS[tier].lcd holds,
-- spelled out here so test_content holds each one to the Code-font list
-- (test_machine checks the two agree).
local GEN_BRAND = {
    valutech = "IGUI_OffGrid_BrandValuTech", old = "IGUI_OffGrid_BrandOld",
    lectromax = "IGUI_OffGrid_BrandLectromax", premium = "IGUI_OffGrid_BrandPremium",
}

--- A string cut to a width, so a long translation shortens a label rather
--  than running out of its box or off the LCD. It cuts whole UTF-8
--  characters: the Code fonts keep Turkish letters such as C-cedilla, two
--  bytes each, and half of one draws as '?'.
local function fit(str, w, font)
    str = tostring(str)
    while #str > 0 and textW(str, font) > w do
        local n = #str
        while n > 1 and string.byte(str, n) >= 128 and string.byte(str, n) < 192 do
            n = n - 1
        end
        str = string.sub(str, 1, n - 1)
    end
    return str
end

--- Words laid into lines no wider than w (OG_Info's wrap, in an LCD font).
local function wrap(str, w, font)
    local out, line = {}, ""
    for word in string.gmatch(tostring(str or ""), "%S+") do
        local try = (line == "") and word or (line .. " " .. word)
        if textW(try, font) > w and line ~= "" then
            out[#out + 1] = fit(line, w, font)
            line = word
        else
            line = try
        end
    end
    if line ~= "" then out[#out + 1] = fit(line, w, font) end
    return out
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

    -- The GEN page's buttons, AFTER the keys so the child indices the panel
    -- test reads stay put: the master AUTO switch, Start at - and +, Stop at
    -- - and +, then each generator row's AUTO and ON/OFF switches. Hidden
    -- until genVisibility finds the GEN page up on a live controller.
    local function genGhost(r, cmd, dir, row)
        local b = ghost(r.x, r.y, r.w, r.h, OG_Window.onGenButton)
        b.genCmd, b.genDir, b.genRow = cmd, dir, row
        b:setVisible(false)
        return b
    end
    self.genBtns = {
        genGhost(GEN.master, "bkMaster"),
        genGhost(GEN.startMinus, "bkLevelStart", -1),
        genGhost(GEN.startPlus, "bkLevelStart", 1),
        genGhost(GEN.stopMinus, "bkLevelStop", -1),
        genGhost(GEN.stopPlus, "bkLevelStop", 1),
    }
    for i = 1, #GEN.rows do
        local g = GEN.rows[i]
        self.genBtns[#self.genBtns + 1] = genGhost(g.auto, "bkAuto", nil, i)
        self.genBtns[#self.genBtns + 1] = genGhost(g.run, "bkRun", nil, i)
    end

    -- LIGHTS OFF, after the GEN buttons for the same reason; hidden until
    -- genVisibility finds the LOADS page up on a live controller.
    self.lightsBtn = ghost(LIGHTS.x, LIGHTS.y, LIGHTS.w, LIGHTS.h, OG_Window.onLightsOff)
    self.lightsBtn:setVisible(false)
end

function OG_Window:onClose()
    self:close()
end

function OG_Window:close()
    self:removeFromUIManager()
    OffGrid.Window.current = nil
end

--- Why this player may not throw the main isolator, or nil: the
--  controller's pick-up lock (Can, 2026-09-29: "Lock them in 3.0.0"),
--  OG_Place's G.useRefusal, the question OG_ResetBreaker's completion asks
--  again on the authority. Nil where OG_Place is not loaded. Reading the
--  panel asks nothing.
function OG_Window:rigLock(playerObj)
    local G = OffGrid.Place
    if not (playerObj and self.object and G and G.useRefusal) then return nil end
    return G.useRefusal(playerObj, P.try(self.object, "getSquare"), self.object)
end

--- The knob. For a player the controller's lock refuses it is drawn greyed
--  (drawColumn) and does nothing but put the reason above him in the
--  warning colour: he is not walked over to be refused.
function OG_Window:onPowerToggle()
    local playerObj = getSpecificPlayer(0)
    if not playerObj or not self.object then return end
    local why = self:rigLock(playerObj)
    if why then
        P.haloNote(playerObj, getText(why), true)
        return
    end
    local on = not (self.snap and self.snap.online)
    if OffGrid.Context and OffGrid.Context.onBreaker then
        OffGrid.Context.onBreaker(nil, self.object, playerObj, on)
    end
end

--- LIGHTS OFF. For a player the controller's lock refuses it is drawn
--  greyed (pageLoads) and a press only puts the reason above him in the
--  warning colour, walking him nowhere, as the knob does.
function OG_Window:onLightsOff()
    local playerObj = getSpecificPlayer(0)
    if not playerObj or not self.object or not (self.snap and self.snap.online) then return end
    local why = self:rigLock(playerObj)
    if why then
        P.haloNote(playerObj, getText(why), true)
        return
    end
    local C = OffGrid.Context
    if C and C.onLightsOff then C.onLightsOff(playerObj, self.object) end
end

function OG_Window:onPageKey(button)
    self.page = button.pageName or "status"
    self:genVisibility()
end

--- The GEN page's buttons exist only where their switches and boxes are
--  drawn: on the GEN page of a live controller, and a generator's two
--  switches only while its row does. Re-applied on every refresh and page
--  change, so a generator cut away, or a controller switched off, takes its
--  buttons with it.
function OG_Window:genVisibility()
    -- LIGHTS OFF: on the LOADS page of a live controller only.
    local lb = self.lightsBtn
    if lb then
        local s0 = self.snap
        local want = s0 ~= nil and s0.online == true and (self.page or "status") == "loads"
        if lb:isVisible() ~= want then lb:setVisible(want) end
    end
    local btns = self.genBtns
    if not btns then return end
    local s = self.snap
    local up = s ~= nil and s.online == true and (self.page or "status") == "gen"
    local rows = s and s.bkRows
    for i = 1, #btns do
        local b = btns[i]
        local want = up and (b.genRow == nil
            or (type(rows) == "table" and rows[b.genRow] ~= nil))
        want = want == true
        if b:isVisible() ~= want then b:setVisible(want) end
    end
end

-- A switch press in flight. A switch asks for the opposite of what it
-- shows, and what it shows is the controller's copy, pushed by the server;
-- a second press before that copy shows the first one's result would ask
-- for the same thing again, or, on a picture half caught up, the reverse
-- (live campaign on 42.21, 2026-09-28: a press meant as a start came out as
-- a stop). So a switch whose press is in flight takes no second one. It is
-- in flight until GEN shows what it asked for, and at most GEN_HOLD_MS
-- real milliseconds after the short action carrying it left the player's
-- queue: long enough for the server's push to arrive, short enough that a
-- press the server refused (Start on an empty tank, a walk cancelled) does
-- not hold the switch for long. The level boxes are steps, every press
-- meant, and are never held.
OG_Window.GEN_HOLD_MS = 3000
local GEN_SWITCH = { bkMaster = true, bkAuto = true, bkRun = true }

local function nowMs()
    return getTimestampMs and getTimestampMs() or 0
end

--- Whose GEN controls these are (Can, 2026-09-29: "Owner's group only").
--  The master AUTO and Start at / Stop at are the controller's; a
--  generator's AUTO and ON/OFF are its own when it stands in memory here,
--  else its controller's, as the authority asks them (BK.unlocked). The
--  reason is OG_Backup's K.lockRefusal, or nil; nil too where OG_Backup is
--  not loaded.
local function unitAt(r)
    if type(r) ~= "table" or not getSquare then return nil end
    local x, y, z = tonumber(r.x), tonumber(r.y), tonumber(r.z)
    if not (x and y and z) then return nil end
    return P.objectAt(x, y, z, "backup")
end

function OG_Window:genLock(playerObj, row)
    local K = OffGrid.Backup
    if not (playerObj and self.object and K and K.lockRefusal) then return nil end
    return K.lockRefusal(playerObj, (row and unitAt(row)) or self.object)
end

--- Does the snapshot show what a press in flight asked for? A generator
--  gone from the page has nothing left to hold.
local function genShows(p, s)
    if p.cmd == "bkMaster" then return s.bkAuto == p.want end
    local rows = s.bkRows
    if type(rows) ~= "table" then return true end
    for i = 1, #GEN.rows do
        local r = rows[i]
        if r == nil then break end
        if type(r) == "table" and r.k == p.k then
            if p.cmd == "bkAuto" then return (r.auto == true) == p.want end
            return (r.s == "running") == p.want
        end
    end
    return true
end

--- Bring the presses in flight up to date with the snapshot: one GEN now
--  shows is done; one whose action is still queued is restamped, so its
--  hold counts from when the action left the queue; one past its hold is
--  let go. Called on every refresh and before a press is judged.
function OG_Window:genTrack()
    local held = self.genHeld
    local s = self.snap
    if not held or not s then return end
    local now = nowMs()
    local Q = ISTimedActionQueue
    local done = {}
    for key, p in pairs(held) do
        if genShows(p, s) then
            done[#done + 1] = key
        elseif p.act ~= nil and Q and Q.hasAction and Q.hasAction(p.act) then
            p.seen = now
        elseif now - p.seen >= OG_Window.GEN_HOLD_MS then
            done[#done + 1] = key
        end
    end
    for i = 1, #done do held[done[i]] = nil end
end

--- A GEN button: a switch asks for the state opposite the one it shows (the
--  master and a row's AUTO flip that Auto, ON/OFF starts a stopped
--  generator and stops a running one), a level box steps its level. Sent
--  the way the menu sends it (C.onBackupPanel walks the player over and
--  queues a short action at the controller whose completion sends it), as
--  the knob goes through onBreaker. An ON/OFF switch drawn greyed, its
--  generator's own AUTO on, sends nothing: the server would refuse it
--  (K.handRefusal), so the player is not walked over for a no. Nor does a
--  switch whose last press is still in flight (genTrack). Nor does any
--  button the owner's lock refuses this player (genLock, asked now, before
--  anything else as the authority asks it): it is drawn greyed, and a press
--  puts the reason above him in the warning colour instead.
function OG_Window:onGenButton(button)
    local playerObj = getSpecificPlayer(0)
    local s = self.snap
    local C = OffGrid.Context
    if not playerObj or not self.object or not s or not s.online
            or not (C and C.onBackupPanel) then
        return
    end
    local cmd, row, value = button.genCmd, nil, nil
    if button.genRow then
        row = type(s.bkRows) == "table" and s.bkRows[button.genRow] or nil
        if not row then return end
    end
    local why = self:genLock(playerObj, row)
    if why then
        P.haloNote(playerObj, getText(why), true)
        return
    end
    if cmd == "bkMaster" then value = not s.bkAuto
    elseif cmd == "bkLevelStart" or cmd == "bkLevelStop" then value = button.genDir
    elseif cmd == "bkAuto" then value = not row.auto
    elseif cmd == "bkRun" then
        if row.auto == true then return end        -- greyed (genRow)
        value = row.s ~= "running"
    else return end
    local key = nil
    if GEN_SWITCH[cmd] then
        key = cmd .. "|" .. tostring(row and row.k or "")
        self:genTrack()
        if self.genHeld and self.genHeld[key] then return end
    end
    local act = C.onBackupPanel(playerObj, self.object, cmd,
                                row and row.x, row and row.y, row and row.z, value)
    if key then
        self.genHeld = self.genHeld or {}
        self.genHeld[key] = { cmd = cmd, k = row and row.k, want = value, act = act,
                              seen = nowMs() }
    end
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
        -- The backup generators, from the controller's mirror under bk*
        -- names: gen stays solar watts, and so do SOLAR, PV and DAY.
        bkW = d.bkW or 0,
        bkCap = d.bkCap or 0,
        bkN = d.bkN or 0,
        bkRows = d.bkRows,
        bkAuto = d.bkAuto ~= false,
        bkWhToday = d.bkWhToday or 0,
        bkFuelToday = d.bkFuelToday or 0,
    }
    -- The levels as the server last clamped them. Before it has written any
    -- (nothing cabled yet) the model gives the same answer from the same
    -- fields, and it gives the ends of both ranges for GEN's - and +.
    local lvStart, lvStop, lvEff, lvLo, lvHi = M.backupLevels(d.dod or M.DAMAGE_SOC,
                                                              d.floorSoc, d.bkStart, d.bkStop)
    snap.bkStart = d.bkStartNow or lvStart
    snap.bkStop = d.bkStopNow or lvStop
    snap.bkLo, snap.bkHi = lvLo, lvHi
    -- Can chose to see where Auto really starts (2026-09-29, "Approved, show
    -- real start"): M.backupLevels' eff, never under 5 points above the
    -- cut-off, which rises in the cold. The - and + still step (and dim
    -- against) the level he set, snap.bkStart.
    snap.bkStartShown = math.max(snap.bkStart, lvEff)
    -- What the house nets: the sun and the generators in, the load out.
    snap.net = snap.gen + snap.bkW - snap.load
    -- Charging is the model's own rule: a surplus, and room in the bank for
    -- it. A full bank clips its surplus and charges nothing.
    snap.charging = snap.net > 0 and (snap.capacity - snap.charge) > 0.01
    -- The tick's own want-predicate (holdPower), so STARTING UP is only ever
    -- promised when the system can actually deliver a start. A running
    -- generator can start a rig with no cells, so it counts for both.
    snap.starting = snap.online and not snap.powered and not snap.lvd
        and (snap.cells > 0 or snap.bkCap > 0)
        and (snap.gen > 0 or snap.charge > 0 or snap.bkCap > 0)
    -- How many of its generators GEN shows RUNNING: STATUS reads GEN RUNNING
    -- while any does, whatever it delivers.
    snap.bkRunning = 0
    -- Which of GEN's controls the owner's lock refuses this player (genLock):
    -- the controller's (lock), and each generator's (bkLocks[i]). Drawn
    -- greyed; asked again at a press.
    local who = getSpecificPlayer and getSpecificPlayer(0)
    -- and whether the controller's lock refuses him the main isolator
    -- (rigLock; Can, 2026-09-29: "Lock them in 3.0.0"), drawn greyed
    snap.rigLock = self:rigLock(who) or false
    snap.lock = self:genLock(who, nil) or false
    snap.bkLocks = {}
    if type(snap.bkRows) == "table" then
        for i = 1, #GEN.rows do
            local r = snap.bkRows[i]
            if r == nil then break end
            if type(r) == "table" and r.s == "running" then
                snap.bkRunning = snap.bkRunning + 1
            end
            if type(r) == "table" then snap.bkLocks[i] = self:genLock(who, r) or false end
        end
    end
    self.snap = snap
    self:genTrack()
    self:genVisibility()
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
        elseif page == "gen" then self:pageGen(s, ix, iy)
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
    -- A running generator outranks the sun: it is what the player pays
    -- petrol for, and gen alone would call a night charge ON BATTERY. Running
    -- is enough, delivering or not: one idling on a full bank with nothing
    -- switched on gives 0 W and still burns its idle petrol (live campaign on
    -- 42.21, 2026-09-28: STATUS said GENERATING while GEN said RUNNING).
    if (s.bkRunning or 0) > 0 then return "IGUI_OffGrid_GenRunning" end
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
    -- the title, and LIGHTS OFF where the other pages keep the clock; greyed
    -- for a player the controller's lock refuses (s.rigLock)
    local hf = UIFont.CodeSmall
    self:text(fit(getText("IGUI_OffGrid_PgLoads"), LIGHTS.x - x - px(8), hf),
              x, y, "ink", hf, 0.85)
    self:genBox(LIGHTS, getText("IGUI_OffGrid_LightsOff"), false, s.rigLock and 0.35 or 1)
    y = y + fontH(hf) + px(4)
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
        -- However many the server sent: it caps the list to what fits and
        -- puts what did not into a final row of its own, rather than leaving
        -- the client to drop rows the total still counts.
        for i = 1, #list do
            local e = list[i]
            if e.more then
                self:text("...", x, y, "ink", UIFont.CodeSmall, 0.45)
                self:text(P.txt("IGUI_OffGrid_LoadMore", e.more),
                          x + px(34), y, "ink", UIFont.CodeSmall, 0.45)
                self:textRight(fmtW(e.w), x + iw, y, "ink",
                               UIFont.CodeSmall, 0.45)
            else
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
            end
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

    -- Per-cell condition blocks, wrapped.
    --
    --  Banks chain, so the cell count is not bounded by one rack's bays: a
    --  sixteen-cell bank divided the row into slivers too narrow to read the
    --  three digits each block exists to show (reported 2026-09-21). The row
    --  is filled to a legible block width and then wrapped, and the rows are
    --  balanced rather than greedily filled, because eight and eight reads
    --  better than twelve and four and leaves both rows wider.
    local cells = s.bankCells
    if cells and #cells > 0 then
        local n = #cells
        local gap = px(5)
        local blockH, rowGap = px(30), px(6)
        -- Wide enough for the three digits the block exists to show, measured
        -- rather than guessed, plus a little air each side.
        local minW = textW("100", UIFont.CodeSmall) + px(6)
        local maxPerRow = math.max(1, math.floor((iw + gap) / (minW + gap)))

        -- How many rows fit above the CELL CONDITION % footer. This has to be
        -- known BEFORE the rows are balanced: balancing first picks a row
        -- count the page may not have room for, and then spreads the cells
        -- thinner than they needed to be across the rows it does have.
        local footTop = MID_Y + LCD_H - px(14) - fontH(UIFont.CodeSmall)
        local maxRows = math.max(1,
            math.floor((footTop - y - px(6)) / (blockH + rowGap)))

        -- Balance within what actually fits: as few rows as the legible block
        -- width allows, then as few blocks per row as those rows need.
        local rows = math.min(maxRows, math.max(1, math.ceil(n / maxPerRow)))
        local perRow = math.min(maxPerRow, math.max(1, math.ceil(n / rows)))

        -- The count on the header is the whole bank; the list is what the
        -- server had room to send. Counting the overflow from the header means
        -- the block says how many cells are missing, not just how many this
        -- page ran out of space for.
        local total = tonumber(s.cells) or n
        if total < n then total = n end
        local capacity = maxRows * perRow
        local shown = n
        if shown > capacity then shown = capacity end
        local over = total - shown
        if over > 0 and shown >= capacity then shown = math.max(0, capacity - 1) end
        over = total - shown

        local cw = math.floor((iw - (perRow - 1) * gap) / perRow)
        local function blockAt(i)
            return x + ((i - 1) % perRow) * (cw + gap),
                   y + math.floor((i - 1) / perRow) * (blockH + rowGap)
        end
        for i = 1, shown do
            local ccx, ccy = blockAt(i)
            self:drawRectBorder(ccx, ccy, cw, blockH, 0.25, c("ink"))
            self:textCentre(tostring(cells[i]), ccx + cw / 2, ccy + px(2),
                            "ink", UIFont.CodeSmall)
            local fw = math.floor((cw - px(8)) * M.clamp(cells[i] / 100, 0, 1))
            self:drawRect(ccx + px(4), ccy + px(22), fw, px(3), 0.9, c("ink"))
        end
        if over > 0 then
            local ccx, ccy = blockAt(shown + 1)
            self:drawRectBorder(ccx, ccy, cw, blockH, 0.25, c("ink"))
            self:textCentre("+" .. over, ccx + cw / 2, ccy + px(2), "ink",
                            UIFont.CodeSmall, 0.6)
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

--- GEN: the backup generators this controller runs.
--
--  Everything here is the controller's mirror under bk* names, written by
--  the server every tick; gen stays solar watts. Every switch and box is a
--  GEN rectangle, so the invisible buttons sit exactly over what is drawn.
--  A fainter rule parts each generator from the next, so each one's lines
--  and switches read as one block (Can, 2026-09-28). A figure that does not
--  fit its line is left off rather than drawn over its neighbour; at the
--  game's own glyph widths every English figure fits at every font size,
--  and only the fullest line of all (far, OFF BY SERVER, MIXED FLUID and
--  HOSE LOST at once) loses its last flag (tests/test_machine.py pins what
--  each font size leaves off), besides what a long translation loses.
--  START AT prints where Auto really starts (s.bkStartShown, higher than the
--  level set in a frost); its - and + step and dim against the level set.
--  For a player the owner's lock refuses (s.lock, s.bkLocks; Can,
--  2026-09-29) the master AUTO is drawn greyed and the four level boxes
--  dimmed, and a generator's two switches greyed (genRow).
function OG_Window:pageGen(s, x, y)
    local font = UIFont.CodeSmall
    local iw = GEN.iw
    local locked = s.lock ~= nil and s.lock ~= false

    -- the title, and the master AUTO switch where the other pages keep the
    -- clock
    self:text(fit(getText("IGUI_OffGrid_GenHeader"), GEN.master.x - x - px(8), font),
              x, y, "ink", font, 0.85)
    self:genSwitch(GEN.master, getText("IGUI_OffGrid_GenSwAuto"), s.bkAuto == true, locked)

    -- the two levels, each with its - and +; a box at the end of its range
    -- is dimmed (the server clamps a press there anyway), and all four while
    -- the controller's lock refuses this player
    local start, stop = s.bkStart or 0, s.bkStop or 0
    local e = 1e-6
    local function dim(atEnd) return (locked or atEnd) and 0.35 or 1 end
    self:text(fit(P.txt("IGUI_OffGrid_GenStartAt",
                        math.floor((s.bkStartShown or start) * 100 + 0.5)),
                  GEN.startMinus.x - x - px(4), font), x, GEN.levelY, "ink", font)
    self:genBox(GEN.startMinus, "-", false, dim(start <= (s.bkLo or 0) + e))
    self:genBox(GEN.startPlus, "+", false, dim(start >= (s.bkHi or 1) - e))
    self:text(fit(P.txt("IGUI_OffGrid_GenStopAt", math.floor(stop * 100 + 0.5)),
                  GEN.stopMinus.x - GEN.stopX - px(4), font), GEN.stopX, GEN.levelY,
              "ink", font)
    self:genBox(GEN.stopMinus, "-", false, dim(stop <= start + 0.10 + e))
    self:genBox(GEN.stopPlus, "+", false, dim(stop >= 0.95 - e))
    self:drawRect(x, GEN.ruleY, iw, px(1), 0.35, c("ink"))

    local rows = s.bkRows
    if type(rows) == "table" and rows[1] ~= nil then
        local locks = type(s.bkLocks) == "table" and s.bkLocks or {}
        for i = 1, #GEN.rows do
            if rows[i] == nil then break end
            if i > 1 then
                self:drawRect(x, GEN.rows[i - 1].ruleY, iw, px(1), 0.22, c("ink"))
            end
            self:genRow(rows[i], GEN.rows[i], x, locks[i] ~= nil and locks[i] ~= false)
        end
    else
        -- Nothing cabled yet: say so, and how, where the rows would be.
        local ly = GEN.rowsY
        self:text(fit(getText("IGUI_OffGrid_GenNone"), iw, font), x, ly, "ink", font, 0.9)
        ly = ly + GEN.fh + px(6)
        local lines = wrap(getText("IGUI_OffGrid_GenHowTo"), iw, font)
        for i = 1, #lines do
            if ly + GEN.fh > GEN.footY - px(4) then break end
            self:text(lines[i], x, ly, "ink", font, 0.7)
            ly = ly + GEN.fh + px(3)
        end
    end

    -- today: what the generators gave and burned since midnight
    self:drawRect(x, GEN.footY - px(3), iw, px(1), 0.35, c("ink"))
    self:text(fit(P.txt("IGUI_OffGrid_GenToday", fmtWh(s.bkWhToday or 0),
                        string.format("%.1f", s.bkFuelToday or 0)), iw, font),
              x, GEN.footY, "ink", font, 0.85)
end

--- One generator's block. Line one: brand, state, FAR while its area is not
--  loaded, and what it delivers while it runs. Line two: tank + barrels,
--  burn, hours left, condition. Both lines end before its two switches,
--  which stand side by side at the right end and span both lines: AUTO, ON
--  while this generator's own Auto is, and ON/OFF, ON while it runs. Their
--  labels never change; the sliders show the state. While its AUTO is on,
--  the ON/OFF switch is greyed and its button does nothing (Can,
--  2026-09-28: "when AUTO is active for a generator, it should disable
--  (greyed out) ON/OFF button until AUTO is disabled for that generator");
--  its slider still shows whether it runs. MIXED FLUID is a barrel skipped
--  for holding a mix, HOSE LOST a barrel dropped this session (gone, moved
--  or out of reach). `locked`: the owner's lock refuses this player the
--  generator's controls, and both switches are greyed (Can, 2026-09-29).
function OG_Window:genRow(r, g, x, locked)
    local font = UIFont.CodeSmall
    local right = g.textR
    local gap = px(8)
    local running = r.s == "running"

    local brand = GEN_BRAND[r.t] and getText(GEN_BRAND[r.t])
        or string.upper(tostring(r.t or "?"))
    local one = { { brand, 1 },
                  { getText(GEN_STATE[r.s] or "IGUI_OffGrid_GenOff"), 0.85 } }
    if r.far then one[#one + 1] = { getText("IGUI_OffGrid_GenFar"), 0.6 } end
    if r.mix then one[#one + 1] = { getText("IGUI_OffGrid_GenMix"), 0.6 } end
    if (r.lost or 0) > 0 then one[#one + 1] = { getText("IGUI_OffGrid_GenLost"), 0.6 } end
    local cx = self:genLine(one, x, g.y, right, gap)
    if running then
        local w = fmtW(r.w or 0)
        if cx + gap + textW(w, font) <= right then
            self:textRight(w, right, g.y, "ink", font)
        end
    end
    self:genSwitch(g.auto, getText("IGUI_OffGrid_GenSwAuto"), r.auto == true, locked == true)

    local tank = P.txt("IGUI_OffGrid_GenTank", string.format("%.1f", r.tank or 0),
                       string.format("%.1f", r.feed or 0))
    local hours = r.left or -1
    local left = "--"
    if hours >= 10 then left = string.format("%d", math.floor(hours + 0.5))
    elseif hours >= 0 then left = string.format("%.1f", hours) end
    self:genLine({
        { tank, 1 },
        { P.txt("IGUI_OffGrid_GenBurn", string.format("%.2f", r.burn or 0)), 0.8 },
        { P.txt("IGUI_OffGrid_GenLeft", left), 0.8 },
        { P.txt("IGUI_OffGrid_GenCond", math.floor((r.cond or 0) + 0.5)), 0.8 },
    }, x, g.y + GEN.lineB, right, gap)
    self:genSwitch(g.run, getText("IGUI_OffGrid_GenSwPower"), running,
                   r.auto == true or locked == true)
end

--- Pieces of one LCD line, left to right with a gap, as many as fit before
--  `right`; the first is cut to fit rather than left off, so a line is
--  never empty. Returns where the last one drawn ends.
function OG_Window:genLine(parts, x, y, right, gap)
    local font = UIFont.CodeSmall
    local cx = x
    for i = 1, #parts do
        local str, a = parts[i][1], parts[i][2]
        local lead = (i == 1) and 0 or gap
        local w = textW(str, font)
        if i == 1 and w > right - cx then
            str = fit(str, right - cx, font)
            w = textW(str, font)
        elseif cx + lead + w > right then
            break
        end
        self:text(str, cx + lead, y, "ink", font, a)
        cx = cx + lead + w
    end
    return cx
end

--- One of the GEN page's level buttons, - or +: an ink outline, filled
--  while it is lit, its label centred and cut to fit. The rectangle is the
--  one its invisible button was made with, so the click lands where the box
--  is.
function OG_Window:genBox(r, label, lit, alpha)
    local a = alpha or 1
    local font = UIFont.CodeSmall
    if lit then self:drawRect(r.x, r.y, r.w, r.h, 0.85 * a, c("ink")) end
    self:drawRectBorder(r.x, r.y, r.w, r.h, 0.6 * a, c("ink"))
    self:textCentre(fit(label, r.w - px(6), font), r.x + r.w / 2,
                    r.y + math.floor((r.h - GEN.fh) / 2),
                    lit and "lcd" or "ink", font, a)
end

-- A switch's three looks, each part an alpha of the LCD's ink. Can,
-- 2026-09-28: "when a toggle is off, the canvas of that toggle should also
-- dim. when it's on, the canvas of that button should also glow (like how it
-- is right now.)" ON is the look every switch had before: it glows. OFF dims
-- the whole switch, frame, fill, label and slider, and stays plain to read
-- and to press. Greyed, a generator's ON/OFF while its own AUTO is on, is
-- fainter again in every part, and its button does nothing. Each part is
-- under four fifths of the look above it (tests/test_machine.py), so the
-- three read apart at a glance.
local SWITCH_LOOK = {
    on     = { fill = 0.14, frame = 0.9,  label = 1,   track = 1,    glow = 0.45, knob = 1 },
    off    = { fill = 0.07, frame = 0.5,  label = 0.6, track = 0.4,  glow = 0,    knob = 0.6 },
    greyed = { fill = 0.03, frame = 0.22, label = 0.3, track = 0.18, glow = 0.12, knob = 0.3 },
}

--- One of the GEN page's switches, the master AUTO or a generator's AUTO or
--  ON/OFF. Can, 2026-09-28: "They should work like switches. And we need to
--  make them more obvious." So a switch reads as a thing to press, set apart
--  from the LCD's text by a heavy frame (GEN.frame, 2 px at the base size)
--  and a faint fill; its label names it and never changes; its slider says
--  the state: OFF is a dark track with the knob at the left, ON a glowing
--  track with the knob at the right. The knob is the brightest thing in
--  the track either way, so the eye follows it from side to side: a first
--  draft with a dark knob on the lit track read as the same picture as a lit
--  knob on the dark one, bright left and dark right. The whole switch takes
--  the look of its state (SWITCH_LOOK), or the greyed one when `greyed`: its
--  slider still shows `on`, a faint glow and the knob at the right while
--  the generator runs. A two-line switch has the slider under the label,
--  the one-line master beside it. The rectangle is the one its invisible
--  button was made with, so the click lands on the switch.
function OG_Window:genSwitch(r, label, on, greyed)
    local font = UIFont.CodeSmall
    local fh, bw = GEN.fh, GEN.frame
    local look = SWITCH_LOOK[greyed and "greyed" or (on and "on" or "off")]
    self:drawRect(r.x, r.y, r.w, r.h, look.fill, c("ink"))
    for i = 0, bw - 1 do
        self:drawRectBorder(r.x + i, r.y + i, r.w - 2 * i, r.h - 2 * i, look.frame, c("ink"))
    end
    local tx, ty, tw, th
    if r.h >= 2 * fh then
        -- the label on top, the slider under it, the spare height shared
        th = math.max(px(6), fh - px(6))
        local spare = math.max(0, r.h - 2 * bw - fh - th)
        local ly = r.y + bw + math.floor(spare / 3)
        self:textCentre(fit(label, r.w - 2 * bw, font), r.x + r.w / 2, ly,
                        "ink", font, look.label)
        tx, tw = r.x + bw + px(3), r.w - 2 * bw - 2 * px(3)
        ty = ly + fh + math.floor(spare / 3)
    else
        -- one line: the label on the left, the slider on the right
        tw = px(30)
        th = math.max(px(4), r.h - 2 * bw - 2 * px(2))
        tx = r.x + r.w - bw - px(4) - tw
        ty = r.y + math.floor((r.h - th) / 2)
        local lw = tx - px(2) - (r.x + bw)
        self:textCentre(fit(label, lw, font), r.x + bw + lw / 2,
                        r.y + math.floor((r.h - fh) / 2), "ink", font, look.label)
    end
    local inset = px(1)
    local kw = math.max(px(4), math.floor((tw - 2 * inset) * 0.4))
    local kh = th - 2 * inset
    self:drawRect(tx, ty, tw, th, 1, c("lcd"))
    self:drawRectBorder(tx, ty, tw, th, look.track, c("ink"))
    if on then
        -- the glow, parted from the knob by a dark gap so the knob stands out
        local kx = tx + tw - inset - kw
        if look.glow > 0 then
            self:drawRect(tx + inset, ty + inset, kx - px(1) - tx - inset, kh,
                          look.glow, c("ink"))
        end
        self:drawRect(kx, ty + inset, kw, kh, look.knob, c("ink"))
    else
        self:drawRect(tx + inset, ty + inset, kw, kh, look.knob, c("ink"))
    end
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
    -- the isolator plate: one baked frame per state; faint, still showing
    -- the state, for a player the controller's lock refuses (s.rigLock),
    -- whose press only says why (onPowerToggle)
    local inert = s.rigLock ~= nil and s.rigLock ~= false
    local a = inert and 0.35 or 1
    local t = tex(s.online and "plate_on.png" or "plate_off.png")
    if t then
        self:drawTextureScaled(t, COLX, MID_Y, COL_W, px(112), a, 1, 1, 1)
    end
    self:textCentre(getText("IGUI_OffGrid_Isolator"), COLX + COL_W / 2,
                    MID_Y + px(114), "dim", UIFont.NewSmall, inert and 0.45 or 1)

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

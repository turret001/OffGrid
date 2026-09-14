--[[ OffGrid -- the battery rack panel.

     One slot per bay, showing what is actually in the rack. Drag a car battery
     from any open inventory pane onto an empty slot to fit it, click a filled
     one to take it back.

     Nothing here mutates ModData. Every change queues OG_BankCell, which is
     the one place the server validates and applies a cell change; a client
     that writes to a rack's ModData and transmits also overwrites the live
     charge and cell list the server has been maintaining, which is the trap
     recorded at the top of OG_System's command section.

     The slots are ISItemSlot, B42's own control. It carries the drag
     detection, the green and red drop border, the icon and the tooltip, and
     it needs no part of the entity or crafting system as long as
     onVerifyItem is supplied: defaultVerifyItem returns false with no
     `resource`, and createChildren only reaches for ISXuiSkin when
     showSelectInputsButton is set, which defaults false.
]]

require "ISUI/ISCollapsableWindow"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Actions"

OffGrid = OffGrid or {}
OffGrid.Bank = OffGrid.Bank or {}
local P = OffGrid.Parts
local M = OffGrid.Model

OG_Bank = ISCollapsableWindow:derive("OG_Bank")

local COL = {
    bg    = { 0.09, 0.10, 0.12 },
    panel = { 0.14, 0.15, 0.18 },
    line  = { 0.28, 0.30, 0.34 },
    text  = { 0.86, 0.88, 0.91 },
    dim   = { 0.55, 0.58, 0.63 },
    good  = { 0.42, 0.78, 0.48 },
    warn  = { 0.85, 0.65, 0.28 },
    bad   = { 0.80, 0.35, 0.30 },
}

-- Font-derived, because the game has no UI scale: Options > Font Size swaps
-- the font set and every UIFont grows with it, and the 4x set a 4K player
-- lands on wrote its bay figures across the next row. Taken at file load,
-- which is safe since fonts only change through a full Lua reset. At the
-- base set (Small 16, Large 26) these are exactly the fixed values they
-- replace; LABEL and HEAD grow by the extra font height on top of the scale.
local FH_S = getTextManager():getFontHeight(UIFont.Small)
local FH_L = getTextManager():getFontHeight(UIFont.Large)
local S = math.max(1, FH_S / 16)
local function px(v) return math.floor(v * S + 0.5) end

local PAD, SLOT, GAP = px(12), px(56), px(8)
local LABEL = px(18) + (FH_S - 16)   -- the condition bar and figure under a slot
-- The charge readout above the grid: the Large figure, the 7 px bar two
-- pixels under it, then an 11 px gap to the first bay. Built from those
-- parts rather than scaled whole, which double-counted the font growth and
-- left a band of empty panel under the bar at 4x. 52 at the base font.
local HEAD = 6 + FH_L + 2 + 7 + px(11)
local MINW = px(248)
local REACH = 2
-- how long the panel waits for the player to arrive before giving up, in
-- update ticks; a walk from the far side of a room is comfortably inside this
local ARRIVE_TICKS = 600

-- A Lua multi-return collapses to its first value anywhere but the final
-- argument slot, so c() is only ever safe as the last thing passed. drawRect
-- and drawRectBorder take colour last; drawText does not, which is why the
-- text helpers below unpack by hand. Getting this wrong is silent: the text
-- simply renders red.
local function c(name) local k = COL[name]; return k[1], k[2], k[3] end

--- Slot columns, chosen so the grid comes out square rather than ragged:
--  a 6-bay rack is two rows of three, not a row of four and a row of two.
local function columnsFor(cap)
    if cap <= 4 then return math.max(1, cap) end
    return math.ceil(cap / 2)
end

local function condColour(h)
    if h >= 0.75 then return "good" end
    if h >= 0.45 then return "warn" end
    return "bad"
end

--- Is one of this player's queued actions already working on this rack?
--
--  Read from the queue rather than tracked with a flag of our own, because a
--  flag has to be cleared and the interesting case is the one where it never
--  would be: the player walks off or presses a movement key and the action is
--  cancelled. The queue empties on its own, so the lock lifts on its own.
--  Indexed directly rather than through getTimedActionQueue, which CREATES a
--  queue for a character that has none.
local function busyOn(character, object)
    local q = ISTimedActionQueue.queues[character]
    if not q or not q.queue then return false end
    for i = 1, #q.queue do
        local a = q.queue[i]
        if a and a.Type == "OG_BankCell" and a.object == object then return true end
    end
    return false
end

--- Same test the context menu applies before offering a row. Kept local
--  rather than reached for out of OG_Context, because OG_Info already
--  requires OG_Context back and adding a second edge into that pair is how a
--  load-order cycle starts.
local function reachable(playerObj, object)
    local sq = object and object:getSquare()
    if not sq or not playerObj then return false end
    return math.abs(sq:getX() - playerObj:getX()) <= REACH
       and math.abs(sq:getY() - playerObj:getY()) <= REACH
       and sq:getZ() == playerObj:getZ()
end

----------------------------------------------------------------- lifecycle

function OG_Bank:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.closeButton:setOnClick(function() self:close() end)

    local cols = columnsFor(self.cap)
    local gridW = cols * SLOT + (cols - 1) * GAP
    local x0 = math.floor((self:getWidth() - gridW) / 2)
    local y0 = self:titleBarHeight() + HEAD

    self.slots = {}
    for i = 1, self.cap do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local slot = ISItemSlot:new(
            x0 + col * (SLOT + GAP),
            y0 + row * (SLOT + LABEL + GAP),
            SLOT, SLOT,
            nil,            -- no crafting resource; this rack is its own store
            self,           -- functionTarget for every callback below
            OG_Bank.onDrop, nil, OG_Bank.onVerify, OG_Bank.onTake)
        slot.bay = i
        slot.allowDrop = true
        slot.renderItemCount = false
        slot.drawProgress = false
        slot:setCharacter(self.character)
        slot:setToolTip(true, "")
        slot:initialise()
        slot:instantiate()
        self:addChild(slot)
        self.slots[i] = slot
    end
end

function OG_Bank:close()
    self:removeFromUIManager()
    OffGrid.Bank.current = nil
end

function OG_Bank:update()
    ISCollapsableWindow.update(self)
    -- A rack that was picked up or destroyed while the panel was open.
    if not self.object or self.object:getObjectIndex() == -1 then
        self:close()
        return
    end
    -- And a player who walked away from it. ARMED first, because the panel can
    -- legitimately be opened before the player has arrived: both the context
    -- row and a click from a few tiles away walk you there, and closing on the
    -- first out-of-reach tick would have shut the window in the same frame it
    -- opened. So wait for the first arrival, then close on leaving; and give up
    -- if that arrival never comes.
    if reachable(self.character, self.object) then
        self.armed = true
    elseif self.armed then
        self:close()
        return
    else
        self.waiting = (self.waiting or 0) + 1
        if self.waiting > ARRIVE_TICKS then
            self:close()
            return
        end
    end
    self.tick = (self.tick or 0) + 1
    if self.tick % 6 == 0 or not self.cells then
        self:refresh()
    end
end

--- Set what a bay says on hover, and rebuild the tooltip if one is open.
--
--  ISItemSlot:setToolTip only stores the text (ISItemSlot.lua:506-511), and
--  activateToolTip, called on every mouse move over the slot, reuses the
--  ISToolTip it already built and reads the text only when it builds a new one
--  (:513-532). So a bay under the pointer kept saying "Empty bay" over a
--  battery just dragged in, and named a battery just taken out, until the
--  pointer left it (live test, 2026-09-14). This is vanilla's own idiom from
--  setStoredItem (:466-469). A slot only holds a tooltip while it is hovered
--  (prerender drops it otherwise, :75-77), so only that bay is rebuilt, and
--  only when its text changed.
local function setBayTip(slot, text)
    local changed = slot.toolTipText ~= text
    slot:setToolTip(true, text)
    if changed and slot.toolTip then
        slot:deactivateToolTip()
        slot:activateToolTip()
    end
end

--- Pull the rack's contents off ModData and push them into the slots.
function OG_Bank:refresh()
    local d = P.data(self.object)
    local info = P.describe(self.object)
    local b = {
        tier = info and info.tier,
        scale = P.bankScale(),
        cellList = d.cellList,
        charge = d.charge or 0,
    }
    -- Nominal, not the cold-derated figure. It is the reference a cell is
    -- handed back against, so showing anything else here would mean the
    -- header and the battery that comes out of a slot disagreed.
    self.nominal = M.bankNominal(b)
    self.fill = M.bankFill(b)
    self.charge = d.charge or 0
    self.cellWh = M.cellWh(b.tier, b.scale)

    self.cells = {}
    local list = d.cellList or {}
    for i = 1, #list do
        self.cells[i] = { id = list[i].id, type = list[i].type,
                          health = M.clamp(list[i].health or 1, 0, 1),
                          bay = list[i].bay }
    end
    -- Each battery in the bay it was put in (P.bayLayout), not the Nth cell
    -- in the Nth bay.
    self.bays = P.bayLayout(self.cells, self.cap)

    local busy = busyOn(self.character, self.object)
    for i = 1, self.cap do
        local slot = self.slots[i]
        local cell = self.bays[i]
        slot:setLocked(busy)
        slot.cellId = cell and cell.id or nil
        if cell then
            local script = getScriptManager():getItem(cell.type)
            slot:setStoredScriptItem(script)
            -- A modded battery whose mod was removed leaves no script item
            -- and would otherwise stop being clickable, stranding it in the
            -- rack. The bay still holds something, so say so.
            if not script then slot.boxOccupied = true end
            setBayTip(slot, self:cellTip(cell))
        else
            slot:setStoredScriptItem(nil)
            setBayTip(slot, getText("Tooltip_OffGrid_CellEmpty"))
        end
    end
end

--- What one bay says on hover.
function OG_Bank:cellTip(cell)
    local name = getItemNameFromFullType(cell.type)
    return string.format("%s\n%s %d%%\n%s %d Wh\n%s %d%%",
        name,
        getText("Tooltip_OffGrid_CellCondition"),
        math.floor(cell.health * 100 + 0.5),
        getText("Tooltip_OffGrid_CellHolds"),
        math.floor(cell.health * self.cellWh + 0.5),
        getText("Tooltip_OffGrid_CellCharge"),
        math.floor(self.fill * 100 + 0.5))
end

------------------------------------------------------------------ callbacks

--- Accept a car battery into an empty bay.
--  ISItemSlot calls this for the border colour on hover as well as for the
--  drop itself, so it has to be cheap and it has to be honest.
function OG_Bank.onVerify(self, slot, item)
    if slot.cellId ~= nil then return false end
    if #(self.cells or {}) >= self.cap then return false end
    if slot:isLocked() then return false end
    return OffGrid.Context.isCarBattery(item) == true
end

function OG_Bank.onDrop(self, slot, items)
    local item = items and items[1]
    if not item then return end
    if slot.cellId ~= nil or slot:isLocked() then return end
    -- One battery per drop even when a stack was dragged: a bay holds one
    -- cell, and queueing six actions from one gesture would be a surprise.
    ISTimedActionQueue.add(OG_BankCell:new(self.character, self.object,
                                           true, item, nil, slot.bay))
    slot:setLocked(true)
end

function OG_Bank.onTake(self, slot)
    if slot.cellId == nil or slot:isLocked() then return end
    -- Refused here too, so the bay does not lock up waiting on an action
    -- that can only finish as a no-op. mayTakeCell says why.
    if OffGrid.Place and OffGrid.Place.mayTakeCell
            and not OffGrid.Place.mayTakeCell(self.character, self.object) then
        return
    end
    ISTimedActionQueue.add(OG_BankCell:new(self.character, self.object,
                                           false, nil, slot.cellId))
    slot:setLocked(true)
end

-------------------------------------------------------------------- drawing

function OG_Bank:text(str, x, y, col, font)
    local k = COL[col or "text"]
    self:drawText(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

function OG_Bank:textRight(str, x, y, col, font)
    local k = COL[col or "text"]
    self:drawTextRight(str, x, y, k[1], k[2], k[3], 1, font or UIFont.Small)
end

function OG_Bank:prerender()
    ISCollapsableWindow.prerender(self)
    if not self.cells then return end

    local w = self:getWidth()
    local y = self:titleBarHeight() + 6

    local pctFill = math.floor(self.fill * 100 + 0.5)
    local col = self.fill >= 0.5 and "good" or (self.fill >= 0.2 and "warn" or "bad")
    self:text(pctFill .. "%", PAD, y, col, UIFont.Large)
    -- The Wh figure sits 8 px under the top of the Large fill figure at the
    -- base fonts and keeps that footing as both fonts grow.
    self:textRight(string.format("%d / %d Wh",
                                 math.floor(self.charge + 0.5),
                                 math.floor(self.nominal + 0.5)),
                   w - PAD, y + 8 + (FH_L - 26) - (FH_S - 16), "dim")

    local barY = y + FH_L + 2
    local barW = w - PAD * 2
    self:drawRect(PAD, barY, barW, 7, 0.9, c("panel"))
    if self.fill > 0 then
        self:drawRect(PAD, barY, math.floor(barW * self.fill), 7, 1, c(col))
    end
    self:drawRectBorder(PAD, barY, barW, 7, 0.5, c("line"))
end

--- The per-bay condition bar, drawn over the slots rather than inside them,
--  because ISItemSlot owns its own box and painting into it would fight the
--  control's own hover and drop states.
function OG_Bank:render()
    ISCollapsableWindow.render(self)
    if not self.cells then return end
    for i = 1, self.cap do
        local slot, cell = self.slots[i], self.bays[i]
        if slot then
            local x, y = slot:getX(), slot:getY() + SLOT + 3
            if cell then
                local k = condColour(cell.health)
                self:drawRect(x, y, SLOT, 4, 0.9, c("panel"))
                self:drawRect(x, y, math.floor(SLOT * cell.health), 4, 1, c(k))
                self:text(math.floor(cell.health * 100 + 0.5) .. "%",
                          x, y + 5, k)
            else
                self:text(getText("IGUI_OffGrid_CellEmpty"), x, y + 5, "dim")
            end
        end
    end
end

------------------------------------------------------------------ construction

function OG_Bank:new(x, y, playerObj, object)
    local cap = P.cellCap(object)
    if cap < 1 then cap = 1 end
    local cols = columnsFor(cap)
    local rows = math.ceil(cap / cols)
    local w = math.max(MINW, PAD * 2 + cols * SLOT + (cols - 1) * GAP)
    local h = 0

    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.cap = cap
    o.object = object
    o.character = playerObj
    o.tick = 0
    o:setResizable(false)
    -- Denser than the controller screen's 0.92 on purpose. This panel exists to
    -- be dragged onto, so it spends its whole life sitting over an open
    -- inventory window, and at 0.92 the character sheet behind it read straight
    -- through the row of bay labels.
    o.backgroundColor = { r = COL.bg[1], g = COL.bg[2], b = COL.bg[3], a = 0.98 }
    o.borderColor = { r = COL.line[1], g = COL.line[2], b = COL.line[3], a = 1 }

    local info = P.describe(object)
    o.title = getText("IGUI_OffGrid_BankTitle_" .. (info and info.tier or "standard"))
    -- titleBarHeight is only callable once the object exists, so the height
    -- is set here rather than passed into the constructor above.
    o:setHeight(o:titleBarHeight() + HEAD
                + rows * (SLOT + LABEL + GAP) + PAD)
    return o
end

function OffGrid.Bank.open(playerObj, object)
    if OffGrid.Bank.current then
        OffGrid.Bank.current:close()
    end
    local win = OG_Bank:new(getPlayerScreenLeft(0) + 60,
                            getPlayerScreenTop(0) + 60, playerObj, object)
    win:initialise()
    win:addToUIManager()
    win:refresh()
    OffGrid.Bank.current = win
    return win
end

return OG_Bank

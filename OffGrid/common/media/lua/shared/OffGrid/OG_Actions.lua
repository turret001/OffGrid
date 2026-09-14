--[[ OffGrid -- the timed actions.

     Shared, because a timed action's complete() runs on whichever side
     started it and single-player runs both. Each one mutates ModData on the
     world object and lets the next simulation tick pick the change up, rather
     than trying to recompute the system here.

     Shaped after the shipped ISActivateGenerator: isValid / waitToStart /
     update / start / stop / perform / complete / getDuration / new.
]]

require "TimedActions/ISBaseTimedAction"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Almanac"

local P = OffGrid.Parts
local M = OffGrid.Model
local A = OffGrid.Almanac

--------------------------------------------------------------- clear snow

OG_ClearArray = ISBaseTimedAction:derive("OG_ClearArray")

function OG_ClearArray:isValid()
    if not self.object or self.object:getObjectIndex() == -1 then return false end
    local d = P.data(self.object)
    if self.mode == "snow" then return (d.snow or 0) > 0.01 end
    return (d.soiling or 0) > 0.01
end

function OG_ClearArray:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function OG_ClearArray:update()
    self.character:faceThisObject(self.object)
end

function OG_ClearArray:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
end

function OG_ClearArray:stop()
    ISBaseTimedAction.stop(self)
end

function OG_ClearArray:perform()
    ISBaseTimedAction.perform(self)
end

function OG_ClearArray:complete()
    -- true, not false: NetTimedAction feeds this straight into the transaction
    -- state and false there is a Reject, which force-stops the client.
    if not self.object or self.object:getObjectIndex() == -1 then return true end
    local d = P.data(self.object)
    if self.mode == "snow" then
        d.snow = 0
    else
        -- A bottle that has run dry cleans nothing. The authority's copy is
        -- the one that counts: the queueing client only checked it at start.
        local fc0 = self.water and self.water.getFluidContainer
                    and self.water:getFluidContainer()
        if fc0 and fc0.getAmount and fc0:getAmount() <= 0 then return true end
        d.soiling = 0
        -- Half a litre off the B42 FLUID container, which is what every match
        -- of predicateWater actually is: isWaterSource() in B42 requires the
        -- FluidContainer component, so writing the legacy `uses` field (the
        -- previous fix here) moved a number nothing reads while the bottle
        -- stayed full. adjustAmount is absolute and clamped, and the fallback
        -- keeps genuinely legacy drainables honest too.
        if self.water then
            local fc = self.water.getFluidContainer
                       and self.water:getFluidContainer()
            if fc and fc.getAmount and fc.adjustAmount then
                fc:adjustAmount(math.max(0, fc:getAmount() - 0.5))
            elseif self.water.setCurrentUsesFloat
                    and self.water.getCurrentUsesFloat then
                self.water:setCurrentUsesFloat(
                    math.max(0, self.water:getCurrentUsesFloat() - 0.15))
            end
            -- The drain happened on the authority's copy; this is the half
            -- that reaches the player's bag. Without it the client kept a
            -- full bottle and could wipe panels with it forever. A no-op
            -- outside a server (LuaManager.sendItemStats), the vanilla pairing
            -- ISCleanGraffiti uses.
            sendItemStats(self.water)
        end
        -- RippedSheets is a plain item, not clothing, so setWetness may not
        -- exist on it; a dish cloth has it. Guard rather than assume.
        if self.rag and self.rag.setWetness and self.rag.getWetness then
            self.rag:setWetness(math.min(100, (self.rag:getWetness() or 0) + 40))
            sendItemStats(self.rag)
        end
    end
    P.setState(self.object, P.arrayState(d))
    self.object:transmitModData()
    return true
end

function OG_ClearArray:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return self.mode == "snow" and 120 or 260
end

function OG_ClearArray:new(character, object, mode, rag, water)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.mode = mode
    o.rag = rag
    o.water = water
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------------------------ battery cells

--- May this character take a battery OUT of this rack? The owner lock's
--  answer (OG_Place.G.mayTakeCell); anyone may put one in.
local function mayRemoveCell(action)
    local G = OffGrid.Place
    if not (G and G.mayTakeCell) then return true end
    return G.mayTakeCell(action.character, action.object)
end

--- A car battery's charge, 0..1.
--
--  getCurrentUsesFloat, NOT getUsedDelta. `setUsedDelta` exists on
--  DrainableComboItem and `getUsedDelta` does not exist on any item class in
--  42.20.2 or 42.20.4 -- only on Clothing. So the obvious symmetric getter is
--  nil, and `item.getUsedDelta and item:getUsedDelta() or 1.0` silently
--  evaluates to 1.0, which recorded EVERY installed battery as fully charged
--  no matter what it held. Beware `getUseDelta` (no d) as well: it exists on
--  both classes and returns the script's UseDelta, 0.00001 for a car battery.
local function itemFill(item)
    if not item then return 0 end
    if item.getCurrentUsesFloat then
        return M.clamp(item:getCurrentUsesFloat() or 0, 0, 1)
    end
    -- Fallback for an item class that predates the float accessor.
    local maxU = item.getMaxUses and item:getMaxUses() or 1
    if not maxU or maxU <= 0 then return 1 end
    return M.clamp((item.getCurrentUses and item:getCurrentUses() or maxU) / maxU, 0, 1)
end

--- A car battery's condition as a fraction of its own maximum, 0..1.
local function itemCondition(item)
    if not item or not item.getCondition then return 1 end
    local maxC = item.getConditionMax and item:getConditionMax() or 100
    if not maxC or maxC <= 0 then return 1 end
    return M.clamp((item:getCondition() or maxC) / maxC, 0, 1)
end

--- The plain-table view of a rack that OG_Model's pure functions operate on.
local function bankOf(obj, d, info)
    return {
        tier = info and info.tier,
        scale = P.bankScale(),
        cellList = d.cellList,
        charge = d.charge or 0,
        nextCellId = d.nextCellId,
    }
end

--- Write a mutated bank view back onto the object's ModData.
local function writeBank(obj, d, b)
    d.cellList = b.cellList
    d.charge = b.charge
    d.nextCellId = b.nextCellId
    d.cells = #b.cellList
    P.setState(obj, P.bankState(d))
end

OG_BankCell = ISBaseTimedAction:derive("OG_BankCell")

function OG_BankCell:isValid()
    if not self.object or self.object:getObjectIndex() == -1 then return false end
    local d = P.data(self.object)
    if self.install then
        return (d.cells or 0) < P.cellCap(self.object) and self.battery ~= nil
    end
    if not mayRemoveCell(self) then return false end
    return P.findCell(d, self.cellId) ~= nil
end

function OG_BankCell:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function OG_BankCell:update()
    self.character:faceThisObject(self.object)
end

function OG_BankCell:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
end

function OG_BankCell:stop()
    ISBaseTimedAction.stop(self)
end

function OG_BankCell:perform()
    ISBaseTimedAction.perform(self)
end

--- Does this action still make sense against the world as it is NOW?
--  isValid() never runs on the server, and in multiplayer complete() runs there
--  against an object the server rebuilt out of a packet, so the gate has to be
--  re-run here rather than trusted from the client that asked.
function OG_BankCell:stillApplies()
    if not self.object or self.object:getObjectIndex() == -1 then return false end
    -- Arm's reach, re-checked at COMPLETION time on the authority. The queue
    -- normally guarantees it via the walk, but a teleport or a forced
    -- interruption can land completion with the character somewhere else
    -- entirely, and a mutation from across the map is how item dupes start.
    local sq = self.object:getSquare()
    if not sq or math.abs(sq:getX() - self.character:getX()) > 2
              or math.abs(sq:getY() - self.character:getY()) > 2
              or sq:getZ() ~= self.character:getZ() then
        return false
    end
    local info = P.describe(self.object)
    if not info or info.kind ~= "bank" then return false end
    local d = P.data(self.object)
    if self.install then
        return self.battery ~= nil and (d.cells or 0) < P.cellCap(self.object)
    end
    -- The owner lock covers what is IN the rack, not only the rack: under
    -- "whoever placed it", lifting the cabinet was refused and emptying it of
    -- its batteries was not. Checked here, on the authority, as well as in
    -- isValid, which never runs on a server.
    if not mayRemoveCell(self) then return false end
    -- By id, not by index. Two players with the panel open on the same rack
    -- would otherwise both ask for "slot 3" and the second one would take
    -- whichever cell had shuffled into that position.
    return P.findCell(d, self.cellId) ~= nil
end

function OG_BankCell:complete()
    -- Return TRUE on every "nothing to do" path. NetTimedAction.perform feeds
    -- this boolean into the transaction state, and false there means Reject,
    -- which force-stops the action on the client. A no-op finished cleanly.
    if not self:stillApplies() then return true end

    local d = P.data(self.object)
    local info = P.describe(self.object)
    local b = bankOf(self.object, d, info)
    local cap = P.cellCap(self.object)

    if self.install then
        local item = self.battery
        -- Still POSSESSED, right now? Two installs can be queued with the same
        -- battery (two racks, two panels; the queue does not know), and the
        -- first to complete nulls the item's container -- after which the
        -- second must be a clean no-op, not a second cell conjured from a
        -- battery already inside another rack. Floor-sourced items are refused
        -- for the same reason from the other side: their container is a
        -- synthetic per-player UI list, so consuming from it leaves the world
        -- object on the ground, duplicating the battery every pane refresh.
        local cont = item.getContainer and item:getContainer()
        if not cont then return true end
        if item.getWorldItem and item:getWorldItem() then return true end
        -- Into the bay it was dropped on while that is still free, chosen
        -- before it joins the list. Nothing already in moves: a cell with no
        -- bay fills the lowest bays nobody claimed, and a free bay is always
        -- above those.
        local bay = P.freeBay(b.cellList, cap, self.bay)
        -- The battery's OWN condition and charge, both preserved. Condition
        -- used to be discarded here and reinvented at 100 on the way out.
        local cell = M.installCell(b, item:getFullType(), itemCondition(item), itemFill(item))
        cell.bay = bay

        -- Take it from the container it is ACTUALLY in.
        --
        -- OG_Context finds the battery with getFirstEvalRecurse, which
        -- descends into every bag in the player's inventory, and
        -- ItemContainer.Remove scans only its own direct children and returns
        -- SILENTLY when the item is not one of them. So removing from the
        -- character's main inventory was a no-op for any battery in a
        -- backpack, while the rack still counted the cell: the duplication
        -- the 2026-08-27 report is about. A car battery is weight 5.0, so
        -- that is where players keep them.
        --
        -- Vanilla names the item's own container for exactly this reason, e.g.
        -- GameServer.sendRemoveItemFromContainer(item.getContainer(), item).
        cont:Remove(item)
        -- The line above only moves this side's copy. This is the networked
        -- half, and it carries its own client/server branches, so it is safe
        -- to call unconditionally in singleplayer too. It must name the SAME
        -- container, or the packet describes a removal that never happened.
        sendRemoveItemFromContainer(cont, item)
    else
        -- Pinned first (P.pinBays): the bay this one leaves can sit below a
        -- battery from an older save that has no bay of its own, which would
        -- slide down into it.
        P.pinBays(b.cellList or {}, cap)
        local out = M.removeCell(b, self.cellId)
        -- Nil means somebody else took it first. A no-op that finished
        -- cleanly, so true rather than false: see the note at the top.
        if not out then return true end
        local item = P.cellItem(out.type, out.fill, out.cond)
        if item then
            local inv = self.character:getInventory()
            inv:AddItem(item)
            sendAddItemToContainer(inv, item)
        end
    end

    writeBank(self.object, d, b)
    -- Unconditional, and the reason it is unconditional is singleplayer: on a
    -- server this is the packet, and in singleplayer it is the flagForHotSave
    -- that makes the write survive without waiting for a full save.
    self.object:transmitModData()
    return true
end

function OG_BankCell:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 150
end

--- `battery` for an install, `cellId` for a removal. `bay` is the bay an
--  install was dropped on; nil takes the first free one. A parameter of new,
--  so it travels: a server rebuilds the action from new's named fields
--  (NetTimedAction.set, NetTimedAction.java:41-51).
function OG_BankCell:new(character, object, install, battery, cellId, bay)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.install = install
    o.battery = battery
    o.cellId = cellId
    o.bay = bay
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------------------------ breaker reset

OG_ResetBreaker = ISBaseTimedAction:derive("OG_ResetBreaker")

function OG_ResetBreaker:isValid()
    return self.object and self.object:getObjectIndex() ~= -1
end

function OG_ResetBreaker:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function OG_ResetBreaker:update()
    self.character:faceThisObject(self.object)
end

function OG_ResetBreaker:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventLootItem")
end

function OG_ResetBreaker:stop()
    ISBaseTimedAction.stop(self)
end

function OG_ResetBreaker:perform()
    ISBaseTimedAction.perform(self)
end

function OG_ResetBreaker:complete()
    -- Same contract as OG_BankCell: a no-op is a clean finish, not a rejection.
    if not self.object or self.object:getObjectIndex() == -1 then return true end
    local info = P.describe(self.object)
    if not info then return true end
    if info.kind ~= "controller" then return true end
    -- A controller dropped on the floor was never set up (OG_Place.G.adopt);
    -- switching it on is where a player finds that out, so take charge first.
    if OffGrid.Place and OffGrid.Place.adopt then OffGrid.Place.adopt(self.object) end
    local d = P.data(self.object)
    d.trip = false
    d.online = self.on
    -- A deliberate throw of the isolator closes the disconnect too. If the
    -- bank is still at or under its floor with no sun to carry the load, the
    -- next tick opens it again before the house lights, and the monitor says
    -- so, which is the answer the player was missing.
    d.lvd = false
    d.lvdAt = nil
    if not self.on then
        -- Off means OFF, now. The tick debounces the generator flip behind
        -- POWER_HOLD because a bank hovering near empty would otherwise flap
        -- the whole larder's food-aging every game minute -- but that guard is
        -- for the AUTONOMOUS decision, and it was also debouncing the player.
        -- Flip the switch and the fridge kept humming for five-plus game
        -- minutes, which reads as "the switch does nothing". A deliberate act
        -- is not noise: cut the engine state here, on the object itself, and
        -- leave the hold counters agreeing with what was just done so the next
        -- tick has nothing to fight.
        d.powered = false
        d.poweredWant = false
        d.poweredHold = 0
        if self.object.setActivated and self.object.isActivated
                and self.object:isActivated() then
            self.object:setActivated(false)
        end
        P.setState(self.object, "off")
    end
    if self.on then
        -- Switching ON is still decided by the next tick -- whether the
        -- system can serve power depends on cells, charge and sun, and the
        -- tick is where that answer honestly lives -- but the DEBOUNCE must
        -- not apply to a deliberate act any more than it did to switching
        -- off. Pre-arming the hold lets the very next tick flip the engine,
        -- so starting takes up to one game minute instead of six; the window
        -- labels that minute STARTING UP, and nothing is billed for it: the
        -- generator is still off.
        d.poweredWant = true
        d.poweredHold = 999
    end
    self.object:transmitModData()
    return true
end

function OG_ResetBreaker:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 25
end

function OG_ResetBreaker:new(character, object, on)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.on = on
    o.maxTime = o:getDuration()
    return o
end

--------------------------------------------------------------- running cable

--  Connecting costs time and nothing else. There is no cable item: the mod
--  already gates every object behind a book and a build recipe, and making the
--  player carry a consumable to plug in a panel they have already built would
--  be a second tax on the same decision. What it costs is the walk and the
--  work, and a long run costs more of both.

OG_RunCable = ISBaseTimedAction:derive("OG_RunCable")

function OG_RunCable:isValid()
    if not self.object or self.object:getObjectIndex() == -1 then return false end
    if not self.target or self.target:getObjectIndex() == -1 then return false end
    return true
end

function OG_RunCable:waitToStart()
    self.character:faceThisObject(self.at or self.object)
    return self.character:shouldBeTurning()
end

function OG_RunCable:update()
    self.character:faceThisObject(self.at or self.object)
end

function OG_RunCable:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
end

function OG_RunCable:stop()
    ISBaseTimedAction.stop(self)
end

function OG_RunCable:perform()
    local a, b = self.object:getSquare(), self.target:getSquare()
    if a and b then
        local ai = P.describe(self.object)
        local bi = P.describe(self.target)
        if ai and bi then
            OffGrid.Context.send(self.character,
                self.cut and "disconnect" or "connect",
                { ax = a:getX(), ay = a:getY(), az = a:getZ(), ak = ai.kind,
                  bx = b:getX(), by = b:getY(), bz = b:getZ(), bk = bi.kind })
        end
    end
    ISBaseTimedAction.perform(self)
end

--- Long enough to be a job, and longer the further the cable has to go.
function OG_RunCable:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    local a, b = self.object:getSquare(), self.target:getSquare()
    local d = 0
    if a and b then
        local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
        d = math.sqrt(dx * dx + dy * dy)
    end
    if self.cut then return 60 + math.floor(d * 6) end
    return 90 + math.floor(d * 22)
end

--- `object` and `target` are the two ENDS of the cable and their order is
--  what the server reads: object is the loose end, target is the thing already
--  in a system. `at` is a separate question, and it is which end the character
--  actually stands at to do the work. They are not the same because the player
--  clicked the second end and should not be marched back to the first.
function OG_RunCable:new(character, object, target, cut, at)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.target = target
    o.at = at or object
    o.cut = cut and true or false
    o.maxTime = o:getDuration()
    return o
end

--------------------------------------------------------- repairing a frame

--  How much condition one pass buys. Deliberately not a full restoration: a
--  badly cracked array is worth several trips or a replacement, which keeps
--  the scrap recipes worth having.
OG_REPAIR_STEP = 30

OG_RepairArray = ISBaseTimedAction:derive("OG_RepairArray")

function OG_RepairArray:isValid()
    if not self.object or self.object:getObjectIndex() == -1 then return false end
    local info = P.describe(self.object)
    if not info or info.kind ~= "array" then return false end
    return (P.data(self.object).condition or 100) < 100
        and self.scrap ~= nil and self.screws ~= nil
end

function OG_RepairArray:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function OG_RepairArray:update()
    self.character:faceThisObject(self.object)
end

function OG_RepairArray:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
end

function OG_RepairArray:stop()
    ISBaseTimedAction.stop(self)
end

function OG_RepairArray:perform()
    ISBaseTimedAction.perform(self)
end

function OG_RepairArray:complete()
    if not self.object or self.object:getObjectIndex() == -1 then return true end
    local info = P.describe(self.object)
    if not info or info.kind ~= "array" then return true end
    local d = P.data(self.object)
    if (d.condition or 100) >= 100 then return true end

    for _, it in ipairs({ self.scrap, self.screws }) do
        if it then
            -- The item's OWN container, never the character's main inventory:
            -- findRepairParts descends into bags (getFirstEvalRecurse), and
            -- ItemContainer.Remove on the wrong container is a silent no-op.
            -- The same shape as the battery duplication this release opened
            -- with; materials in a bag were simply never consumed.
            local cont = (it.getContainer and it:getContainer())
                         or self.character:getInventory()
            cont:Remove(it)
            sendRemoveItemFromContainer(cont, it)
        end
    end

    d.condition = M.repairStep(d.condition or 0, OG_REPAIR_STEP)
    P.setState(self.object, P.arrayState(d))
    self.object:transmitModData()
    -- The engine global routes by side: GameServer.addXp on a server, which
    -- the one-second XP sync then carries to the player, and a plain AddXP in
    -- singleplayer (LuaManager addXp; ISFixGenerator does the same). The old
    -- route granted the XP on the CLIENT, which the server's next sync
    -- overwrote a second later, so repairs taught nothing on a server.
    addXp(self.character, Perks.Electricity, 4)
    return true
end

function OG_RepairArray:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 340
end

function OG_RepairArray:new(character, object, scrap, screws)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.scrap = scrap
    o.screws = screws
    o.maxTime = o:getDuration()
    return o
end


------------------------------------------------------------ reading the sky

--  Thirty real seconds. maxTime advances at 48 units per real second on a
--  client and 50 on a dedicated server, so a plain constant is close enough on
--  both and honest about what it is.
--
--  Deliberately NOT derived from any reading-speed knob. MinutesPerPage, the
--  Fast and Slow Reader traits, reading glasses and the sitting bonus are every
--  one of them implemented inside ISReadABook:getDuration and nowhere else, so
--  a mod action inherits none of them unless it copies the lines. Copying them
--  would mean a server with heavily modded reading speed could turn a
--  half-minute observation into an instant one, which is the one thing this
--  action must not become.
OG_SKY_SECONDS = 30

OG_ReadSky = ISBaseTimedAction:derive("OG_ReadSky")

function OG_ReadSky:isValid()
    if not A.knows(self.character) then return false end
    if A.blocked(self.character) then return false end
    -- Standing still is the point, so leaving the spot ends it.
    local sq = self.character:getCurrentSquare()
    return sq ~= nil and self.startSquare ~= nil
        and sq:getX() == self.startSquare:getX()
        and sq:getY() == self.startSquare:getY()
        and sq:getZ() == self.startSquare:getZ()
end

function OG_ReadSky:waitToStart()
    return false
end

function OG_ReadSky:update()
end

function OG_ReadSky:start()
    -- ExamineVehicle is Bob_IdleCube, a plain standing idle, and it is what
    -- vanilla uses for "stand still and study something" in
    -- ISOpenMechanicsUIAction. Never CharacterActionAnims.None: no node
    -- carries that value, so the actions state falls through to
    -- default-fallback.xml and the survivor stands there hands raised.
    self:setActionAnim("ExamineVehicle")
    self:setOverrideHandModels(nil, nil)
end

function OG_ReadSky:stop()
    ISBaseTimedAction.stop(self)
end

function OG_ReadSky:perform()
    ISBaseTimedAction.perform(self)
end

--- Re-run the gates against the world as it is now.
--  isValid never runs on the server, and in multiplayer complete() runs there,
--  so the conditions have to be re-checked rather than trusted from the client
--  that asked for the action.
function OG_ReadSky:stillApplies()
    return A.knows(self.character) and A.blocked(self.character) == nil
end

function OG_ReadSky:complete()
    -- This runs on the AUTHORITY (LuaTimedActionNew gates the Lua call on
    -- !GameClient.client), which is the only place the forecast ring is real.
    -- Return true on every path: NetTimedAction feeds this boolean into the
    -- transaction state and false there is a Reject, which force-stops the
    -- client. A reading that could not be taken is a clean finish, not a fault.
    if not self:stillApplies() then return true end
    A.grant(self.character)
    return true
end

function OG_ReadSky:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return OG_SKY_SECONDS * 48
end

function OG_ReadSky:new(character)
    local o = ISBaseTimedAction.new(self, character)
    o.startSquare = character:getCurrentSquare()
    o.maxTime = o:getDuration()
    o.forceProgressBar = true
    -- You look up with your eyes, not your hands.
    o.ignoreHandsWounds = true
    return o
end

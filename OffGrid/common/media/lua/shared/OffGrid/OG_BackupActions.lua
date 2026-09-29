--[[ OffGrid -- the backup generator's timed actions.

     Shared for the reason OG_Actions is: the client queues the action and
     complete() runs on the authority, a dedicated server or singleplayer
     (LuaTimedActionNew calls it only where GameClient.client is false). Kept
     out of OG_Actions.lua, which the battery panel's suite loads whole.

     Six actions: converting a vanilla generator into an Off-Grid backup and
     back, refuelling it from a petrol can, repairing it with Scrap
     Electronics, connecting or disconnecting a fuel barrel, and
     OG_BackupPanel, the short action a GEN button or a Start, Stop or Auto
     row queues beside the controller or the unit. Its completion hands the
     command to OG_System on the authority, so the command arrives after the
     walk and from arm's length, the way OG_ResetBreaker switches a
     controller.

     Every complete() re-checks the world as it is NOW (stillApplies, the
     OG_BankCell rule): isValid never runs on a server, and the server
     rebuilds the action from new()'s named parameters, against objects it
     resolves by square and index. And every complete() returns true on each
     path that does nothing: false there is a Reject, which force-stops the
     client. The gates are OG_Backup's, the functions the menu greys its rows
     with, so a row and the authority give the same reason.

     Who may (design, Multiplayer): anyone within reach may refuel, repair,
     start, stop, switch AUTO and the levels, and connect or disconnect a
     barrel. Only Convert to normal generator goes through the pickup lock
     (K.restoreRefusal asks OG_Place), and converting a vanilla generator
     asks nobody: it is vanilla's.

     A hand start or stop (bkRun) needs the unit's own AUTO off (Can,
     2026-09-28). OG_BackupPanel's completion hands it to BK.cmdRun, which
     asks K.handRefusal of the unit as it is NOW, on the authority, and
     refuses it with its note ("Switch its AUTO off first.") while AUTO is
     on: a press queued before someone switched AUTO back on, or a GEN page
     showing an older push, changes nothing.
]]

require "TimedActions/ISBaseTimedAction"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Backup"

local P = OffGrid.Parts
local K = OffGrid.Backup
local try = P.try

--- The character's Electrical level, which sets how long the work takes.
local function electrical(character)
    return tonumber(try(character, "getPerkLevel", Perks.Electricity)) or 0
end

--- Is the object still standing, and within arm's reach of the character on
--  its floor? The OG_BankCell rule, re-checked at completion on the
--  authority: a teleport or a forced interruption can land a completion with
--  the character somewhere else entirely. The character's z is floored: B42
--  reports it as a float, fractional on stairs.
local function inReach(character, obj)
    if not obj or not character then return false end
    local idx = try(obj, "getObjectIndex")
    if idx == nil or idx == -1 then return false end
    local sq = try(obj, "getSquare")
    if not sq then return false end
    return math.abs(sq:getX() - character:getX()) <= 2
       and math.abs(sq:getY() - character:getY()) <= 2
       and sq:getZ() == math.floor(character:getZ())
end

--- Face the work, and wait until turned.
local function faceWait(self, obj)
    self.character:faceThisObject(obj)
    return self.character:shouldBeTurning()
end

--- Crouched hands-on work, as OG_BankCell and vanilla's ISFixGenerator.
local function lootAnim(self)
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
end

--- Bring a unit up to date before the work changes it: a unit that streamed
--  back in holds a stale tank until the next tick resolves it against its
--  controller's mirror, and a change stamped before that would keep the
--  stale one (BK.freshen, server glue, loaded wherever complete() runs).
local function freshen(obj)
    local BK = OffGrid.BackupSys
    if BK and BK.freshen then BK.freshen(obj) end
end

------------------------------------------- convert to an Off-Grid backup

OG_BackupConvert = ISBaseTimedAction:derive("OG_BackupConvert")

function OG_BackupConvert:isValid()
    local gen = self.generator
    if not gen or gen:getObjectIndex() == -1 then return false end
    return K.convertRefusal(self.character, gen) == nil
end

function OG_BackupConvert:waitToStart()
    return faceWait(self, self.generator)
end

function OG_BackupConvert:update()
    self.character:faceThisObject(self.generator)
end

function OG_BackupConvert:start()
    lootAnim(self)
end

function OG_BackupConvert:stop()
    ISBaseTimedAction.stop(self)
end

function OG_BackupConvert:perform()
    ISBaseTimedAction.perform(self)
end

--- A native generator, still where it stood and within reach, that the
--  conversion's gate still lets through. Never an Off-Grid controller: the
--  menu does not offer one, and a rebuilt action must not reach one either.
function OG_BackupConvert:stillApplies()
    local gen = self.generator
    if not inReach(self.character, gen) then return false end
    if not instanceof(gen, "IsoGenerator") or P.partOf(gen) ~= nil then return false end
    return K.convertRefusal(self.character, gen) == nil
end

function OG_BackupConvert:complete()
    if not self:stillApplies() then return true end
    -- K.toBackup runs the gate once more and swaps the objects; nil means it
    -- refused, a clean finish too, and one that teaches nothing. addXp routes
    -- by side (GameServer.addXp on a server), as OG_RepairArray notes.
    if K.toBackup(self.generator, self.character) then
        addXp(self.character, Perks.Electricity, 5)
    end
    return true
end

--- 400 ticks, 20 fewer per Electrical level, never under 200.
function OG_BackupConvert:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return math.max(200, 400 - 20 * electrical(self.character))
end

function OG_BackupConvert:new(character, generator)
    local o = ISBaseTimedAction.new(self, character)
    o.generator = generator
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------- convert to a normal generator

OG_BackupRestore = ISBaseTimedAction:derive("OG_BackupRestore")

function OG_BackupRestore:isValid()
    local obj = self.object
    if not obj or obj:getObjectIndex() == -1 then return false end
    return P.partOf(obj) == "backup" and K.restoreRefusal(self.character, obj) == nil
end

function OG_BackupRestore:waitToStart()
    return faceWait(self, self.object)
end

function OG_BackupRestore:update()
    self.character:faceThisObject(self.object)
end

function OG_BackupRestore:start()
    lootAnim(self)
end

function OG_BackupRestore:stop()
    ISBaseTimedAction.stop(self)
end

function OG_BackupRestore:perform()
    ISBaseTimedAction.perform(self)
end

--- A backup still standing within reach that may be turned back: stopped,
--  uncabled, and the server's pickup option lets this character take it.
function OG_BackupRestore:stillApplies()
    local obj = self.object
    if not inReach(self.character, obj) or P.partOf(obj) ~= "backup" then return false end
    return K.restoreRefusal(self.character, obj) == nil
end

function OG_BackupRestore:complete()
    if not self:stillApplies() then return true end
    -- The generator item carries the unit's tank and condition: the current ones.
    freshen(self.object)
    K.toGenerator(self.object, self.character)
    return true
end

--- 300 ticks, 10 fewer per Electrical level, never under 150. No XP: it
--  undoes work rather than doing any.
function OG_BackupRestore:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return math.max(150, 300 - 10 * electrical(self.character))
end

function OG_BackupRestore:new(character, object)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------ shared by refuel, repair, feed

--- World hours now. A player's change stamps the unit's `at`, so the
--  controller's mirror, written a tick earlier, is never taken for newer
--  and written back over it.
local function worldHours()
    return OffGrid.Env and OffGrid.Env.worldHours and OffGrid.Env.worldHours() or 0
end

--- The container an item is in RIGHT NOW, or nil. A bag inside the
--  inventory counts; a floor item does not, because its container is a
--  per-player UI list and taking from it leaves the world object where it
--  lies (the battery duplication OG_BankCell's install describes). Nil too
--  once another queued action has used the item up.
local function carried(item)
    if not item then return nil end
    if try(item, "getWorldItem") then return nil end
    return try(item, "getContainer")
end

--- Is the item of this full type?
local function isType(item, fullType)
    return try(item, "getFullType") == fullType
end

--- Push the unit's ModData, and have the controller it serves pushed at its
--  next tick, so GEN shows the change without waiting for the ten-minute
--  sync. BK.wake is server glue (OG_BackupSys), loaded wherever complete()
--  runs.
local function publish(obj, d)
    obj:transmitModData()
    local BK = OffGrid.BackupSys
    if BK and BK.wake then BK.wake(d) end
end

------------------------------------------------------------------ refuel

OG_BackupRefuel = ISBaseTimedAction:derive("OG_BackupRefuel")

function OG_BackupRefuel:isValid()
    local obj = self.object
    if not obj or obj:getObjectIndex() == -1 then return false end
    if P.partOf(obj) ~= "backup" or not carried(self.petrol) then return false end
    return K.refuelRefusal(self.character, obj, self.petrol) == nil
end

function OG_BackupRefuel:waitToStart()
    return faceWait(self, self.object)
end

function OG_BackupRefuel:update()
    try(self.petrol, "setJobDelta", self:getJobDelta())
    self.character:faceThisObject(self.object)
end

--- As vanilla's ISAddFuel: the pouring animation, the can's static model in
--  the hand (never the item itself, whose right-hand mask breaks the
--  animation), the job bar on the can, and the sound.
function OG_BackupRefuel:start()
    self:setActionAnim("refuelgascan")
    try(self.petrol, "setJobType", getText("ContextMenu_OffGrid_BkRefuel"))
    try(self.petrol, "setJobDelta", 0.0)
    self:setOverrideHandModels(try(self.petrol, "getStaticModel"), nil)
    self.sound = self.character:playSound("GeneratorAddFuel")
end

function OG_BackupRefuel:stop()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    try(self.petrol, "setJobDelta", 0.0)
    ISBaseTimedAction.stop(self)
end

function OG_BackupRefuel:perform()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    try(self.petrol, "setJobDelta", 0.0)
    ISBaseTimedAction.perform(self)
end

--- A backup within reach, the can still carried, and the gate (a container
--  of petrol, a tank with room) still open. A running unit may be refuelled.
function OG_BackupRefuel:stillApplies()
    local obj = self.object
    if not inReach(self.character, obj) or P.partOf(obj) ~= "backup" then return false end
    if not carried(self.petrol) then return false end
    return K.refuelRefusal(self.character, obj, self.petrol) == nil
end

function OG_BackupRefuel:complete()
    -- The gate reads the tank: the current one, not a stale saved one.
    freshen(self.object)
    if not self:stillApplies() then return true end
    local fc = try(self.petrol, "getFluidContainer")
    if not fc then return true end
    local d = P.data(self.object)
    local fuel = tonumber(d.fuel) or 0
    -- Only the petrol, and only what the tank has room for, litre for litre.
    -- Never adjustAmount, which vanilla's ISAddFuel uses: it scales every
    -- fluid in the container by one ratio (FluidContainer.java:701-715), so
    -- a can holding water too would give up its water with its petrol.
    local n = tonumber(fc:getSpecificFluidAmount(Fluid.Petrol)) or 0
    local t = math.min(n, K.TANK - fuel)
    if t <= 0 then return true end
    fc:adjustSpecificFluidAmount(Fluid.Petrol, n - t)
    -- The can lost petrol on this side; this is the half that reaches the
    -- player's bag. Vanilla's ISAddFuel pairs its adjust with the same call,
    -- whose packet carries the fluid container (SyncItemFieldsPacket).
    self.petrol:syncItemFields()
    d.fuel = fuel + t
    if d.fault == "nofuel" then d.fault = nil end
    d.at = worldHours()
    publish(self.object, d)
    return true
end

--- Vanilla's figure (ISAddFuel.getDuration): 70 ticks and 50 a litre in the
--  can.
function OG_BackupRefuel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    local fc = try(self.petrol, "getFluidContainer")
    return 70 + (tonumber(fc and try(fc, "getAmount")) or 0) * 50
end

function OG_BackupRefuel:new(character, object, petrol)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.petrol = petrol
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------------------------------ repair

OG_BackupRepair = ISBaseTimedAction:derive("OG_BackupRepair")

function OG_BackupRepair:isValid()
    local obj = self.object
    if not obj or obj:getObjectIndex() == -1 then return false end
    if P.partOf(obj) ~= "backup" then return false end
    if not isType(self.scrap, K.SCRAP) or not carried(self.scrap) then return false end
    return K.repairRefusal(self.character, obj, self.scrap) == nil
end

function OG_BackupRepair:waitToStart()
    return faceWait(self, self.object)
end

function OG_BackupRepair:update()
    self.character:faceThisObject(self.object)
end

function OG_BackupRepair:start()
    lootAnim(self)
    self.sound = self.character:playSound("GeneratorRepair")
end

function OG_BackupRepair:stop()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.stop(self)
end

function OG_BackupRepair:perform()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.perform(self)
end

--- A backup within reach, a Scrap Electronics still carried, and the gate
--  (no fire on its square, Electrical 3 or the magazine, stopped, something
--  to repair) still open.
function OG_BackupRepair:stillApplies()
    local obj = self.object
    if not inReach(self.character, obj) or P.partOf(obj) ~= "backup" then return false end
    if not isType(self.scrap, K.SCRAP) or not carried(self.scrap) then return false end
    return K.repairRefusal(self.character, obj, self.scrap) == nil
end

function OG_BackupRepair:complete()
    -- The gate reads "stopped": the current run, not a stale saved one (a
    -- unit its controller started on paper while it was away).
    freshen(self.object)
    if not self:stillApplies() then return true end
    -- From the container the scrap is ACTUALLY in: ItemContainer.Remove on
    -- any other is a silent no-op (OG_BankCell).
    local cont = carried(self.scrap)
    try(self.character, "removeFromHands", self.scrap)
    cont:Remove(self.scrap)
    sendRemoveItemFromContainer(cont, self.scrap)

    local d = P.data(self.object)
    -- Vanilla's figures (ISFixGenerator.complete): 4 + Electrical / 2 a scrap,
    -- in whole points as IsoGenerator.setCondition(int) keeps them. The
    -- engine clamps its own to 100; this is a Lua number and must be capped.
    local cond = tonumber(d.condition) or 100
    d.condition = math.min(100, math.floor(cond + 4 + electrical(self.character) / 2))
    -- Worn out or burnt, it works again once it holds any condition. The
    -- gate refuses a repair while the square burns; the fault stays on a
    -- burning square here too, whatever let the action through.
    if (d.fault == "fault" or d.fault == "fire") and d.condition > 0 then
        local sq = self.object:getSquare()
        if not (sq and sq:haveFire()) then d.fault = nil end
    end
    d.at = worldHours()
    publish(self.object, d)
    addXp(self.character, Perks.Electricity, 5)
    return true
end

--- Vanilla's figure (ISFixGenerator.getDuration): 150 ticks, 3 fewer per
--  Electrical level.
function OG_BackupRepair:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 150 - 3 * electrical(self.character)
end

function OG_BackupRepair:new(character, object, scrap)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.scrap = scrap
    o.maxTime = o:getDuration()
    return o
end

-------------------------------------------------------------- fuel barrels

OG_BackupFeed = ISBaseTimedAction:derive("OG_BackupFeed")

--- The barrel's square as whole numbers, or nil when the action names none.
local function spot(self)
    local x, y, z = tonumber(self.fx), tonumber(self.fy), tonumber(self.fz)
    if not (x and y and z) then return nil end
    return math.floor(x), math.floor(y), math.floor(z)
end

--- Is the square x, y, z one of this unit's feeds?
local function fedFrom(obj, x, y, z)
    local list = K.decodeFeeds(P.data(obj).feeds)
    for i = 1, #list do
        local f = list[i]
        if f.x == x and f.y == y and f.z == z then return true end
    end
    return false
end

--- Connect: the barrel still there, a Rubber Hose still carried, and the
--  gate (a hose, eight at most, no pump, five tiles, nobody else's, petrol
--  in it) still open. Disconnect: the square still one of the unit's feeds.
local function feedApplies(self, obj)
    local x, y, z = spot(self)
    if not x then return false end
    if self.cut then return fedFrom(obj, x, y, z) end
    local barrel = K.findBarrel(x, y, z)
    if not barrel then return false end
    if not isType(self.hose, K.HOSE) or not carried(self.hose) then return false end
    return K.feedRefusal(self.character, obj, barrel) == nil
end

function OG_BackupFeed:isValid()
    local obj = self.object
    if not obj or obj:getObjectIndex() == -1 or P.partOf(obj) ~= "backup" then return false end
    return feedApplies(self, obj)
end

function OG_BackupFeed:waitToStart()
    return faceWait(self, self.object)
end

function OG_BackupFeed:update()
    self.character:faceThisObject(self.object)
end

function OG_BackupFeed:start()
    lootAnim(self)
end

function OG_BackupFeed:stop()
    ISBaseTimedAction.stop(self)
end

function OG_BackupFeed:perform()
    ISBaseTimedAction.perform(self)
end

function OG_BackupFeed:stillApplies()
    local obj = self.object
    if not inReach(self.character, obj) or P.partOf(obj) ~= "backup" then return false end
    return feedApplies(self, obj)
end

--- The work itself is the authority's (OG_BackupSys): connecting takes the
--  hose, appends the feed and claims the barrel; disconnecting hands the
--  hose back and clears the claim. Each re-checks what it needs.
function OG_BackupFeed:complete()
    if not self:stillApplies() then return true end
    local BK = OffGrid.BackupSys
    if not BK then return true end
    local x, y, z = spot(self)
    if self.cut then
        BK.feedCut(self.character, self.object, x, y, z)
    else
        BK.feedConnect(self.character, self.object, x, y, z, self.hose)
    end
    return true
end

function OG_BackupFeed:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    if self.cut then return 90 end
    return 150
end

--- `fx, fy, fz` is the barrel's square; `hose` the Rubber Hose a connection
--  uses (nil for a disconnect); `cut` true to disconnect.
function OG_BackupFeed:new(character, object, fx, fy, fz, hose, cut)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.fx = fx
    o.fy = fy
    o.fz = fz
    o.hose = hose
    o.cut = cut and true or false
    o.maxTime = o:getDuration()
    return o
end

------------------------------------------------------------ panel presses

OG_BackupPanel = ISBaseTimedAction:derive("OG_BackupPanel")

-- The commands a press may send, and what its `value` carries for each: a
-- switch (`on`) or a 5-point step (`dir`). Nothing else is sent: the command
-- name came from the client.
local PANEL_VALUE = { bkMaster = "on", bkLevelStart = "dir", bkLevelStop = "dir",
                      bkAuto = "on", bkRun = "on" }
-- The ones that act on the controller itself, never on one unit.
local PANEL_CONTROLLER = { bkMaster = true, bkLevelStart = true, bkLevelStop = true }

--- The command's arguments, or nil when the press makes no sense (any more).
--  A press at a controller names it (x, y, z), so the authority holds a GEN
--  row to that controller's own units; a press on a unit's menu names only
--  the unit (ux, uy, uz).
local function panelArgs(self)
    local what = PANEL_VALUE[self.cmd]
    if not what then return nil end
    local kind = P.partOf(self.object)
    if kind ~= "controller" and kind ~= "backup" then return nil end
    local args = {}
    if kind == "controller" then
        local sq = self.object:getSquare()
        args.x, args.y, args.z = sq:getX(), sq:getY(), sq:getZ()
    elseif PANEL_CONTROLLER[self.cmd] then
        return nil
    end
    if not PANEL_CONTROLLER[self.cmd] then
        local ux, uy, uz = tonumber(self.ux), tonumber(self.uy), tonumber(self.uz)
        if not (ux and uy and uz) then return nil end
        args.ux, args.uy, args.uz = math.floor(ux), math.floor(uy), math.floor(uz)
    end
    if what == "on" then
        args.on = self.value == true
    else
        local n = tonumber(self.value) or 0
        if n == 0 then return nil end
        args.dir = n > 0 and 1 or -1
    end
    return args
end

function OG_BackupPanel:isValid()
    local obj = self.object
    return obj ~= nil and obj:getObjectIndex() ~= -1 and panelArgs(self) ~= nil
end

function OG_BackupPanel:waitToStart()
    return faceWait(self, self.object)
end

function OG_BackupPanel:update()
    self.character:faceThisObject(self.object)
end

function OG_BackupPanel:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventLootItem")
end

function OG_BackupPanel:stop()
    ISBaseTimedAction.stop(self)
end

function OG_BackupPanel:perform()
    ISBaseTimedAction.perform(self)
end

function OG_BackupPanel:stillApplies()
    return inReach(self.character, self.object) and panelArgs(self) ~= nil
end

--- The command, sent from here on the authority straight into OG_System's
--  table (no packet: this IS the authority), where it is validated exactly
--  as a client's own sendClientCommand would be.
function OG_BackupPanel:complete()
    if not self:stillApplies() then return true end
    local S = OffGrid.System
    if S and S.onCommand then S.onCommand(self.cmd, self.character, panelArgs(self)) end
    return true
end

--- As long as a breaker throw (OG_ResetBreaker).
function OG_BackupPanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 25
end

--- `object` is the controller (a GEN button) or the unit (its menu row);
--  `cmd` one of PANEL_VALUE's commands; `ux, uy, uz` the unit a row acts on
--  (nil for the controller's own switch and levels); `value` the switch
--  (true or false) or the step (1 or -1).
function OG_BackupPanel:new(character, object, cmd, ux, uy, uz, value)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.cmd = cmd
    o.ux = ux
    o.uy = uy
    o.uz = uz
    o.value = value
    o.maxTime = o:getDuration()
    return o
end

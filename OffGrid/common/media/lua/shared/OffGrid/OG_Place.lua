--[[ OffGrid -- placing and picking the parts up.

     The mod ships no placement UI. Its tiles carry IsMoveAble and CustomItem,
     which is all vanilla's moveable system needs to offer "Place Object" on
     the item and "Pick Up" on the world object, complete with the ghost
     cursor and facing rotation. This file fills in what that system leaves
     to the mod:

     * A controller placed by the base method is a plain IsoObject, and a
       plain IsoObject cannot power anything. Only an activated IsoGenerator
       inside the radius makes IsoGridSquare.haveElectricity() true, and the
       engine deletes any generator position not backed by one. So the object
       is swapped for a real IsoGenerator, following the same sequence the
       shipped MOGenerator.lua uses for map-placed generators.

     * A controller can reach the world without being placed: dropped on
       the floor, it becomes a bare IsoGenerator the engine builds itself.
       Wherever a Lua drop path runs (the inventory drop, dropping at a spot
       on the ground, dropping out of a vehicle) it is adopted as it lands
       (G.adopt), so it comes up the way a placed one does, and one dropped
       at the dropper's feet lands beside them instead (G.landingSquare). On
       a server a move from a bag, crate or trunk straight to the floor is
       Java with no Lua on it; that controller is adopted the first time
       anyone wires it, switches it on or sets equalise. See the floor-drop
       hooks.

     * State has to survive the round trip. A bank full of scavenged car
       batteries must not evaporate because someone packed the rack up, so
       pick-up hands the batteries back at the charge they were holding, and
       everything else rides on the item.

     * A part leaving the world by any other road is handled too. A rack
       destroyed by a sledgehammer, a weapon or zombies hands its batteries
       back, except to a player the owner lock would not let take one out,
       and a controller that is lifted or destroyed hands over what it held:
       its whole system, unless another controller still stands on the
       square. See "a part leaving the world".

     * Who is allowed to take a part at all. Vanilla decides that in
       canPickUpMoveableInternal, and this mod used to leave the answer
       entirely to whatever loaded underneath it -- which meant a mod whose
       whole purpose is removing the tool and skill requirement for moving
       furniture (Rebalanced Prop Moving, and Useful Barrels touches the same
       gate) silently made every panel and battery bank liftable bare-handed
       by anyone. On a PVP server that is a theft mechanic nobody chose. The
       gate below is OffGrid's own and only ever TIGHTENS: it never returns
       true where the base said false.
]]

-- Explicit, so the hook below never depends on shared/Moveables
-- happening to sort before shared/OffGrid in the load order.
require "Moveables/ISMoveableSpriteProps"
-- The vanilla actions wrapped at the bottom of this file. shared/OffGrid sorts
-- before shared/TimedActions, so without these the globals would not exist yet.
require "TimedActions/ISTransferAction"
require "TimedActions/ISDropWorldItemAction"
require "TimedActions/ISTakeGenerator"
require "TimedActions/ISDropVehicleItemAction"
require "TimedActions/ISDestroyStuffAction"
require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Place = OffGrid.Place or {}
local G = OffGrid.Place
local P = OffGrid.Parts
local M = OffGrid.Model
local try, sandbox = P.try, P.sandbox

--- What the removal handler needs to know about objects leaving a square (see
--  "a part leaving the world", further down). Declared ahead of everything
--  that fills it.
local removal = {
    kept = {},          -- object -> true while the pick-up hook lifts it (a
                        -- pick-up or a rotation), which deals with it itself
    refused = {},       -- object -> true for a break a refused player caused
    refusedThisFrame = false,
    pending = {},       -- batteries to put on the floor next frame
    retiring = {},      -- controllers an event removed this frame (destroyed,
                        -- burnt, a placeholder swapped): { x, y, z, wire }
}

local function cell()
    -- getCell() is the client-side accessor; on a dedicated server the world
    -- cell is reached through getWorld(), which is what MOGenerator.lua uses
    if getWorld and getWorld() then return getWorld():getCell() end
    return getCell()
end

-- SandboxVars enums are 1-based, so these are the literal stored values.
G.LOCK_ANYONE = 1
G.LOCK_TOOL   = 2
G.LOCK_OWNER  = 3

--- Put a cell that has left its rack on the floor, as a car battery at the
--  charge the rack was holding and the condition that cell had. `cell` is
--  what G.takeCells hands out: { type, fill, cond }.
function G.giveBackCell(square, cell)
    local item = P.cellItem(cell.type, cell.fill, cell.cond)
    if item and square then square:AddWorldInventoryItem(item, 0.5, 0.5, 0.0) end
    return item
end

--- Give a bare IsoGenerator the state a managed controller starts with, and
--  restore whatever the carried item remembers. Shared by the placement hook
--  and by G.adopt, so a controller that reaches the world by any route comes
--  up the same way.
local function initController(gen, item, info)
    gen:setCondition(100)
    gen:setFuel(0)
    gen:setActivated(false)

    local d = P.data(gen)
    d.online = false
    d.trip = false
    d.lvd = false
    d.lvdAt = nil
    d.lastHour = -1
    d.tier = (info and info.tier) or d.tier or "basic"
    local md = item and item.getModData and item:getModData()
    local src = md and md.offgrid
    if type(src) == "table" then
        d.online = src.online or false
        -- THE GRAPH. Vanilla rotation is pickup-then-place, and the pickup
        -- hook deliberately keeps `wire` on the item for exactly that round
        -- trip -- but this side only ever restored `online`, so turning a
        -- controller ninety degrees erased its entire system: every edge
        -- gone, every member still claiming membership, nothing offering
        -- "Run cable" and nothing left to cut. The wire string is the graph's
        -- single authority and it must survive every trip through item form.
        if type(src.wire) == "string" then d.wire = src.wire end
        if src.equalise ~= nil then d.equalise = src.equalise end
        if type(src.owner) == "string" and src.owner ~= "" then
            d.owner = src.owner
        end
    end
    return d
end

--- Turn a freshly placed controller shell into a working IsoGenerator.
function G.makeController(square, item, info, placed)
    local byTier = P.CONTROLLER_ITEM[info.tier or "basic"] or P.CONTROLLER_ITEM.basic
    local itemType = byTier[info.facing] or byTier.S
    local genItem = instanceItem(itemType)
    if not genItem then return placed end

    local condition = 100
    if item and item.getCondition then condition = item:getCondition() or 100 end
    genItem:setCondition(condition)
    genItem:getModData().fuel = 0

    if placed then
        -- The placeholder makes way for the generator. Its removal reaches
        -- S.retire on the next frame like any controller leaving the square,
        -- and by then the generator below stands there and carries the
        -- system on (a rotation's wire rides in on the item).
        square:transmitRemoveItemFromSquare(placed)
    end

    local gen = IsoGenerator.new(genItem, cell(), square)
    -- The IsoGenerator constructor already calls square:AddSpecialObject, so
    -- adding it again here would double-register it (MOGenerator.lua carries
    -- the same warning).
    initController(gen, item, info)

    -- NO transmitCompleteItemToClients here. The IsoGenerator constructor has
    -- already sent the object to every client in range (IsoGenerator.java:
    -- 102-105, gated on GameServer.server), and AddItemToMapPacket builds a
    -- fresh object from every packet it receives with no "already here"
    -- check (IsoObject.loadFromRemoteBuffer inserts at the server's index).
    -- A second send therefore left every client holding TWO controllers on
    -- the square: the later copy at the server's index, which every ModData
    -- and sprite packet keeps updating, and a ghost pushed one slot up that
    -- nothing ever addresses again. The picker returns the highest index, so
    -- the player's clicks all landed on the ghost: the monitor read a blank
    -- table ("no arrays or banks connected"), Switch On and Pick Up were
    -- sent with an index the server could not resolve and completed as
    -- no-ops ("won't turn on", "the bar stops halfway"), and a relog, which
    -- re-streams the chunk with its single real generator, "fixed" it. The
    -- 2026-09 Workshop reports, reproduced on 2026-09-13 with a scripted
    -- client against a local dedicated server: client 3 objects, server 2.
    -- What the constructor's packet lacks is the offgrid ModData written
    -- above; G.push sends that through ObjectModData, addressed by index to
    -- the one copy the client now has.
    if IsoGenerator.updateGenerator then
        IsoGenerator.updateGenerator(square)
    end
    if OffGrid.System then OffGrid.System.register(gen) end
    return gen
end

--- Publish a freshly placed part's ModData to the clients that already hold
--  the object. Vanilla broadcasts the object from inside placeMoveableInternal,
--  BEFORE this file seeds and stamps it, and nothing pushes ModData again until
--  the part is wired to a ticking controller; so a rack put down with its
--  batteries read as empty on every client until then. In singleplayer this
--  is only flagForHotSave, which is harmless. Never called on a multiplayer
--  client: the hook that calls it only runs where the action completes, and a
--  client transmitModData would overwrite the server's copy wholesale.
function G.push(obj)
    if not obj or isClient() then return end
    if obj.transmitModData then obj:transmitModData() end
end

--- Take charge of a controller that reached the world WITHOUT the placement
--  hook. The item carries base:generator and a WorldObjectSprite, and for any
--  such item IsoGridSquare.AddWorldInventoryItem builds `new IsoGenerator`
--  directly instead of a world item (IsoGridSquare.java:6548, 6611). So
--  dropping a controller on the floor -- the inventory Drop, a drag to the
--  ground, placing it at a spot on the ground, and on a server the
--  dropOnFloor transaction -- stood up a real generator that no hook had
--  seen: no defaults, never registered, so it could not be switched on, its
--  monitor stayed blank, and a relog "fixed" it. The same symptom the ghost
--  reports had, by a different road.
--
--  Idempotent. A generator that already carries controller state is only
--  (re-)registered. `item`, when the caller still holds it, restores the
--  wiring and the switch the item carried. Never on a multiplayer client.
function G.adopt(gen, item, character)
    if not gen or isClient() then return false end
    local info = P.describe(gen)
    if not info or info.kind ~= "controller" then return false end
    local md = gen.getModData and gen:getModData()
    local fresh = not (md and type(md.offgrid) == "table" and md.offgrid.tier)
    if fresh then
        initController(gen, item, info)
        -- Whoever put it down owns it, the same rule as any placement. The
        -- owner the item carries only survives when nobody is known to have
        -- dropped it: the item may have changed hands since it was lifted,
        -- and the player dropping it must not be locked out of their own find.
        if character then G.stamp(gen, character) end
        if IsoGenerator and IsoGenerator.updateGenerator and gen.getSquare then
            local sq = gen:getSquare()
            if sq then IsoGenerator.updateGenerator(sq) end
        end
    end
    if OffGrid.System and OffGrid.System.register then
        OffGrid.System.register(gen)
    end
    if fresh then G.push(gen) end
    return fresh
end

--- Is this inventory item an Off-Grid controller?
local function isControllerItem(item)
    local ft = item and item.getFullType and item:getFullType()
    return type(ft) == "string" and string.find(ft, "OffGridController", 1, true) ~= nil
end

--- After a vanilla floor drop, adopt the controller it turned into.
local function adoptDropOn(square, item, character)
    if not square or not item or isClient() then return end
    if not isControllerItem(item) then return end
    -- The fresh one: a square can already hold a managed controller, and
    -- getGenerator() would hand back that one instead.
    local objs = square.getObjects and square:getObjects()
    if not objs then return end
    for n = objs:size() - 1, 0, -1 do
        local o = objs:get(n)
        if P.partOf(o) == "controller" then
            local md = o.getModData and o:getModData()
            if not (md and type(md.offgrid) == "table" and md.offgrid.tier) then
                G.adopt(o, item, character)
                return
            end
        end
    end
end

--- Copy an item's carried state onto a freshly placed array or bank.
function G.seed(obj, item, info)
    if not obj then return end
    -- Vanilla has already copied the item's whole ModData onto the object,
    -- its saved copy of the previous object's ModData included (see
    -- P.VANILLA_CARRIED); left there, each move nests the part one level
    -- deeper. The Off-Grid state is the `offgrid` table and nothing else.
    P.scrubCarried(obj)
    local d = P.data(obj)
    d.condition = (item and item.getCondition and item:getCondition()) or 100

    local src = item and item:getModData() and item:getModData().offgrid
    if src then
        -- The owner rides along; the placement hook re-stamps it for anyone
        -- but a rotation, which keeps it.
        if type(src.owner) == "string" and src.owner ~= "" then d.owner = src.owner end
        -- So does the system, and only a rotation carries one: a pick-up
        -- strips `sys` from the item. Without it the turned part read loose
        -- until its controller's next relink, and wiring it again in that
        -- minute cut the branch behind it.
        if type(src.sys) == "string" and src.sys ~= "" then d.sys = src.sys end
        if info.kind == "bank" then
            d.charge = src.charge or 0
            -- Carry the cells across verbatim. A packed rack that was holding
            -- three half-worn batteries has to put those same three back.
            -- src may predate the per-cell shape, so it goes through the same
            -- migration the world objects use rather than a second copy of it.
            local carried = { cells = src.cells or 0, cellList = src.cellList,
                              cellTypes = src.cellTypes, health = src.health,
                              -- The counter travels WITH the list. Dropping it
                              -- here made a rotated rack mint duplicate cell
                              -- ids (installCell's old fallback was #list+1,
                              -- blind to holes), after which removal-by-id
                              -- pulled whichever twin sat first.
                              nextCellId = src.nextCellId }
            P.migrateCells(carried)
            d.cellList = carried.cellList
            d.nextCellId = carried.nextCellId
            d.cells = #carried.cellList
            -- Show what is actually in it. The item keeps the sprite it was
            -- picked up with, so an emptied rack placed back down wore its
            -- old cN face until the next state touch.
            P.setState(obj, P.bankState(d))
        elseif info.kind == "array" then
            d.panels = src.panels or 1
            d.soiling = src.soiling or 0
            -- Snow rides along. The pickup copy keeps every scalar, so a
            -- rotated panel arrives here still carrying its cover; zeroing it
            -- made a quarter-turn a free snow sweep. A crafted item has no
            -- src at all and still starts clean.
            d.snow = src.snow or 0
            P.setState(obj, P.arrayState(d))
        end
    end
    if OffGrid.System then OffGrid.System.register(obj) end
end

--- A part is being lifted: empty a rack's batteries onto the floor it stood
--  on. Not on a rotation, which puts the same rack straight back. The rest of
--  the state rides to the item on the copy the pick-up hook makes once
--  vanilla has created it.
function G.stow(obj, square, rotating)
    local info = P.describe(obj)
    if not info then return end
    -- Normalise the ModData first (identity fields, defaults, the old
    -- cells/cellTypes to cellList migration): the hook's copy carries no
    -- table but cellList, so a rotated old-format rack would otherwise lose
    -- its battery types.
    P.data(obj)

    if info.kind == "bank" and not rotating then
        -- Rotating goes through the same pick-up path, so the guard matters:
        -- turning a rack ninety degrees must not spit six car batteries onto
        -- the floor.
        local cells = G.takeCells(obj, info)
        for i = 1, #cells do G.giveBackCell(square, cells[i]) end
    end
end

--- Empty a rack: every battery out of its ModData, as { type, fill, cond }.
--
--  Through M.removeCell one at a time, so the batteries come out exactly as a
--  slot-by-slot emptying would give them: each at its own condition, all at
--  the rack's shared charge. The one place a rack's contents are turned back
--  into batteries, for a pick-up and for a rack that is destroyed alike.
function G.takeCells(obj, info)
    local d = P.data(obj)
    local b = { tier = info.tier, scale = P.bankScale(),
                cellList = type(d.cellList) == "table" and d.cellList or {},
                charge = d.charge or 0, nextCellId = d.nextCellId }
    local out = {}
    while #b.cellList > 0 do
        local c = M.removeCell(b, b.cellList[1].id)
        if not c then break end
        out[#out + 1] = c
    end
    d.cellList = {}
    d.cells = 0
    d.charge = 0
    d.nextCellId = b.nextCellId
    return out
end

------------------------------------------------------------------ ownership

--- The account name that placed this part, or nil if nobody ever did.
function G.ownerOf(obj)
    if not obj or not obj.getModData then return nil end
    local md = obj:getModData()
    local d = md and md.offgrid
    local o = d and d.owner
    if type(o) == "string" and o ~= "" then return o end
    return nil
end

--- Record who put a part down. Whoever places it owns it, including when an
--  admin picks somebody else's panel up and puts it back somewhere.
function G.stamp(obj, character)
    if not obj or not character then return end
    -- Not in singleplayer. Ownership means nothing there (G.mayTake), and the
    -- name a singleplayer character carries is forename..surname, which no
    -- server account will ever match: a world moved onto a server would have
    -- every part locked to a player who cannot log in.
    if not isClient() and not isServer() then return end
    local name = try(character, "getUsername")
    if type(name) ~= "string" or name == "" then return end
    P.data(obj).owner = name
end

--- Say WHY a pickup is refused, or the red cursor reads as a bug.
--
--  A halo note rather than a tooltip because the moveable cursor owns its
--  own tooltip surface; rate-limited because mayTake runs every frame the
--  cursor hovers. On a dedicated server the gate runs a second time inside
--  pickUpMoveable, and there setHaloNote only writes the server's own copy
--  of the character, which no player ever sees: the vanilla idiom for a
--  server-side moveable failure is an object change the client renders
--  (ISMoveableSpriteProps.lua:3468).
--
--  Per player, by account name. One Lua state serves every player on a
--  dedicated server, so a single timestamp let one player's refusal swallow
--  the next player's note. A name-keyed table, not one keyed on the character
--  object, which would hold departed players alive. Runtime only, never saved.
local NOTE_EVERY_MS = 3000
local noteSaidAt = {}

local function refuse(character, key, quiet)
    if quiet or not character then return false end
    local now = getTimestampMs and getTimestampMs() or 0
    local who = try(character, "getUsername")
    if type(who) ~= "string" or who == "" then
        who = "#" .. tostring(try(character, "getPlayerNum") or 0)
    end
    if (now - (noteSaidAt[who] or 0)) > NOTE_EVERY_MS then
        noteSaidAt[who] = now
        if isServer() then
            -- The KEY, translated by the client. A dedicated server never
            -- loads mod translations, so getText there hands the key back
            -- and a SET_HALO_NOTE object change would show it verbatim.
            -- OG_Commands turns it into the player's own language.
            if sendServerCommand then
                sendServerCommand(character, "OffGrid", "note",
                                  { key = key, id = try(character, "getOnlineID") })
            end
        elseif character.setHaloNote then
            character:setHaloNote(getText(key))
        end
    end
    return false
end

--- Does this character moderate the server?
--
--  By CAPABILITY, never by role name. B42 replaced the access-level string
--  with roles, and IsoPlayer.getAccessLevel() now returns the role's name
--  (IsoPlayer.java:7603), which for an ordinary player is "user"
--  (Roles.java:364). The old test, "any level other than none", therefore
--  waved every player on every server straight past the owner and
--  screwdriver locks: neither had ever refused anybody in multiplayer.
--
--  Admins hold UseMovablesCheat; moderators hold every capability except
--  that one (Roles.java:450-455), so BanUnbanUser is what they have and a
--  gm, observer, priority or user role does not. A custom role granting
--  either counts too. A character with no role API at all (never true in
--  42.20) falls back to the two staff role names.
function G.isStaff(character)
    if not character then return false end
    local role = try(character, "getRole")
    if role and Capability then
        local caps = { Capability.UseMovablesCheat, Capability.BanUnbanUser }
        for i = 1, 2 do
            if caps[i] ~= nil and try(role, "hasCapability", caps[i]) == true then
                return true
            end
        end
        return false
    end
    local lvl = try(character, "getAccessLevel")
    if type(lvl) ~= "string" then return false end
    lvl = string.lower(lvl)
    return lvl == "admin" or lvl == "moderator"
end

--- A controller that is running, which nobody may lift or turn.
local function running(object)
    return object ~= nil and P.partOf(object) == "controller"
           and try(object, "isActivated") == true
end

--- Is this character allowed to take this part?
--
--  The one owner, tool and switch-off rule, only ever used to turn a true into
--  a false. Anything that is not an OffGrid part, and any case this cannot
--  answer confidently, returns true so the mod never blocks something it does
--  not own. Asked by the canPickUpMoveableInternal hook (every frame on the
--  client's cursor, and again on the authority inside pickUpMoveable when the
--  action completes), by the rotateMoveable wrapper, and through
--  G.mayTakeCell by battery removal (OG_Actions, OG_Bank) and rack
--  destruction, which ask it on the authority. So it is enforced server-side,
--  not only a cursor hint.
--
--  `quiet` answers the question without telling the player anything.
function G.mayTake(character, square, object, quiet)
    if not object or not P.partOf(object) then return true end

    -- A RUNNING controller stays where it is. Removal skips the engine's
    -- setSurroundingElectricity(false) teardown, so the chunk's generator
    -- entries kept powering the neighbourhood off a generator in somebody's
    -- pocket. Vanilla never faces this (its generators are not moveables);
    -- ours are, so the gate is ours to hold. Switching off is instant now,
    -- so the cost is one click.
    if running(object) then
        return refuse(character, "IGUI_OffGrid_SwitchOffFirst", quiet)
    end

    local mode = sandbox("PickupLock")
    if mode == G.LOCK_ANYONE then return true end
    if not character then return true end

    -- Staff are never blocked. The outer canPickUpMoveable already
    -- short-circuits on the movables-cheat toggle before reaching the
    -- internal, so only the role has to be covered here.
    if G.isStaff(character) then return true end

    if mode == G.LOCK_TOOL then
        -- The fail-open stays HERE, not in the helper. A character with no
        -- readable inventory must not be locked out of a part they placed,
        -- whereas the repair menu greying itself out in the same situation is
        -- harmless. Same question, two different right answers on failure.
        local inv = try(character, "getInventory")
        if not inv then return true end
        if P.hasScrewdriver(character) then return true end
        return refuse(character, "Tooltip_OffGrid_NeedScrewdriver", quiet)
    end

    -- G.LOCK_OWNER
    --
    -- Singleplayer is one household and ownership cannot mean anything
    -- there. It is NOT that a singleplayer character has no username: the
    -- engine sets it to forename..surname (IsoPlayer.updateUsername), so a
    -- stamp was a real name and a replacement character after a death, or a
    -- second character in the same world, was locked out of every part the
    -- first one placed, with a red cursor and no reason. Since 2.10.0
    -- singleplayer does not stamp at all (G.stamp). A part stamped there by
    -- an older build keeps that name, and if the world is moved onto a server
    -- only staff or its safehouse can lift it.
    if not isClient() and not isServer() then return true end

    local owner = G.ownerOf(object)
    -- A part placed before this option existed carries no owner. Refusing
    -- those would strand every rig already standing in a live save.
    if not owner then return true end

    local me = try(character, "getUsername")
    if type(me) ~= "string" or me == "" then return true end
    if string.lower(me) == string.lower(owner) then return true end

    -- Anyone the safehouse admits is treated as family: a shared base has to
    -- be tidyable by the people who live in it.
    if SafeHouse and SafeHouse.getSafeHouse and square then
        local ok, sh = pcall(SafeHouse.getSafeHouse, square)
        if ok and sh then
            local ok2, allowed = pcall(sh.playerAllowed, sh, character)
            if ok2 and allowed then return true end
        end
    end

    return refuse(character, "IGUI_OffGrid_NotYours", quiet)
end

--- May this character take a battery out of this rack?
--
--  Only the OWNER lock reaches inside a rack. "Anyone" and "anyone with a
--  screwdriver" are about lifting the part, and a rack's bays have no screws.
--  Under the owner lock, G.mayTake answers for a rack: singleplayer, staff,
--  the owner and their safehouse may; anyone else is told why.
function G.mayTakeCell(character, object, quiet)
    if not object or P.partOf(object) ~= "bank" then return true end
    if sandbox("PickupLock") ~= G.LOCK_OWNER then return true end
    local sq = object.getSquare and object:getSquare()
    return G.mayTake(character, sq, object, quiet)
end

----------------------------------------------------------------- the hooks

-- placeMoveableInternal is handed a square, an item and a sprite name, and no
-- character. The props object does not carry one either (grepped: vanilla
-- never sets self.character). The placer is only in scope one frame up, in
-- placeMoveable. Kahlua is single threaded and placeMoveable calls the
-- internal synchronously, so parking it for the duration of that one call is
-- safe. pcall so an error inside vanilla cannot leave a stale name parked.
local placing = nil
local origPlaceOuter = ISMoveableSpriteProps.placeMoveable
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    local prev = placing
    placing = character
    -- vanilla returns false on refusal and nothing on success: one value
    local ok, res = pcall(origPlaceOuter, self, character, square, origSpriteName, forceAllow)
    placing = prev
    if not ok then error(res, 0) end
    return res
end

-- A ROTATION in progress. Vanilla's rotateMoveable is a pick-up with the gate
-- switched off (_forceAllow) followed by a place (ISMoveableSpriteProps.lua:
-- 2723-2724), and the Rotate cursor only asks canRotateMoveable, which is not
-- even handed the character. Three things went wrong through that door:
--
--  * nobody asked G.mayTake, so any player could turn another player's part,
--    and a running controller could be turned without switching it off;
--  * the place re-stamped the ROTATOR as owner, so a quarter-turn was a change
--    of hands, after which the owner lock let the new "owner" carry it off;
--  * the place took the FIRST item in the bag with the old facing's sprite
--    (findInInventory), so a spare controller carried along was put down in
--    place of the one just lifted, and the rig's wiring stayed in the bag.
--
-- So the rotation is gated here, where the character is in scope, and for its
-- duration the lifted item and the original owner are parked. Same pcall and
-- restore pattern as `placing`.
local rot = nil     -- { character, owner, item } while one rotation runs

--- The Off-Grid part on this square wearing this sprite, found the way
--  vanilla finds a rotation's target (findOnSquare), or nil.
local function partWearing(square, spriteName)
    local ok, found, inst = pcall(function()
        return ISMoveableSpriteProps.new(spriteName):findOnSquare(square, spriteName)
    end)
    if ok and found and not inst and P.partOf(found) then return found end
    return nil
end

--- The movables cheat, which vanilla's own cursor and pick-up let past
--  every gate.
local function movablesCheat(character)
    return try(character, "isMovablesCheat") == true
           or (ISMoveableDefinitions and ISMoveableDefinitions.cheat == true)
end

local origRotate = ISMoveableSpriteProps.rotateMoveable
if origRotate then
    function ISMoveableSpriteProps:rotateMoveable(character, square, origSpriteName)
        local obj = nil
        if square and origSpriteName and P.spriteInfo(origSpriteName) then
            obj = partWearing(square, origSpriteName)
            -- The part changed sprite since the rotation was queued (snow, a
            -- battery, switched on). Vanilla would lift nothing and then
            -- force-place the first bag item wearing the old sprite onto the
            -- occupied square. A no-op instead; the player can turn it again.
            if not obj then return false end
        end
        if obj then
            if not movablesCheat(character) and not G.mayTake(character, square, obj) then
                return false
            end
        end
        local prev = rot
        rot = obj and { character = character, owner = G.ownerOf(obj) } or nil
        local ok, res = pcall(origRotate, self, character, square, origSpriteName)
        rot = prev
        if not ok then error(res, 0) end
        return res
    end
end

-- The Rotate cursor, up front. Its colour, and whether a click queues
-- anything at all, come from canRotateMoveable, asked every frame
-- (ISMoveableCursor.lua:628-629, 640-641; create stops on cannotCreate,
-- 186-195 and 237-250). It is handed the object and not the character, and a
-- running controller is refused on the object alone, so the cursor turns red
-- and no bar runs: the wrapper above used to be the first to say no, after
-- the walk and the whole bar. Only ever adds a refusal. The owner and
-- screwdriver locks need the character, so they refuse on the click instead
-- (walkToAndEquip, below).
local origCanRotate = ISMoveableSpriteProps.canRotateMoveable
if origCanRotate then
    function ISMoveableSpriteProps:canRotateMoveable(square, object, origProps)
        local allowed = origCanRotate(self, square, object, origProps)
        if not allowed then return allowed end
        if running(object) then return false end
        return allowed
    end
end

-- And the reason, in the cursor's own info panel. getInfoPanelFlagsPerTile is
-- where vanilla marks a lit barbecue it will not let you lift, "Needs to be
-- turned off." (ISMoveableSpriteProps.lua:885-888, drawn at 695), and in
-- rotate mode the panel's "Can rotate." is canManuallyRotate, which knows
-- nothing of the refusal above (787, drawn at 677-680). Vanilla's own
-- strings, so every language has them.
local origFlagsPerTile = ISMoveableSpriteProps.getInfoPanelFlagsPerTile
if origFlagsPerTile then
    function ISMoveableSpriteProps:getInfoPanelFlagsPerTile(square, object, player, mode)
        local res = origFlagsPerTile(self, square, object, player, mode)
        if (mode == "rotate" or mode == "pickup") and InfoPanelFlags and running(object) then
            InfoPanelFlags.isOperational = true
            if mode == "rotate" then InfoPanelFlags.canRotate = false end
        end
        return res
    end
end

-- The Rotate cursor's click, for the locks that need the character. The
-- cursor's create queues a rotation only when walkToAndEquip answers yes
-- (ISMoveableCursor.lua:199), and hands it the character, the target square
-- and the mode; in rotate mode it is asked on the props of the sprite the
-- part wears now (origMoveProps, from getRotateableObject, 604 and 860-871).
-- So a player the owner lock refuses, or one without a screwdriver in
-- screwdriver mode, is told why on the click, and no walk or bar starts; it
-- used to come after both. The cursor is still not red for them, since its
-- colour is canRotateMoveable's answer and that has no character. Only ever
-- adds a refusal, before vanilla has walked anywhere, and the rotateMoveable
-- wrapper above still refuses on the authority.
local origWalkTo = ISMoveableSpriteProps.walkToAndEquip
if origWalkTo then
    function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, spriteName)
        if mode == "rotate" and character and square and self.spriteName
                and P.spriteInfo(self.spriteName) then
            local obj = partWearing(square, self.spriteName)
            if obj and not movablesCheat(character)
                    and not G.mayTake(character, square, obj) then
                return false
            end
        end
        return origWalkTo(self, character, square, mode, spriteName)
    end
end

local origFind = ISMoveableSpriteProps.findInInventory
if origFind then
    function ISMoveableSpriteProps:findInInventory(character, spriteName)
        local it = rot and rot.item
        if it and rot.character == character then
            local inv = try(character, "getInventory")
            if inv and try(inv, "contains", it) == true
                    and try(it, "getWorldSprite") == spriteName then
                return it
            end
        end
        return origFind(self, character, spriteName)
    end
end

--- Who owns a part that has just landed. A rotation keeps whoever owned it,
--  and never claims a legacy ownerless part for the rotator; every other
--  placement belongs to the placer.
local function claim(target)
    if not target then return end
    if rot then
        if rot.owner then P.data(target).owner = rot.owner end
        return
    end
    G.stamp(target, placing)
end

local origPlace = ISMoveableSpriteProps.placeMoveableInternal
function ISMoveableSpriteProps:placeMoveableInternal(square, item, spriteName)
    local info = P.spriteInfo(spriteName)
    local obj = origPlace(self, square, item, spriteName)
    if not info or not square then return obj end
    if info.kind == "controller" then
        local gen = G.makeController(square, item, info, obj)
        claim(gen)
        G.push(gen)
        return gen
    end
    G.seed(obj, item, info)
    claim(obj)
    G.push(obj)
    return obj
end

-- One part of each kind per square. A node in the wiring graph is
-- x,y,z,kind (M.nodeKey), and every lookup takes the first part of a kind on
-- a square, so a second one could never be wired: vanilla only refuses a wall
-- object of the SAME facing (ISMoveableSpriteProps.lua:1666-1675), which let
-- a corner take a south rack and an east rack. Only ever adds a refusal.
local origCanPlace = ISMoveableSpriteProps.canPlaceMoveableInternal
if origCanPlace then
    function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
        local allowed = origCanPlace(self, character, square, item, forceTypeObject)
        if not allowed then return allowed end
        local info = self.spriteName and P.spriteInfo(self.spriteName)
        if not info or not square or not square.getObjects then return allowed end
        local objs = square:getObjects()
        for i = 0, objs:size() - 1 do
            if P.partOf(objs:get(i)) == info.kind then return false end
        end
        return allowed
    end
end

local origCanPick = ISMoveableSpriteProps.canPickUpMoveableInternal
function ISMoveableSpriteProps:canPickUpMoveableInternal(character, square, object, isMulti)
    -- Ask the base first and never overturn a refusal. Whatever else is
    -- installed still gets to say no; this only adds a reason to.
    local allowed = origCanPick(self, character, square, object, isMulti)
    if not allowed then return false end
    return G.mayTake(character, square, object)
end

-- A pick-up names its target by the sprite it wore when the action was
-- QUEUED (ISMoveablesAction.new builds moveProps from the object then), and
-- finds it again at completion by exact sprite name (findOnSquare). Off-Grid
-- parts change sprite as they work: a panel under snow, a panel wiped clean,
-- a rack losing a battery, a controller coming on. Any of those during the
-- action made the pick-up find nothing and finish as a silent no-op, the bar
-- running out with the part still standing. Refresh the name from the very
-- object the action captured, only for Off-Grid sprites, and only while that
-- object is still on the square. Every gate after this runs unchanged.
local origPickOuter = ISMoveableSpriteProps.pickUpMoveable
if origPickOuter then
    function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
        local o = self.object
        if o and square and self.spriteName and P.spriteInfo(self.spriteName)
                and P.partOf(o) then
            local objs = square.getObjects and square:getObjects()
            local at = objs and try(objs, "indexOf", o)
            if type(at) == "number" and at >= 0 then
                local spr = try(o, "getSprite")
                local live = spr and try(spr, "getName")
                if live and live ~= self.spriteName and P.spriteInfo(live) then
                    self.spriteName = live
                end
            end
        end
        return origPickOuter(self, character, square, createItem, forceAllow)
    end
end

--- Is another Off-Grid part of this kind still standing on the square?
--  Graph nodes are x,y,z,kind, so a twin (a pair older builds allowed) holds
--  the same node, and unplugging it would cut the wired one's whole chain.
local function kindRemains(square, object, kind)
    local objs = square.getObjects and square:getObjects()
    if not objs then return false end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o ~= object and P.partOf(o) == kind then return true end
    end
    return false
end

local origPick = ISMoveableSpriteProps.pickUpMoveableInternal
function ISMoveableSpriteProps:pickUpMoveableInternal(character, square, object,
                                                      sprInstance, spriteName,
                                                      createItem, rotating)
    local info = object and P.describe(object)
    if info then
        G.stow(object, square, rotating)
        -- Picking a part up unplugs it NOW, on the authority. Its edge used
        -- to stay in the controller's graph until the next half-hourly
        -- relink noticed the square was empty, and a part put back down on
        -- the same square inside that window was still reachable from the
        -- old controller while reading loose, so it could be wired into a
        -- second system and be counted by both, for good.
        if not rotating and info.kind ~= "controller" and not isClient()
                and OffGrid.System and OffGrid.System.unplug and square
                and not kindRemains(square, object, info.kind) then
            OffGrid.System.unplug(M.nodeKey(square:getX(), square:getY(),
                                            square:getZ(), info.kind),
                                  P.data(object).sys)
        end
    end
    -- Vanilla fires the removal event inside this call; a lifted part is not
    -- a destroyed one (see "a part leaving the world").
    local wasKept = removal.kept[object]
    if object then removal.kept[object] = true end
    local ok, item = pcall(origPick, self, character, square, object, sprInstance,
                           spriteName, createItem, rotating)
    if object then removal.kept[object] = wasKept end
    if not ok then error(item, 0) end
    -- A controller lifted for good hands over what it held now, once the
    -- pick-up has really happened and it is off the square (see S.retire,
    -- which also covers a second controller left standing there). A rotation
    -- carries the system on.
    if info and info.kind == "controller" and not rotating and not isClient()
            and OffGrid.System and OffGrid.System.retire and square then
        OffGrid.System.retire(square:getX(), square:getY(), square:getZ(),
                              P.data(object).wire)
    end
    if rot and rotating and item and info and rot.character == character then
        rot.item = item
    end
    -- carry the remaining state onto the item so placing it again restores it
    if item and object and item.getModData then
        local d = object:getModData() and object:getModData().offgrid
        if d then
            local copy = {}
            for k, v in pairs(d) do
                if type(v) ~= "table" and type(v) ~= "userdata" then copy[k] = v end
            end
            -- Wiring does NOT travel. `sys` says which system a part belongs
            -- to and `wire` is a controller's whole graph, and both are
            -- strings, so without this they survive the copy above and a panel
            -- put back down elsewhere claims to be connected to a system it is
            -- nowhere near. Picking a part up unplugs it, which is also what
            -- anyone would expect it to do.
            --
            -- A ROTATION IS NOT A PICK-UP, even though one of vanilla's two
            -- rotate paths is implemented as one. It puts the object back on
            -- the same square, so every edge still points at the right place
            -- and unplugging it would be wrong: the player turned a panel and
            -- their system went dark. The other path rotates in place and
            -- never reaches here at all.
            if not rotating then
                copy.sys = nil
                copy.wire = nil
            end
            -- The loop above drops every table, which is right for `wire` and
            -- wrong for the cells. It has always been wrong for them: the old
            -- `cellTypes` was a table too, so a rack that was picked up and
            -- put back down came back with its batteries all reset to
            -- CarBattery1. Now that a cell also carries its own condition,
            -- losing the list would heal every battery in a rotated rack, so
            -- it is copied out explicitly, element by element. The bay rides
            -- along, or a turned rack put its batteries back in list order.
            if d.cellList then
                local cells = {}
                for i = 1, #d.cellList do
                    local c = d.cellList[i]
                    cells[i] = { id = c.id, type = c.type, health = c.health,
                                 bay = c.bay }
                end
                copy.cellList = cells
                copy.nextCellId = d.nextCellId
            end
            item:getModData().offgrid = copy
            if item.setCondition and d.condition then
                item:setCondition(math.floor(d.condition))
            end
        end
    end
    return item
end

--- Could a dropped controller stand on this neighbour of the dropper?
--  Where vanilla itself would drop an item (ISTransferAction.canDropOnFloor:
--  a floor, not solid, not walled or windowed off from the dropper, the same
--  staircase), with room on that floor when the drop has a floor container
--  to ask, no controller already standing there, and nobody and no vehicle
--  on it: the generator is built the instant it lands, and a solid frame on
--  top of a zombie or under a car is the trap moved, not fixed.
local function landsFree(sq, character, destContainer, item)
    if not ISTransferAction.canDropOnFloor(ISTransferAction, sq, character) then return false end
    if destContainer and ISTransferAction.floorHasRoomFor
            and not ISTransferAction.floorHasRoomFor(ISTransferAction, sq, character, item,
                                                     destContainer) then
        return false
    end
    local movers = try(sq, "getMovingObjects")
    if movers and not movers:isEmpty() then return false end
    if try(sq, "getVehicleContainer") then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if P.partOf(objs:get(i)) == "controller" then return false end
    end
    return true
end

--- Where a controller headed for `square` should land.
--
--  A controller's frame is solidtrans on every facing, and a floor drop
--  builds the generator on the square the drop chose, which is the dropper's
--  own whenever it can be (ISTransferAction.getNotFullFloorSquare, and on a
--  server TransactionManager.getNotFullFloorSquare). Standing inside a solid
--  frame, every walk-to action failed silently until the player stepped off
--  with the movement keys (live test, 2026-09-14). A vanilla generator traps
--  nobody, because its tiles are not solid. So a controller headed for the
--  dropper's own square takes the first neighbour it can stand on, in
--  vanilla's own search order (dy, then dx), and one headed anywhere else,
--  or with no such neighbour, lands where vanilla put it.
function G.landingSquare(character, square, destContainer, item)
    if not square or not ISTransferAction or not ISTransferAction.canDropOnFloor then
        return square
    end
    if square ~= try(character, "getCurrentSquare") then return square end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local sq = getSquare(x + dx, y + dy, z)
                if sq and landsFree(sq, character, destContainer, item) then return sq end
            end
        end
    end
    return square
end

-- Floor drops of a controller: see G.adopt. The inventory transfer (and, on a
-- dedicated server, the dropOnFloor transaction, TransactionProcessor.lua)
-- ends in ISTransferAction:transferItem; placing an item at a spot on the
-- ground ends in ISDropWorldItemAction:complete, and dropping one out of a
-- vehicle in ISDropVehicleItemAction:complete. All run where the item lands.
-- One path has no Lua on it at all: on a server, moving an item from a bag,
-- crate or trunk straight to the floor is done in Java (Transaction.java).
-- A controller that arrives that way is taken charge of the first time
-- anyone wires it, switches it on or sets equalise, and stays unowned; and
-- it lands at the dropper's feet, because G.landingSquare runs only on the
-- Lua paths. Those move a controller off the dropper's own square before
-- vanilla builds it, so no second object, removal or send is involved.
if ISTransferAction and ISTransferAction.transferItem then
    local origTransfer = ISTransferAction.transferItem
    function ISTransferAction:transferItem(character, item, srcContainer, destContainer, dropSquare)
        if dropSquare and destContainer and not isClient()
                and try(destContainer, "getType") == "floor" and isControllerItem(item) then
            local ok, sq = pcall(G.landingSquare, character, dropSquare, destContainer, item)
            if ok and sq then dropSquare = sq end
        end
        local res = origTransfer(self, character, item, srcContainer, destContainer, dropSquare)
        if dropSquare and destContainer and not isClient()
                and try(destContainer, "getType") == "floor" then
            local ok, err = pcall(adoptDropOn, dropSquare, item, character)
            if not ok then print("OffGrid: adopting a dropped controller failed, " .. tostring(err)) end
        end
        return res
    end
end

if ISDropWorldItemAction and ISDropWorldItemAction.complete then
    local origDropComplete = ISDropWorldItemAction.complete
    function ISDropWorldItemAction:complete()
        -- The placement cursor can target the dropper's own square
        -- (IsoGridSquare.isAdjacentTo counts it), so the same rule applies.
        if self.sq and not isClient() and isControllerItem(self.item) then
            local ok, landing = pcall(G.landingSquare, self.character, self.sq, nil, self.item)
            if ok and landing then self.sq = landing end
        end
        local item, sq, who = self.item, self.sq, self.character
        local res = origDropComplete(self)
        if not isClient() then
            local ok, err = pcall(adoptDropOn, sq, item, who)
            if not ok then print("OffGrid: adopting a dropped controller failed, " .. tostring(err)) end
        end
        return res
    end
end

if ISDropVehicleItemAction and ISDropVehicleItemAction.complete then
    local origVehDrop = ISDropVehicleItemAction.complete
    function ISDropVehicleItemAction:complete()
        local item, sq, who = self.item, self.dropSquare, self.character
        local res = origVehDrop(self)
        if not isClient() then
            local ok, err = pcall(adoptDropOn, sq, item, who)
            if not ok then print("OffGrid: adopting a dropped controller failed, " .. tostring(err)) end
        end
        return res
    end
end

------------------------------------------------- a part leaving the world

--  OnObjectAboutToBeRemoved, on the authority (the event also fires on
--  multiplayer clients as the removal arrives). Objects in removal.kept are
--  being lifted by a pick-up or a rotation, and the pick-up hook deals with
--  those itself.
--
--  A controller destroyed hands over what it held (S.retire), for the same
--  reason a lifted one does, but on the next frame. This event fires before
--  the engine takes the object off the square, so S.retire would find the
--  leaving controller still standing, take it for one that stays, and
--  release nothing. And on a server the clients have already dropped it, so
--  a claim pushed from here would be addressed by an index that still counts
--  it, and land on the wrong object for a part standing after it on that
--  same square.
--
--  A battery rack's cells live only in its ModData, so every road out of the
--  world but a pick-up used to delete them. Now a destroyed rack hands its
--  batteries back on the floor, at the charge it held, except when a player
--  the owner lock would not let take a battery out breaks it (a sledgehammer,
--  or the melee hit that finishes it): the cells go with the rack, or
--  breaking it was a way round the lock. Zombies thump rather than hit and
--  are never refused.
--
--  Fire (IsoGridSquare.BurnWalls). A generator it removes outright, through
--  RemoveTileObject or a server's removal packet, and both fire the event, so
--  a burnt controller hands over its system like a destroyed one. It never
--  removes a rack that way: a rack that burns is swapped for a burnt object
--  with no event and its batteries go with it, and one that does not burn
--  keeps them.

local function refuseRefund(obj)
    removal.refused[obj] = true
    removal.refusedThisFrame = true
end

-- The sledgehammer. Marked for exactly the duration of the action's complete,
-- which is where the removal happens on the authority.
if ISDestroyStuffAction and ISDestroyStuffAction.complete then
    local origDestroy = ISDestroyStuffAction.complete
    function ISDestroyStuffAction:complete()
        local item = self.item
        local marked = false
        if item and not isClient() and P.partOf(item) == "bank"
                and not G.mayTakeCell(self.character, item, true) then
            marked = not removal.refused[item]
            removal.refused[item] = true
        end
        local ok, res = pcall(origDestroy, self)
        if marked then removal.refused[item] = nil end
        if not ok then error(res, 0) end
        return res
    end
end

-- A melee weapon. IsoThumpable.WeaponHit fires this before it applies the
-- damage and, when that hit breaks the object, removes it in the same call
-- (IsoThumpable.java:1157-1197). Only the breaking hit may mark the rack: a
-- hit that leaves it standing marks nothing, because on a dedicated server
-- the next frame can be a hundred milliseconds of zombie thumps away.
-- Unreadable health or damage marks it (closed); marks last one frame.
local function onWeaponHitThumpable(character, weapon, obj)
    if isClient() or not obj or P.partOf(obj) ~= "bank" then return end
    if G.mayTakeCell(character, obj, true) then return end
    local hp = try(obj, "getHealth")
    local dmg = try(weapon, "getDoorDamage")
    if type(hp) == "number" and type(dmg) == "number" and hp - dmg > 0 then
        return
    end
    refuseRefund(obj)
end

local function onObjectAboutToBeRemoved(obj)
    if isClient() or not obj or removal.kept[obj] then return end
    local info = P.describe(obj)
    if not info then return end
    if info.kind == "controller" then
        local sq = try(obj, "getSquare")
        if sq and OffGrid.System and OffGrid.System.retire then
            removal.retiring[#removal.retiring + 1] = {
                x = sq:getX(), y = sq:getY(), z = sq:getZ(), wire = P.data(obj).wire }
        end
        return
    end
    if info.kind ~= "bank" then return end
    local sq = try(obj, "getSquare")
    if not sq then return end
    local d = P.data(obj)
    if type(d.cellList) ~= "table" or #d.cellList == 0 then return end
    local cells = G.takeCells(obj, info)
    if removal.refused[obj] then return end
    -- Put on the floor next frame, not here: this event fires from inside the
    -- engine's removal, sometimes in the middle of a walk over the square's
    -- objects, and adding objects to that square there is not worth the risk.
    for i = 1, #cells do
        removal.pending[#removal.pending + 1] = {
            x = sq:getX(), y = sq:getY(), z = sq:getZ(), cell = cells[i] }
    end
end

local function onTick()
    if removal.refusedThisFrame then
        removal.refusedThisFrame = false
        removal.refused = {}
    end
    if #removal.retiring > 0 then
        local gone = removal.retiring
        removal.retiring = {}
        for i = 1, #gone do
            local r = gone[i]
            OffGrid.System.retire(r.x, r.y, r.z, r.wire)
        end
    end
    if #removal.pending == 0 then return end
    local list = removal.pending
    removal.pending = {}
    for i = 1, #list do
        local p = list[i]
        local sq = getSquare(p.x, p.y, p.z)
        if sq then G.giveBackCell(sq, p.cell) end
    end
end

if Events then
    if Events.OnWeaponHitThumpable then Events.OnWeaponHitThumpable.Add(onWeaponHitThumpable) end
    if Events.OnObjectAboutToBeRemoved then Events.OnObjectAboutToBeRemoved.Add(onObjectAboutToBeRemoved) end
    if Events.OnTick then Events.OnTick.Add(onTick) end
end

-- Vanilla's generator Take, on a controller. The context menu strips the
-- Generator submenu, but the Java menu also builds it from the FLOOR a
-- controller stands on and from the joypad prompt, and a Take lifts the
-- generator straight past G.mayTake, G.stow and the switch-off rule. This is
-- the authoritative refusal: isValid on the queueing side, complete where the
-- action runs.
if ISTakeGenerator then
    local origTakeValid = ISTakeGenerator.isValid
    if origTakeValid then
        function ISTakeGenerator:isValid()
            if self.generator and P.partOf(self.generator) == "controller" then
                return false
            end
            return origTakeValid(self)
        end
    end
    local origTakeComplete = ISTakeGenerator.complete
    if origTakeComplete then
        function ISTakeGenerator:complete()
            if self.generator and P.partOf(self.generator) == "controller" then
                return true
            end
            return origTakeComplete(self)
        end
    end
end

return G

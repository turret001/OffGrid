--[[ OffGrid -- the simulation.

     Runs on the server, and in single-player (where lua/server also loads).
     Never on a multiplayer client: the authoritative charge has to live in one
     place, and clients read it back off synced ModData.

     Two things here are worth knowing before changing anything.

     Discovery is free. MapObjects.OnLoadWithSprite is an engine-side index
     from sprite name to callback, fired as chunks stream in, so the mod is
     handed its own objects rather than scanning the world for them. A
     controller that streams in gets a simulation record; a part that streams
     in only tells the systems that may hold it to look again.

     A system is what its controller's wiring reaches, never what stands near
     it. Every connection is one a player made (S.connect), each controller
     keeps its whole graph in its own `wire`, and a relink walks that graph,
     so a part belongs to one system however close it stands to another. The
     model and its caches are written down at "the wiring graph" below.

     Two things walk squares: the appliance load scan, sliced across in-game
     minutes, and the fumes check (foreignGeneratorIn), which walks a
     building's rooms only while that building's toxic flag is up, stops at
     the first foreign generator, and trusts a found one for a while.
]]

if isClient() then return end

require "OffGrid/OG_Model"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Env"

OffGrid = OffGrid or {}
OffGrid.System = OffGrid.System or {}
local S = OffGrid.System
local M = OffGrid.Model
local P = OffGrid.Parts
local E = OffGrid.Env
local try, sandbox = P.try, P.sandbox

-- Caches private to this file, made only by S.resetState. Declared without a
-- value on purpose: a cache resetState forgot would fail on its first use.
local toxicCheck            -- building key -> the foreign generator last found there
local sprinklerGen          -- sprinkler id -> its spray counter at the last look

--- Everything the simulation keeps in memory, none of it saved: all of it is
--  rebuilt from the world as chunks stream in. Made once at load, and by the
--  headless suites between cases, so a table added here is reset everywhere.
function S.resetState()
    S.controllers = {}      -- "x,y,z" -> controller record
    S.order = {}            -- stable iteration order over S.controllers
    S.claimed = {}          -- system ROOT node key -> set of node keys reached
    S.suspect = {}          -- part node keys to re-check once their chunk is in
    S.pendingUnplug = {}    -- root -> set of node keys lifted while it was away
    toxicCheck = {}
    sprinklerGen = {}
end
S.resetState()

local MAX_CATCHUP_HOURS = 72
-- Consecutive ticks the powered/unpowered answer must hold before the
-- generator is actually flipped. One tick is one in-game minute.
local POWER_HOLD = 5

local SLICES = 60           -- in-game minutes a full load scan is spread over
local SYNC_EVERY = 10       -- in-game minutes between multiplayer pushes
local REACH = 3             -- squares; arm's length, the same rule the menus use

-- Watts drawn by each kind of appliance while it is actually running. These
-- are the mod's own numbers: vanilla's getGeneratorPowerConsumption() only
-- ever returns non-zero for fridges, freezers and fuel pumps, so it is no use
-- as a load model.
local DRAW = {
    fridge = 120, freezer = 150, fridgefreezer = 200,
    light = 55, stove = 1400, microwave = 900,
    washer = 480, dryer = 1800, washerdryer = 1200,
    radio = 22, tv = 95, charger = 250,
}

-------------------------------------------------------------------- helpers

local function key(x, y, z) return x .. "," .. y .. "," .. z end

--- Is this table empty? PZ's Kahlua has no global `next` (nor xpcall,
--  loadstring, table.getn, math.random...; tests/test_content.py lists them),
--  so the usual `next(t) == nil` idiom throws "tried to call nil" in game while
--  passing every headless suite that runs on stock Lua.
local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

--- Is the chunk holding this tile actually in memory?
--
--  getSquare() returning nil is ambiguous and the ambiguity matters: it means
--  either "that chunk is not streamed in, ask again later" or "that chunk IS
--  loaded and nothing exists at that z, so whatever used to be there is gone".
--  Reading them as the same thing is why the registry could never prune a part
--  that had been destroyed on a level with no floor under it. IsoCell answers
--  the question directly, and picks the dedicated-server path itself.
local function chunkLoaded(x, y, z)
    local cell = getCell()
    if not cell or not cell.getChunkForGridSquare then return false end
    local ok, chunk = pcall(cell.getChunkForGridSquare, cell, x, y, z)
    return ok and chunk ~= nil
end

--- Push an object's ModData out. IsoObject ModData never syncs on its own;
--  transmitModData() is the explicit push and the engine relevance-filters it.
--
--  Deliberately UNguarded, which vanilla also is. On a server it sends the
--  packet; on a client it sends one too, and this file never runs there
--  (isClient() returns above); and in single-player both branches are skipped
--  and all that happens is flagForHotSave, which is the point -- it is what
--  makes a bank's charge survive without waiting for a full world save. The
--  call is already rate-limited by SYNC_EVERY and by visual change, so this is
--  not a per-tick cost.
local function sync(obj)
    if obj and obj.transmitModData then obj:transmitModData() end
end

-- An appliance nothing here recognises still draws something. The engine's own
-- figure is a balance scale rather than watts (a light switch is 0.002 and a
-- fridge 0.08, which no real pair of appliances is), so there is no honest
-- conversion. This is the median of the mappings below, used only so a modded
-- appliance costs a plausible amount instead of nothing.
local UNKNOWN_WATTS_PER_UNIT = 5000

--- What kind of appliance is this, whether or not it is running.
--
--  Classification is separate from activation so the LOADS page can list
--  a switched-off TV the way a real install sheet would: present, rated,
--  drawing nothing. Fridges and freezers first: the engine collapses both
--  into one constant and the mod wants to tell them apart. Returns kind,
--  rated watts, and whether the kind is refrigeration; nil for anything
--  the ladder cannot name (those still bill as "other" when running, but
--  an unknown idle object has no rated number worth printing).
local function classify(obj)
    local fridge = try(obj, "getContainerByType", "fridge")
    local freezer = try(obj, "getContainerByType", "freezer")
    if fridge and freezer then return "fridgefreezer", DRAW.fridgefreezer, true end
    if fridge then return "fridge", DRAW.fridge, true end
    if freezer then return "freezer", DRAW.freezer, true end
    if instanceof(obj, "IsoLightSwitch") then return "light", DRAW.light, false end
    if instanceof(obj, "IsoStove") then return "stove", DRAW.stove, false end
    if instanceof(obj, "IsoStackedWasherDryer") then
        return "washerdryer", DRAW.washerdryer, false
    end
    if instanceof(obj, "IsoCombinationWasherDryer") then
        return "washerdryer", DRAW.washerdryer, false
    end
    if instanceof(obj, "IsoClothingDryer") then return "dryer", DRAW.dryer, false end
    if instanceof(obj, "IsoClothingWasher") then return "washer", DRAW.washer, false end
    if instanceof(obj, "IsoCarBatteryCharger") then return "charger", DRAW.charger, false end
    if instanceof(obj, "IsoTelevision") then return "tv", DRAW.tv, false end
    if instanceof(obj, "IsoRadio") then return "radio", DRAW.radio, false end
    return nil
end

--- Watts a single world object draws from THIS system right now.
--
--  Returns watts, cold?, kind, rated watts. Kind and rated come back even at
--  zero draw, so the caller can tell "idle appliance" from "not an
--  appliance"; a bare 0 is not an appliance at all.
--
--  The three questions the engine answers better than a hand-written ladder:
--    couldBePoweredByGenerator()   is this a candidate at all
--    ItemContainer.isObjectPowered(obj, false)  is the town grid still paying
--    getGeneratorPowerConsumption() > 0         is it switched on right now
--  This is verbatim the combination IsoGenerator.setSurroundingElectricity
--  uses. Everything a mod subclasses off those nine appliance classes is
--  counted for free, which the old ladder scored as zero.
local function objectDraw(obj)
    if not obj then return 0 end
    if not try(obj, "couldBePoweredByGenerator") then return 0 end
    local kind, rated, coldKind = classify(obj)

    -- Before the hydro shutoff the grid is still paying for this appliance, so
    -- billing it to the bank would invent a load that is not there. Passing
    -- includeGenerators = false is what makes this "grid only".
    if ItemContainer and ItemContainer.isObjectPowered then
        local ok, onGrid = pcall(ItemContainer.isObjectPowered, obj, false)
        if ok and onGrid then return 0, false, kind, rated end
    end

    -- The engine's own on/off answer. A switched-off light, stove, TV, radio,
    -- washer, dryer or charger all return 0 here, which is the half of the old
    -- ladder that was wrong for the charger and missing for stacked units.
    local raw = try(obj, "getGeneratorPowerConsumption") or 0
    if raw <= 0 then return 0, false, kind, rated end

    -- Mirror the engine's own exterior gate. setSurroundingElectricity only
    -- powers an exterior appliance when AllowExteriorGenerator is on
    -- (IsoGenerator.java:315), so with the option off an outdoor floodlight
    -- was BILLED to the bank while drawing nothing the engine would honour --
    -- phantom load, wrong runtime forecast.
    local so = getSandboxOptions and getSandboxOptions()
    local allowExt = so and so:getOptionByName("AllowExteriorGenerator")
    if allowExt and allowExt.getValue and allowExt:getValue() == false then
        local osq = try(obj, "getSquare")
        if osq and try(osq, "isOutside") then return 0, false, kind, rated end
    end

    if kind == "washerdryer" and instanceof(obj, "IsoStackedWasherDryer") then
        -- The only class whose draw is a SUM rather than a ternary: each half
        -- runs independently, so the engine returns 0, 0.9 or 1.8.
        local n = 0
        if try(obj, "isWasherActivated") then n = n + 1 end
        if try(obj, "isDryerActivated") then n = n + 1 end
        if n == 0 then return 0, false, "washerdryer", rated end
        return n == 2 and DRAW.washerdryer or DRAW.washer,
               false, n == 2 and "washerdryer" or "washer", rated
    end
    if kind then return rated, coldKind, kind, rated end

    return raw * UNKNOWN_WATTS_PER_UNIT, false, "other"
end

--- What the vanilla sandbox says a generator's reach is. Off-Grid uses the
--  same numbers on purpose: the controller IS a generator as far as the engine
--  is concerned, and the radius is a private static shared by every generator
--  in the world, so it could not differ even if it wanted to.
local function powerRadius()
    local so = getSandboxOptions()
    local r = so and so:getOptionByName("GeneratorTileRange")
    r = r and r:getValue() or 20
    return r
end

--- The other half of the powered volume. A generator lights a CYLINDER, not a
--  disc: a circle of GeneratorTileRange extruded plus and minus
--  GeneratorVerticalPowerRange (default 3, so seven levels). The scan used to
--  walk three of those seven, which silently under-billed a basement, an upper
--  floor and a roof.
local function powerLevels()
    local so = getSandboxOptions()
    local v = so and so:getOptionByName("GeneratorVerticalPowerRange")
    v = v and v:getValue() or 3
    return v
end

-------------------------------------------------------------- registration

--- The live object of `kind` on a square, or nil. The second value says
--  whether the square is in memory: nil-and-loaded means the part is gone,
--  nil-and-not-loaded means nobody can tell.
local function objectOn(x, y, z, kind)
    local sq = getSquare(x, y, z)
    if not sq then return nil, chunkLoaded(x, y, z) end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if P.partOf(o) == kind then return o, true end
    end
    return nil, true                              -- loaded, and it is gone
end

------------------------------------------------------------ the wiring graph

--  THE MODEL. A controller's `wire` string is the one authority on what is
--  wired to what (see OG_Model). While the controller stands, setWire is the
--  one way its wire changes. When it leaves its square (S.retire) or is found
--  gone from it (S.forget), what it held is released: the whole system, or,
--  when another controller still stands on that square, what that one's
--  graph does not reach. Everything else is a cache of the wire:
--
--    pd.sys           on a part: the root of the system that counts it. Read
--                     by the menus and by S.connect's "already in a system"
--                     rule. Written by S.connect, by relink (which also takes
--                     over a claim whose own controller no longer holds the
--                     part), and by OffGrid.Place.seed when a rotation puts
--                     the same part back; a picked-up item never carries it.
--                     Cleared only through releaseClaim.
--    S.claimed[root]  what that controller's last relink walked. Memory
--                     only, empty after a load.
--    S.pendingUnplug  lifts that could not reach a controller because its
--                     chunk was away; applied at its next relink.
--    S.suspect        parts that streamed in carrying a claim, re-checked
--                     once their controller is in memory.
--
--  Two limits, never confused. MAX_NODES is a CONSTRUCTION rule: S.connect
--  will not grow a system past it. WALK_LIMIT only stops a walk over a
--  corrupt or hand-edited save from hanging the tick. Every walk uses the
--  same bound, so no two walks can disagree about where a graph ends, and a
--  walk that reaches it is treated as incomplete: nothing destructive (a
--  prune, a release) is done on the strength of it.

local MAX_NODES = 96        -- the most parts, controller included, one system may have
local WALK_LIMIT = MAX_NODES * 4

--- Walk a parsed graph from `root`. Returns seen, order, and whether the
--  walk stopped at the safety bound rather than at the end of the graph.
local function walkGraph(edges, root, alive)
    local seen, order = M.wireWalk(edges, root, alive, WALK_LIMIT)
    return seen, order, #order >= WALK_LIMIT
end

--- Every node an edge list names.
local function nodesOf(edges)
    local out = {}
    for i = 1, #edges do
        out[edges[i].a] = true
        out[edges[i].b] = true
    end
    return out
end

--- The controller a system root names, and whether its square is in memory.
local function controllerAt(root)
    local x, y, z = M.parseNodeKey(root)
    if not x then return nil, true end              -- malformed: provably none
    return objectOn(x, y, z, "controller")
end

--- The simulation record for a system root, if that controller is registered.
--
--  Two key spaces meet here. S.controllers is keyed "x,y,z", because a
--  square is one system (a second controller on it, a spare dropped on the
--  floor there, carries the same one; see S.retire); a system root is the 4-part node key
--  "x,y,z,controller" the graph speaks. Passing one where the other is meant
--  fails silently, so the conversion lives here and nowhere else.
local function recordOf(root)
    local x, y, z = M.parseNodeKey(root)
    return x and S.controllers[key(x, y, z)] or nil
end

--- Rebuild a system on its next tick. Returns its record, if registered.
local function relinkSoon(root)
    local rec = recordOf(root)
    if rec then rec.relinkAt = -1 end
    return rec
end

--- Rebuild a system on its next tick and push the result that same tick, for
--  a change a player just made. The Info panel's counts are written after the
--  relink; waiting for the ten-minute sync left "Wired to: array" beside
--  "0 arrays".
local function touchSystem(root)
    local rec = relinkSoon(root)
    if rec then rec.syncIn = 0 end
end

--- Every system that may hold node `nk`: the one its claim names, which
--  survives a load when the claim cache does not, and every one whose last
--  relink walked it.
local function systemsHolding(nk, claim)
    local roots = {}
    if type(claim) == "string" and claim ~= "" then roots[claim] = true end
    for root, set in pairs(S.claimed) do
        if set[nk] then roots[root] = true end
    end
    return roots
end

--- Clear a part's claim, if the claim names `root`. The only way a claim is
--  cleared, and only on proof that `root` does not hold the part. There are
--  three proofs, and they stay three tests on purpose:
--
--    * root's own graph just stopped reaching it (setWire): a relink, a cut,
--      a lift or a rewire changed the wire and the part fell off.
--    * root's controller is missing from a square that is in memory
--      (systemOf). Asked every time a claim is read, so it is the cheap one,
--      and it needs no walk: with no controller there is no graph.
--    * root's controller is in memory and its saved graph does not reach the
--      part (graphReaches, for healSuspects and a target S.connect refuses),
--      walked the way that controller's own next relink will judge it.
--
--  Relink's leaf rule for a part two old systems both hold is not a proof: it
--  only decides which of the two counts the part. A controller releases its
--  own parts and nobody else's, so a part another system counts keeps its
--  owner whatever this one does.
local function releaseClaim(nk, root)
    local x, y, z, kind = M.parseNodeKey(nk)
    if not x or kind == "controller" then return end
    local obj = objectOn(x, y, z, kind)
    if not obj then return end
    local pd = P.data(obj)
    if pd.sys == root then
        pd.sys = nil
        sync(obj)
    end
end

--- Does the controller at `root` hold node `nk`?
--
--  Read from its persisted wire, never from S.claimed, which is empty after a
--  load, and judged the way that controller's own next relink will judge it:
--  a node whose square is in memory with the part gone, or a lift waiting in
--  its pending unplugs, is a break; a node not streamed in is still a path.
--  `wire` walks that string in place of the saved one (S.connect asks about
--  the graph as it would be without the new cable's source). Returns holds,
--  known; known is false when the controller is not in memory, or the walk
--  ran out, which proves nothing either way.
local function graphReaches(root, nk, wire)
    local ctrl, loaded = controllerAt(root)
    if not ctrl then return false, not not loaded end
    local pend = S.pendingUnplug[root]
    local function present(k)
        if pend and pend[k] then return false end
        if k == nk then return true end
        local x, y, z, kind = M.parseNodeKey(k)
        if not x then return false end
        local obj, isLoaded = objectOn(x, y, z, kind)
        return obj ~= nil or not isLoaded
    end
    local seen, _, cut = walkGraph(M.wireParse(wire or P.data(ctrl).wire), root, present)
    if seen[nk] then return true, true end
    return false, not cut
end

--- The graph with every edge its root can no longer walk to removed.
--
--  An edge nothing can reach does nothing, until a new connection lands on
--  one of its ends and brings the whole branch back: that was how cutting a
--  chain in the middle and wiring its far end into a second controller put
--  the tail in BOTH systems. A pure graph walk, so a part in an unloaded chunk
--  is reachable and never pruned; a walk that hit the bound prunes nothing.
--
--  Returns the new string, the reachable set, and whether the walk was cut
--  short (the string then comes back as it was).
local function pruneWire(wire, root)
    wire = wire or ""
    local edges = M.wireParse(wire)
    local seen, _, cut = walkGraph(edges, root, nil)
    if cut then return wire, seen, true end
    local keep = {}
    for i = 1, #edges do
        local e = edges[i]
        if seen[e.a] and seen[e.b] then keep[#keep + 1] = e end
    end
    if #keep == #edges then return wire, seen, false end
    return M.wireEmit(keep), seen, false
end

--- Give a controller its new graph: the one way a wire changes.
--
--  Prunes what the change stranded, pushes the string only when it moved, and
--  releases every part the old string named that the new graph does not
--  reach. Every change to a standing controller's wire comes through here,
--  and a controller that leaves its square hands what it held to S.retire, so
--  the old string always names everything that can fall off: no other record
--  of the graph (the claim cache is empty after a load anyway) is needed to
--  find it. A walk cut short at the safety bound writes the string unpruned
--  and releases nothing on the strength of it. What such a change took out of
--  the string (the far end of a cut, a lifted part) is no longer named by it,
--  so it becomes a suspect instead: healSuspects asks every tick, and releases
--  it once a walk of the graph can finish and does not reach it. Only a
--  hand-edited or corrupt save grows a graph that long. Returns the reachable
--  set and whether the walk was cut short.
local function setWire(ctrl, root, newWire)
    local cd = P.data(ctrl)
    local oldWire = cd.wire or ""
    local wire, reach, cut = pruneWire(newWire, root)
    if wire ~= oldWire then
        cd.wire = wire
        sync(ctrl)
    end
    if not cut then
        for nk in pairs(nodesOf(M.wireParse(oldWire))) do
            if nk ~= root and not reach[nk] then releaseClaim(nk, root) end
        end
    elseif wire ~= oldWire then
        local still = nodesOf(M.wireParse(wire))
        for nk in pairs(nodesOf(M.wireParse(oldWire))) do
            if nk ~= root and not still[nk] then S.suspect[nk] = true end
        end
    end
    return reach, cut
end

-- The controller's daily ledger. Every field is summed into, so a NaN written
-- once stays for good: a controller with no bank wired wrote one into
-- clippedToday on every tick until 2026-09-14 (see gather), and the day roll
-- copied it on into clippedPrev.
local LEDGER_FIELDS = { "clippedToday", "clippedPrev", "shedToday", "shedPrev",
                        "equaliseToday" }

--- Take note of an Off-Grid object as its chunk streams in.
function S.register(obj)
    local sq = obj and obj:getSquare()
    if not sq then return end
    local info = P.describe(obj)
    if not info then return end
    P.data(obj)
    local k = key(sq:getX(), sq:getY(), sq:getZ())

    if info.kind == "controller" then
        -- A save that carries a NaN ledger is healed as it streams in, before
        -- the next tick adds anything to it.
        local cd = P.data(obj)
        for i = 1, #LEDGER_FIELDS do
            local f = LEDGER_FIELDS[i]
            if not M.finite(cd[f] or 0) then cd[f] = 0 end
        end
        -- Re-registration is ROUTINE, not an event: MapObjects fires the
        -- sprite callback on every chunk stream-in, so a controller whose
        -- chunk cycles gets here again with a live record. Replacing that
        -- record zeroed rec.load and rec.drawn, and the catch-up replay then
        -- billed a two-day absence at zero appliance load while crediting two
        -- days of sun -- absence became free energy. Keep the record; it is
        -- keyed by position and the position is identical.
        --
        -- It does invalidate the link cache, though. A chunk that streamed
        -- back in built fresh objects for every part on it, and the record
        -- still held the old ones, which nothing on the square refers to.
        if S.controllers[k] then
            S.controllers[k].relinkAt = -1
            return
        end
        S.order[#S.order + 1] = k
        local d = P.data(obj)
        S.controllers[k] = { key = k, x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                             relinkAt = -1, slice = 0, scanLoad = 0,
                             -- Seed from the demand the tick persisted, so the
                             -- FIRST record after a save-load starts its
                             -- catch-up billing at the load the base really
                             -- had, not at zero for the ~41 replayed hours the
                             -- sliced scan needs to publish its first figure.
                             load = d.demand or 0,
                             scanCold = 0, cold = d.coldWatts or 0,
                             arrays = {}, banks = {},
                             -- Its first sweep publishes as it goes (see
                             -- S.scanSlice), and its appliance list too when
                             -- the save carries none.
                             swept = false, listPending = (d.loadList == nil),
                             syncIn = 0 }
    else
        -- A part saved before 2026-09-14 may carry vanilla's nested copies of
        -- its own ModData from every move (P.VANILLA_CARRIED). Healed as it
        -- streams in; the Off-Grid state is the top-level `offgrid`, which
        -- every one of those moves wrote fresh.
        P.scrubCarried(obj)
        -- Keyed on kind as well as position: see M.nodeKey.
        local nk = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), info.kind)
        -- A part landing (a rotation, a re-placement, a chunk streaming back
        -- in) is a NEW object. Every system that names or walked its square
        -- picks the new one up on its next tick, not in half an hour. A
        -- relink only, not a forced push: a chunk streaming in is routine.
        local sys = P.data(obj).sys
        for root in pairs(systemsHolding(nk, sys)) do relinkSoon(root) end
        -- And whether its claim is still true. Checked on the next tick, not
        -- in the middle of a chunk streaming in (see healSuspects).
        if type(sys) == "string" and sys ~= "" then S.suspect[nk] = true end
    end
end

--- What a controller that left x,y,z held: every node its `wire` named (nil
--  when it could not be read) and every node its last relink walked.
local function heldBy(root, wire)
    local held = nodesOf(M.wireParse(wire or ""))
    for nk in pairs(S.claimed[root] or {}) do held[nk] = true end
    return held
end

--- End the system at x,y,z and drop its record, releasing everything the
--  controller held. A picked-up controller used to leave every part it owned
--  claiming a controller that no longer existed, and a claimed part is never
--  offered "Run cable from here": wired into a ghost, unwireable out of it
--  (the 2026-08-28 report). releaseClaim only clears claims naming this root,
--  so a part it merely walked through keeps its real owner.
local function endSystem(x, y, z, wire)
    local k = key(x, y, z)
    local root = M.nodeKey(x, y, z, "controller")
    for nk in pairs(heldBy(root, wire)) do releaseClaim(nk, root) end
    S.claimed[root] = nil
    S.pendingUnplug[root] = nil
    S.controllers[k] = nil
    for i = #S.order, 1, -1 do
        if S.order[i] == k then table.remove(S.order, i) end
    end
end

--- A record whose controller the tick found gone from a loaded square. The
--  fallback for a controller that left by a road with no removal event
--  (IsoGridSquare.DeleteTileObject, ClearTileObjects); its wire is gone with
--  it, so only what its last relink walked can be released.
function S.forget(k)
    local rec = S.controllers[k]
    if rec then
        endSystem(rec.x, rec.y, rec.z, nil)
    else
        for i = #S.order, 1, -1 do
            if S.order[i] == k then table.remove(S.order, i) end
        end
    end
end

--- A controller has left the square x,y,z for good, carrying `wire`: lifted
--  (not rotated) or destroyed. OffGrid.Place calls this once the object is
--  off the square. Waiting for a tick to find the square empty was not
--  enough: a controller put back on it inside the same minute is a fresh
--  object with no wire under the surviving record, so nothing released the
--  old system and every part of it went on claiming the new controller.
--
--  A square is one system, and it can hold a second controller (a spare
--  dropped on the floor there builds a generator with no occupancy check).
--  Then the system carries on under the one that stays: only what the
--  leaving controller held that the remaining one's graph does not reach is
--  released, and the record relinks on the next tick.
function S.retire(x, y, z, wire)
    local root = M.nodeKey(x, y, z, "controller")
    local stays = objectOn(x, y, z, "controller")
    if not stays then return endSystem(x, y, z, wire) end
    local _, reach, cut = pruneWire(P.data(stays).wire, root)
    if not cut then
        for nk in pairs(heldBy(root, wire)) do
            if nk ~= root and not reach[nk] then releaseClaim(nk, root) end
        end
    end
    touchSystem(root)
end

------------------------------------------------------------------- linking

--- Walk the controller's own wiring graph and collect what it reaches.
--
--  This replaced a proximity sweep, and the difference is the whole feature.
--  The sweep asked "what is near me", which meant a part could be near TWO
--  controllers and be harvested by both, and it meant a panel joined a system
--  by being put down rather than by anybody deciding it should. The walk asks
--  "what did the player wire to me", which has exactly one answer.
--
--  In order: apply lifts that happened while this controller was away, walk
--  (deciding for every node whether it is here, gone, unknown, or owned by
--  another system), drop the edges of what is gone and prune what that
--  stranded, stamp the parts this system counts, and release the parts that
--  are no longer in its graph.
function S.relink(rec)
    local ctrl = objectOn(rec.x, rec.y, rec.z, "controller")
    if not ctrl then
        rec.arrays, rec.banks = {}, {}
        rec.relinkAt = E.worldHours()
        return
    end

    local d = P.data(ctrl)
    local root = M.nodeKey(rec.x, rec.y, rec.z, "controller")

    local wire = d.wire or ""
    local pend = S.pendingUnplug[root]
    if pend then
        S.pendingUnplug[root] = nil
        for nk in pairs(pend) do wire = M.wireDrop(wire, nk) end
    end
    local edges = M.wireParse(wire)
    local degree = {}
    for i = 1, #edges do
        local e = edges[i]
        degree[e.a] = (degree[e.a] or 0) + 1
        degree[e.b] = (degree[e.b] or 0) + 1
    end

    local objOf, gone = {}, {}

    --  `alive` decides each node the walk reaches.
    --
    --  A node whose chunk is not streamed in is unknown, not dead: it stays
    --  traversable and contributes nothing, or walking away from your own base
    --  would sever the chain behind every unloaded part. A node whose square
    --  IS in memory without the part is gone, and so is everything behind it.
    --
    --  ONE owner per part. Saves from before 2.10.0 can carry a part wired
    --  into two systems (a part lifted and put back inside the old relink
    --  window, or a cut branch brought back), which every relink since
    --  counted twice. When a part's claim names another controller whose own
    --  graph still holds it, only that controller counts it. What this one
    --  does with the edges is decided by shape, never by the claim alone:
    --  older relinks re-stamped claims every half hour, so in an old save a
    --  claim only says which controller relinked last. A LEAF here strands
    --  nothing, so its edge goes; a part with more behind it stays walkable
    --  and uncounted, so the chain behind it is not cut. The same when the
    --  other controller is not in memory and there is no telling.
    local function alive(nk)
        local x, y, z, kind = M.parseNodeKey(nk)
        if not x then return false end
        local obj, loaded = objectOn(x, y, z, kind)
        if not obj then
            if loaded then gone[#gone + 1] = nk return false end
            return true
        end
        if kind ~= "controller" then
            local other = P.data(obj).sys
            if type(other) == "string" and other ~= "" and other ~= root then
                local theirs, known = graphReaches(other, nk)
                if theirs and (degree[nk] or 0) <= 1 then
                    gone[#gone + 1] = nk
                    return false
                elseif theirs or not known then
                    return true
                end
                -- the claim it carries is dead; this root takes it
            end
        end
        objOf[nk] = { obj = obj, kind = kind }
        return true
    end

    local seen, order = walkGraph(edges, root, alive)

    -- Everything this graph held before and holds no longer (a middle link
    -- lifted, a pruned tail, a lift applied from the pending list) is
    -- released here. Nothing the walk counted can be among it: a counted part
    -- has a path from the root through parts that are here.
    for n = 1, #gone do wire = M.wireDrop(wire, gone[n]) end
    setWire(ctrl, root, wire)

    local arrays, banks = {}, {}
    for n = 1, #order do
        local hit = objOf[order[n]]
        if hit then
            if hit.kind == "array" then arrays[#arrays + 1] = hit.obj
            elseif hit.kind == "bank" then banks[#banks + 1] = hit.obj end
            if hit.kind ~= "controller" then
                local pd = P.data(hit.obj)
                if pd.sys ~= root then
                    pd.sys = root
                    sync(hit.obj)
                end
            end
        end
    end

    S.claimed[root] = seen

    rec.arrays = arrays
    rec.banks = banks
    rec.relinkAt = E.worldHours()
end

--------------------------------------------------------- making a connection

--- The system a part belongs to, or nil. A controller is its own system.
--
--  A claim is only honoured while its controller can still be found. The check
--  is one-sided about unloaded chunks: no controller on a LOADED square is
--  proof the claim is dead, and being on the authority, proof means the claim
--  is released right here (see releaseClaim); an UNLOADED square proves
--  nothing, so the claim stands and the caller fails at resolving the
--  controller instead, which un-jams itself the moment the chunk streams back
--  in. `obj` is the part objectOn finds at `nk`.
local function systemOf(obj, kind, nk)
    if kind == "controller" then return nk end
    local sys = P.data(obj).sys
    if type(sys) ~= "string" or sys == "" then return nil end
    local ctrl, loaded = controllerAt(sys)
    if not ctrl and loaded then
        releaseClaim(nk, sys)
        return nil
    end
    return sys
end

--- Everything the wire and cut commands agree on, resolved once.
--
--  Nothing here trusts the client. The menu already refuses an illegal
--  connection, and the menu is a convenience, not a gate.
--
--  The reasons are plain strings for the log rather than translation keys.
--  Every one of them is a case the menu will not offer, so a player can only
--  reach them by a desynced client or a modified one, and inventing eight
--  translated sentences nobody is meant to read would be worse than useless.
local function resolveEnds(playerObj, args)
    if type(args) ~= "table" then return nil, "malformed" end
    local ax, ay, az = tonumber(args.ax), tonumber(args.ay), tonumber(args.az)
    local bx, by, bz = tonumber(args.bx), tonumber(args.by), tonumber(args.bz)
    if not (ax and ay and az and bx and by and bz) then
        return nil, "malformed"
    end
    local a = objectOn(ax, ay, az, args.ak)
    local b = objectOn(bx, by, bz, args.bk)
    if not a or not b then return nil, "missing" end
    -- Either end will do. The client walks to the loose end and works there,
    -- but a cable run can be twelve tiles long and there is no position that
    -- is next to both, so insisting on one particular end would refuse work
    -- the player plainly did.
    if playerObj then
        local nearA = math.abs(playerObj:getX() - ax) <= REACH
                      and math.abs(playerObj:getY() - ay) <= REACH
        local nearB = math.abs(playerObj:getX() - bx) <= REACH
                      and math.abs(playerObj:getY() - by) <= REACH
        if not (nearA or nearB) then return nil, "out of reach" end
    end
    -- A player acting on a controller the placement hook never saw (dropped
    -- on the floor: see OffGrid.Place.adopt) takes charge of it first.
    local G = OffGrid.Place
    if G and G.adopt then
        if args.ak == "controller" then G.adopt(a) end
        if args.bk == "controller" then G.adopt(b) end
    end
    return { a = a, b = b,
             ak = args.ak, bk = args.bk,
             akey = M.nodeKey(ax, ay, az, args.ak),
             bkey = M.nodeKey(bx, by, bz, args.bk),
             ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz }
end

--- Take a part out of every graph that holds it. Called when a part is
--  picked up (OG_Place), while it is still on its square.
--
--  `sysHint` is the part's own claim, which names its controller even when
--  the claim cache is empty after a load. A controller in memory drops the
--  part at once, prunes what hung off it and releases that tail (setWire);
--  one that is not remembers the lift and applies it at its next relink, or a
--  part set back down on that square later would be walked straight back in.
function S.unplug(nk, sysHint)
    if type(nk) ~= "string" then return end
    for root in pairs(systemsHolding(nk, sysHint)) do
        local ctrl, loaded = controllerAt(root)
        if ctrl then
            setWire(ctrl, root, M.wireDrop(P.data(ctrl).wire or "", nk))
        elseif loaded == false then
            S.pendingUnplug[root] = S.pendingUnplug[root] or {}
            S.pendingUnplug[root][nk] = true
        end
        if S.claimed[root] then S.claimed[root][nk] = nil end
        touchSystem(root)
    end
end

--- Connect an unwired part to something already in a system.
--
--  The whole invariant lives in this function: the SOURCE must be unwired and
--  the TARGET must already belong to a system. That single rule is why the
--  graph can never contain a cycle, never orphan a branch, and never leave a
--  part in two systems at once.
--
--  Both halves are checked against the controller's graph, not only against
--  the claims: a target whose claim outlived its place in the graph is
--  refused and released, and any stale edge still touching the source is
--  cleared before the new one goes in, so an old branch cannot ride back in.
function S.connect(playerObj, args)
    local e, err = resolveEnds(playerObj, args)
    if not e then return false, err end

    if not M.wireLegal(e.ak, e.bk) then return false, "kinds do not connect" end
    if systemOf(e.a, e.ak, e.akey) then return false, "already in a system" end

    local sys = systemOf(e.b, e.bk, e.bkey)
    if not sys then return false, "target is not in a system" end

    local dx, dy = e.ax - e.bx, e.ay - e.by
    local reach = sandbox("LinkRadius")
    if (dx * dx + dy * dy) > reach * reach then
        return false, "too far"
    end

    local ctrl = controllerAt(sys)
    if not ctrl then return false, "target is not in a system" end

    -- Judged on the graph as it would be without the source's old edges. A
    -- walk cut short at the safety bound proves nothing about the target, so
    -- it refuses first; a system that long is full. The target must then be
    -- held the way the next relink will judge it (graphReaches: a pending
    -- lift or a part gone from a loaded square is a break), or the cable
    -- would be accepted and silently undone a minute later. A refused
    -- target's claim is released only when the saved graph does not hold it
    -- either: one held only through a loose source's own old edges is taken
    -- back, with that source, by the next relink. The wire itself is written
    -- only once the connection is accepted.
    local base, _, cut = pruneWire(M.wireDrop(P.data(ctrl).wire or "", e.akey), sys)
    if cut then return false, "system is full" end
    if e.bk ~= "controller" and not graphReaches(sys, e.bkey, base) then
        local holds, known = graphReaches(sys, e.bkey)
        if known and not holds then releaseClaim(e.bkey, sys) end
        return false, "target is not in a system"
    end
    local nodes = nodesOf(M.wireParse(base))
    nodes[sys] = true
    local count = 0
    for _ in pairs(nodes) do count = count + 1 end
    if count + 1 > MAX_NODES then return false, "system is full" end

    -- Through setWire, so a branch that hung off an old edge of the source
    -- is released as it leaves the graph.
    setWire(ctrl, sys, M.wireAdd(base, e.akey, e.bkey))
    -- Wired into THIS system, so its own pending unplug may not cut it now.
    -- Another controller's pending unplug stays: that one still has to let go
    -- of the part and of the tail that hung off it.
    local pend = S.pendingUnplug[sys]
    if pend then
        pend[e.akey] = nil
        if isEmpty(pend) then S.pendingUnplug[sys] = nil end
    end

    local pd = P.data(e.a)
    pd.sys = sys
    sync(e.a)

    touchSystem(sys)
    return true
end

--- Cut one connection. Everything past the cut stops being reachable, and
--  its edges go with it (pruneWire), so the branch cannot come back through
--  a later connection.
function S.disconnect(playerObj, args)
    local e, err = resolveEnds(playerObj, args)
    if not e then return false, err end

    -- Either end may name the system. Try both: a part left wired into two
    -- graphs by an older build carries only one of them in its claim, and
    -- trying just the first made its own cable uncuttable ("missing").
    local cands = {}
    local sa = systemOf(e.a, e.ak, e.akey)
    local sb = systemOf(e.b, e.bk, e.bkey)
    if sa then cands[#cands + 1] = sa end
    if sb and sb ~= sa then cands[#cands + 1] = sb end
    if #cands == 0 then return false, "target is not in a system" end

    local sys, ctrl, cutWire = nil, nil, nil
    local anyCtrl = false
    for n = 1, #cands do
        local c = controllerAt(cands[n])
        if c then
            anyCtrl = true
            local before = P.data(c).wire or ""
            local after = M.wireRemove(before, e.akey, e.bkey)
            if after ~= before then
                sys, ctrl, cutWire = cands[n], c, after
                break
            end
        end
    end
    if not sys then
        return false, anyCtrl and "missing" or "target is not in a system"
    end

    -- What fell off is released now (setWire), not at the next relink, so the
    -- menus tell the truth the instant the player steps back.
    setWire(ctrl, sys, cutWire)
    touchSystem(sys)
    return true
end

--- Fold the per-square kind splits into one table for the LOADS page, over a
--  cache that only holds squares that actually draw something or hold an
--  idle appliance, so this is a handful of entries.
local function foldKinds(rec)
    local kindsum, idlesum = {}, {}
    for _, e in pairs(rec.drawn) do
        if e.kinds then
            for kk, kw in pairs(e.kinds) do
                kindsum[kk] = (kindsum[kk] or 0) + kw
            end
        end
        if e.idle then
            for kk, kw in pairs(e.idle) do
                idlesum[kk] = (idlesum[kk] or 0) + kw
            end
        end
    end
    rec.kinds = kindsum
    rec.idleKinds = idlesum
end

--- One slice of the appliance load scan. Walks a fraction of the rows each
--  call, so a sweep of the whole powered cylinder (a GeneratorTileRange disc
--  on every GeneratorVerticalPowerRange level, 41x41x7 at the defaults) never
--  lands in a single frame.
function S.scanSlice(rec)
    local radius = powerRadius()
    local rows = radius * 2 + 1
    local perSlice = math.max(1, math.ceil(rows / SLICES))
    if rec.slice <= 0 then rec.scanLoad, rec.scanCold = 0, 0 end

    local startRow = rec.slice
    local endRow = math.min(rows - 1, startRow + perSlice - 1)
    local r2 = radius * radius
    local vr = powerLevels()

    rec.drawn = rec.drawn or {}

    for row = startRow, endRow do
        local dy = row - radius
        for dx = -radius, radius do
            if dx * dx + dy * dy <= r2 then
                for dz = -vr, vr do
                    local x, y, z = rec.x + dx, rec.y + dy, rec.z + dz
                    local s = getSquare(x, y, z)
                    local k = key(x, y, z)
                    if s then
                        local w, cold = 0, 0
                        local kinds, idle = nil, nil
                        local objs = s:getObjects()
                        for i = 0, objs:size() - 1 do
                            -- Locals, deliberately. A Lua multi-return
                            -- collapses to its first value anywhere but the
                            -- final argument slot, so folding this into the
                            -- addition below would silently drop the rest.
                            local ow, isCold, kk, rated = objectDraw(objs:get(i))
                            w = w + ow
                            if isCold then cold = cold + ow end
                            if ow > 0 then
                                kinds = kinds or {}
                                kinds[kk] = (kinds[kk] or 0) + ow
                            elseif kk and rated then
                                -- present but not running: the LOADS page
                                -- lists it dim, at its rated draw
                                idle = idle or {}
                                idle[kk] = (idle[kk] or 0) + rated
                            end
                        end
                        -- Remember, but only what is worth remembering: an
                        -- empty square is the overwhelming majority of a
                        -- 41x41x7 cylinder and holding a zero for each of them
                        -- would be a table of 11,767 entries per controller.
                        -- A square with an idle appliance earns its entry the
                        -- same way a drawing one does; both are rare.
                        if w > 0 or idle then
                            -- The kind split rides in the same cache, so
                            -- squares in unloaded chunks keep their itemised
                            -- entry on the LOADS page, exactly as they keep
                            -- their watts in the total.
                            rec.drawn[k] = { w = w, cold = cold, kinds = kinds,
                                             idle = idle }
                        else
                            rec.drawn[k] = nil
                        end
                        rec.scanLoad = rec.scanLoad + w
                        rec.scanCold = rec.scanCold + cold
                    else
                        -- Not streamed in. Use what this square drew the last
                        -- time it was, so the total does not depend on where
                        -- the player happens to be standing. No invalidation is
                        -- needed: nothing can be added to a square whose chunk
                        -- is not in memory.
                        local c = rec.drawn[k]
                        if c then
                            rec.scanLoad = rec.scanLoad + c.w
                            rec.scanCold = rec.scanCold + c.cold
                        end
                    end
                end
            end
        end
    end

    rec.slice = endRow + 1
    local complete = rec.slice >= rows
    if complete then rec.slice = 0 end

    -- A completed sweep publishes its figures. So does every slice of a
    -- record's FIRST sweep, as far as it has got: a whole sweep is 41 slices
    -- at the default range, and until it finished a controller just put down
    -- billed nothing and listed nothing, and one from a 2.8 save listed
    -- nothing, for most of an in-game hour. The first sweep never lowers the
    -- demand a save carried, and never replaces a saved appliance list with
    -- the part of one it has seen.
    if complete or not rec.swept then
        if complete then
            rec.load = rec.scanLoad
            rec.cold = rec.scanCold or 0
        else
            rec.load = math.max(rec.load or 0, rec.scanLoad)
            rec.cold = math.max(rec.cold or 0, rec.scanCold or 0)
        end
        if complete or rec.listPending then foldKinds(rec) end
        if complete then
            rec.swept = true
            rec.listPending = false
        end
    end
end

------------------------------------------------------------------ weather

--- Snow on the glass and dust between rains, both per mount and per grade.
--  This is where the mod earns its winter: an array under snow makes nothing
--  at all until someone goes out and sweeps it, and a flat roof panel will
--  not shed by itself.
function S.weatherArray(d, info, env, dt, sunlit)
    if not sunlit or info.mount == "wall" then
        d.snow = 0
    else
        d.snow = M.snowCover(d.snow, info.mount, env, dt,
                             sandbox("SnowRate") / 100)
    end

    local spec = M.arraySpec(info.tier)
    local soilRate = (sandbox("SoilRate") / 100) * spec.soil
    if (env.precipitation or 0) > 0.25 and not env.snowing and not env.noWash
            and sunlit then
        d.soiling = M.clamp((d.soiling or 0) - 0.35 * dt, 0, 1)   -- rain washes
    else
        d.soiling = M.clamp((d.soiling or 0) + 0.004 * soilRate * dt, 0, 1)
    end

    -- weather wears a frame down, and a scrap frame faster
    if sunlit and (env.precipitation or 0) > 0.4 then
        d.condition = M.clamp((d.condition or 100) - 0.010 * spec.wear * dt,
                              0, 100)
    end
end

------------------------------------------------------------- sprinklers

--- Which Water Pipes sprinklers watered during the last game minute.
--
--  Water Pipes (Workshop 3546314080) exposes no event and no API; its whole
--  state is the server-side ModData table "WaterPipes", where each sprinkler
--  is `Sprinklers["x-y-z"] = { x, y, z, w, wmax, gen }` and `gen` counts the
--  minutes it actually sprayed. Keying on a CHANGE in gen rather than on the
--  transient `w` makes this independent of which mod's EveryOneMinute handler
--  ran first. Everything is pcall'd: another mod's schema is not ours to
--  trust, and a change there must cost a wash, never the tick.
--
--  A running sprinkler rinses the glass of any array within its five-tile
--  reach, exactly as rain does. Snow is left alone: a sprinkler is not a
--  broom, and in the cold the pipes would not be running anyway.
local SPRINKLER_RADIUS2 = 25

local function sprinklersRunning()
    local out = {}
    if not (ModData and ModData.exists) then return out end
    local ok = pcall(function()
        if not ModData.exists("WaterPipes") then return end
        local wp = ModData.get("WaterPipes")
        local list = wp and wp.Sprinklers
        if type(list) ~= "table" then return end
        for id, s in pairs(list) do
            if type(s) == "table" and type(s.x) == "number"
                    and type(s.y) == "number" then
                local gen = tonumber(s.gen) or 0
                local last = sprinklerGen[id]
                sprinklerGen[id] = gen
                if last ~= nil and gen ~= last then
                    out[#out + 1] = { x = s.x, y = s.y, z = tonumber(s.z) or 0 }
                end
            end
        end
    end)
    if not ok then return {} end
    return out
end

local function sprinkled(wet, x, y, z)
    for i = 1, #wet do
        local s = wet[i]
        if s.z == z then
            local dx, dy = s.x - x, s.y - y
            if dx * dx + dy * dy <= SPRINKLER_RADIUS2 then return true end
        end
    end
    return false
end

--------------------------------------------------------------- the tick

--- Build the model's view of one controller's system.
local function gather(rec, env)
    local bankScale = P.bankScale()
    local arrays, panels, shaded = {}, 0, 0
    local byTier = { array = {}, bank = {} }

    for i = 1, #rec.arrays do
        local o = rec.arrays[i]
        local info = P.describe(o)
        local sq = o:getSquare()
        if info and sq then
            local d = P.data(o)
            byTier.array[info.tier] = (byTier.array[info.tier] or 0) + 1
            if E.isSunlit(sq) then
                arrays[#arrays + 1] = {
                    facing = info.facing, mount = info.mount, tier = info.tier,
                    panels = d.panels or M.arraySpec(info.tier).panels,
                    condition = d.condition or 100,
                    soiling = d.soiling or 0, snow = d.snow or 0,
                }
                panels = panels + (d.panels or M.arraySpec(info.tier).panels)
            else
                -- an array under a roof is still wired in and still counted;
                -- it just never sees the sun, and saying so is the difference
                -- between a bug report and a lesson about where to bolt it
                shaded = shaded + 1
            end
        end
    end

    -- Aggregate the banks. A mixed system shares one state of charge, so the
    -- efficiency and depth-of-discharge that govern it are the blend of what
    -- is actually wired in, weighted by how much each one holds with the
    -- weather taken out. Weighted by the cold figure, a frost moved the
    -- blend: a scrap crate derates harder than a sealed cabinet, so a mixed
    -- bank's floor slid toward the cabinet's 8 percent as the night cooled
    -- and back as it warmed, and the floor is what must not move (M.step).
    local cap, nominal, charge, wSum = 0, 0, 0, 0
    local effW, dodW, decayW, healthW = 0, 0, 0, 0
    local cells, cellCap = 0, 0
    for i = 1, #rec.banks do
        local o = rec.banks[i]
        local info = P.describe(o)
        if info then
            local d = P.data(o)
            local spec = M.bankSpec(info.tier)
            byTier.bank[info.tier] = (byTier.bank[info.tier] or 0) + 1
            local shape = { tier = info.tier, cellSum = P.cellSum(d), scale = bankScale }
            local c = M.bankCapacity(shape, env.temperature)
            local nom = M.bankNominalWh(shape)
            cap = cap + c
            nominal = nominal + nom
            charge = charge + (d.charge or 0)
            cells = cells + (d.cells or 0)
            cellCap = cellCap + M.bankCells(info.tier, info.mount)
            local w = math.max(nom, 1)
            wSum = wSum + w
            effW = effW + spec.eff * w
            dodW = dodW + spec.dod * w
            decayW = decayW + spec.decay * w
            healthW = healthW + P.bankHealth(d) * w
        end
    end
    if wSum <= 0 then
        -- No bank wired at all, so there is no efficiency, floor or wear rate
        -- to blend. Dividing the empty sums gave 0 for each: the model stored
        -- at a charge efficiency of zero, its 0/0 put NaN into the day's
        -- clipping (live test, 2026-09-14), and BATT drew a 0% floor. Left
        -- out, the model's own defaults stand. An empty RACK is not this: it
        -- still has its grade's numbers.
        return arrays, panels, { capacity = 0, nominal = 0, charge = 0, cells = 0,
                                 cellCap = 0, health = 1 }, byTier, shaded
    end

    return arrays, panels, {
        capacity = cap, nominal = nominal, charge = charge, cells = cells,
        cellCap = cellCap,
        health = healthW / wSum,
        eff = effW / wSum, dod = dodW / wSum, decay = decayW / wSum,
    }, byTier, shaded
end

--- Push the model's bank result back across the physical banks.
--
--  Split by NOMINAL capacity, so every rack in a system sits at the same fill
--  of what its cells can hold. It used to split by the cold-derated figure,
--  and grades derate differently (a sealed cabinet keeps 74% in the cold, a
--  scrap crate 42%), so a frost pushed the cabinet's share above what its
--  cells hold at all. Nothing is lost while the charge sits in the system, but
--  a battery unbolted from that rack came out full and the excess was simply
--  gone (installCell and G.stow both clamp against nominal). The total can
--  never exceed the nominal sum, because charging stops at the cold capacity,
--  which is never above nominal. The sprite's state of charge is still read
--  against the cold capacity, which is what the rack will deliver now.
local function scatter(rec, bank, env, healthDelta)
    local bankScale = P.bankScale()
    local caps, noms, total = {}, {}, 0
    for i = 1, #rec.banks do
        local o = rec.banks[i]
        local info = P.describe(o)
        local d = P.data(o)
        caps[i] = info and M.bankCapacity({ tier = info.tier,
                                            cellSum = P.cellSum(d),
                                            scale = bankScale },
                                          env.temperature) or 0
        noms[i] = info and M.bankNominal({ tier = info.tier, scale = bankScale,
                                           cellList = d.cellList }) or 0
        total = total + noms[i]
    end
    for i = 1, #rec.banks do
        local o = rec.banks[i]
        local d = P.data(o)
        local share = total > 0 and (noms[i] / total) or 0
        d.charge = bank.charge * share
        -- The tick's health change, applied to this bank's OWN figure. Writing
        -- the blended value here instead used to flatten a sealed cabinet and a
        -- scrap crate onto the same number, which matters now that only one of
        -- them can be equalised back.
        if healthDelta and healthDelta ~= 0 then
            -- Onto the cells, which is where the damage physically is. The
            -- rack's health is now the mean of them, so this still moves the
            -- reported figure by the same amount it always did.
            P.applyBankHealth(d, healthDelta)
        end
        local soc = caps[i] > 0 and math.min(1, d.charge / caps[i]) or 0
        P.setState(o, P.bankState(d, soc))
    end
end

-- Health a running equalisation recovers every flooded rack to, and the health
-- below which it is worth offering. Apart on purpose: while any rack is below
-- EQUALISE_WORTH the charge runs, and brings the others the rest of the way
-- to full; once none is, a rack a rounding error short of full is no reason
-- to keep the option on the menu, or switched on.
local EQUALISE_TO = 1
local EQUALISE_WORTH = 0.999

--- A rack an equalisation charge can help: a flooded grade (sealed cells
--  cannot vent the gas it makes), holding cells, below `below` health.
--  Returns its description and data, or nil.
local function equalisable(o, below)
    local info = P.describe(o)
    if not (info and M.canEqualise(info.tier)) then return nil end
    local d = P.data(o)
    if (d.cells or 0) <= 0 or P.bankHealth(d) >= below then return nil end
    return info, d
end

--- Spend clipped energy on recovering flooded banks.
--
--  Funded ONLY by surplus that had nowhere else to go, so equalising never
--  competes with the load: in July the array clips several kWh a day and this
--  is somewhere for it to go, and in January there is no surplus and no
--  recovery. Sealed cells are skipped, because an equalisation charge produces
--  gas they cannot vent.
--
--  Returns the Wh actually spent, so the caller can report it.
local function equalise(rec, env, surplusWh, dt)
    if (surplusWh or 0) <= 0 or (dt or 0) <= 0 then return 0 end
    local bankScale = P.bankScale()
    local spent, left = 0, surplusWh
    for i = 1, #rec.banks do
        if left <= 0 then break end
        local info, d = equalisable(rec.banks[i], EQUALISE_TO)
        if info then
            -- Nameplate capacity, not the cold- and health-derated figure:
            -- what a recovery costs should not depend on the weather.
            local spec = M.bankSpec(info.tier)
            local nameplate = (d.cells or 0) * spec.wh * bankScale
            local before = P.bankHealth(d)
            local h, wh = M.equaliseStep(before, left, nameplate, dt)
            -- Same delta onto every cell. An equalisation charge really
            -- does recover sulphated lead-acid capacity, so a rack can
            -- recondition worn batteries; at EQUALISE_COST 4x nameplate
            -- and EQUALISE_RATE 0.02/hour that is about 37 hours of
            -- genuine surplus from the floor to full. Deliberate.
            --
            -- Billed for what LANDED, not for what was asked. Cells
            -- already at 1.0 absorb nothing, so on a mixed rack the mean
            -- rises by less than equaliseStep's contract -- and the old
            -- code deducted the full figure anyway, destroying the
            -- clamped share of the surplus and re-billing at the inflated
            -- rate every tick until the one damaged cell healed alone.
            local wanted = h - before
            local achieved = P.applyBankHealth(d, wanted)
            local billed = wanted > 0 and wh * (achieved / wanted) or 0
            left = left - billed
            spent = spent + billed
        end
    end
    return spent
end

--- Is a generator we do not own running inside this building?
--
--  Asked only just before the fumes flag comes down (clearOurToxic), so only
--  a YES is kept. A "nothing foreign here" is never taken from an earlier
--  walk: a flag that reads toxic when it should not is exactly what a petrol
--  generator switched on a moment ago looks like (setActivated marks the
--  building at once, IsoGenerator.java:524-527), and clearing it on a stale
--  answer gave that generator's fumes a free pass. A yes is trusted for
--  FOREIGN_RECHECK_H while the generator the walk found is still running in
--  the world, so a running petrol generator costs one room walk per ten
--  in-game minutes rather than one per frame of the sweep in clearToxicFast.
local FOREIGN_RECHECK_H = 10 / 60   -- in-game hours a found generator is trusted for

local function foreignGeneratorIn(building)
    local def = building and building.getDef and building:getDef()
    if not def or not def.getX then return false end
    local key = def:getX() .. "," .. def:getY()

    local now = E.worldHours()
    local c = toxicCheck[key]
    if c then
        local age = now - c.at
        -- age < 0: the clock was set back (debug, admin); walk again
        if age >= 0 and age < FOREIGN_RECHECK_H
                and try(c.gen, "isActivated") == true
                and (try(c.gen, "getObjectIndex") or -1) >= 0 then
            return true
        end
    end

    local foundGen = nil
    local rooms = def.getRooms and def:getRooms()
    if rooms then
        for i = 0, rooms:size() - 1 do
            local rd = rooms:get(i)
            local room = rd and rd.getIsoRoom and rd:getIsoRoom()
            local squares = room and room.getSquares and room:getSquares()
            if squares then
                for j = 0, squares:size() - 1 do
                    local g = P.generatorsOn(squares:get(j))
                    if g then foundGen = g break end
                end
            end
            if foundGen then break end
        end
    end
    toxicCheck[key] = foundGen and { at = now, gen = foundGen } or nil
    return foundGen ~= nil
end

--- Take a building's fumes flag back down, unless a generator we do not own
--  is running in it. An activated generator marks its building toxic and a
--  solar controller emits nothing, so the flag has to come off; but
--  IsoBuilding.setToxic is ONE boolean for the whole building with no record
--  of who set it, and clearing it unconditionally also cleared the carbon
--  monoxide of a petrol generator in the same house, which made a controller
--  an immunity token. Only when the flag is actually up: setToxic sends a
--  packet on a server every time it is called (IsoBuilding.java:566-570).
local function clearOurToxic(building)
    if building and building.setToxic and try(building, "isToxic")
            and not foreignGeneratorIn(building) then
        building:setToxic(false)
    end
end

local function driveGenerator(gen, sq, online, soc)
    if not gen then return end
    -- pinned high: under 20 condition a generator randomly backfires, starts
    -- fires and explodes, and none of that belongs to a solar controller
    if try(gen, "getCondition") ~= 100 then gen:setCondition(100) end
    -- The vanilla fuel gauge becomes the state-of-charge gauge; fuel is capped
    -- at a hard-coded 10.0 in the engine, so the real charge in Wh lives in
    -- ModData and this is only the display value. Written only on a visible
    -- change: setFuel calls sync() unconditionally on both server and client.
    -- The fuel gauge is DISPLAY ONLY, and the engine must never be allowed to
    -- run its own fuel economy against it. IsoGenerator.update() burns
    -- totalPowerUsing * GeneratorFuelConsumption off the gauge every in-game
    -- hour and force-deactivates at zero (IsoGenerator.java:196-218) -- so
    -- mirroring the live load into setTotalPowerUsing meant the ENGINE cut the
    -- power near the top of every hour at low charge, driveGenerator switched
    -- it back on a minute later, and every flap re-aged the whole larder
    -- twice. totalPowerUsing stays 0 (nothing to burn), and the gauge is
    -- floored just off zero while power is meant to flow, because the
    -- engine's zero-check is `fuel <= 0` and the old 0.05 write deadband
    -- could pin a sub-0.5%-SOC gauge at exactly 0 forever.
    -- A controller ON FIRE holds no fuel at all. BurnWalls adds explosive
    -- power for any generator whose fuel reads above zero (IsoGridSquare.java
    -- 6776-6778), and the gauge mirrors the state of charge, so a burning
    -- solar controller went up like a full petrol generator and took the
    -- neighbouring squares with it. It is off while the square burns, and
    -- comes back by the normal path once the fire is out.
    local burning = sq and try(sq, "haveFire") == true
    if burning then online = false end
    local want = online and math.max(0.2, soc * 10) or M.clamp(soc * 10, 0, 10)
    local have = try(gen, "getFuel") or -1
    if burning then
        if have ~= 0 then gen:setFuel(0) end
    elseif math.abs(want - have) > 0.05 then
        gen:setFuel(want)
    end
    if try(gen, "isActivated") ~= online then gen:setActivated(online) end
    if gen.setTotalPowerUsing then gen:setTotalPowerUsing(0) end
    clearOurToxic(sq and sq:getBuilding())
end

--- The environment as it stood `hoursAgo` hours before now.
--  Only the clock is rewound. The weather it carries is today's, because the
--  engine keeps no history a mod can read -- but the SUN is geometry, and
--  replaying a gap without moving the sun would charge a bank at midnight.
--  A slice on an earlier day takes that date's engine day too, so it keeps
--  that day's dawn and dusk and not today's. A replay has no daylight gate
--  (the live strength is about now), so the engine day is all that keeps an
--  Endless Night replay dark.
local function rewind(env, hoursAgo)
    if not hoursAgo or hoursAgo <= 0 then return env end
    local e = {}
    for k, v in pairs(env) do e[k] = v end
    local h = env.hour - hoursAgo
    local days = 0
    while h < 0 do
        h = h + 24
        days = days + 1
    end
    e.hour = h
    if days > 0 then
        local y, m0, d = E.dateAt(-days)
        e.month, e.day = m0 + 1, d
        e.dayOfYear = M.dayOfYear(m0 + 1, d)
        e.noon, e.dayHours, e.sky = E.skyDay(y, m0, d)
    end
    e.daylight = nil
    return e
end

--- Has a part the last relink cached left its square since?
--
--  The record holds object references, and the objects change under it: a
--  rotation removes the part and puts a NEW object down, a pick-up removes it,
--  a chunk streaming back in builds fresh ones. A removed IsoObject keeps its
--  square pointer (IsoObject.removeFromSquare only unlinks it), so the tick
--  went on billing, charging and re-spriting the object that had left for up
--  to half an hour: a rack turned every few minutes at night drained the ghost
--  while the real one sat full. getObjectIndex is -1 for anything no longer in
--  its square's list (IsoObject.java:4839).
function S.staleLinks(rec)
    local lists = { rec.arrays, rec.banks }
    for l = 1, 2 do
        local list = lists[l] or {}
        for i = 1, #list do
            local ix = try(list[i], "getObjectIndex")
            if type(ix) ~= "number" or ix < 0 then return true end
        end
    end
    return false
end

--- Weather acts on the physical arrays, not the model's copy of them: snow,
--  soiling and the sprite that shows both. `wet` is the list of sprinklers
--  that ran this minute, nil on a replay (see S.updateController).
local function weatherArrays(rec, env, dt, wet)
    for i = 1, #rec.arrays do
        local o = rec.arrays[i]
        local ai = P.describe(o)
        if ai then
            local ad = P.data(o)
            local osq = o:getSquare()
            S.weatherArray(ad, ai, env, dt, E.isSunlit(osq))
            if wet and #wet > 0 and osq
                    and sprinkled(wet, osq:getX(), osq:getY(), osq:getZ()) then
                ad.soiling = M.clamp((ad.soiling or 0) - 0.35 * dt, 0, 1)
            end
            P.setState(o, P.arrayState(ad))
        end
    end
end

--- Carry the model's load-shed decision onto the controller.
--
--  The switch stays the player's; the model never writes it now. The
--  disconnect is the model's and clears itself. d.trip is never written
--  true again, but a save that carries it still reads as tripped until
--  its owner presses Reset, which clears both.
local function recordShed(rec, d, sys, tel, now, replay)
    d.lvd = sys.lvd and true or false
    d.lvdSoc = tel.reconnectSoc
    -- One slice can both close a shed (it started at the reconnect charge)
    -- and open a new one (the load ran the bank out again before it ended);
    -- a one-hour catch-up slice does it routinely. The opening is the later
    -- event, so it wins: letting the close clear the stamp after it left a
    -- REAL shed unstamped, and the forced-shed release in updateController
    -- let the load back on at any charge on the next tick.
    if tel.lvdOpened then
        d.lvdAt = now
    elseif tel.lvdClosed or not d.lvd then
        d.lvdAt = nil
    end
    if replay then return end
    if tel.lvdOpened then
        print(string.format(
            "OffGrid: load shed at %d,%d,%d, bank at %d%% under %d W, back at %d%%",
            rec.x, rec.y, rec.z, math.floor((tel.soc or 0) * 100 + 0.5),
            math.floor((sys.load or 0) + 0.5),
            math.floor((tel.reconnectSoc or 0) * 100 + 0.5)))
    elseif tel.lvdClosed then
        -- The charge the decision was made on, at the start of the tick. The
        -- end of the tick has already had the minute's sun or load on it, and
        -- printed "bank at 32%" straight after "back at 35%".
        print(string.format("OffGrid: load back on at %d,%d,%d, bank at %d%%",
            rec.x, rec.y, rec.z, math.floor((tel.socIn or 0) * 100 + 0.5)))
    end
end

--- Start a new ledger day when the calendar day has changed.
--
--  The model has always computed clipping and shedding and the system used to
--  throw them away. They are the only numbers in the mod that argue for a
--  specific next build: clipping high means the bank is too small for the
--  panels, shedding high means the panels are too small for the load. Kept
--  per day so the figure the player reads is a whole day's worth and not a
--  tick's. Must run before anything this tick adds to a daily figure.
--
--  The calendar day, NOT worldHours/24: that clock's epoch is 07:00 (see
--  E.dayIndex), so its "days" run 07:00 to 07:00 and every figure that claims
--  to be daily would roll seven hours late. On a save from 2.8.x ledgerDay
--  holds the old small ordinal, which reads as one day change: the daily
--  counters reset once, and that is the migration.
local function rollLedger(d)
    local day = E.dayIndex()
    if d.ledgerDay == day then return end
    d.clippedPrev = d.clippedToday or 0
    d.shedPrev = d.shedToday or 0
    d.clippedToday, d.shedToday = 0, 0
    d.equaliseToday = 0
    -- The DAY trace clears HERE and nowhere later: any later "did the day
    -- change" test would compare against the ledgerDay this just updated.
    d.dayHist = {}
    d.ledgerDay = day
end

--- Run the equalisation charge, and decide whether it stays on offer.
--
--  Equalisation eats the clip before it is recorded as waste, because that is
--  exactly what it is for: the surplus stops being thrown away and starts
--  buying back the one quantity nothing else can. So this runs before the
--  day's clipping is added up, and takes what it spent off tel.wasted.
local function runEqualise(rec, d, env, tel, dt, sliceToday)
    local recovered = 0
    if d.equalise then
        recovered = equalise(rec, env, tel.wasted or 0, dt)
        tel.wasted = math.max(0, (tel.wasted or 0) - recovered)
        -- The recovery itself always applies; the "today" READOUT only
        -- counts today's slices (see sliceToday).
        if sliceToday then
            d.equaliseToday = (d.equaliseToday or 0) + recovered
        end
    end
    d.recovered = recovered

    -- Whether the option is worth offering at all: at least one flooded bank
    -- with cells, below full health. A sealed cabinet can never be equalised
    -- and a healthy bank has nothing to gain, so this is what keeps the row
    -- off the menu except when it is the right thing to do. It also switches
    -- a running equalisation off by itself once there is nothing left to
    -- recover, so it is not a switch the player has to remember.
    local canEq = false
    for i = 1, #rec.banks do
        if equalisable(rec.banks[i], EQUALISE_WORTH) then
            canEq = true
            break
        end
    end
    d.canEqualise = canEq
    if not canEq then d.equalise = false end
end

--- The cold chain.
--
--  Refrigeration is the only load whose interruption has a lasting cost, and
--  the cost is a cliff rather than a slope: vanilla thaws an unpowered freezer
--  over exactly 1.5 game hours and only then flips the frozen flag, after
--  which everything in it rots five times faster. So the number worth putting
--  in front of the player is not the state of charge, it is how many hours of
--  refrigeration the bank can still carry, measured against how much darkness
--  is left tonight. Down to the floor the load actually stops at, which is a
--  share of what the cells hold, not of the cold-adjusted capacity (M.step).
local function writeColdChain(d, bank, env, coldW)
    d.coldWatts = coldW
    d.coldHours = M.coldHours(bank.charge or 0, coldW, bank.dod, bank.nominal)
    local darkLeft = M.darkHoursLeft(env)
    d.darkHours = darkLeft
    local safe, gap = M.coldSafe(d.coldHours, darkLeft)
    d.coldSafe = safe
    d.coldGap = gap
    d.coldReserve = M.coldReserve(coldW, darkLeft, bank.dod, bank.nominal)
end

--- The monitor's LOADS, BATT and DAY pages.
local function writePages(rec, d, env, tel, sliceToday)
    -- LOADS: what is drawing, itemised, then what is merely connected, dim at
    -- its rated draw. A plain array of pairs rather than a keyed table, so the
    -- client draws it in a stable order. Active rows always outrank idle
    -- ones; a kind that is both (two TVs, one on) shows as its active row
    -- only, because the row's number is a bill, not a survey.
    if rec.kinds then
        local ll = {}
        for kk, kw in pairs(rec.kinds) do
            ll[#ll + 1] = { k = kk, w = math.floor(kw + 0.5) }
        end
        table.sort(ll, function(a, b) return a.w > b.w end)
        local il = {}
        for kk, kw in pairs(rec.idleKinds or {}) do
            if not rec.kinds[kk] then
                il[#il + 1] = { k = kk, w = math.floor(kw + 0.5), idle = true }
            end
        end
        table.sort(il, function(a, b) return a.w > b.w end)
        for i = 1, #il do ll[#ll + 1] = il[i] end
        while #ll > 9 do table.remove(ll) end
        d.loadList = ll
    end

    -- BATT: every cell's health across the wired banks, in bank order, capped
    -- at what the screen can show.
    local cellsOut = {}
    for i = 1, #rec.banks do
        local bd = P.data(rec.banks[i])
        local list = bd.cellList or {}
        for n = 1, #list do
            if #cellsOut < 12 then
                cellsOut[#cellsOut + 1] =
                    math.floor((list[n].health or 1) * 100 + 0.5)
            end
        end
    end
    d.bankCells = cellsOut

    -- DAY: Wh actually received, bucketed by hour since midnight. A
    -- controller records; it does not forecast. rollLedger owns the midnight
    -- reset; here only accumulate, and only from slices inside today (see
    -- sliceToday). Index by the time-of-day clock (already rewound for
    -- catch-up slices), never by worldHours % 24, whose 07:00 epoch would
    -- shift every bar.
    if sliceToday then
        local hourIx = math.floor((env.hour or 12) % 24) + 1
        local hist = type(d.dayHist) == "table" and d.dayHist or {}
        hist[hourIx] = (hist[hourIx] or 0) + (tel.generated or 0)
        d.dayHist = hist
    end
end

--- Whether the controller should be powering the house, held still.
--
--  IsoGenerator.setActivated is punishingly expensive on a state CHANGE: it
--  calls updateFridgeFreezerItems(), which walks a 41x41 disc across seven
--  levels re-aging every food item in every fridge and freezer it finds, and
--  then setSurroundingElectricity() across a 49-chunk block. Twice a day at
--  dawn and dusk is fine. The problem is a bank sitting near empty with
--  generation and load close to balance: the raw predicate then flips every
--  single game minute, and every flip re-ages the whole larder.
--
--  So the answer has to hold still before it is acted on. The predicate is
--  read every tick, but the answer only changes once the new one has survived
--  POWER_HOLD consecutive ticks.
--
--  Except a shed the bank really ran into (d.lvdAt stamped), which cuts the
--  power on the tick it opens, the way the switch does. The disconnect opens
--  at the damage floor, so five more minutes of load would take the bank
--  under it; and a shed load is not billed, so five more minutes of lights
--  would be power nobody paid for (live test, 2026-09-14: the fridge was
--  still powered the minute after LOAD SHED). The way back on still waits out
--  the hold, which keeps a bank too small for one minute of its load to two
--  flips in six minutes. A forced shed (no cells) keeps the debounce; it has
--  no bank to protect.
local function holdPower(d, bank, tel)
    if d.lvd and d.lvdAt ~= nil then
        d.poweredWant, d.poweredHold, d.powered = false, 0, false
        return false
    end
    local want = (d.online and not d.lvd and (bank.cells > 0)
                  and (tel.arrayWatts > 0 or (bank.charge or 0) > 0)) and true or false
    if want ~= d.poweredWant then
        d.poweredWant = want
        d.poweredHold = 0
    else
        d.poweredHold = (d.poweredHold or 0) + 1
    end
    local powered = d.powered
    if powered == nil then powered = want end          -- first tick, no delay
    if want ~= powered and (d.poweredHold or 0) >= POWER_HOLD then
        powered = want
    end
    d.powered = powered
    return powered
end

--- Advance one controller. `hoursAgo` > 0 replays a slice of a gap.
--
--  The order is the point, and every step below is its own function so the
--  sequence reads here: link and scan, build the model's view, step the
--  model, act on the physical parts, record what happened, then drive the
--  generator, write down what it serves, and push.
function S.updateController(rec, dt, hoursAgo, wet)
    local gen, loaded = objectOn(rec.x, rec.y, rec.z, "controller")
    if not gen then
        if loaded then S.forget(rec.key) end
        return
    end
    local sq = gen:getSquare()

    local d = P.data(gen)
    local info = P.describe(gen)
    local ctrl = M.ctrlSpec(info and info.tier or "basic")
    local envNow = E.read()
    local env = rewind(envNow, hoursAgo)
    local now = E.worldHours()
    local replay = (hoursAgo or 0) > 0
    -- Does this slice lie inside TODAY? A catch-up replay walks the sun back
    -- across the missed days, and folding those days' generation into one
    -- 24-bucket trace showed a returning player double sun on the DAY page.
    -- Anything labelled "today" only accumulates from today's slices.
    local sliceToday = (hoursAgo or 0) <= (envNow.hour or 12) + 0.001
    local simLoad = sandbox("SimulateLoad") ~= false

    env.outputScale = sandbox("OutputScale") / 100
    env.degrade = sandbox("DegradeBank") ~= false

    if rec.relinkAt >= 0 and S.staleLinks(rec) then rec.relinkAt = -1 end
    if rec.relinkAt < 0 or (now - rec.relinkAt) >= 0.5 then
        S.relink(rec)
    end
    S.scanSlice(rec)

    local arrays, panels, bank, byTier, shaded = gather(rec, env)
    local lvdBefore = d.lvd == true
    local sys = { arrays = arrays, bank = bank,
                  load = simLoad and (rec.load or 0) or 0,
                  online = d.online and not d.trip,
                  lvd = d.lvd == true,
                  inverterEff = ctrl.eff, harvest = ctrl.harvest }
    -- Whether the house had power over the minute being billed: the generator
    -- as the last tick left it. The engine state, not d.powered, which the
    -- burning square and the switch-off action both overrule on the object
    -- itself. A replay has no record of it and bills as powered.
    if not replay then sys.powered = try(gen, "isActivated") == true end
    -- Nothing to draw from (no bank wired, or a rack with no cells) means
    -- the load is shed, not billed. The want-predicate never powers such a
    -- system, so charging its non-existent bank for the load was a trip a
    -- minute after dusk on a rig that had lit nothing.
    --
    -- A shed forced this way is released the moment cells are fitted. Only
    -- a REAL shed (the bank ran out under a load, which stamps d.lvdAt)
    -- waits for the reconnect threshold; a forced one never had a bank to
    -- run down, and holding it to 25% left a rig with fresh cells and no
    -- load dark in full sun until the bank crept up.
    if (bank.capacity or 0) <= 0 then
        sys.lvd = true
    elseif sys.lvd and d.lvdAt == nil then
        sys.lvd = false
    end

    -- A catch-up replay carries no weather history: it moves the sun back
    -- and keeps TODAY'S sky for every replayed hour. Snow is the one part of
    -- that which compounds, so a blizzard at the moment of return buried
    -- every array under three days it never saw. So a replay withholds the
    -- cover, and ALSO the wash that falling snow does not give: clearing
    -- `snowing` alone turned a blizzard's precipitation into a rain wash on
    -- every replayed hour. env is rewind()'s copy here, never the live one.
    if replay and env.snowing then
        env.snowing = false
        env.noWash = true
    end

    local healthBefore = bank.health or 1
    local _, tel = M.step(sys, dt, env)
    local healthDelta = (bank.health or 1) - healthBefore

    -- Sprinklers only on a live tick: a replay has no record of who watered.
    -- `wet` is read ONCE per minute by S.tick and handed to every controller;
    -- sprinklersRunning advances its baseline as it reads, so reading it here
    -- per controller let the first rig each minute take every wash.
    weatherArrays(rec, env, dt, not replay and wet or nil)
    scatter(rec, sys.bank, env, healthDelta)
    recordShed(rec, d, sys, tel, now, replay)

    d.demand = sys.load
    d.gen = tel.arrayWatts
    d.soc = tel.soc
    d.capacity = tel.capacity
    d.charge = tel.charge
    d.panels = panels
    d.cells = bank.cells
    d.cellCap = bank.cellCap
    d.health = bank.health
    d.dod = bank.dod
    -- The floor on the scale d.soc is printed on (M.step): BATT draws its
    -- tick and its DOD FLOOR figure from this, so both move up the gauge in
    -- the cold together with the point where the load really drops.
    d.floorSoc = tel.floorSoc
    d.irradiance = tel.irradiance

    rollLedger(d)
    runEqualise(rec, d, env, tel, dt, sliceToday)
    d.clippedToday = (d.clippedToday or 0) + (tel.wasted or 0)
    d.shedToday = (d.shedToday or 0) + (tel.deficit or 0)

    writeColdChain(d, bank, env, simLoad and (rec.cold or 0) or 0)
    d.arrayCount = #rec.arrays
    d.shaded = shaded
    d.bankCount = #rec.banks
    writePages(rec, d, env, tel, sliceToday)
    d.tiers = byTier
    d.lastHour = now

    local powered = holdPower(d, bank, tel)
    driveGenerator(gen, sq, powered, tel.soc or 0)
    -- What the system is actually SERVING, which is nothing while it is
    -- offline. The measured demand in the radius is kept separately
    -- (d.demand): an offline controller reading "Using 530 W" next to a
    -- positive net was simply untrue, and the number the player wants in that
    -- state is what it would cost to switch back on. Read off the generator
    -- once it has been driven, not off the step, which bills the minute that
    -- has passed: the tick a shed opened printed that minute's load under
    -- LOW BATT, and STARTING UP printed a load nothing was getting.
    d.load = (try(gen, "isActivated") == true and not d.lvd) and (sys.load or 0) or 0
    local visualChanged = P.setState(gen, powered and "on" or "off")

    rec.syncIn = (rec.syncIn or 0) - 1
    -- A shed changing hands is pushed at once, whichever way it changed: a
    -- forced shed raises neither telemetry flag, so a Reset (which clears
    -- d.lvd) followed by the forcing putting it straight back showed the
    -- wrong state on every client for up to ten minutes.
    if visualChanged or tel.lvdOpened or tel.lvdClosed
            or (d.lvd == true) ~= lvdBefore or rec.syncIn <= 0 then
        rec.syncIn = SYNC_EVERY
        sync(gen)
        for i = 1, #rec.arrays do sync(rec.arrays[i]) end
        for i = 1, #rec.banks do sync(rec.banks[i]) end
    end
end

--- Clear `sys` on parts that streamed in claiming a system whose graph no
--  longer holds them (see S.register).
local function healSuspects()
    if isEmpty(S.suspect) then return end
    local list = S.suspect
    S.suspect = {}
    for nk in pairs(list) do
        local x, y, z, kind = M.parseNodeKey(nk)
        local obj = x and kind ~= "controller" and objectOn(x, y, z, kind)
        if obj then
            local pd = P.data(obj)
            local sys = pd.sys
            if type(sys) == "string" and sys ~= "" then
                local reaches, known = graphReaches(sys, nk)
                if known and not reaches then
                    releaseClaim(nk, sys)
                elseif not known then
                    -- Its controller is not streamed in: ask again next tick.
                    -- A part whose own chunk leaves drops out (objectOn is
                    -- nil) and comes back through S.register.
                    S.suspect[nk] = true
                end
            end
        end
    end
end

--- The heartbeat. One in-game minute of simulation per call, with catch-up
--  for the time a chunk spent unloaded.
function S.tick()
    local now = E.worldHours()
    healSuspects()
    -- Once per minute for the whole world; see the note in updateController.
    local wet = sprinklersRunning()
    for i = #S.order, 1, -1 do
        local rec = S.controllers[S.order[i]]
        if not rec then
            table.remove(S.order, i)
        else
            local gen = objectOn(rec.x, rec.y, rec.z, "controller")
            local last = gen and (P.data(gen).lastHour or -1) or -1
            local dt = (last < 0) and (1 / 60) or (now - last)
            if dt > 0 then
                if dt > MAX_CATCHUP_HOURS then dt = MAX_CATCHUP_HOURS end
                if dt > 1.5 then
                    -- A long gap: replay it hour by hour so the sun follows
                    -- its real arc across the missed days rather than being
                    -- frozen at whatever o'clock the player came back at.
                    local remaining = dt
                    while remaining > 0.0001 do
                        local step = math.min(1.0, remaining)
                        S.updateController(rec, step, remaining)
                        remaining = remaining - step
                    end
                else
                    S.updateController(rec, dt, nil, wet)
                end
            end
        end
    end
end

--------------------------------------------------------- commands from a client

--  Everything a player does to a system has to be applied HERE, on the
--  authority, and never on the client.
--
--  The reason is specific and it already bit this mod: an IsoObject's ModData
--  is one blob, and a client calling transmitModData() sends its whole copy
--  up, where the server replaces the object's table with it wholesale. So a
--  client that sets one flag and pushes also overwrites the live charge, cell
--  count and health that only the server has been maintaining. The flag looks
--  like it worked and a bank quietly loses its contents.
--
--  In single player there is no client and no packet: OG_Context calls
--  S.onCommand directly. The same validation runs either way, because the
--  point of validating is not the network, it is that only one place should
--  decide whether an action is legal.

local function commandTarget(playerObj, args, kind)
    if type(args) ~= "table" then return nil end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then return nil end
    if playerObj then
        -- Re-checked server side. The client menu already refuses out of
        -- reach, but a client is not evidence.
        if math.abs(playerObj:getX() - x) > REACH
                or math.abs(playerObj:getY() - y) > REACH then
            return nil
        end
    end
    local obj = objectOn(x, y, z, kind)
    return obj
end

local COMMANDS = {}

function COMMANDS.connect(playerObj, args)
    local ok, why = S.connect(playerObj, args)
    if not ok then print("OffGrid: refused a connection, " .. tostring(why)) end
end

function COMMANDS.disconnect(playerObj, args)
    local ok, why = S.disconnect(playerObj, args)
    if not ok then print("OffGrid: refused a cut, " .. tostring(why)) end
end

function COMMANDS.equalise(playerObj, args)
    local obj = commandTarget(playerObj, args, "controller")
    if not obj then return end
    if OffGrid.Place and OffGrid.Place.adopt then OffGrid.Place.adopt(obj) end
    local d = P.data(obj)
    d.equalise = args.on and true or false
    sync(obj)
end

--- Entry point for both paths. Returns true if the command was known.
function S.onCommand(command, playerObj, args)
    local fn = COMMANDS[command]
    if not fn then return false end
    fn(playerObj, args)
    return true
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= "OffGrid" then return end
    S.onCommand(command, playerObj, args)
end

------------------------------------------------------------------- events

--- The engine re-asserts building-wide toxicity for ANY activated indoor
--  generator once per in-game hour, and toxic damage is charged per FRAME
--  (about 3 HP per real second). driveGenerator's clear runs on the minute
--  tick, which left occupants breathing a solar controller's nonexistent
--  exhaust for up to 2.5 real seconds every hour -- a slow, mystifying HP
--  bleed. This sweep runs per render tick and normally does nothing: it only
--  pays when a managed controller's building actually reads toxic, and it
--  still defers to any real generator sharing the house.
local function clearToxicFast()
    for i = 1, #S.order do
        local rec = S.controllers[S.order[i]]
        if rec then
            local gen = objectOn(rec.x, rec.y, rec.z, "controller")
            if gen and try(gen, "isActivated") then
                local sq = gen:getSquare()
                clearOurToxic(sq and sq:getBuilding())
            end
        end
    end
end
Events.OnTick.Add(clearToxicFast)

--- A fire starting on a controller's square: take the fuel off before the
--  first BurnWalls runs (the event fires inside IsoFire's constructor,
--  IsoFire.java:250). driveGenerator keeps it at zero while the square burns.
local function onNewFire(fire)
    local sq = fire and try(fire, "getSquare")
    local objs = sq and sq.getObjects and sq:getObjects()
    if not objs then return end
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if P.partOf(o) == "controller" then
            if (try(o, "getFuel") or 0) ~= 0 then o:setFuel(0) end
            if try(o, "isActivated") then o:setActivated(false) end
        end
    end
end
Events.OnNewFire.Add(onNewFire)

local function onLoadPart(obj)
    S.register(obj)
end

local function registerSprites()
    local PRIORITY = 6
    for row = 1, #P.ROWS do
        for col = 0, P.COLS - 1 do
            local name = P.TILESET .. "_" .. ((row - 1) * P.COLS + col)
            MapObjects.OnLoadWithSprite(name, onLoadPart, PRIORITY)
            MapObjects.OnNewWithSprite(name, onLoadPart, PRIORITY)
        end
    end
end

-- Registered NOW, at file load, not just on OnGameStart. The engine streams
-- the login area's chunks during the loading screen and fires
-- MapObjects.loadGridSquare THEN (IsoChunk.java:3822); OnGameStart triggers
-- only after loading ends (IngameState.java:761). Registering there meant a
-- rig you logged in NEXT TO never registered that session -- its accounting
-- froze, silently papered over by the engine still powering appliances and
-- by the 72h catch-up replay once the chunk re-streamed. The event hooks
-- stay as belt and braces (OnLoadWithSprite at equal priority replaces, so
-- re-registration is idempotent).
registerSprites()
Events.OnGameStart.Add(registerSprites)
Events.OnServerStarted.Add(registerSprites)
Events.EveryOneMinute.Add(S.tick)
Events.OnClientCommand.Add(onClientCommand)

return S

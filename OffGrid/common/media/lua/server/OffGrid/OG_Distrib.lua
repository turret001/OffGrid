--[[ OffGrid -- what a system adds beyond its controller's own circle.

     Two things reach further than the controller: TRANSFORMERS, parts in the
     cable graph that each light a generator's circle of their own, and WIRED
     BUILDINGS, footprints (map buildings and player-built structures, chosen
     with Wire up the building or the Building Picker) that are lit by one
     relay per chunk and vertical band. The controller stays a real
     IsoGenerator and keeps its own circle; everything here is chunk
     registrations, kept by OG_Grid on every side.

     This file owns, per system:

       * the PLAN (D.plan): transformer circles, the relays for every wired
         footprint, and the list of SHAPES the whole system lights -- the
         controller's cylinder first, then each circle, then each relay's
         chunk band;
       * PUBLISHING it (D.publish): the registry entry for the system, on or
         off with the controller, written only when it changes;
       * BILLING over it (D.sweep, D.near): the load scan walks the shapes, a
         square billed once by the first shape that holds it, so an appliance
         in a wired building 60 tiles away is on the LOADS page and one in the
         overlap of two circles is counted once. A system with nothing extra
         never comes here: OG_System's own sweep is unchanged for it;
       * the COMMANDS (bwDefault, bwClear, bwPick), validated here on the
         authority, never trusted from the client.

     A part's choices live on the part as strings -- `bw`, its targets, and
     `bwr`, their footprints as rects -- because table fields do not survive
     a pick-up or a rotation (OG_Place). The footprint is resolved here, on
     the authority, and stored, so the overlay on every client draws exactly
     what the server wired, even for a player-built structure a dedicated
     server knows only as regions.
]]

if isClient() then return end

require "OffGrid/OG_Model"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Reach"
require "OffGrid/OG_Grid"
require "OffGrid/OG_Buildings"
require "OffGrid/OG_System"

OffGrid = OffGrid or {}
OffGrid.Distrib = OffGrid.Distrib or {}
local D = OffGrid.Distrib
local M = OffGrid.Model
local P = OffGrid.Parts
local R = OffGrid.Reach
local B = OffGrid.Buildings
local try, sandbox = P.try, P.sandbox

local floor = math.floor

-- Targets one part may wire, and the squares the sweep reads per tick (an
-- unloaded chunk unit costs UNLOADED_COST against it: it is summed from a
-- stored total, not read).
D.MAX_TARGETS = 8
D.BUDGET = 400
D.UNLOADED_COST = 8
-- The least time between two wiring commands from one player on a server, in
-- real milliseconds. Nobody clicking through the picker comes near it; a
-- client sending commands in a loop cannot make the server re-plan every tick.
D.CMD_GAP_MS = 250
-- In-game hours between re-reading a wired player-built structure, so one
-- that has been extended is lit to its new walls.
D.REFRESH_HOURS = 0.5

local function Grid() return OffGrid.Grid end
local function Sys() return OffGrid.System end
local function I() return OffGrid.System.internals() end

local function range()
    local r = floor(tonumber(I().powerRadius()) or 20)
    local v = floor(tonumber(I().powerLevels()) or 3)
    if r < 1 then r = 1 end
    if v < 0 then v = 0 end
    return r, v
end

local function worldHours()
    return OffGrid.Env and OffGrid.Env.worldHours and OffGrid.Env.worldHours() or 0
end

------------------------------------------------------------------- targets

--- A part's targets, each with its stored rects string.
local function targetsOf(obj)
    local d = P.data(obj)
    local list = B.decodeTargets(d.bw)
    local rects, i = {}, 1
    for seg in string.gmatch((d.bwr or "") .. "|", "([^|]*)|") do
        rects[i] = seg
        i = i + 1
    end
    for n = 1, #list do list[n].rects = rects[n] or "" end
    return list
end
D.targetsOf = targetsOf

local function writeTargets(obj, list)
    local d = P.data(obj)
    local rects = {}
    for n = 1, #list do rects[n] = list[n].rects or "" end
    local bw = B.encodeTargets(list)
    local bwr = table.concat(rects, "|")
    if bw == "" then bw, bwr = nil, nil end
    if d.bw == bw and d.bwr == bwr then return false end
    d.bw, d.bwr = bw, bwr
    I().sync(obj)
    return true
end

--- Every part of a system that can wire a building: the controller, then its
--  transformers in walk order.
local function partsOf(rec, ctrl)
    local parts = { ctrl }
    for i = 1, #(rec.xfmrs or {}) do parts[#parts + 1] = rec.xfmrs[i] end
    return parts
end

--  What each transformer wires, kept on the controller as one string
--  ("nodekey#bw#bwr~..."), so a transformer whose square is out of memory
--  keeps its circle and its buildings in the plan. The relink cannot see a
--  part it cannot load, and a plan made without it unpublished everything it
--  lit: standing at home with a far transformer out of range, then walking
--  out to its buildings, found them dark (live, 2026-09-24).
local function readFar(ctrl)
    local out = {}
    local s = P.data(ctrl).xbw
    if type(s) ~= "string" then return out end
    for entry in string.gmatch(s, "[^~]+") do
        local nk, bw, bwr = string.match(entry, "^([^#]*)#([^#]*)#([^#]*)$")
        if nk and nk ~= "" then out[nk] = { bw = bw, bwr = bwr } end
    end
    return out
end

--- The cache from the transformers in memory now, keeping what it knew of
--  the ones out of range and dropping the ones that left the system.
local function writeFar(rec, ctrl)
    local old, new = readFar(ctrl), {}
    for i = 1, #(rec.xfmrs or {}) do
        local o = rec.xfmrs[i]
        local sq = o:getSquare()
        if sq then
            local d = P.data(o)
            new[M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "transformer")] = { bw = d.bw or "", bwr = d.bwr or "" }
        end
    end
    for i = 1, #(rec.far or {}) do
        local f = rec.far[i]
        if f.kind == "transformer" and old[f.nk] then new[f.nk] = old[f.nk] end
    end
    local keys = {}
    for nk in pairs(new) do keys[#keys + 1] = nk end
    R.sort(keys, function(a, b) return a < b end)
    local bits = {}
    for i = 1, #keys do
        local e = new[keys[i]]
        bits[#bits + 1] = keys[i] .. "#" .. e.bw .. "#" .. e.bwr
    end
    local s = table.concat(bits, "~")
    if s == "" then s = nil end
    local cd = P.data(ctrl)
    if cd.xbw ~= s then
        cd.xbw = s
        I().sync(ctrl)
    end
end

--- The transformers of the system that are out of memory, as far as the
--  controller last knew them: { x, y, z, nk, bw, bwr } each.
local function farParts(rec, ctrl)
    local out = {}
    local known = nil
    for i = 1, #(rec.far or {}) do
        local f = rec.far[i]
        if f.kind == "transformer" then
            known = known or readFar(ctrl)
            local e = known[f.nk] or { bw = "", bwr = "" }
            out[#out + 1] = { x = f.x, y = f.y, z = f.z, nk = f.nk, bw = e.bw, bwr = e.bwr }
        end
    end
    return out
end
D.farParts = farParts

--- A far part's targets, read from its cached strings.
local function targetsOfFar(fp)
    local list = B.decodeTargets(fp.bw)
    local rects, i = {}, 1
    for seg in string.gmatch((fp.bwr or "") .. "|", "([^|]*)|") do
        rects[i] = seg
        i = i + 1
    end
    for n = 1, #list do list[n].rects = rects[n] or "" end
    return list
end

--- Are some of this system's panels or batteries out of memory while its
--  controller is in it? Then the live tick cannot see its energy: it would
--  read an empty bank and shed, and the snapshot it took would be of an
--  empty system (live, 2026-09-24: a far house went dark and stayed dark).
--  Such a system is treated as away: the tick waits, and the snapshot
--  estimate keeps its grid switching, until every part is back. Only for a
--  system that reaches beyond its own circle, where that grid is somewhere
--  a player can be.
--- Has any part the last relink could not see come back into memory? Then
--  the system relinks before this tick counts anything, so a rack that just
--  streamed in is counted at once rather than read as missing.
function D.farBack(rec)
    for i = 1, #(rec and rec.far or {}) do
        local f = rec.far[i]
        if I().chunkLoaded(f.x, f.y, f.z) then return true end
    end
    return false
end

function D.partial(rec)
    if not (rec and rec.plan and rec.plan.extra) then return false end
    for i = 1, #(rec.far or {}) do
        local k = rec.far[i].kind
        if k == "array" or k == "bank" then return true end
    end
    return false
end

------------------------------------------------------------------- the plan

--- A square no relay may stand on: one holding a generator (removing our
--  entry there would take the generator's own with it) or an Off-Grid part.
local function avoid(x, y, z)
    local sq = getSquare(x, y, z)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if instanceof(o, "IsoGenerator") or P.partOf(o) then return true end
    end
    return false
end

--- Build a system's plan from its parts as they stand.
function D.plan(rec, ctrl)
    local r, v = range()
    local parts = partsOf(rec, ctrl)

    local far = farParts(rec, ctrl)
    local circles = {}
    for i = 2, #parts do
        local sq = parts[i]:getSquare()
        if sq then circles[#circles + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ() } end
    end
    for i = 1, #far do circles[#circles + 1] = { x = far[i].x, y = far[i].y, z = far[i].z } end

    local fp = R.fpNew()
    local ids, boxes, nTargets = {}, {}, 0
    local lists = {}
    for i = 1, #parts do lists[#lists + 1] = targetsOf(parts[i]) end
    for i = 1, #far do lists[#lists + 1] = targetsOfFar(far[i]) end
    for i = 1, #lists do
        local list = lists[i]
        for n = 1, #list do
            local t = list[n]
            local rects = R.decodeRects(t.rects)
            if #rects > 0 then
                nTargets = nTargets + 1
                ids[#ids + 1] = t.k .. ":" .. t.id
                local tfp = R.fpOfRects(rects)
                if t.k == "s" then
                    local x0, y0, x1, y1, z0, z1 = R.fpBounds(tfp)
                    boxes[#boxes + 1] = x0 .. "," .. y0 .. "," .. x1 .. "," .. y1 .. "," .. z0 .. "," .. z1
                end
                R.fpMerge(fp, tfp)
            end
        end
    end

    local relays, dark = {}, 0
    if fp.count > 0 then relays, dark = R.planRelays(fp, r, v, avoid) end

    local shapes = { R.circleShape(rec.x, rec.y, rec.z, r, v) }
    for i = 1, #circles do
        local c = circles[i]
        shapes[#shapes + 1] = R.circleShape(c.x, c.y, c.z, r, v)
    end
    for i = 1, #relays do
        local p = relays[i]
        shapes[#shapes + 1] = R.relayShape(p.x, p.y, p.z, r, v)
    end

    local entry = { c = R.encodePositions(circles), r = R.encodePositions(relays),
                    t = table.concat(ids, ";"), b = table.concat(boxes, ";") }
    return { shapes = shapes, index = R.chunkIndex(shapes), entry = entry,
             extra = #shapes > 1, targets = nTargets, squares = fp.count,
             dark = dark, r = r, v = v,
             hash = entry.c .. "|" .. entry.r .. "|" .. r .. "|" .. v }
end

--- Everything the plan is made from, as one string: when it has not
--  changed, the plan has not either.
local function signature(rec, ctrl)
    local r, v = range()
    local bits = { r .. "," .. v }
    local parts = partsOf(rec, ctrl)
    for i = 1, #parts do
        local o = parts[i]
        local sq = o:getSquare()
        local d = P.data(o)
        bits[#bits + 1] = (sq and (sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()) or "?")
                          .. "|" .. (d.bw or "") .. "|" .. (d.bwr or "")
    end
    local far = farParts(rec, ctrl)
    for i = 1, #far do
        bits[#bits + 1] = "far " .. far[i].nk .. "|" .. far[i].bw .. "|" .. far[i].bwr
    end
    return table.concat(bits, "#")
end

--- The shapes changed: the cache keeps only squares the new shapes hold, the
--  totals drop at once to what that cache holds, and the sweep starts over,
--  publishing as it goes like a first sweep, so newly wired squares appear
--  on LOADS as it reaches them rather than an hour later.
local function reshaped(rec)
    local plan = rec.plan
    rec.sw = nil
    rec.unitSum = nil
    rec.slice = 0
    if rec.drawn then
        for k in pairs(rec.drawn) do
            local x, y, z = string.match(k, "^(-?%d+),(-?%d+),(-?%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            local keep = false
            if x then
                local list = plan.index[floor(x / 8) .. "," .. floor(y / 8)]
                if list then
                    for n = 1, #list do
                        if R.contains(plan.shapes[list[n]], x, y, z) then keep = true break end
                    end
                end
            end
            if not keep then rec.drawn[k] = nil end
        end
        -- the backup's units with the watts: the tick holds them from
        -- falling until the new sweep is round (OG_System.updateController)
        local total, cold, units = I().cacheTotals(rec)
        rec.load, rec.cold, rec.loadUnits = total, cold, units
        I().foldKinds(rec)
    end
    rec.swept = false
    rec.listPending = true
end

--- A player-built structure is re-read now and then, so one that grew is
--  lit to its new walls. Only when its seed is in memory; a structure that
--  cannot be read right now (a door out, a wall down for a moment) keeps
--  the footprint it had rather than going dark.
local function refreshStructures(rec, ctrl)
    local now = worldHours()
    if rec.bwReadAt and now - rec.bwReadAt < D.REFRESH_HOURS and now >= rec.bwReadAt then return end
    rec.bwReadAt = now
    local parts = partsOf(rec, ctrl)
    for i = 1, #parts do
        local list = targetsOf(parts[i])
        local changed = false
        for n = 1, #list do
            local t = list[n]
            if t.k == "s" and getSquare(t.x, t.y, t.z) then
                local fresh = B.resolve("s", t.x, t.y, t.z)
                if fresh then
                    local rects = R.encodeRects(R.rectsOf(fresh.fp))
                    if rects ~= t.rects then
                        t.rects, t.id = rects, fresh.id
                        t.x, t.y, t.z = fresh.x, fresh.y, fresh.z
                        changed = true
                    end
                end
            end
        end
        if changed then writeTargets(parts[i], list) end
    end
end

--- Called at the end of every relink (OG_System), and whenever a command
--  changes what a part wires.
function D.onRelink(rec, ctrl)
    if not ctrl then return end
    refreshStructures(rec, ctrl)
    writeFar(rec, ctrl)
    local sig = signature(rec, ctrl)
    if sig == rec.planSig and rec.plan then return end
    local old = rec.plan
    rec.plan = D.plan(rec, ctrl)
    rec.planSig = sig
    if (old == nil and rec.plan.extra) or (old ~= nil and old.hash ~= rec.plan.hash) then
        reshaped(rec)
    end
end

------------------------------------------------------------- publishing

--- Write the system's registry entry, when it has changed. A system with
--  nothing beyond its controller has no entry at all.
function D.publish(rec, gen)
    local G = Grid()
    if not rec.plan then D.onRelink(rec, gen) end
    local plan = rec.plan
    if not plan then return end
    local e = G.entry(rec.key)
    if not plan.extra then
        if e and not e.dead then G.drop(rec.key) end
        return
    end
    local on = try(gen, "isActivated") == true
    -- Batteries or panels out of memory: the controller's own switch is
    -- stale (its tick is waiting), and the estimate speaks for the grid.
    if D.partial(rec) then
        local est = D.remoteOn(rec.key)
        if est ~= nil then on = est end
    end
    G.put(rec.key, { on = on, c = plan.entry.c, r = plan.entry.r,
                     t = plan.entry.t, b = plan.entry.b })
    local cd = P.data(gen)
    if cd.wiredCount ~= plan.targets then
        cd.wiredCount = plan.targets
        I().sync(gen)
    end
end

-- Registry systems whose controller square has just loaded, to be asked on
-- the next tick whether the controller is still there.
D.check = {}

function D.onLoadChunk(chunk)
    local G = Grid()
    if not G.reg then return end
    local kx, ky = G.chunkCoords(chunk)
    if not kx then return end
    -- Through OG_Grid's index of controller chunks: this runs for every chunk
    -- that streams in anywhere, so it must not walk every system there is.
    local list = G.ctrlIndex and G.ctrlIndex[kx .. "," .. ky]
    if not list then return end
    for i = 1, #list do D.check[list[i]] = true end
end

--- A registry entry whose controller is gone from a loaded square: a
--  controller destroyed or removed by a road with no removal event while no
--  record held it (a server restart in between). Its buildings go dark.
local function runChecks()
    local G = Grid()
    for key in pairs(D.check) do
        D.check[key] = nil
        local e = G.entry(key)
        if e and not e.dead and not Sys().controllers[key] then
            local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x then
                local obj, loaded = I().objectOn(x, y, z, "controller")
                if not obj and loaded then G.drop(key) end
            end
        end
    end
end

------------------------------------------------------------ remote running

--  A system whose controller is not in memory does not tick: OG_System only
--  runs what is loaded, and settles the missed hours with a catch-up replay
--  when the controller comes back. For a controller's own 20 tiles that never
--  shows, because anyone close enough to see its power keeps it loaded. A
--  transformer chain or a big wired building reaches further than that, so a
--  player can stand in a lit house while the controller sits unloaded 80
--  tiles away, and the house would keep its last state all night.
--
--  So a system that reaches beyond its circle keeps a SNAPSHOT (D.capture,
--  every live tick): its sunlit arrays and its bank as the model sees them,
--  its load and its switch. While its controller is away, the authority steps
--  that snapshot through the same model with the live weather, every minute,
--  and switches the grid off when the bank would shed and back on when the
--  sun would bring it back, with the controller's own hold.
--
--  It is an ESTIMATE of the switch and nothing else. It never writes a charge
--  onto a battery: the catch-up replay still settles the energy when the
--  controller loads, exactly as it always has, so nothing can be billed twice.
--  Nor fuel off a backup generator: the snapshot carries copies of the units
--  (OG_BackupSys.snapshot), stepped with a live tick's top-up, Auto and burn,
--  and only the copies burn.
--  The snapshot lives in its own global table (not the registry, which goes
--  to every client), so it survives a restart without a visit.

D.REMOTE_TAG = "OffGridRemote"
-- Longest single step, in hours: a snapshot is never asked to cover a gap
-- larger than this in one go.
D.REMOTE_STEP_MAX = 1

local function remoteStore()
    if not (ModData and ModData.getOrCreate) then return {} end
    return ModData.getOrCreate(D.REMOTE_TAG)
end

--- Keep this system's snapshot current (OG_System.updateController, live ticks
--  only). A system with nothing beyond its circle keeps none.
function D.capture(rec, snap)
    local store = remoteStore()
    if not (rec.plan and rec.plan.extra) then
        store[rec.key] = nil
        return
    end
    local arrays = {}
    for i = 1, #(snap.arrays or {}) do
        local a = snap.arrays[i]
        arrays[i] = { facing = a.facing, mount = a.mount, tier = a.tier, panels = a.panels,
                      condition = a.condition, soiling = a.soiling, snow = a.snow }
    end
    local b = snap.bank or {}
    store[rec.key] = {
        x = rec.x, y = rec.y, z = rec.z, at = worldHours(),
        arrays = arrays,
        bank = { capacity = b.capacity, nominal = b.nominal, charge = b.charge,
                 cells = b.cells, health = b.health, eff = b.eff, dod = b.dod, decay = b.decay },
        load = snap.load or 0, online = snap.online == true, lvd = snap.lvd == true,
        lvdAt = snap.lvdAt, eff = snap.eff, harvest = snap.harvest,
        powered = snap.powered == true, want = snap.want, hold = snap.hold or 0,
        -- the backup generators, copied already (OG_BackupSys.snapshot); nil
        -- for a system with none
        backup = snap.backup,
    }
end

--- One minute of an away system. Returns whether its grid is on.
local function stepRemote(snap, env, now)
    local dt = now - (snap.at or now)
    if dt <= 0 then return snap.powered end
    if dt > D.REMOTE_STEP_MAX then dt = D.REMOTE_STEP_MAX end
    local sys = { arrays = snap.arrays, bank = snap.bank, load = snap.load,
                  online = snap.online, lvd = snap.lvd, powered = snap.powered,
                  inverterEff = snap.eff, harvest = snap.harvest }
    -- Its backup generators run on paper too, on the snapshot's copies: the
    -- top-up, Auto and running set a live tick hands the model, and the fuel
    -- and wear settled after it (OG_BackupSys).
    local BK = snap.backup and OffGrid.BackupSys
    if BK then BK.remoteBefore(snap, sys, env, dt, now) end
    local _, tel = OffGrid.Model.step(sys, dt, env)
    if BK then BK.remoteAfter(snap, tel, dt, now) end
    snap.lvd = sys.lvd == true
    -- OG_System's recordShed: no stamp for a shed opened with no capacity
    -- (a generator copy run dry on a rig with no cells), and a stamp kept
    -- through a step with none.
    if tel.lvdOpened then snap.lvdAt = ((tel.capacity or 0) > 0) and now or nil
    elseif tel.lvdClosed or not snap.lvd then snap.lvdAt = nil end
    -- OG_System's holdPower, on the snapshot: a real shed, or one opened this
    -- step, cuts at once, and every other change has to hold for POWER_HOLD
    -- ticks first.
    local powered
    if snap.lvd and (snap.lvdAt ~= nil or tel.lvdOpened) then
        snap.want, snap.hold, powered = false, 0, false
    else
        local b = snap.bank or {}
        -- holdPower's want: a running generator lights the house with no
        -- cells and no sun.
        local bkCap = tel.backupCap or 0
        local want = (snap.online and not snap.lvd and ((b.cells or 0) > 0 or bkCap > 0)
                      and (tel.arrayWatts > 0 or (b.charge or 0) > 0 or bkCap > 0)) and true or false
        if want ~= snap.want then
            snap.want, snap.hold = want, 0
        else
            snap.hold = (snap.hold or 0) + 1
        end
        powered = snap.powered
        if powered == nil then powered = want end
        if want ~= powered and (snap.hold or 0) >= (I().POWER_HOLD or 5) then powered = want end
    end
    snap.powered = powered
    snap.at = now
    return powered
end

--- Every away system, one minute on.
function D.remote()
    local G = Grid()
    local store = remoteStore()
    local now = worldHours()
    local env = nil
    for key, snap in pairs(store) do
        local e = G.entry(key)
        if not e or e.dead then
            store[key] = nil
        elseif type(snap) == "table" and snap.x
                and (not I().chunkLoaded(snap.x, snap.y, snap.z) or D.partial(Sys().controllers[key])) then
            if not env then
                env = OffGrid.Env.read()
                env.outputScale = sandbox("OutputScale") / 100
                env.degrade = sandbox("DegradeBank") ~= false
            end
            local on = stepRemote(snap, env, now)
            if e.on ~= on then G.put(key, { on = on }) end
        end
    end
end

--- Once per tick, after every controller has been driven (OG_System).
function D.afterTick()
    local S = Sys()
    for i = 1, #S.order do
        local rec = S.controllers[S.order[i]]
        if rec then
            local gen = I().objectOn(rec.x, rec.y, rec.z, "controller")
            if gen then D.publish(rec, gen) end
        end
    end
    runChecks()
    D.remote()
    Grid().flush()
end

--- What the estimate says of a system's switch, or nil with no snapshot.
function D.remoteOn(key)
    local snap = remoteStore()[key]
    if type(snap) ~= "table" or snap.powered == nil then return nil end
    return snap.powered == true
end

--- The controller left for good (OG_System.endSystem).
function D.forget(k)
    local G = Grid()
    local e = G.entry(k)
    if e and not e.dead then
        G.drop(k)
        G.flush()
    end
end

--- Relink and republish one system now.
local function replan(rec)
    local ctrl = I().objectOn(rec.x, rec.y, rec.z, "controller")
    if not ctrl then return end
    rec.planSig = nil
    Sys().relink(rec)
    D.publish(rec, ctrl)
    Grid().flush()
end
D.replan = replan

--- A transformer was lifted out of a system (OG_System.unplug): its circle
--  goes now, not at the next tick.
function D.unplugged(root)
    local rec = I().recordOf(root)
    if rec then replan(rec) end
end

------------------------------------------------------------------- billing

local function inAny(plan, x, y, z)
    local list = plan.index[floor(x / 8) .. "," .. floor(y / 8)]
    if not list then return false end
    for n = 1, #list do
        if R.contains(plan.shapes[list[n]], x, y, z) then return true end
    end
    return false
end

--- One slice of the load scan over every shape the system lights.
--
--  Walks (shape, chunk) units. A loaded chunk is read square by square
--  through OG_System's own readSquare, so an appliance is billed exactly as
--  the controller's own sweep bills it. An unloaded chunk cannot have changed
--  since it was last read, so its stored total is added instead of reading
--  its squares again. Every square is owned by the first shape that holds
--  it, so nothing is billed twice. Publishing follows S.scanSlice's rules:
--  a completed sweep publishes its totals; a first sweep publishes as it
--  goes and never lowers what it started from.
function D.sweep(rec)
    local plan = rec.plan
    local shapes, ix = plan.shapes, plan.index
    local internal = I()
    rec.drawn = rec.drawn or {}
    rec.unitSum = rec.unitSum or {}
    local sw = rec.sw
    if not sw then
        sw = { si = 1, ci = 1 }
        rec.sw = sw
        rec.scanLoad, rec.scanCold = 0, 0
    end

    local budget, complete = D.BUDGET, false
    while budget > 0 do
        local s = shapes[sw.si]
        if not s then
            complete = true
            break
        end
        s.chunks = s.chunks or R.chunksOf(s)
        local ch = s.chunks[sw.ci]
        if not ch then
            sw.si, sw.ci = sw.si + 1, 1
        else
            sw.ci = sw.ci + 1
            local x0, y0 = ch.kx * 8, ch.ky * 8
            local uk = sw.si .. "@" .. ch.kx .. "," .. ch.ky
            local loaded = internal.chunkLoaded(x0, y0, 0)
            local stored = rec.unitSum[uk]
            if loaded or not stored then
                local w, cold, cost = 0, 0, 0
                for y = math.max(s.y0, y0), math.min(s.y1, y0 + 7) do
                    local xa, xb = R.rowSpan(s, y)
                    if xa then
                        if xa < x0 then xa = x0 end
                        if xb > x0 + 7 then xb = x0 + 7 end
                        for x = xa, xb do
                            for z = s.zlo, s.zhi do
                                -- Every square looked at is charged, read or
                                -- summed from the cache: a first visit to an
                                -- unloaded unit walks the whole unit too.
                                cost = cost + 1
                                if R.owner(shapes, ix, sw.si, x, y, z) then
                                    local sw_, sc
                                    if loaded then
                                        sw_, sc = internal.readSquare(rec, x, y, z)
                                    else
                                        local c = rec.drawn[x .. "," .. y .. "," .. z]
                                        sw_, sc = c and c.w or 0, c and c.cold or 0
                                    end
                                    w, cold = w + sw_, cold + sc
                                end
                            end
                        end
                    end
                end
                stored = { w = w, cold = cold }
                rec.unitSum[uk] = stored
                budget = budget - math.max(cost, D.UNLOADED_COST)
            else
                budget = budget - D.UNLOADED_COST
            end
            rec.scanLoad = rec.scanLoad + stored.w
            rec.scanCold = rec.scanCold + stored.cold
        end
    end

    if complete then rec.sw = nil end
    if complete or not rec.swept then
        -- the room lights the cache holds, each once (OG_System roomWatts)
        local rooms = internal.roomWatts(rec)
        if complete then
            rec.load = rec.scanLoad + rooms
            rec.cold = rec.scanCold or 0
        else
            rec.load = math.max(rec.load or 0, rec.scanLoad + rooms)
            rec.cold = math.max(rec.cold or 0, rec.scanCold or 0)
        end
        if complete or rec.listPending then internal.foldKinds(rec) end
        if complete then
            rec.swept = true
            rec.listPending = false
        end
    end
end

--- Drop the stored totals of these chunks ("kx,ky" set), so the sweep reads
--  them again: a chunk just re-read may unload before the sweep comes round
--  to it, and its stored total would then be what it held BEFORE the read.
function D.forgetChunks(rec, chunks)
    if not rec.unitSum then return end
    local plan = rec.plan
    for ck in pairs(chunks) do
        local list = plan.index[ck]
        for n = 1, #(list or {}) do rec.unitSum[list[n] .. "@" .. ck] = nil end
    end
end

--- Every square of every shape in a loaded chunk, each once (R.owner), as
--  D.sweep walks them: S.lightsOff's walk.
function D.eachLoaded(rec, fn)
    local plan = rec.plan
    local shapes, ix = plan.shapes, plan.index
    local internal = I()
    for si = 1, #shapes do
        local s = shapes[si]
        s.chunks = s.chunks or R.chunksOf(s)
        for ci = 1, #s.chunks do
            local ch = s.chunks[ci]
            local x0, y0 = ch.kx * 8, ch.ky * 8
            if internal.chunkLoaded(x0, y0, 0) then
                for y = math.max(s.y0, y0), math.min(s.y1, y0 + 7) do
                    local xa, xb = R.rowSpan(s, y)
                    if xa then
                        if xa < x0 then xa = x0 end
                        if xb > x0 + 7 then xb = x0 + 7 end
                        for x = xa, xb do
                            for z = s.zlo, s.zhi do
                                if R.owner(shapes, ix, si, x, y, z) then
                                    local sq = getSquare(x, y, z)
                                    if sq then fn(x, y, z, sq) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

--- S.scanNear over every shape: the squares around any player standing
--  anywhere the system lights, re-read every tick.
function D.near(rec)
    local plan = rec.plan
    local internal = I()
    local near = internal.NEAR
    local touched = false
    local chunks = {}
    internal.eachPlayer(function(p)
        local sq = p:getCurrentSquare()
        if not sq then return end
        local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
        if not inAny(plan, px, py, pz) then return end
        for dx = -near, near do
            for dy = -near, near do
                local x, y = px + dx, py + dy
                if inAny(plan, x, y, pz) then
                    internal.readSquare(rec, x, y, pz)
                    chunks[floor(x / 8) .. "," .. floor(y / 8)] = true
                    touched = true
                end
            end
        end
    end)
    if not touched then return end
    -- A chunk just re-read may unload before the sweep comes round to it, and
    -- its stored total would then be what it held BEFORE this read. So the
    -- stored totals of exactly these chunks go; the rest stand.
    D.forgetChunks(rec, chunks)
    internal.publishCache(rec)
end

--- Watts every powered transformer draws doing nothing.
function D.loss(rec)
    local n = #(rec.xfmrs or {})
    if n == 0 then return 0 end
    local w = tonumber(sandbox("TransformerLoss")) or 25
    if w < 0 then w = 0 end
    return n * w
end

------------------------------------------------------------------- commands

--- Tell a player why, in their own language. A dedicated server loads no mod
--  translations, so it sends the key and the client translates it
--  (OG_Commands); singleplayer shows it directly. A refusal is drawn in the
--  warning colour (P.haloNote); `news` is a note that is not one (a
--  building wired in or unwired), which keeps the game's own colour. The
--  note the server sends says which it is.
local function note(player, key, news)
    if not player then return end
    local warn = news ~= true
    if isServer() then
        if sendServerCommand then
            sendServerCommand(player, "OffGrid", "note",
                              { key = key, id = try(player, "getOnlineID"), warn = warn })
        end
    else
        P.haloNote(player, getText(key), warn)
    end
end
D.note = note

--- The part a wiring command names, the record of the system it serves, and
--  its square, or nil and why. `reach` is "arm" for the menu rows (the
--  player stands beside the part, the rule every other command uses) or
--  "site" for the Building Picker (the player stands within the part's own
--  reach and clicks a building from there).
local function partFor(player, args, reach)
    if type(args) ~= "table" then return nil, "malformed" end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local kind = args.kind
    if not (x and y and z) or (kind ~= "controller" and kind ~= "transformer") then
        return nil, "malformed"
    end
    local obj = I().objectOn(x, y, z, kind)
    if not obj then return nil, "missing" end
    if player then
        local dx, dy = player:getX() - x, player:getY() - y
        if reach == "arm" then
            if math.abs(dx) > I().REACH or math.abs(dy) > I().REACH then return nil, "far" end
        else
            local r = range()
            if dx * dx + dy * dy > (r + 2) * (r + 2) then return nil, "far" end
        end
    end
    local root
    if kind == "controller" then
        root = M.nodeKey(x, y, z, "controller")
        if OffGrid.Place and OffGrid.Place.adopt then OffGrid.Place.adopt(obj) end
    else
        root = P.data(obj).sys
        if type(root) ~= "string" or root == "" then return nil, "unwired" end
    end
    local rec = I().recordOf(root)
    if not rec then return nil, "unwired" end
    local ctrl = I().objectOn(rec.x, rec.y, rec.z, "controller")
    if not ctrl then return nil, "unwired" end
    -- The command may run before the system's first relink has seen a new
    -- transformer; relink now so the part list is current.
    if kind == "transformer" and (rec.relinkAt or -1) < 0 then Sys().relink(rec) end
    return obj, rec, x, y, z, ctrl
end

--- Another system that already wires this target, by its key, or nil.
local function takenBy(rec, t, fp)
    return Grid().wiredBy(t, fp, rec.key)
end

--- Does any part of this system already wire this target? A structure that
--  has grown since one of its parts wired it resolves to a new key, so its
--  box counts too, as it does against other systems: without it, a click on
--  the new room wired the same structure twice.
local function systemHas(rec, ctrl, t, fp)
    local parts = partsOf(rec, ctrl)
    local lists = {}
    for i = 1, #parts do lists[#lists + 1] = targetsOf(parts[i]) end
    local far = farParts(rec, ctrl)
    for i = 1, #far do lists[#lists + 1] = targetsOfFar(far[i]) end
    for i = 1, #lists do
        local list = lists[i]
        for n = 1, #list do
            if list[n].k == t.k and list[n].id == t.id then return true end
        end
    end
    return Grid().wires(Grid().entry(rec.key), t, fp)
end

--- Add one target to one part, after every check. Returns whether it did.
local function add(player, obj, rec, ctrl, t)
    local fp = B.footprintOf(t)
    if not fp or fp.count == 0 then
        note(player, "IGUI_OffGrid_BwNone")
        return false
    end
    if systemHas(rec, ctrl, t, fp) then
        note(player, "IGUI_OffGrid_BwAlready")
        return false
    end
    local list = targetsOf(obj)
    if #list >= D.MAX_TARGETS then
        note(player, "IGUI_OffGrid_BwFull")
        return false
    end
    local r, v = range()
    local sq = obj:getSquare()
    if not B.reaches(fp, sq:getX(), sq:getY(), sq:getZ(), r, v) then
        note(player, "IGUI_OffGrid_BwFar")
        return false
    end
    if takenBy(rec, t, fp) then
        note(player, "IGUI_OffGrid_BwTaken")
        return false
    end
    if (rec.plan and rec.plan.squares or 0) + fp.count > R.MAX_WIRED then
        note(player, "IGUI_OffGrid_BwBig")
        return false
    end
    list[#list + 1] = { k = t.k, x = t.x, y = t.y, z = t.z, id = t.id,
                        rects = R.encodeRects(R.rectsOf(fp)) }
    writeTargets(obj, list)
    replan(rec)
    note(player, "IGUI_OffGrid_BwAdded", true)
    return true
end
D.add = add

local REFUSAL = {
    unwired = "IGUI_OffGrid_BwUnwired",
    far = "IGUI_OffGrid_BwTooFarAway",
}

--- May this player wire buildings to this part? Its owner's group only
--  (Can, 2026-09-29: "Lock them in 3.0.0"): the part's pick-up lock,
--  OG_Place's G.mayUse, asked on the authority once the part is found and
--  before any other reason, and told to a player it refuses in the warning
--  colour. No player is the authority's own call.
local function usable(player, obj)
    local G = OffGrid.Place
    if not (player and G and G.mayUse) then return true end
    return G.mayUse(player, obj)
end

-- When each player's last wiring command arrived, by account name.
local lastCmd = {}

--- A second wiring command from the same player inside CMD_GAP_MS is dropped
--  on a server. Each accepted one re-plans a system and re-sends the
--  registry, so the rate is the server's to set, not the client's.
--  Singleplayer is not limited: nobody else shares the cost there.
local function tooSoon(player)
    if not (player and isServer() and getTimestampMs) then return false end
    local who = try(player, "getUsername")
    if type(who) ~= "string" then return false end
    local t = getTimestampMs()
    local last = lastCmd[who]
    if last and t >= last and t - last < D.CMD_GAP_MS then return true end
    lastCmd[who] = t
    return false
end

--- Wire up the building: the part's default target. Accepted from anywhere
--  within the part's own reach, like the picker: the player is on site, and
--  a row that only works from beside the part would need a walk first.
function D.cmdDefault(player, args)
    if tooSoon(player) then return false end
    local obj, rec, x, y, z, ctrl = partFor(player, args, "site")
    if not obj then
        if REFUSAL[rec] then note(player, REFUSAL[rec]) end
        return false
    end
    if not usable(player, obj) then return false end
    local r, v = range()
    local t = B.defaultTarget(x, y, z, r, v)
    if not t then
        note(player, "IGUI_OffGrid_BwNone")
        return false
    end
    return add(player, obj, rec, ctrl, t)
end

--- Unwire every building this part wired.
function D.cmdClear(player, args)
    if tooSoon(player) then return false end
    local obj, rec = partFor(player, args, "site")
    if not obj then
        if REFUSAL[rec] then note(player, REFUSAL[rec]) end
        return false
    end
    if not usable(player, obj) then return false end
    if writeTargets(obj, {}) then
        replan(rec)
        note(player, "IGUI_OffGrid_BwRemoved", true)
    end
    return true
end

--- The Building Picker's click: add the building or structure at the
--  clicked square to this part, or take it away if the part has it.
function D.cmdPick(player, args)
    if tooSoon(player) then return false end
    local obj, rec, _, _, _, ctrl = partFor(player, args, "site")
    if not obj then
        if REFUSAL[rec] then note(player, REFUSAL[rec]) end
        return false
    end
    if not usable(player, obj) then return false end
    local sx, sy, sz = tonumber(args.sx), tonumber(args.sy), tonumber(args.sz)
    if not (sx and sy and sz) then return false end

    -- Already this part's? A map building matches by its key; a structure by
    -- whether the click lands inside its stored footprint, because a
    -- structure that has grown since resolves to a new key.
    local t, why = B.targetAt(sx, sy, sz)
    local list = targetsOf(obj)
    for n = 1, #list do
        local mine = list[n]
        local hit = false
        if mine.k == "s" then
            hit = R.fpHas(R.fpOfRects(R.decodeRects(mine.rects)), sx, sy, sz)
        elseif t and t.k == "b" then
            hit = mine.id == t.id
        end
        if hit then
            table.remove(list, n)
            writeTargets(obj, list)
            replan(rec)
            note(player, "IGUI_OffGrid_BwRemoved", true)
            return true
        end
    end

    if not t then
        if why == "open" then note(player, "IGUI_OffGrid_BwNotEnclosed")
        elseif why == "big" then note(player, "IGUI_OffGrid_BwBig")
        else note(player, "IGUI_OffGrid_BwNotBuilding") end
        return false
    end
    return add(player, obj, rec, ctrl, t)
end

--------------------------------------------------------------------- events

if Events and Events.LoadChunk then Events.LoadChunk.Add(D.onLoadChunk) end

return D

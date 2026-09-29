--[[ OffGrid -- the backup generators, on the authority.

     A backup generator is an Off-Grid part of its own (OG_Backup), cabled to
     one controller as a leaf of its wiring graph, and it only ever feeds that
     controller. OG_System finds the units the way it finds every part
     (rec.backups, and rec.far for one whose square is out of memory), holds a
     controller to four of them in S.connect, and stops one in releaseClaim
     when its link goes. What the simulation then does with them lives here,
     split out of OG_System the way OG_Distrib was, so that file only gains
     call sites.

     The unit's own ModData is the truth while its square is in memory. The
     controller keeps a MIRROR of every unit its graph holds (bkMirror, one
     string, because a controller rotation is a pick-up copy and the copy
     drops tables), so a unit whose square is out of memory keeps running on
     paper, tank only, and a unit that streams back in takes what the
     controller settled for it meanwhile (BK.resolve).

     Memory: per system on its record (rec.bk, BK.memo), rebuilt with the
     record; here only when each player's last command arrived, which
     BK.resetState makes anew.
]]

if isClient() then return end

require "OffGrid/OG_Model"
require "OffGrid/OG_Parts"
require "OffGrid/OG_Backup"
require "OffGrid/OG_System"

OffGrid = OffGrid or {}
OffGrid.BackupSys = OffGrid.BackupSys or {}
local BK = OffGrid.BackupSys
local M = OffGrid.Model
local P = OffGrid.Parts
local K = OffGrid.Backup
local try, sandbox = P.try, P.sandbox

-- OG_System's own helpers (objectOn, sync, recordOf, REACH ...), fetched at
-- call time: this file sorts before OG_System and requires it to load it.
local function I() return OffGrid.System.internals() end

-- When each player's last backup command arrived, by account name. Made only
-- by BK.resetState (which S.resetState calls), so a reset it forgot would
-- fail on first use rather than carry state between cases.
local lastCmd

--- Everything this file keeps in memory. Made at load, and by S.resetState,
--  which the headless suites call between cases.
function BK.resetState()
    lastCmd = {}
end
BK.resetState()

------------------------------------------------------------------ commands

--- Tell a player why, in their own language, by the road OG_Distrib's notes
--  take: a dedicated server loads no mod translations, so it sends the key
--  and the client translates it (OG_Commands); singleplayer shows it at once.
--  Every note here is a refusal, drawn in the warning colour (P.haloNote).
function BK.note(player, key)
    if not player then return end
    if isServer() then
        if sendServerCommand then
            sendServerCommand(player, "OffGrid", "note",
                              { key = key, id = try(player, "getOnlineID"), warn = true })
        end
    else
        P.haloNote(player, getText(key), true)
    end
end

--- A second backup command from the same player inside the wiring commands'
--  gap (OG_Distrib CMD_GAP_MS) is dropped on a server: each one can start or
--  stop a generator and push a controller, so the rate is the server's to
--  set, not the client's. Its own memory, so a GEN press and a Building
--  Picker click do not hold each other up. Singleplayer is not limited.
function BK.tooSoon(player)
    if not (player and isServer() and getTimestampMs) then return false end
    local who = try(player, "getUsername")
    if type(who) ~= "string" then return false end
    local gap = OffGrid.Distrib and OffGrid.Distrib.CMD_GAP_MS or 250
    local t = getTimestampMs()
    local last = lastCmd[who]
    if last and t >= last and t - last < gap then return true end
    lastCmd[who] = t
    return false
end

------------------------------------------------------------------ the mirror

--- A finite number, or `dflt`.
local function num(v, dflt)
    v = tonumber(v)
    if M.finite(v) then return v end
    return dflt
end

--- A non-empty string, or nil (an absent fault is written as nothing).
local function word(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

--- One decoded mirror entry in the unit's own types (contract 3.3): run "on"
--  or "off", auto a boolean (nil reads as on, as it does on the unit), fault
--  a word or nil, since, rest and at a number or nil. The string spells run
--  and auto as 1/0 (3.7); either spelling is read here, so nothing else in
--  this file cares how the codec hands them over.
local function entryFrom(e)
    local run, auto = e.run, e.auto
    return {
        fuel = M.clamp(num(e.fuel, 0), 0, K.TANK),
        cond = M.clamp(num(e.cond, 100), 0, 100),
        run = (run == "on" or run == true or run == 1 or run == "1") and "on" or "off",
        fault = word(e.fault),
        wear = num(e.wear, 0),
        at = num(e.at, nil),
        auto = not (auto == false or auto == 0 or auto == "0"),
        since = num(e.since, nil),
        rest = num(e.rest, nil),
        feedL = math.max(0, num(e.feedL, 0)),
    }
end

--- The controller's mirror, node key -> entry in the unit's own types.
--  Empty when it has none, or when OG_Backup is not loaded (a headless suite
--  that does not need it).
function BK.readMirror(ctrl)
    local out = {}
    local s = ctrl and P.data(ctrl).bkMirror
    if not K or type(s) ~= "string" or s == "" then return out end
    for nk, e in pairs(K.decodeMirror(s) or {}) do
        if type(e) == "table" then out[nk] = entryFrom(e) end
    end
    return out
end

--- Write the whole mirror back. Returns whether the string changed; pushing
--  the controller is the caller's, on the tick's own schedule.
function BK.writeMirror(ctrl, map)
    if not (K and ctrl) then return false end
    local s = K.encodeMirror(map or {})
    if s == "" then s = nil end
    local d = P.data(ctrl)
    if d.bkMirror == s then return false end
    d.bkMirror = s
    return true
end

--- A resolved unit (BK.resolve) as its mirror entry.
function BK.mirrorEntry(u)
    return { fuel = u.fuel, cond = u.cond, run = u.run, fault = u.fault,
             wear = u.wear, at = u.at, auto = u.auto, since = u.since,
             rest = u.rest, feedL = u.feedL }
end

--- Write a mirror entry, as BK.readMirror returns it, onto a loaded unit's
--  ModData: what the controller settled for it on paper while its square was
--  out of memory, when nobody could touch it.
function BK.applyMirror(d, e)
    d.fuel = e.fuel
    d.condition = e.cond
    d.run = e.run
    d.fault = e.fault
    d.wear = e.wear
    d.at = e.at
    d.auto = e.auto
    d.since = e.since
    d.rest = e.rest
end

--- A system's graph was walked again (S.relink): the mirror forgets every
--  unit the graph no longer holds, loaded (rec.backups) or out of memory
--  (rec.far). A unit cut loose was stopped by releaseClaim; its entry left
--  here would ride along in every save, and a unit picked up and set down on
--  that square again carries no `at`, so the stale entry would be written
--  onto it the moment it was cabled here again.
function BK.onRelink(rec, ctrl)
    if not (K and ctrl) then return end
    local s = P.data(ctrl).bkMirror
    if type(s) ~= "string" or s == "" then return end
    local keep = {}
    for i = 1, #(rec.backups or {}) do
        local sq = try(rec.backups[i], "getSquare")
        if sq then keep[M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup")] = true end
    end
    for i = 1, #(rec.far or {}) do
        local f = rec.far[i]
        if f.kind == "backup" then keep[f.nk] = true end
    end
    local map = BK.readMirror(ctrl)
    local drop = {}
    for nk in pairs(map) do
        if not keep[nk] then drop[#drop + 1] = nk end
    end
    if #drop == 0 then return end
    for i = 1, #drop do map[drop[i]] = nil end
    BK.writeMirror(ctrl, map)
end

------------------------------------------------------------------- the units

-- Hours. The mirror carries `at` to five decimals (%.5f, OG_Backup), so a
-- unit and its entry stamped in the same tick can differ by a few millionths
-- either way, and a strict "newer" would write the mirror back every tick. A
-- paper run moves the entry on by at least a whole tick (1/60 h), far past it.
local AT_EPS = 1e-4

--- A system's memory, on its record: rebuilt with the record, so a reset
--  needs nothing for it. `replace`: a running unit left RUNNING since the
--  last Auto plan. `hour`: each unit's world hour of its last backfire roll.
--  `tiers`: each unit's brand as last seen loaded. `lost`: each unit's feeds
--  dropped this session. Any field another caller left out is filled in.
function BK.memo(rec)
    local m = rec.bk
    if type(m) ~= "table" then
        m = {}
        rec.bk = m
    end
    if m.replace == nil then m.replace = false end
    m.hour = m.hour or {}
    m.tiers = m.tiers or {}
    m.lost = m.lost or {}
    return m
end

--- A far unit's brand from the rows the controller last showed: bkRows is
--  saved with the controller, and the mirror string carries no brand.
local function rowTier(rows, nk)
    if type(rows) ~= "table" then return nil end
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" and r.k == nk and type(r.t) == "string" then return r.t end
    end
    return nil
end

--- The system's backup generators for this tick, as the `u` tables BK.before
--  works on, and the mirror they were read against (node key -> entry). A far
--  unit's `d` IS its entry in that map, so what is written to it lands in the
--  mirror the caller writes back.
--
--  A loaded unit (rec.backups) is read from its own ModData, after the mirror
--  has been written onto it when the mirror is the newer: the controller ran
--  it on paper while its square was away, when nobody could touch it. One
--  that has left its square since the relink is skipped (S.staleLinks
--  relinks the record); one whose claim no longer names this system is
--  skipped, and the record relinks on its next tick.
--
--  A unit out of memory (rec.far) is its mirror entry, tank only: its barrels
--  are out of reach too. With no entry, or no brand known for it, there is
--  nothing to run it on, so it is left out until it streams in rather than
--  given defaults that would overwrite its real tank when it did.
function BK.resolve(rec, ctrl)
    local units = {}
    local map = BK.readMirror(ctrl)
    if not (K and ctrl) then return units, map end
    local mem = BK.memo(rec)
    local root = M.nodeKey(rec.x, rec.y, rec.z, "controller")

    for i = 1, #(rec.backups or {}) do
        local obj = rec.backups[i]
        local ix = try(obj, "getObjectIndex")
        local sq = try(obj, "getSquare")
        if type(ix) == "number" and ix >= 0 and sq then
            local d = P.data(obj)
            local brand = K.BRANDS[d.tier]
            if d.sys ~= root then
                rec.relinkAt = -1
            elseif brand then
                local x, y, z = sq:getX(), sq:getY(), sq:getZ()
                local nk = M.nodeKey(x, y, z, "backup")
                local e = map[nk]
                local at = num(d.at, nil)
                if e and e.at and (at == nil or e.at - at > AT_EPS) then
                    BK.applyMirror(d, e)
                    -- a client streamed it in with its saved ModData: push the settled state now
                    rec.syncIn = 0
                end
                mem.tiers[nk] = d.tier
                units[#units + 1] = {
                    key = nk, x = x, y = y, z = z, obj = obj, far = false, d = d,
                    tier = d.tier, rating = brand.rating, wearN = brand.wearN,
                    fuel = M.clamp(num(d.fuel, 0), 0, K.TANK),
                    -- the feeds step of BK.before tops the tank up and fills these
                    feedL = 0, mix = false,
                    feeds = type(d.feeds) == "string" and K.decodeFeeds(d.feeds) or {},
                    lost = mem.lost[nk] or 0,
                    auto = d.auto ~= false, run = d.run == "on" and "on" or "off",
                    fault = word(d.fault), since = num(d.since, nil), rest = num(d.rest, nil),
                    wear = num(d.wear, 0), cond = M.clamp(num(d.condition, 100), 0, 100),
                    at = num(d.at, nil) }
            end
        end
    end

    local rows = P.data(ctrl).bkRows
    for i = 1, #(rec.far or {}) do
        local f = rec.far[i]
        local e = f.kind == "backup" and map[f.nk] or nil
        local tier = e and (mem.tiers[f.nk] or rowTier(rows, f.nk))
        local brand = tier and K.BRANDS[tier]
        if brand then
            mem.tiers[f.nk] = tier
            units[#units + 1] = {
                key = f.nk, x = f.x, y = f.y, z = f.z, obj = nil, far = true, d = e,
                tier = tier, rating = brand.rating, wearN = brand.wearN,
                fuel = e.fuel, feedL = e.feedL, mix = false, feeds = {},
                lost = mem.lost[f.nk] or 0,
                auto = e.auto, run = e.run, fault = e.fault, since = e.since,
                rest = e.rest, wear = e.wear, cond = e.cond, at = e.at }
        end
    end
    return units, map
end

------------------------------------------------------------------ the live tick

--  Once per controller tick, between gather and M.step (S.updateController):
--  BK.before resolves the units (BK.resolve), tops the loaded ones up from
--  their barrels, applies the hazards, lets Auto decide and hands the
--  running set to the model; after the step, BK.after settles fuel and wear,
--  flips the sprites, and writes the units, the mirror, the ledgers and what
--  the GEN page reads. A catch-up slice runs the same code on its own clock,
--  the END of the slice, so every timer Auto stamps is the time it would
--  have been stamped live.
--
--  Each unit is worked on as its copy `u` (BK.resolve) and written back to
--  its ModData before anything reads the ModData again: K.startRefusal does,
--  and has to see the petrol this tick just drew from a barrel.

-- A tank at or below this is empty: OG_Backup's own figure, the one
-- K.startRefusal refuses a start under. A tank-limited step can leave a crumb
-- of a litre, and NO FUEL cleared on a crumb read STANDBY on GEN for a unit
-- nothing could start.
local DRY = (K and K.DRY) or 1e-6

--- Petrol a unit can draw on beside its tank: its barrels while its square
--  is in memory. A far unit runs on its tank alone; its barrels are out of
--  reach too.
local function feedsOf(u)
    return u.obj and u.feedL or 0
end

--- Is the unit walled in and roofed? OG_Buildings is reached here, not
--  required: a headless suite that loads this file without it reads
--  "outdoors".
local function unitEnclosed(u)
    local B = OffGrid.Buildings
    if not (B and B.enclosedAt) then return false end
    return B.enclosedAt(u.x, u.y, u.z) == true
end

--- Let go of a barrel whose claim names this unit (OG_Backup, the feed
--  claim): a dead claim would refuse the barrel to every other unit.
local function feedRelease(barrel, nk)
    local md = barrel and barrel.getModData and barrel:getModData()
    if md and md.offgridFeed == nk then
        md.offgridFeed = nil
        if barrel.transmitModData then barrel:transmitModData() end
    end
end

--- Write a loaded unit's working copy back onto its own ModData. A far
--  unit lives in the controller's mirror, which BK.after writes whole.
local function unitWrite(u)
    if not u.obj then return end
    local d = u.d
    d.fuel, d.condition, d.wear = u.fuel, u.cond, u.wear
    d.run, d.fault, d.since, d.rest = u.run, u.fault, u.since, u.rest
end

--- A unit stopped for a reason, not by Auto, keeps the reason as its fault.
--  One that was running lets Auto start the next eligible unit at once
--  (M.autoPlan's `replace`); it takes no rest, which is Auto's own.
local function unitLeave(u, fault, bk, mem)
    if u.run == "on" then
        u.run, u.since = "off", nil
        mem.replace = true
        bk.changed = true
    end
    if u.fault ~= fault then
        u.fault = fault
        bk.changed = true
    end
end

--- Drop a fault whose reason has gone.
local function unitClear(u, fault, bk)
    if u.fault == fault then
        u.fault = nil
        bk.changed = true
    end
end

--- Top a loaded unit's tank up from its barrels, and see what they hold.
--
--  Per barrel in connect order, while the tank is under K.TOPUP_BELOW. Only
--  a barrel holding nothing but petrol is drawn, through
--  adjustSpecificFluidAmount, never removeFluid or useFluid, which take from
--  a mixture in proportion; sync() is what carries the fluid to clients (the
--  FluidContainer rides SyncIsoObject, not ModData). A barrel holding
--  anything else is skipped and stays connected until it is petrol only
--  again; an empty one stays connected and feeds again once refilled. A
--  barrel that is gone from its square, or out of reach, is dropped: its
--  hose is left on the unit's square and the console says so (there is no
--  player to tell on a tick; GEN shows the count). A barrel whose square is
--  not in memory is kept, and counts for nothing until it is. Returns
--  whether one was dropped: the tick pushes the unit's shorter list.
local function unitTopUp(u, mem)
    local keep, dropped = {}, false
    local sq = u.obj:getSquare()
    local reach2 = K.FEED_RANGE * K.FEED_RANGE
    u.feedL, u.mix = 0, false
    for i = 1, #u.feeds do
        local f = u.feeds[i]
        local dx, dy = f.x - u.x, f.y - u.y
        local inReach = f.z == u.z and dx * dx + dy * dy <= reach2
        local loaded = getSquare(f.x, f.y, f.z) ~= nil
        local barrel, fc = nil, nil
        if loaded then barrel, fc = K.findBarrel(f.x, f.y, f.z) end
        if not inReach or (loaded and not barrel) then
            dropped = true
            u.lost = u.lost + 1
            if barrel then feedRelease(barrel, u.key) end
            K.dropHoses(sq, 1)
            print(string.format("OffGrid: fuel barrel at %d,%d,%d dropped from the backup generator at %d,%d,%d",
                f.x, f.y, f.z, u.x, u.y, u.z))
        else
            keep[#keep + 1] = f
            if fc then
                local n, pure = K.petrolIn(fc)
                n = n or 0
                if not pure then
                    u.mix = true
                else
                    if n > 0 and u.fuel < K.TOPUP_BELOW then
                        local take = math.min(n, K.TANK - u.fuel)
                        fc:adjustSpecificFluidAmount(Fluid.Petrol, n - take)
                        barrel:sync()
                        u.fuel = u.fuel + take
                        n = n - take
                    end
                    u.feedL = u.feedL + n
                end
            end
        end
    end
    mem.lost[u.key] = u.lost
    u.feeds = keep
    if dropped then u.d.feeds = K.encodeFeeds(keep) end
    return dropped
end

--- The hazards a tick checks (a fire is OnNewFire's, BK.onFire): worn to
--  nothing with no fault, a tank or barrels holding petrol again after NO
--  FUEL, Allow backup generators switched off, and walled in and roofed.
--  With the option off, or walled in, every unit that has no other fault
--  takes it, stopped or not (a running one is stopped): GEN never shows
--  STANDBY for a unit nothing may start, and Auto, which names one start a
--  step, never names one that K.startRefusal would refuse for good. Worn to
--  nothing is FAULT, far units included, however the unit came by its
--  condition 0 without one; a repair that lifts the condition clears it.
local function unitHazards(u, bk, mem)
    if u.fault == nil and u.cond <= 0 then unitLeave(u, "fault", bk, mem) end
    if u.fault == "nofuel" and u.fuel + feedsOf(u) > DRY then unitClear(u, "nofuel", bk) end
    if not bk.allow then
        if u.fault == nil then unitLeave(u, "server", bk, mem) end
    else
        unitClear(u, "server", bk)
    end
    if u.obj then
        if unitEnclosed(u) then
            if u.fault == nil or u.run == "on" then unitLeave(u, "indoors", bk, mem) end
        elseif u.fault == "indoors" then
            unitClear(u, "indoors", bk)
        end
    end
end

--- Auto's turn (M.autoPlan), applied. Stops first; a start the unit's own
--  Start button would be refused (K.startRefusal) is skipped. Every Auto
--  stop rests the unit K.REST hours; every start is stamped with the clock.
local function autoRun(d, sys, bank, env, dt, bk, mem)
    local hasCells = (bank.capacity or 0) > 0
    local solarW = M.solarWatts(sys, env)
    local demandW = sys.online and (sys.load or 0) or 0
    local runW, list, byKey = 0, {}, {}
    for i = 1, #bk.units do
        local u = bk.units[i]
        byKey[u.key] = u
        if u.run == "on" then runW = runW + u.rating end
        list[i] = { key = u.key, rating = u.rating, auto = u.auto, run = u.run,
                    fault = u.fault, fuel = u.fuel + feedsOf(u),
                    since = u.since, rest = u.rest }
    end
    local lv = bk.levels
    local plan = M.autoPlan({
        master = bk.master,
        -- a REAL shed only: a rig with no cells is forced shed every tick,
        -- unstamped, and reading that as a shed started a generator on every
        -- such rig, even switched off in full sun
        shed = hasCells and sys.lvd == true and d.lvdAt ~= nil,
        replace = mem.replace == true,
        hasCells = hasCells, demandW = demandW, solarW = solarW, dt = dt,
        sunSince = tonumber(d.bkSunSince), units = list,
    }, M.projectSoc(bank, solarW, runW, demandW, dt),
       { start = lv.eff, stop = lv.stop, startSet = lv.start }, bk.clock)
    mem.replace = false
    bk.sunSince = plan.sunSince
    local stops = plan.stop or {}
    for i = 1, #stops do
        local u = byKey[stops[i]]
        if u and u.run == "on" then
            u.run, u.since, u.rest = "off", nil, bk.clock + K.REST
            bk.changed = true
        end
    end
    local starts = plan.start or {}
    for i = 1, #starts do
        local u = byKey[starts[i]]
        if u and u.run ~= "on" and not (u.obj and K.startRefusal(u.obj)) then
            u.run, u.since, u.rest = "on", bk.clock, nil
            bk.changed = true
        end
    end
end

--- The running set as M.step takes it (sys.backup), or nil when none runs.
local function handOver(sys, bk)
    local running = {}
    bk.capW = 0
    for i = 1, #bk.units do
        local u = bk.units[i]
        if u.run == "on" then
            running[#running + 1] = { key = u.key, rating = u.rating, tank = u.fuel }
            bk.capW = bk.capW + u.rating
        end
    end
    bk.running = #running
    if #running == 0 then
        sys.backup = nil
    else
        sys.backup = { units = running, gfc = bk.gfc, use = bk.use,
                       loadUnits = bk.loadUnits, unitlessW = bk.unitlessW,
                       wpu = OffGrid.Loads.WATTS_PER_UNIT, realistic = bk.realistic }
    end
end

--- Before M.step (S.updateController, after the forced shed's release and
--  before its forcing). Returns `bk`, this tick's working state, for
--  BK.after; `bk.running` tells the caller whether a unit runs this step.
function BK.before(rec, ctrl, d, sys, bank, env, dt, hoursAgo, now)
    local mem = BK.memo(rec)
    local replay = (hoursAgo or 0) > 0
    local use = tonumber(sandbox("BackupFuelUse")) or 1
    if use < 0 then use = 0 end
    local units, map = BK.resolve(rec, ctrl)
    local bk = {
        clock = replay and (now - hoursAgo + dt) or now,
        replay = replay,
        master = d.bkAuto ~= false,
        allow = K.allowed(),
        units = units, mirror = map,
        running = 0, capW = 0, changed = false,
        -- what the model bills with, kept for the away estimate's snapshot too:
        -- in Realistic Mode a petrol generator's burn (M.realFuelUse), read
        -- here as the live tick and every catch-up slice read it
        gfc = P.generatorFuelConsumption(), use = use, realistic = M.isRealistic() == true,
        loadUnits = sys.loadUnitsIn or 0, unitlessW = sys.lossIn or 0,
        dod = bank.dod,
    }
    -- The levels on the gauge's scale, against the floor exactly as M.step
    -- compares it, so Auto starts a generator before the house is cut off.
    local floorSoc = M.floorSoc(bank, env.temperature or 20)
    local start, stop, eff, lo, hi = M.backupLevels(bank.dod, floorSoc,
                                                    tonumber(d.bkStart), tonumber(d.bkStop))
    bk.levels = { start = start, stop = stop, eff = eff, lo = lo, hi = hi }
    if #units == 0 then
        sys.backup = nil
        return bk
    end
    for i = 1, #units do
        local u = units[i]
        if u.obj and unitTopUp(u, mem) then bk.changed = true end
        unitHazards(u, bk, mem)
        unitWrite(u)
    end
    autoRun(d, sys, bank, env, dt, bk, mem)
    for i = 1, #units do unitWrite(units[i]) end
    handOver(sys, bk)
    return bk
end

--- After M.step. Settles what the model billed each running unit, writes
--  every unit and the mirror, adds today's ledgers and writes what the GEN
--  page reads. Returns whether any unit started, stopped, took or lost a
--  fault, or dropped a barrel this tick (BK.before), which pushes the
--  controller and its units at once.
function BK.after(rec, ctrl, d, bk, tel, env, dt, hoursAgo, now, sliceToday)
    local mem = BK.memo(rec)
    local byKey = {}
    for i = 1, #bk.units do byKey[bk.units[i].key] = bk.units[i] end

    -- Fuel and wear, on what ran. The tank is a Lua number, never the
    -- engine's float, whose spacing near 10 L swallows a minute's idle. An
    -- idle burn billed to a tank that ran out mid-step takes what was left.
    local burned = 0
    local bill = tel.backupUnits or {}
    for i = 1, #bill do
        local e = bill[i]
        local u = byKey[e.key]
        if u and u.run == "on" then
            local take = math.min(u.fuel, math.max(0, tonumber(e.fuel) or 0))
            u.fuel = u.fuel - take
            burned = burned + take
            u.wh = math.max(0, tonumber(e.wh) or 0)
            u.burn = dt > 0 and take / dt or 0
            local points, remainder = M.wear({ wear = u.wear, wearN = u.wearN }, dt)
            u.wear = remainder
            u.cond = math.max(0, u.cond - points)
            if u.cond <= 0 then
                unitLeave(u, "fault", bk, mem)
            elseif u.fuel <= DRY and feedsOf(u) <= 0 then
                unitLeave(u, "nofuel", bk, mem)
            end
        end
    end

    -- Every unit and its mirror entry carry the same stamp. The sprite is
    -- what a client's sound and every menu go by, and P.setState sends it.
    local stamp = bk.clock
    local map = bk.mirror
    for i = 1, #bk.units do
        local u = bk.units[i]
        u.at = stamp
        if u.obj then
            unitWrite(u)
            u.d.at = stamp
            P.setState(u.obj, u.run == "on" and "on" or "off")
        end
        map[u.key] = BK.mirrorEntry(u)
    end
    BK.writeMirror(ctrl, map)

    -- Only today's slices add to today's figures, as the DAY trace does:
    -- petrol burned on an earlier replayed day is settled on the tank and
    -- lands in no daily figure.
    if sliceToday then
        d.bkWhToday = (d.bkWhToday or 0) + (tel.backupWh or 0)
        d.bkFuelToday = (d.bkFuelToday or 0) + burned
    end

    -- What the GEN page reads, under bk* names (`gen` is solar watts).
    d.bkCap = dt > 0 and (tel.backupCap or 0) / dt or 0
    d.bkW = tel.backupWatts or 0
    d.bkN = #bk.units
    d.bkStartNow, d.bkStopNow = bk.levels.start, bk.levels.stop
    d.bkSunSince = bk.sunSince
    local rows = {}
    for i = 1, math.min(#bk.units, K.MAX_UNITS) do
        local u = bk.units[i]
        local on = u.run == "on"
        local burn = on and u.burn or 0
        rows[i] = {
            k = u.key, x = u.x, y = u.y, z = u.z, t = u.tier,
            -- the barrels count with the tank for NO FUEL, as they do for Auto
            s = K.unitState(u.obj and u.d or map[u.key], bk.master, feedsOf(u)),
            far = u.far == true,
            w = (on and dt > 0) and (u.wh or 0) / dt or 0,
            -- A far unit's feed is the figure its barrels held when it left,
            -- but it runs on its tank alone there, so its hours are the tank's.
            tank = u.fuel, feed = u.feedL, burn = burn,
            left = burn > 0 and (u.fuel + feedsOf(u)) / burn or -1,
            cond = u.cond, auto = u.auto, mix = u.mix == true, lost = u.lost or 0,
        }
    end
    d.bkRows = rows
    -- The live half of the hazards (BK.live): never on a catch-up slice, by
    -- the same test S.updateController makes for `replay`.
    if (hoursAgo or 0) <= 0 then BK.live(rec, ctrl, now) end
    return bk.changed
end

------------------------------------------------------------ remote estimate

--  The controller away and its grid somewhere a player is: OG_Distrib steps
--  a snapshot of the system every minute to switch the grid (D.remote). The
--  snapshot carries copies of the units; the estimate runs a live tick's
--  top-up, hazards, Auto, burn and wear on the copies and never writes a
--  unit, a barrel or a battery. The catch-up replay settles those when the
--  controller returns, so nothing is billed twice.

--- This system's generators for the remote estimate (OG_Distrib.capture, live
--  ticks only), or nil: a system with no unit, or one the estimate does not
--  keep (nothing beyond its own circle: D.capture stores nothing for it, so
--  nothing is copied every minute for nothing). Copies of what BK.after has
--  just settled on each unit, and the terms BK.before billed with (kept on
--  `bk`), so the estimate starts where the units stand. A far unit brings
--  its tank only, as it runs here. `replace` carries a unit that left
--  RUNNING on this very tick (8.31).
function BK.snapshot(rec, d, bk)
    if not (bk and K and rec.plan and rec.plan.extra) then return nil end
    local units = {}
    for i = 1, #(bk.units or {}) do
        local u = bk.units[i]
        units[#units + 1] = {
            k = u.key, tier = u.tier, rating = u.rating, wearN = u.wearN,
            tank = u.fuel, feedL = feedsOf(u),
            auto = u.auto, run = u.run, fault = u.fault, wear = u.wear,
            since = u.since, rest = u.rest, cond = u.cond,
        }
    end
    if #units == 0 then return nil end
    return {
        master = bk.master, start = tonumber(d.bkStart), stop = tonumber(d.bkStop),
        sunSince = bk.sunSince, dod = bk.dod,
        gfc = bk.gfc, use = bk.use, realistic = bk.realistic == true,
        loadUnits = bk.loadUnits, unitlessW = bk.unitlessW,
        replace = (rec.bk and rec.bk.replace) == true,
        units = units,
    }
end

--- One step of an away system, before the model (OG_Distrib stepRemote):
--  what BK.before does for a live tick, on the snapshot's copies. Each tank
--  copy is topped up from its feed copy under K.TOPUP_BELOW; with the server
--  switch off every fault-free copy is stopped and marked, as the live tick
--  marks the units; the shed is released before Auto reads it and forced
--  after Auto has decided (no cells, nothing running), exactly where
--  updateController does both (8.30, 8.7); Auto decides at `now`; and the
--  running set goes to M.step as sys.backup. Writes the snapshot only.
function BK.remoteBefore(snap, sys, env, dt, now)
    local bs = snap.backup
    sys.backup = nil
    if type(bs) ~= "table" or type(bs.units) ~= "table" or #bs.units == 0 then return end
    local bank = sys.bank or {}
    local hasCells = (bank.capacity or 0) > 0
    if hasCells and sys.lvd and snap.lvdAt == nil then sys.lvd = false end

    -- the server switch read live, as the tick and the replay read it
    local allow = K.allowed()
    local byKey = {}
    for i = 1, #bs.units do
        local u = bs.units[i]
        byKey[u.k] = u
        u.feedL = u.feedL or 0
        if u.tank < K.TOPUP_BELOW and u.feedL > 0 then
            local t = math.min(u.feedL, K.TANK - u.tank)
            u.tank, u.feedL = u.tank + t, u.feedL - t
        end
        -- NO FUEL clears over DRY and before the server switch, as in
        -- unitHazards: a crumb left by a tank-limited step is still empty,
        -- and clearing it let Auto start the dry copy again every step.
        if u.fault == "nofuel" and u.tank + u.feedL > DRY then u.fault = nil end
        if not allow then
            if u.fault == nil then
                if u.run == "on" then
                    u.run, u.since = "off", nil
                    bs.replace = true
                end
                u.fault = "server"
            end
        elseif u.fault == "server" then
            u.fault = nil
        end
    end

    local start, stop, eff = M.backupLevels(bs.dod, M.floorSoc(bank, env.temperature or 20),
                                            bs.start, bs.stop)
    local solarW = M.solarWatts(sys, env)
    local demandW = sys.online and (sys.load or 0) or 0
    local runW, list = 0, {}
    for i = 1, #bs.units do
        local u = bs.units[i]
        if u.run == "on" then runW = runW + u.rating end
        list[i] = { key = u.k, rating = u.rating, auto = u.auto, run = u.run, fault = u.fault,
                    fuel = u.tank + u.feedL, since = u.since, rest = u.rest }
    end
    local plan = M.autoPlan({ master = bs.master,
                              shed = hasCells and sys.lvd == true and snap.lvdAt ~= nil,
                              replace = bs.replace == true, hasCells = hasCells,
                              demandW = demandW, solarW = solarW, dt = dt,
                              sunSince = bs.sunSince, units = list },
                            M.projectSoc(bank, solarW, runW, demandW, dt),
                            { start = eff, stop = stop, startSet = start }, now)
    bs.replace = false
    bs.sunSince = plan.sunSince
    for i = 1, #(plan.stop or {}) do
        local u = byKey[plan.stop[i]]
        if u and u.run == "on" then u.run, u.since, u.rest = "off", nil, now + K.REST end
    end
    for i = 1, #(plan.start or {}) do
        local u = byKey[plan.start[i]]
        if u and u.run ~= "on" and u.fault == nil then u.run, u.since, u.rest = "on", now, nil end
    end

    local running = {}
    for i = 1, #bs.units do
        local u = bs.units[i]
        if u.run == "on" then running[#running + 1] = { key = u.k, rating = u.rating, tank = u.tank } end
    end
    if #running > 0 then
        sys.backup = { units = running, gfc = bs.gfc, use = bs.use, loadUnits = bs.loadUnits,
                       unitlessW = bs.unitlessW, wpu = OffGrid.Loads.WATTS_PER_UNIT,
                       realistic = bs.realistic == true }
    elseif not hasCells then
        -- forced; a real shed's stamp is kept, as updateController keeps it
        sys.lvd = true
    end
end

--- The same step after the model: the fuel and the wear settled on the
--  copies, and a copy that wore out or ran dry stopped, as BK.after settles
--  a unit, with the next one free to start at once (8.31).
function BK.remoteAfter(snap, tel, dt, now)
    local bs = snap.backup
    if type(bs) ~= "table" or type(bs.units) ~= "table" then return end
    local byKey = {}
    for i = 1, #bs.units do byKey[bs.units[i].k] = bs.units[i] end
    local list = tel and tel.backupUnits or {}
    for i = 1, #list do
        local e = list[i]
        local u = byKey[e.key]
        if u and u.run == "on" then
            u.tank = math.max(0, u.tank - math.max(0, tonumber(e.fuel) or 0))
            local points, left = M.wear({ wear = u.wear, wearN = u.wearN }, dt)
            u.wear = left
            u.cond = math.max(0, u.cond - points)
            if u.cond <= 0 then
                u.run, u.since, u.fault = "off", nil, "fault"
                bs.replace = true
            elseif u.tank <= DRY and u.feedL <= 0 then
                u.run, u.since, u.fault = "off", nil, "nofuel"
                bs.replace = true
            end
        end
    end
end

--------------------------------------------------------------- live hazards

--  What only a live tick does with a running unit: the noise zombies follow,
--  and below 40% condition the backfire. Neither is replayed nor estimated.
--  A catch-up slice has nobody near to hear it, and a random roll in the
--  replay or in OG_Distrib's estimate would make the two disagree about a
--  tank; the fuel and wear of those hours are the model's (BK.after), with
--  no dice at all.

--- The least real time between two rounds of world sound from one system,
--  in ms. A live tick is an in-game minute: 2.5 real seconds at the default
--  day length, but a few milliseconds under fast-forward, and every call on
--  a server sends a packet (WorldSoundManager.addSound, doSend). Vanilla
--  re-issues its own generator's sound on every update; one round a second
--  keeps zombies coming without a flood.
BK.SOUND_GAP_MS = 1000

-- Vanilla's stress modifier for its generator's backfire sound
-- (IsoGenerator.java:243).
local BACKFIRE_STRESS = 15

--- 1 in how many running hours a unit at this condition backfires, or nil
--  above the worn bands. K.BACKFIRE lists the bands most worn first, the way
--  IsoGenerator.update tests them: 20 or less 1 in 5, 30 or less 1 in 10,
--  40 or less 1 in 15.
function BK.backfireOdds(condition)
    local c = tonumber(condition) or 100
    for i = 1, #K.BACKFIRE do
        local band = K.BACKFIRE[i]
        if c <= band[1] then return band[2] end
    end
    return nil
end

--- A worn unit's backfire: one roll per whole world hour it runs, on the
--  first live tick of that hour, as vanilla rolls when its lastHour turns
--  over. `m.hour` is the hour each unit was last seen running. A unit seen
--  for the first time only takes the hour down, so a load or a new record is
--  never a roll. A unit started again only notes the hour and rolls at the
--  next hour turnover, as vanilla's setActivated(true) sets lastHour to the
--  current hour (IsoGenerator.java:531).
--
--  Sound only: Can ruled out fire and explosion, so vanilla's rolls for those
--  below 20% are not here. `bf` counts backfires and OG_BackupSound plays the
--  brand's Backfire on every client that sees it change, so it is pushed now
--  rather than at the next sync. Zombies hear it 40 tiles out.
local function backfire(ctrl, obj, d, x, y, z, m, hour, wsm)
    if type(m.hour) ~= "table" then m.hour = {} end
    local nk = M.nodeKey(x, y, z, "backup")
    local last = m.hour[nk]
    m.hour[nk] = hour
    if last == nil or last == hour then return false end
    -- Started this hour: vanilla's setActivated(true) sets lastHour to the
    -- current hour (IsoGenerator.java:531), so its first roll is at the next turn.
    if math.floor(tonumber(d.since) or -1) == hour then return false end
    local n = BK.backfireOdds(d.condition)
    if not n or not ZombRand or ZombRand(n) ~= 0 then return false end
    d.bf = (tonumber(d.bf) or 0) + 1
    I().sync(obj)
    if wsm then
        local s = K.WORLD_SOUND_BACKFIRE
        wsm:addSound(ctrl, x, y, z, s.radius, s.volume, false, 0, BACKFIRE_STRESS)
    end
    return true
end

--- The running noise of each loaded unit this system runs, on a live tick
--  (BK.after). `ctrl`, the system's controller, is the source of every
--  sound: an IsoGenerator source is what makes zombies in singleplayer treat
--  the noise as a base, as vanilla's own generator does. The sound itself is
--  at the unit.
--
--  Radius and volume are the brand's, the radius halved on a room square,
--  the way IsoGenerator.update works them out from the item's SoundRadius
--  and SoundVolume (IsoGenerator.java:169-188). The last argument is a Lua
--  boolean on purpose: addSoundRepeating has two seven-argument overloads,
--  one ending in a boolean and one in a short, and Kahlua takes the one the
--  value converts to.
function BK.live(rec, ctrl, now)
    local list = rec and rec.backups
    if not ctrl or not list or #list == 0 then return end
    local m = rec.bk
    if type(m) ~= "table" then
        m = {}
        rec.bk = m
    end
    local wsm = getWorldSoundManager and getWorldSoundManager()
    local ms = getTimestampMs and getTimestampMs() or nil
    local loud = not (ms and m.soundMs and ms >= m.soundMs
                      and ms - m.soundMs < BK.SOUND_GAP_MS)
    local heard = false
    for i = 1, #list do
        local obj = list[i]
        local sq = P.try(obj, "getSquare")
        local ix = P.try(obj, "getObjectIndex")
        local d = sq and type(ix) == "number" and ix >= 0 and P.data(obj) or nil
        local brand = d and d.run == "on" and K.BRANDS[d.tier] or nil
        if brand then
            local x, y, z = math.floor(sq:getX()), math.floor(sq:getY()), math.floor(sq:getZ())
            if loud and wsm then
                local radius = brand.radius
                if P.try(sq, "getRoom") ~= nil then radius = math.floor(radius / 2) end
                wsm:addSoundRepeating(ctrl, x, y, z, radius, brand.volume, false)
                heard = true
            end
            backfire(ctrl, obj, d, x, y, z, m, math.floor(now or 0), wsm)
        end
    end
    if heard then m.soundMs = ms end
end

--- A fire starting on a backup's square. OG_System's onNewFire hands the
--  square over from inside IsoFire's constructor, before the square first
--  burns (IsoFire.java:250). Every backup standing there stops where it is
--  with the fire fault, running or not (it burned), and only a repair clears
--  it (a pick-up carries it, OG_Place). Its tiles are not solid, so BurnWalls
--  leaves the object, its tank and ModData alone; nothing else is taken here.
--
--  The unit is stamped and pushed at once, so the next tick reads the unit
--  rather than the controller's older mirror of it. Its system is pushed on
--  that tick, and when the unit was running, Auto may start the next eligible
--  generator without waiting out the minimum run (rec.bk.replace). A second
--  fire on the same square finds it stopped with the fault and does nothing.
function BK.onFire(square)
    local objs = square and P.try(square, "getObjects")
    if not objs then return end
    local now = OffGrid.Env and OffGrid.Env.worldHours and OffGrid.Env.worldHours() or 0
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if P.partOf(o) == "backup" then
            local d = P.data(o)
            local wasRunning = d.run == "on"
            if wasRunning or d.fault ~= "fire" then
                d.run = "off"
                d.since = nil
                d.fault = "fire"
                d.at = now
                P.setState(o, "off")
                I().sync(o)
                local rec = type(d.sys) == "string" and I().recordOf(d.sys) or nil
                if rec then
                    rec.syncIn = 0
                    if wasRunning then
                        if type(rec.bk) ~= "table" then rec.bk = {} end
                        rec.bk.replace = true
                    end
                end
            end
        end
    end
end

------------------------------------------------------------ player commands

--  What a player does to a backup generator arrives here, on the authority:
--  from the completion of an OG_BackupPanel or OG_BackupFeed action (a GEN
--  button, a menu row) or from a client's own sendClientCommand, both through
--  OG_System's COMMANDS. Every handler takes the per-player gap first, then
--  reach, then checks that a unit belongs to the controller the command
--  names, then the owner's lock (K.lockRefusal, Can 2026-09-29: "Owner's
--  group only"), and writes nothing before all of it has passed. A refusal
--  the player can act on is told through BK.note; a malformed or
--  out-of-reach command is dropped, as OG_System's own commands are.

--- Within arm's reach of obj: OG_System's REACH, on x and y, the rule every
--  command uses. A command with no player is the authority's own.
local function near(player, obj)
    if not player then return true end
    local sq = obj and obj:getSquare()
    if not sq then return false end
    local r = I().REACH
    return math.abs(player:getX() - sq:getX()) <= r
       and math.abs(player:getY() - sq:getY()) <= r
end

--- The controller a command names at x, y, z, within reach, and its data;
--  or nil. Adopted first, as OG_System's equalise does: P.data on a
--  controller nobody has set up yet stamps its tier, and G.adopt would then
--  take it for one that had been set up.
local function controllerFor(player, args)
    if type(args) ~= "table" then return nil end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (x and y and z) then return nil end
    local ctrl = I().objectOn(math.floor(x), math.floor(y), math.floor(z), "controller")
    if not ctrl or not near(player, ctrl) then return nil end
    if OffGrid.Place and OffGrid.Place.adopt then OffGrid.Place.adopt(ctrl) end
    return ctrl, P.data(ctrl)
end

--- May this player use `obj`'s controls? The owner's lock (K.lockRefusal:
--  the owner, their safehouse, staff, and whoever the server's Pick-up
--  option lets lift it; anyone in singleplayer), asked on the authority
--  before any other reason and told to the player when it refuses, so a
--  stranger's press, or a menu row greyed on an older push, changes nothing.
--  A command with no player is the authority's own.
function BK.unlocked(player, obj)
    if not player or not (K and K.lockRefusal) then return true end
    local why = K.lockRefusal(player, obj)
    if why then
        BK.note(player, why)
        return false
    end
    return true
end

--- Have the controller a unit serves pushed at its next tick, so GEN shows a
--  player's change now rather than at the ten-minute sync. The refuel and
--  repair actions call it too, on the authority.
function BK.wake(d)
    local root = d and d.sys
    if type(root) ~= "string" or root == "" then return end
    local rec = I().recordOf(root)
    if rec then rec.syncIn = 0 end
end

--- What a GEN row stands for now, for BK.showNow: the unit's own ModData
--  while its square is in memory and its claim still names this controller,
--  or the controller's mirror entry when that is the newer (BK.resolve's
--  rule) or the square is out of memory. Second, the petrol its barrels
--  hold as the row last counted them; none for a unit out of memory, which
--  runs on its tank alone. Nil for a row whose unit is gone or cabled
--  elsewhere since: the next tick drops that row.
local function rowSource(r, map, root)
    local e = type(r.k) == "string" and map[r.k] or nil
    local x, y, z = tonumber(r.x), tonumber(r.y), tonumber(r.z)
    if not (x and y and z) then return e, 0 end
    local unit, loaded = I().objectOn(math.floor(x), math.floor(y), math.floor(z), "backup")
    if not unit then
        if loaded then return nil, 0 end
        return e, 0
    end
    local d = P.data(unit)
    if d.sys ~= root then return nil, 0 end
    local feed = math.max(0, num(r.feed, 0))
    local at = num(d.at, nil)
    if e and e.at and (at == nil or e.at - at > AT_EPS) then return e, feed end
    return d, feed
end

--- Show a player's change on the GEN page now. The page draws a generator
--  from its row (bkRows) and the controller's bk* figures, which BK.after
--  writes once a tick, a game minute (2.5 real seconds at the default day
--  length). A switch sends the opposite of what it shows, so a second press
--  inside that minute went out on the old picture (live campaign on 42.21,
--  2026-09-28: a press meant as a start came out as a stop). So every
--  command that changes a state (Generator Auto, a generator's AUTO, Start
--  and Stop, the levels) rewrites the rows from the units as they now stand
--  and pushes the controller in the same call, as a tick that starts or
--  stops one does; in singleplayer too, where the push is the hot-save flag
--  and the page reads the very table written here.
--
--  Only what a command can change is rewritten: each row's state word, its
--  AUTO, tank and condition, read from rowSource. A row that is not running
--  delivers nothing, and one just started has run no step: no watts, no
--  burn, hours unknown ("--") until the next tick settles them. The
--  controller's backup watts are the running rows' sum, as the tick's are;
--  with none running there is nothing to give. Nothing is written onto a
--  unit or the mirror, which stay the tick's.
function BK.showNow(ctrl)
    if not ctrl then return end
    local cd = P.data(ctrl)
    local rows = cd.bkRows
    local sq = try(ctrl, "getSquare")
    if K and sq and type(rows) == "table" and #rows > 0 then
        local root = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "controller")
        local master = cd.bkAuto ~= false
        local map = BK.readMirror(ctrl)
        local out, watts, running = {}, 0, 0
        for i = 1, #rows do
            local r = rows[i]
            local nr = {}
            if type(r) == "table" then
                for k, v in pairs(r) do nr[k] = v end
                local src, feed = rowSource(r, map, root)
                if src then
                    local was = r.s == "running"
                    nr.s = K.unitState(src, master, feed)
                    nr.auto = src.auto ~= false
                    nr.tank = M.clamp(num(src.fuel, 0), 0, K.TANK)
                    -- a unit's ModData says condition, a mirror entry cond
                    nr.cond = M.clamp(num(src.condition, num(src.cond, 100)), 0, 100)
                    if nr.s ~= "running" or not was then
                        nr.w, nr.burn, nr.left = 0, 0, -1
                    end
                end
                if nr.s == "running" then
                    running = running + 1
                    watts = watts + math.max(0, num(nr.w, 0))
                end
            end
            out[i] = nr
        end
        cd.bkRows = out
        cd.bkW = watts
        if running == 0 then cd.bkCap = 0 end
    end
    I().sync(ctrl)
end

--- Generator Auto, the controller's master switch. Turning it off is acted
--  on by the next tick's plan (every running unit with AUTO on stops, its
--  minimum run waived); nothing is stopped here, so that rule lives in one
--  place. GEN shows the switch, and every stopped generator's STANDBY or
--  OFF, at once (BK.showNow).
function BK.cmdMaster(player, args)
    if BK.tooSoon(player) then return false end
    local ctrl, d = controllerFor(player, args)
    if not ctrl then return false end
    if not BK.unlocked(player, ctrl) then return false end
    d.bkAuto = args.on == true
    BK.showNow(ctrl)
    return true
end

--- Start at / Stop at, one 5-point step. The level is read the way the tick
--  reads it (M.backupLevels, clamped, with the dod and floor the last tick
--  wrote on the controller), stepped, and stored as the next read will show
--  it: the figure the player pressed is the figure GEN prints, and a press
--  past a limit changes nothing. Stop keeps its own value when a raised
--  Start pushes it up; bkStopNow shows where it lands. Pushed at once
--  (BK.showNow), since a level change alone does not force the tick's sync.
function BK.cmdLevel(player, args, which)
    if BK.tooSoon(player) then return false end
    if which ~= "start" and which ~= "stop" then return false end
    local ctrl, d = controllerFor(player, args)
    if not ctrl then return false end
    local dir = tonumber(args.dir)
    if dir ~= 1 and dir ~= -1 then return false end
    if not BK.unlocked(player, ctrl) then return false end
    local start, stop = M.backupLevels(d.dod, d.floorSoc, d.bkStart, d.bkStop)
    if which == "start" then
        d.bkStart = start + dir * 0.05
    else
        d.bkStop = stop + dir * 0.05
    end
    start, stop = M.backupLevels(d.dod, d.floorSoc, d.bkStart, d.bkStop)
    if which == "start" then d.bkStart = start else d.bkStop = stop end
    d.bkStartNow, d.bkStopNow = start, stop
    BK.showNow(ctrl)
    return true
end

--- World hours now, the stamp a player's change carries: the unit's `at` is
--  then newer than the mirror entry the last tick wrote, and the next tick
--  keeps the change instead of writing the mirror back over it (BK.resolve).
local function hoursNow()
    return OffGrid.Env and OffGrid.Env.worldHours and OffGrid.Env.worldHours() or 0
end

--- Bring a loaded unit up to date before a player changes it. A unit that
--  streamed back in is resolved against its controller's mirror only at the
--  next tick (BK.resolve); a change stamped before that would make the unit
--  the newer, and the paper run the controller kept for it while it was away
--  (its tank, condition, wear, timers) would be lost for good. So the newer
--  entry is written onto it first, by BK.resolve's own rule (the mirror's
--  `at` newer by more than its five-decimal rounding). The timed actions call
--  it too, on the authority. Nothing to do for a unit with no live controller.
function BK.freshen(unit)
    local sq = unit and try(unit, "getSquare")
    if not sq or P.partOf(unit) ~= "backup" then return end
    local d = P.data(unit)
    if type(d.sys) ~= "string" or d.sys == "" then return end
    local ctrl = I().controllerAt(d.sys)
    if not ctrl then return end
    local e = BK.readMirror(ctrl)[M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup")]
    local at = tonumber(d.at)
    if e and e.at and (at == nil or e.at - at > 1e-4) then BK.applyMirror(d, e) end
end

--- Start refusals for a unit out of memory, from what the controller's
--  mirror holds: K.startRefusal's keys, in its order, for what can be known
--  without the square. The link is the mirror entry itself (a relink purges
--  what the graph no longer holds); a fire is checked again the tick the
--  square streams back in. INDOORS stands as it was last seen: nobody can
--  have taken the roof off a square out of memory, and the tick judges
--  enclosure only on a loaded square.
local function farStartRefusal(e)
    if not K.allowed() then return "Tooltip_OffGrid_BkServerOff" end
    if e.fault == "indoors" then return "Tooltip_OffGrid_BkMoveOut" end
    if e.fault == "fault" or e.fault == "fire" or (e.cond or 100) <= 0 then
        return "Tooltip_OffGrid_BkRepairFirst"
    end
    if (e.fuel or 0) <= 0 then return "Tooltip_OffGrid_BkRefuelFirst" end
    return nil
end

--- What a unit command acts on, or nil. A unit whose square is in memory:
--  { unit = obj, d = its ModData, brought up to date by BK.freshen }, when
--  the player stands within reach of
--  the unit or of its controller, and, if the command names a controller (a
--  GEN row), only when it is that controller's (a GEN page left open must
--  not reach a unit cabled elsewhere since). A unit out of memory: only from
--  its controller's GEN row, as { far = true, d = its mirror entry, ctrl,
--  map, root }, the entry the controller runs it on paper from.
local function targetFor(player, args)
    if type(args) ~= "table" then return nil end
    local ux, uy, uz = tonumber(args.ux), tonumber(args.uy), tonumber(args.uz)
    if not (ux and uy and uz) then return nil end
    ux, uy, uz = math.floor(ux), math.floor(uy), math.floor(uz)
    local root
    if args.x ~= nil then
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        if not (x and y and z) then return nil end
        root = M.nodeKey(x, y, z, "controller")
    end
    local unit, loaded = I().objectOn(ux, uy, uz, "backup")
    if unit then
        local d = P.data(unit)
        local ctrl
        if root then
            if d.sys ~= root then return nil end
            ctrl = I().controllerAt(root)
        else
            ctrl = K.linkedController(unit)
        end
        if not (near(player, unit) or (ctrl ~= nil and near(player, ctrl))) then
            return nil
        end
        BK.freshen(unit)
        return { unit = unit, d = d }
    end
    if loaded or not root then return nil end
    local ctrl = controllerFor(player, args)
    if not ctrl then return nil end
    local map = BK.readMirror(ctrl)
    local e = map[M.nodeKey(ux, uy, uz, "backup")]
    if not e then return nil end
    return { far = true, d = e, ctrl = ctrl, map = map, root = root }
end

--- Publish a unit command's change. A unit in memory: its sprite (when
--  `sprite`, which is what clients and the sound module read) and its
--  ModData pushed, and its controller woken. A unit out of memory: the
--  mirror written back and the controller pushed at its next tick. Either
--  way the controller's GEN rows show the change and it is pushed now
--  (BK.showNow), so a second press reads the new picture.
local function commit(t, sprite)
    if t.far then
        BK.writeMirror(t.ctrl, t.map)
        local rec = I().recordOf(t.root)
        if rec then rec.syncIn = 0 end
        BK.showNow(t.ctrl)
        return
    end
    if sprite then P.setState(t.unit, t.d.run == "on" and "on" or "off") end
    I().sync(t.unit)
    BK.wake(t.d)
    if type(t.d.sys) == "string" then BK.showNow(I().controllerAt(t.d.sys)) end
end

--- A unit's own AUTO switch. Only `auto` changes (and the `at` stamp): a
--  running unit handed back to Auto keeps running, its minimum run counted
--  from its own `since`, and Auto may then stop it by its rules.
function BK.cmdAuto(player, args)
    if BK.tooSoon(player) then return false end
    local t = targetFor(player, args)
    if not t then return false end
    if not BK.unlocked(player, t.far and t.ctrl or t.unit) then return false end
    t.d.auto = args.on == true
    t.d.at = hoursNow()
    commit(t, false)
    return true
end

--- Start or Stop by hand, from the GEN page's ON/OFF switch or the unit's
--  menu. Only while the unit's own AUTO is off (K.handRefusal, Can,
--  2026-09-28): the player switches AUTO off first, so Auto never undoes a
--  hand action (design, Auto), and a press while it is on is refused with
--  the reason the switch and the rows are greyed with, changing nothing. A
--  start the unit refuses tells the player the reason the menu greys the
--  row with. A second Start on a running unit keeps the time it started. A
--  stop sets no rest: rest is for Auto's own stops.
function BK.cmdRun(player, args)
    if BK.tooSoon(player) then return false end
    local t = targetFor(player, args)
    if not t then return false end
    if not BK.unlocked(player, t.far and t.ctrl or t.unit) then return false end
    local d, now = t.d, hoursNow()
    local held = K.handRefusal(d)
    if held then
        BK.note(player, held)
        return false
    end
    d.at = now
    local ok = true
    if args.on == true then
        local why
        if t.far then why = farStartRefusal(d) else why = K.startRefusal(t.unit) end
        if why then
            BK.note(player, why)
            ok = false
        else
            if d.run ~= "on" then d.since = now end
            d.run = "on"
            d.rest = nil
            if d.fault == "nofuel" then d.fault = nil end
        end
    else
        d.run = "off"
        d.since = nil
    end
    commit(t, true)
    return ok
end

--- Connect the barrel at fx, fy, fz to `unit` with `hose` (OG_BackupFeed's
--  completion). The gate again (K.feedRefusal, the menu's own), told to the
--  player when it refuses; the hose taken from the container it is actually
--  in, and only while it is still carried (OG_BankCell on bags and floor
--  items); the square appended to the unit's feeds; and the barrel claimed
--  for this unit, so no other unit may take it. The next tick draws from it.
--  Returns whether it connected.
function BK.feedConnect(character, unit, fx, fy, fz, hose)
    if not unit or P.partOf(unit) ~= "backup" then return false end
    local sq = unit:getSquare()
    if not sq then return false end
    fx, fy, fz = tonumber(fx), tonumber(fy), tonumber(fz)
    if not (fx and fy and fz) then return false end
    fx, fy, fz = math.floor(fx), math.floor(fy), math.floor(fz)
    local barrel = K.findBarrel(fx, fy, fz)
    if not barrel then return false end
    if not BK.unlocked(character, unit) then return false end
    local why = K.feedRefusal(character, unit, barrel)
    if why then
        BK.note(character, why)
        return false
    end
    BK.freshen(unit)
    local d = P.data(unit)
    local list = K.decodeFeeds(d.feeds)
    for i = 1, #list do
        if list[i].x == fx and list[i].y == fy and list[i].z == fz then return false end
    end
    local cont = hose and try(hose, "getContainer")
    if not cont or try(hose, "getWorldItem") or try(hose, "getFullType") ~= K.HOSE then
        return false
    end
    try(character, "removeFromHands", hose)
    cont:Remove(hose)
    sendRemoveItemFromContainer(cont, hose)
    list[#list + 1] = { x = fx, y = fy, z = fz }
    d.feeds = K.encodeFeeds(list)
    d.at = hoursNow()
    barrel:getModData().offgridFeed = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup")
    barrel:transmitModData()
    unit:transmitModData()
    BK.wake(d)
    return true
end

--- Disconnect the barrel at fx, fy, fz from `unit`: the square dropped from
--  its feeds; the barrel's claim cleared when that square is in memory and
--  the claim names this unit (a barrel out of memory keeps a claim that is
--  dead anyway, since the unit no longer lists it); and the Rubber Hose
--  handed back, into the character's inventory or, with nobody to take it,
--  onto the unit's square. Returns whether the unit had that feed.
function BK.feedCut(character, unit, fx, fy, fz)
    if not unit or P.partOf(unit) ~= "backup" then return false end
    local sq = unit:getSquare()
    if not sq then return false end
    fx, fy, fz = tonumber(fx), tonumber(fy), tonumber(fz)
    if not (fx and fy and fz) then return false end
    fx, fy, fz = math.floor(fx), math.floor(fy), math.floor(fz)
    if not BK.unlocked(character, unit) then return false end
    BK.freshen(unit)
    local d = P.data(unit)
    local list, kept, found = K.decodeFeeds(d.feeds), {}, false
    for i = 1, #list do
        local f = list[i]
        if not found and f.x == fx and f.y == fy and f.z == fz then
            found = true
        else
            kept[#kept + 1] = f
        end
    end
    if not found then return false end
    local feeds = K.encodeFeeds(kept)
    if feeds == "" then feeds = nil end
    d.feeds = feeds
    d.at = hoursNow()
    local nk = M.nodeKey(sq:getX(), sq:getY(), sq:getZ(), "backup")
    local bsq = getSquare(fx, fy, fz)
    local objs = bsq and bsq:getObjects()
    if objs then
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local md = o and o.getModData and o:getModData()
            if md and md.offgridFeed == nk then
                md.offgridFeed = nil
                o:transmitModData()
            end
        end
    end
    local inv = character and try(character, "getInventory")
    if inv then
        local item = instanceItem(K.HOSE)
        if item then
            inv:AddItem(item)
            sendAddItemToContainer(inv, item)
        end
    else
        K.dropHoses(sq, 1)
    end
    unit:transmitModData()
    BK.wake(d)
    return true
end

--- Disconnect fuel barrel as a command: the unit command's reach rules
--  (a unit in memory only; its barrels are out of reach otherwise), then
--  BK.feedCut, the path the timed action takes.
function BK.cmdFeedCut(player, args)
    if BK.tooSoon(player) then return false end
    local t = targetFor(player, args)
    if not t or t.far then return false end
    return BK.feedCut(player, t.unit, args.fx, args.fy, args.fz)
end

return BK

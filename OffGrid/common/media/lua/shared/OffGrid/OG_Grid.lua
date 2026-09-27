--[[ OffGrid -- keeping building relays and transformer circles registered,
     on every side of the network.

     WHAT IS BEING KEPT. A wired building and a transformer deliver power as
     chunk REGISTRATIONS: positions added to a chunk's generator list with
     IsoChunk.addGeneratorPos. A square
     has power when its own chunk lists a position that reaches it (OG_Reach
     has the arithmetic). The controller itself stays a real IsoGenerator and
     keeps its own circle; this file only ever handles what a system ADDS.

     WHY A RUNTIME AND NOT A ONE-OFF CALL. Three engine facts, each of which
     would quietly turn the lights off if ignored:

       * Every chunk load purges. IsoGenerator.chunkLoaded runs
         checkForMissingGenerators on the loaded chunk and on every chunk
         within radius/8+1 of it, deleting any entry whose square is loaded
         and holds no running IsoGenerator -- which is every one of ours. The
         Lua LoadChunk event fires AFTER that purge, in the same call
         (IsoChunk.doLoadGridsquare, 3863 then 3962), so re-adding there
         costs the player not a single frame of darkness.
       * Every side keeps its own lists. A client runs setSurroundingElectricity
         itself when a generator's flag arrives; a registration made on the
         server is never sent anywhere. So the registry travels (one global
         ModData table, OffGridGrid) and each side applies it to the chunks
         IT has loaded.
       * An entry whose square is NOT loaded survives the purge and is saved
         into the chunk file. So a system switched off while one of its chunks
         was away leaves an entry behind in that file, and the load that brings
         it back has to take it out again (the off index and the owed list).

     WHO WRITES WHAT. The authority -- the server, or singleplayer -- is the
     only writer of the registry (G.put, G.drop), and it transmits after a
     change (G.flush). A client asks for it once (ModData.request) and adopts
     every copy it is sent. A copy that arrives ON the server is ignored:
     accepting one would let any client light anything.

     WHAT A FLIP ALSO OWES. When a real generator switches, the engine re-ages
     fridge food under the OLD power state first (updateFridgeFreezerItems),
     and afterwards pokes the consumers in range (checkHaveElectricity: fridge
     hum, light sources, the process list -- client side only, the method
     does nothing on a server). Virtual power owes both, so this file does
     both, around every change of what is lit.
]]

require "OffGrid/OG_Reach"

OffGrid = OffGrid or {}
OffGrid.Grid = OffGrid.Grid or {}
local G = OffGrid.Grid
local R = OffGrid.Reach

local floor = math.floor

G.TAG = "OffGridGrid"
G.FMT = 1
-- In-game hours a dropped system, and a removed transformer's circle, are
-- remembered as OFF: long enough for any chunk that saved one of their
-- entries while they were on to load again and shed it.
G.DEAD_HOURS = 48
-- Registrations re-asserted per tick by the heal rotation, and chunk levels
-- whose consumers are refreshed per tick.
G.HEAL_PER_TICK = 16
G.REFRESH_PER_TICK = 2
-- The least time between two sends of the registry to every client, in real
-- milliseconds. A burst of changes (a player clicking through the Building
-- Picker, or a client sending wiring commands in a loop) goes out as one
-- message; the tick sends whatever the gap held back.
G.FLUSH_GAP_MS = 1000

--------------------------------------------------------------------- state

--- Everything in memory here is rebuilt from the registry, so a table added
--  here is reset by G.resetState, which the headless suites call between
--  cases.
function G.resetState()
    G.reg = nil
    G.applied = {}    -- system key -> { [reg id] = reg } this side has added
    G.owed = {}       -- chunk key -> { [reg id] = reg } removals its unloading prevented
    G.index = {}      -- chunk key -> regs of ON systems registered there
    G.offIndex = {}   -- chunk key -> regs of OFF or dead systems and ghosts
    G.ring = {}       -- every ON reg, for the heal rotation
    G.ringAt = 1
    G.refreshQ = {}
    G.refreshSet = {}
    G.expandCache = {}
    G.ctrlIndex = {}  -- chunk key -> keys of the systems whose controller stands there
    G.dirty = false
    G.lastFlush = nil
    G.lastR, G.lastV = nil, nil
end
G.resetState()

local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

--- The authority: a dedicated server, or singleplayer. Never a multiplayer
--  client.
function G.authority()
    return not isClient()
end

local function sandboxInt(name, fallback)
    local ok, v = pcall(function()
        local so = getSandboxOptions()
        local opt = so and so:getOptionByName(name)
        return opt and opt:getValue()
    end)
    v = ok and tonumber(v) or nil
    return v or fallback
end

--- The engine's range, as the sandbox states it. The engine reads the same
--  two options whenever an IsoGenerator is built (IsoGenerator.setGeneratorRange).
function G.range()
    local r = floor(sandboxInt("GeneratorTileRange", 20))
    local v = floor(sandboxInt("GeneratorVerticalPowerRange", 3))
    if r < 1 then r = 1 end
    if v < 0 then v = 0 end
    return r, v
end

--- The range the current registrations were expanded with: the one last
--  applied, or the sandbox's when nothing has been yet.
local function rangeNow()
    if G.lastR then return G.lastR, G.lastV end
    return G.range()
end

local function now()
    local gt = getGameTime and getGameTime()
    return gt and gt:getWorldAgeHours() or 0
end

--- A registry with every field it needs, whatever arrived.
local function normalise(t)
    if type(t) ~= "table" then t = {} end
    t.fmt = t.fmt or G.FMT
    if type(t.sys) ~= "table" then t.sys = {} end
    if type(t.ghost) ~= "table" then t.ghost = {} end
    return t
end

--- The registry this side believes. On the authority it IS the global
--  ModData table, so it is saved with the world; a client holds only what it
--  was last sent.
function G.bind()
    if G.reg then return G.reg end
    if G.authority() and ModData and ModData.getOrCreate then
        G.reg = normalise(ModData.getOrCreate(G.TAG))
    else
        G.reg = normalise({})
    end
    return G.reg
end

-------------------------------------------------------------- registrations

local function chunkAt(kx, ky)
    local cell = getCell and getCell()
    if not cell or not cell.getChunkForGridSquare then return nil end
    -- By tile, not by chunk index: IsoCell.getChunk(wx, wy) only walks the
    -- client chunk maps and answers nil on a dedicated server, where
    -- getChunkForGridSquare switches to ServerMap (IsoCell.java:333-373).
    local ok, c = pcall(cell.getChunkForGridSquare, cell, kx * 8, ky * 8, 0)
    if ok then return c end
    return nil
end

--- Every registration a system entry stands for: each circle centre on every
--  chunk its bounding box touches, each relay on its own chunk. Cached on
--  the entry's strings and the range.
local function expand(key, e)
    local r = G.lastR or G.range()
    local sig = (e.c or "") .. "|" .. (e.r or "") .. "|" .. r
    local cached = G.expandCache[key]
    if cached and cached.sig == sig then return cached.regs end
    local regs, seen = {}, {}
    local function add(p, kx, ky)
        local id = p.x .. "," .. p.y .. "," .. p.z .. "@" .. kx .. "," .. ky
        if seen[id] then return end
        seen[id] = true
        regs[#regs + 1] = { key = key, id = id, x = p.x, y = p.y, z = p.z, kx = kx, ky = ky }
    end
    local circles = R.decodePositions(e.c)
    for i = 1, #circles do
        local p = circles[i]
        local chunks = R.circleChunks(p.x, p.y, r)
        for j = 1, #chunks do add(p, chunks[j].kx, chunks[j].ky) end
    end
    local relays = R.decodePositions(e.r)
    for i = 1, #relays do
        local p = relays[i]
        local kx, ky = R.chunkOf(p.x, p.y)
        add(p, kx, ky)
    end
    G.expandCache[key] = { sig = sig, regs = regs }
    return regs
end
G.expand = expand

local function addReg(reg)
    local c = chunkAt(reg.kx, reg.ky)
    if not c then return false end
    c:addGeneratorPos(reg.x, reg.y, reg.z)
    return true
end

--- Take one of ours out of a loaded chunk. Never when a running generator
--  stands on the position: removeGeneratorPos removes EVERY entry at a
--  position, so that generator's own entry would go with ours. Returns
--  whether the chunk was there to ask.
local function removeReg(reg)
    local c = chunkAt(reg.kx, reg.ky)
    if not c then return false end
    local sq = getSquare(reg.x, reg.y, reg.z)
    if sq and sq.getGenerator then
        local g = sq:getGenerator()
        if g and g.isActivated and g:isActivated() then return true end
    end
    c:removeGeneratorPos(reg.x, reg.y, reg.z)
    return true
end

local function owe(reg)
    local ck = reg.kx .. "," .. reg.ky
    local list = G.owed[ck]
    if not list then
        list = {}
        G.owed[ck] = list
    end
    list[reg.id] = reg
end

------------------------------------------------------------- the lit squares

--- Visit every loaded square a registration lights: its chunk, within reach
--  of its position, across its band.
local function eachLit(reg, fn)
    local r, v = rangeNow()
    local lo, hi = R.band(reg.z, v)
    local r2 = r * r
    local x0, y0 = reg.kx * 8, reg.ky * 8
    for x = x0, x0 + 7 do
        local dx = x - reg.x
        for y = y0, y0 + 7 do
            local dy = y - reg.y
            if dx * dx + dy * dy <= r2 then
                for z = lo, hi do
                    local sq = getSquare(x, y, z)
                    if sq then fn(sq) end
                end
            end
        end
    end
end

--- Bank the fridge and freezer food in these registrations' squares under
--  the power state they had until now, as setActivated does before a real
--  generator flips (IsoGenerator.updateFridgeFreezerItems). Authority only:
--  containers are simulated there.
local function ageFood(regs)
    if not G.authority() or #regs == 0 then return end
    local done = {}
    for i = 1, #regs do
        eachLit(regs[i], function(sq)
            local k = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
            if done[k] then return end
            done[k] = true
            local objs = sq:getObjects()
            for j = 0, objs:size() - 1 do
                local o = objs:get(j)
                local n = o.getContainerCount and o:getContainerCount() or 0
                for ci = 0, n - 1 do
                    local cont = o:getContainerByIndex(ci)
                    local t = cont and cont:getType()
                    if t == "fridge" or t == "freezer" then
                        local items = cont:getItems()
                        for ii = 0, items:size() - 1 do
                            local it = items:get(ii)
                            if instanceof(it, "Food") then pcall(it.updateAge, it) end
                        end
                    end
                end
            end
        end)
    end
end
G.ageFood = ageFood

--- Queue the consumers under a registration for checkHaveElectricity. Not on
--  a dedicated server, where the engine method does nothing at all.
local function refresh(reg)
    if isServer() then return end
    local _, v = rangeNow()
    local lo, hi = R.band(reg.z, v)
    local k = reg.kx .. "," .. reg.ky .. "," .. lo .. "," .. hi
    if G.refreshSet[k] then return end
    G.refreshSet[k] = true
    G.refreshQ[#G.refreshQ + 1] = { kx = reg.kx, ky = reg.ky, lo = lo, hi = hi, k = k }
end

local function runRefresh(n)
    while n > 0 and #G.refreshQ > 0 do
        local job = table.remove(G.refreshQ, 1)
        G.refreshSet[job.k] = nil
        for x = job.kx * 8, job.kx * 8 + 7 do
            for y = job.ky * 8, job.ky * 8 + 7 do
                for z = job.lo, job.hi do
                    local sq = getSquare(x, y, z)
                    if sq then
                        local objs = sq:getObjects()
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            if o.couldBePoweredByGenerator and o:couldBePoweredByGenerator()
                                    and o.checkHaveElectricity then
                                pcall(o.checkHaveElectricity, o)
                            end
                        end
                    end
                end
            end
        end
        n = n - 1
    end
end

----------------------------------------------------------------- indexes

--- Rebuild the chunk indexes and the heal ring from the registry.
local function rebuild()
    local reg = G.bind()
    G.index, G.offIndex, G.ring, G.ctrlIndex = {}, {}, {}, {}
    for key, e in pairs(reg.sys) do
        -- Where each controller stands, so a chunk load can ask about the
        -- systems on that chunk without walking every system in the world.
        local cx, cy = string.match(key, "^(-?%d+),(-?%d+),")
        if cx then
            local ck = floor(tonumber(cx) / 8) .. "," .. floor(tonumber(cy) / 8)
            local l = G.ctrlIndex[ck]
            if not l then
                l = {}
                G.ctrlIndex[ck] = l
            end
            l[#l + 1] = key
        end
        local regs = expand(key, e)
        local live = e.on == true and not e.dead
        for i = 1, #regs do
            local rg = regs[i]
            local ck = rg.kx .. "," .. rg.ky
            local ix = live and G.index or G.offIndex
            local l = ix[ck]
            if not l then
                l = {}
                ix[ck] = l
            end
            l[#l + 1] = rg
            if live then G.ring[#G.ring + 1] = rg end
        end
    end
    -- A ghost is a circle centre that is gone. Its entries may sit in chunk
    -- files still; the off index is what sheds them.
    for pos in pairs(reg.ghost) do
        local ps = R.decodePositions(pos)
        if ps[1] then
            local regs = expand("ghost:" .. pos, { c = pos })
            for i = 1, #regs do
                local rg = regs[i]
                local ck = rg.kx .. "," .. rg.ky
                local l = G.offIndex[ck]
                if not l then
                    l = {}
                    G.offIndex[ck] = l
                end
                l[#l + 1] = rg
            end
        end
    end
    if G.ringAt > #G.ring then G.ringAt = 1 end
end
G.rebuild = rebuild

--- Make what this side has registered for one system match what the
--  registry wants of it.
function G.reconcile(key)
    local reg = G.bind()
    local e = reg.sys[key]
    local want = {}
    if e and e.on == true and not e.dead then
        local regs = expand(key, e)
        for i = 1, #regs do want[regs[i].id] = regs[i] end
    end
    local have = G.applied[key] or {}

    local gone, fresh = {}, {}
    for id, rg in pairs(have) do
        if not want[id] then gone[#gone + 1] = rg end
    end
    for id, rg in pairs(want) do
        if not have[id] then fresh[#fresh + 1] = rg end
    end

    -- Food first, under the state it had until now.
    if #gone > 0 or #fresh > 0 then
        local changing = {}
        for i = 1, #gone do changing[#changing + 1] = gone[i] end
        for i = 1, #fresh do changing[#changing + 1] = fresh[i] end
        ageFood(changing)
    end

    for i = 1, #gone do
        local rg = gone[i]
        have[rg.id] = nil
        if removeReg(rg) then refresh(rg) else owe(rg) end
    end
    -- Every wanted one, not only the fresh ones: adding is idempotent, and a
    -- reconcile is also how a side puts back what it has lost track of.
    for _, rg in pairs(want) do
        if addReg(rg) then
            if not have[rg.id] then refresh(rg) end
            have[rg.id] = rg
        end
    end
    if isEmpty(have) then G.applied[key] = nil else G.applied[key] = have end
end

local function reconcileAll(extra)
    local keys = {}
    for key in pairs(G.bind().sys) do keys[key] = true end
    for key in pairs(G.applied) do keys[key] = true end
    if extra then for key in pairs(extra) do keys[key] = true end end
    for key in pairs(keys) do G.reconcile(key) end
end

------------------------------------------------------------ the authority

local FIELDS = { "on", "c", "r", "t", "b" }

--- Write a system's entry. Authority only; a client cannot write. `fields`
--  holds any of on, c (circle centres), r (relays), t (wired target ids),
--  b (structure boxes). Returns whether anything changed.
function G.put(key, fields)
    if not G.authority() or type(key) ~= "string" then return false end
    local reg = G.bind()
    if G.lastR == nil then G.lastR, G.lastV = G.range() end
    local e = reg.sys[key]
    local isNew = e == nil
    e = e or {}
    local changed = isNew
    for i = 1, #FIELDS do
        local f = FIELDS[i]
        local v = fields[f]
        if v ~= nil and e[f] ~= v then
            if f == "c" and e.c and e.c ~= "" then
                -- Circles that go away become ghosts.
                local keep = {}
                local nowC = R.decodePositions(v)
                for j = 1, #nowC do keep[R.encodePositions({ nowC[j] })] = true end
                local was = R.decodePositions(e.c)
                for j = 1, #was do
                    local p = R.encodePositions({ was[j] })
                    if not keep[p] then reg.ghost[p] = now() end
                end
            end
            e[f] = v
            changed = true
        end
    end
    if e.dead and e.on == true and fields.on == true then
        e.dead = nil
        changed = true
    end
    if e.c == nil then e.c = "" end
    if e.r == nil then e.r = "" end
    if e.on == nil then e.on = false end
    if not changed then return false end
    reg.sys[key] = e
    G.dirty = true
    rebuild()
    G.reconcile(key)
    return true
end

--- A system that no longer exists: off at once, remembered as dead for a
--  while so any chunk file still holding its entries sheds them on load.
function G.drop(key)
    if not G.authority() then return end
    local reg = G.bind()
    local e = reg.sys[key]
    if not e then return end
    local circles = R.decodePositions(e.c)
    for i = 1, #circles do reg.ghost[R.encodePositions({ circles[i] })] = now() end
    e.on = false
    e.dead = now()
    G.dirty = true
    rebuild()
    G.reconcile(key)
end

--- Forget what the grace period has covered.
function G.housekeep()
    if not G.authority() then return end
    local reg = G.bind()
    local t, changed = now(), false
    for key, e in pairs(reg.sys) do
        if e.dead and t - e.dead > G.DEAD_HOURS then
            reg.sys[key] = nil
            G.applied[key] = nil
            G.expandCache[key] = nil
            changed = true
        end
    end
    for pos, at in pairs(reg.ghost) do
        if t - (tonumber(at) or 0) > G.DEAD_HOURS then
            reg.ghost[pos] = nil
            G.expandCache["ghost:" .. pos] = nil
            changed = true
        end
    end
    if changed then
        G.dirty = true
        rebuild()
    end
end

--- Send the registry to every client, once per batch of changes and never
--  twice within FLUSH_GAP_MS: it goes to every connection whether or not it
--  is near, so its rate is capped here rather than trusted to the callers. A
--  dedicated or hosted server only; singleplayer has nobody to tell.
function G.flush()
    if not G.dirty then return end
    if not isServer() then
        G.dirty = false
        return
    end
    local t = getTimestampMs and getTimestampMs() or nil
    if t and G.lastFlush and t >= G.lastFlush and t - G.lastFlush < G.FLUSH_GAP_MS then
        return
    end
    G.dirty = false
    G.lastFlush = t
    if ModData and ModData.transmit then ModData.transmit(G.TAG) end
end

function G.entry(key)
    return G.bind().sys[key]
end

--- Does the registry entry `e` wire target `t` (footprint `fp`)? A map
--  building by its key; a player-built structure also by its box meeting
--  one the entry wires, because a structure that has grown since resolves
--  to a new key. The server refuses a pick by this (OG_Distrib), and the
--  Building Picker previews it by this, so the two agree on every client.
function G.wires(e, t, fp)
    if type(e) ~= "table" or e.dead or not t then return false end
    local want = t.k .. ":" .. tostring(t.id)
    for id in string.gmatch(e.t or "", "[^;]+") do
        if id == want then return true end
    end
    if t.k ~= "s" or not fp then return false end
    local x0, y0, x1, y1, z0, z1 = R.fpBounds(fp)
    if not x0 then return false end
    for box in string.gmatch(e.b or "", "[^;]+") do
        local a, b, c, d, e0, e1 = string.match(box, "^(-?%d+),(-?%d+),(-?%d+),(-?%d+),(-?%d+),(-?%d+)$")
        if a then
            a, b, c, d, e0, e1 = tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e0), tonumber(e1)
            if a <= x1 and x0 <= c and b <= y1 and y0 <= d and e0 <= z1 and z0 <= e1 then return true end
        end
    end
    return false
end

--- The key of a system other than `skip` that wires the target, or nil.
function G.wiredBy(t, fp, skip)
    for key, e in pairs(G.bind().sys) do
        if key ~= skip and G.wires(e, t, fp) then return key end
    end
    return nil
end

----------------------------------------------------------------- all sides

--- A sandbox change of range re-expands every circle. The removals use the
--  registrations as they were applied, so nothing the old range put down is
--  left behind.
function G.checkRange()
    local r, v = G.range()
    if r == G.lastR and v == G.lastV then return false end
    G.lastR, G.lastV = r, v
    G.expandCache = {}
    rebuild()
    reconcileAll()
    return true
end

--- The chunk's indices. IsoChunk exposes no coordinate getter (its wx and wy
--  are fields Lua cannot read), so they come from any square it holds.
local function coordsOf(chunk)
    if not chunk or not chunk.getGridSquare then return nil end
    local levels = { 0 }
    local lo = chunk.getMinLevel and chunk:getMinLevel() or 0
    local hi = chunk.getMaxLevel and chunk:getMaxLevel() or 0
    for z = lo, hi do
        if z ~= 0 then levels[#levels + 1] = z end
    end
    for i = 1, #levels do
        local z = levels[i]
        for lx = 0, 7 do
            for ly = 0, 7 do
                local sq = chunk:getGridSquare(lx, ly, z)
                if sq then return floor(sq:getX() / 8), floor(sq:getY() / 8) end
            end
        end
    end
    return nil
end
G.chunkCoords = coordsOf

--- A chunk has loaded, and vanilla has just purged it and every chunk within
--  reach of it. Shed what should not be there, then put back everything this
--  side wants in all of those chunks.
function G.onLoadChunk(chunk)
    local reg = G.reg
    if not reg then return end
    local kx, ky = coordsOf(chunk)
    if not kx then return end
    if G.lastR == nil then G.lastR, G.lastV = G.range() end
    local ck = kx .. "," .. ky

    local owed = G.owed[ck]
    if owed then
        G.owed[ck] = nil
        for _, rg in pairs(owed) do removeReg(rg) end
    end
    local offs = G.offIndex[ck]
    if offs then
        for i = 1, #offs do removeReg(offs[i]) end
    end

    local rr = floor(G.lastR / 8) + 1
    for dx = -rr, rr do
        for dy = -rr, rr do
            local list = G.index[(kx + dx) .. "," .. (ky + dy)]
            if list then
                for i = 1, #list do
                    local rg = list[i]
                    if addReg(rg) then
                        local have = G.applied[rg.key]
                        if not have then
                            have = {}
                            G.applied[rg.key] = have
                        end
                        have[rg.id] = rg
                        -- The objects on the chunk that just arrived were
                        -- built before these entries were back.
                        if dx == 0 and dy == 0 then refresh(rg) end
                    end
                end
            end
        end
    end
end

--- A client's copy arrives. Ignored anywhere but a multiplayer client: the
--  server writes this table and never takes one.
function G.onReceive(tag, tbl)
    if tag ~= G.TAG or not isClient() then return end
    local old = G.reg and G.reg.sys or {}
    G.reg = normalise(type(tbl) == "table" and tbl or {})
    if G.lastR == nil then G.lastR, G.lastV = G.range() end
    rebuild()
    reconcileAll(old)
end

function G.onInit()
    G.reg = nil
    G.bind()
    G.lastR, G.lastV = G.range()
    rebuild()
end

function G.onGameStart()
    if isClient() and ModData and ModData.request then
        ModData.request(G.TAG)
    end
end

--- The heal rotation and the consumer refresh, a little every tick.
function G.onTick()
    if not G.reg then return end
    local n = #G.ring
    if n > 0 then
        for _ = 1, math.min(G.HEAL_PER_TICK, n) do
            if G.ringAt > n then G.ringAt = 1 end
            local rg = G.ring[G.ringAt]
            G.ringAt = G.ringAt + 1
            if addReg(rg) then
                local have = G.applied[rg.key]
                if not have then
                    have = {}
                    G.applied[rg.key] = have
                end
                have[rg.id] = rg
            end
        end
    end
    if #G.refreshQ > 0 then runRefresh(G.REFRESH_PER_TICK) end
    -- A change the gap held back goes out as soon as the gap has passed.
    if G.dirty and isServer() then G.flush() end
end

function G.everyMinute()
    if not G.reg then return end
    G.checkRange()
    if G.authority() then
        G.housekeep()
        G.flush()
    end
end

--- Does the registry light x, y, z? The same answer the engine gives once
--  the registrations are down, asked of the registry alone. For the probes
--  and the in-game self-test.
function G.litAt(x, y, z)
    if not G.reg then return false end
    local r, v = rangeNow()
    local list = G.index[floor(x / 8) .. "," .. floor(y / 8)]
    if not list then return false end
    for i = 1, #list do
        local rg = list[i]
        local lo, hi = R.band(rg.z, v)
        if z >= lo and z <= hi then
            local dx, dy = x - rg.x, y - rg.y
            if dx * dx + dy * dy <= r * r then return true end
        end
    end
    return false
end

--------------------------------------------------------------------- events

if Events then
    if Events.LoadChunk then Events.LoadChunk.Add(G.onLoadChunk) end
    if Events.OnTick then Events.OnTick.Add(G.onTick) end
    if Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(G.onInit) end
    if Events.OnReceiveGlobalModData then Events.OnReceiveGlobalModData.Add(G.onReceive) end
    if Events.OnGameStart then Events.OnGameStart.Add(G.onGameStart) end
    if Events.EveryOneMinute then Events.EveryOneMinute.Add(G.everyMinute) end
end

return G

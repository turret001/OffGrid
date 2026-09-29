--[[ OffGrid -- a backup generator's engine noise, and its run light, for
     whoever is near it.

     A backup generator is a plain IsoObject, not an IsoGenerator, so the
     engine plays nothing for it. Vanilla's generator plays its loop from
     IsoGenerator.update and its start-up and shutdown from setActivated, on
     every machine except a dedicated server (IsoGenerator.java:159-163,
     524-536, 758-771). This file does the same for the backups wherever
     there is a local player, singleplayer included: one emitter per running
     unit within 30 tiles playing the brand's Loop, Starting and Stopping
     when a unit it is already listening to is switched, and Backfire when
     the unit's backfire counter moves.

     THE RUN LIGHT. Can, 2026-09-29: "let's scrap the smoke effect. it looks
     like the machine itself is broken and smoking due to fault. let's just
     use a light to show if it's on or not." The lamp painted on the running
     sprite is enough by day, but the game darkens a whole sprite at night,
     lamp and all. So each running unit this file hears also gives off a
     small green light of its own (N.LIGHT_*), one IsoLightSource on its
     square, from the look that hears it run to the look that sees it stop,
     go, or fall out of earshot. Local to this machine, like the sounds: a
     light in the cell's list is drawn by this client only, and every client
     keeps its own from the same sprite.

     THE SPRITE IS THE CARRIER. The authority flips a unit between its `off`
     and `on` sprites (P.setState). transmitUpdatedSpriteToClients reaches
     every client in range, is still sent during fast-forward, and a client
     that streams the chunk in later gets the current sprite. The one other
     thing read is `bf` in the unit's ModData, the counter the authority
     bumps and pushes in the tick the unit backfires. Nothing here writes to
     the world: the sounds and lights are this machine's own.

     LOCAL SOUNDS ONLY: playSoundImpl, never playSound. On a multiplayer
     client playSound also sends PlayWorldSound (FMODSoundEmitter.java:
     389-401), and the server passes that on to every other client within 70
     tiles, which plays it with no handle to stop it (PlayWorldSoundPacket.
     java:37-69): a loop nobody could switch off, on top of the one their own
     copy of this file plays. The unit goes in as the sound's parent, as
     vanilla passes the generator. With nil, Kahlua may take the
     IsoGridSquare overload of playSoundImpl, which reads the square's x.

     THE EMITTER IS BORROWED. It comes from the world's pool
     (IsoWorld.getFreeEmitter) and goes back by itself the moment it falls
     silent (IsoWorld.java:2975-2993), to be lent to whatever asks next. So
     one is kept only while its loop plays, asked isPlaying(id) before it is
     touched again, let go when the loop stops, and never cleared with
     stopAll or moved with setPos, which would reach its next user.

     FINDING THE UNITS. Nothing searches the world for them: the engine hands
     each one over, and only its square is noted (N.found). A unit streaming
     in with its chunk comes through MapObjects.OnLoadWithSprite, on a
     multiplayer client as in singleplayer (IsoChunk.java:3822); one added
     to a loaded square on a multiplayer client through OnObjectAdded
     (AddItemToMapPacket.java:88); and one converted or put down in
     singleplayer, where AddTileObject fires no event, from OG_Backup's
     K.toBackup and OG_Place's G.seed. Once a real second every unit noted
     or already heard is looked at directly, one square each, which is what
     hears a unit come into earshot, a switch, a removal, an unloaded chunk
     or a player walking away. With none noted a frame costs nothing at all.
     tests/test_client.py pins that, so the cost cannot grow unnoticed.
]]

if isServer() then return end

require "OffGrid/OG_Parts"
require "OffGrid/OG_Backup"

OffGrid = OffGrid or {}
OffGrid.BackupSound = OffGrid.BackupSound or {}
local N = OffGrid.BackupSound
local P = OffGrid.Parts
local M = OffGrid.Model
local K = OffGrid.Backup

local floor = math.floor

-- The least real time between two looks at the units.
N.EVERY_MS = 1000
-- Floors heard either side of the player's own.
N.FLOORS = 1
-- Tiles past K.EMITTER_RANGE that a unit already playing keeps its loop, so
-- a player standing on the edge does not switch it on and off.
N.LEAVE = 2
-- The priority N.found is registered at with MapObjects. Not OG_System's 6
-- on the same sprites: singleplayer registers both, and an equal priority
-- replaces the callback already there (MapObjects.java:149-151). Above it,
-- so N.found runs first: OG_System's may turn the unit off as it streams in,
-- and the engine skips every callback still to come for a sprite the object
-- no longer shows (MapObjects.java:207-210).
N.PRIORITY = 7
-- The run light: green, reaching one tile, so it picks the unit out at night
-- without lighting the yard. The engine doubles each channel before it lights
-- with it (LightingJNI.java:325-327). Measured at night in 42.21 (V3-1,
-- 2026-09-29): a small green glow about two tiles across, clear at the normal
-- zoom and zoomed out.
N.LIGHT_R = 0.0
N.LIGHT_G = 0.3
N.LIGHT_B = 0.06
N.LIGHT_RADIUS = 1

N.units = {}        -- node key -> { x, y, z, tier, prefix, state, bf, em, loop, light }
N.candidates = {}   -- node key -> { x, y, z }: noted, not heard yet
N.lookAt = nil      -- getTimestampMs() when the units were last looked at

-- Every backup sprite, by name, with the brand and state it shows. One hash
-- lookup per object: P.describe would also read the ModData of every object
-- on the square, and OnObjectAdded hands over every object added anywhere.
local SPRITES = {}
for _, tier in ipairs(P.TIERS.backup or {}) do
    for _, state in ipairs(P.STATES.backup or {}) do
        for _, facing in ipairs(P.FACINGS) do
            local name = P.sprite("backup", "ground", tier, state, facing)
            if name then SPRITES[name] = { tier = tier, state = state } end
        end
    end
end

--- The backup standing on a square and what its sprite shows, or nil.
local function backupOn(sq)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local spr = o and o:getSprite()
        local name = spr and spr:getName()
        local b = name and SPRITES[name]
        if b then return o, b end
    end
    return nil
end

--- The backfire counter the authority bumps, 0 before the first.
local function backfires(obj)
    local md = obj:getModData()
    local d = md and md.offgrid
    local bf = d and d.bf
    if type(bf) == "number" then return bf end
    return 0
end

--- Is the unit's loop still playing on the emitter it was started on? The
--  same answer says whether that emitter is still this unit's to touch.
local function playing(u)
    return u.em ~= nil and u.loop ~= nil and u.em:isPlaying(u.loop)
end

--- A fresh emitter from the pool, at the middle of the unit's square.
local function emitterAt(u)
    local world = getWorld()
    return world and world:getFreeEmitter(u.x + 0.5, u.y + 0.5, u.z)
end

--- Stop the unit's loop and let its emitter go. The one place an emitter is
--  let go, so none is ever dropped with its loop still playing.
local function silence(u)
    if playing(u) then u.em:stopSound(u.loop) end
    u.em, u.loop = nil, nil
end

--- Start the unit's loop on an emitter of its own: after the start-up when
--  it has just been switched on, alone when it only came into earshot or
--  its loop fell silent.
local function listen(u, obj, announce)
    silence(u)
    local em = emitterAt(u)
    if not em then return end
    if announce then em:playSoundImpl(u.prefix .. "Starting", obj) end
    local id = em:playSoundImpl(u.prefix .. "Loop", obj)
    if id and id ~= 0 then u.em, u.loop = em, id end
end

--- A sound that plays once (Stopping, Backfire): on the emitter the loop is
--  playing on, or on a fresh one, which the pool takes back when it ends.
local function once(u, obj, suffix)
    local em = playing(u) and u.em or emitterAt(u)
    if em then em:playSoundImpl(u.prefix .. suffix, obj) end
end

--- The unit's run light on. Made once, on its square; then asked of the cell
--  once a look. The one-argument addLamppost lists a light only when it is
--  not listed already (IsoCell.java:2798-2808), so a look costs one search of
--  the cell's list, and a light the engine's light pass dropped (its chunk
--  map left it behind, LightingJNI.java:266) is listed again. With no cell
--  (the loading screen) nothing is lit.
local function lightOn(u)
    local cell = getCell and getCell()
    if not cell then return end
    if not u.light then
        if not (IsoLightSource and IsoLightSource.new) then return end
        u.light = IsoLightSource.new(u.x, u.y, u.z, N.LIGHT_R, N.LIGHT_G, N.LIGHT_B,
                                     N.LIGHT_RADIUS)
    end
    cell:addLamppost(u.light)
end

--- The unit's run light off, when it has one. Always the one-argument
--  removeLamppost: it sets the light's life to 0 and the engine drops it at its
--  next light pass (IsoCell.java:2839-2846, LightingJNI.java:351-360). The
--  x, y, z form calls clearInfluence, which throws IllegalStateException under
--  LightingJNI and leaves the light lit (seen in 42.21, 2026-09-29).
local function lightOff(u)
    local l = u.light
    u.light = nil
    if not l then return end
    local cell = getCell and getCell()
    if cell then cell:removeLamppost(l) end
end

--- Is square x, y, z within `far` tiles across and N.FLOORS floors up or
--  down of the player's square cx, cy, cz? A unit noted is first heard
--  within K.EMITTER_RANGE; one already heard keeps its loop N.LEAVE tiles
--  more.
local function earshot(x, y, z, cx, cy, cz, far)
    local dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= far * far and math.abs(z - cz) <= N.FLOORS
end

--- Does table t hold anything? (Kahlua has no `next`.)
local function any(t)
    for _ in pairs(t) do return true end
    return false
end

--- The first local player still alive: the ears the units are heard by.
local function listener()
    local n = getNumActivePlayers and getNumActivePlayers() or 1
    for i = 0, n - 1 do
        local pl = getSpecificPlayer(i)
        if pl and not pl:isDead() then return pl end
    end
    return nil
end

--- One unit as it stands now: `obj` on square x, y, z, showing sprite `b`.
--  A unit first heard and one already known both come here, so both follow
--  one rule.
function N.visit(x, y, z, obj, b)
    local key = M.nodeKey(x, y, z, "backup")
    local u = N.units[key]
    if u and u.tier ~= b.tier then
        -- Another brand put down on the square: the old one's loop and light go.
        silence(u)
        lightOff(u)
        u = nil
    end
    local bf = backfires(obj)
    if not u then
        local brand = K.BRANDS[b.tier]
        if not brand then return end
        u = { x = floor(x), y = floor(y), z = floor(z), tier = b.tier,
              prefix = brand.sound, state = b.state, bf = bf }
        N.units[key] = u
        -- First heard: a running unit gets its loop and no start-up, since
        -- nobody here heard it start, and its light.
        if b.state == "on" then
            listen(u, obj, false)
            lightOn(u)
        end
        return
    end
    if b.state == "on" then
        if u.state ~= "on" then
            listen(u, obj, true)
        elseif not playing(u) then
            listen(u, obj, false)
        end
        lightOn(u)
    else
        if u.state == "on" then
            silence(u)
            once(u, obj, "Stopping")
        end
        lightOff(u)
    end
    u.state = b.state
    if bf ~= u.bf then
        u.bf = bf
        once(u, obj, "Backfire")
    end
end

--- Stop listening to a unit, quietly, and put its light out: it did not shut
--  down, it went out of earshot, out of memory or out of the world.
function N.forget(key)
    local u = N.units[key]
    if u then
        silence(u)
        lightOff(u)
    end
    N.units[key] = nil
end

--- Note a unit to be heard: the first look with the player within earshot
--  reads its square, and hears it or finds it gone. Only a table write,
--  since the engine calls it from inside the chunk loader: nothing is
--  played here.
function N.note(x, y, z)
    x, y, z = floor(x), floor(y), floor(z)
    N.candidates[M.nodeKey(x, y, z, "backup")] = { x = x, y = y, z = z }
end

--- A backup the engine or the mod hands over: streamed in with its chunk
--  (MapObjects.OnLoadWithSprite), added on a multiplayer client
--  (OnObjectAdded), or converted or put down in singleplayer (K.toBackup,
--  G.seed).
function N.found(obj)
    local sq = obj and obj:getSquare()
    if sq then N.note(sq:getX(), sq:getY(), sq:getZ()) end
end

--- Every unit quiet and dark, nobody being left to hear or see them. They stay
--  noted, so a player who lives again finds them without their chunks
--  streaming in anew.
function N.silenceAll()
    for _, u in pairs(N.units) do
        silence(u)
        lightOff(u)
        N.note(u.x, u.y, u.z)
    end
    N.units = {}
end

--- Look at every unit, once a real second. One already heard: a square that
--  is gone (streamed out) or has no backup on it any more (picked up,
--  destroyed, converted back) forgets it, a player who walked away ends its
--  loop quietly and notes it again, and anything else is visited. One noted
--  and not heard yet: its square is read only once the player is within
--  earshot, and then it is visited, or dropped when its backup is gone.
function N.look(pl)
    local cx, cy, cz = floor(pl:getX()), floor(pl:getY()), floor(pl:getZ())
    local r = K.EMITTER_RANGE
    local keep = r + N.LEAVE
    local gone, away = {}, {}
    for key, u in pairs(N.units) do
        local sq = getSquare(u.x, u.y, u.z)
        local obj, b = nil, nil
        if sq then obj, b = backupOn(sq) end
        if not obj then
            gone[#gone + 1] = key
        elseif not earshot(u.x, u.y, u.z, cx, cy, cz, keep) then
            away[#away + 1] = key
        else
            N.visit(u.x, u.y, u.z, obj, b)
        end
    end
    for i = 1, #gone do N.forget(gone[i]) end
    for i = 1, #away do
        local u = N.units[away[i]]
        N.forget(away[i])
        N.note(u.x, u.y, u.z)
    end
    local near = {}
    for key, c in pairs(N.candidates) do
        if earshot(c.x, c.y, c.z, cx, cy, cz, r) then near[#near + 1] = key end
    end
    for i = 1, #near do
        local c = N.candidates[near[i]]
        N.candidates[near[i]] = nil
        local sq = getSquare(c.x, c.y, c.z)
        local obj, b = nil, nil
        if sq then obj, b = backupOn(sq) end
        if obj then N.visit(c.x, c.y, c.z, obj, b) end
    end
end

function N.onTick()
    if not any(N.units) and not any(N.candidates) then return end
    local pl = listener()
    if not pl then
        N.silenceAll()
        return
    end
    local now = getTimestampMs()
    if not N.lookAt or now - N.lookAt >= N.EVERY_MS then
        N.lookAt = now
        N.look(pl)
    end
end

--- A new game: the last one's emitters and lights went with its world (the
--  lights with its cell, so none is taken off the new one). The units noted
--  stay: the login area streams in during the loading screen, before this
--  event (IngameState.java:761), and one noted in the last world is dropped
--  by the first look that finds no backup on its square.
function N.reset()
    N.units, N.lookAt = {}, nil
end

--- An object added to a loaded square on a multiplayer client.
local function onObjectAdded(obj)
    local spr = obj and obj:getSprite()
    local name = spr and spr:getName()
    if name and SPRITES[name] then N.found(obj) end
end

--- Every backup sprite, so a unit streaming in with its chunk is noted. At
--  file load, as OG_System does: the login area's chunks stream in during
--  the loading screen, before OnGameStart. Registering again replaces the
--  same callback, so it is idempotent.
local function registerSprites()
    if not (MapObjects and MapObjects.OnLoadWithSprite) then return end
    for name in pairs(SPRITES) do
        MapObjects.OnLoadWithSprite(name, N.found, N.PRIORITY)
    end
end
registerSprites()

Events.OnTick.Add(N.onTick)
Events.OnGameStart.Add(N.reset)
Events.OnGameStart.Add(registerSprites)
Events.OnObjectAdded.Add(onObjectAdded)

return N

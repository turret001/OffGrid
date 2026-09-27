--[[ OffGrid -- the solar lamps.

     A Solar Garden Lamp and a Solar Street Lamp. Each is a vanilla light (an
     IsoLightSwitch, built from the tile's `lightswitch` property) running on
     its own battery, which the engine already does well: with useBattery and
     hasBattery set, canSwitchLight asks only whether the battery holds a
     charge, the lighting pass lights it on every client with no grid power,
     and IsoLightSwitch.update drains `delta` per game minute while it is lit
     and switches it off when the charge runs out, on the authority, synced to
     every client. Bulbs burn out on the sandbox's own lifespan.

     What vanilla lamps lack is a panel, and that is this file. On the
     authority, once a game minute, every lamp in memory is charged from the
     sun (the arrays' model, OG_Model.lampWatts), lit at dusk and put out at
     dawn, when the town's street lights are (OG_Model.LAMP_NIGHT), and has
     the time it spent out of memory replayed when it comes back. Only the
     change from day to night, and back, switches it, the way a photocell
     does: a player who puts a lamp out at midnight keeps it out until the
     next dusk.

     The charge, the bulb and its colour also live in the lamp's own ModData
     (`offgrid`). Vanilla carries a lamp's battery and bulb settings on the
     item only for a moveable without a CustomItem (Moveable.ReadFromWorldSprite
     returns before it sets isLight, and Moveable.save writes the light fields
     only when isLight), and every Off-Grid item has one. ModData does ride
     along: vanilla copies an object's onto the item it is lifted as, and back.

     A bulb wears only while its lamp is in memory. The engine keeps the burn
     count in fields Lua cannot reach (IsoLightSwitch.bulbBurnMinutes), and the
     replay of an absence starts the engine's clock afresh, so an absence adds
     no wear (2026-09-26).
]]

require "TimedActions/ISLightActions"
require "OffGrid/OG_Model"
require "OffGrid/OG_Env"
require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Lamps = OffGrid.Lamps or {}
local L = OffGrid.Lamps
local P = OffGrid.Parts
local M = OffGrid.Model
local E = OffGrid.Env

-- Lamps in memory on the authority, by square: "x,y,z" -> the IsoLightSwitch.
L.lamps = L.lamps or {}
-- The longest absence replayed. A lamp left for a season settles as if a
-- fortnight had passed, which is long enough to be empty or full either way.
L.REPLAY_MAX_H = 24 * 14
-- A gap longer than this since the lamp's last minute is an absence.
L.GAP_H = 2 / 60
-- Clients are sent the charge when it has moved this much since the last send.
L.SYNC_STEP = 0.01

local function try(obj, method, ...)
    if not obj or not obj[method] then return nil end
    local ok, v = pcall(obj[method], obj, ...)
    if ok then return v end
    return nil
end

local function key(sq)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function authority()
    return not isClient()
end

--- Is this object one of the solar lamps?
function L.isLamp(obj)
    return obj ~= nil and P.partOf(obj) == "lamp"
end

--- The charge the engine holds, 0..1.
function L.charge(obj)
    local v = try(obj, "getPower")
    if type(v) ~= "number" or v ~= v then return 0 end
    return clamp(v, 0, 1)
end

--- Give the engine the lamp's battery: its own, always fitted, drained at the
--  lamp's draw. Idempotent, and nothing else about the light is touched.
function L.arm(obj)
    local info = P.describe(obj)
    if not info or info.kind ~= "lamp" then return false end
    if not instanceof(obj, "IsoLightSwitch") then return false end
    obj:setUseBatteryDirect(true)
    obj:setHasBatteryRaw(true)
    obj:setDelta(M.lampDelta(info.tier))
    return true
end

--- Light or put out a lamp through the engine's full path, which switches
--  its light source and syncs every client. Out works at any charge (the
--  flag-only form left the light burning, and the checked form refuses an
--  empty battery); on is checked, so an empty lamp stays dark.
--
--  setActive does nothing when the flag already matches, and a lamp whose
--  flag alone was dropped (L.register) keeps its light source burning until
--  the full path switches it: `force` raises the flag first, so the full path
--  runs. Only for that lamp: every full path broadcasts to the clients
--  (IsoLightSwitch.setActive, syncIsoObject), and forcing it for every dark
--  lamp sent a packet per lamp on every tick of a fast-forwarded sleep.
local function switch(obj, on, force)
    if on then
        obj:setActive(true)
    else
        if force and not obj:isActivated() then obj:setActive(true, true, true) end
        obj:setActive(false, false, true)
    end
end
L.switch = switch

--- Is the lamp's light itself burning? The lighting pass keeps a light
--  source on while its lamp can switch (LightingJNI), whatever the lamp's
--  flag says, and only the full path puts it out (switchLight).
local function burning(obj)
    local ls = try(obj, "getLights")
    local n = ls and try(ls, "size")
    if type(n) ~= "number" or n < 1 then return false end
    return try(try(ls, "get", 0), "isActive") == true
end

--- Set the charge on the lamp and in its ModData together.
local function setCharge(obj, d, charge)
    charge = clamp(charge or 0, 0, 1)
    obj:setPower(charge)
    d.charge = charge
    return charge
end

--- A lamp just placed. `item` is the item it was placed from: a lamp lifted
--  and put down again brings its charge and its bulb (or the lack of one)
--  through the ModData vanilla copied onto the item; a new one starts half
--  charged with the bulb it was built with. `turning` for the place that
--  finishes a rotation, which keeps the lamp's switch and its day or night.
function L.placed(obj, item, turning)
    if not L.arm(obj) then return end
    local d = P.data(obj)
    local src = item and item.getModData and item:getModData()
    src = src and src.offgrid
    if type(src) == "table" and type(src.charge) == "number" then
        setCharge(obj, d, src.charge)
        if src.nobulb then
            obj:setBulbItemRaw(nil)
        elseif type(src.bulb) == "string" and src.bulb ~= "" then
            -- The bulb it was lifted with, and its colour: a new lamp object
            -- starts with a plain bulb and the tile's warm white, so a red
            -- bulb came back white, and came out of it a plain one.
            obj:setBulbItemRaw(src.bulb)
        end
        if type(src.lightR) == "number" and type(src.lightG) == "number"
                and type(src.lightB) == "number" then
            obj:setPrimaryR(src.lightR)
            obj:setPrimaryG(src.lightG)
            obj:setPrimaryB(src.lightB)
        end
        d.nobulb = src.nobulb and true or nil
    else
        setCharge(obj, d, M.LAMP_FRESH)
        d.nobulb = nil
    end
    local lit = false
    if turning and type(src) == "table" then
        -- A turn is a lift and a place (ISMoveableSpriteProps.rotateMoveable):
        -- the lamp keeps its day or night and its switch, so one put out by
        -- hand stays out and one lit by hand stays lit (review, 2026-09-26).
        if type(src.night) == "boolean" then d.night = src.night else d.night = nil end
        lit = src.lit == true and obj:hasLightBulb() and L.charge(obj) > 0
    else
        -- Its first minute decides day or night afresh, and lights it if it
        -- is dark: put down at night, it shows at once that it works.
        d.night = nil
    end
    d.lit = nil
    d.leftOn = nil
    d.away = nil
    d.at = E.worldHours()
    switch(obj, lit)
    L.register(obj)
    -- On a server vanilla sent the new light to every client before this
    -- armed it; send what it is now: battery, charge, bulb, drain.
    if isServer() then obj:syncCustomizedSettings(nil) end
end

--- A lamp in memory. Registered on every side so the sprite callback is the
--  same everywhere; only the authority ticks them.
function L.register(obj)
    local sq = obj and obj:getSquare()
    if not sq or not L.isLamp(obj) then return end
    if not authority() then return end
    local armed = obj.getUseBattery and obj:getUseBattery()
    L.arm(obj)
    if not armed and isServer() then obj:syncCustomizedSettings(nil) end
    local d = P.data(obj)
    if type(d.charge) == "number" and d.at == nil then
        -- A lamp saved before it had a clock: take the charge it recorded.
        setCharge(obj, d, d.charge)
    end
    -- Back after time out of memory: the next minute replays the absence
    -- (L.update). Marked here, where the lamp is seen streaming in, and not
    -- read off the clock later: in a fast-forwarded sleep the game moves
    -- several minutes between two ticks of a lamp that never left, the
    -- engine has already drained it for those, and taking every such gap for
    -- an absence replayed each tick with a switch per lamp (2026-09-26).
    --
    -- Lit when it left: the engine saves the lamp's minute stamp
    -- (IsoLightSwitch.save/load, lastMinuteStamp) and on its first update
    -- drains `delta` for every minute since, as if it had burned the whole
    -- absence, day included; the replay then billed the absence again (found
    -- 2026-09-26). So the replay alone decides: the lamp is put out by its
    -- flag here, before that first update, which makes the engine drop its
    -- stamp (update() resets it for a lamp that is off), and the replay on the
    -- next minute lights it again if it should be lit.
    if type(d.at) == "number" and E.worldHours() - d.at > L.GAP_H then
        d.away = true
        if obj:isActivated() then
            d.leftOn = true
            obj:setActive(false, true, true)
        end
    end
    L.lamps[key(sq)] = obj
end

--- The weather at `hoursAgo` hours before `env`. The engine's own readings
--  exist only for now, so the two a lamp needs are worked out for then: the
--  night strength the street lights switched on (M.nightStrength, from that
--  date's engine day; 1 and 0 under Endless Night and Endless Day, which
--  `cycle` names, as E.skyParams gives it), and the panel's daylight from the
--  sun's height. `days`, when given, keeps each past date's engine day, so a
--  fortnight's replay asks the engine for fifteen days and not 336 hours.
local function rewind(env, hoursAgo, cycle, days)
    local e = {}
    for k, v in pairs(env) do e[k] = v end
    local h = (env.hour or 12) - hoursAgo
    local back = 0
    while h < 0 do
        h = h + 24
        back = back + 1
    end
    e.hour = h
    if back > 0 and E.dateAt then
        local sky = days and days[back]
        if not sky then
            local y, m0, day = E.dateAt(-back)
            sky = { month = m0 + 1, day = day, dayOfYear = M.dayOfYear(m0 + 1, day) }
            sky.noon, sky.dayHours, sky.sky = E.skyDay(y, m0, day)
            if days then days[back] = sky end
        end
        e.month, e.day, e.dayOfYear = sky.month, sky.day, sky.dayOfYear
        e.noon, e.dayHours, e.sky = sky.noon, sky.dayHours, sky.sky
    end
    if cycle == "night" then
        e.night = 1
    elseif cycle == "day" then
        e.night = 0
    elseif type(e.noon) == "number" and type(e.dayHours) == "number" then
        e.night = M.nightStrength(e.hour, e.noon - e.dayHours / 2, e.noon + e.dayHours / 2)
    else
        e.night = nil
    end
    local sun = M.solarHour(e.hour, e.dayOfYear, e.noon, e.dayHours, e.latitude)
    e.daylight = clamp(M.sinAltitude(e.dayOfYear, sun, e.latitude) * 3, 0, 1)
    return e
end
L.rewind = rewind

--- One game minute for one lamp, on the authority.
function L.update(obj, env, now)
    local info = P.describe(obj)
    if not info then return end
    local d = P.data(obj)
    local sq = obj:getSquare()
    local sunlit = E.isSunlit(sq)
    local charge = L.charge(obj)
    local elapsed = now - (d.at or now)
    local leftOn, away = d.leftOn, d.away
    d.leftOn, d.away = nil, nil

    -- The battery is built in. One pulled before 2.12 (vanilla's Remove
    -- Battery reached a lamp through a click beside it) goes back.
    if not obj:getHasBattery() then
        L.arm(obj)
        if isServer() then obj:syncCustomizedSettings(nil) end
    end

    -- The engine puts an empty lamp out by its flag alone
    -- (IsoLightSwitch.update), and the lighting pass puts out only a light
    -- that cannot switch. In a sleep's fast-forward this minute runs in the
    -- same frame and charges the battery again first, so the light kept
    -- shining with its switch off until dusk (review, 2026-09-26). A light
    -- still burning under a lowered flag is put out properly; after an
    -- ordinary switch-off it is already out, and nothing is sent.
    if not leftOn and not obj:isActivated() and burning(obj) then
        switch(obj, false, true)
    end

    if (away or leftOn) and elapsed > 0 then
        -- Out of memory since d.at (L.register saw it come back): replay the
        -- absence, hour by hour, ending at now, the way the lamp runs in
        -- memory: from how it left, lit or not, switched only at dusk and
        -- dawn, so a hand on the switch holds until the next change. It starts
        -- from the charge it left with, which the engine may already have
        -- drawn on (see L.register).
        local hours = math.min(elapsed, L.REPLAY_MAX_H)
        local start = (type(d.charge) == "number") and d.charge or charge
        local _, _, cycle = E.skyParams()
        -- The debug Always Day power keeps the lamps in memory dark (the
        -- engine answers night 0 for it, ClimateManager.getNightStrength), so
        -- an absence under it is replayed as all day. Singleplayer only: a
        -- dedicated server has no player of its own.
        local me = getPlayer and getPlayer()
        if me and try(me, "isAlwaysDayCheat") == true then cycle = "day" end
        local days = {}
        local lit, night
        charge, lit, night = M.lampReplay(info.tier, info.facing, start, hours,
                                          function(h) return rewind(env, hours - h, cycle, days) end,
                                          sunlit, leftOn or obj:isActivated(), d.night,
                                          obj:hasLightBulb())
        charge = setCharge(obj, d, charge)
        d.night = night
        switch(obj, lit and charge > 0 and obj:hasLightBulb(), leftOn)
    elseif elapsed > 0 then
        local watts = M.lampWatts(info.tier, info.facing, env, sunlit)
        if watts > 0 then
            charge = setCharge(obj, d, M.lampCharge(info.tier, charge, watts, elapsed * 60))
        else
            d.charge = charge
        end
    else
        d.charge = charge
    end

    -- Dusk and dawn, when the street lights switch. Only a change of the two
    -- switches the lamp, so a hand on the switch in between is left alone.
    local was = d.night
    local night = M.lampNight(env.night, was)
    if night ~= was then
        d.night = night
        if night then
            if charge > 0 and obj:hasLightBulb() then switch(obj, true) end
        else
            switch(obj, false)
        end
    end

    d.nobulb = (not obj:hasLightBulb()) or nil
    d.at = now
    P.setState(obj, obj:isActivated() and "on" or "off")

    -- Clients read the charge for the menu, and canSwitchLight on their side
    -- needs it above zero. Vanilla sends it while draining; this sends it
    -- while charging, once per whole per cent.
    if isServer() and math.abs(charge - (d.synced or -1)) >= L.SYNC_STEP then
        d.synced = charge
        obj:syncCustomizedSettings(nil)
    end
end

--- The heartbeat: every lamp in memory, once a game minute, on the authority.
function L.tick()
    if not authority() then return end
    -- (Kahlua has no `next`: an empty table is found by trying to walk it.)
    local any = false
    for _ in pairs(L.lamps) do any = true break end
    if not any then return end
    local env = E.read()
    env.outputScale = (P.sandbox("OutputScale") or 100) / 100
    local now = E.worldHours()
    for k, obj in pairs(L.lamps) do
        local ix = try(obj, "getObjectIndex")
        if type(ix) ~= "number" or ix < 0 or not obj:getSquare() then
            L.lamps[k] = nil
        else
            local ok, err = pcall(L.update, obj, env, now)
            if not ok then print("OffGrid lamps: " .. tostring(err)) end
        end
    end
end

--- What the lamp's menu says about it: the charge, and what it will do.
function L.status(obj)
    local pct = math.floor(L.charge(obj) * 100 + 0.5)
    local key
    -- The roof before the empty battery: an empty lamp under a roof never
    -- charges, and "it charges in the sun" sent the player waiting.
    if not obj:hasLightBulb() then
        key = "IGUI_OffGrid_LampNoBulb"
    elseif obj:isActivated() then
        key = "IGUI_OffGrid_LampLit"
    elseif not E.isSunlit(obj:getSquare()) then
        key = "IGUI_OffGrid_LampShaded"
    elseif pct <= 0 then
        key = "IGUI_OffGrid_LampEmpty"
    else
        key = "IGUI_OffGrid_LampWaits"
    end
    return P.txt("IGUI_OffGrid_LampStatus", pct .. "%", getText(key))
end

----------------------------------------------------------------------- events

--- Every lamp sprite, so a lamp streaming in with its chunk is registered.
local function registerSprites()
    if not (MapObjects and MapObjects.OnLoadWithSprite) then return end
    local names = {}
    for _, tier in ipairs(P.TIERS.lamp) do
        for _, state in ipairs(P.STATES.lamp) do
            for _, f in ipairs(P.FACINGS) do
                local n = P.sprite("lamp", "ground", tier, state, f)
                if n then names[#names + 1] = n end
            end
        end
    end
    for i = 1, #names do
        MapObjects.OnLoadWithSprite(names[i], L.register, 6)
        MapObjects.OnNewWithSprite(names[i], L.register, 6)
    end
end
-- At file load and again at start, as OG_System does: the login area's
-- chunks stream in during the loading screen, before OnGameStart.
registerSprites()
if Events then
    if Events.OnGameStart then Events.OnGameStart.Add(registerSprites) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(registerSprites) end
    if Events.EveryOneMinute then Events.EveryOneMinute.Add(L.tick) end
end

-- The battery is built in, so vanilla's Remove Battery and Add Battery never
-- apply to a lamp. The lamp's menu hides Remove Battery (OG_Context), but
-- vanilla also offers it from a right-click beside the lamp and from the
-- joypad, which fetch every object on the square
-- (ISWorldObjectContextMenuLogic); a battery pulled out left the lamp dark and
-- handed out one charged by the sun, and one put back was charged by the panel
-- from then on. Refused where the action is checked: on a multiplayer client
-- isValid always answers yes, and the server asks again in complete.
if ISLightActions then
    local origRemoveValid = ISLightActions.isValidRemoveBattery
    if origRemoveValid then
        function ISLightActions:isValidRemoveBattery(...)
            if L.isLamp(self.lightswitch) then return false end
            return origRemoveValid(self, ...)
        end
    end
    local origAddValid = ISLightActions.isValidAddBattery
    if origAddValid then
        function ISLightActions:isValidAddBattery(...)
            if L.isLamp(self.lightswitch) then return false end
            return origAddValid(self, ...)
        end
    end
end

return L

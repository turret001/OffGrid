--[[ OffGrid -- an optional diagnostic report for Error Magnifier.

     Error Magnifier (workshop 2896041179) lets a mod register a function that
     returns a description of its own state. The panel then shows "Report: Yes"
     against that mod, and its Copy button folds the text into what the player
     puts on the clipboard. That is the whole mechanism: it is collected when
     the player opens the tab or presses Copy, it goes to the clipboard, and
     nowhere else. Project Zomboid exposes no HTTP or socket surface to Lua, so
     there is no submission path for any of this to take.

     THIS IS NOT A DEPENDENCY, and the whole file is written so that it cannot
     become one.

       * mod.info gains no `require=`. Off-Grid must load and run identically
         for the overwhelming majority of players who do not have Error
         Magnifier installed.
       * getActivatedMods() is consulted BEFORE require(). PZ's require returns
         nil rather than throwing when a module is missing
         (LuaManager.java:4904-4921), so requiring blindly would be safe, but it
         also emits `require("errorMagnifier_Main") failed` as a Lua warning.
         Asking first keeps the log clean for everyone who does not have it.
       * Registration is deferred to OnGameStart rather than done at file scope,
         so a change in mod load order cannot decide whether this works.
       * Nothing here prints on the absent path. A soft integration that
         announces its own absence is just noise in someone else's log.

     ON require(): it does NOT re-run an already loaded file. RunLuaInternal
     checks a `loaded` set and hands back the cached return value
     (LuaManager.java:1344), so this gets the same table the panel itself uses.
     If it re-ran the module it would hand back a fresh one, and the report
     would register onto a table nothing renders.

     WHAT GOES IN THE REPORT is chosen from what actually cost time to diagnose.
     Both bugs fixed in 2.8.0 and the crash fixed in 2.8.1 would have been
     obvious from this: the sandbox block shows whether the world is even
     configured the way the reporter thinks, the parts list shows the state each
     object is REALLY in rather than what it looks like, and the env block shows
     what the model is being fed at the moment the report was taken.

     Deliberately NOT included: anything about the machine, the account, the
     Steam id, the server address, or other players. A player pasting this into
     a Discord thread should not be handing over anything but Off-Grid's state.
]]

if isServer() then return end

require "OffGrid/OG_Parts"
require "OffGrid/OG_Model"
require "OffGrid/OG_Env"
require "OffGrid/OG_Almanac"
require "OffGrid/OG_Boot"

OffGrid = OffGrid or {}
OffGrid.Report = OffGrid.Report or {}
local R = OffGrid.Report

R.MOD_ID = "OffGrid"
R.DISPLAY = "Off-Grid: Solar Power"

-- Kept in step with mod.info by tests/test_report.py, which fails the build if
-- the two ever disagree. A report that names the wrong version is worse than
-- one that names none, because it sends whoever reads it to the wrong source.
R.VERSION = "2.10.1"

-- How far around the player to look for the mod's own objects. Matched to the
-- link radius rather than picked, so the report covers the same ground a
-- controller would.
R.SCAN_RADIUS = 24

--- Is Error Magnifier actually active in this session?
--
--  getActivatedMods() is an ArrayList of mod ids. Checked with a plain loop
--  rather than :contains() because the list is a Java collection and the
--  argument types have bitten this project before.
function R.magnifierActive()
    if not getActivatedMods then return false end
    local ok, mods = pcall(getActivatedMods)
    if not ok or not mods then return false end
    local n = 0
    local ok2 = pcall(function() n = mods:size() end)
    if not ok2 then return false end
    for i = 0, n - 1 do
        local id
        pcall(function() id = mods:get(i) end)
        if id == "errorMagnifier" then return true end
    end
    return false
end

--- Every sandbox option the mod declares, read live.
function R.sandbox()
    local sv = SandboxVars and SandboxVars.OffGrid
    if not sv then return "SandboxVars.OffGrid is nil" end
    local out = {}
    for name in pairs(OffGrid.Parts.SANDBOX_DEFAULTS) do
        local v = sv[name]
        out[name] = (v == nil) and "MISSING" or v
    end
    return out
end

--- Hours to two places, or nil.
local function hours2(v)
    return v and math.floor(v * 100 + 0.5) / 100
end

--- What the irradiance model is being fed right now.
--
--  The sky block is what lines the model's sun up with the game's: the
--  engine's high noon and day length, where they came from ("engine" is the
--  live DayInfo, "calendar" the mod's port, "cycle" Endless Day or Endless
--  Night), the solar hour the geometry ran at, and the port's answer for
--  today beside it. On "engine" the two pairs agree to about a minute; a
--  patch that changes the engine's formula shows up here as a gap between
--  them.
function R.env()
    local E, M = OffGrid.Env, OffGrid.Model
    local ok, e = pcall(E.read)
    if not ok or not e then return "Env.read() failed: " .. tostring(e) end
    -- Past a successful read these are pure arithmetic and guarded engine
    -- calls (P.try), so they need no pcall of their own.
    local y, m0, d = E.dateAt(0)
    local calNoon, calHours = M.engineDay(y, m0 + 1, d, E.skyParams())
    local sun = M.solarHour(e.hour, e.dayOfYear, e.noon, e.dayHours, e.latitude)
    return {
        dayOfYear   = e.dayOfYear,
        hour        = e.hour and math.floor(e.hour * 100) / 100,
        month       = e.month,
        day         = e.day,
        cloud       = e.cloud,
        fog         = e.fog,
        precipitation = e.precipitation,
        temperature = e.temperature,
        groundSnow  = e.groundSnow,
        noon        = hours2(e.noon),
        dayHours    = hours2(e.dayHours),
        sky         = e.sky or "none",
        sun         = hours2(sun),
        calendarNoon     = hours2(calNoon),
        calendarDayHours = hours2(calHours),
    }
end

--- Did the mod's tiles and items come up? The boot check's counts.
--
--  Fewer than all tiles is the fingerprint of another mod claiming the same
--  tiledef file number: the engine loads only one of the two, and the loser's
--  placed parts come back missing or broken after a load.
function R.boot()
    local B = OffGrid.Boot
    if not (B and B.done and B.tilesWanted) then return "boot check has not run" end
    return {
        ok           = B.ok and true or false,
        tiles        = B.tiles .. "/" .. B.tilesWanted,
        items        = B.items .. "/" .. B.itemsWanted,
        firstMissing = B.firstMissing or "none",
    }
end

--- How many cable links a controller's wire string holds, read the way the
--  simulation reads it (a malformed edge is not a link).
local function linkCount(wire)
    return #OffGrid.Model.wireParse(wire)
end

--- One part as the report shows it.
--
--  Every field is set with an explicit test, never `cond and v or nil`: that
--  idiom turns a false into nil, and a controller that is NOT tripped or NOT
--  shed is exactly the answer a bug report needs. The owner's account name is
--  left out on purpose (it is another player's name); whether the part has an
--  owner, and whether it is the reporting player, is enough to diagnose a
--  refused pickup.
function R.partEntry(o, info, d, square, playerObj)
    local e = {
        at        = square and (square:getX() .. "," .. square:getY() .. "," .. square:getZ()) or "?",
        what      = info.kind .. "/" .. info.mount .. "/" .. info.tier,
        sprite    = info.state,
        condition = d.condition,
    }
    local function put(key, value)
        if value ~= nil then e[key] = value end
    end
    if info.kind == "array" then
        put("panels", d.panels)
        put("soiling", d.soiling)
        put("snow", d.snow)
        put("sunlit", OffGrid.Env.isSunlit(square))
        put("wiredTo", d.sys or "none")
    elseif info.kind == "bank" then
        put("cells", d.cells)
        put("charge", d.charge)
        put("health", OffGrid.Parts.bankHealth(d))
        put("wiredTo", d.sys or "none")
    elseif info.kind == "controller" then
        put("online", d.online == true)
        put("powered", d.powered == true)
        put("trip", d.trip == true)
        put("shed", d.lvd == true)
        put("backAtSoc", d.lvdSoc)
        put("floorSoc", d.floorSoc)
        put("soc", d.soc)
        put("capacityWh", d.capacity)
        put("generatingW", d.gen)
        put("loadW", d.load)
        put("demandW", d.demand)
        put("arrays", d.arrayCount)
        put("banks", d.bankCount)
        put("shadedArrays", d.shaded)
        put("equalise", d.equalise == true)
        put("links", linkCount(d.wire))
        put("wire", d.wire or "")
    end
    local owner = d.owner
    if type(owner) == "string" and owner ~= "" then
        e.owned = true
        local me = playerObj and playerObj.getUsername and playerObj:getUsername()
        e.ownedByYou = type(me) == "string" and string.lower(me) == string.lower(owner)
    else
        e.owned = false
    end
    return e
end

--- Off-Grid objects standing near the player, and the state each is really in.
--
--  This is the half that matters. A panel that LOOKS clean but carries
--  condition 22 is the exact shape of the seeding bug fixed in 2.8.0, and it is
--  invisible from a screenshot.
function R.parts(playerObj)
    if not playerObj then return "no player" end
    local sq = playerObj.getSquare and playerObj:getSquare()
    if not sq then return "player has no square" end

    local found, counts = {}, {}
    local P = OffGrid.Parts
    local ok = pcall(P.forEachSquare, sq:getX(), sq:getY(), sq:getZ(),
                     R.SCAN_RADIUS, 1, function(s)
        local objs = s and s.getObjects and s:getObjects()
        if not objs then return end
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local info = o and P.describe(o)
            if info then
                local d = P.data(o) or {}
                local entry = R.partEntry(o, info, d, s, playerObj)
                counts[entry.what] = (counts[entry.what] or 0) + 1
                found[#found + 1] = entry
            end
        end
    end)
    if not ok then return "scan failed" end
    if #found == 0 then
        return "no Off-Grid objects within " .. R.SCAN_RADIUS .. " tiles"
    end
    return { radius = R.SCAN_RADIUS, byType = counts, objects = found }
end

--- The reach the engine lights, and whether LG Extended Electricity has taken
--  it over (OG_Interop). An empty LOADS page on a server running LGEE is this,
--  and nothing else in the report would show it.
function R.generator()
    local I = OffGrid.Interop
    if not (I and I.generatorRange and I.lgeeTakeover) then return "OG_Interop not loaded" end
    -- Explicit branches, not `ok and v or msg`: lgeeTakeover's usual answer is
    -- false, and that idiom would print it as a failure.
    local out = {}
    local ok, range = pcall(I.generatorRange)
    if ok then out.range = range else out.range = "failed: " .. tostring(range) end
    local ok2, takeover = pcall(I.lgeeTakeover)
    if ok2 then out.lgeeTakeover = takeover else out.lgeeTakeover = "failed: " .. tostring(takeover) end
    return out
end

--- Everything, assembled. Returned as a TABLE: Error Magnifier renders one
--  with its own tableToString, which formats better than anything built here.
function R.build()
    local player = getPlayer()
    return {
        modVersion   = R.VERSION,
        boot         = R.boot(),
        almanacRead  = player and OffGrid.Almanac.knows(player) or false,
        sandbox      = R.sandbox(),
        generator    = R.generator(),
        environment  = R.env(),
        nearbyParts  = R.parts(player),
        multiplayer  = isClient() and true or false,
    }
end

--- Register, if and only if Error Magnifier is here.
--
--  Wrapped in pcall as a belt-and-braces measure: this runs inside OnGameStart,
--  and an error thrown from an event handler is not this mod's to inflict on
--  whatever else is registered on the same event.
function R.attach()
    if not R.magnifierActive() then return end
    local ok, em = pcall(require, "errorMagnifier_Main")
    if not ok or type(em) ~= "table" then return end
    if type(em.registerDebugReport) ~= "function" then return end
    pcall(em.registerDebugReport, R.MOD_ID, R.build, R.DISPLAY)
end

Events.OnGameStart.Add(R.attach)

return R

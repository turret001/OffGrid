--[[ OffGrid -- turning the live world into the plain table the model wants.

     OG_Model is deliberately engine-free so it can be tested headlessly. This
     is the one file allowed to know about ClimateManager and GameTime, and it
     exists so that everything downstream of it is testable numbers.

     Two things here are not obvious:

     * The engine has no per-square sunlight. There is exactly one global 0..1
       scalar, ClimateManager:getDayLightStrength(), and one per-square gate,
       IsoGridSquare:isOutside(). That pairing IS the vanilla idiom -- the
       foraging system does the same thing to decide how dark a search is.

     * The mod computes its own solar elevation rather than reading daylight
       as an intensity (getDayLightStrength() is a broad plateau, so as the
       sun it would give a flat noon and no seasonal strength), but it takes
       the TIME of the sun from the engine. The sky is centred on
       ErosionSeason's high noon (12:30 in December, about 14:30 in June),
       with dawn and dusk half the day's length either side. So the clock is
       mapped onto solar time: engine dawn is the model's sunrise, engine noon
       its noon, engine dusk its sunset (OG_Model.solarHour).
       getDayLightStrength() stays a gate, so nothing generates in a world
       the engine says is dark; the map is what makes the arrays generate
       while the engine shows the sun.
]]

require "OffGrid/OG_Model"
require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Env = OffGrid.Env or {}
local E = OffGrid.Env
local M = OffGrid.Model
local P = OffGrid.Parts

--- Today's date: year, 0-based month (GameTime's own convention) and day of
--  the month. The one place the mod reads the calendar, so every date it
--  works with agrees. In the engine getGameTime() is never nil (it hands back
--  the static GameTime.instance, LuaManager.java:4929); the nil branch is for
--  headless fixtures, and answers with the game's default start, 9 July 1993.
local function today()
    local gt = getGameTime()
    if not gt then return 1993, 6, 9 end
    return gt:getYear(), gt:getMonth(), gt:getDayPlusOne()
end

--- Read the world into the environment table OG_Model.step expects.
--  Every field degrades to a sane default if the engine hands back nil,
--  because a nil arithmetic error inside a per-hour tick would take the
--  whole system down silently.
function E.read()
    local gt = getGameTime()
    local cm = getClimateManager()

    local hour = gt and gt:getTimeOfDay() or 12.0
    local year, month0, day = today()
    local month = month0 + 1            -- OG_Model.dayOfYear wants it 1-based

    local env = {
        hour = hour,
        month = month,
        day = day,
        dayOfYear = M.dayOfYear(month, day),
        cloud = 0, fog = 0, precipitation = 0,
        temperature = 18, groundSnow = 0, daylight = nil,
        thunder = false, wind = 0,
    }
    env.noon, env.dayHours, env.sky = E.skyDay(year, month0, day)

    if cm then
        env.cloud = cm:getCloudIntensity() or 0
        env.fog = cm:getFogIntensity() or 0
        env.precipitation = cm:getPrecipitationIntensity() or 0
        env.temperature = cm:getTemperature() or 18
        env.groundSnow = cm:getSnowFracNow() or 0
        env.daylight = cm:getDayLightStrength()
        env.snowing = cm:getPrecipitationIsSnow() and env.precipitation > 0
        env.thunder = cm:getIsThunderStorming() or false
        env.wind = cm:getWindIntensity() or 0
        env.season = cm:getSeasonName()
    end
    return env
end

--- Whether a square can see the sky. An array under a roof makes nothing.
function E.isSunlit(square)
    if not square then return false end
    if square.isOutside then return square:isOutside() end
    return true
end

-- A real, finite number (OG_Model.finite): the engine's own dawn and dusk go
-- NaN for a latitude past the polar circle in erosion.ini.
local finite = M.finite

--- The world's season settings: latitude, configured noon, and the day-night
--  cycle ("day", "night" or nil). Read from the live season, because a world
--  can change them: an edited erosion.ini (an MP client is handed the
--  server's, ErosionMain.java:287-291), or vanilla's Winter is Coming, which
--  re-inits the season at 50 N (WinterIsComing.lua:27-38). Each is nil when
--  the engine does not answer, and OG_Model.engineDay takes the default.
--
--  The cycle is the sandbox's DayNightCycle, which the season and GameTime
--  both read straight from SandboxOptions (ErosionSeason.java:472-478,
--  GameTime.java:1314-1320), so GameTime answers when the season chain does
--  not. Without it a patch that dropped a getter on the way to the season
--  would lose Endless Night, and a catch-up replay, which has no daylight
--  gate, would charge banks under a sun that never rose.
function E.skyParams()
    local season = P.try(getClimateManager(), "getSeason")
    local lat, noon = P.try(season, "getLat"), P.try(season, "getHighNoon")
    local function endless(name)
        local v = P.try(season, name)
        if v == nil then v = P.try(getGameTime(), name) end
        return v == true
    end
    local cycle = nil
    if endless("isEndlessNight") then
        cycle = "night"
    elseif endless("isEndlessDay") then
        cycle = "day"
    end
    return finite(lat) and lat or nil, finite(noon) and noon or nil, cycle
end

--- The engine's day for a date: high noon and sunrise-to-sunset length in
--  clock hours, and where they came from. `m0` is 0-based, `d` 1-based.
--
--  "cycle" under Endless Day or Endless Night, on every date: no day, or 24
--  hours round the configured noon (OG_Model.engineDay). There the sky's
--  light is decided by the live cycle alone (ClimateValues.java:288-305), and
--  the DayInfo cannot be trusted for the timing: it is recomputed only on a
--  date change (ClimateManager.java:1717-1752) while a server applies sandbox
--  options live (GameServer.java:1690-1694), so after an admin changes the
--  cycle it holds the old cycle's day until midnight, and Endless Day never
--  assigns high noon (ErosionSeason.java:427-435), so its noon is whatever
--  the last other day left there until a restart clones a fresh season.
--
--  "engine" when ClimateManager's current DayInfo IS that date and holds a
--  Normal-cycle day: its season is what the visible sky is drawn from
--  (ClimateValues.java:239-241), so that is the exact sky, whatever a future
--  patch does to the formula. A Normal day is strictly between 0 and 24
--  hours: it is a cosine blend of the two solstice days (ErosionSeason.java:
--  83-84, 419-424), and each is strictly inside that range at every whole-
--  degree latitude it is defined for (the latitude is an int, line 19; 66 N
--  gives 22.2 h, 67 N is NaN). So a 0 or a 24 is an Endless cycle's day left
--  over from before a switch to Normal.
--
--  "calendar" otherwise, from OG_Model.engineDay with the live season
--  settings: any other date, the first frame before the climate manager has
--  built its day, the frame at midnight before it rolls, a leftover Endless
--  day, and a season answering NaN. nil, nil, nil only where the engine's
--  formula is itself undefined, and the model then keeps its own clock.
--
--  The DayInfo and not getSeason()'s date-less answer, because the season
--  ErosionMain holds is dated a day early (it uses the 0-based getDay,
--  ErosionMain.java:125-130) and getSeason() falls back to it.
function E.skyDay(y, m0, d)
    local lat, cfgNoon, cycle = E.skyParams()
    if cycle then
        local noon, len = M.engineDay(y, m0 + 1, d, lat, cfgNoon, cycle)
        return noon, len, "cycle"
    end
    local day = P.try(getClimateManager(), "getCurrentDay")
    if day and P.try(day, "getYear") == y and P.try(day, "getMonth") == m0
            and P.try(day, "getDay") == d then
        local season = P.try(day, "getSeason")
        local noon = P.try(season, "getDayHighNoon")
        local len = P.try(season, "getDaylight")
        if finite(noon) and finite(len) and len > 0 and len < 24 then
            return noon, len, "engine"
        end
    end
    local noon, len = M.engineDay(y, m0 + 1, d, lat, cfgNoon)
    if noon then return noon, len, "calendar" end
    return nil, nil, nil
end

--- The world-clock hour, as a float, used for catch-up across chunk unloads.
function E.worldHours()
    local gt = getGameTime()
    if not gt then return 0 end
    return gt:getWorldAgeHours() or 0
end


-------------------------------------------------------------------- almanac

-- One bit per kind of weather a forecast day can carry. A DayForecast records
-- only THAT a stage happened, never how hard, so these are flags rather than
-- intensities and OG_Model.forecastPrecip is what turns them into a number.
E.SKY_STORM    = 1
E.SKY_BLIZZARD = 2
E.SKY_TROPICAL = 4
E.SKY_RAIN     = 8
E.SKY_SNOW     = 16

local function hasFlag(w, bit)
    return math.floor((w or 0) / bit) % 2 >= 1
end

--- One number per calendar day that only ever goes up.
--
--  Deliberately not getWorldAgeHours()/24. That clock's epoch is 07:00 on the
--  first night (GameTime.java:904-913), so its days run 07:00 to 07:00 while
--  the engine rolls its forecast ring at the calendar day change
--  (ClimateManager.java:835). Anchoring the almanac to the wrong boundary
--  would shrink the horizon seven hours out of step with the data behind it.
--  Deliberately not getDaysSurvived() either: that one ends in `days % 30`
--  (GameTime.java:229) and silently wraps.
--
--  Counted in pure arithmetic on the Gregorian calendar, days since
--  1970-01-01. It used to go through the engine's Calendar, which works in
--  the HOST'S time zone: the noon it set was not noon everywhere, so on a host
--  far enough from UTC the count repeated or skipped a day, and a client in
--  another zone disagreed with its server about which day a reading was taken.
--  For every host between UTC-12 and UTC+12 this returns exactly what the
--  Calendar route did, so the day numbers already stored in saves (the
--  almanac reading, the daily ledger) stay comparable. (The arithmetic is
--  OG_Model.daysFromCivil, shared with the engine-day port.)
function E.dayIndex()
    local y, m, d = today()
    return M.daysFromCivil(y, m + 1, d)
end

--- The calendar date `offset` days from today, as year, 0-based month, day.
function E.dateAt(offset)
    local y, m, d = today()
    local yy, mm, dd = M.civilFromDays(M.daysFromCivil(y, m + 1, d)
                                       + math.floor(offset or 0))
    return yy, mm - 1, dd
end

--- Today's day of the year, 1..365, on the mod's own fixed-length calendar.
function E.dayOfYear()
    local _, m, d = today()
    return M.dayOfYear(m + 1, d)
end

--- The engine's own month name, so the almanac reads in the player's language
--  without the mod shipping twelve more strings (Farming.json:136-147).
function E.monthName(month0)
    return getText("Farming_Month_" .. ((month0 or 0) + 1))
end

--- Snapshot the engine's forecast ring into a plain, saveable table.
--
--  ONLY CALL THIS ON THE AUTHORITY. The ring is populated at world load on
--  every side, because IsoWorld's call to ClimateManager.init is ungated
--  (IsoWorld.java:2024), but the day-change roll that keeps it pointing at
--  today runs only when the process is not a multiplayer client
--  (ClimateManager.java:835). So a client's copy stops advancing the moment it
--  finishes loading and drifts a day per day, and it drifts INVISIBLY: the
--  numbers stay perfectly well-formed and are simply for the wrong dates.
--
--  Taking the snapshot where the ring is true is not a workaround for that.
--  The feature is a reading taken at a moment, so a copy handed to the player
--  is exactly what it should be.
function E.readForecast(span)
    span = span or M.FORECAST_SPAN
    local cm = getClimateManager()
    if not cm or not cm.getClimateForecaster then return nil end
    local fc = cm:getClimateForecaster()
    if not fc then return nil end

    local out = {}
    for i = 0, span do
        -- getForecast(offset) indexes a 40-slot ring with today at 10, so it
        -- answers for -10..+29 and returns nil past either end rather than
        -- throwing (ClimateForecaster.java:23-27).
        local day = fc:getForecast(i)
        if not day then break end
        local cloud = day:getCloudiness()
        local temp = day:getTemperature()
        local w = 0
        if day:isHasStorm() then w = w + E.SKY_STORM end
        if day:isHasBlizzard() then w = w + E.SKY_BLIZZARD end
        if day:isHasTropicalStorm() then w = w + E.SKY_TROPICAL end
        if day:isHasHeavyRain() then w = w + E.SKY_RAIN end
        if day:isChanceOnSnow() then w = w + E.SKY_SNOW end
        out[#out + 1] = {
            -- The DAY mean, not the total: night cloud makes no difference to
            -- a solar panel and averaging it in would flatten the one number
            -- the whole readout turns on.
            c = M.round(M.clamp(cloud and cloud:getDayMean() or 0, 0, 1), 3),
            g = day:isHasFog() and M.round(M.clamp(day:getFogStrength() or 0, 0, 1), 3) or 0,
            t = M.round(temp and temp:getDayMean() or 15, 1),
            n = M.round(temp and temp:getTotalMin() or 10, 1),
            x = M.round(temp and temp:getTotalMax() or 20, 1),
            w = w,
        }
    end
    if #out == 0 then return nil end
    return out
end

--- Turn one stored record back into the sky table OG_Model.forecastEnv wants.
--  `offset` is the day's distance from today, which gives it that date's
--  engine day: a record stores weather, never the sun's timing.
function E.skyOf(rec, dayOfYear, offset)
    if not rec then return nil end
    local noon, dayHours = E.skyDay(E.dateAt(offset or 0))
    return {
        dayOfYear = dayOfYear,
        noon = noon,
        dayHours = dayHours,
        cloud = rec.c or 0,
        fog = rec.g or 0,
        temperature = rec.t or 15,
        tempMin = rec.n,
        tempMax = rec.x,
        storm = hasFlag(rec.w, E.SKY_STORM),
        blizzard = hasFlag(rec.w, E.SKY_BLIZZARD),
        tropical = hasFlag(rec.w, E.SKY_TROPICAL),
        rain = hasFlag(rec.w, E.SKY_RAIN),
        snow = hasFlag(rec.w, E.SKY_SNOW),
    }
end

return E

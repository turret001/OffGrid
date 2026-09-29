--[[ OffGrid -- the physics.

     Every function in this file is pure: numbers in, numbers out, no engine
     calls anywhere. That is deliberate. It means the whole simulation can be
     run and asserted headlessly under a plain Lua 5.1 interpreter, which is
     how the test suite in tests/ checks it, and it keeps the parts that can
     silently break (world access, multiplayer, persistence) out of the parts
     that have to be numerically right.

     The solar model is real geodesy rather than a fudge factor on a clock:
     declination and hour angle give the sun's position over Knox County, the
     plane-of-array formula projects that onto a tilted panel, and Meinel air
     mass attenuates the beam near the horizon. That is what makes a January
     noon weaker than a July dawn-plus-four, and what makes pointing an array
     north actually cost you something.

     The geometry runs on solar time; WHEN the sun is up is the engine's. The
     game's sky is centred on a high noon that drifts with the season, and
     M.solarHour lines the model's day up with it (see "the engine's sky").
]]

OffGrid = OffGrid or {}
OffGrid.Model = OffGrid.Model or {}
local M = OffGrid.Model

local floor, sin, cos, asin, acos, sqrt = math.floor, math.sin, math.cos, math.asin, math.acos, math.sqrt
local pi, max, min, abs = math.pi, math.max, math.min, math.abs
local RAD = pi / 180

-------------------------------------------------------------------- constants

-- Knox County stands in for Muldraugh/West Point, KY.
M.LATITUDE      = 37.9
M.PANEL_TILT    = 32          -- degrees off horizontal; a fixed winter-biased frame
-- Reference values for the standard grade. ARRAY_SPEC below carries the real
-- per-grade numbers; these remain as the fallbacks an untiered caller gets.
M.PANEL_AREA    = 1.64        -- m^2 of cell per array module
M.PANEL_EFF     = 0.175       -- module efficiency at STC
M.TEMP_COEFF    = -0.0040     -- fraction of rated output lost per degree over 25C
M.NOCT_RISE     = 0.028       -- cell temp rise per W/m^2 of irradiance
M.INVERTER_EFF  = 0.93
M.CHARGE_EFF    = 0.86        -- energy kept when pushing into lead-acid
M.SOLAR_CONST   = 1100        -- clear-sky direct normal at zero air mass, W/m^2

-- Surface azimuth in degrees away from due south, positive toward the west.
-- The four facings are the ones a placed tile can have.
M.FACING_AZIMUTH = { S = 0, W = 90, N = 180, E = -90 }

M.DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

------------------------------------------------------------ tiers and mounts

--- What each grade of panel is actually made of.
--  `panels` is how many modules the object represents, so a premium array is
--  physically bigger as well as better per square metre. `wear` scales how
--  fast condition falls, `soil` how fast dust builds.
M.ARRAY_SPEC = {
    makeshift = { area = 1.30, eff = 0.135, temp = -0.0050,
                  panels = 2, soil = 1.6, wear = 1.7 },
    standard  = { area = 1.64, eff = 0.175, temp = -0.0040,
                  panels = 2, soil = 1.0, wear = 1.0 },
    premium   = { area = 1.80, eff = 0.215, temp = -0.0029,
                  panels = 3, soil = 0.7, wear = 0.5 },
}

--- Mount decides the tilt, and tilt decides the year.
--  A 32-degree ground frame is aimed at the winter sun and sheds snow. A roof
--  panel lying at 6 degrees catches more of a high summer sun, catches less of
--  everything else, and holds every flake that lands on it.
M.MOUNT = {
    ground = { tilt = 32.0, snowGain = 1.0, snowShed = 1.0, cellShare = 1.0 },
    flat   = { tilt = 6.0,  snowGain = 1.7, snowShed = 0.30, cellShare = 1.0 },
    wall   = { tilt = 0.0,  snowGain = 0.0, snowShed = 1.0, cellShare = 0.5 },
}

--- Battery grades. `wh` is per cell; `dod` is the depth of discharge the
--  chemistry tolerates before it starts losing capacity for good.
M.BANK_SPEC = {
    makeshift = { cells = 3, wh = 560, eff = 0.72, cold = 0.42,
                  dod = 0.30, decay = 0.022 },
    standard  = { cells = 6, wh = 720, eff = 0.86, cold = 0.55,
                  dod = 0.15, decay = 0.010 },
    premium   = { cells = 8, wh = 920, eff = 0.94, cold = 0.74,
                  dod = 0.08, decay = 0.0035 },
}

--- Controller grades. An MPPT unit tracks the panel's maximum power point,
--  which is a real thing worth a real 8-12% over a dumb PWM controller.
M.CTRL_SPEC = {
    basic = { eff = 0.93, harvest = 1.00 },
    mppt  = { eff = 0.965, harvest = 1.10 },
}

--- REALISTIC MODE: 1993 panels, from Alwar on the suggestions board
--  (2026-09-25), taken as he gave them. A 1993 module was 129.3 x 33 cm, so a
--  32-degree frame holds three of them, 0.43 m2 each; top cells of the day
--  ran 13-14 per cent, ordinary panels 10-11, and makeshift is salvaged or
--  degraded cells soldered together. Soiling, wear and the temperature
--  coefficients are the ordinary figures. A standard frame makes about a
--  quarter of what it does otherwise (142 W against 574 W in full sun).
M.ARRAY_SPEC_1993 = {
    makeshift = { area = 0.43, eff = 0.05, temp = -0.0050,
                  panels = 3, soil = 1.6, wear = 1.7 },
    standard  = { area = 0.43, eff = 0.11, temp = -0.0040,
                  panels = 3, soil = 1.0, wear = 1.0 },
    premium   = { area = 0.43, eff = 0.14, temp = -0.0029,
                  panels = 3, soil = 0.7, wear = 0.5 },
}

--- Is Realistic Mode on? The sandbox answers it: OG_Parts, the one file that
--  reads SandboxVars, replaces this. Off until then, so the model stays pure
--  for every test that loads it alone.
M.isRealistic = M.isRealistic or function() return false end

--- A frame's spec in the ordinary mode, whatever mode is running. This is
--  the one a frame's stored panel count is written in.
function M.baseArraySpec(tier)
    return M.ARRAY_SPEC[tier or "standard"] or M.ARRAY_SPEC.standard
end

--- A frame's spec in the mode that is running.
function M.arraySpec(tier)
    if M.isRealistic() then
        return M.ARRAY_SPEC_1993[tier or "standard"] or M.ARRAY_SPEC_1993.standard
    end
    return M.baseArraySpec(tier)
end

--- How many panels a frame carries in the mode that is running. The count a
--  frame stores (d.panels, at placement) is always in the ordinary mode's
--  terms, so switching the mode changes what this reads and never what is
--  written into the world.
function M.framePanels(stored, tier)
    local base = M.baseArraySpec(tier)
    local n = stored or base.panels
    if not M.isRealistic() then return n end
    return n * M.arraySpec(tier).panels / base.panels
end

function M.bankSpec(tier)
    return M.BANK_SPEC[tier or "standard"] or M.BANK_SPEC.standard
end

function M.ctrlSpec(tier)
    return M.CTRL_SPEC[tier or "basic"] or M.CTRL_SPEC.basic
end

function M.mountSpec(mount)
    return M.MOUNT[mount or "ground"] or M.MOUNT.ground
end

--- How many car batteries a bank of this grade and mount holds.
function M.bankCells(tier, mount)
    return math.floor(M.bankSpec(tier).cells * M.mountSpec(mount).cellShare + 0.5)
end

-------------------------------------------------------------------- utilities

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
M.clamp = clamp

function M.round(v, places)
    local m = 10 ^ (places or 0)
    return floor(v * m + 0.5) / m
end

--- A real, finite number: not nil, not NaN, not infinite. The engine's own
--  dawn and dusk go NaN for a latitude past the polar circle in erosion.ini,
--  and a NaN written into ModData stays there through every later sum.
function M.finite(v)
    return type(v) == "number" and v == v and v - v == 0
end

--- Day of year, 1..365. `month` and `day` are 1-based.
function M.dayOfYear(month, day)
    local n = 0
    local mo = clamp(floor(month or 1), 1, 12)
    for i = 1, mo - 1 do n = n + M.DAYS_IN_MONTH[i] end
    return n + clamp(floor(day or 1), 1, 31)
end

------------------------------------------------------------------ sun position

--- Solar declination in degrees for a day of the year (Cooper's equation).
function M.declination(dayOfYear)
    return 23.44 * sin(2 * pi * (284 + dayOfYear) / 365.0)
end

--- Hour angle in degrees for a SOLAR hour (noon = 12): solar noon is 0,
--  morning negative, afternoon positive. Every `hour` in this section is solar
--  time; clock hours go through M.solarHour first.
function M.hourAngle(hour)
    return 15.0 * (hour - 12.0)
end

--- Sine of the sun's altitude above the horizon. Negative means below it.
function M.sinAltitude(dayOfYear, hour, lat)
    lat = lat or M.LATITUDE
    local d = M.declination(dayOfYear) * RAD
    local h = M.hourAngle(hour) * RAD
    local l = lat * RAD
    return sin(l) * sin(d) + cos(l) * cos(d) * cos(h)
end

--- Sun altitude in degrees.
function M.altitude(dayOfYear, hour, lat)
    return asin(clamp(M.sinAltitude(dayOfYear, hour, lat), -1, 1)) / RAD
end

--- Hour of sunrise and sunset for the day, in decimal hours.
function M.dayLength(dayOfYear, lat)
    lat = lat or M.LATITUDE
    local d = M.declination(dayOfYear) * RAD
    local l = lat * RAD
    local c = -math.tan(l) * math.tan(d)
    if c <= -1 then return 0.0, 24.0, 24.0 end        -- midnight sun
    if c >= 1 then return 12.0, 12.0, 0.0 end         -- polar night
    local ha = acos(c) / RAD / 15.0
    return 12 - ha, 12 + ha, 2 * ha
end

--- Cosine of the angle between the sun and a tilted panel's normal.
--  Standard plane-of-array incidence; `azimuth` is degrees from south, +west.
function M.cosIncidence(dayOfYear, hour, azimuth, tilt, lat)
    lat = lat or M.LATITUDE
    tilt = tilt or M.PANEL_TILT
    local d = M.declination(dayOfYear) * RAD
    local h = M.hourAngle(hour) * RAD
    local l = lat * RAD
    local b = tilt * RAD
    local g = (azimuth or 0) * RAD
    return sin(d) * sin(l) * cos(b)
         - sin(d) * cos(l) * sin(b) * cos(g)
         + cos(d) * cos(l) * cos(b) * cos(h)
         + cos(d) * sin(l) * sin(b) * cos(g) * cos(h)
         + cos(d) * sin(b) * sin(g) * sin(h)
end

--- Meinel air-mass attenuation of the direct beam, 0..1.
function M.beamAttenuation(sinAlt)
    if sinAlt <= 0.005 then return 0.0 end
    local airmass = 1.0 / sinAlt
    if airmass > 38 then return 0.0 end
    return 0.7 ^ (airmass ^ 0.678)
end

--------------------------------------------------------------- the engine's sky

--  The geometry above puts solar noon at 12. The game's sky does not: its
--  ErosionSeason centres the day on a high noon that drifts from 12:30 at the
--  winter solstice to 14:30 at the summer one, with dawn and dusk half the
--  day's length either side (ErosionSeason.java:436-440). Taken at face value
--  the model stopped an array at 19:15 in July under a bright evening sky and
--  started it at 04:45 in the dark. What follows lines the two clocks up, and
--  stays pure: OG_Env reads the live day, and these answer for the rest.

-- The season defaults (ErosionConfig.java:328-334). A world's erosion.ini
-- can change both, which is why OG_Env reads them from the live season.
M.SKY_LATITUDE    = 38
M.SKY_NOON        = 12.5
-- Hard-coded in ErosionSeason.init, not configurable (ErosionSeason.java:80,
-- 83-84).
M.SKY_SUMMER_TILT = 2.0
M.SKY_OBLIQUITY   = 23.44
-- Hours until the sun comes back when it never will (Endless Night): the same
-- large finite number M.coldHours answers with, so a caller can format it.
M.NO_DAWN         = 999

--- Hours wrapped into [0, 24). Floor-based on purpose: Kahlua's % truncates
--  toward zero (KahluaThread.java:1061-1067), so -1 % 24 is -1 in the game
--  and 23 under the Lua 5.1 the headless suites run. tests/test_kahlua.py
--  runs the sun clock in the game's own VM because lupa cannot see that.
function M.wrapHours(h)
    return h - floor(h / 24) * 24
end

--- Days since 1970-01-01 for a Gregorian date, in pure arithmetic, so no
--  host time zone can move it. `m` is 1..12. (Howard Hinnant's
--  days_from_civil.) OG_Env's day index and the engine-day port share it.
function M.daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- The inverse: year, month (1..12) and day for a day count.
function M.civilFromDays(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
                            - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

--- The engine's day for a calendar date: its high noon and its sunrise-to-
--  sunset length, both in clock hours. A port of ErosionSeason.init and
--  setDaylightData (ErosionSeason.java:69-90, 399-441), for the dates the
--  live engine is not looking at: the almanac's days ahead and a catch-up
--  replay's days behind.
--
--  `m` is 1..12. `lat` and `noon` are the world's season settings, nil for
--  the defaults. `cycle` is nil, "day" or "night" for the sandbox's Endless
--  Day and Endless Night, which the engine applies after the season maths:
--  night zeroes everything, day is 24 hours around the configured noon.
--  Returns nil where the engine's own dawn and dusk are NaN, a latitude whose
--  summer sun never sets (|tan lat * tan 23.44| >= 1).
--
--  The engine counts the days in the host's time zone (dayDiff truncates a
--  span that daylight saving made an hour short), so on such a host a date
--  can differ from this by up to about a minute of dawn. A UTC host matches
--  it exactly.
function M.engineDay(y, m, d, lat, noon, cycle)
    lat = lat or M.SKY_LATITUDE
    noon = noon or M.SKY_NOON
    if cycle == "night" then return 0, 0 end
    if cycle == "day" then return noon, 24 end
    local t = math.tan(lat * RAD) * math.tan(M.SKY_OBLIQUITY * RAD)
    if t >= 1 or t <= -1 then return nil end
    local su = 2 * (acos(-t) / RAD) / 15            -- summer solstice day
    local wi = 2 * (acos(t) / RAD) / 15             -- winter solstice day
    -- Solstices on 22 June and 22 December. From June's up to (not including)
    -- December's the days shorten; otherwise they lengthen toward June.
    local D = M.daysFromCivil(y, m, d)
    local win, sum = M.daysFromCivil(y, 12, 22), M.daysFromCivil(y, 6, 22)
    local s0, s1, lengthening
    if D < win and D >= sum then
        s0, s1, lengthening = sum, win, false
    elseif D >= win then
        s0, s1, lengthening = win, M.daysFromCivil(y + 1, 6, 22), true
    else
        s0, s1, lengthening = M.daysFromCivil(y - 1, 12, 22), sum, true
    end
    local p = (D - s0) / (s1 - s0)
    local t2 = (1 - cos(p * pi)) / 2                -- ErosionSeason.clerp
    if lengthening then
        return noon + M.SKY_SUMMER_TILT * p, wi * (1 - t2) + su * t2
    end
    return noon + M.SKY_SUMMER_TILT * (1 - p), su * (1 - t2) + wi * t2
end

--- The solar hour (noon = 12) the geometry should use at clock hour `hour`,
--  given the engine's day: its high noon and its length in hours.
--
--  Engine dawn maps to the model's sunrise, engine noon to 12 and engine dusk
--  to the model's sunset, linearly; the night maps linearly from sunset to
--  the next sunrise. The engine's dawn and dusk are symmetric about its noon
--  by construction (ErosionSeason.java:437-439), so the day is one straight
--  piece with no kink at noon. Continuous and increasing (mod 24) whenever
--  0 < dayHours < 24; 24 is all day, 0 all night.
--
--  So Knox County's sun keeps its own path and strength, and only WHEN it
--  happens follows the sky: an array wakes at the engine's dawn and stops at
--  its dusk, and a day's energy scales by the engine's day length over the
--  model's (within about one per cent on the default settings).
--
--  `noon` or `dayHours` nil means no engine day is known: the model's own
--  clock, noon at 12:00.
function M.solarHour(hour, dayOfYear, noon, dayHours, lat)
    if noon == nil or dayHours == nil then return hour end
    local _, set, len = M.dayLength(dayOfYear, lat)
    local half = clamp(dayHours, 0, 24) / 2
    local x = M.wrapHours(hour - noon + 12) - 12            -- -12 <= x < 12
    if half > 0 and x >= -half and x <= half then
        return M.wrapHours(12 + x * (len / 2) / half)
    end
    local y = (x < -half) and (x + 24) or x                -- half < y < 24 - half
    return M.wrapHours(set + (y - half) * (24 - len) / (24 - 2 * half))
end

--- How much darkness is left before the sun comes back, in hours.
--
--  This is what the cold chain is measured against: the bank does not have to
--  last forever, it has to last until dawn. After dusk that is the run to
--  tomorrow's dawn; before dawn it is the remainder of tonight; and in
--  daylight it is the coming night in full, because a player checking the
--  monitor at noon is asking whether tonight is covered.
--
--  Dawn is the engine's when the env carries its day (OG_Env.read), the
--  model's sunrise when it does not, and tonight is as long as today's night.
function M.darkHoursLeft(env)
    local h = env.hour or 12
    local dawn, len
    if env.noon ~= nil and env.dayHours ~= nil then
        len = clamp(env.dayHours, 0, 24)
        dawn = env.noon - len / 2
    else
        local rise, _, l = M.dayLength(env.dayOfYear or 1, env.latitude)
        dawn, len = rise, l
    end
    if len <= 0 then return M.NO_DAWN end
    local since = M.wrapHours(h - dawn)
    if since < len then return 24 - len end
    return 24 - since
end

------------------------------------------------------------------- irradiance

--- Plane-of-array irradiance in W/m^2 on a panel, given sky conditions.
--  `sky` carries cloud, fog and precipitation, each 0..1.
function M.planeIrradiance(dayOfYear, hour, facing, sky, lat, tilt)
    tilt = tilt or M.PANEL_TILT
    local sinAlt = M.sinAltitude(dayOfYear, hour, lat)
    if sinAlt <= 0 then return 0, 0, 0 end

    local az = M.FACING_AZIMUTH[facing]
    if az == nil then az = 0 end

    local dni = M.SOLAR_CONST * M.beamAttenuation(sinAlt)
    local cosT = max(0, M.cosIncidence(dayOfYear, hour, az, tilt, lat))

    local cloud = clamp((sky and sky.cloud) or 0, 0, 1)
    local fog   = clamp((sky and sky.fog) or 0, 0, 1)
    local precip = clamp((sky and sky.precipitation) or 0, 0, 1)

    -- Thick cloud does not delete the energy, it scatters the beam into the
    -- diffuse sky. That is why an overcast array still limps along instead of
    -- flatlining, and it is the single most important thing to get right for
    -- how the mod feels in November.
    local beamFrac = clamp(1.0 - 1.05 * cloud - 0.55 * fog - 0.45 * precip, 0, 1)
    local beam = dni * cosT * beamFrac

    -- 0.12 is tuned, not guessed: it is what puts a fully overcast noon at
    -- roughly a fifth of clear-sky global irradiance, which is where real
    -- overcast measurements sit (about 100-200 W/m^2 against 1000).
    local diffuseHoriz = 0.10 * M.SOLAR_CONST * sinAlt
                       + 0.12 * dni * sinAlt * (cloud * (1 - 0.45 * precip) + 0.6 * fog)
    local skyView = (1 + cos(tilt * RAD)) * 0.5
    local diffuse = diffuseHoriz * skyView

    -- ground-reflected, small but not nothing, and it is what makes a snowy
    -- field slightly better than a muddy one once the panel itself is clear
    local albedo = (sky and sky.groundSnow and (0.20 + 0.45 * sky.groundSnow)) or 0.20
    local ground = (beam + diffuseHoriz) * albedo * (1 - cos(tilt * RAD)) * 0.5

    return beam + diffuse + ground, beam, diffuse + ground
end

--------------------------------------------------------------- array output

--- Cell temperature in C from air temperature and irradiance.
function M.cellTemperature(airC, irradiance)
    return (airC or 20) + M.NOCT_RISE * (irradiance or 0)
end

--- Derate factor from cell temperature. Hot panels make less power, and a
--  cheap panel loses more per degree than a good one.
function M.temperatureDerate(cellC, coeff)
    return clamp(1.0 + (coeff or M.TEMP_COEFF) * ((cellC or 25) - 25.0),
                 0.50, 1.18)
end

--- DC watts from one array object.
--  `array`  = { facing, mount, tier, panels, condition (0..100),
--               soiling (0..1), snow (0..1) }
--  `env`    = { dayOfYear, hour, noon, dayHours, cloud, fog, precipitation,
--               temperature, groundSnow, daylight }
--  `hour` is the clock; `noon` and `dayHours` are the engine's day, which
--  M.solarHour turns the clock into the sun's time with.
function M.arrayOutput(array, env)
    local spec = M.arraySpec(array.tier)
    local mount = M.mountSpec(array.mount)
    local panels = max(0, M.framePanels(array.panels, array.tier))
    if panels == 0 then return 0, 0 end

    local tilt = array.tilt or mount.tilt
    local sun = M.solarHour(env.hour, env.dayOfYear, env.noon, env.dayHours,
                            env.latitude)
    local poa = M.planeIrradiance(
        env.dayOfYear, sun, array.facing, env, env.latitude, tilt)
    if poa <= 0 then return 0, 0 end

    -- The engine's own daylight value is the authority on whether it is dark.
    -- Trusting the geometry alone would let an array make power through an
    -- eclipse-black sandbox setting or an endless-night scenario.
    if env.daylight ~= nil then
        if env.daylight <= 0.02 then return 0, poa end
        poa = poa * clamp(env.daylight * 1.25, 0, 1)
    end

    local snow = clamp(array.snow or 0, 0, 1)
    if snow >= 0.98 then return 0, poa end

    local soiling = clamp(array.soiling or 0, 0, 1)
    local condition = clamp((array.condition or 100) / 100, 0, 1)

    local cellC = M.cellTemperature(env.temperature, poa)
    local watts = poa * spec.area * spec.eff * panels
    watts = watts * (1 - snow)
    watts = watts * (1 - 0.40 * soiling)
    watts = watts * (0.25 + 0.75 * condition)
    watts = watts * M.temperatureDerate(cellC, spec.temp)
    -- sandbox scaling, applied last so it multiplies the finished figure and
    -- never distorts the physics that produced it
    watts = watts * (env.outputScale or 1)
    return max(0, watts), poa
end

------------------------------------------------------------------ solar lamps

--- The standalone lamps (2026-09-24). Each has its own panel and battery and
--  is never wired. panelW is the module at 1000 W/m^2, wh the battery, drawW
--  what the lamp uses while lit, tilt the panel's. Sized so a clear summer
--  day fills the battery and a full one lasts a long night: the garden
--  light's 30 Wh runs 15 hours at 2 W, the street light's 480 Wh 16 hours at
--  30 W. A dull week runs them down, as it does a real one.
M.LAMP_SPEC = {
    garden = { panelW = 6,   wh = 30,  drawW = 2,  tilt = 0 },
    street = { panelW = 110, wh = 480, drawW = 30, tilt = 30 },
}
-- Dusk and dawn are the town's street lights' moments. Vanilla lights a street
-- light while GameTime's night is at least 0.5 (LightingJNI.java:282), and
-- that is the climate's night strength (GameTime.java:833-835): 0 by day,
-- rising from the day's dusk to 1 a quarter of the way into the night, back to
-- 0 at its dawn, from the clock alone (ClimateValues.java:288-300; see
-- M.nightStrength). The lamps read the same value, so a lamp and the street
-- light beside it switch in the same minute, and a replay computes it for any
-- past hour. It ignores the weather, so a lightning flash, which lifts the
-- daylight reading to near noon for a moment (ThunderStorm.java:263-271), no
-- longer reads as dawn. Until 2026-09-26 the lamps read that daylight (dusk
-- 0.45, dawn 0.55) and the replay a sun-height curve of its own, and the two
-- disagreed by hours.
M.LAMP_NIGHT = 0.5
-- A lamp fresh from the workbench comes half charged, so one put down at
-- night shows it works before its first day in the sun.
M.LAMP_FRESH = 0.5

function M.lampSpec(tier)
    return M.LAMP_SPEC[tier or "garden"] or M.LAMP_SPEC.garden
end

--- Charge drained per game minute while lit, as a fraction of the battery.
--  The engine does the draining: this is the IsoLightSwitch's delta.
function M.lampDelta(tier)
    local s = M.lampSpec(tier)
    return s.drawW / s.wh / 60
end

--- Watts the lamp's panel makes now: the same sun as an array
--  (M.planeIrradiance and the engine's daylight gate), on a small module
--  facing the way the lamp faces. Nothing under a roof.
function M.lampWatts(tier, facing, env, sunlit)
    if not sunlit or not env then return 0 end
    local s = M.lampSpec(tier)
    local sun = M.solarHour(env.hour, env.dayOfYear, env.noon, env.dayHours,
                            env.latitude)
    local poa = M.planeIrradiance(env.dayOfYear, sun, facing or "S", env,
                                  env.latitude, s.tilt)
    if poa <= 0 then return 0 end
    if env.daylight ~= nil then
        if env.daylight <= 0.02 then return 0 end
        poa = poa * clamp(env.daylight * 1.25, 0, 1)
    end
    return max(0, s.panelW * poa / 1000 * (env.outputScale or 1))
end

--- The engine's cosine ease between a and b (ClimateManager.clerp).
local function clerp(t, a, b)
    local t2 = (1 - cos(t * pi)) / 2
    return a * (1 - t2) + b * t2
end

--- The climate's night strength at clock hour `hour` on a day whose dawn and
--  dusk are `dawn` and `dusk`, in hours: ClimateValues' lerpNight, which is
--  ClimateManager.getTimeLerpHours(hour, dusk, dawn, clerp) doubled and
--  clamped (ClimateValues.java:292-295; getTimeLerp, ClimateManager.java:
--  2169-2197). 0 by day, 0.5 a sixth of the way into the night, 1 from a
--  quarter of the way until a quarter before dawn. Endless Night and Endless
--  Day skip this in the engine (1 and 0); the caller handles them. nil for a
--  day the engine could not describe.
function M.nightStrength(hour, dawn, dusk)
    if type(hour) ~= "number" or type(dawn) ~= "number" or type(dusk) ~= "number"
            or hour ~= hour or dawn ~= dawn or dusk ~= dusk then
        return nil
    end
    local cur = clamp(hour / 24, 0, 1)
    local lo = clamp(dusk / 24, 0, 1)
    local hi = clamp(dawn / 24, 0, 1)
    local v
    if lo <= hi then
        if cur < lo or cur > hi then
            v = 0
        else
            local mid = (hi - lo) * 0.5
            if mid <= 0 then return 0 end
            local c = cur - lo
            if c < mid then v = clerp(c / mid, 0, 1) else v = clerp((c - mid) / mid, 1, 0) end
        end
    elseif cur < lo and cur > hi then
        v = 0
    else
        -- the night runs over midnight, as every Normal-cycle night does
        local off = 1 - lo
        local c = (cur >= lo) and (cur - lo) or (cur + off)
        local mid = (hi + off) * 0.5
        if c < mid then v = clerp(c / mid, 0, 1) else v = clerp((c - mid) / mid, 1, 0) end
    end
    return clamp(v * 2, 0, 1)
end

--- Is it night for a lamp? The night strength at or above the street
--  lights' 0.5. With no reading at all, as it was.
function M.lampNight(night, wasNight)
    if type(night) ~= "number" or night ~= night then return wasNight == true end
    return night >= M.LAMP_NIGHT
end

--- The charge after `minutes` at `watts` in, as a fraction of the battery.
function M.lampCharge(tier, charge, watts, minutes)
    local s = M.lampSpec(tier)
    return clamp((charge or 0) + (watts or 0) * (minutes or 0) / 60 / s.wh, 0, 1)
end

--- Replay hours the lamp spent out of memory, the way it runs in memory: the
--  panel charges whenever the sun reaches it, the lamp burns only while it is
--  lit, and only a change between day and night switches it (on at dusk, off
--  at dawn), so a lamp put out by hand stays out until the next dusk. It goes
--  out when it runs empty, and one with no bulb never lights.
--  `on` and `night` are how it left (a `night` of nil means it had not yet
--  seen day or night, and the first step counts as a change); `bulb` false
--  for no bulb. `envAt(h)` gives the environment at hour offset h from the
--  start, with `night` the night strength (M.nightStrength) and `daylight`
--  the panel's light; the last hour may be partial.
--  Returns the charge, whether it ends lit, and whether it ends in night.
--
--  Each hour is judged at its middle: the sun and the switch there stand for
--  the whole hour, so a dusk or dawn inside it is at most half an hour out,
--  either way. The state at the start is the one the lamp left with, never
--  judged again (a second opinion there switched a lamp at the very moment
--  it left, 2026-09-26).
--
--  It assumed the automatic switch until 2026-09-26: a lamp switched off by
--  hand came back lit after an absence inside the same night, with the
--  absence billed as burning.
function M.lampReplay(tier, facing, charge, hours, envAt, sunlit, on, night, bulb)
    local s = M.lampSpec(tier)
    on = (on == true) and bulb ~= false
    local done = 0
    while done < hours do
        local step = min(1, hours - done)
        local env = envAt(done + step / 2)
        local was = night
        night = M.lampNight(env and env.night, night)
        if night ~= was then on = night and bulb ~= false end
        charge = M.lampCharge(tier, charge,
                              M.lampWatts(tier, facing, env, sunlit), step * 60)
        if on then
            if charge <= 0 then
                on = false
            else
                charge = clamp(charge - s.drawW * step / s.wh, 0, 1)
                if charge <= 0 then on = false end
            end
        end
        done = done + step
    end
    return charge, on, night
end

---------------------------------------------------------------- battery bank

-- Again, the standard grade's numbers, kept as the fallbacks for a caller that
-- supplies no tier. BANK_SPEC above is what the game actually uses.
-- Vanilla's thaw window. Food.updateFreezing subtracts
-- elapsedHours / 1.5 * 100 from a 0..100 scale for an unpowered freezer, and
-- setFrozen(false) only fires at 0, so this is exactly how long the power can
-- be off before anything is actually lost.
-- Equalisation. The cost is expressed in multiples of the bank's own nameplate
-- capacity per 1.0 of health recovered, so a bigger bank costs proportionally
-- more to nurse: hauling a scrap crate back from the floor is an afternoon's
-- surplus, doing the same for a full rack is most of a summer week.
-- At the 0.25 health floor that is 3x capacity of throughput to reach full.
M.EQUALISE_COST  = 4.0
-- And a rate cap, so it is a project rather than a button. 0.02 per hour means
-- the floor-to-full trip takes about 37 hours of genuine surplus.
M.EQUALISE_RATE  = 0.02
-- Sealed cells cannot vent what an equalisation charge produces, so the mod
-- refuses rather than offering a way to destroy the best bank in the game.
M.EQUALISE_OK    = { makeshift = true, standard = true, premium = false }

M.THAW_HOURS     = 1.5
-- What losing it costs: frozen food ages at 0.0x, a powered fridge at 0.2x,
-- an unpowered one at 1.0x. Thawing is a five-fold rot-rate step.
M.THAW_ROT_STEP  = 5.0

M.CELL_WH        = 720        -- one scavenged 12V/60Ah lead-acid battery
M.DAMAGE_SOC     = 0.15       -- discharging past here costs permanent capacity
M.DAMAGE_RATE    = 0.010      -- health lost per hour spent below DAMAGE_SOC

--- Summed health of a cell list. Capacity is proportional to THIS, not to a
--  raw count: a battery installed at 55% condition is 55% of a cell, and it
--  costs its own share only. It never gates its neighbours.
function M.cellSum(cellList)
    local s = 0
    for i = 1, #(cellList or {}) do
        s = s + clamp(cellList[i].health or 1, 0, 1)
    end
    return s
end

--- What one cell at full health is worth, in Wh. NOMINAL: no cold factor.
--
--  Deliberate, and it is what makes install and remove conserve energy exactly.
--  `coldFactor` scales how much a rack will ACCEPT, so a rack filled in the
--  cold genuinely holds fewer Wh; it does not scale what is already in there.
--  Feeding cold into the hand-back would mean a battery unbolted at -10C read
--  differently from the same battery unbolted at noon, and since `charge` can
--  legitimately sit above the cold capacity after a temperature drop, it would
--  also let `charge / coldCapacity` pin at 1.0 and hand back a full battery.
--  Against nominal capacity that ratio stays at most 1: charging stops at the
--  cold capacity, which is never above nominal, and OG_System's scatter splits
--  a system's charge across its racks by nominal capacity, so no one rack can
--  be handed more than its own cells hold.
function M.cellWh(tier, scale)
    return M.bankSpec(tier).wh * (scale or 1)
end

--- Usable capacity in Wh, after health and cold.
--
--  Takes either shape. `cellSum` is the summed health of the real cells; the
--  older `cells` x blended `health` is arithmetically the same number, since
--  a mean times a count IS a sum, so the aggregate path in OG_System keeps
--  working untouched.
function M.bankCapacity(bank, tempC)
    local spec = M.bankSpec(bank.tier)
    return M.bankNominalWh(bank) * M.coldFactor(tempC, spec.cold)
end

--- The same capacity with the weather taken out: what the cells hold, after
--  health, in the shape bankCapacity takes. M.bankNominal is this figure for
--  one rack's cell list. The damage floor and the reconnect point are shares
--  of it (M.step), because a cooling night takes nothing out of a bank and a
--  warm morning puts nothing in.
function M.bankNominalWh(bank)
    local spec = M.bankSpec(bank.tier)
    local units = bank.cellSum
    if units == nil then
        units = max(0, bank.cells or 0) * clamp(bank.health or 1, 0, 1)
    end
    units = max(0, units)
    return units * spec.wh * (bank.scale or 1)
end

--- Nominal capacity: what the rack holds with the weather taken out.
--  The reference the cells are handed back against.
function M.bankNominal(b)
    return M.cellSum(b.cellList) * M.cellWh(b.tier, b.scale)
end

--- State of charge against nominal capacity, 0..1.
function M.bankFill(b)
    local nom = M.bankNominal(b)
    if nom <= 0 then return 0 end
    return clamp((b.charge or 0) / nom, 0, 1)
end

--- Put a battery into a rack.
--
--  `b` is { tier, scale, cellList, charge, nextCellId } and is mutated in
--  place. `cond` and `fill` are the item's condition and charge, both 0..1.
--  Returns the cell record that was appended.
--
--  The energy arrives WITH the battery: a cell of condition `cond` holds
--  `cond * cellWh` when full, and it turns up holding `fill` of that. The old
--  code added a full nameplate `wh` here regardless of condition and then
--  divided by a health-derated capacity on the way out, which inflated every
--  removal by 1/health. Both sides now speak Wh over the same nominal cell.
function M.installCell(b, itemType, cond, fill)
    cond = clamp(cond or 1, 0, 1)
    fill = clamp(fill or 0, 0, 1)
    b.cellList = b.cellList or {}
    if not b.nextCellId then
        -- max(id)+1, never #list+1: a rack that lost its counter (the item
        -- round trip dropped it before 2026-08-28) and then lost a middle
        -- cell has #list smaller than its largest id, and #list+1 would mint
        -- a DUPLICATE -- at which point removal-by-id grabs whichever twin
        -- sits first in the list.
        local top = 0
        for i = 1, #b.cellList do
            local id = b.cellList[i].id or 0
            if id > top then top = id end
        end
        b.nextCellId = top + 1
    end

    local cell = {
        id = b.nextCellId,
        type = itemType or "Base.CarBattery1",
        health = cond,
    }
    b.nextCellId = b.nextCellId + 1
    b.cellList[#b.cellList + 1] = cell

    b.charge = max(0, (b.charge or 0) + fill * cond * M.cellWh(b.tier, b.scale))
    local nom = M.bankNominal(b)
    if b.charge > nom then b.charge = nom end
    return cell
end

--- Take the cell with this id out.
--
--  Returns { type, cond, fill } describing the battery to hand back, or nil if
--  no cell carries that id -- which is the multiplayer case where somebody
--  else emptied the slot while this panel was open.
--
--  Cells in a rack sit in parallel and share one state of charge, so the cell
--  leaves holding the rack's fill, and the rack loses exactly that cell's
--  share. Both are the same fraction, so the rack's fill is unchanged by the
--  removal and no energy is created or destroyed.
function M.removeCell(b, cellId)
    local list = b.cellList or {}
    local idx, cell
    for i = 1, #list do
        if list[i].id == cellId then idx, cell = i, list[i]; break end
    end
    if not cell then return nil end

    local health = clamp(cell.health or 1, 0, 1)
    local fill = M.bankFill(b)
    b.charge = max(0, (b.charge or 0) - fill * health * M.cellWh(b.tier, b.scale))
    table.remove(list, idx)
    return { type = cell.type, cond = health, fill = fill }
end

--- Lead-acid loses usable capacity in the cold. A scrap bank is down near 42%
--  at -10C where a sealed one holds 74%, which is most of why the good ones
--  are worth the scavenging.
function M.coldFactor(tempC, floor)
    floor = floor or 0.55
    return clamp(floor + (1 - floor) * (((tempC or 20) + 10) / 25), floor, 1.0)
end

--- State of charge, 0..1, against the bank's cold-adjusted capacity.
function M.stateOfCharge(bank, tempC)
    local cap = M.bankCapacity(bank, tempC)
    if cap <= 0 then return 0 end
    return clamp((bank.charge or 0) / cap, 0, 1)
end

------------------------------------------------------------------ the system


-------------------------------------------------------------------- repair

--- Can this grade of bank take an equalisation charge at all?
function M.canEqualise(tier)
    return M.EQUALISE_OK[tier or "standard"] == true
end

--- One step of an equalisation charge.
--
--  `surplusWh` is energy that would otherwise have been clipped, so this is
--  only ever spent on power there was nowhere else to put. Returns the new
--  health and the Wh actually consumed, which is zero when there is nothing to
--  recover or nothing to recover it with.
function M.equaliseStep(health, surplusWh, capacityWh, dtHours)
    health = M.clamp(health or 1, 0, 1)
    surplusWh = max(0, surplusWh or 0)
    capacityWh = max(0, capacityWh or 0)
    dtHours = max(0, dtHours or 0)
    if health >= 1 or surplusWh <= 0 or capacityWh <= 0 or dtHours <= 0 then
        return health, 0
    end

    local perHealth = M.EQUALISE_COST * capacityWh
    local wantHealth = min(M.EQUALISE_RATE * dtHours, 1 - health)
    local wantWh = wantHealth * perHealth
    local spend = min(wantWh, surplusWh)
    local gained = spend / perHealth
    return M.clamp(health + gained, 0, 1), spend
end

--- Repairing a panel frame. Condition is 0..100 and the gain is capped so one
--  action is never a full restoration of a badly cracked array: a premium
--  frame is worth patching several times, a scrap one is worth replacing.
function M.repairStep(condition, amount)
    return M.clamp((condition or 0) + max(0, amount or 0), 0, 100)
end

------------------------------------------------------------ backup generators

--  A converted generator (2026-09-27) is a second source the controller
--  runs beside the sun: it serves what is switched on, charges the bank
--  with what is left, and burns petrol the way a normal generator does for
--  the same appliances. It never lands in the solar figures (t.generated,
--  t.arrayWatts, t.wasted), which feed the DAY trace, clipping,
--  equalisation and every "is the sun up" test. The tank, the sandbox and
--  the barrels all arrive as arguments (OG_BackupSys); nothing here reads
--  the world.

-- A normal generator burns 0.02 of the engine's units an hour running
-- nothing, on top of the units of every appliance it powers, times the
-- server's Generator Fuel Consumption (IsoGenerator.update).
M.BACKUP_IDLE_UNITS  = 0.02
-- In Realistic Mode it burns like a real petrol generator instead (Can,
-- 2026-09-29: "keep vanilla rate but make adjustments for the realistic
-- mode sandbox option as well"): 0.15 L an hour for each kW it is rated,
-- running or not, and 0.45 L for each kWh it delivers, charging included,
-- times Backup generator fuel use and never Generator Fuel Consumption. A
-- 4 kW Lectromax idles on 0.6 L an hour and burns 2.4 L at full output; a
-- 10 L tank runs a 1 kW house about 9.5 hours. M.realFuelUse bills it.
M.BACKUP_REAL_IDLE_L = 0.15
M.BACKUP_REAL_KWH_L  = 0.45
-- It loses 1 or 2 points of condition on a 1-in-N roll each running hour.
-- The model takes the average, 1.5 points every N hours, and carries the
-- fraction, so a minute's tick, an hour's catch-up slice and the away
-- estimate take the same toll.
M.BACKUP_WEAR_POINTS = 1.5

--- Share a request for energy among the running generators.
--
--  units = { { key, rating (W), tank (L, after this step's feed draw),
--              idle (L per running hour, its own; nil: k.idle) }, ... }
--  need  = Wh asked for; dt = hours
--  k     = { idle = L per running hour, perWh = L per Wh delivered }
--
--  Returns { total, cap, [i] = { key, wh, capWh } }, one entry per unit in
--  the order given. A unit gives at most its rating over dt, and at most
--  what its tank pays for after its idle burn (capWh; nothing from an empty
--  tank). The request is split in proportion to rating; a share a unit
--  cannot pay for passes to the others, again by rating, until the request
--  is met or every unit is spent. `cap` is the set's whole capWh and
--  `total` what it gave, the smaller of the request and `cap`. A unit's own
--  idle is Realistic Mode's, where a unit idles by its rating.
function M.backupSupply(units, need, dt, k)
    units = units or {}
    dt = max(0, dt or 0)
    k = k or {}
    local idle = max(0, k.idle or 0)
    local perWh = max(0, k.perWh or 0)
    local out = { total = 0, cap = 0 }
    local rating, spent = {}, {}
    for i = 1, #units do
        local u = units[i]
        rating[i] = max(0, u.rating or 0)
        local capWh = 0
        if (u.tank or 0) > 0 then
            local ui = u.idle ~= nil and max(0, u.idle) or idle
            capWh = rating[i] * dt
            if perWh > 0 then capWh = min(capWh, max(0, u.tank - ui * dt) / perWh) end
        end
        out[i] = { key = u.key, wh = 0, capWh = capWh }
        out.cap = out.cap + capWh
        spent[i] = capWh <= 0
    end
    -- Each round either meets what is left or spends at least one more
    -- unit, so as many rounds as there are units always finish. A spent
    -- unit is marked, not compared: wh + (capWh - wh) need not come back as
    -- capWh in doubles, and a unit left one unit in the last place short
    -- would swallow a share it cannot give in every later round.
    local left = max(0, need or 0)
    for _ = 1, #units do
        if left <= 0 then break end
        local open = 0
        for i = 1, #units do
            if not spent[i] then open = open + rating[i] end
        end
        if open <= 0 then break end
        local given = 0
        for i = 1, #units do
            if not spent[i] then
                local o = out[i]
                local share = left * rating[i] / open
                local room = o.capWh - o.wh
                if share >= room then
                    o.wh = o.capWh
                    spent[i] = true
                    given = given + room
                else
                    o.wh = o.wh + share
                    given = given + share
                end
            end
        end
        left = left - given
    end
    for i = 1, #units do out.total = out.total + out[i].wh end
    return out
end

--- Litres one generator burned over a step.
--
--  unit  = { wh = Wh it delivered, dtRun = hours it ran (the step, while running),
--            loadWh, chargeWh = the part of wh that served the load and the
--            part that charged, when the caller knows them (M.step does) }
--  parts = { U = Wh every generator delivered; loadWh, chargeWh = the part
--            of U that served the load and the part that charged the bank;
--            billedWh = the load served this step; loadUnits = the engine
--            units of the appliances the load scan counted; unitlessW =
--            load watts no engine unit covers (a transformer's loss);
--            dt = hours; wpu = W per engine unit for those and for charging }
--  gfc   = the server's Generator Fuel Consumption; use = Backup generator
--          fuel use. Either at 0 is free petrol, as in vanilla.
--
--  A normal generator burns its idle 0.02 units plus the units of what it
--  powers, times gfc, every hour. So does this one: the idle for the time
--  it ran, and its share of the backup's energy times the share of the
--  load's units the backup carried. Load watts with no unit, and charging,
--  which a normal generator never does, cost one unit per `wpu` watts, the
--  rate OG_Loads already bills an appliance it cannot name at. A
--  fridge-freezer, eight lights and a TV (0.13 + 8 x 0.002 + 0.03 units)
--  come to 0.0196 L an hour at the default 0.1, vanilla's own figure.
--
--  A unit that gives its own loadWh and chargeWh is billed on its own split,
--  not on its share of the set's: M.step caps each unit's load at the load's
--  price and its charging at charging's, so a bill on its own split never
--  passes its tank (final review, 2026-09-28).
function M.fuelUse(unit, parts, gfc, use)
    local gu = max(0, gfc or 0) * max(0, use or 0)
    if gu <= 0 then return 0 end
    parts = parts or {}
    local dt = max(0, parts.dt or 0)
    local wpu = parts.wpu or 0
    local U = parts.U or 0
    local billed = parts.billedWh or 0
    local unitless = min(billed, max(0, parts.unitlessW or 0) * dt)
    local loadUnits = max(0, parts.loadUnits or 0) * dt + (wpu > 0 and unitless / wpu or 0)
    local idle = M.BACKUP_IDLE_UNITS * max(0, unit.dtRun or 0)
    if unit.loadWh ~= nil or unit.chargeWh ~= nil then
        local perLoadWh = billed > 0 and loadUnits / billed or 0
        return gu * (idle + max(0, unit.loadWh or 0) * perLoadWh
                     + (wpu > 0 and max(0, unit.chargeWh or 0) / wpu or 0))
    end
    local s = U > 0 and (unit.wh or 0) / U or 0
    local f = billed > 0 and (parts.loadWh or 0) / billed or 0
    local chargeUnits = wpu > 0 and (parts.chargeWh or 0) / wpu or 0
    return gu * (idle + s * (f * loadUnits + chargeUnits))
end

--- Litres one generator burned over a step in Realistic Mode: a real
--  petrol generator's burn, M.BACKUP_REAL_IDLE_L an hour for each rated kW
--  for the time it ran, and M.BACKUP_REAL_KWH_L for each kWh it delivered,
--  load and charging alike, times `use` (Backup generator fuel use; 0 is
--  free). Generator Fuel Consumption plays no part.
--
--  unit = { wh = Wh it delivered, dtRun = hours it ran, rating = W }
function M.realFuelUse(unit, use)
    local u = max(0, use or 0)
    if u <= 0 or not unit then return 0 end
    local ratedKw = max(0, unit.rating or 0) / 1000
    return u * (M.BACKUP_REAL_IDLE_L * ratedKw * max(0, unit.dtRun or 0)
                + M.BACKUP_REAL_KWH_L * max(0, unit.wh or 0) / 1000)
end

--- The same rule as prices for M.backupSupply: { idle = L per running hour
--  for a unit of `rating` W, perWh = L per Wh delivered }.
function M.realPrices(rating, use)
    local u = max(0, use or 0)
    return u * M.BACKUP_REAL_IDLE_L * max(0, rating or 0) / 1000,
           u * M.BACKUP_REAL_KWH_L / 1000
end

--- Condition points a running generator loses over `hours`, and the
--  remainder to carry to the next step.
--
--  unit = { wear = remainder (0..1), wearN = N, the brand's 1-in-N chance
--  per running hour }. No roll: the average (M.BACKUP_WEAR_POINTS), so live
--  ticks, a catch-up and the away estimate agree to the point.
function M.wear(unit, hours)
    local acc = max(0, unit.wear or 0)
    local n = unit.wearN or 0
    if n > 0 then acc = acc + M.BACKUP_WEAR_POINTS / n * max(0, hours or 0) end
    local points = floor(acc)
    return points, acc - points
end

------------------------------------------------------------------ cold chain

--- Hours the bank can keep the refrigeration alive, at the current draw.
--  `charge` and `usable` are Wh, `coldWatts` is what the fridges and freezers
--  in the system are drawing between them. Returns a large finite number
--  rather than infinity when nothing is drawing, so callers can format it.
function M.coldHours(charge, coldWatts, dodFloor, capacity)
    coldWatts = max(0, coldWatts or 0)
    local floorWh = (dodFloor or M.DAMAGE_SOC) * max(0, capacity or 0)
    local usable = max(0, (charge or 0) - floorWh)
    if coldWatts <= 0 then return 999 end
    return usable / coldWatts
end

--- Is the cold chain safe for the next `hours` of darkness?
--  Safe means the bank can carry refrigeration right through, OR the gap it
--  cannot carry is shorter than the thaw window and therefore free.
function M.coldSafe(coldHours, darkHours)
    local gap = max(0, (darkHours or 0) - (coldHours or 0))
    return gap < M.THAW_HOURS, gap
end

--- The reserve, in Wh, that has to stay in the bank to guarantee the cold
--  chain survives `hours` without sun.
function M.coldReserve(coldWatts, hours, dodFloor, capacity)
    local floorWh = (dodFloor or M.DAMAGE_SOC) * max(0, capacity or 0)
    return floorWh + max(0, coldWatts or 0) * max(0, hours or 0)
end

--- Split a measured load into the part that must not be interrupted and the
--  part that can wait for the sun. Refrigeration is the only load in the game
--  whose interruption has a lasting cost, and it is also the only one the
--  engine will not let a mod switch off on its own, so it is the whole of the
--  protected half by construction.
function M.splitLoad(totalWatts, coldWatts)
    local cold = max(0, min(coldWatts or 0, totalWatts or 0))
    return cold, max(0, (totalWatts or 0) - cold)
end

--- Should the controller be holding charge back right now?
--  The rule is deliberately one line of arithmetic the player can predict:
--  hold when the bank is at or below the reserve the cold chain needs to get
--  through the night, and release once it is clear of it by a margin. The
--  margin is what stops the answer oscillating around the threshold.
function M.shouldHold(charge, reserveWh, marginWh)
    charge = charge or 0
    reserveWh = reserveWh or 0
    marginWh = marginWh or 0
    if charge <= reserveWh then return true end
    if charge >= reserveWh + marginWh then return false end
    return nil                       -- inside the band: keep doing what you were
end


--- The low-voltage disconnect.
--
--  When the load would take the bank under its damage floor the controller
--  sheds it, and takes it back by itself once the bank has recovered past a
--  threshold. It used to latch instead: one tick of shortfall switched the
--  system off until the player reset it by hand, and at night a reset
--  re-tripped within a game minute because the bank was still at zero. A base
--  whose panels could not quite carry two nights in a row therefore "tripped
--  every other day" (Workshop, 2026-09), with a FAULT lamp and no reason. A
--  real charge controller reconnects on its own; so does this one now.
--
--  It opens at the floor and not at empty, because protecting the battery is
--  what a real one is for. The first cut waited for an empty bank, so every
--  shed night was spent under the floor, wearing the cells: a standard rack
--  lost about a tenth of its capacity a night and a scrap crate a fifth (live
--  test, 2026-09-14). The load now never takes the bank under its floor, and
--  a bank the disconnect stopped there takes no wear while it waits. The
--  floor is a charge in Wh, a share of what the cells hold with the weather
--  taken out, so a night's cooling and a morning's warming do not move the
--  bank across it (see M.step). A bank that is already under its floor (flat
--  cells fitted, a bank run empty before this build) wears until the sun
--  lifts it back over; the load cannot.
--
--  The reconnect point (M.reconnectWh) is at least the bank's own damage
--  floor plus a margin, and never under a fifth of capacity: standard and
--  sealed banks come back at 25 percent or later, a scrap crate at 35 or
--  later. The margin leaves the reconnect at least five points above where
--  the disconnect opened, whatever the blend of grades.
M.LVD_MIN_SOC = 0.20
M.LVD_MARGIN  = 0.05
-- Five points was the whole wait, and on a small bank five points is not
-- long: 28 Wh on a one-battery crate, about two minutes of a fridge and the
-- lights. Under a 115 W sun such a rig lit the house for three to five
-- minutes twice an hour all afternoon (live test R2, 2026-09-14), which a
-- player reads as a broken mod. So the load comes back only once the charge
-- over the floor can keep what the house asks for running for half an hour.
M.LVD_MIN_RUN_HOURS = 0.5
-- And never past what the bank can reach: 95 percent of what it takes now.
-- What it takes is the cold capacity, not what the cells hold: charging stops
-- there, and a crate at 0 C takes 65 percent of its cells, so a point on the
-- cells alone could leave a frosty house dark for good.
M.LVD_TOP_SOC = 0.95
-- A bank the disconnect left exactly at its floor must not read as under it.
-- OG_System splits the charge across the racks by share and adds it back up
-- on the next tick, and in doubles that sum can come back one unit in the
-- last place under the floor it was clamped to (two sealed cabinets holding
-- one battery and two do; Kahlua's numbers are doubles too). Without the
-- margin that one unit would wear a correctly shed bank all night.
M.FLOOR_EPS   = 1e-9

function M.lvdThreshold(dodFloor)
    local floor = dodFloor or M.DAMAGE_SOC
    return clamp(max(floor, M.LVD_MIN_SOC) + M.LVD_MARGIN, 0, 0.95)
end

function M.lvdShouldClose(soc, threshold)
    return (soc or 0) >= (threshold or M.lvdThreshold())
end

--- The charge, in Wh, a shed load comes back on at.
--
--  `nominal` is what the cells hold with the weather taken out, `capacity`
--  what the bank takes now (nil: no cold in it), `demandW` what the house is
--  asking for while it is dark: the switched-on appliances in reach, which
--  the load scan goes on counting through a shed. The floor plus half an hour
--  of that, never under the grade's threshold, never over 95 percent of what
--  the bank takes now. A bank too small to hold half an hour of its house
--  comes back nearly full, and runs what it holds. Worked out afresh every
--  tick, so a light switched off in the dark brings the point down, and a
--  controller shed under an earlier rule adopts this one on its next tick.
--
--  The top never undercuts the threshold: 95 percent of every grade's
--  coldest capacity is still over its threshold, and so is every blend's
--  (test_model). If it ever did, the top would win, because a point the bank
--  cannot reach keeps the house dark for good.
function M.reconnectWh(dodFloor, nominal, capacity, demandW)
    local floor = dodFloor or M.DAMAGE_SOC
    nominal = max(0, nominal or 0)
    local takes = min(nominal, max(0, capacity or nominal))
    local run = floor * nominal + max(0, demandW or 0) * M.LVD_MIN_RUN_HOURS
    return min(max(M.lvdThreshold(floor) * nominal, run), M.LVD_TOP_SOC * takes)
end

--- The bank's two sizes as M.step reads them: what it takes now (after
--  health and cold) and what its cells hold with the weather taken out. A
--  caller that gives capacity and no nominal has no cold in it.
local function bankSizes(bank, tempC)
    local cap = bank.capacity or M.bankCapacity(bank, tempC)
    local nominal = bank.nominal
    if nominal == nil then nominal = bank.capacity or M.bankNominalWh(bank) end
    return cap, nominal
end

--- The damage floor on the gauge's scale: the charge the disconnect opens
--  at, as a share of what the bank takes now, which is the scale BATT
--  prints on. M.step reports it as t.floorSoc and judges the disconnect on
--  it. The backup generator's Auto sets its start level above this floor
--  BEFORE the step runs (2026-09-27), and it reads this function, never a
--  copy of the arithmetic: a start level worked out from a floor a point
--  away from the step's would let the house go dark before a generator was
--  asked for.
function M.floorSoc(bank, tempC)
    bank = bank or {}
    local cap, nominal = bankSizes(bank, tempC or 20)
    local dod = bank.dod or M.DAMAGE_SOC
    if cap > 0 then return clamp(dod * nominal / cap, 0, 1) end
    return dod
end

--- What the arrays deliver now, in W after the inverter and the
--  controller's harvest, and the strongest plane-of-array irradiance among
--  them (W/m^2). Moved out of M.step (2026-09-27) so the backup generator's
--  Auto can ask what the sun gives before the step runs and get the very
--  number the step then uses.
function M.solarWatts(sys, env)
    local invEff = sys.inverterEff or M.INVERTER_EFF
    local harvest = sys.harvest or 1.0
    local watts, irradiance = 0, 0
    for i = 1, #(sys.arrays or {}) do
        local a = sys.arrays[i]
        local w, poa = M.arrayOutput(a, env)
        watts = watts + w
        if poa > irradiance then irradiance = poa end
    end
    return watts * invEff * harvest, irradiance
end

--- The running set's two passes in M.step, in the order the energy goes:
--  first the part of `loadWh` the sun leaves, at the load's price (pL L a
--  Wh, each unit's tank paying its idle first), then the room the sun left
--  in the bank, from what each unit has left of its rating and its tank, at
--  charging's price (pC). Returns both backupSupply results, and what the
--  set could give asked for this load: all the load pass gave, and all the
--  charge pass could.
--
--  One blended price for both (final review, 2026-09-28) capped a nearly
--  empty tank at the blend, but the energy it gave went to the load first:
--  a 0.005 L tank was billed 0.0104 L, and half of what it gave was free.
local function backupPasses(units, loadWh, S, toFill, dt, idle, pL, pC)
    local one = M.backupSupply(units, max(0, loadWh - S), dt, { idle = idle, perWh = pL })
    local rest = {}
    for i = 1, #units do
        local u, got = units[i], one[i]
        local ui = u.idle ~= nil and max(0, u.idle) or idle
        rest[i] = {
            key = u.key,
            rating = dt > 0 and max(0, max(0, u.rating or 0) * dt - got.wh) / dt or 0,
            tank = max(0, (u.tank or 0) - ui * dt - got.wh * pL),
        }
    end
    local two = M.backupSupply(rest, max(0, toFill - max(0, S - loadWh)), dt,
                               { idle = 0, perWh = pC })
    return one, two, one.total + two.cap
end

--- Advance a whole system by `dtHours`.
--
--  `sys` is mutated in place and also returned, alongside a telemetry table
--  the UI reads. Keeping the telemetry separate from the persisted state is
--  what stops the save file growing a graph's worth of junk.
--
--  sys = {
--    arrays = { {facing, mount, tier, panels, condition, soiling, snow}, ... },
--    bank   = { charge, capacity, nominal, health, eff, dod, decay },
--             -- capacity after health and cold, nominal after health only;
--             -- a caller that gives capacity and no nominal has no cold in it
--    load   = watts currently demanded,
--    online = boolean,   -- the player's switch; never written here
--    lvd    = boolean,   -- load shed by the low-voltage disconnect;
--                        -- clears itself once the bank recovers
--    powered = boolean,  -- whether the house had power over this step (the
--                        -- generator was on); nil for a catch-up slice,
--                        -- which keeps no record of it and bills as powered
--    inverterEff, harvest -- from the controller's grade
--    backup = nil or {   -- the backup generators RUNNING this step (OG_BackupSys)
--      units = { { key, rating (W), tank (L) }, ... },
--      gfc, use,         -- Generator Fuel Consumption, Backup generator fuel use
--      loadUnits,        -- the engine units of what the load scan counted
--      unitlessW,        -- load watts no engine unit covers (transformer loss)
--      wpu,              -- W per engine unit for those and for charging (OG_Loads)
--      realistic,        -- Realistic Mode: burn by M.realFuelUse instead (the
--                        -- caller reads the sandbox; this file never does)
--    }
--  }
--
--  The bank arrives pre-aggregated rather than as a tier, because a real
--  system is a mix: three scrap crates and one sealed cabinet share one state
--  of charge, and the efficiency and depth-of-discharge that govern them are
--  the capacity-weighted blend the caller worked out.
--
--  A running backup generator is a second source with figures of its own:
--  t.backupCap (B, what the running set could give this step, Wh),
--  t.backupWh and t.backupWatts (what it gave), t.backupLoadWh and
--  t.backupChargeWh (the part that served the load and the part that
--  charged), t.bypass, and t.backupUnits = { { key, wh, fuel (L) }, ... }.
--  The sun goes first; the generators fill the rest of the load, then the
--  room the sun left in the bank, and no more. While the sun and B can
--  carry everything switched on (the supply bypass), a shed closes at once
--  whatever the charge, and the load never touches the bank.
function M.step(sys, dtHours, env)
    local t = {
        generated = 0, consumed = 0, stored = 0, drawn = 0,
        wasted = 0, deficit = 0, irradiance = 0,
        arrayWatts = 0, loadWatts = 0,
        lvdOpened = false, lvdClosed = false, reconnectSoc = 0, socIn = 0,
        floorSoc = 0,
        backupCap = 0, backupWh = 0, backupWatts = 0,
        backupLoadWh = 0, backupChargeWh = 0, bypass = false, backupUnits = {},
    }
    dtHours = max(0, dtHours or 0)
    local bank = sys.bank or { cells = 0, charge = 0, health = 1 }
    local tempC = env.temperature or 20
    local chargeEff = bank.eff or M.CHARGE_EFF
    local dodFloor = bank.dod or M.DAMAGE_SOC
    local decayRate = bank.decay or M.DAMAGE_RATE

    -- generation
    t.arrayWatts, t.irradiance = M.solarWatts(sys, env)
    t.generated = t.arrayWatts * dtHours

    -- The floor and the reconnect point are charges in Wh, worked out from
    -- what the cells hold with the weather taken out. They were shares of the
    -- cold-adjusted capacity, which moves with the temperature while the
    -- charge does not: a crate shed at its floor at dusk rose over its
    -- reconnect point as the night cooled and lit the house at 2 am, to shed
    -- again inside the hour, and a rack shed on a frosty night sank under
    -- its floor as the morning warmed and wore until the sun caught up
    -- (review, 2026-09-14). The reconnect point also waits for half an hour
    -- of the load the house is asking for (M.reconnectWh); only its top, 95
    -- percent of what the bank takes now, follows the cold, and that top
    -- stays over the threshold, so a bank shed at its floor still never
    -- comes back on in a cooling night.
    --
    -- The monitor prints the charge against the cold-adjusted capacity, what
    -- the bank will take now, so both points are handed back on that scale
    -- too: from 15 C up the grade's own floor, and its threshold or later,
    -- higher on the gauge in the cold. The disconnect is judged on that
    -- scale, on the charge as it stands at the START of the tick, so the
    -- number the player reads and the number compared are still one number.
    local cap, nominal = bankSizes(bank, tempC)
    local floorWh = dodFloor * nominal
    local lvd = sys.lvd == true
    local charge = max(0, bank.charge or 0)
    local socIn = cap > 0 and clamp(charge / cap, 0, 1) or 0
    t.socIn = socIn
    t.floorSoc = M.floorSoc(bank, tempC)
    if cap > 0 then
        t.reconnectSoc = clamp(M.reconnectWh(dodFloor, nominal, cap, sys.load) / cap, 0, 1)
    else
        t.reconnectSoc = M.lvdThreshold(dodFloor)
    end

    -- Backup generators: what the running set could give this step (B),
    -- asked against the load as if the house were lit (D, everything
    -- switched on, which the load scan counts through a shed) plus the room
    -- the sun leaves in the bank. Its tanks pay for the load first, at the
    -- load's units, and charge with what is left, at charging's
    -- (backupPasses); the bill per unit is M.fuelUse, at the end. While the
    -- sun and B carry all of D the shed closes here, whatever the charge and
    -- whatever the bank holds, before the reconnect test below: a house a
    -- generator can light is not left dark to wait for the batteries.
    local backup = sys.backup
    local units = backup and backup.units or {}
    local S = t.generated
    local toFill, B = 0, 0
    local idle, pL, pC = 0, 0, 0
    -- Realistic Mode's burn (backup.realistic, passed in by the caller): each
    -- unit idles by its own rating and every Wh costs the same, load or
    -- charge (M.realPrices). The units are copied with their idle, never
    -- written: they are the caller's.
    local real = backup ~= nil and backup.realistic == true
    if #units > 0 then
        toFill = chargeEff > 0 and max(0, cap - charge) / chargeEff or 0
        local Dwh = max(0, sys.load or 0) * dtHours
        if real then
            local priced = {}
            for i = 1, #units do
                local u = units[i]
                local ui, perWh = M.realPrices(u.rating, backup.use)
                priced[i] = { key = u.key, rating = u.rating, tank = u.tank, idle = ui }
                pL, pC = perWh, perWh
            end
            units = priced
        else
            local gu = max(0, backup.gfc or 0) * max(0, backup.use or 0)
            local wpu = backup.wpu or 0
            pC = wpu > 0 and gu / wpu or 0
            local unitless = min(Dwh, max(0, backup.unitlessW or 0) * dtHours)
            pL = Dwh > 0
                and (gu * max(0, backup.loadUnits or 0) * dtHours + unitless * pC) / Dwh or 0
            idle = gu * M.BACKUP_IDLE_UNITS
        end
        local _, _, setCap = backupPasses(units, Dwh, S, toFill, dtHours, idle, pL, pC)
        B = setCap
        t.backupCap = B
        t.bypass = dtHours > 0 and S + B >= Dwh
        if t.bypass and lvd then
            lvd = false
            t.lvdClosed = true
        end
    end

    if lvd and cap > 0 and M.lvdShouldClose(socIn, t.reconnectSoc) then
        lvd = false
        t.lvdClosed = true
    end

    -- Demand, and what of it is billed. Nothing is asked for while the switch
    -- is off or the load is shed, and nothing is BILLED while the house has
    -- no power: the load was billed from the tick the disconnect closed, while
    -- the generator waited out its start-up hold, so a small bank paid for
    -- minutes of power it never delivered, ran flat before the lights came on
    -- and shed again, every hour of a sunny day (live test, 2026-09-14).
    local demand = (sys.online and not lvd) and max(0, sys.load or 0) or 0
    local connected = demand > 0 and sys.powered ~= false
    t.loadWatts = connected and demand or 0
    t.consumed = t.loadWatts * dtHours

    -- What the generators give (U): the part of the billed load the sun
    -- leaves, then the room in the bank the sun leaves, never more than
    -- their tanks pay for. So U never lands in t.wasted, and while the
    -- bypass holds the load never reaches the bank.
    local one, two, U = nil, nil, 0
    if #units > 0 then
        one, two = backupPasses(units, t.consumed, S, toFill, dtHours, idle, pL, pC)
        t.backupLoadWh = one.total
        t.backupChargeWh = two.total
        U = one.total + two.total
    end

    local net = t.generated + U - t.consumed

    if net >= 0 then
        -- A chemistry that keeps nothing stores nothing, and all of the
        -- surplus is waste. Dividing by its zero efficiency was a 0/0 that
        -- wrote NaN into the day's ledger.
        local room = max(0, cap - charge)
        local accepted = chargeEff > 0 and min(room, net * chargeEff) or 0
        bank.charge = charge + accepted
        t.stored = accepted
        t.wasted = chargeEff > 0 and max(0, net - accepted / chargeEff) or net
    else
        -- The load takes what sits above the floor and no more. What it
        -- still wants is the shortfall, and the controller drops the load
        -- rather than draw the cells into the range that wears them. It
        -- comes back on its own, see M.reconnectWh. A bank already under
        -- its floor (flat cells fitted) is not lifted to it.
        local need = -net
        local above = max(0, charge - floorWh)
        if need <= above then
            bank.charge = charge - need
            t.drawn = need
        else
            bank.charge = min(charge, floorWh)
            t.drawn = above
            t.deficit = need - above
            if t.deficit > 0.0001 and sys.online and not lvd then
                lvd = true
                t.lvdOpened = true
            end
        end
    end

    -- The house is dark (a start-up hold, a switch just thrown, cells just
    -- fitted) and the bank is already at its floor with no sun to carry the
    -- load: lighting the house now would only shed it again a minute later,
    -- so the disconnect opens before it ever connects. Under a sun that
    -- carries the load it connects, as a real disconnect does on charging
    -- voltage. A running backup generator counts with the sun: what the
    -- set can give (B) lights the house as well.
    if not connected and demand > 0 and not lvd and cap > 0
            and socIn <= t.floorSoc + M.FLOOR_EPS and t.generated + B < demand * dtHours then
        lvd = true
        t.lvdOpened = true
    end

    -- health: deep cycling is what actually kills a lead-acid bank, and a
    -- cheap chemistry starts complaining far sooner than a sealed one
    local soc = cap > 0 and clamp((bank.charge or 0) / cap, 0, 1) or 0
    if soc < t.floorSoc - M.FLOOR_EPS and cap > 0 and env.degrade ~= false then
        bank.health = clamp((bank.health or 1) - decayRate * dtHours, 0.25, 1)
    end

    t.soc = soc
    t.capacity = cap
    t.charge = bank.charge or 0

    -- The backup's own figures, and each unit's petrol, billed on its own
    -- split of load and charging. Every running unit burns its idle for the
    -- whole step, even one that gave nothing.
    t.backupWh = U
    t.backupWatts = dtHours > 0 and U / dtHours or 0
    if one then
        local parts = { U = U, loadWh = t.backupLoadWh, chargeWh = t.backupChargeWh,
                        billedWh = t.consumed, loadUnits = backup.loadUnits or 0,
                        unitlessW = backup.unitlessW or 0, dt = dtHours, wpu = backup.wpu }
        for i = 1, #units do
            local wh1, wh2 = one[i].wh, two[i].wh
            local fuel
            if real then
                fuel = M.realFuelUse({ wh = wh1 + wh2, dtRun = dtHours, rating = units[i].rating },
                                     backup.use)
            else
                fuel = M.fuelUse({ wh = wh1 + wh2, dtRun = dtHours, loadWh = wh1, chargeWh = wh2 },
                                 parts, backup.gfc, backup.use)
            end
            t.backupUnits[i] = { key = one[i].key, wh = wh1 + wh2, fuel = fuel }
        end
    end
    sys.bank = bank
    sys.lvd = lvd
    return sys, t
end

--- How snow behaves on a panel of this mount over `dt` hours.
--  Returns the new cover, 0..1. A tilted frame sheds; a roof panel does not,
--  which is the whole reason to keep a ground array through a Kentucky winter.
function M.snowCover(cover, mount, env, dt, rateScale)
    local m = M.mountSpec(mount)
    cover = clamp(cover or 0, 0, 1)
    rateScale = rateScale or 1
    if env.snowing then
        return clamp(cover + 0.45 * m.snowGain * rateScale * dt, 0, 1)
    end
    if (env.temperature or 10) > 1.5 then
        local melt = (0.10 + 0.30 * clamp(env.daylight or 0, 0, 1)) * m.snowShed
        return clamp(cover - melt * dt, 0, 1)
    end
    return cover
end

--- Hours the bank can carry the current load with no sun. -1 means indefinite.
function M.runtimeRemaining(sys, env)
    local load = max(0, sys.load or 0)
    if load <= 0 then return -1 end
    local tempC = env and env.temperature or 20
    local bank = sys.bank or {}
    local usable = max(0, (bank.charge or 0))
    return usable / load
end

--- Whole-day energy forecast in Wh, sampled every `stepMinutes`.
--  Used by the controller's readout so the player can size an array before
--  committing a week of scavenging to it. The samples and peakHour are clock
--  hours; env's engine day moves the sun under them.
function M.forecastDay(sys, env, stepMinutes)
    local stepH = (stepMinutes or 30) / 60.0
    local total, peak, peakHour = 0, 0, 0
    local samples = {}
    local h = 0
    while h < 24 do
        local e = {}
        for k, v in pairs(env) do e[k] = v end
        e.hour = h
        e.daylight = nil                 -- forecast is geometry, not live light
        local w = 0
        for i = 1, #(sys.arrays or {}) do
            local aw = M.arrayOutput(sys.arrays[i], e)
            w = w + aw
        end
        w = w * (sys.inverterEff or M.INVERTER_EFF) * (sys.harvest or 1.0)
        total = total + w * stepH
        if w > peak then peak, peakHour = w, h end
        samples[#samples + 1] = { hour = h, watts = w }
        h = h + stepH
    end
    return total, peak, peakHour, samples
end


------------------------------------------------------------------ backup Auto

--- Auto: when the controller starts and stops its backup generators (design
--  "Auto"). The levels are shares of the charge on the gauge's scale, the one
--  BATT prints and M.step judges the disconnect on, and they sit on a
--  five-point grid.
M.AUTO_START_OVER = 0.10   -- the default start, over the disconnect's threshold
M.AUTO_START_MIN  = 0.05   -- the lowest start, over the same threshold
M.AUTO_START_TOP  = 0.80   -- the highest start
M.AUTO_STOP       = 0.90   -- the default stop
M.AUTO_STOP_TOP   = 0.95   -- the highest stop
M.AUTO_BAND       = 0.10   -- a stop sits at least this far over its start
M.AUTO_OVER_FLOOR = 0.05   -- and Auto starts at least this far over the floor

-- Twentieths: the grid every level sits on. Dividing by 20 lands on the
-- nearest double to k/20 exactly; multiplying by 0.05 can miss it by a unit
-- in the last place, and then 35 percent no longer equals itself.
local function snapLevel(v)
    return floor(v * 20 + 0.5) / 20
end

-- Up to the grid. The slack keeps a level a unit in the last place over a
-- grid point (0.1 + 0.2 is 0.30000000000000004) from climbing a whole step.
local function snapLevelUp(v)
    return math.ceil(v * 20 - 1e-9) / 20
end

--- Auto's levels for a system, worked out afresh every tick.
--
--  `dod` is the rack's blended depth of discharge, `floorSoc` the
--  disconnect's floor on the gauge's scale (M.floorSoc, the very number
--  M.step compares), `bkStart` / `bkStop` the controller's stored levels,
--  nil for the defaults. Returns start (the level the player set, clamped),
--  stop, eff (the level Auto really starts at), and lo / hi, the limits of
--  start for GEN's - and + (stop's are start + 0.10 and 0.95).
--
--  A stored level is clamped on every read, never on write, so a rack that
--  changes grade moves its levels with it: start to [threshold + 5, 80],
--  stop to [start + 10, 95], both on the grid. A blend's threshold can sit
--  off the grid (0.27 + 0.05 = 0.32), so the lowest start is snapped UP: one
--  snapped down would sit under threshold + 5. With lo and 80 both on the
--  grid, the clamp can only land on it.
--
--  In the cold the floor climbs the gauge (a scrap crate at -10 C is cut off
--  at 71 percent of what it takes, against a set start of 45), so eff climbs
--  with it and a generator still starts before the house is cut off. The
--  player's start is kept as set; GEN shows it and steps it.
function M.backupLevels(dod, floorSoc, bkStart, bkStop)
    if not M.finite(dod) then dod = nil end
    local thr = M.lvdThreshold(dod)
    local hi = M.AUTO_START_TOP
    local lo = min(snapLevelUp(thr + M.AUTO_START_MIN), hi)
    local start = M.finite(bkStart) and bkStart or thr + M.AUTO_START_OVER
    start = clamp(snapLevel(start), lo, hi)
    local stop = M.finite(bkStop) and bkStop or M.AUTO_STOP
    -- start + 0.10 in doubles can land a unit off the grid (0.35 + 0.10 is
    -- 0.44999999999999996); its snap cannot.
    stop = clamp(snapLevel(stop), snapLevel(start + M.AUTO_BAND), M.AUTO_STOP_TOP)
    local eff = max(start, (M.finite(floorSoc) and floorSoc or 0) + M.AUTO_OVER_FLOOR)
    return start, stop, eff, lo, hi
end

--- The charge on the gauge's scale at the end of a step if the running
--  generators gave their whole rating and the house drew `demandW`. Auto
--  reads its levels against this, so it starts a generator before the step
--  that would take the bank under its start level, not after it. Charging
--  keeps the bank's efficiency and drawing does not, as in M.step. A bank
--  with no capacity reads 0 (Auto does not read it then).
function M.projectSoc(bank, solarW, supplyW, demandW, dt)
    bank = bank or {}
    local cap = bank.capacity or 0
    if not (cap > 0) then return 0 end
    local net = ((solarW or 0) + (supplyW or 0) - (demandW or 0)) * max(0, dt or 0)
    local eff = bank.eff or M.CHARGE_EFF
    local charge = max(0, bank.charge or 0) + (net > 0 and net * eff or net)
    return clamp(charge / cap, 0, 1)
end

-- The two timers Auto reads, in hours. The model keeps them because it is
-- the one that reads them: OG_Backup loads after this file, and a pure model
-- reads no other module.
M.AUTO_MIN_RUN  = 0.5    -- a generator runs this long before Auto may stop it
M.AUTO_SUN_HOLD = 0.5    -- the sun carries the house this long before Auto stops one
-- World hours are doubles, and thirty minute ticks measured as the difference
-- of two of them can come back a hair short of 0.5 (1022.504 plus 60 and plus
-- 90 steps of 1/60 do). Without the slack that tick would hold a generator a
-- minute past its rule. Well under a game second.
M.AUTO_EPS      = 1e-6

-- Of two running generators, did `a` start after `b`? The later one is the
-- one Auto stops first when the sun takes over. A start with no record reads
-- as the earliest; a tie goes to the larger node key, the reverse of the
-- start order.
local function startedAfter(a, b)
    if a.since ~= b.since then
        if a.since == nil then return false end
        if b.since == nil then return true end
        return a.since > b.since
    end
    return a.key > b.key
end

--- Auto's decision for one step. Pure: the caller applies it, stamps the
--  timers and keeps the clock.
--
--  state = {
--    master   = the controller's Auto (bkAuto); nil reads as on
--    shed     = a REAL shed: cells fitted and the disconnect opened by a
--               deficit (d.lvdAt stamped). A rig with no cells is forced
--               shed every tick, unstamped, and that is not a shed here:
--               read as one, it started a generator at once on every such
--               rig, even with the controller off in full sun
--    replace  = a running generator left RUNNING (no fuel, fault, fire,
--               indoors, off by server) since the last plan
--    hasCells = the bank has capacity
--    demandW  = what the house asks for; 0 while the controller is off
--    solarW   = what the arrays make now (M.solarWatts); never the billed
--               load, which is 0 while the house is dark
--    dt       = the step, hours
--    sunSince = the sun timer the last plan returned, or nil
--    units    = every unit of the system, { key, rating, auto, run, fault,
--               fuel, since, rest }: fuel is the tank and its own loaded
--               feeds (the tank alone when far); auto nil reads as on, as
--               P.data defaults it
--  }
--  soc    = M.projectSoc for this step (not read with no cells)
--  levels = { start = eff, stop = stop, startSet = start } (M.backupLevels);
--           the rules read start and stop only: in the frost every stop
--           follows the raised start, not the one the player set
--  clock  = the end of this step or slice, world hours
--
--  Returns { start = { key } or {}, stop = { key, ... }, sunSince }. The
--  caller rests every generator it stops and stamps since = clock on the
--  one it starts.
--
--  Stops are decided before starts, a step that stops a generator starts
--  none, and a step starts at most one. So a one-minute tick and a one-hour
--  catch-up slice stage the same generators in the same order.
function M.autoPlan(state, soc, levels, clock)
    local plan = { start = {}, stop = {} }
    state = state or {}
    levels = levels or {}
    local units = state.units or {}
    local dt = max(0, state.dt or 0)
    local demandW = max(0, state.demandW or 0)
    local solarW = max(0, state.solarW or 0)
    local hasCells = state.hasCells == true
    soc = M.finite(soc) and soc or 0
    local startAt = levels.start or 0
    -- In the cold eff climbs the gauge with the floor, and can pass the stop
    -- the player set: Auto would stop a generator under the level it starts
    -- it at, and start it again after every rest. The stop is kept a band
    -- over where Auto really starts; in the warm eff is the set start and
    -- this is the stop as set.
    local stopAt = max(levels.stop or 1, startAt + M.AUTO_BAND)

    -- 1. The sun timer: the arrays alone carry what the house asks for.
    --    With cells a dark array carries nothing, so a generator charging at
    --    night with the controller off goes on charging to its stop. With no
    --    cells the sun alone lights nothing (the controller powers a house
    --    from cells or a running generator, as before generators), so only a
    --    house asking for nothing is carried: a generator left running for
    --    it stops after the hold. Stopped for the sun instead, it left the
    --    house dark from mid-morning until the sun fell short again (final
    --    review, 2026-09-28).
    local covering = (hasCells and solarW > 0 and solarW >= demandW)
        or (not hasCells and demandW <= 0)
    if covering then plan.sunSince = state.sunSince or (clock - dt) end

    -- 2. The master switched off stops every running generator whose own
    --    AUTO is on, its minimum run waived; manual ones run on; nothing
    --    starts.
    if state.master == false then
        for i = 1, #units do
            local u = units[i]
            if u.run == "on" and u.auto ~= false then plan.stop[#plan.stop + 1] = u.key end
        end
        return plan
    end

    -- 3. What is running. A generator kept running by hand counts in every
    --    decision; only AUTO generators past their minimum run can be
    --    stopped, and the next one waits for all of them to get there.
    local nRun, capW, allDone, done = 0, 0, true, {}
    for i = 1, #units do
        local u = units[i]
        if u.run == "on" then
            nRun = nRun + 1
            capW = capW + max(0, u.rating or 0)
            if u.auto ~= false then
                if u.since == nil or clock - u.since >= M.AUTO_MIN_RUN - M.AUTO_EPS then
                    done[#done + 1] = u
                else
                    allDone = false
                end
            end
        end
    end

    -- 4. Stops, never while the house is shed: at the stop level all of
    --    them; else, once the sun has carried the house for the hold and the
    --    bank is a band over where Auto starts, the latest started.
    if not state.shed then
        if hasCells and soc >= stopAt then
            for i = 1, #done do plan.stop[#plan.stop + 1] = done[i].key end
        elseif plan.sunSince and clock - plan.sunSince >= M.AUTO_SUN_HOLD - M.AUTO_EPS
                and (not hasCells or soc >= startAt + M.AUTO_BAND) then
            local last
            for i = 1, #done do
                if last == nil or startedAfter(done[i], last) then last = done[i] end
            end
            if last then plan.stop[1] = last.key end
        end
    end
    if #plan.stop > 0 then return plan end

    -- 5. Starts. With nothing running: at once on a shed, at the start
    --    level, or with no cells while the house asks for anything (the sun
    --    alone lights nothing there). With something running: the next one
    --    once every AUTO generator has done its minimum run, while they and
    --    the sun fall short of the house and the bank is under its stop; the
    --    sun counts then, as M.step takes it first. A generator that dropped
    --    out is replaced at once, with no minimum run, as if it had carried
    --    on to the stop.
    local want
    if nRun == 0 then
        want = state.shed == true or (hasCells and soc <= startAt)
            or (not hasCells and demandW > 0)
    else
        want = allDone and solarW + capW < demandW and (not hasCells or soc < stopAt)
    end
    if not want and state.replace then
        want = (not hasCells and (nRun == 0 and demandW > 0
                                  or nRun > 0 and solarW + capW < demandW))
            or (hasCells and soc < stopAt)
    end
    if not want then return plan end

    -- The fullest tank first (tank and its own feeds); a tie goes to the
    -- smaller node key.
    local pick
    for i = 1, #units do
        local u = units[i]
        local fuel = u.fuel or 0
        if u.auto ~= false and u.run ~= "on" and u.fault == nil and fuel > 0
                and (u.rest == nil or clock >= u.rest - M.AUTO_EPS) then
            if pick == nil or fuel > (pick.fuel or 0)
                    or (fuel == (pick.fuel or 0) and u.key < pick.key) then
                pick = u
            end
        end
    end
    if pick then plan.start[1] = pick.key end
    return plan
end


-------------------------------------------------------------------- almanac

-- The engine's forecast ring is forty slots with today at index ten, so
-- getForecast(offset) answers for -10..+29 and returns nil outside it
-- (ClimateForecaster.java:23-27). Twenty-nine days ahead is a wall in the
-- engine, not a balance decision, and nothing here may exceed it.
M.FORECAST_SPAN = 29

--- Day of year `n` days after `doy`, wrapping the year at 365.
--  The rest of the model works in a fixed 365-day year with no leap handling,
--  so this wraps the same way rather than agreeing with a real calendar.
function M.addDays(doy, n)
    local d = (floor(doy or 1) - 1 + floor(n or 0)) % 365
    if d < 0 then d = d + 365 end
    return d + 1
end

--- How far ahead a reading taken on `anchorDay` can still see on `today`.
--
--  Returns the largest offset in days from today that is still known, so 0
--  means only today survives and -1 means the knowledge has run out. The
--  horizon is fixed at the moment of reading, which is the whole point: the
--  window shrinks by a day per day and closes on its own, so topping it up is
--  a decision the player makes rather than a chore the game reminds them of.
function M.forecastReach(anchorDay, today, span)
    span = span or M.FORECAST_SPAN
    if anchorDay == nil or today == nil then return -1 end
    -- A clock that ran backwards means a different save, not a longer horizon.
    if today < anchorDay then return span end
    local reach = (anchorDay + span) - today
    if reach < 0 then return -1 end
    if reach > span then return span end
    return reach
end

-- A forecast day carries booleans for its weather, not an intensity: the
-- engine samples hourly and records only that a stage occurred (see
-- ClimateForecaster.sampleDay). So the flags are mapped onto the 0..1
-- precipitation fraction planeIrradiance wants. Cloudiness is a real mean and
-- is used as it is.
M.FORECAST_PRECIP = {
    blizzard = 0.75, tropical = 0.70, storm = 0.60, rain = 0.45,
}

--- The precipitation fraction implied by a forecast day's weather flags.
function M.forecastPrecip(sky)
    if not sky then return 0 end
    local p = 0
    if sky.blizzard then p = max(p, M.FORECAST_PRECIP.blizzard) end
    if sky.tropical then p = max(p, M.FORECAST_PRECIP.tropical) end
    if sky.storm    then p = max(p, M.FORECAST_PRECIP.storm) end
    if sky.rain     then p = max(p, M.FORECAST_PRECIP.rain) end
    return p
end

--- Turn one forecast day into the env table the irradiance model reads.
--  `base` supplies anything the forecast does not know about, which in
--  practice is ground snow and the sandbox output scale.
function M.forecastEnv(sky, base)
    local e = {}
    if base then for k, v in pairs(base) do e[k] = v end end
    e.dayOfYear = sky and sky.dayOfYear or e.dayOfYear or 1
    e.cloud = clamp((sky and sky.cloud) or 0, 0, 1)
    e.fog = clamp((sky and sky.fog) or 0, 0, 1)
    e.precipitation = M.forecastPrecip(sky)
    e.temperature = (sky and sky.temperature) or e.temperature or 15
    -- The sun keeps THAT day's engine clock, never the base's: the base is
    -- today, and today's high noon is not the one three weeks out.
    e.noon = sky and sky.noon or nil
    e.dayHours = sky and sky.dayHours or nil
    -- The live daylight scalar is about right now and says nothing about a day
    -- three weeks out, so a forecast is geometry only.
    e.daylight = nil
    e.snowing = nil
    return e
end

--- Predicted whole-day output in Wh for one forecast day.
--  Same path as the live simulation: the forecast is the same physics fed a
--  different sky, not a separate estimate that could disagree with it.
function M.forecastYield(sys, sky, base, stepMinutes)
    return M.forecastDay(sys, M.forecastEnv(sky, base), stepMinutes or 60)
end


------------------------------------------------------------- world seeding

--- A stable pseudo-random value for a map position, in 0..modulus-1.
--
--  Deterministic on purpose: the same building must reach the same answer
--  however many times the question is asked, because two chunks of one
--  building can both be new in the same session and a coin flip would give
--  them different rigs.
--
--  Keyed on the building's COORDINATES and not on its metaId, which is the
--  obvious choice and is wrong. A metaId is a Java long, it arrives in Lua as
--  a double, and it is routinely larger than 2^53. Past that point a double
--  cannot represent consecutive integers, so `id % n` is computed as
--  `id - floor(id/n)*n` on values whose rounding error dwarfs n, and it
--  returns garbage of the same magnitude as the input rather than a small
--  remainder. That failure is silent and it is not obviously a failure: it
--  produced a panel with a condition of 5.1e24, which then sailed through
--  every "is this worn?" comparison as a very healthy panel indeed.
--
--  Map coordinates are at most five digits, so every term here stays far
--  inside the exactly-representable range.
function M.placeRoll(x, y, salt, modulus)
    local hx = floor(math.abs(x or 0)) % 100000
    local hy = floor(math.abs(y or 0)) % 100000
    local h = (hx * 73856093 + hy * 19349663 + floor(salt or 0) * 83492791)
    h = h % 1000003
    return h % max(1, floor(modulus or 1))
end

------------------------------------------------------------------ node keys

--- The identity of one Off-Grid part in the world.
--
--  Coordinates alone are NOT an identity. Two parts of different kinds can
--  legitimately stand on the same square, and keying only on x,y,z meant the
--  second one to stream in silently replaced the first in the registry: an
--  array and a battery bank sharing a tile were one entry, and whichever
--  loaded last won. Under the proximity sweep that was a quiet mis-sum. Under
--  an explicit wiring graph it would be an edge pointing at the wrong
--  component, written into the save and never noticed.
--
--  Kept in the model rather than in the simulation because the wiring graph
--  parses and emits these on both sides of the client/server split, and
--  because a pure function is a function the headless tests can hold.
function M.nodeKey(x, y, z, kind)
    return floor(x or 0) .. "," .. floor(y or 0) .. "," .. floor(z or 0)
           .. "," .. tostring(kind or "?")
end

--- Split a node key back into its parts. Returns nil on anything malformed,
--  because a graph parsed out of save data is untrusted input.
function M.parseNodeKey(k)
    if type(k) ~= "string" then return nil end
    local x, y, z, kind = string.match(k, "^(-?%d+),(-?%d+),(-?%d+),([%a]+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), kind
end


--------------------------------------------------------------- the wiring graph

--  What a system IS, now that it is not "whatever happens to be nearby".
--
--  Every connection the player makes is one edge between two nodes, and a node
--  is M.nodeKey(x, y, z, kind). The whole graph for one system lives on its
--  controller as a single STRING, which is not a stylistic choice: an
--  IsoObject's ModData is copied onto the item when the object is picked up,
--  and that copy DROPS every table-valued field (OG_Place.lua). A table would
--  survive right up until somebody moved their controller, and then quietly
--  not. A string survives, and it survives the rotate path that destroys and
--  rebuilds the object too.
--
--      "12,34,0,array>12,36,0,array;12,36,0,array>13,36,0,controller"
--
--  Edges are separated by ";" and their two ends by ">". The two ends are
--  stored in a fixed order, smaller first, so an edge written A-B and an edge
--  written B-A are the same edge and cannot both exist.
--
--  THE INVARIANT THAT MAKES ALL OF THIS SIMPLE: a part may only ever be wired
--  to something that is ALREADY in a system. So the graph is always a forest
--  rooted at controllers. There are no cycles to detect, no orphans to adopt,
--  and no question about which system a part belongs to, because it got there
--  by walking from exactly one controller. The walk below is still cycle-safe,
--  because the string is save data and save data is untrusted.

M.WIRE_SEP  = ";"
M.WIRE_LINK = ">"

--- Read an edge string. Never errors, and silently drops anything malformed:
--  this is parsing save data, and one corrupt edge must not cost the system.
function M.wireParse(str)
    local edges = {}
    if type(str) ~= "string" or str == "" then return edges end
    for chunk in string.gmatch(str, "[^" .. M.WIRE_SEP .. "]+") do
        local a, b = string.match(chunk, "^(.-)" .. M.WIRE_LINK .. "(.+)$")
        if a and b and a ~= b and M.parseNodeKey(a) and M.parseNodeKey(b) then
            edges[#edges + 1] = { a = a, b = b }
        end
    end
    return edges
end

function M.wireEmit(edges)
    local bits = {}
    for i = 1, #edges do
        bits[#bits + 1] = edges[i].a .. M.WIRE_LINK .. edges[i].b
    end
    return table.concat(bits, M.WIRE_SEP)
end

--- Both ends in a fixed order, so one connection is one edge whichever way
--  round the player made it.
local function ordered(a, b)
    if a > b then return b, a end
    return a, b
end

function M.wireHas(edges, a, b)
    a, b = ordered(a, b)
    for i = 1, #edges do
        if edges[i].a == a and edges[i].b == b then return true end
    end
    return false
end

function M.wireAdd(str, a, b)
    if a == b then return str end
    local edges = M.wireParse(str)
    if M.wireHas(edges, a, b) then return M.wireEmit(edges) end
    local x, y = ordered(a, b)
    edges[#edges + 1] = { a = x, b = y }
    return M.wireEmit(edges)
end

function M.wireRemove(str, a, b)
    a, b = ordered(a, b)
    local edges = M.wireParse(str)
    local out = {}
    for i = 1, #edges do
        if not (edges[i].a == a and edges[i].b == b) then
            out[#out + 1] = edges[i]
        end
    end
    return M.wireEmit(out)
end

--- Every edge touching a node, gone. This is what a part being picked up or
--  smashed means.
function M.wireDrop(str, node)
    local edges = M.wireParse(str)
    local out = {}
    for i = 1, #edges do
        if edges[i].a ~= node and edges[i].b ~= node then
            out[#out + 1] = edges[i]
        end
    end
    return M.wireEmit(out)
end

function M.wireNeighbours(edges, node)
    local out = {}
    for i = 1, #edges do
        if edges[i].a == node then out[#out + 1] = edges[i].b
        elseif edges[i].b == node then out[#out + 1] = edges[i].a end
    end
    return out
end

--- Everything reachable from `root`, in discovery order.
--
--  `alive` is optional and is how a destroyed part removes its whole branch
--  without anyone having to notice it went: if a node cannot be traversed then
--  nothing behind it is reachable either, which is the correct answer rather
--  than a special case. `limit` bounds the walk so a pathological save cannot
--  hang the tick.
function M.wireWalk(edges, root, alive, limit)
    limit = limit or 256
    local seen = { [root] = true }
    local order = { root }
    local head = 1
    while head <= #order and #order < limit do
        local node = order[head]
        head = head + 1
        for i = 1, #edges do
            local e = edges[i]
            local other = nil
            if e.a == node then other = e.b
            elseif e.b == node then other = e.a end
            if other and not seen[other] and (alive == nil or alive(other)) then
                seen[other] = true
                order[#order + 1] = other
            end
        end
    end
    return seen, order
end

--- May `kind` be wired to `targetKind`?
--
--  Arrays chain to arrays, banks chain to banks, and either kind lands on a
--  controller. An array is never wired to a bank: the controller is what sits
--  between generation and storage, and letting a panel hang off a battery rack
--  would say otherwise.
--
--  A transformer lands on the controller or on another transformer: a grid
--  runs out from the controller, transformer to transformer, and never
--  through a panel or a rack.
--
--  A backup generator (2026-09-27) lands on the controller it feeds and on
--  nothing else, and nothing lands on it: it is a leaf, so the controller
--  that starts and stops it is never in doubt. Its lead is a short one
--  (M.cableReach's default).
function M.wireLegal(kind, targetKind)
    if targetKind == "controller" then
        return kind == "array" or kind == "bank" or kind == "transformer"
            or kind == "backup"
    end
    if kind == "array" then return targetKind == "array" end
    if kind == "bank" then return targetKind == "bank" end
    if kind == "transformer" then return targetKind == "transformer" end
    return false
end

--- How long one cable between these two kinds may be. A power line to or
--  from a transformer takes the grid's reach, so transformers can be spaced
--  to keep a street lit end to end; everything else keeps the short run a
--  panel or a battery lead has.
function M.cableReach(kind, targetKind, linkRadius, gridRadius)
    if kind == "transformer" or targetKind == "transformer" then
        return gridRadius or linkRadius
    end
    return linkRadius
end


return M

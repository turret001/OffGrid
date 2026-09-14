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

function M.arraySpec(tier)
    return M.ARRAY_SPEC[tier or "standard"] or M.ARRAY_SPEC.standard
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
    local panels = max(0, array.panels or spec.panels)
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
--  }
--
--  The bank arrives pre-aggregated rather than as a tier, because a real
--  system is a mix: three scrap crates and one sealed cabinet share one state
--  of charge, and the efficiency and depth-of-discharge that govern them are
--  the capacity-weighted blend the caller worked out.
function M.step(sys, dtHours, env)
    local t = {
        generated = 0, consumed = 0, stored = 0, drawn = 0,
        wasted = 0, deficit = 0, irradiance = 0,
        arrayWatts = 0, loadWatts = 0,
        lvdOpened = false, lvdClosed = false, reconnectSoc = 0, socIn = 0,
        floorSoc = 0,
    }
    dtHours = max(0, dtHours or 0)
    local bank = sys.bank or { cells = 0, charge = 0, health = 1 }
    local tempC = env.temperature or 20
    local chargeEff = bank.eff or M.CHARGE_EFF
    local dodFloor = bank.dod or M.DAMAGE_SOC
    local decayRate = bank.decay or M.DAMAGE_RATE
    local invEff = sys.inverterEff or M.INVERTER_EFF
    local harvest = sys.harvest or 1.0

    -- generation
    for i = 1, #(sys.arrays or {}) do
        local a = sys.arrays[i]
        local w, poa = M.arrayOutput(a, env)
        t.arrayWatts = t.arrayWatts + w
        if poa > t.irradiance then t.irradiance = poa end
    end
    t.arrayWatts = t.arrayWatts * invEff * harvest
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
    local cap = bank.capacity or M.bankCapacity(bank, tempC)
    local nominal = bank.nominal
    if nominal == nil then nominal = bank.capacity or M.bankNominalWh(bank) end
    local floorWh = dodFloor * nominal
    local lvd = sys.lvd == true
    local charge = max(0, bank.charge or 0)
    local socIn = cap > 0 and clamp(charge / cap, 0, 1) or 0
    t.socIn = socIn
    if cap > 0 then
        t.floorSoc = clamp(floorWh / cap, 0, 1)
        t.reconnectSoc = clamp(M.reconnectWh(dodFloor, nominal, cap, sys.load) / cap, 0, 1)
    else
        t.floorSoc = dodFloor
        t.reconnectSoc = M.lvdThreshold(dodFloor)
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

    local net = t.generated - t.consumed

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
    -- voltage.
    if not connected and demand > 0 and not lvd and cap > 0
            and socIn <= t.floorSoc + M.FLOOR_EPS and t.generated < demand * dtHours then
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
function M.wireLegal(kind, targetKind)
    if targetKind == "controller" then
        return kind == "array" or kind == "bank"
    end
    if kind == "array" then return targetKind == "array" end
    if kind == "bank" then return targetKind == "bank" end
    return false
end


return M

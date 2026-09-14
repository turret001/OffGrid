--[[ OffGrid -- what the player knows about the sky, and when they learned it.

     Three separate things, deliberately not one. The Knox County Almanac is a
     book that teaches how to read the sky and nothing else. Reading the sky is
     an act that takes time and produces knowledge. The knowledge is a snapshot
     with a date on it, and it goes out of date on its own.

     TWO ENGINE FACTS SHAPE ALL OF THIS.

     First, the ability is stored as a LEARNED RECIPE with an invented name.
     That is not a trick. Item.parseLine splits LearnedRecipes on ';' into a
     plain list with no validation against any registry, learnRecipe appends
     whatever string it is handed, and vanilla teaches Herbalist, Generator and
     the three Mechanics tiers exactly this way -- none of which has a
     craftRecipe record anywhere in the shipped scripts. The list is part of the
     player blob, it is saved on the authority, and on a dedicated server the
     only path into it is a server-side learnRecipe: SyncPlayerFieldsPacket is
     Client-only handling, so a client cannot push one up.

     Second, THE FORECAST IS ONLY TRUE ON THE AUTHORITY. The ring is populated
     on every side, because IsoWorld's call to ClimateManager.init is ungated,
     but the simplex offsets behind it are rolled with Rand.Next in the
     ClimateManager constructor and are never transmitted and never saved on a
     client. So a multiplayer client's forecast is a DIFFERENT WORLD'S weather
     from the first frame, and the day-change roll that would at least keep it
     pointing at today is gated on !GameClient.client, so it stays on the day
     the client loaded. It fails silently and convincingly: forty well-formed
     DayForecasts full of plausible numbers, all of them fiction.

     Not beyond reach, incidentally: ClimateManager.init is public and Lua can
     re-sample the whole ring. Doing that would be worse than useless. It fixes
     the dates and leaves the seeds exactly as wrong, and on the way through it
     clears the world flares and resets the thunderstorm map bounds.

     So the reading is taken on the authority and the result is handed to the
     player. Which is what the feature already is.
]]

require "OffGrid/OG_Model"
require "OffGrid/OG_Env"

OffGrid = OffGrid or {}
OffGrid.Almanac = OffGrid.Almanac or {}
local A = OffGrid.Almanac
local M = OffGrid.Model
local E = OffGrid.Env

-- The taught token. Namespaced because isRecipeKnown(String, boolean) looks the
-- name up in the OLD B41 Recipe registry first, so a collision with some other
-- mod's legacy recipe record would silently change what this check means.
A.TOKEN = "OffGridSkyReading"

-- Where the reading lives on the player. Player modData is part of the same
-- blob as the known-recipe list, so it persists in singleplayer, on a
-- dedicated server, and across a rejoin, where the client is rebuilt from the
-- server's copy.
A.KEY = "ogSky"
A.VERSION = 1

--- Has this player learned to read the sky?
--
--  getKnownRecipes():contains, not isRecipeActuallyKnown: the latter
--  short-circuits to true whenever the admin know-all-recipes cheat is on,
--  which would hand the ability to every admin without the book. Vanilla uses
--  the list form in ISInventoryPane and ISLiteratureUI for the same reason.
--
--  That same cheat is a trap when TESTING this. learnRecipe only appends when
--  isRecipeKnown(name, true) is false, and that call returns true outright
--  while knowAllRecipes is on, so reading the book with the cheat enabled
--  stores nothing at all. The read looks like it worked and the list stays
--  empty. Test it with the cheat off.
function A.knows(playerObj)
    if not playerObj or not playerObj.getKnownRecipes then return false end
    local known = playerObj:getKnownRecipes()
    return known ~= nil and known:contains(A.TOKEN)
end

--- The stored reading, or nil if there is none this version understands.
function A.record(playerObj)
    if not playerObj then return nil end
    local md = playerObj:getModData()
    local rec = md and md[A.KEY]
    if type(rec) ~= "table" then return nil end
    if rec.v ~= A.VERSION or type(rec.d) ~= "table" then return nil end
    if type(rec.day) ~= "number" then return nil end
    return rec
end

--- The largest offset in days from today that is still known. -1 is nothing.
function A.reach(playerObj)
    local rec = A.record(playerObj)
    if not rec then return -1 end
    return M.forecastReach(rec.day, E.dayIndex(), M.FORECAST_SPAN)
end

--- How many days ago the reading was taken.
function A.age(playerObj)
    local rec = A.record(playerObj)
    if not rec then return -1 end
    local elapsed = E.dayIndex() - rec.day
    if elapsed < 0 then return 0 end
    return elapsed
end

--- The sky `offset` days from today, or nil past the horizon.
--
--  The stored table is indexed from the day the reading was TAKEN, so the
--  lookup walks forward by however many days have passed since. That single
--  offset is the whole mechanic: nothing expires, the window simply slides
--  off the end of what was written down.
function A.skyAt(playerObj, offset)
    local rec = A.record(playerObj)
    if not rec then return nil end
    local elapsed = E.dayIndex() - rec.day
    if elapsed < 0 then elapsed = 0 end
    local i = elapsed + (offset or 0) + 1
    local day = rec.d[i]
    if not day then return nil end
    return E.skyOf(day, M.addDays(rec.doy or 1, i - 1), offset or 0)
end

--- Take the reading and write it onto the player. AUTHORITY ONLY.
--
--  transmitModData is what carries it to the owning client: on the server it
--  goes through GameServer.sendObjectModData, which excludes nobody and sends
--  to every connection relevant to the object's position, and a player is
--  always relevant to their own. In singleplayer the same call is the
--  flagForHotSave that makes the write survive without waiting for a full
--  save. The receive is a wholesale replace of that player's table, which is
--  correct here because the authority holds the only copy worth having.
function A.grant(playerObj)
    if not playerObj then return false end
    local days = E.readForecast(M.FORECAST_SPAN)
    if not days then return false end
    local md = playerObj:getModData()
    md[A.KEY] = {
        v = A.VERSION,
        day = E.dayIndex(),
        doy = E.dayOfYear(),
        d = days,
    }
    playerObj:transmitModData()
    return true
end

-------------------------------------------------------------- reading gates

-- Fog thick enough that vanilla itself calls the weather foggy.
A.FOG_LIMIT = 0.4
-- Rain or snow heavy enough to be worth stopping for.
A.PRECIP_LIMIT = 0.2
-- Too dark to read the sky below this. Not the generation gate: arrays stop
-- only at 0.02 and are scaled by daylight x 1.25 above it (OG_Model.arrayOutput).
A.LIGHT_LIMIT = 0.35

--- Why the sky cannot be read right now, as a translation key, or nil.
function A.blocked(playerObj)
    if not playerObj then return "IGUI_OffGrid_SkyBlockedIndoors" end
    if playerObj:getVehicle() then return "IGUI_OffGrid_SkyBlockedIndoors" end
    local sq = playerObj:getCurrentSquare()
    if not sq or not sq:isOutside() or sq:isInARoom() then
        return "IGUI_OffGrid_SkyBlockedIndoors"
    end
    local cm = getClimateManager()
    if cm then
        if (cm:getDayLightStrength() or 0) < A.LIGHT_LIMIT then
            return "IGUI_OffGrid_SkyBlockedDark"
        end
        if (cm:getPrecipitationIntensity() or 0) > A.PRECIP_LIMIT
                or (cm:getFogIntensity() or 0) > A.FOG_LIMIT then
            return "IGUI_OffGrid_SkyBlockedWeather"
        end
    end
    return nil
end

--- A one-word summary of a sky, as a translation key.
function A.skyLabel(sky)
    if not sky then return "IGUI_OffGrid_SkyUnknown" end
    if sky.blizzard then return "IGUI_OffGrid_SkyBlizzard" end
    if sky.tropical or sky.storm then return "IGUI_OffGrid_SkyStorm" end
    if sky.snow and (sky.temperature or 10) <= 1 then return "IGUI_OffGrid_SkySnow" end
    if sky.rain then return "IGUI_OffGrid_SkyRain" end
    if (sky.fog or 0) > A.FOG_LIMIT then return "IGUI_OffGrid_SkyFog" end
    if (sky.cloud or 0) > 0.65 then return "IGUI_OffGrid_SkyOvercast" end
    if (sky.cloud or 0) > 0.25 then return "IGUI_OffGrid_SkyPartly" end
    return "IGUI_OffGrid_SkyClear"
end

return A

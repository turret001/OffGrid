--[[ OffGrid -- the fumes flag, on a multiplayer client.

     An activated generator indoors marks its building toxic, and a solar
     controller emits nothing, so the server clears the flag again
     (OG_System's clearToxicFast). That works for the houses on the map. It
     does not reach a PLAYER-BUILT base: the engine builds those buildings from
     the player's own walls through the region pipeline, which runs everywhere
     except on a dedicated server (IsoRegions.java: `if (!GameServer.server)`),
     and that same pipeline marks the building toxic for any activated
     generator on its squares (WorldRegionToMetaGrid.java:647-649). On the
     server the square has no building at all, so there is nothing for the
     server to clear, and every client inside a player-built base with a
     running controller breathed fumes that never existed: the noxious smell
     moodle and the damage it drives.

     So on a client, and only for a player-built building, the flag is cleared
     locally whenever every activated generator inside is an Off-Grid
     controller. IsoBuilding.setToxic sends nothing from a client
     (IsoBuilding.java:566-570). A real generator anywhere in the building, or
     any square of it not streamed in, leaves the flag alone, and that answer
     is cached for a short while so the walk is not repeated every frame.
     Houses on the map stay the server's to decide.
]]

if not isClient() then return end

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Toxic = OffGrid.Toxic or {}
local T = OffGrid.Toxic
local P = OffGrid.Parts
local try = P.try

local EVERY = 10            -- frames between looks, a sixth of a second
local HOLD = 600            -- frames a "leave it" answer is trusted for

T.frame = 0
T.hold = {}                 -- building key -> frame until which to leave it

--- May the flag on this player-built building come off? True only when an
--  Off-Grid controller is the one generator running in it and every square of
--  its footprint was in memory to be looked at.
function T.onlyOurs(building)
    local def = try(building, "getDef")
    if not def then return false end
    local x1, y1 = try(def, "getX"), try(def, "getY")
    local x2, y2 = try(def, "getX2"), try(def, "getY2")
    local z1, z2 = try(def, "getMinLevel"), try(def, "getMaxLevel")
    if not (x1 and y1 and x2 and y2 and z1 and z2) then return false end
    local cell = getCell and getCell()
    if not cell then return false end
    local ours = false
    for z = z1, z2 do
        for x = x1, x2 - 1 do
            for y = y1, y2 - 1 do
                local sq = cell:getGridSquare(x, y, z)
                -- No square: either nothing is built there at that level, or
                -- the chunk is not in memory, which proves nothing.
                if not sq and not try(cell, "getChunkForGridSquare", x, y, z) then
                    return false
                end
                if sq and try(sq, "getBuilding") == building then
                    local foreign, mine = P.generatorsOn(sq)
                    if foreign then return false end
                    if mine then ours = true end
                end
            end
        end
    end
    return ours
end

function T.check(playerObj)
    local b = try(playerObj, "getCurrentBuilding")
    if not b or not try(b, "isToxic") then return end
    local def = try(b, "getDef")
    if not def or not try(def, "isUserDefined") then return end
    local key = tostring(try(def, "getX")) .. "," .. tostring(try(def, "getY"))
    if (T.hold[key] or -1) > T.frame then return end
    if T.onlyOurs(b) then
        b:setToxic(false)
        T.hold[key] = nil
    else
        T.hold[key] = T.frame + HOLD
    end
end

function T.onTick()
    T.frame = T.frame + 1
    if T.frame % EVERY ~= 0 then return end
    local n = getNumActivePlayers and getNumActivePlayers() or 1
    for i = 0, n - 1 do
        local pl = getSpecificPlayer(i)
        if pl and not pl:isDead() then T.check(pl) end
    end
end

Events.OnTick.Add(T.onTick)

return T

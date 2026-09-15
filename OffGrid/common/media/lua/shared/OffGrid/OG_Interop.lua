--[[ OffGrid -- telling other mods that the charge controller is not a genset.

     The controller IS a real IsoGenerator, which is what buys the mod its power
     delivery, its save/load and its multiplayer sync for free. The cost is that
     any mod which enumerates generators finds it and reasonably assumes petrol.

     LG Extended Electricity (Workshop 3779562002) anticipated exactly this. It
     keeps two allowlists a foreign mod can add itself to, and its own comment
     invites the addition: "A TABLE RATHER THAN AN `if`, because it is not one
     mod... Adding one is a line here." It already carries an entry for Plysken
     Solar Revolution. Off-Grid was not in it.

     Being absent from those tables is currently harmless only by accident:
     every LGEE write path is gated on IsoGenerator.isConnected(), and Off-Grid
     never calls setConnected. But vanilla's OWN generator submenu offers "Plug
     in generator" on any IsoGenerator, so one click by a curious player arms
     LGEE's fuel line (which would pour real petrol into a gauge that is really
     a state-of-charge readout), its building wiring, and a breaker rated off
     ConditionLowerChanceOneIn, which Off-Grid pins at 100000 to defeat vanilla
     wear and which LGEE reads as 22.5 megawatts.

     Registering is cheap, cannot fail loudly, and is written so it costs
     nothing when LGEE is absent.
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Interop = OffGrid.Interop or {}
local I = OffGrid.Interop
local P = OffGrid.Parts

--- Every sprite a controller can ever be drawn as.
--  BOTH states matter. LGEE's first detection leg reads the object's CURRENT
--  texture name, and a controller spends every daylight hour in its "on"
--  sprite, so registering only the "off" row would leave a running system
--  looking exactly like a petrol generator for the half of the day it matters.
function I.controllerSprites()
    local out = {}
    for _, tier in ipairs(P.TIERS.controller) do
        for _, state in ipairs(P.STATES.controller) do
            for _, facing in ipairs(P.FACINGS) do
                local s = P.sprite("controller", "ground", tier, state, facing)
                if s then out[#out + 1] = s end
            end
        end
    end
    return out
end

--- Every item type that resolves to a controller, including the three rotated
--  variants per tier. This is the leg that survives an unresolved sprite,
--  because IsoGenerator.setInfoFromItem writes the full type into modData.
--  P.CONTROLLER_ITEM already carries every facing including S, and the strings
--  are already module-qualified, so this is a straight copy with no prefixing.
function I.controllerTypes()
    local out = {}
    for _, tier in ipairs(P.TIERS.controller) do
        for _, tbl in ipairs({ P.CONTROLLER_ITEM, P.CONTROLLER_ITEM_ON }) do
            local fam = tbl and tbl[tier]
            if fam then
                for _, f in ipairs(P.FACINGS) do
                    if fam[f] then out[#out + 1] = fam[f] end
                end
            end
        end
    end
    return out
end

--- LG Extended Electricity.
function I.registerLGEE()
    if not LGEE then return false end
    local n = 0
    if LGEE.FOREIGN_SPRITE then
        for _, s in ipairs(I.controllerSprites()) do
            LGEE.FOREIGN_SPRITE[s] = true
            n = n + 1
        end
    end
    if LGEE.FOREIGN_TYPE then
        for _, t in ipairs(I.controllerTypes()) do
            LGEE.FOREIGN_TYPE[t] = true
            n = n + 1
        end
    end
    if n > 0 then
        print(string.format("OffGrid: registered %d keys with LG Extended"
                            .. " Electricity so the controller is not billed"
                            .. " as a petrol generator", n))
    end
    return n > 0
end

function I.run()
    if I.done then return end
    I.done = true
    -- Wrapped: an interop courtesy must never be able to take the mod down if
    -- the other mod changes shape.
    local ok, err = pcall(I.registerLGEE)
    if not ok then
        print("OffGrid: LGEE registration skipped (" .. tostring(err) .. ")")
    end
end

-- OnGameBoot rather than OnGameStart, so mod folder load order cannot matter,
-- and LGEE's own cache deliberately does not memoise a negative answer, which
-- is what makes late registration work at all.
Events.OnGameBoot.Add(I.run)

------------------------------------------------------------ the power reach

--- The generator reach the engine lights, in tiles: vanilla's
--  GeneratorTileRange, the same figure OG_System scans the LOADS page over.
function I.generatorRange()
    -- Wrapped: the monitor and the Info card ask this while they draw, and an
    -- error there repeats every frame.
    local ok, v = pcall(function()
        local so = getSandboxOptions()
        local opt = so and so:getOptionByName("GeneratorTileRange")
        return opt and opt:getValue()
    end)
    v = ok and tonumber(v) or nil
    if not v or v < 1 then return 20 end
    return math.floor(v)
end

--- Has LG Extended Electricity taken the generator range over?
--
--  Its "Mod sets generator range" option, on by default, forces the game's
--  own GeneratorTileRange to 1 and lights every running generator's circle
--  through relays of its own. It skips the machines on its FOREIGN lists,
--  which is exactly where I.registerLGEE puts the controller, unless Plysken
--  Solar Revolution is running. So under the takeover a controller powers only
--  the tiles beside it, the LOADS page scans that same radius and lists
--  nothing, and nothing on screen said why (live server, 2026-09-15).
--
--  Judged on the effect as well as the option, the range really at 1: an LGEE
--  from before the option leaves it nil, and a server that also runs Plysken
--  Solar Revolution may light the circle after all, so neither is warned of.
function I.lgeeTakeover()
    if type(LGEE) ~= "table" then return false end
    local sv = P.foreignSandbox("LGExtendedElectricity")
    if not sv then return false end
    if sv.Enabled == false or sv.TakeOverGeneratorRange ~= true then return false end
    if P.foreignSandbox("PSR") then return false end
    return I.generatorRange() <= 1
end

--- Said once a session in the console, which is where a server admin looks.
function I.warnRange()
    if I.warned or not I.lgeeTakeover() then return false end
    I.warned = true
    print("OffGrid: WARNING -- LG Extended Electricity's 'Mod sets generator range'"
          .. " (LGExtendedElectricity.TakeOverGeneratorRange) is on, so the game's"
          .. " generator range is 1 and every solar controller powers only the tiles"
          .. " next to it. Set that option to false in the sandbox settings.")
    return true
end

local function warnRangeSafely()
    local ok, err = pcall(I.warnRange)
    if not ok then
        print("OffGrid: generator range check skipped (" .. tostring(err) .. ")")
    end
end

-- Not at boot: LGEE writes the range while the world loads, and on a client
-- the server's sandbox has not arrived by OnGameBoot.
Events.OnGameStart.Add(warnRangeSafely)
Events.OnServerStarted.Add(warnRangeSafely)

return I

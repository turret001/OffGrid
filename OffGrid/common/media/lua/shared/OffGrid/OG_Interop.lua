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

return I

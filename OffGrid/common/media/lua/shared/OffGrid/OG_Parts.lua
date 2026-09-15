--[[ OffGrid -- identifying and describing the world parts.

     Shared, because the client draws these and the server simulates them and
     both have to agree on what a given world object is.

     Identity comes from the sprite name. The tilesheet is laid out one row per
     (kind, mount, tier, state) and one column per facing, so `offgrid_01_101`
     is exactly "a premium ground battery bank, LEDs green, facing S" and
     nothing else needs storing to know that. This table MUST stay in step with
     tools/og_taxonomy.py -- tests/test_pack.py fails if they drift.
]]

require "OffGrid/OG_Model"

OffGrid = OffGrid or {}
OffGrid.Parts = OffGrid.Parts or {}
local P = OffGrid.Parts

---------------------------------------------------- engine and sandbox access

--- Call an optional method: nil, not an error, when the object is nil, lacks
--  the method, or the call throws. For engine surfaces that differ between
--  builds and for objects that may already have left the world.
function P.try(obj, method, ...)
    if not obj or not obj[method] then return nil end
    local ok, v = pcall(obj[method], obj, ...)
    if ok then return v end
    return nil
end

--- Every sandbox option the mod declares, at the default
--  media/sandbox-options.txt gives it. tests/test_content.py fails if the two
--  drift, or if anything reads an option not listed here.
P.SANDBOX_DEFAULTS = {
    LinkRadius = 12,
    OutputScale = 100,
    BankScale = 100,
    SnowRate = 100,
    SoilRate = 100,
    SimulateLoad = true,
    DegradeBank = true,
    PickupLock = 3,
}

--- A sandbox option's value, or its declared default while SandboxVars does
--  not carry it yet (the main menu, a world from before the option existed).
function P.sandbox(name)
    local sv = SandboxVars and SandboxVars.OffGrid
    local v = sv and sv[name]
    if v == nil then return P.SANDBOX_DEFAULTS[name] end
    return v
end

--- ANOTHER mod's sandbox page, as the table SandboxVars holds, or nil. Read
--  here so this file stays the one place that touches SandboxVars; it has no
--  defaults to fall back on, because those options are not ours to declare.
function P.foreignSandbox(page)
    local sv = SandboxVars and SandboxVars[page]
    if type(sv) ~= "table" then return nil end
    return sv
end

--- The bank capacity multiplier, and the only reader of it. Installing and
--  removing batteries, the simulation, the seeder and every panel must agree
--  on how big a rack is, or a charge is kept against one capacity and handed
--  back against another. Anything but a positive number (a hand-edited
--  SandboxVars) reads as 100%.
function P.bankScale()
    local v = P.sandbox("BankScale")
    if type(v) ~= "number" or v <= 0 then return 1 end
    return v / 100
end

P.TILESET = "offgrid_01"
P.COLS = 4

-- Column order inside every row, and the reverse lookup.
P.FACINGS = { "E", "S", "W", "N" }
P.FACING_INDEX = { E = 0, S = 1, W = 2, N = 3 }

-- APPEND ONLY, and in the same order as og_taxonomy.py: a sprite index is
-- row * COLS + facing, so a kind inserted anywhere but the end repoints
-- every object already standing in a save.
P.KINDS = { "array", "bank", "controller" }
P.MOUNTS = {
    array = { "ground", "flat" },
    bank = { "ground", "wall" },
    controller = { "ground" },
}
P.TIERS = {
    array = { "makeshift", "standard", "premium" },
    bank = { "makeshift", "standard", "premium" },
    controller = { "basic", "mppt" },
}
P.STATES = {
    array = { "clear", "snow", "cracked" },
    controller = { "off", "on" },
    -- bank has no flat list: see P.statesFor.
}

--- How many cells each bank grade holds, by mount. Mirrors
--  og_taxonomy.BANK_CELLS and M.bankCells; all three must agree or the sheet
--  and the game disagree about what a sprite name means.
P.BANK_CELLS = {
    ground = { makeshift = 3, standard = 6, premium = 8 },
    wall   = { makeshift = 2, standard = 3, premium = 4 },
}

--- The sprite states one exact object has.
--
--  A battery rack shows what is IN it, so its states are its possible cell
--  counts, c0 through cN, and how many it can hold depends on grade and mount.
--  Everything else keeps a flat list per kind.
function P.statesFor(kind, mount, tier)
    if kind ~= "bank" then return P.STATES[kind] end
    local out = {}
    local n = (P.BANK_CELLS[mount] or {})[tier] or 0
    for i = 0, n do out[#out + 1] = "c" .. i end
    return out
end

--- Build the row table in exactly the order og_taxonomy.py emits it.
local function buildRows()
    local rows = {}
    for _, kind in ipairs(P.KINDS) do
        for _, mount in ipairs(P.MOUNTS[kind]) do
            for _, tier in ipairs(P.TIERS[kind]) do
                for _, state in ipairs(P.statesFor(kind, mount, tier)) do
                    rows[#rows + 1] = { kind = kind, mount = mount,
                                        tier = tier, state = state }
                end
            end
        end
    end
    return rows
end

P.ROWS = buildRows()

-- Reverse index: "kind|mount|tier|state" -> row number (1-based).
P.ROW_OF = {}
for i, r in ipairs(P.ROWS) do
    P.ROW_OF[r.kind .. "|" .. r.mount .. "|" .. r.tier .. "|" .. r.state] = i
end

--- The item handed to IsoGenerator.new for each controller tier and facing.
--  One record per combination, because getGeneratorSpriteToType() keys its map
--  on a single WorldObjectSprite per item, and a facing that misses the map
--  falls through to Base.Generator -- restoring the radius-20 zombie magnet
--  that SoundRadius = 1 exists to remove.
--  Sixteen records, not eight. IsoGenerator.getGeneratorItemType() keys off
--  the object's CURRENT sprite, and getGeneratorSpriteToType() is built from
--  one WorldObjectSprite per generator-tagged item, so a sprite with no record
--  resolves to Base.Generator and its radius-20 world sound. The controller
--  swaps sprite when it starts working, so the "on" state needs records too or
--  the mod is loud for precisely the hours it advertises silence.
P.CONTROLLER_ITEM = {
    basic = { E = "Base.OffGridControllerE", S = "Base.OffGridController",
              W = "Base.OffGridControllerW", N = "Base.OffGridControllerN" },
    mppt  = { E = "Base.OffGridControllerMPPTE", S = "Base.OffGridControllerMPPT",
              W = "Base.OffGridControllerMPPTW", N = "Base.OffGridControllerMPPTN" },
}

--  The same eight for the running state. These are never craftable, never in
--  loot and never carried; they exist only to keep that map complete.
P.CONTROLLER_ITEM_ON = {
    basic = { E = "Base.OffGridControllerOnE", S = "Base.OffGridControllerOn",
              W = "Base.OffGridControllerOnW", N = "Base.OffGridControllerOnN" },
    mppt  = { E = "Base.OffGridControllerMPPTOnE", S = "Base.OffGridControllerMPPTOn",
              W = "Base.OffGridControllerMPPTOnW", N = "Base.OffGridControllerMPPTOnN" },
}

--- The inventory item behind each (kind, mount, tier). Mirrors T.ITEM in
--  tools/og_taxonomy.py, which is what stamps CustomItem into the tiledef.
P.ITEM = {
    array = {
        ground = { makeshift = "Base.OffGridArraySalvage",
                   standard  = "Base.OffGridArray",
                   premium   = "Base.OffGridArrayMono" },
        flat   = { makeshift = "Base.OffGridFlatSalvage",
                   standard  = "Base.OffGridFlat",
                   premium   = "Base.OffGridFlatMono" },
    },
    bank = {
        ground = { makeshift = "Base.OffGridBankCrate",
                   standard  = "Base.OffGridBank",
                   premium   = "Base.OffGridBankSealed" },
        wall   = { makeshift = "Base.OffGridWallCrate",
                   standard  = "Base.OffGridWallBank",
                   premium   = "Base.OffGridWallSealed" },
    },
    controller = {
        ground = { basic = "Base.OffGridController",
                   mppt  = "Base.OffGridControllerMPPT" },
    },
}

--- Every item record the mod declares, for the boot self-check.
function P.allItems()
    local out = {}
    for kind, byMount in pairs(P.ITEM) do
        for mount, byTier in pairs(byMount) do
            for tier, item in pairs(byTier) do
                out[#out + 1] = item
                if kind == "controller" then
                    -- Every rotated and every running variant. These are the
                    -- records whose absence would be invisible and would make
                    -- the controller resolve to Base.Generator at radius 20.
                    local fam = P.CONTROLLER_ITEM[tier]
                    if fam then
                        for _, f in ipairs({ "E", "W", "N" }) do
                            out[#out + 1] = fam[f]
                        end
                    end
                    local on = P.CONTROLLER_ITEM_ON[tier]
                    if on then
                        for _, f in ipairs(P.FACINGS) do
                            out[#out + 1] = on[f]
                        end
                    end
                end
            end
        end
    end
    out[#out + 1] = "Base.OffGridManual"
    out[#out + 1] = "Base.OffGridManualAdv"
    return out
end

--- The item a placed object corresponds to, or nil.
function P.itemFor(kind, mount, tier)
    local byMount = P.ITEM[kind]
    local byTier = byMount and byMount[mount]
    return byTier and byTier[tier] or nil
end

-------------------------------------------------------------------- sprites

--- Sprite name for a variant, or nil if that combination does not exist.
function P.sprite(kind, mount, tier, state, facing)
    local row = P.ROW_OF[kind .. "|" .. mount .. "|" .. tier .. "|" .. state]
    if not row then return nil end
    local fi = P.FACING_INDEX[facing or "S"] or 1
    return P.TILESET .. "_" .. ((row - 1) * P.COLS + fi)
end

--- Decompose one of the mod's sprite names, or nil if it is not ours.
function P.spriteInfo(name)
    if not name then return nil end
    local idx = string.match(name, "^" .. P.TILESET .. "_(%d+)$")
    if not idx then return nil end
    idx = tonumber(idx)
    local r = P.ROWS[math.floor(idx / P.COLS) + 1]
    if not r then return nil end
    return { kind = r.kind, mount = r.mount, tier = r.tier, state = r.state,
             facing = P.FACINGS[(idx % P.COLS) + 1], index = idx }
end

--- Everything the mod knows about an object, or nil if it is not one of ours.
--
--  Sprite name first, ModData as the fallback. The fallback is not paranoia:
--  `IsoObject.new(square, tile)` -- the two-argument form -- does NOT use the
--  named sprite. It calls IsoSprite.CreateSprite + LoadFramesNoDirPageSimple
--  and builds an anonymous one (IsoObject.java:361-367), so the object renders
--  perfectly while getSprite():getName() comes back nil.
function P.describe(obj)
    if not obj or not obj.getSprite then return nil end
    local spr = obj:getSprite()
    if spr then
        local name = spr:getName()
        local info = P.spriteInfo(name)
        if info then return info end
        -- Rubble, not a part. A fire swaps a burning solidtrans object's
        -- sprite for a *_burnt_* one and KEEPS the object and its ModData
        -- (IsoGridSquare.BurnWalls), which is what happens to a seeded yard
        -- rig. The fallback below would still see the kind stamped in its
        -- ModData, so the ash went on generating, and the next state change
        -- put the panel's sprite back. The engine's own test for rubble.
        if name and string.find(name, "_burnt_", 1, true) then return nil end
    end
    local md = obj.getModData and obj:getModData()
    local d = md and md.offgrid
    if d and d.kind then
        -- "off" is not a bank state any more; banks are counted, c0 up.
        return { kind = d.kind, mount = d.mount or "ground",
                 tier = d.tier or "standard",
                 state = d.state or (d.kind == "bank" and "c0" or "off"),
                 facing = d.facing or "S" }
    end
    return nil
end

function P.partOf(obj)
    local info = P.describe(obj)
    return info and info.kind or nil
end

--- The running generators on a square: the first one that is NOT an Off-Grid
--  controller (or nil), and whether a running controller is there too.
--
--  Every generator on the square, not getGenerator(), which returns only the
--  first: nothing stops two sharing a tile, and the engine marks a building
--  toxic for each of them. A generator is a special object
--  (IsoGridSquare.getSpecialObjects); instanceof filters out the light
--  switches and appliances in the same list that also answer isActivated().
function P.generatorsOn(sq)
    if not sq then return nil, false end
    local list = sq:getSpecialObjects()
    local ours = false
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        if o and instanceof(o, "IsoGenerator") and o:isActivated() then
            if P.partOf(o) == "controller" then
                ours = true
            else
                return o, ours
            end
        end
    end
    return nil, ours
end

--- The Off-Grid object of a given kind standing on a square, or nil.
--
--  A wiring edge is a pair of coordinates, so both sides of the mod need to
--  turn a coordinate back into the thing that is standing there. Returns nil
--  for a square that is not streamed in, which callers that care about the
--  difference between "gone" and "not loaded" have to resolve themselves.
function P.objectAt(x, y, z, kind)
    local sq = getSquare(x, y, z)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if P.partOf(o) == kind then return o end
    end
    return nil
end

function P.facingOf(obj)
    local info = P.describe(obj)
    return info and info.facing or "S"
end

-------------------------------------------------------------------- cells

--- Bring a rack's contents up to the per-cell shape.
--
--  Before this release a rack stored a list of type strings plus ONE health
--  for the whole rack, so a battery's own condition was destroyed on the way
--  in and invented at full on the way out. A cell now carries its own health,
--  which IS the car battery's condition over its ConditionMax, and the rack's
--  health is the mean of its cells.
--
--  Every migrated cell inherits the rack's stored health, so capacity comes
--  out at exactly the old number and nobody's rack moves under them on update.
--  A very old save with a count but no cellTypes fills with CarBattery1, which
--  is what the removal path already used as its fallback.
function P.migrateCells(d)
    if d.cellList ~= nil then return false end
    local n = math.floor(d.cells or 0)
    if n < 0 then n = 0 end
    local health = d.health
    if health == nil then health = 1 end
    local types = d.cellTypes or {}
    local list = {}
    for i = 1, n do
        list[i] = { id = i, type = types[i] or "Base.CarBattery1",
                    health = health }
    end
    d.cellList = list
    d.nextCellId = n + 1
    -- Both are gone for good. d.health is now derived by P.bankHealth, and
    -- leaving a stale copy behind is exactly how a reader ends up silently
    -- using a number nothing maintains.
    d.cellTypes = nil
    d.health = nil
    return true
end

--- The rack's health: the mean of its cells.
--
--  An empty rack reads 1, because there is nothing in it to be damaged. The
--  damage lives in the batteries and leaves with them, which is the whole
--  point of the per-cell shape.
function P.bankHealth(d)
    local list = d.cellList
    if not list or #list == 0 then return 1 end
    return OffGrid.Model.cellSum(list) / #list
end

--- Summed cell health, which is what capacity is actually proportional to.
function P.cellSum(d)
    return OffGrid.Model.cellSum(d.cellList)
end

--- The cell carrying this id, or nil. Positions shift when a cell is pulled,
--  so nothing outside the panel's own draw loop should key on an index.
function P.findCell(d, cellId)
    if cellId == nil then return nil end
    local list = d.cellList or {}
    for i = 1, #list do
        if list[i].id == cellId then return list[i], i end
    end
    return nil
end

--- Which bay each cell sits in: bays[1..cap] = cell, or nil for an empty bay.
--
--  A cell keeps the bay it was dropped on (cell.bay). Listed in order with
--  the bays compacted, a battery dropped on bay 2 of an empty rack showed in
--  bay 1, and bay 2, still under the pointer, said "Empty bay" (live test,
--  2026-09-14). A cell with no bay, or with one out of range or already
--  taken, fills the first empty bay in list order, which is exactly the
--  layout every rack had before, so a rack from an older save opens as it
--  always did. Removal stays keyed on the cell id; the bay is only where it
--  is drawn.
function P.bayLayout(list, cap)
    local bays, loose = {}, {}
    list = list or {}
    for i = 1, #list do
        local c, b = list[i], list[i].bay
        if type(b) == "number" and b >= 1 and b <= cap and b == math.floor(b)
                and not bays[b] then
            bays[b] = c
        else
            loose[#loose + 1] = c
        end
    end
    local n = 1
    for i = 1, #loose do
        while bays[n] do n = n + 1 end
        if n > cap then break end
        bays[n] = loose[i]
    end
    return bays
end

--- Write down the bay every cell is drawn in, before the rack changes.
--
--  A cell from an older save has no bay and sits where list order puts it,
--  so taking the cell before it out would slide it one bay left. Pinned
--  first, every battery stays where the player saw it.
function P.pinBays(list, cap)
    local bays = P.bayLayout(list, cap)
    for b = 1, cap do
        if bays[b] then bays[b].bay = b end
    end
end

--- The bay a battery goes into: the one it was dropped on while that is
--  free, else the first free one (somebody filled it while the action ran, or
--  the drop named no bay). Nil when the rack is full.
function P.freeBay(list, cap, wanted)
    local bays = P.bayLayout(list, cap)
    if type(wanted) == "number" and wanted >= 1 and wanted <= cap
            and wanted == math.floor(wanted) and not bays[wanted] then
        return wanted
    end
    for b = 1, cap do
        if not bays[b] then return b end
    end
    return nil
end

--- Apply one tick's health delta to every cell in the rack.
--
--  Returns the MEAN delta actually achieved, which is not always the delta
--  asked for: a cell already at 1.0 absorbs none of a recovery, and the
--  equalise biller pays only for what landed. The 0.25 floor never LIFTS a
--  cell -- a battery installed at 8% condition is an 8% cell, and the old
--  unconditional clamp quietly healed it to 25% on the first tick that
--  touched the rack.
function P.applyBankHealth(d, delta)
    local list = d.cellList or {}
    if #list == 0 then return 0 end
    local before = P.bankHealth(d)
    for i = 1, #list do
        local h = list[i].health or 1
        local lo = math.min(0.25, h)
        list[i].health = OffGrid.Model.clamp(h + delta, lo, 1)
    end
    return P.bankHealth(d) - before
end

-------------------------------------------------------------------- state

--- Per-object persisted state, with defaults filled in on first touch.
--  IsoObject ModData is written into the chunk save, so this survives a
--  reload without the mod keeping a registry of its own.
function P.data(obj)
    local md = obj:getModData()
    if md.offgrid == nil then md.offgrid = {} end
    local d = md.offgrid
    local info = P.describe(obj)
    if not info then return d end

    -- remember the identity, so an object whose sprite went anonymous is
    -- still recognised on the next pass
    d.kind = info.kind
    d.mount = info.mount
    d.tier = info.tier
    d.facing = info.facing
    if d.state == nil then d.state = info.state end

    if info.kind == "array" then
        if d.panels == nil then
            d.panels = OffGrid.Model.arraySpec(info.tier).panels
        end
        if d.soiling == nil then d.soiling = 0 end
        if d.snow == nil then d.snow = 0 end
        if d.condition == nil then d.condition = 100 end
    elseif info.kind == "bank" then
        if d.charge == nil then d.charge = 0 end
        P.migrateCells(d)
        -- ONE authority for the count. Everything downstream reads d.cells on
        -- the hot path and d.cellList for the detail, and they cannot drift
        -- because the count is derived here on every touch.
        d.cells = #d.cellList
    elseif info.kind == "controller" then
        if d.online == nil then d.online = false end
        if d.lastHour == nil then d.lastHour = -1 end
        if d.load == nil then d.load = 0 end
        if d.trip == nil then d.trip = false end
    end
    return d
end

--- What vanilla's moveable round trip leaves on a placed part's ModData.
--
--  Picking up an IsoThumpable saves its name, health, sound, colour, light
--  and padlock onto the item, and a deep copy of its whole ModData
--  (ISMoveableSpriteProps.saveThumpableParameters, 42.20.4 lines 1204-1231);
--  placing the item copies that copy's keys back onto the new object, and
--  then every key of the item's ModData, the copy itself included, when the
--  item carries no movableData (restoreThumpableParameters 1233-1253,
--  placeMoveableInternal 2241-2243 and 2273-2282). Racks and panels are
--  IsoThumpables and a rotation is a pick-up and a place, so every turn or
--  move stored the part's data one level deeper inside itself: 53, 82 and
--  111 entries after three turns of one rack (live test, 2026-09-14).
--  Nothing reads these keys off an object; the restore reads the item's own
--  copy. itemCondition is not listed, because a non-thumpable pick-up reads
--  it back (1310-1312), and neither is anything another mod wrote.
P.VANILLA_CARRIED = { "modData", "name", "health", "maxHealth", "thumpSound", "color",
                      "lightSource", "canBeLockedByPadlock", "lockedByKeyId",
                      "lockedByCode" }

--- Drop those keys from an Off-Grid part's ModData; a part the mod owns
--  only (one carrying an `offgrid` table). Returns whether it removed any.
function P.scrubCarried(obj)
    local md = obj and obj.getModData and obj:getModData()
    if not md or type(md.offgrid) ~= "table" then return false end
    local changed = false
    for i = 1, #P.VANILLA_CARRIED do
        local k = P.VANILLA_CARRIED[i]
        if md[k] ~= nil then
            md[k] = nil
            changed = true
        end
    end
    return changed
end

--- How many car batteries this particular bank can hold.
function P.cellCap(obj)
    local info = P.describe(obj)
    if not info or info.kind ~= "bank" then return 0 end
    return OffGrid.Model.bankCells(info.tier, info.mount)
end

--- Swap an object to the sprite for `state`, keeping kind, mount, tier and
--  facing. No-op if it is already showing it, because setSprite dirties the
--  chunk for a resave.
function P.setState(obj, state)
    if not obj then return false end
    local info = P.describe(obj)
    if not info then return false end
    local want = P.sprite(info.kind, info.mount, info.tier, state, info.facing)
    if not want then return false end
    local cur = obj:getSprite() and obj:getSprite():getName()
    if cur == want then return false end
    -- BOTH calls, in this order, and neither is redundant.
    --
    -- setSprite(String) builds an ANONYMOUS sprite: IsoSprite.CreateSprite +
    -- LoadSingleTexture, so getSprite():getName() comes back nil afterwards.
    -- It is still wanted, because it is also what sets the object's `tile` and
    -- `spriteName` fields, which the network path and re-identification use.
    --
    -- Corrected 2026-08-26: an earlier note here claimed `spriteName` is what
    -- IsoObject.save writes. It is not. save() writes the sprite's numeric id
    -- (`output.putInt(this.sprite == null ? -1 : this.sprite.id)`,
    -- IsoObject.java:1315), which is why setSpriteFromName below is the call
    -- that actually decides what persists: it swaps in the REGISTERED sprite
    -- out of IsoSpriteManager, and only a registered sprite has a usable id.
    -- Do not drop it on the grounds that setSprite already set the name.
    --
    -- setSpriteFromName(String) then swaps that anonymous sprite for the
    -- registered one out of IsoSpriteManager, which restores the name. That
    -- matters far beyond cosmetics: IsoGenerator.getGeneratorItemType() looks
    -- the CURRENT sprite name up in getGeneratorSpriteToType(), and a miss
    -- returns "Base.Generator" -- whose SoundRadius is 20. A controller with a
    -- nameless sprite is a controller that broadcasts a petrol generator's
    -- world sound, which is the one thing this mod exists not to do.
    obj:setSprite(want)
    if obj.setSpriteFromName then obj:setSpriteFromName(want) end
    local md = obj.getModData and obj:getModData()
    if md then
        md.offgrid = md.offgrid or {}
        md.offgrid.kind = info.kind
        md.offgrid.mount = info.mount
        md.offgrid.tier = info.tier
        md.offgrid.facing = info.facing
        md.offgrid.state = state
    end
    if obj.transmitUpdatedSpriteToClients and isServer() then
        obj:transmitUpdatedSpriteToClients()
    end
    return true
end

--- Which bank sprite a rack should be showing: the one with its cell count.
--
--  `soc` is no longer part of it. The sprite carries how many batteries are in
--  the rack, which is the thing worth seeing from across a room, and the charge
--  is on the controller's monitor and in the Info panel to the nearest per cent.
function P.bankState(d, soc)
    local n = math.floor(d.cells or 0)
    if n < 0 then n = 0 end
    -- Clamp to what this grade holds. Over capacity should be impossible, but
    -- a state with no sprite makes P.setState a silent no-op, so the rack
    -- would quietly stop tracking its own contents rather than say anything.
    local cap = (P.BANK_CELLS[d.mount or ""] or {})[d.tier or ""]
    if cap and n > cap then n = cap end
    return "c" .. n
end

--- Which array sprite an array should be showing.
function P.arrayState(d)
    if (d.snow or 0) >= 0.15 then return "snow" end
    if (d.condition or 100) <= 35 then return "cracked" end
    return "clear"
end

------------------------------------------------------------------ the world

--- Walk every square in a cube around a point, calling fn(square).
--  `zRange` is levels either side. Squares in unloaded chunks come back nil
--  and are skipped, which is the correct behaviour: the mod should not
--  simulate what the engine is not streaming.
function P.forEachSquare(x, y, z, radius, zRange, fn)
    local r2 = radius * radius
    for dz = -zRange, zRange do
        local zz = z + dz
        if zz >= -32 and zz <= 31 then
            for dy = -radius, radius do
                for dx = -radius, radius do
                    if dx * dx + dy * dy <= r2 then
                        local sq = getSquare(x + dx, y + dy, zz)
                        if sq then fn(sq) end
                    end
                end
            end
        end
    end
end

--- Every Off-Grid object of `kind` within `radius` of a square.
function P.findParts(square, radius, zRange, kind)
    local found = {}
    if not square then return found end
    P.forEachSquare(square:getX(), square:getY(), square:getZ(), radius, zRange,
        function(sq)
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if P.partOf(o) == kind then found[#found + 1] = o end
            end
        end)
    return found
end

---------------------------------------------------------------- inventory

--- A rack's cell as a car battery item, at `fill` charge and `cond`
--  condition (both 0..1). Nil only if not even a plain car battery can be
--  made. Every road a cell leaves a rack by comes through here: a battery
--  taken out by hand, a rack picked up, a rack destroyed.
--
--  A type that no longer resolves (a modded battery whose mod was removed)
--  comes back as Base.CarBattery1 at the same charge and condition. By the
--  time a cell becomes an item it is already out of the rack, so handing back
--  nothing would destroy both the battery and its share of the charge; this
--  keeps the value and loses only the branding.
--
--  setCurrentUsesFloat, not setUsedDelta: the pair is asymmetric on
--  InventoryItem (only the setter half of setUsedDelta exists, and only on
--  DrainableComboItem), so the mod uses the float accessors, which are
--  declared on the base class in both directions. See itemFill in OG_Actions.
function P.cellItem(batteryType, fill, cond)
    local M = OffGrid.Model
    local wanted = batteryType or "Base.CarBattery1"
    local item = instanceItem(wanted)
    if not item and wanted ~= "Base.CarBattery1" then
        print("OffGrid: cell type " .. tostring(wanted)
              .. " no longer exists, substituting Base.CarBattery1")
        item = instanceItem("Base.CarBattery1")
    end
    if not item then return nil end
    if item.setCurrentUsesFloat then
        item:setCurrentUsesFloat(M.clamp(fill or 0, 0, 1))
    end
    if item.setCondition and cond ~= nil then
        local maxC = item.getConditionMax and item:getConditionMax() or 100
        item:setCondition(math.floor(M.clamp(cond, 0, 1) * maxC + 0.5))
    end
    return item
end

--- Does this character have a screwdriver, counting bags and modded ones?
--
--  ONE copy of this, on purpose. It existed twice and the copies drifted: the
--  pickup gate passed `ItemTag.SCREWDRIVER` while the repair context menu
--  passed the string `"Screwdriver"`, which threw
--
--      expected argument of type ItemTag, got String
--
--  the moment a player right-clicked a damaged part while carrying both scrap
--  and screws. That is the `elseif` branch of the repair option, which is why
--  it took until a subscriber found it.
--
--  There has never been a String overload to lean on: 42.20.2 already declared
--  only `containsTagRecurse(zombie.scripting.objects.ItemTag)`, so this was
--  wrong long before 42.20.4 and is not a regression from that update. The
--  string is seductive precisely because it IS the tag's name --
--  `SCREWDRIVER = registerBase("Screwdriver")` -- but the name is not the
--  argument.
--
--  ItemTag's statics are assigned in the class initialiser, so they are
--  populated well before Lua expose and `ItemTag.SCREWDRIVER` is reliable. The
--  guard and the plain-type fallback stay regardless: this decides whether
--  someone may repair their own kit, and failing open beats locking them out.
--
--  Returns false when there is no inventory to read. The pickup gate wants the
--  opposite in that case, so it keeps its own `if not inv then return true end`
--  ahead of this call rather than pushing that policy in here.
function P.hasScrewdriver(character)
    if not character then return false end
    local ok, inv = pcall(function() return character:getInventory() end)
    if not ok or not inv then return false end

    if ItemTag and ItemTag.SCREWDRIVER and inv.containsTagRecurse then
        local okTag, has = pcall(inv.containsTagRecurse, inv, ItemTag.SCREWDRIVER)
        if okTag then return has == true end
    end

    local okType, hasType = pcall(inv.contains, inv, "Screwdriver")
    return okType and hasType == true
end

--------------------------------------------------------------------- text

--- getText with positional {1}/{2} substitution.
--
--  A correction to an earlier revision of this comment: `getText(key, a, b)`
--  DOES substitute. The Lua global is genuinely varargs
--  (LuaManager.java:7174) and %1..%9 are the engine's own placeholder syntax,
--  rewritten to %1$s by Translator.formatFixer at load time
--  (Translator.java:167, :895), for mod translation directories too. The old
--  claim came from testing a string that carried no placeholder in the
--  engine's syntax at all, so nothing substituted and the wrong lesson stuck.
--
--  Brace tokens are kept anyway because they also work -- Java's formatter
--  ignores them, so getText returns them untouched and the substitution
--  happens here -- and because 244 shipped strings is a lot of churn for a
--  change no player would see. What IS still true and still load-bearing:
--  a bare per-cent throws UnknownFormatConversionException, because
--  FORMAT_TOKEN matches only %% and %1..%9. build_translations escapes them.
--  Braces are not Lua pattern metacharacters either, so gsub takes them as-is.
function P.txt(key, ...)
    local s = getText(key)
    if s == nil then return tostring(key) end
    for i = 1, select("#", ...) do
        local v = tostring((select(i, ...)))
        -- gsub reads % in the REPLACEMENT as a capture reference and throws
        -- "invalid use of '%'", so anything heading into one gets escaped.
        v = string.gsub(v, "%%", "%%%%")
        s = string.gsub(s, "{" .. i .. "}", v)
    end
    return s
end

--- A counted phrase: "1 bank", "2 banks".
--
--  English needs the singular after 1, and a key holding "{1} banks" printed
--  "1 banks" on the Info card (live test, 2026-09-14). So every counted key
--  has a twin ending in One, picked when the count is exactly 1. Turkish
--  never puts a noun in the plural after a number ("1 akü", "3 akü"), so its
--  One key carries the same words as the other. The count picks the key; the
--  arguments fill it, the count alone when none are given.
function P.count(key, n, ...)
    local k = (n == 1) and (key .. "One") or key
    if select("#", ...) > 0 then return P.txt(k, ...) end
    return P.txt(k, n)
end

--- "3 arrays, 1 module": a system's arrays and the modules they carry.
function P.arrayLine(arrays, modules)
    return P.txt("IGUI_OffGrid_ArrayLine",
                 P.count("IGUI_OffGrid_ArrayCount", arrays or 0),
                 P.count("IGUI_OffGrid_ModuleCount", modules or 0))
end

-- North is -y and east is +x (IsoDirections.java:9-16, N is (0, -1)), the
-- compass the in-game map is drawn to and the one a panel's facing names.
local TOWARD = {
    north = "IGUI_OffGrid_DirNorth", south = "IGUI_OffGrid_DirSouth",
    east = "IGUI_OffGrid_DirEast", west = "IGUI_OffGrid_DirWest",
    up = "IGUI_OffGrid_DirUp", down = "IGUI_OffGrid_DirDown",
}

--- How to get from one square to another: "1 tile south, 3 tiles east,
--  1 floor up", or "same tile".
--
--  Whole tiles along each axis, not a straight-line distance. A row of
--  arrays three tiles east of a controller is three parts at the same
--  rounded distance and the same rough bearing, and the cut menu listed them
--  as the same "Solar Array" (live test, 2026-09-14). A connection is a node,
--  x,y,z,kind (M.nodeKey), and two parts of one name are one kind, so the
--  offset is what tells them apart. Levels count too: a controller on the
--  roof is not at the coordinates a player on the ground floor walks to.
function P.offsetText(fx, fy, fz, tx, ty, tz)
    local bits = {}
    local function add(n, plus, minus, floors)
        n = math.floor((n or 0) + 0.5)
        if n == 0 then return end
        local m = math.abs(n)
        bits[#bits + 1] = P.txt("IGUI_OffGrid_Toward",
                                floors and P.count("IGUI_OffGrid_FloorCount", m)
                                        or P.count("IGUI_OffGrid_TileCount", m),
                                getText(TOWARD[n > 0 and plus or minus]))
    end
    add((ty or 0) - (fy or 0), "south", "north")
    add((tx or 0) - (fx or 0), "east", "west")
    add((tz or 0) - (fz or 0), "up", "down", true)
    if #bits == 0 then return getText("IGUI_OffGrid_SameTile") end
    return table.concat(bits, ", ")
end

--- Translated one-word name for a tier, for the monitor's parts list.
function P.tierName(tier)
    return getText("IGUI_OffGrid_Tier_" .. tostring(tier))
end

return P

--[[ OffGrid -- putting the books and the hardware in the world.

     THREE SEPARATE STORIES, and they are deliberately different.

     The BOOKS are the gate. Nothing is craftable until one is read, so finding
     the first is the moment the mod turns on and finding the second is the
     moment it opens up.

     WORN HARDWARE is the salvage story. A cracked array in a barn, a dead
     battery crate in a lock-up: something you drag home on day six and cannot
     yet build, repair or use. It only works now that repair exists, which was
     the missing half.

     PRISTINE HARDWARE is the retail story. A tool store or an electronics shop
     had this on a shelf, boxed, at full condition. Rare, because it is the
     good stuff and the mod's whole progression is that you earn it.

     CONDITION IS NOT SET HERE, mostly. It is a property of the LIST, not of
     the room: a list flagged `isShop` spawns everything in it at full
     condition, a list flagged `isWorn` runs wearDownItem over everything, and
     a plain list re-rolls 40 per cent of items uniformly. So the retail
     placements go into lists that are ALREADY isShop and cost nothing. What
     this file does add is a gentler wear for its own items in salvage
     contexts, because vanilla's wearDownItem is brutal: a quarter of
     everything arrives at condition 1 and the median is 13, which for an
     expensive object with a real repair cost is not salvage, it is litter.

     Appended rather than assigned. Replacing a vanilla container's `items`
     table would silently delete whatever every other loaded mod had already
     put there, and the last mod to load would win.

     One list per container fill: ItemPickerJava builds a forced pool from the
     entries a room marks min=1 and picks exactly ONE list name, forced pool
     first (ItemPickerJava.java:836-848). So a book in a min=1 list is reached
     early and reliably, and a book only in BookstoreMisc (min=0,
     weightChance=10) waits for eleven other lists to fire first. That is why
     the almanac sits in both kinds.
]]

if isClient() then return end

OffGrid = OffGrid or {}
OffGrid.Loot = OffGrid.Loot or {}
local L = OffGrid.Loot

-- Weights sit alongside ElectronicsMag1 in the same containers, a notch
-- rarer: this is one book, not a series, and it unlocks three recipes.
L.PLACES = {
    -- 2.10.0: a full loot of Rosewood came out at about three handbooks, a
    -- third of them in garage lockers and fifteen per cent in the bookstore
    -- and shops where players actually look. The hardware store's own
    -- magazine rack (ToolStoreBooks, forced on the rack tiles) now carries
    -- it, and the bookstore's forced blue-collar roll pays out twice as often.
    OffGridManual = {
        ElectronicStoreMagazines = 5,
        BookstoreBlueCollar      = 4,
        BookstoreMisc            = 1.5,
        CrateMagazines           = 1,
        ElectricianTools         = 1.5,
        EngineerTools            = 1.5,
        ArmyStorageElectronics   = 0.5,
        GarageTools              = 1,
        ToolStoreMisc            = 1,
        ToolStoreBooks           = 3,
    },
    -- ElectricianOutfit used to be in the list above. It is a DEAD LIST: it
    -- is defined in ProceduralDistributions.lua and referenced by no room in
    -- Distributions.lua, so nothing it holds has ever spawned. Nothing warns
    -- about this, because the list genuinely exists; only a room reference
    -- makes it reachable. tests/test_content.py now checks for that.
    --
    -- The advanced volume unlocks monocrystalline panels, sealed cabinets and
    -- MPPT, so it is deliberately much rarer and sits where an engineer would
    -- have kept it rather than on a shop shelf.
    OffGridManualAdv = {
        ElectronicStoreMagazines = 1,
        ArmyStorageElectronics   = 0.6,
        EngineerTools            = 0.8,
        ElectricianTools         = 0.5,
        CrateMagazines           = 0.4,
        BookstoreMisc            = 0.3,
    },
    -- The almanac is not an electronics book and does not sit with them. It
    -- goes where a county almanac would: bookstores and libraries, and
    -- nowhere else. Weights are read off the same lists -- an ordinary recipe
    -- magazine is 2 in BookstoreMisc and 1 in LibraryMagazines -- so these
    -- are a notch above ordinary inside a much smaller set of places.
    --
    -- LibraryOutdoors and LibraryChilds are the library's min=1 lists, so
    -- LibraryOutdoors is rolled in every library room that fills a shelf.
    OffGridAlmanac = {
        -- LibraryBooks is the library shelf's forced draw, which is what a
        -- one-library town like Muldraugh (0.26 almanacs for a full loot)
        -- could otherwise never reach reliably.
        LibraryBooks               = 1.5,
        LibraryMagazines           = 2,
        LibraryOutdoors            = 2,
        LibraryScience             = 1.5,
        LibraryGeneralReference    = 1.5,
        UniversityLibraryMagazines = 1.5,
        BookstoreMisc              = 3,
        BookstoreOutdoors          = 2,
        BookstoreFarming           = 2,
        BookstoreScience           = 1.5,
        BookstoreGeneralReference  = 1.5,
    },
}

-- Weights are a PER-ROLL PER-CENT CHANCE, not a share of a weighted pick:
-- the engine rolls every entry in a chosen list independently, `rolls` times.
-- Most of these lists roll four times, so a weight of 0.5 is about a two per
-- cent chance per container that draws the list. These are heavy, expensive
-- objects and they are meant to be a find.

--- New stock. Every list here but GeneratorRoom is already flagged `isShop`,
--  which is what makes its contents spawn at full condition, so nothing extra
--  is needed to keep them pristine. GeneratorRoom is not a shop list: what it
--  holds keeps the engine's own condition roll (a used one, some of the time),
--  and it is never worn down further here. Setting the flag on it instead
--  would change every vanilla item in that list.
L.RETAIL = {
    -- ToolStoreMisc is forced (min=1) on toolstore.shelves, which makes it the
    -- single strongest retail placement in the game. Hence the low weight.
    ToolStoreMisc = {
        OffGridArray = 0.5, OffGridFlat = 0.5, OffGridBank = 0.4,
        OffGridWallBank = 0.4, OffGridController = 0.4,
    },
    ToolStoreTools = {
        OffGridArray = 0.3, OffGridFlat = 0.3, OffGridController = 0.3,
    },
    ElectronicStoreMisc = {
        OffGridArray = 0.4, OffGridFlat = 0.4, OffGridBank = 0.3,
        OffGridWallBank = 0.3, OffGridController = 0.5,
        OffGridControllerMPPT = 0.15,
        OffGridArrayMono = 0.1, OffGridBankSealed = 0.1,
    },
    -- Reached by electronicstore.locker and technical.other only, so it is
    -- rare by placement rather than by weight. The best-stocked room in the
    -- game for this mod, and it should feel like it.
    GeneratorRoom = {
        OffGridArray = 1.5, OffGridFlat = 1.0, OffGridBank = 1.2,
        OffGridWallBank = 1.0, OffGridController = 1.5,
        OffGridControllerMPPT = 0.4,
        OffGridArrayMono = 0.3, OffGridBankSealed = 0.3,
    },
    -- THE CONTROLLER WAS THE SCARCE PIECE, and by a wide margin. Replaying
    -- the 42.20 loot engine over every container in Rosewood gave 0.42
    -- controllers for a full loot (0.55 in Muldraugh) against eight or nine
    -- car battery chargers, while players reported piles of panels and
    -- racks. Two causes: every controller item carries base:generator, which
    -- the generator sprite map needs and which also puts its loot under the
    -- sandbox "Generator Spawning" knob (Rare on Apocalypse, x0.6); and the
    -- lists it sat in exist in few rooms per town. So it now goes where a
    -- car battery charger already goes, which is also what the controller
    -- recipe consumes. Car supply shelves and gas-station emergency shelves
    -- are shop lists, so these arrive boxed.
    CarSupplyTools     = { OffGridController = 0.5 },
    CarSupplyBatteries = { OffGridController = 0.5 },
    GasStoreEmergency  = { OffGridController = 0.5 },
}

--- Used, second-hand, sitting in a shed. Mostly the salvaged grades, because
--  a cracked scrap-framed panel is the one the story wants: the first array a
--  player ever touches should be one they could not have built.
L.SALVAGE = {
    -- mechanic 85 rooms plus the 588 rooms named `garage`, which alias onto
    -- the mechanic table. The thematic home for a used controller.
    MechanicShelfElectric = {
        OffGridArraySalvage = 0.6, OffGridBankCrate = 0.5,
        OffGridWallCrate = 0.4, OffGridController = 0.5,
    },
    -- garagestorage is the widest storage room in both small towns (55 room
    -- records in Rosewood, 85 in Muldraugh), and its metal shelves draw this
    -- list at full weight. On its own it is worth more controllers per town
    -- than every retail placement above put together.
    GarageMechanics = {
        OffGridController = 0.5,
    },
    -- the household electronics crate: attics, bedrooms, closets, living
    -- rooms, sheds and storage units. Only the shed and storage-unit draws are
    -- in WORN_ROOMS, so a controller from a bedroom or closet crate keeps the
    -- engine's own condition, usually full. Deliberately generous: a house
    -- crate is not a scrapyard.
    CrateElectronics = {
        OffGridController = 0.3,
    },
    -- 201 barn rooms spread across the rural map. Somebody was running a pump.
    BarnTools = {
        OffGridArraySalvage = 0.5, OffGridFlatSalvage = 0.4,
        OffGridBankCrate = 0.4,
    },
    -- 11 references, and the name says it: an off-grid household's shelf.
    Homesteading = {
        OffGridArraySalvage = 0.6, OffGridFlatSalvage = 0.5,
        OffGridBankCrate = 0.5, OffGridWallCrate = 0.4,
        OffGridController = 0.3,
    },
    FarmerTools = {
        OffGridArraySalvage = 0.4, OffGridBankCrate = 0.3,
    },
    -- Already flagged isWorn, so the engine wears these down itself and the
    -- handler below deliberately leaves them alone.
    CrateToolsOld = {
        OffGridArraySalvage = 0.3, OffGridFlatSalvage = 0.25,
        OffGridBankCrate = 0.25,
    },
    -- electronicstore.locker.
    ElectricianTools = {
        OffGridArraySalvage = 0.8, OffGridBankCrate = 0.6,
        OffGridController = 0.5,
    },
    -- garagestorage is 1496 rooms, by far the widest reach in this table, so
    -- it carries the lowest weight of the lot bar one.
    GarageTools = {
        OffGridArraySalvage = 0.15, OffGridBankCrate = 0.12,
        OffGridController = 0.15,
    },
    -- all.toolcabinet, which is every tool cabinet in every room the map
    -- never named. Lowest weight in the file for exactly that reason.
    ToolCabinetMechanics = {
        OffGridArraySalvage = 0.06, OffGridController = 0.15,
    },
}

--- Vehicles are a different table with a different shape: VehicleDistributions
--  entries sit at the top level rather than under `.list`, and the profession
--  groups hold REFERENCES to them, so appending to ElectricianTruckBed covers
--  TruckBed, TruckBedOpen and TrailerTrunk in one write.
L.VEHICLES = {
    ElectricianTruckBed = {
        OffGridArraySalvage = 0.6, OffGridBankCrate = 0.4,
        OffGridController = 0.4,
    },
    ConstructionWorkerTruckBed = {
        OffGridArraySalvage = 0.3, OffGridBankCrate = 0.2,
    },
    ElectricianGloveBox = {
    },
}

function L.inject()
    if L.done then return end
    if not ProceduralDistributions or not ProceduralDistributions.list then
        print("OffGrid: ProceduralDistributions not available, "
              .. "the books will not spawn")
        return
    end
    L.done = true

    local added, missed = 0, {}

    --- Append one name/weight pair to a distribution's flat items array.
    local function put(t, name, weight, label)
        if t and t.items then
            t.items[#t.items + 1] = name
            t.items[#t.items + 1] = weight
            added = added + 1
        else
            missed[#missed + 1] = label
        end
    end

    -- the books, keyed the other way round: one book, many places
    for book, places in pairs(L.PLACES) do
        for container, weight in pairs(places) do
            put(ProceduralDistributions.list[container], book, weight, container)
        end
    end

    -- the hardware, keyed one list at a time
    for _, group in ipairs({ L.RETAIL, L.SALVAGE }) do
        for container, items in pairs(group) do
            local t = ProceduralDistributions.list[container]
            for item, weight in pairs(items) do
                put(t, item, weight, container)
            end
        end
    end

    -- vehicles: a different table, at the top level rather than under .list
    if VehicleDistributions then
        for container, items in pairs(L.VEHICLES) do
            local t = VehicleDistributions[container]
            for item, weight in pairs(items) do
                put(t, item, weight, "vehicle:" .. container)
            end
        end
    else
        missed[#missed + 1] = "VehicleDistributions"
    end

    print(string.format("OffGrid: seeded %d loot entries%s", added,
                        #missed > 0
                        and ("  (absent: " .. table.concat(missed, ", ") .. ")")
                        or ""))
end

------------------------------------------------------------------ condition

-- Where a used one would be lying about. Everything else the mod seeds is
-- either in a list the engine already flags `isShop`, and so arrives boxed at
-- full condition, or in one it flags `isWorn`, and so has already been chewed
-- up by wearDownItem before this runs.
--
-- This list is deliberately an ALLOW-list rather than a deny-list. A room
-- nobody anticipated leaves an item at whatever condition the engine gave it,
-- which errs towards being generous. The opposite default would quietly trash
-- gear in places that were never considered.
-- carsupply is NOT here any more. Since 2.10.0 its shelves, counters and
-- metal shelves carry boxed controllers from shop lists, and wearing those
-- down made the retail find players can actually reach arrive as salvage.
-- Everything else in the store is still salvage: see WORN_ROOM_EXCEPT below.
L.WORN_ROOMS = {
    mechanic = true, garage = true, garagestorage = true, shed = true,
    barn = true, farmstorage = true, farm = true, construction = true,
    storageunit = true, storage = true,
}

-- Vehicle fills come through the same event with the vehicle's script name in
-- place of a room, so they are matched on the container instead.
L.WORN_CONTAINERS = {
    TruckBed = true, TruckBedOpen = true, TrailerTrunk = true,
    GloveBox = true,
}

-- Worn in every container of the room EXCEPT these, where a room holds both
-- kinds. A car supply store's counters, shelves and metal shelves draw shop
-- lists (CarSupplyTools, CarSupplyBatteries, GasStoreEmergency) and stay
-- boxed. Everything else in it draws unflagged lists: the tool cabinet, and
-- the `other` fallback every crate, locker and box in the store gets
-- (Distributions.lua carsupply.other), both of which end in
-- ToolCabinetMechanics. Those were worn while carsupply sat in WORN_ROOMS and
-- stay worn. OnFillContainer names the container's REAL type, never "other",
-- so the rule is written as an exception list rather than an allow list.
L.WORN_ROOM_EXCEPT = {
    carsupply = { counter = true, shelves = true, metal_shelves = true },
}

-- The band a salvaged find lands in. Deliberately NOT vanilla's wearDownItem,
-- which puts a quarter of everything at condition 1 and has a median of 13.
-- For an object that costs electronics scrap and screws to repair thirty
-- points at a time, that is not a salvage story, it is litter. This band is
-- always worth carrying home and never immediately usable.
L.WORN_MIN, L.WORN_MAX = 18, 55

--- Wear down Off-Grid's own items, and only those, in salvage contexts.
--
--  OnFillContainer is the right hook and the only one: it fires AFTER
--  fillContainerTypeInternal, so it has the last word on condition, it runs on
--  the authority only, and it fires for vehicle containers as well as world
--  ones. The alternatives all lose: an item script's OnCreate runs at
--  instantiation and is then overwritten by the distribution's own 40 per cent
--  re-roll, and it is discarded again on load.
--
--  What this must never do is set `isWorn` on a vanilla list to get the same
--  effect. That flag is a property of the whole list and the engine applies it
--  item-blind, so one flag on GarageTools would wear down every vanilla tool
--  in every garage in Knox County. Vanilla itself never does that; it forks a
--  second list instead, which is what CrateToolsOld is.
function L.onFill(roomName, containerType, container)
    -- OnFillContainer fires with TWO different Java types in this argument and
    -- only one of them is an ItemContainer. The bag-fill paths
    -- (ItemPickerJava.java:630, 1153, 1407) pass `containerDist.bags`, which is
    -- an ItemPickerJava$ItemPickerContainer: the loot DEFINITION, public fields
    -- only, no methods, and no metatable in __classmetatables.
    --
    -- AN UNEXPOSED JAVA OBJECT CANNOT BE INDEXED AT ALL. The guard that used to
    -- be on this line, `not container.getItems`, was itself the crash:
    --
    --   attempted index: getItems of non-table:
    --     zombie.inventory.ItemPickerJava$ItemPickerContainer
    --
    -- Reading a missing key returns nil only for a class the exposer
    -- registered; for one it did not, Kahlua throws. So a defensive field
    -- probe is NOT safe on an argument whose concrete type you do not control,
    -- which is the opposite of how that idiom reads.
    --
    -- instanceof() takes the object as an ARGUMENT and never indexes it, and
    -- instof() returns false both for null and for any class absent from the
    -- exposer's typeMap (LuaManager.java:2889), so it cannot throw here.
    -- Vanilla uses the same idiom: `instanceof(dest, "ItemContainer")`.
    --
    -- Vanilla's own LootLog.lua has this bug unguarded on the same event; it
    -- survives only because ISLootLog.cheat is off by default.
    if not instanceof(container, "ItemContainer") then return end
    local except = L.WORN_ROOM_EXCEPT[roomName]
    if not (L.WORN_ROOMS[roomName] or L.WORN_CONTAINERS[containerType]
            or (except and not except[containerType])) then
        return
    end
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local full = item and item.getFullType and item:getFullType()
        if full and string.find(full, "Base.OffGrid", 1, true) == 1
                and item.getConditionMax and item.setCondition then
            local maxc = item:getConditionMax() or 0
            -- Books have no condition and must not be touched.
            if maxc > 0 then
                item:setCondition(ZombRand(L.WORN_MIN, L.WORN_MAX + 1))
            end
        end
    end
end

Events.OnPreDistributionMerge.Add(L.inject)
Events.OnFillContainer.Add(L.onFill)

return L

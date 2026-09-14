--[[ OffGrid -- one line in the log saying whether the mod actually came up.

     This mod ships two generated binaries (a tiledef and a texture atlas) and
     depends on twenty-two item records resolving. All of that fails QUIETLY:

       * IsoSpriteManager.getSprite() never returns nil -- a miss falls through
         to AddSprite, so a typo'd or unloaded tile is an invisible, silent,
         error-free object rather than a crash.
       * A malformed tiledef throws inside IsoWorld, which catches and logs it
         and carries on with a half-loaded tileset.
       * A generator whose sprite is missing from getGeneratorSpriteToType()
         silently falls back to Base.Generator and its radius-20 world sound.

     So the check is explicit and runs once at boot. Reading one summary line
     beats reading a boot log looking for an absence.
]]

require "OffGrid/OG_Parts"

OffGrid = OffGrid or {}
OffGrid.Boot = OffGrid.Boot or {}
local B = OffGrid.Boot
local P = OffGrid.Parts

function B.check()
    if B.done then return end
    B.done = true

    -- getSprite() cannot report a miss, but the named map can: it is the
    -- table AddSprite populates, so a name absent from it never loaded.
    -- getSpriteManager takes one argument and ignores it (LuaManager.java:7399);
    -- calling it bare throws "expected 1 argument, got 0".
    local sm0 = getSpriteManager("")
    local named = sm0 and sm0:getNamedMap()
    local total = P.COLS * #P.ROWS
    local sprites, missing = 0, nil
    for m = 0, total - 1 do
        local name = P.TILESET .. "_" .. m
        if named and named:containsKey(name) then
            sprites = sprites + 1
        elseif not missing then
            missing = name
        end
    end

    local sm = getScriptManager()
    local want = P.allItems()
    local items, missingItem = 0, nil
    for i = 1, #want do
        if sm and sm:getItem(want[i]) then
            items = items + 1
        elseif not missingItem then
            missingItem = want[i]
        end
    end

    local ok = (sprites == total) and (items == #want)
    print(string.format(
        "OffGrid: %s -- %d/%d tiles, %d/%d items%s",
        ok and "ready" or "INCOMPLETE",
        sprites, total, items, #want,
        ok and "" or string.format("  (first missing: %s)",
                                   missing or missingItem or "?")))
    if not ok then
        print("OffGrid: check that mod.info carries 'tiledef=offgrid_tiles 4471'"
              .. " and 'pack=offgrid', and that both files exist under"
              .. " common/media/.")
    end
    B.ok = ok
    -- Kept for the Error Magnifier report: a tiledef whose file number another
    -- mod also claims never loads (ZomboidFileSystem skips the second claimant
    -- with one log line), and this count is the only in-game trace of it.
    B.tiles, B.tilesWanted = sprites, total
    B.items, B.itemsWanted = items, #want
    B.firstMissing = missing or missingItem
end

Events.OnGameStart.Add(B.check)
Events.OnServerStarted.Add(B.check)

return B

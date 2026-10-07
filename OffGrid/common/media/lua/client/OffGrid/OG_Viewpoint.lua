--[[ OffGrid -- Project Viewpoint (Workshop 3809306528), the first-person 3D view.

     Viewpoint draws the world itself and did not draw a single Off-Grid tile
     (0.1.5a, 2026-10-07: every part invisible in 3D while the vanilla
     furniture beside it showed). It does draw any tile a model pack binds to
     a model, so the mod ships one: media/modelpacks/offgrid, a model for
     every tile (one per part, turned for its facings), written by
     tools/build_viewpoint.py from the very geometry the tiles are rendered
     from. This file registers it.

     In first person Viewpoint's interaction list is the vanilla right-click
     menu built off-screen for the aimed object (ViewpointInteract.harvest),
     so every Off-Grid row works there. Two things do not carry over, and both
     are said rather than hidden (Can's "show why, never hide"):
       * the list shows a row's name and whether it is greyed, never its
         tooltip, so while it is being built a greyed row gets its reason
         written into its name;
       * what Off-Grid paints on the ground in screen space -- the power
         coverage and the Building Picker -- is not drawn in 3D: those rows
         are greyed there with "only in the top-down view".

     Nothing here does anything without Viewpoint: every call is guarded, and
     the pack is only data until Viewpoint asks for it.
]]

OffGrid = OffGrid or {}
OffGrid.Viewpoint = OffGrid.Viewpoint or {}
local VP = OffGrid.Viewpoint

VP.MOD_ID = "OffGrid"
VP.MANIFEST = "media/modelpacks/offgrid/pack.properties"
-- A reason longer than this is cut, so the list stays readable.
VP.REASON_MAX = 90

--- Is Viewpoint loaded? Its Lua API is a table ZombieBuddy exposes at boot.
function VP.present()
    return type(Viewpoint) == "table" and Viewpoint.ModelPacks ~= nil
end

local registered, complained = false, false

--- Hand Viewpoint the model pack. Idempotent on Viewpoint's side; tried at
--  file load, OnGameBoot and OnGameStart, because the API's exposure and its
--  caches are not tied to one of them (Hiro.uou's pack does the same).
function VP.register()
    if not VP.present() then return false end
    local api = Viewpoint.ModelPacks
    if type(api.register) ~= "function" and type(api.register) ~= "userdata" then
        return false
    end
    local ok, result = pcall(api.register, VP.MOD_ID, VP.MANIFEST)
    if ok and result then
        if not registered then print("[OffGrid] Viewpoint model pack registered") end
        registered = true
        return true
    end
    if not complained then
        print("[OffGrid] Viewpoint did not take the model pack: " .. tostring(result))
        complained = true
    end
    return false
end

------------------------------------------------------------------- the 3D view

--- Is a menu being built for Viewpoint's 3D view? Viewpoint has no call
--  that says the view is on, and the game's own render events go on firing
--  under it (OnPostRender: 60 a second either way, 2026-10-07). Two things
--  do tell, and between them they cover both ways a menu opens in 3D:
--    * its interaction list (crosshair mode) is built inside harvest;
--    * a right-click menu needs its mouse pointer out (middle mouse), and
--      while that is out over the world Viewpoint.Mouse.worldX() answers
--      the point under it; in the top-down view and in crosshair mode it
--      answers nil.
function VP.in3D()
    if not VP.present() then return false end
    if VP.harvesting then return true end
    local mouse = Viewpoint.Mouse
    if type(mouse) ~= "table" or mouse.worldX == nil then return false end
    local ok, x = pcall(mouse.worldX)
    return ok and x ~= nil
end

------------------------------------------------------- the interaction list

--- Wrap ViewpointInteract.harvest so the menu knows it is being built for
--  Viewpoint's list. Everything it is handed goes through untouched, and so
--  does everything it returns or raises. Viewpoint's Java looks the global up
--  at every call, so the wrap is seen.
function VP.wrapHarvest()
    local vi = ViewpointInteract
    if type(vi) ~= "table" then return false end
    local orig = vi.harvest
    if type(orig) ~= "function" or orig == VP.wrapped then return false end
    -- Through pcall so the flag can never stay up after a failed build (it
    -- would grey the top-down menu), then raised again as it was.
    local function finish(ok, ...)
        VP.harvesting = false
        if not ok then error((...), 0) end
        return ...
    end
    local function wrapped(...)
        VP.harvesting = true
        return finish(pcall(orig, ...))
    end
    VP.original, VP.wrapped = orig, wrapped
    vi.harvest = wrapped
    return true
end

--- A tooltip's text as one plain line: the engine's rich-text tags dropped.
local function plain(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("<[^>]*>", " "):gsub("%s+", " ")
    text = text:gsub("^ ", ""):gsub(" $", "")
    if text == "" then return nil end
    if #text > VP.REASON_MAX then text = text:sub(1, VP.REASON_MAX - 3) .. "..." end
    return text
end

--- While Viewpoint builds its list: every greyed row of `menu`, and of its
--  submenus, carries its reason in its name. Called by the context menu once
--  a menu of ours is complete (C.dimUnavailable).
function VP.explain(menu, seen)
    if not VP.harvesting or type(menu) ~= "table" then return end
    seen = seen or {}
    if seen[menu] then return end
    seen[menu] = true
    local opts = menu.options
    if type(opts) ~= "table" then return end
    for _, o in ipairs(opts) do
        if type(o) == "table" then
            -- Not on a submenu's own row: Viewpoint already puts that row's
            -- name in front of each of its children, which say why themselves.
            if o.notAvailable and not o.ogExplained and not o.subOption then
                local why = plain(o.toolTip and o.toolTip.description)
                if why and type(o.name) == "string" then
                    o.name = o.name .. " (" .. why .. ")"
                    o.ogExplained = true
                end
            end
            if o.subOption and menu.getSubMenu then
                VP.explain(menu:getSubMenu(o.subOption), seen)
            end
        end
    end
end

VP.register()
VP.wrapHarvest()
Events.OnGameBoot.Add(function() VP.register(); VP.wrapHarvest() end)
Events.OnGameStart.Add(function() VP.register(); VP.wrapHarvest() end)

--[[ OffGrid -- server-to-client commands.

     `note`: why the server refused something (OG_Place's refuse), or, for a
     few, news (a building wired in). The server sends the translation KEY,
     because a dedicated server never loads mod translations, and the note
     is translated here, in the player's language. `warn` says it is a
     refusal, drawn in the warning colour (P.haloNote, Can 2026-09-29); a
     note without it keeps the game's own colour. It is the only command
     the server sends.
]]

require "OffGrid/OG_Parts"

local function onServerCommand(module, command, args)
    if module ~= "OffGrid" then return end
    if command == "note" then
        if type(args) ~= "table" or type(args.key) ~= "string" then return end
        -- Only this mod's own keys: the note is a translated string, never
        -- whatever text a server cares to send.
        if not string.match(args.key, "^%a+_OffGrid_[%w_]+$") then return end
        local playerObj = nil
        if args.id and getPlayerByOnlineID then
            playerObj = getPlayerByOnlineID(args.id)
        end
        playerObj = playerObj or getSpecificPlayer(0)
        OffGrid.Parts.haloNote(playerObj, getText(args.key), args.warn == true)
    end
end

Events.OnServerCommand.Add(onServerCommand)

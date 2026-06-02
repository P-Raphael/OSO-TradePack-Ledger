-- OPS / TradePacks shared helpers

-- Detects whether the user is running the dark-mode UI replacement.
-- Reads the first lines of the modded ui/common/default.g and checks for the
-- dark background color signature. Returns false on the standard (light) UI.
-- (isUserDarkMode by Noir <3, copied from the globals folder so OPS does not
--  depend on globals being installed.)
function isUserDarkMode()
    local isDarkMode = false
    local commonFilePath = "../Documents/Addon/ui/common/default.g"
    local commonFile = io.open(commonFilePath, "r")
    -- no file = standard UI
    if not commonFile then
        return isDarkMode
    end

    -- skip to line 6
    local line
    for i = 1, 6 do
        line = commonFile:read("*l")
        if not line then
            break
        end
    end
    commonFile:close()

    if line then
        if line:find("bg_01%s*%(%s*15,%s*22,%s*29,%s*255%s*%)") then
            isDarkMode = true
        end
    end
    return isDarkMode
end

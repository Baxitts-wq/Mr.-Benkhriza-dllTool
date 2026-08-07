-- manifest.lua — Multi-API fallback for manifest codes
-- Tries steamrun first, then wudrm, then opensteamtool
-- Place at: C:\Program Files (x86)\Steam\config\lua\manifest.lua

function fetch_manifest_code(gid)
    -- 1. Try steamrun (JSON response)
    local body, st = http_get("https://manifest.steam.run/api/manifest/" .. gid)
    if st == 200 and body then
        local code = body:match('"content":"(%d+)"')
        if code then return code end
    end

    -- 2. Try wudrm (plain-text uint64)
    body, st = http_get("http://gmrc.wudrm.com/manifest/" .. gid)
    if st == 200 and body and body:match("^%d+$") then
        return body
    end

    -- 3. Try opensteamtool
    body, st = http_get("https://manifest.opensteamtool.com/" .. gid)
    if st == 200 and body and body:match("^%d+$") then
        return body
    end

    return nil
end

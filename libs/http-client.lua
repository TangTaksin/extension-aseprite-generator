-- http-client.lua
-- Async HTTP client using background curl + Timer polling
-- Non-blocking: Aseprite UI stays responsive during all requests

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*)[/\\]")

local json = dofile(script_dir .. "/json.lua")
if not json then
    app.alert("Critical Error: http-client.lua could not load json.lua. Ensure both files are in the same folder.")
    return
end

local http_client = {}

-- =====================================
-- Temp File Helpers
-- =====================================
local temp_counter = 0

local function create_temp_filename()
    temp_counter = temp_counter + 1
    local timestamp = os.time()
    local random_part = math.random(1000, 9999)

    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("USERPROFILE") or "."
    local sep = package.config:sub(1, 1)

    if temp_dir:sub(-1) == sep then
        return temp_dir .. string.format("aseprite_ai_%d_%d_%d.tmp", timestamp, random_part, temp_counter)
    else
        return temp_dir .. sep .. string.format("aseprite_ai_%d_%d_%d.tmp", timestamp, random_part, temp_counter)
    end
end

local function write_file(filename, content)
    local file = io.open(filename, "wb")
    if file then
        file:write(content)
        file:close()
        return true
    end
    return false
end

local function read_file(filename)
    local file = io.open(filename, "rb")
    if file then
        local content = file:read("*all")
        file:close()
        return content
    end
    return nil
end

local function remove_file(filename)
    if filename then pcall(os.remove, filename) end
end

local function file_exists(filename)
    local file = io.open(filename, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- =====================================
-- Async Curl Execution
-- =====================================
-- Spawns curl in a background process, then polls for a sentinel file
-- using Aseprite's Timer API. When the sentinel appears, the response
-- is read, temp files are cleaned up, and the callback is invoked.

local function exec_curl_async(curl_cmd, output_file, callback, extra_cleanup, poll_interval, max_wait)
    poll_interval = poll_interval or 0.5
    max_wait = max_wait or 660

    local done_file = output_file .. ".done"
    local bat_file = output_file .. ".bat"

    -- Write a batch script: run curl, then create a sentinel file
    local bat_content = string.format(
        '@%s\r\n@echo.>"%s"\r\n',
        curl_cmd, done_file
    )

    if not write_file(bat_file, bat_content) then
        if callback then callback(nil, "Cannot create batch script") end
        return
    end

    -- Launch in background (non-blocking, no new window)
    os.execute('start "" /b cmd /c call "' .. bat_file .. '"')

    -- Poll for sentinel file
    local poll_start = os.time()
    local poll_timer
    poll_timer = Timer {
        interval = poll_interval,
        ontick = function()
            -- Safety timeout: give up if curl never finishes
            if (os.time() - poll_start) > max_wait then
                poll_timer:stop()
                remove_file(output_file)
                remove_file(done_file)
                remove_file(bat_file)
                if extra_cleanup then
                    for _, f in ipairs(extra_cleanup) do remove_file(f) end
                end
                if callback then callback(nil, "Request timed out") end
                return
            end

            -- Sentinel not yet created — curl still running
            if not file_exists(done_file) then return end

            -- Curl finished — read result and clean up
            poll_timer:stop()

            local content = read_file(output_file)
            remove_file(output_file)
            remove_file(done_file)
            remove_file(bat_file)
            if extra_cleanup then
                for _, f in ipairs(extra_cleanup) do remove_file(f) end
            end

            if content and content ~= "" then
                local success, parsed = pcall(json.decode, content)
                if success then
                    if callback then callback(parsed, nil) end
                else
                    if callback then callback(nil, "Failed to parse JSON: " .. tostring(parsed)) end
                end
            else
                if callback then callback(nil, "Empty or no response from server") end
            end
        end
    }
    poll_timer:start()
end

-- =====================================
-- Public API
-- =====================================

-- HTTP GET (async, non-blocking)
function http_client.get(url, callback)
    local temp_file = create_temp_filename()
    local curl_cmd = string.format(
        'curl.exe -s -k --connect-timeout 5 --max-time 10 "%s" > "%s" 2>nul',
        url, temp_file
    )
    -- Fast polling (0.2s) with short timeout (15s) for quick requests
    exec_curl_async(curl_cmd, temp_file, callback, nil, 0.2, 15)
end

-- HTTP POST (async, non-blocking)
function http_client.post(url, data, callback)
    local temp_file = create_temp_filename()
    local json_data = json.encode(data)
    local data_file = create_temp_filename()

    if not write_file(data_file, json_data) then
        if callback then callback(nil, "Cannot create request data file") end
        return
    end

    local curl_cmd = string.format(
        'curl.exe -s -k --connect-timeout 10 --max-time 600 -X POST -H "Content-Type: application/json" -d @"%s" "%s" > "%s" 2>nul',
        data_file, url, temp_file
    )
    -- Slower polling (0.5s) with long timeout (660s) for AI generation
    exec_curl_async(curl_cmd, temp_file, callback, {data_file}, 0.5, 660)
end

return http_client
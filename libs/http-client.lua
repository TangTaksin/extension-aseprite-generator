

-- Get the script's directory to reliably load the JSON library
local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*)[/\\]")

-- Load the robust JSON library from the same directory
local json = dofile(script_dir .. "/json.lua")
if not json then
    app.alert("Critical Error: http-client.lua could not load json.lua. Ensure both files are in the same folder.")
    return
end

local http_client = {}

-- Generate unique filename without os.tmpname()
local temp_counter = 0
local function create_temp_filename()
    temp_counter = temp_counter + 1
    local timestamp = os.time()
    local random_part = math.random(1000, 9999)
    
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("USERPROFILE") or "."
    local sep = package.config:sub(1, 1)
    
    if temp_dir:sub(-1) == sep then
        return temp_dir .. string.format("aseprite_temp_%d_%d_%d.tmp", timestamp, random_part, temp_counter)
    else
        return temp_dir .. sep .. string.format("aseprite_temp_%d_%d_%d.tmp", timestamp, random_part, temp_counter)
    end
end

-- Create temporary file with unique name
local function create_temp_file(content)
    local temp_name = create_temp_filename()
    if content then
        local file = io.open(temp_name, "wb")  -- Use binary mode for Windows
        if file then
            file:write(content)
            file:close()
            return temp_name
        end
    else
        -- Just return the temp name for output file
        return temp_name
    end
    return nil
end

-- Read file content safely
local function read_file(filename)
    local file = io.open(filename, "rb")  -- Use binary mode
    if file then
        local content = file:read("*all")
        file:close()
        return content
    end
    return nil
end

-- Remove file safely
local function remove_file(filename)
    if filename then
        pcall(os.remove, filename)  -- Use pcall to avoid errors
    end
end

-- HTTP GET request
function http_client.get(url, callback)
    local temp_file = create_temp_file()
    if not temp_file then
        if callback then callback(nil, "Cannot create temporary file") end
        return
    end

    local cmd = string.format('curl.exe -s -k --connect-timeout 5 --max-time 10 "%s" > "%s" 2>nul', url, temp_file)
    os.execute(cmd)

    local content = read_file(temp_file)
    remove_file(temp_file)

    if content and content ~= "" then
        local success, parsed = pcall(json.decode, content)
        if success then
            if callback then callback(parsed, nil) end
        else
            if callback then callback(nil, "Failed to parse JSON response: " .. tostring(parsed)) end
        end
    else
        if callback then callback(nil, "Empty or no response from server") end
    end
end

-- HTTP POST request
function http_client.post(url, data, callback)
    local temp_file = create_temp_file()
    local data_file = nil

    if not temp_file then
        if callback then callback(nil, "Cannot create temporary file") end
        return
    end

    local json_data = json.encode(data)
    data_file = create_temp_file(json_data)
    if not data_file then
        remove_file(temp_file)
        if callback then callback(nil, "Cannot create data file") end
        return
    end

    -- *** INCREASED TIMEOUT: 600 seconds (10 minutes) for long AI generations ***
    local cmd = string.format('curl.exe -s -k --connect-timeout 10 --max-time 600 -X POST -H "Content-Type: application/json" -d @"%s" "%s" > "%s" 2>nul',
                              data_file, url, temp_file)

    os.execute(cmd)

    local content = read_file(temp_file)
    remove_file(temp_file)
    remove_file(data_file)

    if content and content ~= "" then
        local success, parsed = pcall(json.decode, content)
        if success then
            if callback then callback(parsed, nil) end
        else
            if callback then callback(nil, "Failed to parse JSON response: " .. tostring(parsed)) end
        end
    else
        if callback then callback(nil, "Empty or no response from server") end
    end
end

return http_client
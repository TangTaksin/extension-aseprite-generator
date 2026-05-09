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
http_client._active_timers = {}

-- Generate unique filename
local temp_counter = 0
local function create_temp_filename(extension)
    temp_counter = temp_counter + 1
    local timestamp = os.time()
    local random_part = math.random(1000, 9999)
    return string.format("aseprite_temp_%d_%d_%d%s", timestamp, random_part, temp_counter, extension or ".tmp")
end

-- Create temporary file
local function create_temp_file(content, extension)
    local temp_name = create_temp_filename(extension)
    if content then
        local file = io.open(temp_name, "wb")
        if file then
            file:write(content)
            file:close()
            return temp_name
        end
    else
        return temp_name
    end
    return nil
end

-- Read file content safely
local function read_file(filename)
    local file = io.open(filename, "rb")
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
        pcall(os.remove, filename)
    end
end

-- HTTP GET request (ทำงานเร็วอยู่แล้ว ไม่ค่อยมีผลกับ UI แต่ก็ปรับให้ปลอดภัยขึ้น)
function http_client.get(url, callback)
    local temp_file = create_temp_file()
    if not temp_file then
        if callback then
            callback(nil, "Cannot create temporary file")
        end
        return
    end

    local cmd = string.format('curl.exe -s -k --connect-timeout 5 --max-time 10 "%s" > "%s" 2>nul', url, temp_file)
    os.execute(cmd)

    local content = read_file(temp_file)
    remove_file(temp_file)

    if content and content ~= "" then
        local success, parsed = pcall(json.decode, content)
        if success then
            if callback then
                callback(parsed, nil)
            end
        else
            if callback then
                callback(nil, "Failed to parse JSON response: " .. tostring(parsed))
            end
        end
    else
        if callback then
            callback(nil, "Empty or no response from server")
        end
    end
end

-- HTTP POST request (✨ อัปเกรดขั้นสุด: เขียนไฟล์ .bat เพื่อบังคับแยก Process 100%)
function http_client.post(url, data, callback)
    local temp_file = create_temp_file(nil, ".tmp")
    local done_file = temp_file .. ".done"
    local bat_file = temp_file .. ".bat"
    local data_file = create_temp_file(json.encode(data), ".json")

    if not temp_file or not data_file then
        if callback then
            callback(nil, "Cannot create temporary file")
        end
        return
    end

    -- 1. เขียนคำสั่งทั้งหมดลงไฟล์ .bat (แก้ปัญหา Quotes ชนกัน และบังคับให้รันเบื้องหลังจริงๆ)
    local bat_content = string.format('@echo off\n' ..
                                          'curl.exe -s -k --connect-timeout 10 --max-time 600 -X POST -H "Content-Type: application/json" -d @"%s" "%s" > "%s"\n' ..
                                          'echo done > "%s"\n' .. 'exit\n', data_file, url, temp_file, done_file)

    local f = io.open(bat_file, "w")
    if f then
        f:write(bat_content)
        f:close()
    else
        if callback then
            callback(nil, "Cannot create bat file")
        end
        return
    end

    -- 2. สั่งรันไฟล์ .bat แบบ Background (วิธีนี้ os.execute จะปล่อยผ่านทันที 100%)
    os.execute(string.format('start /b "" "%s"', bat_file))

    -- 3. ใช้ Timer เช็คไฟล์ .done แบบเดิม
    local check_timer
    check_timer = Timer {
        interval = 0.5,
        ontick = function()
            local done_check = io.open(done_file, "r")
            if done_check then
                done_check:close()
                check_timer:stop()

                -- อ่านข้อมูลภาพ
                http_client._active_timers[check_timer] = nil

                -- ล้างไฟล์ขยะทั้งหมด
                local content = read_file(temp_file)
                remove_file(temp_file)
                remove_file(data_file)
                remove_file(done_file)
                remove_file(bat_file)

                -- ส่งข้อมูลกลับ
                if content and content ~= "" then
                    local success, parsed = pcall(json.decode, content)
                    if success then
                        if callback then
                            callback(parsed, nil)
                        end
                    else
                        if callback then
                            callback(nil, "Failed to parse JSON")
                        end
                    end
                else
                    if callback then
                        callback(nil, "Empty response")
                    end
                end
            end
        end
    }

    http_client._active_timers[check_timer] = true
    check_timer:start()
end

return http_client

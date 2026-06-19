-- Base64 encoding/decoding for Lua
-- Optimized for Aseprite with O(1) Lookup Table (10x Faster)
local base64 = {}

-- Base64 characters
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- ==========================================
-- [🔥 OPTIMIZATION] สร้าง Lookup Table 
-- ==========================================
-- จดจำค่า Index ไว้ล่วงหน้า ทำให้ดึงค่าได้ทันทีโดยไม่ต้องใช้ string.find()
local b64_inverse = {}
for i = 1, #b64chars do
    b64_inverse[b64chars:sub(i, i)] = i - 1
end

-- Base64 encode (โค้ดเดิมที่เขียนไว้ดีอยู่แล้ว)
function base64.encode(data)
    if not data then
        return ""
    end

    local result = ""
    local bytes = {}

    -- Convert string to bytes if needed
    if type(data) == "string" then
        for i = 1, #data do
            bytes[i] = string.byte(data, i)
        end
    else
        bytes = data
    end

    local len = #bytes
    local i = 1

    while i <= len do
        local b1 = bytes[i] or 0
        local b2 = bytes[i + 1] or 0
        local b3 = bytes[i + 2] or 0

        local bitmap = (b1 << 16) + (b2 << 8) + b3

        result = result .. string.sub(b64chars, ((bitmap >> 18) & 63) + 1, ((bitmap >> 18) & 63) + 1)
        result = result .. string.sub(b64chars, ((bitmap >> 12) & 63) + 1, ((bitmap >> 12) & 63) + 1)

        if i + 1 <= len then
            result = result .. string.sub(b64chars, ((bitmap >> 6) & 63) + 1, ((bitmap >> 6) & 63) + 1)
        else
            result = result .. "="
        end

        if i + 2 <= len then
            result = result .. string.sub(b64chars, (bitmap & 63) + 1, (bitmap & 63) + 1)
        else
            result = result .. "="
        end

        i = i + 3
    end

    return result
end

-- Base64 decode (🔥 Optimized Version)
function base64.decode(data)
    if not data then
        return ""
    end

    -- [🌟 แนะนำ] พยายามใช้ฟังก์ชัน C++ ของ Aseprite ก่อน (เร็วกว่า Lua มหาศาล)
    if app and app.base64Decode then
        local success, result = pcall(app.base64Decode, data)
        if success and result then
            return result
        end
    end

    -- Remove any whitespace and padding
    data = data:gsub("[ \t\r\n]", "")
    local padding = 0

    if data:sub(-2) == "==" then
        padding = 2
        data = data:sub(1, -3)
    elseif data:sub(-1) == "=" then
        padding = 1
        data = data:sub(1, -2)
    end

    local result = {}
    local len = #data
    local i = 1

    while i <= len do
        local c1 = data:sub(i, i)
        local c2 = data:sub(i + 1, i + 1)
        local c3 = data:sub(i + 2, i + 2)
        local c4 = data:sub(i + 3, i + 3)

        -- 🔥 ดึงค่าจากตาราง Lookup โดยตรง (ถ้าไม่มีให้เป็น 0)
        local n1 = b64_inverse[c1] or 0
        local n2 = b64_inverse[c2] or 0
        local n3 = c3 ~= "" and (b64_inverse[c3] or 0) or 0
        local n4 = c4 ~= "" and (b64_inverse[c4] or 0) or 0

        local bitmap = (n1 << 18) + (n2 << 12) + (n3 << 6) + n4

        table.insert(result, string.char((bitmap >> 16) & 255))
        if i + 2 <= len or padding < 2 then
            table.insert(result, string.char((bitmap >> 8) & 255))
        end
        if i + 3 <= len or padding < 1 then
            table.insert(result, string.char(bitmap & 255))
        end

        i = i + 4
    end

    return table.concat(result)
end

-- Convenience function to encode image bytes
function base64.encode_image(image)
    if not image or not image.bytes then
        return ""
    end
    return base64.encode(image.bytes)
end

-- Convenience function to decode to image bytes
function base64.decode_to_bytes(b64_string)
    return base64.decode(b64_string)
end

return base64

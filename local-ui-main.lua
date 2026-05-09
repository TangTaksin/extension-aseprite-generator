local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*)[/\\]")

local function safe_dofile(filename)
    local full_path = script_dir .. "/" .. filename
    local success, result = pcall(dofile, full_path)
    if not success then
        app.alert("Error loading " .. filename .. ": " .. tostring(result))
        return nil
    end
    return result
end

-- Load required libraries
local json = safe_dofile("json.lua")
local base64 = safe_dofile("base64.lua")
local http_client = safe_dofile("http-client.lua")

if not json or not base64 or not http_client then
    app.alert("Failed to load required libraries. Please ensure all files are in the same directory.")
    return
end

-- Plugin configuration
local plugin_config = {
    server_url = "http://127.0.0.1:5000",
    name = "Local AI Generator v2.0",
    version = "2.0"
}

-- Global state
local is_generating = false
local current_dialog = nil
local available_models = {"ponyDiffusionV6XL_v6StartWithThisOne.safetensors"}
local available_loras = {None}
local server_status = "Unknown"
local last_generation_time = 0
local loading_timer = nil
local loading_dots = 0

-- Default settings
local current_settings = {
    prompt = "shirosu00, chibi, 1girl, solo, Reze, short dark purple hair, braided side bangs, green eyes, school uniform, playful smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, bomb pin, simple blue background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime",
    negative_prompt = "score_6, score_5, score_4, score_3, score_2, score_1, realistic, 3d, blurry, lowres, bad anatomy, extra limbs, extra fingers, text, watermark, duplicate",
    pixel_width = 64,
    pixel_height = 64,
    steps = 25,
    guidance_scale = 7.5,
    colors = 16,
    seed = -1,
    remove_background = false,
    model_name = "stabilityai/stable-diffusion-xl-base-1.0",
    lora_model = "None",
    lora_strength = 0.8,
    output_method = "New Frame",
    generation_quality = "High (1024x1024)"
}

-- Preset prompts
local preset_prompts =
    {"pixel art, single lone character, cyberpunk girl with neon glowing hair, solo, futuristic visor, detailed sprite",
     "pixel art, single character, brave knight in shining plate armor, standing, solo, fantasy RPG, 16-bit sprite",
     "pixel art, one single character, cute slime monster, solo, squishy, expressive eyes, flat colors",
     "pixel art, single character, wizard with a long white beard, solo, holding a wooden staff, magical robe",
     "pixel art, single character, vampire lord, solo, red cape, gothic style, pale skin, 16-bit masterpiece",
     "shirosu00, chibi, 1girl, solo, Makima, red hair, braid, yellow concentric eyes, white shirt, black tie, smug smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, floating chains, simple red background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime",
     "shirosu00, chibi, 1girl, solo, Reze, short dark purple hair, braided side bangs, green eyes, school uniform, playful smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, bomb pin, simple blue background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime"}

-- Dimension presets
local dimension_presets = {{
    name = "Tiny (32x32)",
    width = 32,
    height = 32
}, {
    name = "Small (64x64)",
    width = 64,
    height = 64
}, {
    name = "Medium (128x128)",
    width = 128,
    height = 128
}, {
    name = "Large (256x256)",
    width = 256,
    height = 256
}}

-- Utility functions
local function format_time(seconds)
    if seconds < 60 then
        return string.format("%.1fs", seconds)
    else
        return string.format("%.1fm", seconds / 60)
    end
end

-- Fetch data from server
local function fetch_models_and_loras(callback)
    server_status = "Connecting..."

    -- 1. ดึงรายชื่อ Models
    http_client.get(plugin_config.server_url .. "/models", function(res, err)
        if res and res.models then
            available_models = res.models
        end

        -- 2. ดึงรายชื่อ LoRAs
        http_client.get(plugin_config.server_url .. "/loras", function(res2, err2)
            if res2 and res2.loras then
                available_loras = res2.loras
            end

            -- 3. ตรวจสอบสถานะ Server (ข้าม /settings ไปได้เลยเพราะ Server ไม่มี)
            http_client.get(plugin_config.server_url .. "/health", function(health_res, health_err)
                if health_res then
                    -- แสดงสถานะ Online พร้อมชื่อโมเดลที่รันอยู่
                    server_status = "Online" .. (health_res.current_model and (" - " .. health_res.current_model) or "")
                else
                    server_status = "Offline"
                end

                -- เมื่อโหลดครบทุกอย่างแล้วค่อยรัน Callback เพื่อเปิดหน้าต่าง UI
                if callback then
                    callback()
                end
            end)
        end)
    end)
end

-- Core generation logic
local function generate_image(settings, callback)
    if is_generating then
        return
    end
    is_generating = true
    local start_time = os.clock()
    local base_width, base_height = 1024, 1024
    if settings.generation_quality == "Fast (512x512)" then
        base_width, base_height = 512, 512
    elseif settings.generation_quality == "Ultra (1536x1536)" then
        base_width, base_height = 1536, 1536
    end

    local request_data = {
        prompt = settings.prompt,
        negative_prompt = settings.negative_prompt,
        width = base_width,
        height = base_height,
        pixel_width = settings.pixel_width,
        pixel_height = settings.pixel_height,
        steps = settings.steps,
        guidance_scale = settings.guidance_scale,
        colors = settings.colors,
        lora_model = settings.lora_model,
        lora_strength = settings.lora_strength,
        remove_background = settings.remove_background,
        seed = settings.seed ~= -1 and settings.seed or nil,
        model_name = settings.model_name
    }
    http_client.post(plugin_config.server_url .. "/generate", request_data, function(response, error)
        is_generating = false
        last_generation_time = os.clock() - start_time
        if callback then
            callback(response, error)
        end
    end)
end

-- Image placement functions
local function prepare_image_for_generation(output_method, image_mode)
    local cel
    app.transaction("AI Generation Setup", function()
        local layer = app.activeSprite:newLayer({
            name = "AI Gen " .. os.date("%H:%M:%S"),
            colorMode = image_mode
        })
        app.activeLayer = layer
        local frame
        if output_method == "New Frame" then
            frame = app.activeSprite:newEmptyFrame()
        else
            frame = app.activeFrame
        end
        cel = app.activeSprite:newCel(layer, frame)
    end)
    return cel
end

local function place_image_in_aseprite_raw(image_data, output_method)
    local image_mode = (image_data.mode == "rgba") and ColorMode.RGBA or ColorMode.RGB
    if not app.activeSprite then
        app.command.NewFile({
            width = image_data.width,
            height = image_data.height,
            colorMode = image_mode
        })
    end
    local cel = prepare_image_for_generation(output_method, image_mode)
    local pixel_data = base64.decode(image_data.base64)
    app.transaction("Place AI Image", function()
        local im = Image(image_data.width, image_data.height, image_mode)
        im.bytes = pixel_data
        cel.image:drawImage(im, Point(0, 0))
    end)
    app.refresh()
end

local function update_dialog_status(dlg)
    if not dlg then
        return
    end

    if is_generating then
        -- 🎨 สถานะ: กำลัง Generate -> ปิดการกดปุ่มและเริ่มอนิเมชั่น
        dlg:modify{
            id = "generate",
            enabled = false
        }

        -- ถ้ายังไม่มี Timer ให้สร้างใหม่
        if not loading_timer then
            loading_timer = Timer {
                interval = 0.25, -- อัปเดตทุก 0.25 วินาที
                ontick = function()
                    if not is_generating then
                        loading_timer:stop()
                        return
                    end
                    -- สร้างอนิเมชั่นจุดไข่ปลา 1-3 จุด
                    loading_dots = (loading_dots + 1) % 4
                    local dots = string.rep(".", loading_dots)

                    -- อัปเดตข้อความบน UI ให้ขยับได้
                    dlg:modify{
                        id = "server_status_label",
                        text = "Status: 🎨 Generating AI" .. dots
                    }
                    dlg:modify{
                        id = "generate",
                        text = "Generating" .. string.rep(" ", 3 - loading_dots) .. dots
                    }
                end
            }
        end
        loading_timer:start()

    else
        -- ✅ สถานะ: ปกติ (รอรับคำสั่ง) -> คืนค่าปุ่มและหยุดอนิเมชั่น
        if loading_timer then
            loading_timer:stop()
        end

        dlg:modify{
            id = "server_status_label",
            text = "Status: " .. server_status
        }
        dlg:modify{
            id = "generate",
            enabled = true,
            text = "Generate Image"
        }

        if last_generation_time > 0 then
            dlg:modify{
                id = "generation_time_label",
                text = "Last generation: " .. format_time(last_generation_time)
            }
        end
    end
end

-- UI Dialogs
local function open_advanced_dialog()
    local adv_dlg = Dialog("Advanced Settings")
    adv_dlg:slider{
        id = "steps",
        label = "Steps:",
        min = 10,
        max = 50,
        value = current_settings.steps,
        onchange = function()
            current_settings.steps = adv_dlg.data.steps
        end
    }
    adv_dlg:slider{
        id = "guidance_scale",
        label = "Guidance:",
        min = 1,
        max = 20,
        value = current_settings.guidance_scale,
        onchange = function()
            current_settings.guidance_scale = adv_dlg.data.guidance_scale
        end
    }
    adv_dlg:number{
        id = "seed",
        label = "Seed:",
        text = tostring(current_settings.seed),
        onchange = function()
            current_settings.seed = adv_dlg.data.seed
        end
    }

    adv_dlg:button{
        text = "Close",
        onclick = function()
            adv_dlg:close()
        end
    }
    adv_dlg:show({
        wait = false
    })
end

local function open_model_dialog()
    local model_dlg = Dialog("Model Settings")
    model_dlg:combobox{
        id = "model_name",
        label = "Model:",
        options = available_models,
        option = current_settings.model_name,
        onchange = function()
            -- 1. ดึงข้อมูลจาก model_dlg (หน้าต่าง Settings)
            current_settings.model_name = model_dlg.data.model_name

            -- 2. เปลี่ยนสถานะ
            server_status = "Ready - " .. current_settings.model_name

            -- 3. สั่งอัปเดตหน้าต่างหลัก โดยใช้ตัวแปร current_dialog
            update_dialog_status(current_dialog)
        end
    }
    model_dlg:combobox{
        id = "quality",
        label = "Quality:",
        options = {"Fast (512x512)", "High (1024x1024)", "Ultra (1536x1536)"},
        option = current_settings.generation_quality,
        onchange = function()
            current_settings.generation_quality = model_dlg.data.quality
        end
    }
    model_dlg:combobox{
        id = "lora",
        label = "LoRA:",
        options = available_loras,
        option = current_settings.lora_model,
        onchange = function()
            current_settings.lora_model = model_dlg.data.lora
        end
    }
    model_dlg:slider{
        id = "lora_str",
        label = "LoRA Str:",
        min = 0,
        max = 2,
        value = current_settings.lora_strength,
        onchange = function()
            current_settings.lora_strength = model_dlg.data.lora_str
        end
    }
    model_dlg:button{
        text = "Close",
        onclick = function()
            model_dlg:close()
        end
    }
    model_dlg:show({
        wait = false
    })
end

local function create_main_dialog()
    if current_dialog then
        current_dialog:close()
    end
    local dlg = Dialog("Local AI Generator")
    current_dialog = dlg
    dlg:label{
        id = "server_status_label",
        text = "Status: " .. server_status
    }
    dlg:button{
        text = "Refresh",
        onclick = function()
            fetch_models_and_loras(function()
                update_dialog_status(dlg)
            end)
        end
    }
    dlg:separator{}
    dlg:entry{
        id = "prompt",
        label = "Prompt:",
        text = current_settings.prompt,
        onchange = function()
            current_settings.prompt = dlg.data.prompt
        end
    }

    dlg:entry{
        id = "negative_prompt",
        label = "Negative:",
        text = current_settings.negative_prompt,
        onchange = function()
            current_settings.negative_prompt = dlg.data.negative_prompt
        end
    }

    dlg:combobox{
        id = "preset",
        label = "Presets:",
        options = preset_prompts,
        onchange = function()
            current_settings.prompt = dlg.data.preset;
            dlg:modify{
                id = "prompt",
                text = current_settings.prompt
            }
        end
    }
    dlg:combobox{
        id = "size",
        label = "Size:",
        options = {"Tiny (32x32)", "Small (64x64)", "Medium (128x128)", "Large (256x256)"},
        onchange = function()
            for _, p in ipairs(dimension_presets) do
                if p.name == dlg.data.size then
                    current_settings.pixel_width = p.width;
                    current_settings.pixel_height = p.height
                end
            end
        end
    }
    dlg:number{
        id = "colors",
        label = "Colors:",
        text = tostring(current_settings.colors),
        onchange = function()
            current_settings.colors = dlg.data.colors
        end
    }
    dlg:check{
        id = "remove_bg",
        text = "Remove Background",
        selected = current_settings.remove_background,
        onclick = function()
            current_settings.remove_background = dlg.data.remove_bg
        end
    }
    dlg:combobox{
        id = "out",
        label = "Output:",
        options = {"New Layer", "New Frame"},
        option = current_settings.output_method,
        onchange = function()
            current_settings.output_method = dlg.data.out
        end
    }
    dlg:separator{}

    dlg:button{
        text = "Model Settings",
        onclick = open_model_dialog
    }
    dlg:button{
        text = "Advanced Settings",
        onclick = open_advanced_dialog
    }
    dlg:separator{}
    dlg:label{
        id = "generation_time_label",
        text = "Ready"
    }
    dlg:button{
        id = "generate",
        text = "Generate Image",
        focus = true,
        onclick = function()
            if not current_settings.prompt or current_settings.prompt == "" then
                app.alert("Prompt is empty");
                return
            end
            update_dialog_status(dlg)
            generate_image(current_settings, function(res, err)
                update_dialog_status(dlg)
                if err then
                    app.alert("Error: " .. err)
                elseif res and res.success then
                    place_image_in_aseprite_raw(res.image, current_settings.output_method)
                else
                    app.alert("Failed: " .. (res and res.error or "Unknown"))
                end
            end)
        end
    }
    dlg:show({
        wait = false
    })
    update_dialog_status(dlg)
end

fetch_models_and_loras(create_main_dialog)

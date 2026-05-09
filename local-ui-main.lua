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

local json = safe_dofile("json.lua")
local base64 = safe_dofile("base64.lua")
local http_client = safe_dofile("http-client.lua")

if not json or not base64 or not http_client then
    app.alert("Failed to load required libraries. Please ensure all files are in the same directory.")
    return
end

local plugin_config = {
    server_url = "http://127.0.0.1:5000",
    name = "Local AI Generator v2.0",
    version = "2.0",
    request_timeout = 300
}

local is_generating = false
local generation_cancelled = false
local current_dialog = nil
local available_models = {"ponyDiffusionV6XL_v6StartWithThisOne.safetensors"}
local available_loras = {"None"}
local server_status = "Unknown"
local last_generation_time = 0
local loading_timer = nil
local loading_dots = 0
local last_successful_seed = -1
local request_start_time = nil

-- =====================================
-- Dialog References (FIX: ป้องกันซ้อนกัน)
-- =====================================
local advanced_dialog = nil
local model_dialog = nil
local profiles_dialog = nil

local function close_all_subdialogs()
    if advanced_dialog then
        advanced_dialog:close();
        advanced_dialog = nil
    end
    if model_dialog then
        model_dialog:close();
        model_dialog = nil
    end
    if profiles_dialog then
        profiles_dialog:close();
        profiles_dialog = nil
    end
end

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

-- =====================================
-- Profile System
-- =====================================
local profiles_file_path = script_dir .. "/ai_profiles.json"
local saved_profiles = {}

local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
    else
        copy = orig
    end
    return copy
end

local function load_profiles_from_disk()
    local file = io.open(profiles_file_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local success, decoded = pcall(json.decode, content)
        if success and type(decoded) == "table" then
            saved_profiles = decoded
            return
        end
    end
    saved_profiles = {
        ["Default"] = deepcopy(current_settings)
    }
end

local function save_profiles_to_disk()
    local file = io.open(profiles_file_path, "w")
    if file then
        file:write(json.encode(saved_profiles))
        file:close()
    end
end

local function get_profile_names()
    local names = {}
    for k, _ in pairs(saved_profiles) do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

-- =====================================
-- Preset Data
-- =====================================
local preset_prompts =
    {"pixel art, single lone character, cyberpunk girl with neon glowing hair, solo, futuristic visor, detailed sprite",
     "pixel art, single character, brave knight in shining plate armor, standing, solo, fantasy RPG, 16-bit sprite",
     "pixel art, one single character, cute slime monster, solo, squishy, expressive eyes, flat colors",
     "pixel art, single character, wizard with a long white beard, solo, holding a wooden staff, magical robe",
     "pixel art, single character, vampire lord, solo, red cape, gothic style, pale skin, 16-bit masterpiece",
     "shirosu00, chibi, 1girl, solo, Makima, red hair, braid, yellow concentric eyes, white shirt, black tie, smug smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, floating chains, simple red background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime",
     "shirosu00, chibi, 1girl, solo, Reze, short dark purple hair, braided side bangs, green eyes, school uniform, playful smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, bomb pin, simple blue background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime"}

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
}, {
    name = "Portrait (64x96)",
    width = 64,
    height = 96
}, {
    name = "Landscape (96x64)",
    width = 96,
    height = 64
}}

local size_options = {}
for _, p in ipairs(dimension_presets) do
    table.insert(size_options, p.name)
end

-- =====================================
-- Utilities
-- =====================================
local function format_time(seconds)
    if seconds < 60 then
        return string.format("%.1fs", seconds)
    end
    return string.format("%.1fm", seconds / 60)
end

local function format_seed(seed_val)
    if not seed_val or seed_val <= 0 then
        return "-1"
    end
    return string.format("%.0f", seed_val)
end

local function set_status_bar(msg)
    app.statusBar = tostring(msg or "")
    app.refresh()
end

-- =====================================
-- Server Communication
-- =====================================
local function fetch_models_and_loras(callback)
    server_status = "Connecting..."
    set_status_bar("Connecting to server...")
    http_client.get(plugin_config.server_url .. "/models", function(res, err)
        if res and res.models then
            available_models = res.models
        end
        http_client.get(plugin_config.server_url .. "/loras", function(res2, err2)
            if res2 and res2.loras then
                available_loras = res2.loras
            end
            http_client.get(plugin_config.server_url .. "/health", function(health_res, health_err)
                if health_res then
                    server_status = "Online" ..
                                        (health_res.current_model and (" -- " .. health_res.current_model) or "")
                else
                    server_status = "Offline"
                end
                if callback then
                    callback()
                end
            end)
        end)
    end)
end

local function generate_image(settings, callback)
    if is_generating then
        return
    end
    is_generating = true
    generation_cancelled = false
    request_start_time = os.time()
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

    local function check_timeout()
        if request_start_time and (os.time() - request_start_time) > plugin_config.request_timeout then
            return true
        end
        return false
    end

    http_client.post(plugin_config.server_url .. "/generate", request_data, function(response, error)
        if generation_cancelled then
            is_generating = false
            if callback then
                callback(nil, "Generation cancelled by user")
            end
            return
        end
        if check_timeout() then
            is_generating = false
            if callback then
                callback(nil, "Request timed out (" .. plugin_config.request_timeout .. "s)")
            end
            return
        end
        is_generating = false
        last_generation_time = os.clock() - start_time
        request_start_time = nil
        if callback then
            callback(response, error)
        end
    end)
end

-- =====================================
-- Aseprite Image Placement
-- =====================================
local function prepare_image_for_generation(output_method, image_mode)
    local cel
    app.transaction("AI Generation Setup", function()
        local layer = app.activeSprite:newLayer({
            name = "AI Gen " .. os.date("%H:%M:%S"),
            colorMode = image_mode
        })
        app.activeLayer = layer
        local frame = (output_method == "New Frame") and app.activeSprite:newEmptyFrame() or app.activeFrame
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

-- =====================================
-- Dialog Status Updater
-- =====================================
local function update_dialog_status(dlg)
    if not dlg then
        return
    end
    if is_generating then
        dlg:modify{
            id = "generate",
            enabled = false
        }
        dlg:modify{
            id = "cancel_btn",
            visible = true,
            enabled = true
        }
        if not loading_timer then
            loading_timer = Timer {
                interval = 0.25,
                ontick = function()
                    if not is_generating then
                        loading_timer:stop();
                        loading_timer = nil;
                        return
                    end
                    if request_start_time and (os.time() - request_start_time) > plugin_config.request_timeout then
                        generation_cancelled = true;
                        is_generating = false
                        loading_timer:stop();
                        loading_timer = nil
                        dlg:modify{
                            id = "server_status_label",
                            text = "Status: Timeout"
                        }
                        dlg:modify{
                            id = "generate",
                            enabled = true,
                            text = "Generate Image"
                        }
                        dlg:modify{
                            id = "cancel_btn",
                            visible = false
                        }
                        app.alert("Request timed out. Please try again.")
                        set_status_bar("Timeout")
                        return
                    end
                    loading_dots = (loading_dots + 1) % 4
                    local dots = string.rep(".", loading_dots)
                    dlg:modify{
                        id = "server_status_label",
                        text = "Status: Generating AI" .. dots
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
        if loading_timer then
            loading_timer:stop();
            loading_timer = nil
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
        dlg:modify{
            id = "cancel_btn",
            visible = false,
            enabled = false
        }
        if last_generation_time > 0 then
            dlg:modify{
                id = "generation_time_label",
                text = "Time: " .. format_time(last_generation_time)
            }
        end
    end
end

-- =====================================
-- Sub-dialogs (FIXED)
-- =====================================
local function open_advanced_dialog()
    if advanced_dialog then
        advanced_dialog:close();
        advanced_dialog = nil
    end
    local adv = Dialog("Advanced Settings");
    advanced_dialog = adv
    adv:separator{
        text = "Sampling"
    }
    adv:slider{
        id = "steps",
        label = "Steps:",
        min = 10,
        max = 50,
        value = current_settings.steps,
        onchange = function()
            current_settings.steps = adv.data.steps
        end
    }
    adv:slider{
        id = "guidance_scale",
        label = "Guidance:",
        min = 1,
        max = 20,
        value = current_settings.guidance_scale,
        onchange = function()
            current_settings.guidance_scale = adv.data.guidance_scale
        end
    }
    adv:separator{
        text = "Output"
    }
    adv:combobox{
        id = "out",
        label = "Place On:",
        options = {"New Layer", "New Frame"},
        option = current_settings.output_method,
        onchange = function()
            current_settings.output_method = adv.data.out
        end
    }
    adv:separator{}
    adv:button{
        text = "Close",
        onclick = function()
            advanced_dialog = nil;
            adv:close()
        end
    }
    adv:show{
        wait = false
    }
end

local function open_model_dialog()
    if model_dialog then
        model_dialog:close();
        model_dialog = nil
    end
    local mdl = Dialog("Model Settings");
    model_dialog = mdl
    mdl:separator{
        text = "Model"
    }
    mdl:combobox{
        id = "model_name",
        label = "Checkpoint:",
        options = available_models,
        option = current_settings.model_name,
        onchange = function()
            current_settings.model_name = mdl.data.model_name
            server_status = "Ready -- " .. current_settings.model_name
            update_dialog_status(current_dialog)
        end
    }
    mdl:combobox{
        id = "quality",
        label = "Render Quality:",
        options = {"Fast (512x512)", "High (1024x1024)", "Ultra (1536x1536)"},
        option = current_settings.generation_quality,
        onchange = function()
            current_settings.generation_quality = mdl.data.quality
        end
    }
    mdl:separator{
        text = "LoRA"
    }
    mdl:combobox{
        id = "lora",
        label = "LoRA Model:",
        options = available_loras,
        option = current_settings.lora_model,
        onchange = function()
            current_settings.lora_model = mdl.data.lora
        end
    }
    mdl:slider{
        id = "lora_str",
        label = "Strength:",
        min = 0,
        max = 200,
        value = math.floor(current_settings.lora_strength * 100),
        onchange = function()
            current_settings.lora_strength = mdl.data.lora_str / 100
            mdl:modify{
                id = "str_val",
                text = string.format("Value: %.2f", current_settings.lora_strength)
            }
        end
    }
    mdl:label{
        id = "str_val",
        text = string.format("Value: %.2f", current_settings.lora_strength)
    }
    mdl:separator{}
    mdl:button{
        text = "Close",
        onclick = function()
            model_dialog = nil;
            mdl:close()
        end
    }
    mdl:show{
        wait = false
    }
end

local create_main_dialog

local function open_profiles_dialog()
    if profiles_dialog then
        profiles_dialog:close();
        profiles_dialog = nil
    end
    local names = get_profile_names()
    local selected_profile = names[1] or "Default"
    local p_dlg = Dialog("Manage Profiles");
    profiles_dialog = p_dlg
    p_dlg:separator{
        text = "Load Profile"
    }
    p_dlg:combobox{
        id = "profile_select",
        label = "Profile:",
        options = names,
        option = selected_profile,
        onchange = function()
            selected_profile = p_dlg.data.profile_select
        end
    }
    p_dlg:button{
        text = "Load Selected",
        onclick = function()
            if saved_profiles[selected_profile] then
                current_settings = deepcopy(saved_profiles[selected_profile])
                app.alert("Loaded: " .. selected_profile)
                profiles_dialog = nil;
                p_dlg:close();
                create_main_dialog()
            end
        end
    }
    p_dlg:separator{
        text = "Save / Delete"
    }
    p_dlg:button{
        text = "Save Current As...",
        onclick = function()
            local save_dlg = Dialog("Save Profile")
            save_dlg:entry{
                id = "p_name",
                label = "Name:",
                text = selected_profile
            }
            save_dlg:button{
                text = "Save",
                onclick = function()
                    local new_name = save_dlg.data.p_name
                    if new_name and new_name ~= "" then
                        saved_profiles[new_name] = deepcopy(current_settings);
                        save_profiles_to_disk()
                        app.alert("Saved: " .. new_name);
                        save_dlg:close();
                        profiles_dialog = nil;
                        p_dlg:close()
                        open_profiles_dialog()
                    end
                end
            }
            save_dlg:button{
                text = "Cancel"
            }
            save_dlg:show()
        end
    }
    p_dlg:button{
        text = "Delete Selected",
        onclick = function()
            if selected_profile == "Default" then
                app.alert("The Default profile cannot be deleted.");
                return
            end
            saved_profiles[selected_profile] = nil;
            save_profiles_to_disk()
            app.alert("Deleted: " .. selected_profile);
            profiles_dialog = nil;
            p_dlg:close();
            open_profiles_dialog()
        end
    }
    p_dlg:separator{}
    p_dlg:button{
        text = "Close",
        onclick = function()
            profiles_dialog = nil;
            p_dlg:close()
        end
    }
    p_dlg:show{
        wait = false
    }
end

-- =====================================
-- Main Dialog
-- =====================================
function create_main_dialog()
    close_all_subdialogs()
    if current_dialog then
        current_dialog:close()
    end
    if loading_timer then
        loading_timer:stop();
        loading_timer = nil
    end
    if is_generating then
        is_generating = false;
        generation_cancelled = false
    end

    local dlg = Dialog("Local AI Generator v2.0");
    current_dialog = dlg
    local current_size_name = "Small (64x64)"
    for _, p in ipairs(dimension_presets) do
        if p.width == current_settings.pixel_width and p.height == current_settings.pixel_height then
            current_size_name = p.name;
            break
        end
    end

    dlg:separator{
        text = "Server"
    }
    dlg:label{
        id = "server_status_label",
        text = "Status: " .. server_status
    }
    dlg:label{
        id = "generation_time_label",
        text = "Time: --"
    }
    dlg:button{
        text = "Refresh Status",
        onclick = function()
            fetch_models_and_loras(function()
                update_dialog_status(dlg)
            end)
        end
    }

    dlg:separator{
        text = "Prompt"
    }
    dlg:entry{
        id = "prompt",
        label = "Positive:",
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
        label = "Quick Preset:",
        options = preset_prompts,
        onchange = function()
            current_settings.prompt = dlg.data.preset
            dlg:modify{
                id = "prompt",
                text = current_settings.prompt
            }
        end
    }

    dlg:separator{
        text = "Canvas"
    }
    dlg:combobox{
        id = "size",
        label = "Sprite Size:",
        options = size_options,
        option = current_size_name,
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
        label = "Color Depth:",
        text = tostring(current_settings.colors),
        onchange = function()
            current_settings.colors = math.floor(dlg.data.colors or 16)
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

    dlg:separator{
        text = "Seed"
    }
    dlg:entry{
        id = "seed_val",
        label = "Seed Value:",
        text = format_seed(current_settings.seed),
        onchange = function()
            local cleaned = dlg.data.seed_val:gsub("[^%d%-]", "")
            if dlg.data.seed_val ~= cleaned then
                dlg:modify{
                    id = "seed_val",
                    text = cleaned
                }
            end
            current_settings.seed = tonumber(cleaned) or -1
        end
    }
    dlg:label{
        id = "seed_result_label",
        text = "Last Seed: " .. format_seed(last_successful_seed)
    }
    dlg:button{
        text = "Reset (-1)",
        onclick = function()
            dlg:modify{
                id = "seed_val",
                text = "-1"
            };
            current_settings.seed = -1
        end
    }
    dlg:button{
        text = "Reuse Last Seed",
        onclick = function()
            if last_successful_seed > 0 then
                dlg:modify{
                    id = "seed_val",
                    text = format_seed(last_successful_seed)
                }
                current_settings.seed = last_successful_seed
            else
                app.alert("No previous seed found.")
            end
        end
    }

    dlg:separator{
        text = "Settings"
    }
    dlg:button{
        text = "Model",
        onclick = open_model_dialog
    }
    dlg:button{
        text = "Advanced",
        onclick = open_advanced_dialog
    }
    dlg:button{
        text = "Profiles",
        onclick = function()
            current_settings.prompt = dlg.data.prompt
            current_settings.negative_prompt = dlg.data.negative_prompt
            current_settings.colors = math.floor(dlg.data.colors or 16)
            current_settings.remove_background = dlg.data.remove_bg
            open_profiles_dialog()
        end
    }

    dlg:separator{}
    dlg:button{
        id = "generate",
        text = "Generate Image",
        focus = true,
        onclick = function()
            current_settings.prompt = dlg.data.prompt
            current_settings.negative_prompt = dlg.data.negative_prompt
            current_settings.remove_background = dlg.data.remove_bg
            current_settings.colors = math.floor(dlg.data.colors or 16)
            current_settings.seed = tonumber(dlg.data.seed_val) or -1
            dlg:modify{
                id = "seed_val",
                text = format_seed(current_settings.seed)
            }
            if not current_settings.prompt or current_settings.prompt:match("^%s*$") then
                app.alert("Prompt cannot be empty.");
                return
            end
            set_status_bar("Generating...");
            update_dialog_status(dlg)
            generate_image(current_settings, function(res, err)
                update_dialog_status(dlg)
                if err then
                    app.alert("Error: " .. tostring(err));
                    set_status_bar("Error: " .. tostring(err))
                elseif res and res.success then
                    if res.seed then
                        last_successful_seed = res.seed
                        dlg:modify{
                            id = "seed_result_label",
                            text = "Last Seed: " .. format_seed(res.seed)
                        }
                    end
                    place_image_in_aseprite_raw(res.image, current_settings.output_method);
                    set_status_bar("Done")
                else
                    app.alert("Generation failed: " .. (res and res.error or "Unknown error"));
                    set_status_bar("Failed")
                end
            end)
        end
    }

    dlg:button{
        id = "cancel_btn",
        text = "Cancel",
        visible = false,
        enabled = false,
        onclick = function()
            if is_generating then
                generation_cancelled = true;
                is_generating = false;
                request_start_time = nil
                if loading_timer then
                    loading_timer:stop();
                    loading_timer = nil
                end
                dlg:modify{
                    id = "server_status_label",
                    text = "Status: Cancelled"
                }
                dlg:modify{
                    id = "generate",
                    enabled = true,
                    text = "Generate Image"
                }
                dlg:modify{
                    id = "cancel_btn",
                    visible = false
                }
                app.alert("Generation cancelled");
                set_status_bar("Cancelled")
            end
        end
    }

    dlg:show{
        wait = false
    }
    update_dialog_status(dlg)
end

-- =====================================
-- Entry Point
-- =====================================
load_profiles_from_disk()
fetch_models_and_loras(create_main_dialog)

-- local-ui-main.lua
-- Main UI module for Aseprite AI Generator

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

-- Load modular services and libraries
local base64 = safe_dofile("libs/base64.lua")
local settings_store = safe_dofile("libs/settings-store.lua")
local api_service = safe_dofile("libs/api-service.lua")

if not base64 or not settings_store or not api_service then
    app.alert("Failed to load required libraries. Please ensure all files are inside 'libs/' folder.")
    return
end

-- Local shortcuts to settings and API states
local current_settings = settings_store.current_settings
local plugin_config = api_service.config

local current_dialog = nil
local advanced_dialog = nil
local model_dialog = nil
local profiles_dialog = nil

local loading_timer = nil
local loading_dots = 0

-- =====================================
-- Subdialog Manager
-- =====================================
local function close_all_subdialogs()
    if advanced_dialog then advanced_dialog:close() advanced_dialog = nil end
    if model_dialog then model_dialog:close() model_dialog = nil end
    if profiles_dialog then profiles_dialog:close() profiles_dialog = nil end
end

-- =====================================
-- Preset Data
-- =====================================
local preset_prompts = {
    "pixel art, single lone character, cyberpunk girl with neon glowing hair, solo, futuristic visor, detailed sprite",
    "pixel art, single character, brave knight in shining plate armor, standing, solo, fantasy RPG, 16-bit sprite",
    "pixel art, one single character, cute slime monster, solo, squishy, expressive eyes, flat colors",
    "pixel art, isometric landscape, tiny retro house, garden, fantasy world, vintage colors, game scene"
}

local dimension_presets = {
    { name = "Tiny (32x32)", width = 32, height = 32 },
    { name = "Small (64x64)", width = 64, height = 64 },
    { name = "Medium (128x128)", width = 128, height = 128 },
    { name = "Large (256x256)", width = 256, height = 256 }
}

local size_options = {}
for _, p in ipairs(dimension_presets) do
    table.insert(size_options, p.name)
end

-- =====================================
-- Helper Formatters
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
    local target_w = current_settings.pixel_width
    local target_h = current_settings.pixel_height
    local image_mode = ColorMode.RGB 

    if not app.activeSprite then
        app.command.NewFile({
            width = target_w,
            height = target_h,
            colorMode = image_mode
        })
    end

    local cel = prepare_image_for_generation(output_method, image_mode)

    local decode_success, pixel_data = pcall(base64.decode, image_data.base64)
    if not decode_success or not pixel_data then
        app.alert("Error: Failed to decode image data from server.")
        return
    end

    app.transaction("Place AI Image", function()
        local success, err = pcall(function()
            local im = Image(target_w, target_h, image_mode)
            im.bytes = pixel_data
            cel.image = im
        end)

        if not success then
            print("Error placing image: " .. tostring(err))
        end
    end)

    app.refresh()
end

-- =====================================
-- Dialog Status Updater
-- =====================================
local function update_dialog_status(dlg)
    if not dlg then return end

    if api_service.is_generating then
        dlg:modify{ id = "generate", enabled = false }
        dlg:modify{ id = "cancel_btn", visible = true, enabled = true }

        if not loading_timer then
            loading_timer = Timer {
                interval = 0.25,
                ontick = function()
                    if not api_service.is_generating then
                        if loading_timer then loading_timer:stop() loading_timer = nil end
                        return
                    end
                    if api_service.request_start_time and (os.time() - api_service.request_start_time) > plugin_config.request_timeout then
                        api_service.generation_cancelled = true
                        api_service.is_generating = false
                        if loading_timer then loading_timer:stop() loading_timer = nil end
                        dlg:modify{ id = "server_status_label", text = "Status: Timeout" }
                        dlg:modify{ id = "generate", enabled = true, text = "Generate Image" }
                        dlg:modify{ id = "cancel_btn", visible = false }
                        app.alert("Request timed out. Please try again.")
                        set_status_bar("Timeout")
                        return
                    end
                    loading_dots = (loading_dots + 1) % 4
                    local dots = string.rep(".", loading_dots)
                    dlg:modify{ id = "server_status_label", text = "Status: Generating" .. dots }
                end
            }
            loading_timer:start()
        end
    else
        if loading_timer then
            loading_timer:stop()
            loading_timer = nil
        end
        dlg:modify{ id = "generate", enabled = true, text = "Generate Image" }
        dlg:modify{ id = "cancel_btn", visible = false, enabled = false }
        dlg:modify{ id = "server_status_label", text = "Status: " .. api_service.server_status }
        
        if api_service.last_generation_time > 0 then
            dlg:modify{ id = "generation_time_label", text = "Time: " .. format_time(api_service.last_generation_time) }
        else
            dlg:modify{ id = "generation_time_label", text = "Time: --" }
        end
    end
end

-- =====================================
-- Subdialog Creators
-- =====================================
local function open_advanced_dialog()
    if advanced_dialog then advanced_dialog:close() advanced_dialog = nil end
    local adv = Dialog("Advanced Pixel Settings")
    advanced_dialog = adv

    adv:separator{ text = "Diffusion Parameters" }
    adv:number{
        id = "cfg",
        label = "CFG Scale:",
        text = string.format("%.1f", current_settings.guidance_scale),
        decimals = 1,
        onchange = function()
            current_settings.guidance_scale = tonumber(adv.data.cfg) or 7.5
        end
    }
    adv:slider{
        id = "steps",
        label = "Steps:",
        min = 1,
        max = 100,
        value = current_settings.steps,
        onchange = function()
            current_settings.steps = adv.data.steps
        end
    }
    adv:separator{ text = "Background Removal" }
    adv:slider{
        id = "bg_threshold",
        label = "BG Remove Threshold:",
        min = 10,
        max = 90,
        value = math.floor((current_settings.remove_background_threshold or 0.5) * 100),
        onchange = function()
            current_settings.remove_background_threshold = adv.data.bg_threshold / 100
        end
    }
    adv:separator{ text = "Canvas Output" }
    adv:combobox{
        id = "out",
        label = "Target:",
        options = { "New Frame", "New Layer" },
        option = current_settings.output_method,
        onchange = function()
            current_settings.output_method = adv.data.out
        end
    }
    adv:separator{}
    adv:button{
        text = "Close",
        onclick = function()
            advanced_dialog = nil
            adv:close()
        end
    }
    adv:show{ wait = false }
end

local function open_model_dialog()
    if model_dialog then model_dialog:close() model_dialog = nil end
    local mdl = Dialog("Model Settings")
    model_dialog = mdl

    mdl:separator{ text = "Model" }
    mdl:combobox{
        id = "model_name",
        label = "Checkpoint:",
        options = api_service.available_models,
        option = current_settings.model_name,
        onchange = function()
            current_settings.model_name = mdl.data.model_name
            api_service.server_status = "Ready -- " .. current_settings.model_name
            update_dialog_status(current_dialog)
        end
    }
    mdl:combobox{
        id = "quality",
        label = "Render Quality:",
        options = { "Fast (512x512)", "High (1024x1024)", "Ultra (1536x1536)" },
        option = current_settings.generation_quality,
        onchange = function()
            current_settings.generation_quality = mdl.data.quality
        end
    }
    mdl:separator{ text = "LoRA" }
    mdl:combobox{
        id = "lora",
        label = "LoRA Model:",
        options = api_service.available_loras,
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
            mdl:modify{ id = "str_val", text = string.format("Value: %.2f", current_settings.lora_strength) }
        end
    }
    mdl:label{ id = "str_val", text = string.format("Value: %.2f", current_settings.lora_strength) }
    mdl:separator{}
    mdl:button{
        id = "refresh_btn",
        text = "Refresh Lists",
        onclick = function()
            api_service.fetch_models_and_loras(function()
                if model_dialog then
                    model_dialog:modify{ id = "model_name", options = api_service.available_models }
                    model_dialog:modify{ id = "lora", options = api_service.available_loras }
                    app.alert("Models and LoRAs lists refreshed from server!")
                end
            end)
        end
    }
    mdl:button{
        text = "Close",
        onclick = function()
            model_dialog = nil
            mdl:close()
        end
    }
    mdl:show{ wait = false }
end

local create_main_dialog

local function open_profiles_dialog()
    if profiles_dialog then profiles_dialog:close() profiles_dialog = nil end
    local names = settings_store.get_profile_names()
    local selected_profile = names[1] or "Default"
    local p_dlg = Dialog("Manage Profiles")
    profiles_dialog = p_dlg

    p_dlg:separator{ text = "Load Profile" }
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
            if settings_store.saved_profiles[selected_profile] then
                settings_store.current_settings = settings_store.deepcopy(settings_store.saved_profiles[selected_profile])
                current_settings = settings_store.current_settings
                app.alert("Loaded: " .. selected_profile)
                profiles_dialog = nil
                p_dlg:close()
                create_main_dialog()
            end
        end
    }
    p_dlg:separator{ text = "Save / Delete" }
    p_dlg:button{
        text = "Save Current As...",
        onclick = function()
            local save_dlg = Dialog("Save Profile")
            save_dlg:entry{ id = "p_name", label = "Name:", text = selected_profile }
            save_dlg:button{
                text = "Save",
                onclick = function()
                    local new_name = save_dlg.data.p_name
                    if new_name and new_name ~= "" then
                        settings_store.saved_profiles[new_name] = settings_store.deepcopy(current_settings)
                        settings_store.save_profiles_to_disk()
                        app.alert("Saved: " .. new_name)
                        save_dlg:close()
                        profiles_dialog = nil
                        p_dlg:close()
                        open_profiles_dialog()
                    end
                end
            }
            save_dlg:button{ text = "Cancel" }
            save_dlg:show()
        end
    }
    p_dlg:button{
        text = "Delete Selected",
        onclick = function()
            if selected_profile == "Default" then
                app.alert("The Default profile cannot be deleted.")
                return
            end
            settings_store.saved_profiles[selected_profile] = nil
            settings_store.save_profiles_to_disk()
            app.alert("Deleted: " .. selected_profile)
            profiles_dialog = nil
            p_dlg:close()
            open_profiles_dialog()
        end
    }
    p_dlg:separator{}
    p_dlg:button{
        text = "Close",
        onclick = function()
            profiles_dialog = nil
            p_dlg:close()
        end
    }
    p_dlg:show{ wait = false }
end

-- =====================================
-- Main Dialog Implementation
-- =====================================
function create_main_dialog()
    close_all_subdialogs()
    if current_dialog then current_dialog:close() end
    if loading_timer then loading_timer:stop() loading_timer = nil end

    local dlg = Dialog("Local AI Generator v1.0.4")
    current_dialog = dlg
    local current_size_name = "Small (64x64)"
    for _, p in ipairs(dimension_presets) do
        if p.width == current_settings.pixel_width and p.height == current_settings.pixel_height then
            current_size_name = p.name
            break
        end
    end

    dlg:separator{ text = "Server" }
    dlg:label{ id = "server_status_label", text = "Status: " .. api_service.server_status }
    dlg:label{ id = "generation_time_label", text = "Time: --" }
    dlg:button{
        text = "Refresh Status",
        onclick = function()
            api_service.fetch_models_and_loras(function()
                update_dialog_status(dlg)
            end)
        end
    }

    dlg:separator{ text = "Prompt" }
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
            dlg:modify{ id = "prompt", text = current_settings.prompt }
        end
    }

    dlg:separator{ text = "Canvas" }
    dlg:combobox{
        id = "size",
        label = "Sprite Size:",
        options = size_options,
        option = current_size_name,
        onchange = function()
            for _, p in ipairs(dimension_presets) do
                if p.name == dlg.data.size then
                    current_settings.pixel_width = p.width
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

    dlg:separator{ text = "Seed" }
    dlg:entry{
        id = "seed_val",
        label = "Seed Value:",
        text = format_seed(current_settings.seed),
        onchange = function()
            local cleaned = dlg.data.seed_val:gsub("[^%d%-]", "")
            if dlg.data.seed_val ~= cleaned then
                dlg:modify{ id = "seed_val", text = cleaned }
            end
            current_settings.seed = tonumber(cleaned) or -1
        end
    }
    dlg:label{ id = "seed_result_label", text = "Last Seed: " .. format_seed(api_service.last_successful_seed) }
    dlg:button{
        text = "Reset (-1)",
        onclick = function()
            dlg:modify{ id = "seed_val", text = "-1" }
            current_settings.seed = -1
        end
    }
    dlg:button{
        text = "Reuse Last Seed",
        onclick = function()
            if api_service.last_successful_seed > 0 then
                dlg:modify{ id = "seed_val", text = format_seed(api_service.last_successful_seed) }
                current_settings.seed = api_service.last_successful_seed
            else
                app.alert("No previous seed found.")
            end
        end
    }

    dlg:separator{ text = "Settings" }
    dlg:button{ text = "Model", onclick = open_model_dialog }
    dlg:button{ text = "Advanced", onclick = open_advanced_dialog }
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
            dlg:modify{ id = "seed_val", text = format_seed(current_settings.seed) }

            if not current_settings.prompt or current_settings.prompt:match("^%s*$") then
                app.alert("Prompt cannot be empty.")
                return
            end

            set_status_bar("Generating...")
            update_dialog_status(dlg)
            api_service.generate_image(current_settings, function(res, err)
                update_dialog_status(dlg)
                if err then
                    app.alert("Error: " .. tostring(err))
                    set_status_bar("Error: " .. tostring(err))
                elseif res and res.success then
                    if res.seed then
                        api_service.last_successful_seed = res.seed
                        dlg:modify{ id = "seed_result_label", text = "Last Seed: " .. format_seed(res.seed) }
                    end
                    place_image_in_aseprite_raw(res.image, current_settings.output_method)
                    set_status_bar("Done")
                else
                    app.alert("Generation failed: " .. (res and res.error or "Unknown error"))
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
            if api_service.is_generating then
                api_service.generation_cancelled = true
                api_service.is_generating = false
                api_service.request_start_time = nil
                if loading_timer then loading_timer:stop() loading_timer = nil end
                dlg:modify{ id = "server_status_label", text = "Status: Cancelled" }
                dlg:modify{ id = "generate", enabled = true, text = "Generate Image" }
                dlg:modify{ id = "cancel_btn", visible = false }
                app.alert("Generation cancelled")
                set_status_bar("Cancelled")
            end
        end
    }

    dlg:show{ wait = false }
    update_dialog_status(dlg)
end

-- =====================================
-- Entry Point
-- =====================================
settings_store.load_profiles_from_disk()
create_main_dialog()

-- Fetch models and loras in background without blocking UI startup
api_service.fetch_models_and_loras(function()
    update_dialog_status(current_dialog)
    -- Sync default model from server if user is still using the standard client default
    if api_service.default_model and current_settings.model_name == "stabilityai/stable-diffusion-xl-base-1.0" then
        current_settings.model_name = api_service.default_model
        api_service.server_status = "Ready -- " .. current_settings.model_name
        update_dialog_status(current_dialog)
    end
    -- Update open model settings dialog if it is open when fetch completes
    if model_dialog then
        model_dialog:modify{ id = "model_name", options = api_service.available_models, option = current_settings.model_name }
        model_dialog:modify{ id = "lora", options = api_service.available_loras, option = current_settings.lora_model }
    end
end)
update_dialog_status(current_dialog)

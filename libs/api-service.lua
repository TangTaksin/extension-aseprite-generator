-- api-service.lua
-- Manages communications with the Flask backend server

local libs_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local http_client = dofile(libs_dir .. "/http-client.lua")

local api_service = {}

api_service.server_status = "Unknown"
api_service.default_model = nil
api_service.available_models = {
    "stabilityai/stable-diffusion-xl-base-1.0",
    "runwayml/stable-diffusion-v1-5"
}
api_service.available_loras = {"None"}
api_service.last_successful_seed = -1
api_service.is_generating = false
api_service.generation_cancelled = false
api_service.request_start_time = nil
api_service.last_generation_time = 0

local plugin_config = {
    server_url = "http://127.0.0.1:5000",
    name = "Local AI Generator v1.0.5",
    version = "1.0.5",
    request_timeout = 300
}

api_service.config = plugin_config

function api_service.fetch_models_and_loras(callback)
    api_service.server_status = "Connecting..."
    app.statusBar = "Connecting to server..."
    app.refresh()

    http_client.get(plugin_config.server_url .. "/models", function(res, err)
        if res and res.models then
            api_service.available_models = res.models
        end
        http_client.get(plugin_config.server_url .. "/loras", function(res2, err2)
            if res2 and res2.loras then
                api_service.available_loras = res2.loras
            end
            http_client.get(plugin_config.server_url .. "/health", function(health_res, health_err)
                if health_res then
                    api_service.server_status = "Online" ..
                                        (health_res.current_model and (" -- " .. health_res.current_model) or "")
                    if health_res.default_model then
                        api_service.default_model = health_res.default_model
                    end
                else
                    api_service.server_status = "Offline"
                end
                if callback then
                    callback()
                end
            end)
        end)
    end)
end

function api_service.generate_image(settings, callback)
    if api_service.is_generating then
        return
    end
    api_service.is_generating = true
    api_service.generation_cancelled = false
    api_service.request_start_time = os.time()
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
        remove_background_threshold = settings.remove_background_threshold,
        pixel_snapping = settings.pixel_snapping,
        pixel_size = settings.pixel_size_override,
        seed = settings.seed ~= -1 and settings.seed or nil,
        model_name = settings.model_name
    }

    local function check_timeout()
        if api_service.request_start_time and (os.time() - api_service.request_start_time) > plugin_config.request_timeout then
            return true
        end
        return false
    end

    http_client.post(plugin_config.server_url .. "/generate", request_data, function(response, error)
        if api_service.generation_cancelled then
            api_service.is_generating = false
            if callback then
                callback(nil, "Generation cancelled by user")
            end
            return
        end
        if check_timeout() then
            api_service.is_generating = false
            if callback then
                callback(nil, "Request timed out (" .. plugin_config.request_timeout .. "s)")
            end
            return
        end
        api_service.is_generating = false
        api_service.last_generation_time = os.clock() - start_time
        api_service.request_start_time = nil
        if callback then
            callback(response, error)
        end
    end)
end

return api_service

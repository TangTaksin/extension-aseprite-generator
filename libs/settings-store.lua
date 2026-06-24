-- settings-store.lua
-- Manages saving, loading, and profiles of user settings

local json = dofile(debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]") .. "/json.lua")

local settings_store = {}

settings_store.profiles_file_path = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]") .. "/../ai_profiles.json"
settings_store.saved_profiles = {}

settings_store.current_settings = {
    prompt = "shirosu00, chibi, 1girl, solo, Reze, short dark purple hair, braided side bangs, green eyes, school uniform, playful smile, looking at viewer, super deformed, oversized head, tiny body, pixel art, 16-bit sprite, bomb pin, simple blue background, <lora:shirosu0011:1>, score_8_up, score_7_up, score_anime",
    negative_prompt = "score_6, score_5, score_4, score_3, score_2, score_1, realistic, 3d, blurry, lowres, bad anatomy, extra limbs, extra fingers, text, watermark, duplicate",
    pixel_width = 64,
    pixel_height = 64,
    steps = 25,
    guidance_scale = 7.5,
    colors = 16,
    seed = -1,
    remove_background = false,
    remove_background_threshold = 0.5,
    pixel_snapping = false,
    pixel_size_override = 0.0,
    model_name = "stabilityai/stable-diffusion-xl-base-1.0",
    lora_model = "None",
    lora_strength = 0.8,
    output_method = "New Frame",
    generation_quality = "High (1024x1024)"
}

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

settings_store.deepcopy = deepcopy

function settings_store.load_profiles_from_disk()
    local file = io.open(settings_store.profiles_file_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local success, decoded = pcall(json.decode, content)
        if success and type(decoded) == "table" then
            settings_store.saved_profiles = decoded
            return
        end
    end
    settings_store.saved_profiles = {
        ["Default"] = deepcopy(settings_store.current_settings)
    }
end

function settings_store.save_profiles_to_disk()
    local file = io.open(settings_store.profiles_file_path, "w")
    if file then
        file:write(json.encode(settings_store.saved_profiles))
        file:close()
    end
end

function settings_store.get_profile_names()
    local names = {}
    for k, _ in pairs(settings_store.saved_profiles) do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

return settings_store

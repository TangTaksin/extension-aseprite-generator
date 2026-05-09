-- Extension wrapper for Local AI Generator
-- This just adds the button and loads the existing working script

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*)[/\\]")

-- Function to run the existing working script
local function run_ai_generator()
    -- Load and run the existing local-ui-main.lua script
    local success, result = pcall(dofile, script_dir .. "/local-ui-main.lua")
    if not success then
        app.alert("Error loading AI Generator: " .. tostring(result))
    end
end

-- Extension initialization - adds the button
function init(plugin)
    plugin:newCommand{
        id = "LocalAIGenerator",
        title = "Local AI Generator",
        group = "file_scripts",
        onclick = run_ai_generator
    }
end

-- Extension cleanup
function exit(plugin)
    -- Nothing to clean up
end
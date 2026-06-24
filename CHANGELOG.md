# Changelog — Aseprite Extension (Local AI Generator)

---

### [1.0.5]

#### Added
- Added `bg_threshold` slider (BG Remove Threshold) in Advanced Settings dialog to control the strictness of background removal (0.10 - 0.90)
- Configured default value `remove_background_threshold = 0.5` in user profiles settings

#### Changed
- Bumped extension version to `1.0.5` across config scripts, payload mappings, and UI templates

#### Removed
- Removed the Floyd-Steinberg dithering checkbox and its label separator from Advanced Settings UI

---

### [1.0.4]

#### Added
- `main.lua`: Register menu command in Aseprite (`File > Local AI Generator`)
- `local-ui-main.lua`: Main dialog UI with canvas rendering
- `libs/http-client.lua`: HTTP client for communicating with Python server
- `libs/json.lua`: JSON encoder/decoder for Lua
- `libs/base64.lua`: Base64 decoder for receiving images from API
- `libs/api-service.lua`: Request handler bridge to the server
- `libs/settings-store.lua`: Save and load user settings
- `ai_profiles.json`: Preset profiles for generation parameters

---

# Local AI Generator — Aseprite Extension

A pixel art generation extension for [Aseprite](https://www.aseprite.org/) that connects directly to a local [Stable Diffusion](https://github.com/TangTaksin/Local-Aseprite-AI-Generator) server. Generate game sprites from text prompts without sending any data to the cloud.

**Version:** 1.0.4 | **Part of:** [Aseprite AI Generator (AAG)](https://github.com/TangTaksin/Local-Aseprite-AI-Generator)

---

## Requirements

- Aseprite v1.2.10 or newer
- [AAG Python Server](https://github.com/TangTaksin/Local-Aseprite-AI-Generator) running locally on `http://127.0.0.1:5000`

---

## Features

### 🖊️ Prompt
- **Positive Prompt** — text field for your generation prompt
- **Negative Prompt** — text field to exclude unwanted elements
- **Quick Preset** — dropdown with 4 built-in example prompts (cyberpunk girl, knight, slime, isometric house)

### 🖼️ Canvas Output
- **Sprite Size** — choose output resolution: Tiny (32×32), Small (64×64), Medium (128×128), Large (256×256)
- **Color Depth** — set number of colors for pixel art quantization
- **Remove Background** — toggle AI-powered background removal via BiRefNet

### 🎲 Seed
- **Seed Value** — enter a specific seed or `-1` for random
- **Reset (-1)** — reset seed to random
- **Reuse Last Seed** — reapply the seed from the previous generation
- **Last Seed display** — shows the seed used in the last generation

### ⚙️ Model Settings (Sub-dialog)
- **Checkpoint** — select SD / SDXL model from server list
- **Render Quality** — Fast (512×512) / High (1024×1024) / Ultra (1536×1536)
- **LoRA Model** — select LoRA from server list
- **LoRA Strength** — slider from 0.00 to 2.00
- **Refresh Lists** — reload models and LoRAs from the server

### 🔬 Advanced Settings (Sub-dialog)
- **CFG Scale** — control how strictly the model follows the prompt
- **Steps** — inference steps slider (1–100)
- **Floyd-Steinberg Dithering** — optional dithering on quantization
- **Canvas Target** — output to New Frame or New Layer

### 📋 Profiles (Sub-dialog)
- **Load Profile** — load a saved settings preset
- **Save Current As...** — save current settings as a named profile
- **Delete Selected** — delete a profile (Default profile is protected)
- Built-in presets: 10 chibi character presets included in `ai_profiles.json`

### 📡 Server Status
- **Status label** — real-time server state (Connecting / Ready / Generating... / Timeout / Error)
- **Generation Time** — displays time taken for the last generation
- **Refresh Status** — manually re-check server connection
- **Cancel** — cancel an in-progress generation request (with automatic timeout)

### 📁 Aseprite Integration
- Auto-places generated image into a **New Frame** or **New Layer**
- Auto-creates a new sprite canvas if none is open
- All canvas operations support **Undo** via `app.transaction`

---

## File Structure

```
extension-aseprite-generator/
├── package.json           # Extension manifest (version, entry point)
├── main.lua               # Registers the menu command (File > Local AI Generator)
├── local-ui-main.lua      # Main dialog UI and canvas rendering logic
├── ai_profiles.json       # Saved generation profiles / presets
└── libs/
    ├── api-service.lua    # HTTP request handler to Python server
    ├── http-client.lua    # Low-level HTTP client
    ├── json.lua           # JSON encoder / decoder
    ├── base64.lua         # Base64 decoder for image data
    └── settings-store.lua # Save / load user settings to disk
```

---

## Changelog

See [CHANGELOG.md](./CHANGELOG.md)
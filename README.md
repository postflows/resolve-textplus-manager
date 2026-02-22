# TextPlus Manager

> Part of [PostFlows](https://github.com/postflows) toolkit for DaVinci Resolve

Copy style and transform text across Text+ clips or Fusion Macros on the timeline via a single-window interface.

## What it does

Manages Text+ and Fusion Macro titles: copy full style or selected parameter groups (Font, Style, Color, Size, etc.), apply text transforms (lowercase, uppercase, capitalize), remove punctuation. Supports track and clip-color filters. Source clip is playhead position; targets are filtered by track and color.

## Requirements

- DaVinci Resolve Studio
- Open project and timeline before use
- **Optional:** UTF-8 module for full Unicode support (lowercase/uppercase/capitalize for non-ASCII text). The script works without it; ASCII-only transforms still work.

## Installation

### 1. Copy the script

Copy `textplus-manager.lua` to Resolve’s Fusion Scripts folder:

- **macOS:** `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/` (or a subfolder, e.g. `Utility/TextPlus/`)
- **Windows:** `C:\ProgramData\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\`

### 2. Optional: UTF-8 module (recommended for non-ASCII text)

For correct case conversion (lower/upper/capitalize) with Unicode (e.g. Cyrillic, accented characters), copy **`utf8_module.lua`** from this repo into the **same folder** as `textplus-manager.lua`. The script uses `require("utf8_module")`, so Lua must find `utf8_module.lua` in the same directory (or on `package.path`).

- If you place the script in a subfolder (e.g. `Fusion/Scripts/Utility/TextPlus/`), place `utf8_module.lua` in that same subfolder.
- If the module is missing, the script runs without it and falls back to built-in string functions (ASCII-only for case transforms).

## Usage

1. Position playhead on source clip.
2. Click Refresh to load timeline.
3. Choose Title Type (Text+ or Fusion Macros), Track, Clip Color, Style Copy, Text Transform.
4. Apply Text Format Only or Apply Style.

## License

MIT © PostFlows

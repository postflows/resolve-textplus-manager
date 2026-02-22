-- ================================================
-- TextPlus Manager
-- Part of PostFlows toolkit for DaVinci Resolve
-- https://github.com/postflows
-- ================================================

--[[
    TextPlus Manager Unified v03 for DaVinci Resolve

    Copy style and transform text across Text+ clips or Fusion Macros on the timeline.
    Single-window interface, no tabs.

    Version 02 Changes:
    - Fixed issue with Macro/GroupOperator detection
    - Improved textplus tool detection logic
    - Added comprehensive debug output for troubleshooting

    Title Type
    - Text+: Standard Text+ titles. Copy full style (fast) or selected parameters
      (Font, Style, Size, Color, Tracking, Spacing, Layout). Transform text case
      and optionally remove punctuation.
    - Fusion Macros: MacroOperator/GroupOperator titles with published inputs.
      Copy all published (Inspector) parameters between clips with the same name.
      Text transform applies to published Styled Text and inner Text+ nodes.

    Target selection (both modes)
    - Track: All, or a specific video track.
    - Clip Color: All, or a specific clip color.
    Filters combine: e.g. "Track 1" + "Green" applies only to green clips on track 1.

    Workflow
    1. Position playhead on the source clip.
    2. Click Refresh to load the active timeline (and when switching timelines).
    3. Choose Title Type, Track, Clip Color, Style Copy, and Text Transform.
    4. Apply Text Format Only, or Apply Style, to update target clips.

    Requirements: DaVinci Resolve Studio. Open project and timeline before use.
]]

resolve = Resolve()
local projectManager = resolve:GetProjectManager()
local project = projectManager:GetCurrentProject()
if not project then
    print("[Error] No project open")
    return
end

local ctx = { timeline = project:GetCurrentTimeline() }
if not ctx.timeline then
    print("[Error] No timeline open")
    return
end

local DEBUG_MODE = false  -- Enable debug messages (set to true for troubleshooting)
local ENABLE_PROGRESS = true

-- Debug print function (must be defined early)
local function debug_print(msg)
    if DEBUG_MODE then
        print("[DEBUG] " .. tostring(msg))
    end
end

local utf8 = string
local function LoadUTF8Module()
    package.loaded.utf8_module = nil
    local ok, mod = pcall(require, "utf8_module")
    if ok and mod then return mod end
    return string
end
utf8 = LoadUTF8Module()

local function debugPrint(...)
    if DEBUG_MODE then print("[DEBUG]", ...) end
end

local function get_fusion_comp_from_clip(clip)
    if not clip then return nil end
    local ok, comp = pcall(function() return clip:GetFusionCompByIndex(1) end)
    return (ok and comp) and comp or nil
end
local function is_macro(tool)
    if not tool then return false end
    local a = tool:GetAttrs()
    return a and (a.TOOLS_RegID == "GroupOperator" or a.TOOLS_RegID == "MacroOperator")
end

local function find_macro_in_comp(comp)
    if not comp then return nil end
    for _, t in pairs(comp:GetToolList(false)) do
        if is_macro(t) then return t end
    end
    return nil
end

local function get_textplus_tool(clip)
    if not clip then return nil end
    local comp = get_fusion_comp_from_clip(clip)
    if not comp then return nil end
    
    -- IMPORTANT: First check if this is a Macro/Group
    if find_macro_in_comp(comp) then
        return nil  -- This is Macro/Group, not plain TextPlus
    end
    
    -- Now search for TextPlus without filter
    local tools = comp:GetToolList(false)  -- WITHOUT "TextPlus" filter!
    if not tools or #tools == 0 then return nil end
    
    for _, t in pairs(tools) do
        local a = t:GetAttrs()
        if a.TOOLS_RegID == "TextPlus" and t.HorizontalLeftCenterRight ~= nil then
            return t
        end
    end
    return nil  -- Changed from tools[1] to nil for safety
end

local function get_tool_settings_fast(tool)
    for _, name in ipairs({"SaveSettings", "GetSettings", "GetCurrentSettings"}) do
        local fn = tool[name]
        if fn and type(fn) == "function" then
            local ok, res = pcall(function() return fn(tool) end)
            if ok and res and type(res) == "table" then
                local has = res.Tools or res.Inputs
                if not has then
                    local n = 0
                    for _ in pairs(res) do n = n + 1 end
                    has = (n > 5)
                end
                if has then return res, name end
            end
        end
    end
    return nil, nil
end

local function apply_full_style_fast(source_tool, target_tool)
    if not source_tool or not target_tool then return false end
    local orig = ""
    local ok, v = pcall(function() return target_tool:GetInput("StyledText") end)
    if ok and v then orig = v end
    local cfg, method = get_tool_settings_fast(source_tool)
    if not cfg then return false end
    local tname = target_tool:GetAttrs().TOOLS_Name
    if cfg.Tools then
        for k, val in pairs(cfg.Tools) do
            if type(val) == "table" and val.Inputs and k ~= tname then
                cfg.Tools[tname] = val
                cfg.Tools[k] = nil
                break
            end
        end
    end
    local applied = false
    if method == "SaveSettings" and target_tool.LoadSettings then
        pcall(function() target_tool:LoadSettings(cfg) applied = true end)
    end
    if not applied and target_tool.SetSettings then
        pcall(function() target_tool:SetSettings(cfg) applied = true end)
    end
    if not applied and target_tool.LoadSettings then
        pcall(function() target_tool:LoadSettings(cfg) applied = true end)
    end
    if not applied then return false end
    pcall(function() target_tool:SetInput("StyledText", orig) end)
    return true
end

local function utf8_len(s)
    if utf8 and utf8.len then return utf8.len(s) end
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        if b < 128 then i = i + 1
        elseif b < 224 then i = i + 2
        elseif b < 240 then i = i + 3
        else i = i + 4 end
        n = n + 1
    end
    return n
end

local function utf8_sub(s, i, j)
    if utf8 and utf8.sub then return utf8.sub(s, i, j) end
    j = j or -1
    if j < 0 then j = utf8_len(s) + j + 1 end
    local start_pos, end_pos, pos, cnt = 1, #s, 1, 0
    while pos <= #s and cnt < i - 1 do
        local b = s:byte(pos)
        if b < 128 then pos = pos + 1 elseif b < 224 then pos = pos + 2 elseif b < 240 then pos = pos + 3 else pos = pos + 4 end
        cnt = cnt + 1
    end
    start_pos = pos
    while pos <= #s and cnt < j do
        local b = s:byte(pos)
        if b < 128 then pos = pos + 1 elseif b < 224 then pos = pos + 2 elseif b < 240 then pos = pos + 3 else pos = pos + 4 end
        cnt = cnt + 1
    end
    end_pos = pos - 1
    return s:sub(start_pos, end_pos)
end

local function utf8_lower(s)
    if utf8 and utf8.lower then return utf8.lower(s) end
    return string.lower(s)
end

local function utf8_upper(s)
    if utf8 and utf8.upper then return utf8.upper(s) end
    return string.upper(s)
end

local function ApplyTextTransform(text, transformType, punctuationSettings)
    if not text or type(text) ~= "string" then return text end
    local r = text
    if punctuationSettings and punctuationSettings.enabled then
        local patterns = {}
        if punctuationSettings.periods then table.insert(patterns, "%.") end
        if punctuationSettings.commas then table.insert(patterns, ",") end
        if punctuationSettings.semicolons then table.insert(patterns, ";") end
        if punctuationSettings.colons then table.insert(patterns, ":") end
        if punctuationSettings.exclamation then table.insert(patterns, "!") end
        if punctuationSettings.question then table.insert(patterns, "?") end
        if punctuationSettings.quotes then table.insert(patterns, "[\"']") end
        for _, p in ipairs(patterns) do
            r = r:gsub(p, "")
        end
        r = r:gsub("%s+", " ")
        r = r:match("^%s*(.-)%s*$") or r
    end
    if transformType == "To Lowercase" then
        return utf8_lower(r)
    elseif transformType == "To Uppercase" then
        return utf8_upper(r)
    elseif transformType == "Capitalize All Words" then
        local low = utf8_lower(r)
        local words = {}
        for w in low:gmatch("%S+") do
            if utf8_len(w) > 0 then
                table.insert(words, utf8_upper(utf8_sub(w, 1, 1)) .. utf8_sub(w, 2))
            else
                table.insert(words, w)
            end
        end
        return table.concat(words, " ")
    elseif transformType == "Capitalize First Letter" then
        if utf8_len(r) > 0 then
            return utf8_upper(utf8_sub(utf8_lower(r), 1, 1)) .. utf8_sub(utf8_lower(r), 2)
        end
    end
    return r
end

local function get_used_colors()
    local colors, seen = {}, {}
    local tc = ctx.timeline:GetTrackCount("video")
    for tr = 1, tc do
        local items = ctx.timeline:GetItemListInTrack("video", tr)
        if items then
            for _, it in ipairs(items) do
                local c = it:GetClipColor()
                if c and c ~= "" and not seen[c] then
                    seen[c] = true
                    table.insert(colors, c)
                end
            end
        end
    end
    return colors
end

local function find_textplus_clips()
    local out = {}
    local tc = ctx.timeline:GetTrackCount("video")
    for tr = 1, tc do
        local items = ctx.timeline:GetItemListInTrack("video", tr)
        if items then
            for _, it in ipairs(items) do
                local en = true
                local ok, v = pcall(function() return it:GetClipEnabled() end)
                if ok then en = v end
                if en then
                    -- ADD CHECK: ensure this is not a Macro/Group
                    local comp = get_fusion_comp_from_clip(it)
                    if comp and not find_macro_in_comp(comp) then
                        local tool = get_textplus_tool(it)
                        if tool then
                            table.insert(out, { 
                                clip = it, 
                                tool = tool, 
                                track = tr, 
                                name = it:GetName(), 
                                color = it:GetClipColor() 
                            })
                        end
                    end
                end
            end
        end
    end
    return out
end

local function sc(s, sub)
    return s and sub and string.find(s, sub, 1, true) ~= nil
end



local function is_simple_textplus(tool)
    return tool and tool.HorizontalLeftCenterRight and tool:GetAttrs().TOOLS_RegID == "TextPlus"
end



local function is_text_input_name(name)
    if not name then return false end
    if sc(name, "Styled Text") or sc(name, "StyledText") then return true end
    if sc(name, "Text") and not sc(name, "Font") and not sc(name, "Style") then return true end
    return false
end

local function get_published_inputs(comp)
    if not comp then return {}, nil end
    local op = find_macro_in_comp(comp)
    if not op then return {}, nil end
    local inputs = {}
    for _, obj in pairs(op:GetInputList()) do
        local a = obj:GetAttrs()
        local n = (a and a.INPS_Name) or "Unknown"
        local id = (a and a.INPS_ID) or "Unknown"
        if not is_text_input_name(n) then
            local ok, val = pcall(function() return obj[comp.CurrentTime] end)
            table.insert(inputs, { name = n, id = id, value = ok and val or nil, obj = obj })
        end
    end
    return inputs, op
end

local function id_set(inp)
    local m = {}
    for _, x in ipairs(inp or {}) do if x.id then m[x.id] = true end end
    return m
end

local function same_structure(a, b)
    if #a ~= #b then return false end
    local s = id_set(a)
    for _, x in ipairs(b) do if not s[x.id] then return false end end
    return true
end

local function find_fusion_macro_clips()
    local out = {}
    local tc = ctx.timeline:GetTrackCount("video")
    for tr = 1, tc do
        local items = ctx.timeline:GetItemListInTrack("video", tr)
        if items then
            for _, it in ipairs(items) do
                local en = true
                local ok, v = pcall(function() return it:GetClipEnabled() end)
                if ok then en = v end
                if not en then goto cont end
                local comp = get_fusion_comp_from_clip(it)
                if not comp or not find_macro_in_comp(comp) then goto cont end
                table.insert(out, { clip = it, comp = comp, track = tr, name = it:GetName(), color = it:GetClipColor() })
                ::cont::
            end
        end
    end
    return out
end

local function filter_by_track_color(list, track_filter, color_filter, exclude_source)
    local src = ctx.timeline:GetCurrentVideoItem()
    local out = {}
    for _, e in ipairs(list) do
        if exclude_source and e.clip == src then goto skip end
        if track_filter and e.track ~= track_filter then goto skip end
        if color_filter and e.color ~= color_filter then goto skip end
        table.insert(out, e)
        ::skip::
    end
    return out
end

local function filter_fusion_same_name(list, source_name)
    local out = {}
    for _, e in ipairs(list) do
        if e.name == source_name then table.insert(out, e) end
    end
    return out
end

local function apply_transform_macro(target_comp, transformType, punctSettings)
    local tools = target_comp:GetToolList(false)
    for _, t in pairs(tools) do
        if is_macro(t) then
            for _, obj in pairs(t:GetInputList()) do
                local a = obj:GetAttrs()
                local n = (a and a.INPS_Name) or ""
                if (sc(n, "Text") or sc(n, "StyledText")) and not sc(n, "Font") and not sc(n, "Style") then
                    local cur = obj[target_comp.CurrentTime]
                    if type(cur) == "string" and cur ~= "" then
                        local x = ApplyTextTransform(cur, transformType, punctSettings)
                        pcall(function() obj[target_comp.CurrentTime] = x end)
                    end
                end
            end
            break
        end
    end
    local tplus = target_comp:GetToolList(false, "TextPlus")
    if tplus then
        for _, tp in ipairs(tplus) do
            if is_simple_textplus(tp) then
                local cur
                local ok, v = pcall(function() return tp.StyledText and tp.StyledText[1] end)
                if ok and v and type(v) == "string" and v ~= "" then
                    cur = v
                    local x = ApplyTextTransform(cur, transformType, punctSettings)
                    pcall(function() tp.StyledText[1] = x end)
                else
                    ok, v = pcall(function() return tp:GetInput("StyledText") end)
                    if ok and v and type(v) == "string" and v ~= "" then
                        local x = ApplyTextTransform(v, transformType, punctSettings)
                        pcall(function() tp:SetInput("StyledText", x) end)
                    end
                end
            end
        end
    end
end

local PRIMARY_COLOR = "#4C956C"
local HOVER_COLOR = "#61B15A"
local TEXT_COLOR = "#ebebeb"
local BORDER_COLOR = "#3a6ea5"
local SECTION_BG = "#2A2A2A"

local PRIMARY_BUTTON = string.format([[
    QPushButton { border: 2px solid %s; border-radius: 8px; background-color: %s; color: #FFF;
        min-height: 35px; font-size: 15px; font-weight: bold; padding: 5px 15px; }
    QPushButton:hover { background-color: %s; border-color: %s; }
    QPushButton:disabled { background-color: #666; border-color: #555; color: #999; }
]], BORDER_COLOR, PRIMARY_COLOR, HOVER_COLOR, PRIMARY_COLOR)

local SECONDARY_BUTTON = string.format([[
    QPushButton { border: 1px solid %s; border-radius: 5px; background-color: %s; color: %s;
        min-height: 30px; font-size: 12px; padding: 3px 10px; }
    QPushButton:hover { background-color: #3A3A3A; }
    QPushButton:disabled { background-color: #666; color: #999; }
]], BORDER_COLOR, SECTION_BG, TEXT_COLOR)

local SECTION = string.format([[ QLabel { color: %s; font-size: 14px; font-weight: bold; padding: 5px 0; } ]], TEXT_COLOR)
local STATUS = [[ QLabel { color: #c0c0c0; font-size: 12px; padding: 3px 0; } ]]
local COMBO = string.format([[
    QComboBox { border: 1px solid %s; border-radius: 4px; padding: 5px;
        background-color: %s; color: %s; min-height: 25px; }
]], BORDER_COLOR, SECTION_BG, TEXT_COLOR)

-- Parameter groups reference for Text+ node (accurate, extracted from macro settings)
local PARAM_GROUPS = {
    Text = {
        name = "Text",
        params = {
            -- Basic
            "StyledText", "Font", "Style", "Size",
            -- Color
            "Red1", "Green1", "Blue1", "Alpha1",
            -- Justification/Anchor
            "VerticalJustificationTop", "VerticalJustificationCenter", "VerticalJustificationBottom",
            "VerticalTopCenterBottom", "CenterOnBaseOfFirstLine", "VerticallyJustified",
            "HorizontalJustificationLeft", "HorizontalJustificationCenter", "HorizontalJustificationRight",
            "HorizontalLeftCenterRight", "HorizontallyJustified",
            -- Scroll
            "Scroll", "ScrollPosition",
            -- Direction
            "Direction", "LineDirection", "ReadingDirection", "Orientation",
            -- Emphasis
            "Strikeout", "Underline", "UnderlinePosition",
            -- Range
            "Start", "End",
            -- Tabs
            "Tab", "Tab1Position", "Tab1Alignment", "Tab2Position", "Tab2Alignment",
            "Tab3Position", "Tab3Alignment", "Tab4Position", "Tab4Alignment",
            "Tab5Position", "Tab5Alignment", "Tab6Position", "Tab6Alignment",
            "Tab7Position", "Tab7Alignment", "Tab8Position", "Tab8Alignment",
            -- Advanced Font
            "ForceMonospaced", "UseFontKerning", "UseLigatures", "SplitLigatures",
            "StylisticSet", "FontFeatures",
            -- Manual Kerning/Placement
            "ManualFontKerning", "ClearSelectedKerning", "ClearAllKerning",
            "ManualFontPlacement", "ClearSelectedPlacement", "ClearAllPlacement"
        },
        subgroups = {
            Font = { "Font" },
            Style = { "Style" },
            Color = { "Red1", "Green1", "Blue1", "Alpha1" },
            Size = { "Size" },
            Spacing = { "CharacterSpacing", "LineSpacing" },  -- From Transform group
            Justification = {
                "VerticalJustificationTop", "VerticalJustificationCenter", "VerticalJustificationBottom",
                "VerticalTopCenterBottom", "CenterOnBaseOfFirstLine", "VerticallyJustified",
                "HorizontalJustificationLeft", "HorizontalJustificationCenter", "HorizontalJustificationRight",
                "HorizontalLeftCenterRight", "HorizontallyJustified"
            },
            Other = {
                -- Scroll
                "Scroll", "ScrollPosition",
                -- Direction
                "Direction", "LineDirection", "ReadingDirection", "Orientation",
                -- Emphasis
                "Strikeout", "Underline", "UnderlinePosition",
                -- Range
                "Start", "End",
                -- Tabs
                "Tab", "Tab1Position", "Tab1Alignment", "Tab2Position", "Tab2Alignment",
                "Tab3Position", "Tab3Alignment", "Tab4Position", "Tab4Alignment",
                "Tab5Position", "Tab5Alignment", "Tab6Position", "Tab6Alignment",
                "Tab7Position", "Tab7Alignment", "Tab8Position", "Tab8Alignment",
                -- Advanced Font
                "ForceMonospaced", "UseFontKerning", "UseLigatures", "SplitLigatures",
                "StylisticSet", "FontFeatures",
                -- Manual Kerning/Placement
                "ManualFontKerning", "ClearSelectedKerning", "ClearAllKerning",
                "ManualFontPlacement", "ClearSelectedPlacement", "ClearAllPlacement"
            }
        }
    },
    Layout = {
        name = "Layout",
        params = {
            -- Basic
            "LayoutType", "Wrap", "Clip",
            -- Center
            "Center", "CenterZ",
            -- Size
            "LayoutSize", "LayoutWidth", "LayoutHeight",
            -- Advanced Layout
            "Perspective", "FitCharacters", "PositionOnPath",
            -- Rotation
            "RotationOrder", "AngleX", "AngleY", "AngleZ",
            -- Background Color
            "Red", "Green", "Blue", "Alpha"
        },
        subgroups = {
            Basic = { "LayoutType", "Wrap", "Clip" },
            Center = { "Center", "CenterZ" },
            Size = { "LayoutSize", "LayoutWidth", "LayoutHeight" }
        }
    },
    Transform = {
        name = "Transform",
        params = {
            -- Basic
            "SelectTransform",
            -- Line Transform
            "LineSpacing", "LineOffset", "LineOffsetZ",
            "LineRotationOrder", "LineAngleX", "LineAngleY", "LineAngleZ",
            "LinePivot", "LinePivotZ", "LineShearX", "LineShearY",
            "LineSizeX", "LineSizeY",
            -- Word Transform
            "WordSpacing", "WordOffset", "WordOffsetZ",
            "WordRotationOrder", "WordAngleX", "WordAngleY", "WordAngleZ",
            "AdaptWordWidthToAngle",
            "WordPivot", "WordPivotZ", "WordShearX", "WordShearY",
            "WordSizeX", "WordSizeY",
            -- Character Transform
            "CharacterSpacing", "CharacterOffset", "CharacterOffsetZ",
            "CharacterRotationOrder", "CharacterAngleX", "CharacterAngleY", "CharacterAngleZ",
            "AdaptCharacterWidthToAngle",
            "CharacterPivot", "CharacterPivotZ", "CharacterShearX", "CharacterShearY",
            "CharacterSizeX", "CharacterSizeY"
        },
        subgroups = {
            Basic = { "SelectTransform" },
            Line = {
                "LineSpacing", "LineOffset", "LineOffsetZ",
                "LineRotationOrder", "LineAngleX", "LineAngleY", "LineAngleZ",
                "LinePivot", "LinePivotZ", "LineShearX", "LineShearY",
                "LineSizeX", "LineSizeY"
            },
            Word = {
                "WordSpacing", "WordOffset", "WordOffsetZ",
                "WordRotationOrder", "WordAngleX", "WordAngleY", "WordAngleZ",
                "AdaptWordWidthToAngle",
                "WordPivot", "WordPivotZ", "WordShearX", "WordShearY",
                "WordSizeX", "WordSizeY"
            },
            Character = {
                "CharacterSpacing", "CharacterOffset", "CharacterOffsetZ",
                "CharacterRotationOrder", "CharacterAngleX", "CharacterAngleY", "CharacterAngleZ",
                "AdaptCharacterWidthToAngle",
                "CharacterPivot", "CharacterPivotZ", "CharacterShearX", "CharacterShearY",
                "CharacterSizeX", "CharacterSizeY"
            }
        }
    },
    Shading = {
        name = "Shading",
        params = {},
        subgroups = {}
    }
}

-- Build Shading parameters for elements 1-8
local shading_element_params = {
    "Name", "Enabled", "Opacity", "Overlap", "ElementShape", "Thickness",
    "AdaptThicknessToPerspective", "OutsideOnly", "CleanIntersections",
    "JoinStyle", "MiterLimit", "LineStyle", "Level", "ExtendHorizontal",
    "ExtendVertical", "Round", "Type", "Red", "Green", "Blue", "Alpha",
    "ImageSource", "ColorImage", "ColorFile", "ColorBrush", "ShadingGradient",
    "ImageShadingSampling", "ImageShadingEdges", "ShadingMapping",
    "ShadingMappingAngle", "ShadingMappingSize", "ShadingMappingAspect",
    "ShadingMappingLevel", "SoftnessX", "SoftnessY", "SoftnessOnFillColorToo",
    "SoftnessGlow", "SoftnessBlend", "PriorityBack", "Offset", "OffsetZ",
    "AngleX", "AngleY", "AngleZ", "Pivot", "PivotZ", "ShearX", "ShearY",
    "SizeX", "SizeY"
}

for i = 1, 8 do
    local element_params = {}
    for _, base_param in ipairs(shading_element_params) do
        local param_name = base_param .. i
        table.insert(element_params, param_name)
        table.insert(PARAM_GROUPS.Shading.params, param_name)
    end
    PARAM_GROUPS.Shading.subgroups["Shading " .. i] = element_params
end

-- Note: Common shading parameters are not included in the UI, only Shading 1-8

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local function build_tracks()
    local t = {}
    for i = 1, ctx.timeline:GetTrackCount("video") do table.insert(t, "Track " .. i) end
    return t
end

win = disp:AddWindow({
    ID = "UnifiedWin",
    WindowTitle = "TextPlus Manager",
    Geometry = {300, 300, 530, 560},
    Spacing = 8,

    ui:VGroup{
        ui:Label{ Text = "TextPlus Manager", StyleSheet = SECTION },
        ui:VGap(4),

        ui:Label{ Text = "Title Type", StyleSheet = SECTION },
        ui:ComboBox{ ID = "TitleType", Weight = 1, StyleSheet = COMBO },

        ui:Label{ Text = "Select target clips", StyleSheet = SECTION },
        ui:HGroup{
            ui:Label{ Text = "Track", Weight = 0.3, MinimumSize = {50, 0} },
            ui:ComboBox{ ID = "TrackCombo", Weight = 0.5, StyleSheet = COMBO }
        },
        ui:HGroup{
            ui:Label{ Text = "Clip Color", Weight = 0.3, MinimumSize = {50, 0} },
            ui:ComboBox{ ID = "ColorCombo", Weight = 0.5, StyleSheet = COMBO }
        },
        ui:Label{ ID = "TargetCount", Text = "Target clips: —", StyleSheet = STATUS },

        ui:VGap(8),

        ui:Label{ Text = "Style Copy", StyleSheet = SECTION },
        ui:ComboBox{ ID = "StyleCopy", Weight = 1, StyleSheet = COMBO },
        ui:VGroup{
            ID = "ParamsGroup",
            Hidden = true,
            StyleSheet = string.format([[
                QWidget { background-color: %s; border-radius: 4px; padding: 5px; }
            ]], SECTION_BG),
            ui:Label{ Text = "Choose parameter groups to copy:", StyleSheet = STATUS },
            ui:HGroup{
                ui:CheckBox{ ID = "G Text", Text = "Text", Checked = true },
                ui:CheckBox{ ID = "G Layout", Text = "Layout" },
                ui:CheckBox{ ID = "G Transform", Text = "Transform" },
                ui:CheckBox{ ID = "G Shading", Text = "Shading" }
            },
            ui:VGroup{
                ID = "TextSubgroups",
                Hidden = true,
                StyleSheet = string.format([[
                    QWidget { background-color: #1F1F1F; border-radius: 3px; padding: 3px; margin: 2px; }
                ]], SECTION_BG),
                ui:HGroup{
                    ui:Label{ Text = "Text subgroups:", StyleSheet = STATUS, Weight = 1 },
                    ui:Button{ ID = "SelectAllText", Text = "Select All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON },
                    ui:Button{ ID = "ClearAllText", Text = "Clear All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON }
                },
                ui:HGroup{
                    ui:CheckBox{ ID = "SG Text Font", Text = "Font" },
                    ui:CheckBox{ ID = "SG Text Style", Text = "Style" },
                    ui:CheckBox{ ID = "SG Text Color", Text = "Color" },
                    ui:CheckBox{ ID = "SG Text Size", Text = "Size" }
                },
                ui:HGroup{
                    ui:CheckBox{ ID = "SG Text Spacing", Text = "Spacing" },
                    ui:CheckBox{ ID = "SG Text Justification", Text = "Justification" },
                    ui:CheckBox{ ID = "SG Text Other", Text = "Other (Scroll, Direction, Tabs, Advanced)" }
                }
            },
            ui:VGroup{
                ID = "LayoutSubgroups",
                Hidden = true,
                StyleSheet = string.format([[
                    QWidget { background-color: #1F1F1F; border-radius: 3px; padding: 3px; margin: 2px; }
                ]], SECTION_BG),
                ui:HGroup{
                    ui:Label{ Text = "Layout subgroups:", StyleSheet = STATUS, Weight = 1 },
                    ui:Button{ ID = "SelectAllLayout", Text = "Select All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON },
                    ui:Button{ ID = "ClearAllLayout", Text = "Clear All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON }
                },
                ui:HGroup{
                    ui:CheckBox{ ID = "SG Layout Basic", Text = "Basic" },
                    ui:CheckBox{ ID = "SG Layout Center", Text = "Center" },
                    ui:CheckBox{ ID = "SG Layout Size", Text = "Size" }
                }
            },
            -- Transform group: no subgroups shown, but all parameters will be copied when group is selected
            ui:VGroup{
                ID = "ShadingSubgroups",
                Hidden = true,
                StyleSheet = string.format([[
                    QWidget { background-color: #1F1F1F; border-radius: 3px; padding: 3px; margin: 2px; }
                ]], SECTION_BG),
                ui:HGroup{
                    ui:Label{ Text = "Shading subgroups:", StyleSheet = STATUS, Weight = 1 },
                    ui:Button{ ID = "SelectAllShading", Text = "Select All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON },
                    ui:Button{ ID = "ClearAllShading", Text = "Clear All", MinimumSize = {70, 20}, StyleSheet = SECONDARY_BUTTON }
                },
                ui:HGroup{
                    ui:CheckBox{ ID = "SG Shading 1", Text = "Shading 1" },
                    ui:CheckBox{ ID = "SG Shading 2", Text = "Shading 2" },
                    ui:CheckBox{ ID = "SG Shading 3", Text = "Shading 3" },
                    ui:CheckBox{ ID = "SG Shading 4", Text = "Shading 4" }
                },
                ui:HGroup{
                    ui:CheckBox{ ID = "SG Shading 5", Text = "Shading 5" },
                    ui:CheckBox{ ID = "SG Shading 6", Text = "Shading 6" },
                    ui:CheckBox{ ID = "SG Shading 7", Text = "Shading 7" },
                    ui:CheckBox{ ID = "SG Shading 8", Text = "Shading 8" }
                }
            }
        },

        ui:VGap(8),

        ui:Label{ Text = "Text transform", StyleSheet = SECTION },
        ui:ComboBox{ ID = "TextTransform", Weight = 1, StyleSheet = COMBO },
        ui:CheckBox{ ID = "RemovePunctuationToggle", Text = "Remove punctuation (select below)" },
        ui:VGroup{
            ID = "PunctuationGroup",
            Hidden = true,
            StyleSheet = string.format([[
                QWidget { background-color: %s; border-radius: 4px; padding: 5px; }
            ]], SECTION_BG),
            ui:HGroup{
                ui:CheckBox{ ID = "PunctPeriods", Text = "Periods ." },
                ui:CheckBox{ ID = "PunctCommas", Text = "Commas ," },
                ui:CheckBox{ ID = "PunctSemicolons", Text = "Semicolons ;" }
            },
            ui:HGroup{
                ui:CheckBox{ ID = "PunctColons", Text = "Colons :" },
                ui:CheckBox{ ID = "PunctExclamation", Text = "Exclamation !" },
                ui:CheckBox{ ID = "PunctQuestion", Text = "Question ?" }
            },
            ui:HGroup{
                ui:CheckBox{ ID = "PunctQuotes", Text = "Quotes \" '" }
            },
            ui:HGroup{
                ui:Button{ ID = "SelectAllPunct", Text = "Select All", MinimumSize = {80, 25}, StyleSheet = SECONDARY_BUTTON },
                ui:Button{ ID = "ClearAllPunct", Text = "Clear All", MinimumSize = {80, 25}, StyleSheet = SECONDARY_BUTTON }
            }
        },

        ui:VGap(10),

        ui:HGroup{
            ui:Button{ ID = "Refresh", Text = "Refresh", MinimumSize = {90, 30}, StyleSheet = SECONDARY_BUTTON },
            ui:Button{ ID = "ApplyTextOnly", Text = "Apply Text Format Only", Weight = 0.6, StyleSheet = string.format([[
                QPushButton { border: 2px solid %s; border-radius: 8px; background-color: #5A7A9A; color: #FFF;
                    min-height: 35px; font-size: 13px; font-weight: bold; padding: 5px 15px; }
                QPushButton:hover { background-color: #6B8BAD; }
                QPushButton:disabled { background-color: #666; color: #999; }
            ]], BORDER_COLOR) },
            ui:Button{ ID = "ApplyStyle", Text = "Apply Style", Weight = 0.4, StyleSheet = PRIMARY_BUTTON }
        },
        ui:Label{ ID = "Status", Text = "", Alignment = { AlignCenter = true }, StyleSheet = STATUS }
    }
})

local itm = win:GetItems()

itm.TitleType:AddItem("Text+")
itm.TitleType:AddItem("Fusion Macros")

itm.TrackCombo:AddItem("All")
for _, o in ipairs(build_tracks()) do itm.TrackCombo:AddItem(o) end

itm.ColorCombo:AddItem("All")
for _, c in ipairs(get_used_colors()) do itm.ColorCombo:AddItem(c) end

itm.StyleCopy:AddItem("Full Style")
itm.StyleCopy:AddItem("Selected Parameters")

itm.TextTransform:AddItem("No change")
itm.TextTransform:AddItem("To Lowercase")
itm.TextTransform:AddItem("To Uppercase")
itm.TextTransform:AddItem("Capitalize First Letter")
itm.TextTransform:AddItem("Capitalize All Words")

local has_refreshed = false

local function track_filter_value()
    local t = itm.TrackCombo.CurrentText
    if not t or t == "All" then return nil end
    return tonumber(t:match("%d+"))
end

local function color_filter_value()
    local c = itm.ColorCombo.CurrentText
    if not c or c == "All" then return nil end
    return c
end

local function is_fusion_mode()
    return itm.TitleType.CurrentText == "Fusion Macros"
end

local function build_punct_settings()
    return {
        enabled = itm.RemovePunctuationToggle.Checked,
        periods = itm.PunctPeriods.Checked,
        commas = itm.PunctCommas.Checked,
        semicolons = itm.PunctSemicolons.Checked,
        colons = itm.PunctColons.Checked,
        exclamation = itm.PunctExclamation.Checked,
        question = itm.PunctQuestion.Checked,
        quotes = itm.PunctQuotes.Checked
    }
end

local function resize_window(delta)
    local g = win.Geometry
    local w, h = g[3], g[4]
    win.Geometry = { g[1], g[2], w, math.max(200, h + delta) }
    win:RecalcLayout()
    win:Update()
end

-- Variable to store previous height delta for subgroups visibility
local subgroups_visibility_last_delta = 0

local function update_subgroups_visibility()
    local text_visible = itm["G Text"].Checked
    local layout_visible = itm["G Layout"].Checked
    local transform_visible = itm["G Transform"].Checked
    local shading_visible = itm["G Shading"].Checked
    
    if itm.TextSubgroups then
        itm.TextSubgroups.Hidden = not text_visible
    end
    
    if itm.LayoutSubgroups then
        itm.LayoutSubgroups.Hidden = not layout_visible
    end
    
    -- Transform has no subgroups in UI
    
    if itm.ShadingSubgroups then
        itm.ShadingSubgroups.Hidden = not shading_visible
    end
    
    -- Force UI update to reflect visibility changes
    win:RecalcLayout()
    win:Update()
    
    -- Calculate height delta (adjusted for simplified subgroup counts)
    local delta = 0
    if text_visible then delta = delta + 80 end   -- 7 subgroups (Font, Style, Color, Size, Spacing, Justification, Other) in 2 rows
    if layout_visible then delta = delta + 50 end -- 3 subgroups (Basic, Center, Size)
    -- Transform: no subgroups, no height change
    if shading_visible then delta = delta + 60 end -- 8 checkboxes in 2 rows
    
    local height_delta = delta - subgroups_visibility_last_delta
    subgroups_visibility_last_delta = delta
    
    if height_delta ~= 0 then
        resize_window(height_delta)
    end
end

local function update_style_copy_state()
    local fusion = is_fusion_mode()
    itm.StyleCopy.Enabled = not fusion
    local show_params = not fusion and (itm.StyleCopy.CurrentText == "Selected Parameters")
    local was_visible = not itm.ParamsGroup.Hidden
    itm.ParamsGroup.Hidden = not show_params
    
    if show_params and not was_visible then
        resize_window(200)
        -- Call update_subgroups_visibility after ParamsGroup is shown
        update_subgroups_visibility()
        win:RecalcLayout()
        win:Update()
    elseif not show_params and was_visible then
        resize_window(-200)
    end
    if fusion then
        itm.Status.Text = "Fusion Macros: copy all published inputs; Style Copy disabled."
    end
end

local function update_target_count()
    if not has_refreshed then
        itm.TargetCount.Text = "Target clips: —"
        return 0
    end
    local src = ctx.timeline:GetCurrentVideoItem()
    if not src then
        itm.TargetCount.Text = "Target clips: —"
        return 0
    end
    local trF = track_filter_value()
    local clF = color_filter_value()
    local n = 0
    if is_fusion_mode() then
        local name = src:GetName()
        local tc = ctx.timeline:GetTrackCount("video")
        for tr = 1, tc do
            local items = ctx.timeline:GetItemListInTrack("video", tr)
            if items then
                for _, it in ipairs(items) do
                    if it == src then goto next end
                    local en = true
                    local ok, v = pcall(function() return it:GetClipEnabled() end)
                    if ok then en = v end
                    if not en then goto next end
                    if it:GetName() ~= name then goto next end
                    if trF and tr ~= trF then goto next end
                    if clF and it:GetClipColor() ~= clF then goto next end
                    n = n + 1
                    ::next::
                end
            end
        end
    else
        local all = find_textplus_clips()
        local filtered = filter_by_track_color(all, trF, clF, true)
        n = #filtered
    end
    itm.TargetCount.Text = "Target clips: " .. tostring(n)
    return n
end

local function get_targets_textplus()
    local trF, clF = track_filter_value(), color_filter_value()
    return filter_by_track_color(find_textplus_clips(), trF, clF, true)
end

local function get_targets_fusion()
    local src = ctx.timeline:GetCurrentVideoItem()
    if not src then return {} end
    local name = src:GetName()
    local all = find_fusion_macro_clips()
    all = filter_fusion_same_name(all, name)
    return filter_by_track_color(all, track_filter_value(), color_filter_value(), true)
end

-- DEBUG_MODE and debug_print are now defined at the top of the file

-- Build a cache of selected parameters from the source tool.
-- This avoids calling GetInputList/GetKeyFrames repeatedly per target clip.
local function build_source_param_cache(source_tool, params)
    local cache = {}

    -- Map input INPS_ID -> input object once
    local inputs_by_id = {}
    local ok_list, source_inputs = pcall(function() return source_tool:GetInputList() end)
    if ok_list and source_inputs then
        for _, inp in pairs(source_inputs) do
            local a = inp:GetAttrs()
            local id = a and a.INPS_ID
            if id then inputs_by_id[id] = inp end
        end
    end

    for _, param_name in ipairs(params) do
        local spec = { animated = false, value = nil, keyframes = nil, kf_values = nil }
        cache[param_name] = spec

        local source_input = inputs_by_id[param_name]
        if source_input then
            local get_kf_ok, kf_result = pcall(function() return source_input:GetKeyFrames() end)
            if get_kf_ok and kf_result and #kf_result > 0 then
                local keyframes = {}
                for _, time in ipairs(kf_result) do
                    if type(time) == "number" and math.abs(time) < 999999999 then
                        keyframes[#keyframes + 1] = time
                    end
                end
                if #keyframes > 0 then
                    spec.animated = true
                    spec.keyframes = keyframes
                    spec.kf_values = {}

                    local source_param = source_tool[param_name]
                    if source_param then
                        for _, time in ipairs(keyframes) do
                            local val_ok, val = pcall(function() return source_param[time] end)
                            if val_ok and val ~= nil then
                                spec.kf_values[time] = val
                            end
                        end
                    else
                        -- If we can't access as a spline, fall back to static value below
                        spec.animated = false
                        spec.keyframes = nil
                        spec.kf_values = nil
                    end
                end
            end
        end

        if not spec.animated then
            local ok_v, v = pcall(function() return source_tool:GetInput(param_name) end)
            if ok_v then 
                spec.value = v
            end
        end
    end

    return cache
end

local function apply_cached_param_to_target(target_tool, target_comp, param_name, spec)
    if not spec then 
        return false 
    end

    if spec.animated then
        if not target_comp then
            debug_print(string.format("✗ No target comp for animated parameter '%s'", param_name))
            return false
        end

        -- Reset animation by assigning a fresh spline, then write keyframes.
        local created = pcall(function()
            target_tool[param_name] = target_comp:BezierSpline({})
        end)
        if not created then
            debug_print(string.format("✗ Failed to create spline for parameter '%s'", param_name))
            return false
        end

        local spline = target_tool[param_name]
        if not spline or type(spline) ~= "table" then
            debug_print(string.format("✗ Target spline not available for parameter '%s'", param_name))
            return false
        end

        local copied = 0
        for _, time in ipairs(spec.keyframes or {}) do
            local val = spec.kf_values and spec.kf_values[time]
            if val ~= nil then
                -- Use pcall for reliability, especially when values might have changed
                local set_ok = pcall(function() spline[time] = val end)
                if set_ok then
                    copied = copied + 1
                end
            end
        end
        return copied > 0
    end

    if spec.value == nil then
        return false
    end

    local setOk = pcall(function() target_tool:SetInput(param_name, spec.value) end)
    return setOk
end

local function selected_params_list()
    local L = {}
    local selected_params = {}
    
    -- Process each main group
    for group_name, group_data in pairs(PARAM_GROUPS) do
        local group_id = "G " .. group_name
        local group_checked = itm[group_id] and itm[group_id].Checked or false
        
        if group_checked then
            -- Special handling for Transform: if group is checked, copy all parameters
            if group_name == "Transform" then
                for _, param in ipairs(group_data.params) do
                    selected_params[param] = true
                end
            else
                -- For other groups, check subgroups
                for subgroup_name, subgroup_params in pairs(group_data.subgroups) do
                    -- Special handling for Shading: subgroup names are "Shading 1", "Shading 2", etc.
                    -- UI IDs are "SG Shading 1", "SG Shading 2", etc. (not "SG Shading Shading 1")
                    local subgroup_id
                    if group_name == "Shading" and subgroup_name:match("^Shading %d+$") then
                        subgroup_id = "SG " .. subgroup_name  -- "SG Shading 1"
                    else
                        subgroup_id = "SG " .. group_name .. " " .. subgroup_name  -- "SG Text Basic"
                    end
                    
                    local subgroup_checked = itm[subgroup_id] and itm[subgroup_id].Checked or false
                    
                    if subgroup_checked then
                        -- Normal subgroup processing (no special handling needed anymore)
                        for _, param in ipairs(subgroup_params) do
                            selected_params[param] = true
                        end
                    end
                end
            end
        end
    end
    
    -- Convert to list
    for param, _ in pairs(selected_params) do
        table.insert(L, param)
    end
    
    return L
end

function win.On.UnifiedWin.Close(ev)
    disp:ExitLoop()
end

function win.On.TitleType.CurrentIndexChanged(ev)
    update_style_copy_state()
    update_target_count()
end

function win.On.StyleCopy.CurrentIndexChanged(ev)
    update_style_copy_state()
    update_target_count()
end

function win.On.TrackCombo.CurrentIndexChanged(ev) update_target_count() end
function win.On.ColorCombo.CurrentIndexChanged(ev) update_target_count() end

-- Helper function to select/clear all subgroups in a group
local function set_all_subgroups(group_name, checked)
    local group_data = PARAM_GROUPS[group_name]
    if not group_data then 
        return 
    end
    
    for subgroup_name, _ in pairs(group_data.subgroups) do
        -- Special handling for Shading: subgroup names are "Shading 1", "Shading 2", etc.
        -- UI IDs are "SG Shading 1", "SG Shading 2", etc. (not "SG Shading Shading 1")
        local subgroup_id
        if group_name == "Shading" and subgroup_name:match("^Shading %d+$") then
            subgroup_id = "SG " .. subgroup_name  -- "SG Shading 1"
        else
            subgroup_id = "SG " .. group_name .. " " .. subgroup_name  -- "SG Text Basic"
        end
        
        if itm[subgroup_id] then
            itm[subgroup_id].Checked = checked
        end
    end
end

-- Group checkbox handlers
win.On["G Text"] = { Clicked = function(ev) update_subgroups_visibility() end }
win.On["G Layout"] = { Clicked = function(ev) update_subgroups_visibility() end }
win.On["G Transform"] = { Clicked = function(ev) 
    -- Transform has no subgroups, just update visibility
    update_subgroups_visibility() 
end }
win.On["G Shading"] = { Clicked = function(ev) update_subgroups_visibility() end }

-- Select All / Clear All button handlers
function win.On.SelectAllText.Clicked(ev) set_all_subgroups("Text", true) end
function win.On.ClearAllText.Clicked(ev) set_all_subgroups("Text", false) end
function win.On.SelectAllLayout.Clicked(ev) set_all_subgroups("Layout", true) end
function win.On.ClearAllLayout.Clicked(ev) set_all_subgroups("Layout", false) end
-- Transform: no subgroups, so buttons are not needed (but keep for consistency)
function win.On.SelectAllTransform.Clicked(ev) 
    -- Transform has no subgroups
end
function win.On.ClearAllTransform.Clicked(ev) 
    -- Transform has no subgroups
end
function win.On.SelectAllShading.Clicked(ev) set_all_subgroups("Shading", true) end
function win.On.ClearAllShading.Clicked(ev) set_all_subgroups("Shading", false) end

function win.On.RemovePunctuationToggle.Clicked(ev)
    itm.PunctuationGroup.Hidden = not itm.RemovePunctuationToggle.Checked
    resize_window(itm.RemovePunctuationToggle.Checked and 120 or -120)
end

function win.On.SelectAllPunct.Clicked(ev)
    itm.PunctPeriods.Checked = true
    itm.PunctCommas.Checked = true
    itm.PunctSemicolons.Checked = true
    itm.PunctColons.Checked = true
    itm.PunctExclamation.Checked = true
    itm.PunctQuestion.Checked = true
    itm.PunctQuotes.Checked = true
end

function win.On.ClearAllPunct.Clicked(ev)
    itm.PunctPeriods.Checked = false
    itm.PunctCommas.Checked = false
    itm.PunctSemicolons.Checked = false
    itm.PunctColons.Checked = false
    itm.PunctExclamation.Checked = false
    itm.PunctQuestion.Checked = false
    itm.PunctQuotes.Checked = false
end

function win.On.Refresh.Clicked(ev)
    ctx.timeline = project:GetCurrentTimeline()
    if not ctx.timeline then
        itm.Status.Text = "No timeline open. Open a timeline and click Refresh."
        return
    end
    has_refreshed = true
    itm.ColorCombo:Clear()
    itm.ColorCombo:AddItem("All")
    for _, c in ipairs(get_used_colors()) do itm.ColorCombo:AddItem(c) end
    itm.TrackCombo:Clear()
    itm.TrackCombo:AddItem("All")
    for _, o in ipairs(build_tracks()) do itm.TrackCombo:AddItem(o) end
    update_target_count()
    update_style_copy_state()
    itm.Status.Text = "Refreshed. Active timeline updated. Track/Color filters updated."
end

function win.On.ApplyTextOnly.Clicked(ev)
    if not has_refreshed then
        itm.Status.Text = "Click Refresh first."
        return
    end
    local src = ctx.timeline:GetCurrentVideoItem()
    local transform = itm.TextTransform.CurrentText
    local punct = build_punct_settings()
    local need = (transform ~= "No change") or punct.enabled
    if not need then
        itm.Status.Text = "No text transform selected."
        return
    end

    local targets
    if is_fusion_mode() then
        targets = get_targets_fusion()
    else
        targets = get_targets_textplus()
    end

    if #targets == 0 then
        itm.Status.Text = "No target clips found."
        return
    end

    itm.ApplyTextOnly.Enabled = false
    itm.ApplyStyle.Enabled = false
    local ok_count = 0

    if is_fusion_mode() then
        for _, e in ipairs(targets) do
            local comp = e.comp or get_fusion_comp_from_clip(e.clip)
            if comp then
                apply_transform_macro(comp, transform, punct)
                ok_count = ok_count + 1
            end
        end
    else
        for _, e in ipairs(targets) do
            local ok, cur = pcall(function() return e.tool:GetInput("StyledText") end)
            if ok and cur and type(cur) == "string" and cur ~= "" then
                local x = ApplyTextTransform(cur, transform, punct)
                pcall(function() e.tool:SetInput("StyledText", x) end)
                ok_count = ok_count + 1
            end
        end
    end

    if src and need then
        if is_fusion_mode() then
            local comp = get_fusion_comp_from_clip(src)
            if comp then apply_transform_macro(comp, transform, punct) end
        else
            local tool = get_textplus_tool(src)
            if tool then
                local ok, cur = pcall(function() return tool:GetInput("StyledText") end)
                if ok and cur and type(cur) == "string" and cur ~= "" then
                    local x = ApplyTextTransform(cur, transform, punct)
                    pcall(function() tool:SetInput("StyledText", x) end)
                end
            end
        end
    end

    itm.Status.Text = string.format("Text format applied to %d clip(s).", ok_count)
    itm.ApplyTextOnly.Enabled = true
    itm.ApplyStyle.Enabled = true
end

function win.On.ApplyStyle.Clicked(ev)
    if not has_refreshed then
        itm.Status.Text = "Click Refresh first."
        return
    end
    local src = ctx.timeline:GetCurrentVideoItem()
    if not src then
        itm.Status.Text = "No source clip selected."
        return
    end

    local transform = itm.TextTransform.CurrentText
    local punct = build_punct_settings()
    local needTransform = (transform ~= "No change") or punct.enabled

    local targets
    if is_fusion_mode() then
        targets = get_targets_fusion()
    else
        targets = get_targets_textplus()
    end

    if #targets == 0 then
        itm.Status.Text = "No target clips found."
        return
    end

    itm.ApplyStyle.Enabled = false
    itm.ApplyTextOnly.Enabled = false
    local ok_count = 0

    if is_fusion_mode() then
        local comp = get_fusion_comp_from_clip(src)
        if not comp then
            itm.Status.Text = "Source has no Fusion comp."
            itm.ApplyStyle.Enabled = true
            itm.ApplyTextOnly.Enabled = true
            return
        end
        local src_in, _ = get_published_inputs(comp)
        if #src_in == 0 then
            itm.Status.Text = "Source has no MacroOperator/GroupOperator or no published inputs."
            itm.ApplyStyle.Enabled = true
            itm.ApplyTextOnly.Enabled = true
            return
        end

        for i, e in ipairs(targets) do
            local tc = e.comp or get_fusion_comp_from_clip(e.clip)
            if tc then
                local tgt_in, _ = get_published_inputs(tc)
                if same_structure(src_in, tgt_in) then
                    local by_id = {}
                    for _, x in ipairs(tgt_in) do by_id[x.id] = x end
                    for _, s in ipairs(src_in) do
                        local t = by_id[s.id]
                        if t and t.obj then
                            pcall(function() t.obj[tc.CurrentTime] = s.value end)
                        end
                    end
                    if needTransform then
                        apply_transform_macro(tc, transform, punct)
                    end
                    ok_count = ok_count + 1
                end
            end
            if ENABLE_PROGRESS and i % 5 == 0 then
                itm.Status.Text = string.format("Processing... %d/%d", i, #targets)
            end
        end

        if needTransform and src then
            local comp = get_fusion_comp_from_clip(src)
            if comp then apply_transform_macro(comp, transform, punct) end
        end
    else
        local tool = get_textplus_tool(src)
        if not tool then
            itm.Status.Text = "Source is not a Text+ clip."
            itm.ApplyStyle.Enabled = true
            itm.ApplyTextOnly.Enabled = true
            return
        end

        local full = itm.StyleCopy.CurrentText == "Full Style"
        
        local params = full and nil or selected_params_list()
        if not full and #params == 0 then
            itm.Status.Text = "Select at least one parameter."
            itm.ApplyStyle.Enabled = true
            itm.ApplyTextOnly.Enabled = true
            return
        end

        -- Performance: cache all source values/keyframes once for selected-params mode
        -- IMPORTANT: Cache is rebuilt every time ApplyStyle is clicked to ensure fresh values
        local source_cache = nil
        if not full then
            source_cache = build_source_param_cache(tool, params)
        end

        for i, e in ipairs(targets) do
            local t = e.tool
            local target_comp = get_fusion_comp_from_clip(e.clip)
            if full then
                if apply_full_style_fast(tool, t) then 
                    ok_count = ok_count + 1
                end
            else
                local n = 0
                local failed_params = {}
                for _, p in ipairs(params) do
                    local spec = source_cache and source_cache[p]
                    local copy_ok = apply_cached_param_to_target(t, target_comp, p, spec)
                    if copy_ok then
                        n = n + 1
                    else
                        table.insert(failed_params, p)
                    end
                end
                if #failed_params > 0 then
                    debug_print(string.format("Failed to copy parameters: %s", table.concat(failed_params, ", ")))
                end
                if n > 0 then 
                    ok_count = ok_count + 1
                end
            end
            if needTransform then
                local ok, cur = pcall(function() return t:GetInput("StyledText") end)
                if ok and cur and type(cur) == "string" and cur ~= "" then
                    local x = ApplyTextTransform(cur, transform, punct)
                    pcall(function() t:SetInput("StyledText", x) end)
                end
            end
            if ENABLE_PROGRESS and i % 5 == 0 then
                itm.Status.Text = string.format("Processing... %d/%d", i, #targets)
            end
        end

        if needTransform and src then
            local ok, cur = pcall(function() return tool:GetInput("StyledText") end)
            if ok and cur and type(cur) == "string" and cur ~= "" then
                local x = ApplyTextTransform(cur, transform, punct)
                pcall(function() tool:SetInput("StyledText", x) end)
            end
        end
    end

    itm.Status.Text = string.format("Style applied to %d of %d clip(s).", ok_count, #targets)
    itm.ApplyStyle.Enabled = true
    itm.ApplyTextOnly.Enabled = true
end

itm.ParamsGroup.Hidden = true
itm.PunctuationGroup.Hidden = true
itm.StyleCopy.CurrentIndex = 0

-- Set default selections for Text group
itm["G Text"].Checked = true
itm["SG Text Font"].Checked = true
itm["SG Text Style"].Checked = true
itm["SG Text Color"].Checked = true
itm["SG Text Size"].Checked = true

-- Initialize subgroups visibility
-- All subgroups (Text, Layout, Shading) are Hidden = true by default
-- They will be shown/hidden by update_subgroups_visibility() based on group checkbox states

-- Force update visibility after setting defaults
-- This will set correct visibility based on current StyleCopy selection and group checkboxes
update_subgroups_visibility()

-- Initialize subgroup visibility
subgroups_visibility_last_delta = 0

-- Initialize ParamsGroup state - it should be hidden initially
itm.ParamsGroup.Hidden = true

-- Call update_style_copy_state to set initial state
update_style_copy_state()

itm.TargetCount.Text = "Target clips: —"
itm.Status.Text = "Click Refresh, then apply. No comp access at startup."

win:Show()
disp:RunLoop()
win:Hide()

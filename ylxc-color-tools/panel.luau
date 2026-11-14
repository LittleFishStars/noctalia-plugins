
-- [[panel]] entry:
-- shows the last/current picked color with a button to
-- pick a new one, a history of the last colors, and
-- color fields with real-time editing.
--
-- No hyprpicker, no disk, no history mutation here -- that all lives in
-- service.luau. This script only reads noctalia.state and dispatches IPC
-- events to the service for anything that touches picking or persistence.
--!nocheck
--!nolint UnknownGlobal

--==============================================
-- CONSTANTS
--==============================================
local SERVICE = "ylxc/color-tools:service"
local swatch_radius = noctalia.getConfig("swatch-radius")
local tr_color_picker = noctalia.tr("color_picker")

--==============================================
-- CONTROL VARIABLES
--==============================================
local waitingForPanelPick = false
local initialSessionColor = nil
local initialSessionOpacity = 1
local initialChanged = false

--==============================================
-- TRANSLATION HELPER
--==============================================
local function tr(key: string, subst: table?): string
  if subst then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

--==============================================
-- COLOR CONVERSION
--==============================================

local function hexToRgb(hex: string)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return r, g, b
end

local function rgbToHsl(r: number, g: number, b: number)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local h, s, l = 0, 0, (max + min) / 2

  if max ~= min then
    local d = max - min
    s = if l > 0.5 then d / (2 - max - min) else d / (max + min)
    if max == r then
      h = (g - b) / d + (if g < b then 6 else 0)
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end

  return math.floor(h * 360 + 0.5), math.floor(s * 100 + 0.5), math.floor(l * 100 + 0.5)
end

local function formatHex(hex: string, alpha: number): string
  if alpha < 1 then
    return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  return hex
end

local function formatRgb(hex: string, alpha: number): string
  local r, g, b = hexToRgb(hex)
  if alpha < 1 then
    return string.format("rgba(%d, %d, %d, %.2f)", r, g, b, alpha)
  end
  return string.format("rgb(%d, %d, %d)", r, g, b)
end

local function formatHsl(hex: string, alpha: number): string
  local r, g, b = hexToRgb(hex)
  local h, s, l = rgbToHsl(r, g, b)
  if alpha < 1 then
    return string.format("hsla(%d, %d%%, %d%%, %.2f)", h, s, l, alpha)
  end
  return string.format("hsl(%d, %d%%, %d%%)", h, s, l)
end

local function hexWithAlpha(hex: string, alpha: number): string
  if alpha >= 1 then
    return hex
  end
  return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
end

-- HSL (hue 0-360, saturation/lightness 0-1) -> "#rrggbb". Used by the palette
-- generator so the swatch grid can be built without any hardcoded color table.
local function hslToHex(h: number, s: number, l: number): string
  local function hueToRgb(p: number, q: number, t: number): number
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end

  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = if l < 0.5 then l * (1 + s) else l + s - l * s
    local p = 2 * l - q
    local hn = h / 360
    r = hueToRgb(p, q, hn + 1 / 3)
    g = hueToRgb(p, q, hn)
    b = hueToRgb(p, q, hn - 1 / 3)
  end

  return string.format(
    "#%02x%02x%02x",
    math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5)
  )
end

--==============================================
-- COLOR TEXT PARSING (field input -> hex)
--==============================================

local function parseRgbText(text: string): string?
  local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if r == nil then
    return nil
  end
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if r > 255 or g > 255 or b > 255 then
    return nil
  end
  return string.format("#%02x%02x%02x", r, g, b)
end

local function parseHslText(text: string): string?
  local h, s, l = text:match("^%s*(%d+)%s*,%s*(%d+)%%?%s*,%s*(%d+)%%?")
  if h == nil then
    return nil
  end
  h, s, l = tonumber(h), tonumber(s) / 100, tonumber(l) / 100

  local function hueToRgb(p: number, q: number, t: number): number
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end

  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = if l < 0.5 then l * (1 + s) else l + s - l * s
    local p = 2 * l - q
    local hn = h / 360
    r = hueToRgb(p, q, hn + 1 / 3)
    g = hueToRgb(p, q, hn)
    b = hueToRgb(p, q, hn - 1 / 3)
  end

  return string.format(
    "#%02x%02x%02x",
    math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5)
  )
end

local function parseHexText(text: string): string?
  local clean = text:match("^#?(%x%x%x%x%x%x)$")
  if clean == nil then
    return nil
  end
  return "#" .. clean
end

--==============================================
-- SERVICE DISPATCH
--==============================================

local function sendToService(event: string, payload: string?)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then
    cmd = cmd .. " '" .. payload .. "'"
  end
  noctalia.runAsync(cmd, function() end)
end

local function commitInitialColorIfFirstChange(newHex: string?)
    if initialChanged then return end
    if initialSessionColor == nil then return end
    if newHex == nil or newHex == initialSessionColor then return end

    initialChanged = true
    local payload = initialSessionColor .. ":" .. tostring(initialSessionOpacity)
    -- noctalia.notify("DEBUG", "Push initial color = ".. initialSessionColor .. "\nOpacity = " .. initialSessionOpacity)
    sendToService("push-to-history", payload)
end

--==============================================
-- STATE (read-only view + pure-UI selection)
-- These states are synced and persisted to disk by the service on close.
--==============================================

local function getSelectedColor(): string?
    return noctalia.state.get("selectedColor")
end

local function getSelectedOpacity(): number
    return tonumber(noctalia.state.get("selectedOpacity")) or 1
end

local function setSelected(hex: string, opacity: number)
    commitInitialColorIfFirstChange(hex)
    noctalia.state.set("selectedColor", hex)
    noctalia.state.set("selectedOpacity", opacity)
end

local render -- forward declaration: the palette callbacks call render(), which is defined in the RENDERING section below
--==============================================
-- RENDERING
--==============================================

local function renderTitlebar()
    return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = tr("color_picker"), fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
        ui.button({ glyph = "color-picker", onClick = "onPickClickedFromPanel" }),
        ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    })
end

local function renderRecentItem(color: string, index: number)
    return ui.box({
        width = 32,
        height = 32,
        fill = color,
        radius = swatch_radius / 2.5,
        border = "outline",
        onClick = function() handleHistoryClick(index) end,
    })
end

-- Recent-colors row
function renderRecent()
    local recent = noctalia.state.get("colorHistory") or {}

    if #recent == 0 then
        return ui.label({ text = tr("no_history"), fontSize = 12, color = "on_surface_variant" })
    end

    local items = {}
    for i = #recent, 1, -1 do
        table.insert(items, renderRecentItem(recent[i].hex, i))
    end

    return ui.row({ gap = 8, align = "center" }, items)
end

--==============================================
-- PALETTE (adjustment modes: HSL / RGB / HSV)
--==============================================

local paletteModes = { "hsl", "rgb", "hsv" }

-- The hue / saturation / lightness triple is the canonical draft for the HSL and
-- HSV sliders, kept as floats so a drag is never rounded through hex twice.
-- RGB sliders read their channels straight from `draftHex` instead: the HSL triple
-- is only stored as whole degrees / whole percent, so deriving RGB from it would
-- round every drag (and visibly move the two channels the user did not touch).
local draftHue, draftSat, draftLum = 0, 0.62, 0.72
local draftHex = nil
local paletteMode = nil

local function clamp01(value: number): number
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function clampByte(value: number): number
    if value < 0 then value = 0 end
    if value > 255 then value = 255 end
    return math.floor(value + 0.5)
end

local function rgbToHex(r: number, g: number, b: number): string
    return string.format("#%02X%02X%02X", clampByte(r), clampByte(g), clampByte(b))
end

local function hslToHsv(h: number, s: number, l: number): (number, number, number)
    local v = l + s * math.min(l, 1 - l)
    local sat = 0
    if v > 0 then sat = 2 * (1 - l / v) end
    return h, sat, v
end

local function hsvToHsl(h: number, s: number, v: number): (number, number, number)
    local l = v * (1 - s / 2)
    local sat = 0
    if l > 0 and l < 1 then sat = (v - l) / math.min(l, 1 - l) end
    return h, sat, l
end

-- Keeps the draft in sync with the selection when it changes from outside the
-- palette (history, picker, text fields). A color produced by the palette
-- itself is recognised through `draftHex`, so drag precision survives.
local function syncDraft(hex: string?)
    if hex == nil then return end
    if draftHex ~= nil and draftHex:lower() == hex:lower() then return end

    local r, g, b = hexToRgb(hex)
    local h, s, l = rgbToHsl(r, g, b)
    draftHue, draftSat, draftLum = h, s / 100, l / 100
    draftHex = hex
end

local function applyDraft()
    local hex = hslToHex(draftHue, draftSat, draftLum)
    draftHex = hex
    setSelected(hex, getSelectedOpacity())
    render()
end

local function applyRgb(r: number, g: number, b: number)
    local rr, gg, bb = clampByte(r), clampByte(g), clampByte(b)
    local h, s, l = rgbToHsl(rr, gg, bb)
    draftHue, draftSat, draftLum = h, s / 100, l / 100
    draftHex = rgbToHex(rr, gg, bb)
    setSelected(draftHex, getSelectedOpacity())
    render()
end

local function getPaletteMode(): string
    if paletteMode == nil then
        local configured = noctalia.getConfig("palette-mode")
        if type(configured) == "string" then
            local wanted = string.lower(configured)
            for _, candidate in ipairs(paletteModes) do
                if candidate == wanted then
                    paletteMode = candidate
                    break
                end
            end
        end
        if paletteMode == nil then paletteMode = "hsl" end
    end
    return paletteMode
end

-- Switches the adjustment mode and repaints the mode buttons and slider rows.
function setPaletteMode(mode: string)
    paletteMode = mode
    render()
end

-- The color currently in the draft, as 0..255 channels. Read back from the exact
-- hex the draft last produced, never from the rounded HSL triple.
local function draftRgb(): (number, number, number)
    local hex = draftHex
    if hex == nil then
        hex = getSelectedColor()
    end
    if hex == nil then
        return hexToRgb(hslToHex(draftHue, draftSat, draftLum))
    end
    return hexToRgb(hex)
end

-- The live component values of the active mode. Each is a plain number so one
-- slider row layout serves every mode: hue 0..360, saturation / lightness /
-- value 0..100 as percentages, and the RGB channels 0..255.
function onPaletteComp1Change(value: string)
    local v = tonumber(value)
    if v == nil then return end

    local mode = getPaletteMode()

    if mode == "rgb" then
        local _, g, b = draftRgb()
        applyRgb(v, g, b)
    elseif mode == "hsv" then
        local _, s, val = hslToHsv(draftHue, draftSat, draftLum)
        local h, sat, lum = hsvToHsl(v, s, val)
        draftHue, draftSat, draftLum = h, sat, lum
        applyDraft()
    else
        draftHue = v
        applyDraft()
    end
end

function onPaletteComp2Change(value: string)
    local v = tonumber(value)
    if v == nil then return end

    local mode = getPaletteMode()

    if mode == "rgb" then
        local r, _, b = draftRgb()
        applyRgb(r, v, b)
    else
        local frac = clamp01(v / 100)
        if mode == "hsv" then
            local h, _, val = hslToHsv(draftHue, draftSat, draftLum)
            local nh, ns, nl = hsvToHsl(h, frac, val)
            draftHue, draftSat, draftLum = nh, ns, nl
        else
            draftSat = frac
        end
        applyDraft()
    end
end

function onPaletteComp3Change(value: string)
    local v = tonumber(value)
    if v == nil then return end

    local mode = getPaletteMode()

    if mode == "rgb" then
        local r, g = draftRgb()
        applyRgb(r, g, v)
    else
        local frac = clamp01(v / 100)
        if mode == "hsv" then
            local h, s = hslToHsv(draftHue, draftSat, draftLum)
            local nh, ns, nl = hsvToHsl(h, s, frac)
            draftHue, draftSat, draftLum = nh, ns, nl
        else
            draftLum = frac
        end
        applyDraft()
    end
end

-- One continuous slider row: component name on the left, live value on the right.
local function renderPaletteSlider(name: string, value: number, min: number, max: number, step: number, display: string, handler: string)
    return ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = name, fontSize = 12, color = "on_surface_variant", width = 72 }),
        ui.slider({ min = min, max = max, step = step, value = value, flexGrow = 1, onChange = handler }),
        ui.label({ text = display, fontSize = 12, color = "on_surface_variant", width = 52, textAlign = "end" }),
    })
end

-- Mode selector: one button per adjustment model, the active one highlighted.
local function renderModeButtons()
    local buttons = {}

    for _, mode in ipairs(paletteModes) do
        local active = getPaletteMode() == mode
        local variant = "ghost"
        if active then variant = "primary" end

        table.insert(buttons, ui.button({
            key = "palette-mode-" .. mode,
            text = string.upper(mode),
            variant = variant,
            selected = active,
            controlSize = "sm",
            flexGrow = 1,
            tooltip = string.upper(mode),
            onClick = function() setPaletteMode(mode) end,
        }))
    end

    return ui.row({ gap = 6, align = "center" }, buttons)
end

-- Palette block: adjustment-mode buttons above three continuous slider rows.
-- Returns nil when the palette is turned off in the plugin settings.
function renderPalette(current: string?)
    if not noctalia.getConfig("palette-visible") then
        return nil
    end

    syncDraft(current)

    local mode = getPaletteMode()
    local rows = {}

    if mode == "rgb" then
        local r, g, b = draftRgb()
        table.insert(rows, renderPaletteSlider(tr("palette_red"), r, 0, 255, 1, string.format("%d", r), "onPaletteComp1Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_green"), g, 0, 255, 1, string.format("%d", g), "onPaletteComp2Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_blue"), b, 0, 255, 1, string.format("%d", b), "onPaletteComp3Change"))
    elseif mode == "hsv" then
        local h, s, v = hslToHsv(draftHue, draftSat, draftLum)
        table.insert(rows, renderPaletteSlider(tr("palette_hue"), h, 0, 360, 1, string.format("%d°", math.floor(h + 0.5)), "onPaletteComp1Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_saturation"), s * 100, 0, 100, 1, string.format("%d%%", math.floor(s * 100 + 0.5)), "onPaletteComp2Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_value"), v * 100, 0, 100, 1, string.format("%d%%", math.floor(v * 100 + 0.5)), "onPaletteComp3Change"))
    else
        table.insert(rows, renderPaletteSlider(tr("palette_hue"), draftHue, 0, 360, 1, string.format("%d°", math.floor(draftHue + 0.5)), "onPaletteComp1Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_saturation"), draftSat * 100, 0, 100, 1, string.format("%d%%", math.floor(draftSat * 100 + 0.5)), "onPaletteComp2Change"))
        table.insert(rows, renderPaletteSlider(tr("palette_lightness"), draftLum * 100, 0, 100, 1, string.format("%d%%", math.floor(draftLum * 100 + 0.5)), "onPaletteComp3Change"))
    end

    local children = {
        ui.label({ text = tr("palette"), fontSize = 14, color = "on_surface_variant" }),
    }
    for _, row in ipairs(rows) do
        table.insert(children, row)
    end
    table.insert(children, renderModeButtons())

    return ui.column({ gap = 6 }, children)
end

local function renderColorspaceColumn(name: string, value: string, onSubmit: string, onCopy: string, keySuffix: string)
  if name ~= "HEX" then
    value = value:match("%((.-)%)")
  end

  return ui.column({ gap = 4, flexGrow = 1 }, {
    ui.label({ text = name, fontSize = 14, color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = name .. "-input-" .. keySuffix,
        value = value,
        flexGrow = 1,
        onSubmit = onSubmit,
      }),
      ui.button({ glyph = "copy", variant = "ghost", onClick = onCopy }),
    }),
  })
end

function render()
  local current = getSelectedColor()
  local opacity = getSelectedOpacity()

  local children = { renderTitlebar() }

  if current == nil then
    table.insert(children, ui.label({ text = tr("no_color_picked"), padding = { top = 8 } }))
    table.insert(children, renderRecent())
  else
    table.insert(children, ui.row({ gap = 12, align = "stretch" }, {
      ui.column({ gap = 8, flexGrow = 2 }, {
        ui.label({ text = tr("recent_colors"), fontSize = 14, color = "on_surface_variant" }),
        renderRecent(),
      }),
      ui.column({ gap = 8, flexGrow = 2 }, {
        ui.label({ text = tr("opacity"), fontSize = 14, color = "on_surface_variant" }),
        ui.slider({ min = 0, max = 1, step = 0.01, value = opacity, onChange = "onOpacityChange", onDragEnd = "onOpacityDragEnd" }),
      }),
      -- Render current swatch
      ui.box({
        width = 128,
        height = 64,
        fill =  hexWithAlpha(current, opacity),
        radius = swatch_radius,
        border = "outline",
        borderWidth = 2,
        flexGrow = 1,
        onClick = "onNativePickerClicked"
      }),
    }))

    table.insert(children, ui.row({ gap = 12 }, {
      renderColorspaceColumn("HEX", formatHex(current, opacity), "onSubmitHex", "onCopyHex", current .. "-" .. opacity),
      renderColorspaceColumn("RGB", formatRgb(current, opacity), "onSubmitRgb", "onCopyRgb", current .. "-" .. opacity),
      renderColorspaceColumn("HSL", formatHsl(current, opacity), "onSubmitHsl", "onCopyHsl", current .. "-" .. opacity),
    }))
  end

  local palette = renderPalette(current)
  if palette ~= nil then
    table.insert(children, palette)
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, children))
end

--==============================================
-- CALLBACKS: history interaction (pure UI, no service call)
--==============================================

function handleHistoryClick(index: number)
  local history = noctalia.state.get("colorHistory") or {}
  local entry = history[index]
  if entry then
    setSelected(entry.hex, entry.opacity or 1)
    render()
  end
end

--==============================================
-- CALLBACKS: palette (pure UI, no service call)
--==============================================

-- ui.slider takes its handler by name, so the palette handlers must stay named
-- globals; they live in the PALETTE section above. onPaletteComp1Change,
-- onPaletteComp2Change and onPaletteComp3Change interpret their value according
-- to the active adjustment mode, and setPaletteMode switches that mode.

--==============================================
-- CALLBACKS: colorspace fields (pure UI, no service call)
--==============================================

local function processSubmit(parseText: (string) -> string?, text: string)
  local color_value = parseText(text)
  if color_value == nil then return end

  setSelected(color_value, getSelectedOpacity())
  render()
end

function onSubmitHex(text: string) processSubmit(parseHexText, text) end
function onSubmitRgb(text: string) processSubmit(parseRgbText, text) end
function onSubmitHsl(text: string) processSubmit(parseHslText, text) end

local function processCopy(format: (string, number) -> string)
  local current = getSelectedColor()
  if current == nil then return end

  local text = format(current, getSelectedOpacity())
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  noctalia.notify(tr_color_picker, tr("color_copied", { color = text }))
end

function onCopyHex() processCopy(formatHex) end
function onCopyRgb() processCopy(formatRgb) end
function onCopyHsl() processCopy(formatHsl) end

function onOpacityChange(value)
  local parsed = tonumber(value)
  if parsed == nil then return end

  noctalia.state.set("selectedOpacity", parsed)
  render()
end

function onOpacityDragEnd(value)
    local parsed = tonumber(value)
    if parsed == nil then return end

    local currentHex = getSelectedColor()
    if currentHex then
        setSelected(currentHex, parsed)
    end
end

--==============================================
-- CALLBACKS: picking (delegates to the service)
--==============================================

-- Panel's own pick button: just closes the panel (so it doesn't cover the
-- area being sampled). The actual pick is triggered from onClose(), which
-- only fires once the close animation has actually finished -- firing the
-- pick here instead would race the animation and hyprpicker would freeze
-- mid-transition.
function onPickClickedFromPanel()
	waitingForPanelPick = true
	panel.close()
end

function onNativePickerClicked()
  sendToService("picker-dialog")
end

function onCloseClicked()
  panel.close()
end

-- Panel closed. Two cases:
-- - Technical close to hand off to hyprpicker (waitingForPanelPick): ask
--   the service to pick now that the close animation is done, then wait
--   for the selectedColor watch to reopen the panel.
--
-- - Real close (close button, Esc, click outside): save whatever is
--   currently selected to the service's SELECTED_FILE.
function onClose()
	if waitingForPanelPick then
		sendToService("pick-panel")
		return
	end
	sendToService("save-selected")
end

function onOpen(context)
    initialChanged = false
    initialSessionColor = getSelectedColor()
    initialSessionOpacity = getSelectedOpacity()

    noctalia.state.watch("selectedColor", function(newHex: string?)
        if waitingForPanelPick then
        waitingForPanelPick = false
        noctalia.togglePanel("ylxc/color-tools:panel")
        return
        end

        -- Covers changes the service made directly (panel pick button, native
        -- picker dialog), which bypass this panel's setSelected().
        commitInitialColorIfFirstChange(newHex)

        render()
    end)

    noctalia.state.watch("colorHistory", function()
        render()
    end)

    render()
end

--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- desktop.luau —— 桌面小组件：一张自适应的天气卡片
--
-- 数据同样来自 service 发布的快照；尺寸由用户在桌面上拖出来，所以这里只用
-- flexGrow / maxLines 做自适应，不写死宽高。
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./lib/qweather.luau")

local watched = false
local snap, source, age = nil, nil, nil
local status = nil

local function ensureWatch()
    if watched then
        return
    end
    watched = true
    q.watchState(function(next, src, seconds)
        snap, source, age = next, src, seconds
        draw()
    end)
    q.watchStatus(function(value)
        status = value
        draw()
    end)
end

local function sync()
    snap, source, age = q.stateInfo()
    status = q.status()
end

local function pack(...)
    local count = select("#", ...)
    local out = {}
    for i = 1, count do
        local value = select(i, ...)
        if value ~= nil then
            out[#out + 1] = value
        end
    end
    return out
end

local function isNight(s)
    local today = q.today(s)
    if not today then
        return false
    end
    local rise = q.hourOf(today.sunrise)
    local set = q.hourOf(today.sunset)
    local nowHour = q.hourOf(os.date("%Y-%m-%dT%H:%M"))
    if not (rise and set and nowHour) then
        return false
    end
    return nowHour < rise or nowHour >= set
end

local function iconFor(s)
    if not (s and type(s.now) == "table") then
        return "cloud-off"
    end
    local code = tostring(s.now.code or "")
    if isNight(s) and (code == "100" or code == "103") then
        return code == "100" and "moon" or "moon-stars"
    end
    return q.glyph(code, "cloud-sun")
end

local function placeholder()
    local st = status
    local text = q.t("desktop.waiting", "等待天气数据…")
    if st and st.state == "config" then
        text = q.t("desktop.need_config", "请先填写 API Host 与凭据")
    elseif st and st.state == "error" then
        text = q.t("desktop.error", "获取失败")
    elseif st and st.state == "loading" then
        text = q.t("desktop.loading", "正在获取天气…")
    end
    return ui.column({
        gap = 6,
        padding = 12,
        radius = 12,
        fill = "surface/0.5",
        align = "center",
        justify = "center",
    }, pack(
        ui.glyph({ name = "cloud-off", size = 26, color = "on_surface_variant" }),
        ui.label({
            text = text,
            fontSize = 11,
            color = "on_surface_variant",
            textAlign = "center",
            maxLines = 2,
        })
    ))
end

local function hourlyStrip(s)
    local list = s.hourly
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local cells = {}
    for i = 1, math.min(#list, 6) do
        local item = list[i]
        cells[#cells + 1] = ui.column({ gap = 1, flexGrow = 1, align = "center" }, pack(
            ui.label({
                text = (item.hour ~= "" and item.hour) or "--",
                fontSize = 9,
                color = "on_surface_variant",
            }),
            ui.glyph({ name = q.glyph(item.code), size = 15, color = "primary" }),
            ui.label({ text = q.tempText(item.temp, s.imperial), fontSize = 11, fontWeight = "medium" })
        ))
    end
    return ui.column({ gap = 4 }, pack(
        ui.separator({}),
        ui.row({ gap = 2 }, cells)
    ))
end

local function draw()
    sync()

    local s = snap
    if not (s and type(s.now) == "table") then
        desktopWidget.render(placeholder())
        return
    end

    local now = s.now
    local today = q.today(s)
    local place = (s.location and s.location.name ~= "" and s.location.name) or ""

    local highLow = nil
    if today and today.tempMax ~= nil and today.tempMin ~= nil then
        highLow = ui.label({
            text = q.tempText(today.tempMax, s.imperial) .. " / " .. q.tempText(today.tempMin, s.imperial),
            fontSize = 11,
            color = "on_surface_variant",
            flexGrow = 1,
            textAlign = "end",
        })
    end

    desktopWidget.render(ui.column({ gap = 6, padding = 12, radius = 12, fill = "surface/0.5" }, pack(
        ui.row({ align = "center", gap = 10 }, pack(
            ui.glyph({ name = iconFor(s), size = 28, color = "primary" }),
            ui.column({ gap = 1, flexGrow = 1 }, pack(
                ui.label({
                    text = q.tempText(now.temp, s.imperial),
                    fontSize = 24,
                    fontWeight = "bold",
                }),
                ui.label({
                    text = (now.text ~= "" and now.text) or "--",
                    fontSize = 11,
                    color = "on_surface_variant",
                    maxLines = 1,
                })
            ))
        )),
        ui.row({ align = "center", gap = 6 }, pack(
            ui.label({
                text = place ~= "" and place or q.t("desktop.here", "当前位置"),
                fontSize = 11,
                color = "on_surface_variant",
                flexGrow = 1,
                maxLines = 1,
            }),
            highLow
        )),
        hourlyStrip(s),
        now.feels ~= nil and ui.row({ align = "center", gap = 6 }, pack(
            ui.label({
                text = q.t("desktop.feels", "体感") .. " " .. q.tempText(now.feels, s.imperial),
                fontSize = 10,
                color = "on_surface_variant",
                flexGrow = 1,
            }),
            now.humidity ~= nil and ui.label({
                text = q.t("desktop.humidity", "湿度") .. " " .. tostring(now.humidity) .. "%",
                fontSize = 10,
                color = "on_surface_variant",
            }) or nil
        )) or nil
    )))
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function update()
    ensureWatch()
    noctalia.setUpdateInterval(60000)
    sync()
    draw()
end

function onClick()
    noctalia.togglePanel(q.PANEL)
end

--- 桌面上的右键菜单项：刷新 / 打开面板
function onRightClick()
    q.request("refresh")
end

function onIpc(event, payload)
    if event == "refresh" then
        q.request("refresh")
    elseif event == "reload" then
        watched = false
        update()
    end
end

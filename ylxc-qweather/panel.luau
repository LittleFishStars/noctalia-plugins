--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— 天气详情面板
--
-- 栏上左键打开的弹窗：实况 + 指标网格 + 逐日/逐小时 + 预警 + 空气质量 + 生活指数。
-- 同样是纯展示层；「刷新」按钮只是给 service 发一条命令。
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./lib/qweather.luau")

local watched = false
local snap, source, age = nil, nil, nil
local status = nil
local view = "daily"

-- ── 订阅 ──────────────────────────────────────────────────────────────────

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

--- 过滤掉 nil 的子节点：UI 树里出现 nil 会截断整段
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

-- ── 展示辅助 ──────────────────────────────────────────────────────────────

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

local function windText(s)
    local now = s.now
    if now.windScale == nil and now.windSpeed == nil then
        return nil
    end
    local text = now.windCompass or ""
    if now.windScale ~= nil then
        text = text .. " " .. tostring(now.windScale) .. q.t("bar.wind_scale", "级")
    end
    if now.windSpeed ~= nil then
        text = text .. " " .. q.numberText(now.windSpeed, 1) .. ((s.units and s.units.speed) or "")
    end
    return text
end

local function openSettings()
    local ok = pcall(noctalia.openSettings)
    if not ok then
        noctalia.notify(q.t("panel.settings_title", "天气插件"),
            q.t("panel.settings_body", "请到 设置 → 插件 → ylxc/qweather 里填写"))
    end
end

local function copySummary()
    local s = snap or q.state()
    pcall(noctalia.copyToClipboard, q.summary(s))
    noctalia.notify(q.t("panel.copy_title", "天气"), q.t("panel.copy_body", "已复制到剪贴板"))
end

-- ── 区块 ──────────────────────────────────────────────────────────────────

local function headerBlock(s)
    local now = s.now
    local place = (s.location and s.location.name ~= "" and s.location.name)
        or q.t("panel.here", "当前位置")
    return ui.row({ align = "center", gap = 10 }, pack(
        ui.glyph({ name = iconFor(s), size = 40, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 2 }, pack(
            ui.label({ text = place, fontSize = 15, fontWeight = "semibold" }),
            ui.label({
                text = (now.text ~= "" and now.text) or "--",
                fontSize = 12,
                color = "on_surface_variant",
            })
        )),
        ui.label({ text = q.tempText(now.temp, s.imperial), fontSize = 34, fontWeight = "bold" })
    ))
end

local function metricsBlock(s)
    local now = s.now
    local today = q.today(s)
    local units = s.units or {}

    local function metric(key, value)
        if value == nil or value == "" then
            return nil
        end
        return ui.column({ gap = 1, flexGrow = 1, minWidth = 76 }, pack(
            ui.label({ text = key, fontSize = 11, color = "on_surface_variant" }),
            ui.label({ text = value, fontSize = 13, fontWeight = "medium" })
        ))
    end

    local items = pack(
        metric(q.t("panel.feels", "体感"),
            now.feels ~= nil and q.tempText(now.feels, s.imperial) or nil),
        metric(q.t("panel.humidity", "湿度"),
            now.humidity ~= nil and (tostring(now.humidity) .. "%") or nil),
        metric(q.t("panel.wind", "风"), windText(s)),
        metric(q.t("panel.pressure", "气压"),
            now.pressure ~= nil and q.numberText(now.pressure, 0, units.pressure or "") or nil),
        metric(q.t("panel.visibility", "能见度"),
            now.visibility ~= nil and q.numberText(now.visibility, 1, units.dist or "") or nil),
        metric(q.t("panel.uv", "紫外线"),
            now.uv ~= nil and q.numberText(now.uv, 0) or nil),
        metric(q.t("panel.cloud", "云量"),
            now.cloud ~= nil and (tostring(now.cloud) .. "%") or nil),
        metric(q.t("panel.precip", "降水"),
            now.precip ~= nil and q.numberText(now.precip, 1, units.precip or "") or nil),
        metric(q.t("panel.sun", "日出/日落"),
            (today and today.sunrise ~= "" and today.sunset ~= "")
                and ((q.hourOf(today.sunrise) or "--") .. " / " .. (q.hourOf(today.sunset) or "--"))
                or nil)
    )

    local rows = {}
    local i = 1
    while i <= #items do
        rows[#rows + 1] = ui.row({ gap = 8 }, {
            items[i] or ui.box({ flexGrow = 1 }),
            items[i + 1] or ui.box({ flexGrow = 1 }),
        })
        i = i + 2
    end
    return ui.column({ gap = 8 }, rows)
end

local function alertsBlock(s)
    local list = s.alerts
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local children = {
        ui.label({
            text = q.t("panel.alerts", "气象预警"),
            fontSize = 12,
            fontWeight = "semibold",
            color = "error",
        }),
    }
    for i = 1, math.min(#list, 3) do
        local alert = list[i]
        children[#children + 1] = ui.column({ gap = 2, padding = 8, radius = 8, fill = "error/0.12" }, pack(
            ui.label({
                text = (alert.title ~= "" and alert.title) or alert.event,
                fontSize = 13,
                fontWeight = "semibold",
                color = "error",
                maxLines = 2,
            }),
            alert.description ~= "" and ui.label({
                text = alert.description,
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 3,
            }) or nil
        ))
    end
    return ui.column({ gap = 6 }, children)
end

local function hourlyBlock(s)
    local list = s.hourly
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local cells = {}
    for i = 1, math.min(#list, 12) do
        local item = list[i]
        cells[#cells + 1] = ui.column({ gap = 2, flexGrow = 1, align = "center" }, pack(
            ui.label({
                text = (item.hour ~= "" and item.hour) or "--",
                fontSize = 10,
                color = "on_surface_variant",
            }),
            ui.glyph({ name = q.glyph(item.code), size = 18, color = "primary" }),
            ui.label({ text = q.tempText(item.temp, s.imperial), fontSize = 12, fontWeight = "medium" }),
            item.precipProb ~= nil and ui.label({
                text = tostring(item.precipProb) .. "%",
                fontSize = 9,
                color = "on_surface_variant",
            }) or nil
        ))
    end
    return ui.column({ gap = 6 }, {
        ui.label({
            text = q.t("panel.hourly", "逐小时"),
            fontSize = 12,
            fontWeight = "semibold",
            color = "on_surface_variant",
        }),
        ui.row({ gap = 2 }, cells),
    })
end

local function dailyBlock(s)
    local list = s.daily
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local children = {
        ui.label({
            text = q.t("panel.daily", "逐日预报"),
            fontSize = 12,
            fontWeight = "semibold",
            color = "on_surface_variant",
        }),
    }
    for i, item in ipairs(list) do
        local label = i == 1 and q.t("panel.today", "今天") or (item.date ~= "" and item.date or "--")
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, pack(
            ui.label({
                text = label,
                fontSize = 12,
                minWidth = 44,
                color = i == 1 and "primary" or "on_surface",
            }),
            ui.glyph({ name = q.glyph(item.code), size = 16, color = "on_surface_variant" }),
            ui.label({
                text = (item.text ~= "" and item.text) or "--",
                fontSize = 12,
                flexGrow = 1,
                maxLines = 1,
                color = "on_surface_variant",
            }),
            item.precipProb ~= nil and item.precipProb > 0 and ui.label({
                text = tostring(item.precipProb) .. "%",
                fontSize = 11,
                color = "primary",
            }) or nil,
            ui.label({
                text = q.tempText(item.tempMin, s.imperial) .. " / " .. q.tempText(item.tempMax, s.imperial),
                fontSize = 12,
                fontWeight = "medium",
            })
        ))
    end
    return ui.column({ gap = 6 }, children)
end

local function airBlock(s)
    local air = s.air
    if type(air) ~= "table" or air.aqi == nil then
        return nil
    end
    local color = air.color or q.aqiColor(air.level) or "primary"
    local sub = air.category ~= "" and air.category or air.level
    return ui.column({ gap = 4 }, pack(
        ui.label({
            text = q.t("panel.air", "空气质量"),
            fontSize = 12,
            fontWeight = "semibold",
            color = "on_surface_variant",
        }),
        ui.row({ align = "center", gap = 8 }, pack(
            ui.label({ text = tostring(air.aqi), fontSize = 22, fontWeight = "bold", color = color }),
            ui.column({ gap = 1, flexGrow = 1 }, pack(
                ui.label({ text = sub or "", fontSize = 13 }),
                air.primary ~= "" and ui.label({
                    text = q.t("panel.primary_pollutant", "首要污染物") .. " " .. air.primary,
                    fontSize = 11,
                    color = "on_surface_variant",
                }) or nil
            ))
        ))
    ))
end

local function indicesBlock(s)
    local list = s.indices
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local children = {
        ui.label({
            text = q.t("panel.indices", "生活指数"),
            fontSize = 12,
            fontWeight = "semibold",
            color = "on_surface_variant",
        }),
    }
    for _, item in ipairs(list) do
        children[#children + 1] = ui.column({ gap = 1 }, pack(
            ui.row({ align = "center", gap = 6 }, pack(
                ui.label({ text = item.name, fontSize = 12, fontWeight = "medium", flexGrow = 1 }),
                ui.label({ text = item.category, fontSize = 12, color = "primary" })
            )),
            item.text ~= "" and ui.label({
                text = item.text,
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 2,
            }) or nil
        ))
    end
    return ui.column({ gap = 6 }, children)
end

local function footerBlock(s)
    local parts = {}
    if age then
        if source == "cache" then
            parts[#parts + 1] = string.format(q.t("tooltip.cached", "缓存 · %d 分钟前"), math.floor(age / 60))
        else
            parts[#parts + 1] = string.format(q.t("tooltip.updated", "%d 分钟前更新"), math.floor(age / 60))
        end
    end
    if s.location and s.location.lat and s.location.lon then
        parts[#parts + 1] = string.format("%.2f, %.2f", s.location.lat, s.location.lon)
    end
    parts[#parts + 1] = "QWeather"
    return ui.row({ align = "center", gap = 8 }, pack(
        ui.label({
            text = table.concat(parts, " · "),
            fontSize = 11,
            color = "on_surface_variant",
            flexGrow = 1,
        }),
        ui.button({
            text = q.t("panel.refresh", "刷新"),
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                q.request("refresh")
            end,
        }),
        ui.button({
            text = q.t("panel.copy", "复制"),
            variant = "ghost",
            controlSize = "sm",
            onClick = copySummary,
        })
    ))
end

local function viewSwitcher()
    local function tab(id, label)
        return ui.button({
            text = label,
            variant = view == id and "primary" or "ghost",
            controlSize = "sm",
            onClick = function()
                if view ~= id then
                    view = id
                    draw()
                end
            end,
        })
    end
    return ui.row({ gap = 6 }, pack(
        tab("daily", q.t("panel.view_daily", "逐日")),
        tab("hourly", q.t("panel.view_hourly", "逐小时"))
    ))
end

-- ── 无数据时的占位 ────────────────────────────────────────────────────────

local function emptyTree()
    local st = status
    local title = q.t("panel.no_data", "还没有天气数据")
    local body = ""

    if st and st.state == "config" then
        title = q.t("panel.need_config", "需要先完成配置")
        body = st.message or ""
    elseif st and st.state == "error" then
        title = q.t("panel.error", "获取失败")
        body = st.message or ""
    elseif st and st.state == "loading" then
        title = q.t("panel.loading", "正在获取天气…")
    end

    return ui.column({
        gap = 10,
        padding = 20,
        flexGrow = 1,
        align = "center",
        justify = "center",
    }, pack(
        ui.glyph({ name = "cloud-off", size = 36, color = "on_surface_variant" }),
        ui.label({ text = title, fontSize = 15, fontWeight = "semibold" }),
        body ~= "" and ui.label({
            text = body,
            fontSize = 12,
            color = "on_surface_variant",
            textAlign = "center",
            maxLines = 4,
        }) or nil,
        ui.button({
            text = q.t("panel.open_settings", "插件设置"),
            glyph = "settings",
            variant = "secondary",
            controlSize = "sm",
            onClick = openSettings,
        })
    ))
end

-- ── 绘制 ──────────────────────────────────────────────────────────────────

function draw()
    sync()

    local s = snap
    if not (s and type(s.now) == "table") then
        panel.render(emptyTree())
        return
    end

    panel.render(ui.scroll({ key = "qweather-main", flexGrow = 1, gap = 12, padding = 14 }, pack(
        headerBlock(s),
        ui.separator({}),
        metricsBlock(s),
        alertsBlock(s),
        viewSwitcher(),
        view == "daily" and dailyBlock(s) or hourlyBlock(s),
        ui.separator({}),
        airBlock(s),
        indicesBlock(s),
        ui.separator({}),
        footerBlock(s)
    )))
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function onOpen(context)
    ensureWatch()
    sync()
    draw()

    -- 打开面板时如果数据已经过期，顺手催一次（不额外消耗配额）
    local s = snap
    if not s or q.isStale(s, age, q.num("refresh_minutes", 20)) then
        q.request("refresh")
    end
end

function update()
    ensureWatch()
    noctalia.setUpdateInterval(60000)
    sync()
    draw()
end

function onClose()
    -- 保留订阅，下次打开立即可用
end

function onIpc(event, payload)
    if event == "refresh" then
        q.request("refresh")
        sync()
        draw()
    elseif event == "daily" or event == "hourly" then
        view = event
        draw()
    elseif event == "reload" then
        watched = false
        ensureWatch()
        sync()
        draw()
    end
end

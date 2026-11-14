--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— 栏上的天气组件：图标 + 温度
--
-- 它只是快照的展示层：数据由 service 统一取好，放在插件共享状态里，
-- 所以一个栏上放几个天气组件都不会多花一次请求。
-- 左键由 plugin.toml 的 [widget.actions] 绑成「打开详情面板」，
-- 右键在这里实现为「立刻刷新」。
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./lib/qweather.luau")

local watched = false
local snap, source, age = nil, nil, nil
local status = nil

-- ── 组件级设置（声明在 plugin.toml 的 [[widget.setting]]）──────────────────

local function flag(key, default)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok or value == nil then
        return default
    end
    if type(value) == "boolean" then
        return value
    end
    local text = tostring(value)
    if text == "true" or text == "1" then
        return true
    end
    if text == "false" or text == "0" then
        return false
    end
    return default
end

local function choice(key, default)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok or type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

-- ── 显示细节 ──────────────────────────────────────────────────────────────

--- 现在是夜里的本地时间吗（用来把晴天的太阳换成月亮）
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

--- 图标名：天气现象码 → Tabler 名，晴天在夜里换成月亮
local function iconFor(s)
    local fallback = choice("fallback_glyph", "cloud-sun")
    if not (s and type(s.now) == "table") then
        return fallback
    end
    local code = tostring(s.now.code or "")
    if isNight(s) and (code == "100" or code == "103") then
        return code == "100" and "moon" or "moon-stars"
    end
    return q.glyph(code, fallback)
end

--- 图标颜色：跟随主题 / 主题主色 / 前景文字色 / 按温度上色
local function colorFor(s)
    local mode = choice("glyph_color", "theme")
    if mode == "temp" and s and type(s.now) == "table" then
        return q.tempColor(s.now.temp) or "primary"
    end
    if mode == "text" then
        return "on_surface"
    end
    return "primary"
end

local function alertRow(s)
    local alerts = s and s.alerts
    if type(alerts) ~= "table" or not alerts[1] then
        return nil
    end
    local first = alerts[1]
    local title = first.title ~= "" and first.title or first.event
    return {
        key = q.t("tooltip.alert", "预警"),
        value = title,
    }
end

-- ── 渲染 ──────────────────────────────────────────────────────────────────

local function render()
    local s = snap
    local st = status

    -- 还没有任何数据：按后台服务的状态给出可读的占位
    if not (s and type(s.now) == "table") then
        barWidget.setGlyph(iconFor(nil))
        barWidget.setGlyphColor("primary")
        if st and st.state == "config" then
            barWidget.setText(q.t("bar.setup", "配置"))
            barWidget.setTooltip({
                { key = q.t("tooltip.hint", "提示"), value = st.message or "" },
            })
        elseif st and st.state == "loading" then
            barWidget.setText(q.t("bar.loading", "…"))
            barWidget.setTooltip({
                { key = q.t("tooltip.state", "状态"), value = q.t("bar.loading_full", "正在获取天气…") },
            })
        elseif st and st.state == "error" then
            barWidget.setText(q.t("bar.error", "!"))
            barWidget.setTooltip({
                { key = q.t("tooltip.error", "错误"), value = st.message or "" },
                { key = q.t("tooltip.hint", "提示"), value = q.t("bar.error_hint", "左键打开面板查看详情") },
            })
        else
            barWidget.setText(q.t("bar.idle", "--"))
            barWidget.setTooltip({
                { key = q.t("tooltip.state", "状态"), value = q.t("bar.starting", "等待后台服务取数…") },
            })
        end
        return
    end

    local now = s.now
    local today = q.today(s)
    local parts = {}

    if flag("show_text", true) then
        table.insert(parts, q.tempText(now.temp, s.imperial))
    end
    if flag("show_location", false) and s.location and s.location.name ~= "" then
        table.insert(parts, s.location.name)
    end
    if flag("show_feels", false) and now.feels ~= nil then
        table.insert(parts, q.t("bar.feels", "体感") .. " " .. q.tempText(now.feels, s.imperial))
    end
    if flag("show_high_low", false) and today and today.tempMax ~= nil and today.tempMin ~= nil then
        table.insert(parts, q.tempText(today.tempMin, s.imperial) .. "~" .. q.tempText(today.tempMax, s.imperial))
    end
    if flag("show_humidity", false) and now.humidity ~= nil then
        table.insert(parts, tostring(now.humidity) .. "%")
    end
    if flag("show_wind", false) and now.windScale ~= nil then
        table.insert(parts, tostring(now.windScale) .. q.t("bar.wind_scale", "级"))
    end

    barWidget.setGlyph(iconFor(s))
    barWidget.setGlyphColor(colorFor(s))
    barWidget.setText(table.concat(parts, " "))

    -- 悬停详情
    local rows = {}
    local place = (s.location and s.location.name) or ""
    if place ~= "" then
        table.insert(rows, { key = q.t("tooltip.location", "位置"), value = place })
    end
    table.insert(rows, {
        key = q.t("tooltip.condition", "天气"),
        value = (now.text ~= "" and now.text) or "--",
    })
    table.insert(rows, {
        key = q.t("tooltip.temperature", "温度"),
        value = q.tempText(now.temp, s.imperial) .. (now.feels ~= nil and ("（" .. q.t("bar.feels", "体感") .. " " .. q.tempText(now.feels, s.imperial) .. "）") or ""),
    })
    if today and today.tempMax ~= nil then
        table.insert(rows, {
            key = q.t("tooltip.high_low", "最高/最低"),
            value = q.tempText(today.tempMax, s.imperial) .. " / " .. q.tempText(today.tempMin, s.imperial),
        })
    end
    if today and today.sunrise ~= "" and today.sunset ~= "" then
        table.insert(rows, {
            key = q.t("tooltip.sun", "日出/日落"),
            value = (q.hourOf(today.sunrise) or today.sunrise) .. " / " .. (q.hourOf(today.sunset) or today.sunset),
        })
    end
    if now.humidity ~= nil then
        table.insert(rows, { key = q.t("tooltip.humidity", "湿度"), value = tostring(now.humidity) .. "%" })
    end
    if now.windScale ~= nil or now.windSpeed ~= nil then
        local wind = now.windCompass or ""
        if now.windScale ~= nil then
            wind = wind .. " " .. tostring(now.windScale) .. q.t("bar.wind_scale", "级")
        end
        if now.windSpeed ~= nil then
            wind = wind .. " " .. q.numberText(now.windSpeed, 1) .. (s.units and s.units.speed or "")
        end
        table.insert(rows, { key = q.t("tooltip.wind", "风"), value = wind })
    end
    if now.uv ~= nil then
        table.insert(rows, { key = q.t("tooltip.uv", "紫外线"), value = q.numberText(now.uv, 0) })
    end
    if s.air and s.air.aqi ~= nil then
        local air = q.t("tooltip.aqi", "空气质量") .. " " .. tostring(s.air.aqi)
        if s.air.category ~= "" then
            air = air .. " · " .. s.air.category
        end
        table.insert(rows, { key = q.t("tooltip.air", "空气"), value = air })
    end
    local alert = alertRow(s)
    if alert then
        table.insert(rows, alert)
    end

    local updated = ""
    if source == "cache" and age then
        updated = string.format(q.t("tooltip.cached", "缓存 · %d 分钟前"), math.floor(age / 60))
    elseif age then
        updated = string.format(q.t("tooltip.updated", "%d 分钟前更新"), math.floor(age / 60))
    end
    if updated ~= "" then
        table.insert(rows, { key = q.t("tooltip.data", "数据"), value = updated })
    end
    if q.isStale(s, age, q.num("refresh_minutes", 20)) then
        table.insert(rows, { key = q.t("tooltip.stale", "注意"), value = q.t("tooltip.stale_text", "数据已过期，正在重试") })
    end

    barWidget.setTooltip(rows)
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function update()
    if not watched then
        watched = true
        q.watchState(function(next, src, seconds)
            snap, source, age = next, src, seconds
            render()
        end)
        q.watchStatus(function(value)
            status = value
            render()
        end)
    end

    -- 每分钟重画一次，让「N 分钟前」「已过期」这类相对信息保持正确
    noctalia.setUpdateInterval(60000)

    snap, source, age = q.stateInfo()
    status = q.status()
    render()
end

--- 左键：清单里默认绑成了 panel-toggle；若用户改成 none，这里兜底
function onClick()
    noctalia.togglePanel(q.PANEL)
end

--- 右键：立刻刷新
function onRightClick()
    q.request("refresh")
    noctalia.log("[qweather] 已请求刷新")
end

function onIpc(event, payload)
    if event == "refresh" then
        q.request("refresh")
    elseif event == "toggle" then
        noctalia.togglePanel(q.PANEL)
    elseif event == "reload" then
        watched = false
        update()
    end
end

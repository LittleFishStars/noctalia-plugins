--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/qweather.luau —— 和风天气插件的共享模块
--
-- 只做三件事：
--   1. 读插件设置并归一化成一份 cfg（单位和长度都在这里收敛）
--   2. 提供与 UI 无关的纯函数：单位换算、图标映射、图标配色、时间格式化
--   3. 持有跨入口共享的快照：service 发布，bar / panel / desktop 订阅
--
-- 本模块不发网络请求（那是 lib/api.luau 的事），也不抛出异常：
-- 所有宿主调用都走 pcall，缺 API 时降级而不是崩溃。
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

M.VERSION = "1.0.0"
M.ID = "ylxc/qweather"

M.STATE_KEY = "qweather.snapshot" -- service 发布的天气快照
M.STATUS_KEY = "qweather.status" -- service 发布的服务状态（config / loading / ok / error）
M.CMD_KEY = "qweather.cmd" -- 其它入口发给 service 的命令
M.PANEL = "ylxc/qweather:panel"
M.WIDGET = "ylxc/qweather:weather"

M.SNAPSHOT_FILE = "snapshot.json"
M.GEO_FILE = "geo.json"

-- 插件级设置的默认值。键名必须与 plugin.toml 的 [[setting]] 完全一致，
-- 少一个键就会在设置界面上出现"读了但没声明"的告警。
local DEFAULTS = {
    api_host = "",
    auth_mode = "apikey",
    api_key = "",
    jwt_private_key = "",
    jwt_kid = "",
    jwt_sub = "",
    jwt_iss = "",
    location_mode = "auto",
    city_name = "",
    latitude = "",
    longitude = "",
    location_id = "",
    lang = "zh",
    unit = "metric",
    refresh_minutes = 20,
    daily_days = "7",
    hourly_hours = "24",
    fetch_warning = true,
    fetch_air = true,
    fetch_indices = false,
}

-- ── 基础工具 ──────────────────────────────────────────────────────────────

function M.toBool(v, fallback)
    if type(v) == "boolean" then
        return v
    end
    if v == nil then
        return fallback
    end
    local s = tostring(v):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then
        return true
    end
    if s == "false" or s == "0" or s == "no" or s == "off" then
        return false
    end
    return fallback
end

function M.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "https://abc.qweatherapi.com/" → "abc.qweatherapi.com"
function M.normalizeHost(v)
    local s = M.trim(v):gsub("%s", "")
    s = s:gsub("^[Hh][Tt][Tt][Pp][Ss]?://", "")
    s = s:gsub("^[^/]*://", "")
    local slash = s:find("/", 1, true)
    if slash then
        s = s:sub(1, slash - 1)
    end
    return s
end

--- 读一个已声明的插件设置；未声明 / 读不到时回落到默认值
function M.setting(key)
    local ok, v = pcall(noctalia.getConfig, key)
    if ok and v ~= nil then
        return v
    end
    return DEFAULTS[key]
end

function M.str(key)
    local v = M.setting(key)
    if type(v) == "string" then
        return v
    end
    if v == nil then
        return ""
    end
    return tostring(v)
end

function M.num(key, fallback)
    local n = tonumber(M.setting(key))
    if n == nil then
        return fallback
    end
    return n
end

--- 完整配置。cfg.ready 为 false 时 UI 显示引导而不是空白。
function M.config()
    local cfg = {}
    for key in pairs(DEFAULTS) do
        cfg[key] = M.setting(key)
    end

    cfg.host = M.normalizeHost(cfg.api_host)
    cfg.lang = tostring(cfg.lang or "zh")
    cfg.auth = tostring(cfg.auth_mode or "apikey")
    cfg.imperial = tostring(cfg.unit) == "imperial"
    cfg.days = math.max(1, math.min(10, tonumber(cfg.daily_days) or 7))
    cfg.hours = math.max(1, math.min(240, tonumber(cfg.hourly_hours) or 24))
    cfg.interval = math.max(5, math.min(360, tonumber(cfg.refresh_minutes) or 20))
    cfg.warning = M.toBool(cfg.fetch_warning, true)
    cfg.air = M.toBool(cfg.fetch_air, true)
    cfg.indices = M.toBool(cfg.fetch_indices, false)
    cfg.place = tostring(cfg.location_mode or "auto")

    local jwt_ok = M.trim(cfg.jwt_private_key) ~= ""
        and M.trim(cfg.jwt_kid) ~= ""
        and M.trim(cfg.jwt_sub) ~= ""
        and M.trim(cfg.jwt_iss) ~= ""
    local key_ok = M.trim(cfg.api_key) ~= ""

    if cfg.host == "" then
        cfg.ready = false
        cfg.setup = "host"
    elseif cfg.auth == "jwt" and not jwt_ok then
        cfg.ready = false
        cfg.setup = "jwt"
    elseif cfg.auth ~= "jwt" and not key_ok then
        cfg.ready = false
        cfg.setup = "key"
    else
        cfg.ready = true
        cfg.setup = nil
    end

    return cfg
end

-- ── 单位换算 ──────────────────────────────────────────────────────────────
-- 和风的 v1 系列接口只返回公制（°C / m/s / mm / hPa / m），英制由本地换算，
-- 这样两套单位共用同一份解析代码。

local MS_TO_KMH = 3.6
local MS_TO_MPH = 2.2369363
local M_TO_MI = 0.000621371
local HPA_TO_INHG = 0.02952998

function M.cToF(c)
    return c * 9 / 5 + 32
end

function M.tempLabels(imperial)
    if imperial then
        return "°F", "mph", "mi", "in", "inHg"
    end
    return "°C", "km/h", "km", "mm", "hPa"
end

--- 温度：公制原值 → 用户单位
function M.temp(value, imperial)
    if value == nil then
        return nil
    end
    if imperial then
        return value * 9 / 5 + 32
    end
    return value
end

--- 风速：m/s → km/h | mph
function M.speed(value, imperial)
    if value == nil then
        return nil
    end
    if imperial then
        return value * MS_TO_MPH
    end
    return value * MS_TO_KMH
end

--- 距离：m → km | mi
function M.distance(value, imperial)
    if value == nil then
        return nil
    end
    if imperial then
        return value * M_TO_MI
    end
    return value / 1000
end

--- 降水量：mm → mm | in
function M.precip(value, imperial)
    if value == nil then
        return nil
    end
    if imperial then
        return value / 25.4
    end
    return value
end

--- 气压：hPa → hPa | inHg
function M.pressure(value, imperial)
    if value == nil then
        return nil
    end
    if imperial then
        return value * HPA_TO_INHG
    end
    return value
end

-- ── 图标 ──────────────────────────────────────────────────────────────────
-- 和风图标码 → Tabler 图标名（Noctalia 的图标集）。
-- 码表来自 https://dev.qweather.com/docs/api/weather/weather-conditions/

local GLYPH = {
    ["100"] = "sun",
    ["150"] = "moon",
    ["101"] = "cloud-sun",
    ["102"] = "cloud-sun",
    ["103"] = "cloud-sun",
    ["151"] = "moon-stars",
    ["152"] = "moon-stars",
    ["153"] = "moon-stars",
    ["104"] = "cloud",
    ["154"] = "cloud",
    ["200"] = "wind",
    ["201"] = "wind",
    ["202"] = "wind",
    ["203"] = "wind",
    ["204"] = "wind",
    ["205"] = "wind",
    ["206"] = "wind",
    ["207"] = "wind",
    ["208"] = "wind",
    ["209"] = "wind",
    ["210"] = "wind",
    ["211"] = "wind",
    ["212"] = "wind",
    ["213"] = "wind",
    ["300"] = "cloud-rain",
    ["301"] = "cloud-rain",
    ["302"] = "cloud-storm",
    ["303"] = "cloud-storm",
    ["304"] = "cloud-storm",
    ["305"] = "cloud-rain",
    ["306"] = "cloud-rain",
    ["307"] = "cloud-rain",
    ["308"] = "cloud-rain",
    ["309"] = "cloud-rain",
    ["310"] = "cloud-rain",
    ["311"] = "cloud-rain",
    ["312"] = "cloud-rain",
    ["313"] = "cloud-rain",
    ["314"] = "cloud-rain",
    ["315"] = "cloud-rain",
    ["316"] = "cloud-rain",
    ["317"] = "cloud-rain",
    ["318"] = "cloud-rain",
    ["399"] = "cloud-rain",
    ["400"] = "cloud-snow",
    ["401"] = "cloud-snow",
    ["402"] = "cloud-snow",
    ["403"] = "cloud-snow",
    ["404"] = "cloud-snow",
    ["405"] = "cloud-snow",
    ["406"] = "cloud-snow",
    ["407"] = "cloud-snow",
    ["408"] = "cloud-snow",
    ["409"] = "cloud-snow",
    ["410"] = "cloud-snow",
    ["499"] = "cloud-snow",
    ["500"] = "mist",
    ["501"] = "mist",
    ["509"] = "mist",
    ["510"] = "mist",
    ["514"] = "mist",
    ["515"] = "mist",
    ["502"] = "haze",
    ["503"] = "haze",
    ["504"] = "haze",
    ["507"] = "haze",
    ["508"] = "haze",
    ["511"] = "haze",
    ["512"] = "haze",
    ["513"] = "haze",
    ["900"] = "sun-high",
    ["901"] = "snowflake",
    ["999"] = "cloud-off",
}

--- 天气现象码 → Tabler 图标名；未知码按区间兜底
function M.glyph(code, fallback)
    local key = tostring(code or "")
    local name = GLYPH[key]
    if name then
        return name
    end
    local n = tonumber(key)
    if n then
        if n >= 100 and n < 200 then
            return n >= 150 and "moon" or "sun"
        elseif n >= 200 and n < 300 then
            return "wind"
        elseif n >= 300 and n < 400 then
            return "cloud-rain"
        elseif n >= 400 and n < 500 then
            return "cloud-snow"
        elseif n >= 500 and n < 600 then
            return "mist"
        end
    end
    return fallback or "cloud-sun"
end

--- 图标是否应该用"夜间"配色（月亮系图标）
function M.isNightGlyph(code)
    local n = tonumber(tostring(code or ""))
    return n ~= nil and n >= 150 and n <= 154
end

--- 按温度取一个直观的图标颜色（glyph_color = "temp" 时使用）
function M.tempColor(t)
    if type(t) ~= "number" then
        return nil
    end
    if t <= 0 then
        return "#7cc4ff"
    elseif t <= 10 then
        return "#7fd6ff"
    elseif t <= 18 then
        return "#8de5a8"
    elseif t <= 26 then
        return "#ffd479"
    elseif t <= 32 then
        return "#ffab6b"
    end
    return "#ff7a6b"
end

--- 空气质量等级 → 颜色（和风 v1 的 indexes[].color 优先，这里只是兜底）
function M.aqiColor(level)
    local n = tonumber(tostring(level or ""))
    if n == nil then
        return nil
    end
    if n <= 1 then
        return "#4ecb71"
    elseif n == 2 then
        return "#ffd479"
    elseif n == 3 then
        return "#ffab6b"
    elseif n == 4 then
        return "#ff7a6b"
    elseif n == 5 then
        return "#d96bff"
    end
    return "#b04a4a"
end

-- ── 格式化 ────────────────────────────────────────────────────────────────

--- 取整（用于温度、风速这类展示值）
function M.round(v)
    if type(v) ~= "number" then
        return nil
    end
    if v >= 0 then
        return math.floor(v + 0.5)
    end
    return -math.floor(-v + 0.5)
end

function M.tempText(v, imperial)
    local n = M.round(v)
    if n == nil then
        return "--"
    end
    return tostring(n) .. "°"
end

function M.numberText(v, decimals, suffix)
    if type(v) ~= "number" then
        return "--"
    end
    local s = string.format("%." .. tostring(decimals or 0) .. "f", v)
    if suffix then
        return s .. suffix
    end
    return s
end

--- 湿度：和风 v1 返回 [0,1] 的小数，也兼容旧版的整数百分比
function M.humidityPercent(v)
    if type(v) ~= "number" then
        return nil
    end
    if v <= 1 then
        return M.round(v * 100)
    end
    return M.round(v)
end

--- 概率：v1 返回 [0,1]
function M.probabilityPercent(v)
    if type(v) ~= "number" then
        return nil
    end
    if v <= 1 then
        return M.round(v * 100)
    end
    return M.round(v)
end

--- "2025-10-17T14:00+08:00" / "2025-10-17T06:00Z" → "14:00"
function M.hourOf(iso)
    if type(iso) ~= "string" then
        return nil
    end
    return iso:match("T(%d%d:%d%d)")
end

--- "2025-10-17T..." → "10-17"
function M.dayOf(iso)
    if type(iso) ~= "string" then
        return nil
    end
    local m, d = iso:match("^%d%d%d%d%-(%d%d)%-(%d%d)")
    if m then
        return m .. "-" .. d
    end
    return nil
end

--- "2025-10-17T14:00+08:00" → "10-17 14:00"
function M.stampOf(iso)
    local day = M.dayOf(iso)
    local hour = M.hourOf(iso)
    if day and hour then
        return day .. " " .. hour
    end
    return day or hour or tostring(iso or "")
end

-- ── 快照的存取 ────────────────────────────────────────────────────────────

local memory = nil

function M.dataDir()
    local ok, dir = pcall(noctalia.pluginDataDir)
    if ok and type(dir) == "string" and dir ~= "" then
        return dir
    end
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/.cache/noctalia/plugin-qweather"
end

function M.cachePath()
    return M.dataDir() .. "/" .. M.SNAPSHOT_FILE
end

function M.loadCache()
    local ok, text = pcall(noctalia.readFile, M.cachePath())
    if not ok or type(text) ~= "string" or #text < 2 then
        return nil
    end
    local decode = noctalia.json and noctalia.json.decode
    if not decode then
        return nil
    end
    local ok2, data = pcall(decode, text)
    if ok2 and type(data) == "table" and type(data.now) == "table" then
        data.cached = true
        return data
    end
    return nil
end

function M.saveCache(snap)
    local encode = noctalia.json and noctalia.json.encode
    if not encode then
        return false
    end
    local ok, text = pcall(encode, snap)
    if not ok or type(text) ~= "string" then
        return false
    end
    pcall(noctalia.writeFile, M.cachePath(), text)
    return true
end

function M.clearCache()
    pcall(noctalia.removeFile, M.cachePath())
end

--- 发布快照（只有 service 调用）。disk 为 true 时同时落盘。
function M.publish(snap, disk)
    memory = snap
    pcall(noctalia.state.set, M.STATE_KEY, snap)
    if disk then
        M.saveCache(snap)
    end
end

--- 当前快照：内存 → 共享状态 → 磁盘缓存，一级级往下找
function M.state()
    local ok, shared = pcall(noctalia.state.get, M.STATE_KEY)
    if ok and type(shared) == "table" and type(shared.now) == "table" then
        memory = shared
        return shared
    end
    if memory then
        return memory
    end
    local cached = M.loadCache()
    if cached then
        memory = cached
    end
    return cached
end

--- 给 service 发一条命令（bar / panel / desktop 通过它触发刷新）
function M.request(action)
    pcall(noctalia.state.set, M.CMD_KEY, {
        action = action,
        at = os.time(),
        nonce = tostring(os.clock()),
    })
end

--- 快照 + 来源 + 新鲜度：返回 snap, source（"live" | "cache"）, ageSeconds
function M.stateInfo()
    local ok, shared = pcall(noctalia.state.get, M.STATE_KEY)
    if ok and type(shared) == "table" and type(shared.now) == "table" then
        memory = shared
        local age = type(shared.fetchedAt) == "number" and (os.time() - shared.fetchedAt) or nil
        return shared, "live", age
    end
    if memory and type(memory.now) == "table" then
        local age = type(memory.fetchedAt) == "number" and (os.time() - memory.fetchedAt) or nil
        return memory, "live", age
    end
    local cached = M.loadCache()
    if cached then
        memory = cached
        local age = type(cached.fetchedAt) == "number" and (os.time() - cached.fetchedAt) or nil
        return cached, "cache", age
    end
    return nil, nil, nil
end

--- 订阅快照变化；回调收到 (snap, source, age)
function M.watchState(handler)
    local ok = pcall(noctalia.state.watch, M.STATE_KEY, function()
        local snap, source, age = M.stateInfo()
        if snap then
            handler(snap, source, age)
        end
    end)
    return ok
end

-- ── 服务状态与命令通道 ────────────────────────────────────────────────────

--- 发布服务状态（只有 service 调用）
function M.setStatus(status)
    pcall(noctalia.state.set, M.STATUS_KEY, status)
end

--- 读服务状态：{ state = "config|loading|ok|error", at, message, failures, fetchedAt, partial, problems }
function M.status()
    local ok, value = pcall(noctalia.state.get, M.STATUS_KEY)
    if ok and type(value) == "table" then
        return value
    end
    return nil
end

function M.watchStatus(handler)
    pcall(noctalia.state.watch, M.STATUS_KEY, function()
        handler(M.status())
    end)
end

--- service 侧：监听 UI 发来的刷新请求
function M.watchCommand(handler)
    pcall(noctalia.state.watch, M.CMD_KEY, function(value)
        if type(value) == "table" then
            handler(value)
        end
    end)
end

--- 数据是否已过期（超过刷新间隔的 2.5 倍）
function M.isStale(snap, age, minutes)
    if type(snap) ~= "table" then
        return true
    end
    if type(age) ~= "number" then
        age = type(snap.fetchedAt) == "number" and (os.time() - snap.fetchedAt) or nil
    end
    if type(age) ~= "number" then
        return true
    end
    return age > math.max(10, tonumber(minutes) or 20) * 60 * 2.5
end

--- 快照里“当前这一小时”的预报（用来判断该显示白天还是夜间图标）
function M.currentHour(snap)
    if type(snap) ~= "table" or type(snap.hourly) ~= "table" then
        return nil
    end
    local nowHour = M.hourOf(os.date("%Y-%m-%dT%H:%M"))
    if not nowHour then
        return snap.hourly[1]
    end
    for _, item in ipairs(snap.hourly) do
        if item.hour == nowHour then
            return item
        end
    end
    for _, item in ipairs(snap.hourly) do
        if item.hour and item.hour >= nowHour then
            return item
        end
    end
    return snap.hourly[1]
end

--- 今天那条日预报
function M.today(snap)
    if type(snap) ~= "table" or type(snap.daily) ~= "table" then
        return nil
    end
    return snap.daily[1]
end

--- 一行摘要，供 copyToClipboard / 通知使用
function M.summary(snap)
    if type(snap) ~= "table" or type(snap.now) ~= "table" then
        return "QWeather: --"
    end
    local now = snap.now
    local place = (snap.location and snap.location.name) or ""
    local parts = {}
    if place ~= "" then
        table.insert(parts, place)
    end
    table.insert(parts, tostring(now.text or ""))
    table.insert(parts, M.tempText(now.temp, snap.imperial))
    if snap.daily and snap.daily[1] then
        local d = snap.daily[1]
        if d.tempMax and d.tempMin then
            table.insert(parts, M.tempText(d.tempMin, snap.imperial) .. "~" .. M.tempText(d.tempMax, snap.imperial))
        end
    end
    if snap.air and snap.air.aqi then
        table.insert(parts, "AQI " .. tostring(snap.air.aqi))
    end
    return "QWeather · " .. table.concat(parts, " · ")
end
--- 翻译：查插件自己的 translations/<lang>.json，缺失时回退到调用方给的中文
function M.t(key, fallback)
    local tr = noctalia.tr
    if type(tr) == "function" then
        local ok, value = pcall(tr, key)
        if ok and type(value) == "string" and value ~= "" and value ~= key then
            return value
        end
    end
    return fallback or key
end

return M

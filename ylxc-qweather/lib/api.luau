--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/api.luau —— 和风天气的请求与解析
--
-- 只有 service.luau 会调用 M.fetch()：它是整个插件唯一的取数者，
-- 其它入口都只读快照。这样配额只花一份，UI 也永远看到同一份数据。
--
-- 端点（全部走用户的专属 API Host）：
--   GET /weather/v1/current/{lat}/{lon}          实况
--   GET /weather/v1/hourly/{lat}/{lon}           逐小时（hours=1..240）
--   GET /weather/v1/daily/{lat}/{lon}            逐日（days=1..10）
--   GET /weatheralert/v1/current/{lat}/{lon}     灾害预警
--   GET /airquality/v1/current/{lat}/{lon}       空气质量
--   GET /v7/indices/1d?type=...&location=...     生活指数（仍是 v7 风格）
--   GET /geo/v2/city/lookup?location=...         位置解析（城市名 / ID / 坐标）
--
-- 认证：API Key 走 X-QW-Api-Key 请求头，JWT 走 Authorization: Bearer。
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./qweather.luau")
local jwt = require("./jwt.luau")

local M = {}

-- ── 小工具 ────────────────────────────────────────────────────────────────

local function num(v)
    if type(v) == "number" then
        return v
    end
    return tonumber(v)
end

--- {value = 12.3, unit = "m/s"} → 12.3
local function value(o)
    if type(o) == "table" then
        return num(o.value)
    end
    return num(o)
end

local function firstOf(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil then
            return v
        end
    end
    return nil
end

function M.encode(s)
    local ok, v = pcall(noctalia.string.urlEncode, tostring(s))
    if ok and type(v) == "string" and v ~= "" then
        return v
    end
    -- 兜底：自己按字节百分号编码（中文城市名必须编码）
    return (tostring(s):gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function M.queryString(params)
    local parts = {}
    for key, val in pairs(params or {}) do
        if val ~= nil and val ~= "" then
            table.insert(parts, M.encode(key) .. "=" .. M.encode(val))
        end
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function shortBody(body, n)
    if type(body) ~= "string" then
        return ""
    end
    n = n or 160
    if #body > n then
        return body:sub(1, n) .. "…"
    end
    return body
end

-- ── HTTP ──────────────────────────────────────────────────────────────────

local function authHeaders(cfg, token)
    local headers = {
        "User-Agent: noctalia-qweather/" .. q.VERSION .. " (+https://noctalia.dev)",
        "Accept: application/json",
    }
    if cfg.auth == "jwt" then
        table.insert(headers, "Authorization: Bearer " .. tostring(token or ""))
    else
        table.insert(headers, "X-QW-Api-Key: " .. q.trim(tostring(cfg.api_key)))
    end
    return headers
end

--- GET 一个 JSON 端点；回调 cb(data, err)。
--- err = { kind = "network|http|api|parse|offline|no_http", status, code, body }
---
--- 为什么不用 noctalia.http：和风天气对所有响应都做 gzip（实测即使显式请求
--- Accept-Encoding: identity 也照压），而宿主的 HTTP 层不会解压，插件拿到的是
--- 原始 gzip 字节，JSON 解析必然失败。所以这里改走 curl --compressed。
local function parseAndDeliver(deliver, status, body)
    local data
    local okj, val = pcall(noctalia.json.decode, body)
    if okj and type(val) == "table" then
        data = val
    end

    if status < 200 or status >= 300 then
        deliver(nil, {
            kind = "http",
            status = status,
            code = data and data.code or nil,
            body = shortBody(body),
        })
        return
    end
    if not data then
        deliver(nil, { kind = "parse", status = status, body = shortBody(body) })
        return
    end
    -- 旧版 v7 风格端点用 code 字段表状态；v1 系列没有 code
    local code = data.code
    if code ~= nil and tostring(code) ~= "200" then
        deliver(nil, { kind = "api", status = status, code = tostring(code), body = shortBody(body) })
        return
    end
    deliver(data, nil)
end

local function hasCurl()
    return type(noctalia.commandExists) == "function"
        and type(noctalia.runAsync) == "function"
        and noctalia.commandExists("curl")
end

local function curlArgv(cfg, token, url)
    local argv = {
        "curl", "-sS", "--compressed", "-m", "20",
        "-H", "Accept: application/json",
        "-H", "User-Agent: noctalia-qweather/" .. q.VERSION .. " (+https://noctalia.dev)",
    }
    if cfg.auth == "jwt" then
        table.insert(argv, "-H")
        table.insert(argv, "Authorization: Bearer " .. tostring(token or ""))
    else
        table.insert(argv, "-H")
        table.insert(argv, "X-QW-Api-Key: " .. q.trim(tostring(cfg.api_key)))
    end
    -- 把 HTTP 状态码追加在响应体之后，方便解析
    table.insert(argv, "-w")
    table.insert(argv, "\n%{http_code}")
    table.insert(argv, "--url")
    table.insert(argv, url)
    return argv
end

local function request(cfg, token, path, params, cb)
    local url = "https://" .. cfg.host .. path
    local query = M.queryString(params)
    if query ~= "" then
        url = url .. "?" .. query
    end

    local delivered = false
    local function deliver(data, err)
        if delivered then
            return
        end
        delivered = true
        cb(data, err)
    end

    -- 首选：curl --compressed（自动协商并解开 gzip）
    if hasCurl() then
        noctalia.runAsync(curlArgv(cfg, token, url), function(res)
            local out = (res and res.stdout) or ""
            local body, code = out:match("^(.*)\n(%d%d%d)%s*$")
            if not code then
                local why = ((res and res.stderr) or ""):gsub("%s+$", "")
                deliver(nil, {
                    kind = "network",
                    status = 0,
                    body = shortBody(why ~= "" and why or ("curl exit " .. tostring(res and res.exitCode)), 200),
                })
                return
            end
            parseAndDeliver(deliver, tonumber(code) or 0, body or "")
        end, 25000)
        return
    end

    -- 回退：宿主 HTTP（宿主不解压 gzip，多半会走到 parse 错误）
    if type(noctalia.http) ~= "function" then
        deliver(nil, { kind = "no_http" })
        return
    end

    local ok = noctalia.http({
        url = url,
        method = "GET",
        headers = authHeaders(cfg, token),
        follow_redirects = true,
    }, function(res)
        if type(res) ~= "table" then
            deliver(nil, { kind = "no_response" })
            return
        end
        if not res.ok then
            deliver(nil, {
                kind = "network",
                status = tonumber(res.status) or 0,
                body = shortBody(res.body or ""),
            })
            return
        end
        parseAndDeliver(deliver, tonumber(res.status) or 0, res.body or "")
    end)

    if not ok then
        deliver(nil, { kind = "offline" })
    end
end

-- ── 位置解析 ──────────────────────────────────────────────────────────────

--- 读取 Noctalia 定位服务缓存（IP 级、城市级别），拿经纬度
local LOCATION_FILES = {
    "~/.cache/noctalia/location.json",
    "~/.local/state/noctalia/location.json",
}

function M.noctaliaLocation()
    for _, path in ipairs(LOCATION_FILES) do
        local ok, text = pcall(noctalia.readFile, noctalia.expandPath(path))
        if ok and type(text) == "string" and #text > 2 then
            local ok2, data = pcall(noctalia.json.decode, text)
            if ok2 and type(data) == "table" then
                local lat = num(data.latitude or data.lat)
                local lon = num(data.longitude or data.lon)
                if lat and lon then
                    return {
                        lat = lat,
                        lon = lon,
                        name = tostring(data.city or data.name or ""),
                        source = "noctalia",
                    }
                end
            end
        end
    end
    return nil
end

local function geoCachePath()
    return q.dataDir() .. "/" .. q.GEO_FILE
end

local function geoKey(cfg)
    local place = cfg.place
    if place == "city" then
        return "city|" .. q.trim(cfg.city_name) .. "|" .. cfg.lang
    elseif place == "cityid" then
        return "id|" .. q.trim(cfg.location_id) .. "|" .. cfg.lang
    elseif place == "coords" then
        return "coords|" .. q.trim(cfg.latitude) .. "," .. q.trim(cfg.longitude) .. "|" .. cfg.lang
    end
    return "auto|" .. cfg.lang
end

local function loadGeoCache(key)
    local ok, text = pcall(noctalia.readFile, geoCachePath())
    if not ok or type(text) ~= "string" or #text < 2 then
        return nil
    end
    local ok2, data = pcall(noctalia.json.decode, text)
    if ok2 and type(data) == "table" and data.key == key and type(data.place) == "table" then
        return data.place
    end
    return nil
end

local function saveGeoCache(key, place)
    local encode = noctalia.json and noctalia.json.encode
    if not encode then
        return
    end
    local ok, text = pcall(encode, { key = key, place = place, at = os.time() })
    if ok and type(text) == "string" then
        pcall(noctalia.writeFile, geoCachePath(), text)
    end
end

local function parseGeo(data)
    local list = data and data.location
    if type(list) ~= "table" or type(list[1]) ~= "table" then
        return nil
    end
    local item = list[1]
    local lat = num(item.lat)
    local lon = num(item.lon)
    if not lat or not lon then
        return nil
    end
    local name = tostring(item.name or "")
    local adm = tostring(item.adm2 or "")
    if adm ~= "" and adm ~= name then
        name = adm .. " " .. name
    end
    return {
        id = tostring(item.id or ""),
        name = name,
        lat = lat,
        lon = lon,
        adm1 = tostring(item.adm1 or ""),
        adm2 = tostring(item.adm2 or ""),
        country = tostring(item.country or ""),
        tz = tostring(item.tz or ""),
        source = "geo",
    }
end

--- 解析出 { lat, lon, name, id, source }，必要时消耗一次 GeoAPI 查询（结果落盘复用）
function M.resolve(cfg, token, cb)
    local mode = cfg.place
    local query
    local direct

    if mode == "coords" then
        local lat = tonumber(q.trim(cfg.latitude))
        local lon = tonumber(q.trim(cfg.longitude))
        if not lat or not lon then
            cb(nil, { kind = "config", message = "coords" })
            return
        end
        query = string.format("%.2f,%.2f", lon, lat)
        direct = { lat = lat, lon = lon, name = "", source = "coords" }
    elseif mode == "cityid" then
        query = q.trim(cfg.location_id)
        if query == "" then
            cb(nil, { kind = "config", message = "cityid" })
            return
        end
    elseif mode == "city" then
        query = q.trim(cfg.city_name)
        if query == "" then
            cb(nil, { kind = "config", message = "city" })
            return
        end
    else
        local loc = M.noctaliaLocation()
        if loc then
            query = string.format("%.2f,%.2f", loc.lon, loc.lat)
            direct = loc
        else
            cb(nil, { kind = "config", message = "no_location" })
            return
        end
    end

    local key = geoKey(cfg)
    local cached = loadGeoCache(key)
    if cached then
        if direct and direct.name ~= "" and cached.name == "" then
            cached.name = direct.name
        end
        cb(cached, nil)
        return
    end

    request(cfg, token, "/geo/v2/city/lookup", {
        location = query,
        number = 1,
        lang = cfg.lang,
    }, function(data, err)
        if err then
            -- GeoAPI 失败但已经有坐标（auto / coords）时，退化为"只有坐标"
            if direct then
                cb(direct, nil)
            else
                cb(nil, err)
            end
            return
        end
        local place = parseGeo(data)
        if not place then
            if direct then
                cb(direct, nil)
            else
                cb(nil, { kind = "geo_empty" })
            end
            return
        end
        saveGeoCache(key, place)
        cb(place, nil)
    end)
end

-- ── 各端点解析 ────────────────────────────────────────────────────────────

local function parseCondition(c)
    if type(c) ~= "table" then
        return nil, nil
    end
    return c.text, c.code
end

local function parseWind(w, imperial)
    if type(w) ~= "table" then
        return nil
    end
    local dir
    if type(w.direction) == "table" then
        dir = firstOf(num(w.direction.degree), w.direction.compass)
    end
    return {
        degree = num(w.wind360) or (type(w.direction) == "table" and num(w.direction.degree)) or nil,
        compass = (type(w.direction) == "table" and w.direction.compass) or w.windDir,
        scale = num(w.scale) or num(w.windScale),
        speed = q.speed(value(w.speed) or num(w.windSpeed), imperial),
    }
end

--- 实况：v1 /weather/v1/current 是顶层字段；兼容旧版 {now = {...}}
function M.parseNow(data, cfg)
    local src = type(data.now) == "table" and data.now or data
    local text, code = parseCondition(src.condition)
    if not text then
        text = src.text
    end
    if not code then
        code = src.icon
    end

    local imperial = cfg.imperial
    local wind = parseWind(src.wind, imperial)
    local precipAmount = value(type(src.precipitation) == "table" and src.precipitation.amount)
        or num(src.precip)
    local precipProb = type(src.precipitation) == "table" and src.precipitation.probability or nil

    return {
        text = text or "",
        code = code and tostring(code) or nil,
        temp = q.temp(firstOf(value(src.temperature), num(src.temp)), imperial),
        feels = q.temp(firstOf(value(src.feelsLike), num(src.feelsLike)), imperial),
        humidity = q.humidityPercent(num(src.humidity)),
        windDegree = wind and wind.degree or nil,
        windCompass = wind and wind.compass or nil,
        windScale = wind and wind.scale or nil,
        windSpeed = wind and wind.speed or nil,
        precip = q.precip(precipAmount, imperial),
        precipProb = q.probabilityPercent(precipProb),
        precipType = type(src.precipitation) == "table" and src.precipitation.type or nil,
        pressure = q.pressure(value(src.pressure), imperial),
        visibility = q.distance(value(src.visibility), imperial),
        dew = q.temp(value(src.dewPoint), imperial),
        cloud = q.probabilityPercent(num(src.cloudCover)),
        gust = q.speed(value(src.windGust), imperial),
        uv = num(src.uvIndex) or num(src.uvIndexMax),
        observedAt = tostring(src.observedAt or src.obsTime or src.updateTime or ""),
    }
end

function M.parseHourly(data, cfg)
    local list = type(data.hours) == "table" and data.hours or data.hourly
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for _, item in ipairs(list) do
        if type(item) == "table" then
            local text, code = parseCondition(item.condition)
            if not text then
                text = item.text
            end
            if not code then
                code = item.icon
            end
            local wind = parseWind(item.wind, cfg.imperial)
            local time = tostring(item.forecastTime or item.fxTime or item.time or "")
            table.insert(out, {
                time = time,
                hour = q.hourOf(time) or "",
                day = q.dayOf(time) or "",
                code = code and tostring(code) or nil,
                text = text or "",
                temp = q.temp(firstOf(value(item.temperature), num(item.temp)), cfg.imperial),
                feels = q.temp(firstOf(value(item.feelsLike), num(item.feelsLike)), cfg.imperial),
                humidity = q.humidityPercent(num(item.humidity)),
                windScale = wind and wind.scale or nil,
                windSpeed = wind and wind.speed or nil,
                windDegree = wind and wind.degree or nil,
                precip = q.precip(firstOf(value(type(item.precipitation) == "table" and item.precipitation.amount), num(item.precip)), cfg.imperial),
                precipProb = q.probabilityPercent(type(item.precipitation) == "table" and item.precipitation.probability or nil),
                pressure = q.pressure(value(item.pressure), cfg.imperial),
                visibility = q.distance(value(item.visibility), cfg.imperial),
                cloud = q.probabilityPercent(num(item.cloudCover)),
                uv = num(item.uvIndex),
            })
        end
    end
    return out
end

local function parseDayPeriod(p, cfg)
    if type(p) ~= "table" then
        return nil
    end
    local text, code = parseCondition(p.condition)
    local wind = parseWind(p.wind, cfg.imperial)
    return {
        code = code and tostring(code) or nil,
        text = text or "",
        tempMax = q.temp(firstOf(value(p.temperatureMax), num(p.tempMax)), cfg.imperial),
        tempMin = q.temp(firstOf(value(p.temperatureMin), num(p.tempMin)), cfg.imperial),
        humidity = q.humidityPercent(num(p.humidity)),
        windScale = wind and wind.scale or nil,
        windSpeed = wind and wind.speed or nil,
        windDegree = wind and wind.degree or nil,
        precip = q.precip(value(type(p.precipitation) == "table" and p.precipitation.amount), cfg.imperial),
        precipProb = q.probabilityPercent(type(p.precipitation) == "table" and p.precipitation.probability or nil),
        cloud = q.probabilityPercent(num(p.cloudCover)),
    }
end

function M.parseDaily(data, cfg)
    local list = type(data.days) == "table" and data.days or data.daily
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for _, item in ipairs(list) do
        if type(item) == "table" then
            local startTime = tostring(item.forecastStartTime or item.fxDate or "")
            local astro = type(item.astro) == "table" and item.astro or {}
            local day = parseDayPeriod(item.daytime, cfg)
            local night = parseDayPeriod(item.nighttime, cfg)
            local head = day or night

            local text = head and head.text or item.text or ""
            local code = head and head.code or item.icon or nil
            -- 旧版 v7 用顶层 textDay/textNight
            if item.textDay then
                text = tostring(item.textDay)
                code = tostring(item.iconDay or code or "")
            end

            table.insert(out, {
                date = q.dayOf(startTime) or "",
                startTime = startTime,
                endTime = tostring(item.forecastEndTime or ""),
                code = code and tostring(code) or nil,
                text = text,
                tempMax = q.temp(firstOf(value(item.temperatureMax), num(item.tempMax)), cfg.imperial),
                tempMin = q.temp(firstOf(value(item.temperatureMin), num(item.tempMin)), cfg.imperial),
                tempAvg = q.temp(value(item.temperatureAvg), cfg.imperial),
                uvMax = num(item.uvIndexMax) or num(item.uvIndex),
                humidity = day and day.humidity or nil,
                windScale = day and day.windScale or nil,
                windSpeed = day and day.windSpeed or nil,
                precipProb = day and day.precipProb or nil,
                precip = day and day.precip or nil,
                day = day,
                night = night,
                sunrise = tostring(astro.sunrise or item.sunrise or ""),
                sunset = tostring(astro.sunset or item.sunset or ""),
                moonrise = tostring(astro.moonrise or ""),
                moonset = tostring(astro.moonset or ""),
                moonPhase = tostring(astro.moonPhase or ""),
            })
        end
    end
    return out
end

function M.parseAlerts(data)
    local list = data and data.alerts
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for _, item in ipairs(list) do
        if type(item) ~= "table" then
            continue
        end
        local eventType = type(item.eventType) == "table" and item.eventType or {}
        local messageType = type(item.messageType) == "table" and item.messageType or {}
        local color = type(item.color) == "table" and item.color or nil
        table.insert(out, {
            id = tostring(item.id or ""),
            title = tostring(item.headline or eventType.name or item.title or ""),
            event = tostring(eventType.name or item.title or ""),
            eventCode = eventType.code and tostring(eventType.code) or nil,
            sender = tostring(item.senderName or ""),
            severity = tostring(item.severity or ""),
            severityColor = tostring(item.severityColor or ""),
            urgency = tostring(item.urgency or ""),
            certainty = tostring(item.certainty or ""),
            status = tostring(item.status or ""),
            messageType = tostring(messageType.code or ""),
            issued = tostring(item.issuedTime or ""),
            effective = tostring(item.effectiveTime or ""),
            onset = tostring(item.onsetTime or ""),
            expires = tostring(item.expireTime or ""),
            description = tostring(item.description or ""),
            instruction = tostring(item.instruction or ""),
            color = color and string.format(
                "#%02x%02x%02x",
                math.max(0, math.min(255, num(color.red) or 0)),
                math.max(0, math.min(255, num(color.green) or 0)),
                math.max(0, math.min(255, num(color.blue) or 0))
            ) or nil,
        })
    end
    return out
end

function M.parseAir(data)
    if type(data) ~= "table" then
        return nil
    end
    local indexes = type(data.indexes) == "table" and data.indexes or nil
    local chosen
    if indexes then
        for _, item in ipairs(indexes) do
            if type(item) == "table" and tostring(item.code or "") == "qaqi" then
                chosen = item
                break
            end
        end
        chosen = chosen or indexes[1]
    end
    if not chosen then
        return nil
    end

    local color = type(chosen.color) == "table" and chosen.color or nil
    local primary = type(chosen.primaryPollutant) == "table" and chosen.primaryPollutant or {}
    local health = type(chosen.health) == "table" and chosen.health or {}

    local pollutants = {}
    if type(data.pollutants) == "table" then
        for _, p in ipairs(data.pollutants) do
            if type(p) == "table" and p.code then
                pollutants[tostring(p.code)] = {
                    name = tostring(p.name or p.code),
                    value = value(p.concentration),
                    unit = type(p.concentration) == "table" and tostring(p.concentration.unit or "") or "",
                }
            end
        end
    end

    return {
        code = tostring(chosen.code or ""),
        name = tostring(chosen.name or ""),
        aqi = num(chosen.aqi),
        aqiDisplay = tostring(chosen.aqiDisplay or chosen.aqi or ""),
        level = tostring(chosen.level or ""),
        category = tostring(chosen.category or ""),
        primary = tostring(primary.name or primary.fullName or ""),
        color = color and string.format(
            "#%02x%02x%02x",
            math.max(0, math.min(255, num(color.red) or 0)),
            math.max(0, math.min(255, num(color.green) or 0)),
            math.max(0, math.min(255, num(color.blue) or 0))
        ) or nil,
        advice = type(health.advice) == "table" and tostring(health.advice.generalPopulation or "") or "",
        pollutants = pollutants,
    }
end

function M.parseIndices(data)
    local list = data and data.daily
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for _, item in ipairs(list) do
        if type(item) == "table" then
            table.insert(out, {
                date = tostring(item.date or ""),
                type = tostring(item.type or ""),
                name = tostring(item.name or ""),
                level = tostring(item.level or ""),
                category = tostring(item.category or ""),
                text = tostring(item.text or ""),
            })
        end
    end
    return out
end

-- ── 一次完整抓取 ──────────────────────────────────────────────────────────

local INDICES_TYPES = "1,2,3,5,8" -- 运动 / 洗车 / 穿衣 / 紫外线 / 舒适度

local function collect(cfg, token, place, cb)
    local units = { q.tempLabels(cfg.imperial) }
    local snap = {
        version = q.VERSION,
        fetchedAt = os.time(),
        lang = cfg.lang,
        imperial = cfg.imperial,
        units = {
            temp = units[1],
            speed = units[2],
            dist = units[3],
            precip = units[4],
            pressure = units[5],
        },
        location = {
            name = place.name or "",
            id = place.id or "",
            lat = place.lat,
            lon = place.lon,
            adm1 = place.adm1 or "",
            source = place.source or "",
        },
        errors = {},
        partial = false,
    }

    local latPath = string.format("%.2f/%.2f", place.lat, place.lon)
    local jobs = {}
    local pending = 0
    local finished = false

    local function done()
        if pending > 0 or finished then
            return
        end
        finished = true
        cb(snap, nil)
    end

    local function track()
        pending = pending + 1
        return function()
            pending = pending - 1
            done()
        end
    end

    local function add(key, fn)
        table.insert(jobs, { key = key, fn = fn })
    end

    -- 实况（必需）
    add("now", function()
        local finish = track()
        request(cfg, token, "/weather/v1/current/" .. latPath, {
            localTime = "true",
            lang = cfg.lang,
        }, function(data, err)
            if err then
                snap.errors.now = err
            else
                snap.now = M.parseNow(data, cfg)
            end
            finish()
        end)
    end)

    -- 逐小时
    add("hourly", function()
        local finish = track()
        request(cfg, token, "/weather/v1/hourly/" .. latPath, {
            hours = cfg.hours,
            localTime = "true",
            lang = cfg.lang,
        }, function(data, err)
            if err then
                snap.errors.hourly = err
            else
                snap.hourly = M.parseHourly(data, cfg)
            end
            finish()
        end)
    end)

    -- 逐日
    add("daily", function()
        local finish = track()
        request(cfg, token, "/weather/v1/daily/" .. latPath, {
            days = cfg.days,
            localTime = "true",
            lang = cfg.lang,
        }, function(data, err)
            if err then
                snap.errors.daily = err
            else
                snap.daily = M.parseDaily(data, cfg)
            end
            finish()
        end)
    end)

    -- 灾害预警
    if cfg.warning then
        add("alerts", function()
            local finish = track()
            request(cfg, token, "/weatheralert/v1/current/" .. latPath, {
                localTime = "true",
                lang = cfg.lang,
            }, function(data, err)
                if err then
                    snap.errors.alerts = err
                else
                    snap.alerts = M.parseAlerts(data)
                end
                finish()
            end)
        end)
    end

    -- 空气质量
    if cfg.air then
        add("air", function()
            local finish = track()
            request(cfg, token, "/airquality/v1/current/" .. latPath, {
                lang = cfg.lang,
            }, function(data, err)
                if err then
                    snap.errors.air = err
                else
                    snap.air = M.parseAir(data)
                end
                finish()
            end)
        end)
    end

    -- 生活指数（v7 风格，接受 LocationID 或 "经度,纬度"）
    if cfg.indices then
        add("indices", function()
            local finish = track()
            local location = place.id ~= "" and place.id
                or string.format("%.2f,%.2f", place.lon, place.lat)
            request(cfg, token, "/v7/indices/1d", {
                type = INDICES_TYPES,
                location = location,
                lang = cfg.lang,
            }, function(data, err)
                if err then
                    snap.errors.indices = err
                else
                    snap.indices = M.parseIndices(data)
                end
                finish()
            end)
        end)
    end

    -- 注意：每个 job 内部会先 track()（pending +1），完成后 finish()（pending -1）。
    -- 这里不能再写 pending = #jobs，否则计数翻倍、done() 永远不触发（曾导致取数回调石沉大海）。
    for _, job in ipairs(jobs) do
        local before = pending
        local ok, err = pcall(job.fn)
        if not ok then
            snap.errors[job.key] = { kind = "internal", message = tostring(err) }
            if pending > before then
                pending = pending - 1
            end
        end
    end
    done()
end

--- 完整流程：JWT（可选）→ 位置解析 → 并发取数 → 快照
function M.fetch(cfg, cb)
    if not cfg.ready then
        cb(nil, { kind = "config", message = cfg.setup or "setup" })
        return
    end

    local function withToken(fn)
        if cfg.auth == "jwt" then
            jwt.get(cfg, function(token, err)
                if not token then
                    cb(nil, { kind = "jwt", message = tostring(err or "") })
                    return
                end
                fn(token)
            end)
        else
            fn(nil)
        end
    end

    withToken(function(token)
        M.resolve(cfg, token, function(place, err)
            if not place then
                cb(nil, err or { kind = "geo_empty" })
                return
            end
            collect(cfg, token, place, function(snap, cerr)
                if cerr then
                    cb(nil, cerr)
                    return
                end
                if not snap.now then
                    cb(nil, snap.errors.now or { kind = "empty" })
                    return
                end
                if next(snap.errors) ~= nil then
                    snap.partial = true
                end
                cb(snap, nil)
            end)
        end)
    end)
end

--- 把 err 变成人能读的一行（供日志 / 面板使用）
function M.describe(err)
    if type(err) ~= "table" then
        return tostring(err or "unknown")
    end
    local kind = err.kind or "unknown"
    if kind == "no_http" then
        return "宿主没有提供 noctalia.http（需要较新的 Noctalia）"
    elseif kind == "offline" then
        return "请求未能发出（离线或 URL 不合法）"
    elseif kind == "network" then
        return "网络错误（HTTP " .. tostring(err.status or 0) .. "）"
    elseif kind == "http" then
        return "接口返回 HTTP " .. tostring(err.status or 0)
            .. (err.code and (" / code " .. err.code) or "")
            .. (err.body and (" · " .. err.body) or "")
    elseif kind == "api" then
        return "接口错误码 " .. tostring(err.code or "")
            .. (err.body and (" · " .. err.body) or "")
    elseif kind == "parse" then
        return "响应不是合法 JSON" .. (err.body and (" · " .. err.body) or "")
    elseif kind == "config" then
        return "配置不完整（" .. tostring(err.message or "") .. "）"
    elseif kind == "geo_empty" then
        return "没有找到这个地点，检查城市名 / LocationID"
    elseif kind == "jwt" then
        return "JWT 生成失败：" .. tostring(err.message or "")
    end
    return tostring(err.message or kind)
end

return M

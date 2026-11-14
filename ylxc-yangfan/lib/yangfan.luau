--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/yangfan.luau —— 扬帆云面板的共享模块
--
-- 这里放三件事，其它入口（service / bar / panel）只调用不重复实现：
--   1. 配置读取：所有 [[setting]] / [[widget.setting]] 的键都登记在 DEFAULTS
--   2. 接口调用：登录（邮箱 + 密码换 Bearer）→ getSubscribe → info
--   3. 令牌缓存：token 落到 pluginDataDir/session.json，失效（403）自动重登
--
-- 接口事实（2026-11-14 实测，面板为 Xboard 内核）：
--   POST /api/v1/passport/auth/login   {"email","password"}
--        → data.auth_data = "Bearer <token>"（服务端已带前缀）
--   GET  /api/v1/user/getSubscribe     → transfer_enable / u / d / expired_at
--                                        / plan / reset_day / subscribe_url
--   GET  /api/v1/user/info             → balance / commission_balance（单位：分）
--   未登录时回 HTTP 403 + {"status":"fail","message":"未登录或登陆已过期"}
--   注意：nginx 会拦掉没有 User-Agent 的请求（直接 403 空页），所以每个
--   请求都必须显式带 UA。
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

M.PANEL = "ylxc/yangfan:panel"
M.WIDGET = "ylxc/yangfan:main"

M.STATE_KEY = "yangfan.snapshot" -- service 发布的快照
M.STATUS_KEY = "yangfan.status" -- service 的运行状态
M.CMD_KEY = "yangfan.cmd" -- UI 发给 service 的命令

local SESSION_FILE = "session.json"
local NOTIFY_FILE = "notified.json"

local DEFAULT_BASE = "https://panel.example.com"
local UA = "Mozilla/5.0 (X11; Linux x86_64) noctalia-plugin-yangfan/1.0"

--- 插件级 + 栏组件级设置的全集。键名必须与 plugin.toml 完全一致，
--- 少一个会被 `noctalia plugins lint` 报「读了但没声明」。
local DEFAULTS = {
    -- 插件级
    email = "",
    password = "",
    base_url = DEFAULT_BASE,
    keep_session = true,
    refresh_minutes = 10,
    notify_enabled = true,
    warn_traffic_percent = 10,
    warn_days = 3,
    -- 栏组件级
    show_glyph = true,
    glyph = "cloud",
    display = "remain",
}

--- 哪些键是「插件级」的。config() 只能读这些：栏组件级设置只在
--- [[widget.setting]] 里声明，service / panel 去读会被宿主报 undeclared。
local PLUGIN_KEYS = {
    "email",
    "password",
    "base_url",
    "keep_session",
    "refresh_minutes",
    "notify_enabled",
    "warn_traffic_percent",
    "warn_days",
}

-- ── 基础工具 ──────────────────────────────────────────────────────────────

function M.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 读一个已声明的设置；读不到时回落到 DEFAULTS
function M.setting(key)
    local ok, value = pcall(noctalia.getConfig, key)
    if ok and value ~= nil then
        return value
    end
    return DEFAULTS[key]
end

function M.str(key)
    local value = M.setting(key)
    if type(value) == "string" then
        return value
    end
    if value == nil then
        return ""
    end
    return tostring(value)
end

function M.num(key, fallback)
    local n = tonumber(M.setting(key))
    if n == nil then
        return fallback
    end
    return n
end

function M.flag(key, fallback)
    local value = M.setting(key)
    if type(value) == "boolean" then
        return value
    end
    if value == nil then
        return fallback
    end
    local text = tostring(value)
    if text == "true" or text == "1" then
        return true
    end
    if text == "false" or text == "0" then
        return false
    end
    return fallback
end

--- 面板地址归一化：去掉尾部斜杠与误粘的 /dashboard 之类路径
function M.normalizeBase(value)
    local s = M.trim(value)
    if s == "" then
        return DEFAULT_BASE
    end
    s = s:gsub("/+$", "")
    s = s:gsub("/(dashboard|login|plan|order|profile|traffic|invite|node|knowledge)$", "")
    if not s:match("^https?://") then
        s = "https://" .. s
    end
    return s
end

--- 完整配置。cfg.ready == false 时 UI 显示引导而不是空白。
function M.config()
    local cfg = {}
    for _, key in ipairs(PLUGIN_KEYS) do
        cfg[key] = M.setting(key)
    end
    cfg.base = M.normalizeBase(cfg.base_url)
    cfg.email = M.trim(cfg.email)
    cfg.interval = math.max(1, math.min(1440, tonumber(cfg.refresh_minutes) or 10))
    cfg.warnPercent = math.max(1, math.min(50, tonumber(cfg.warn_traffic_percent) or 10))
    cfg.warnDays = math.max(1, math.min(30, tonumber(cfg.warn_days) or 3))
    cfg.ready = cfg.email ~= "" and M.trim(cfg.password) ~= ""
    if cfg.email == "" then
        cfg.problem = "settings"
    elseif M.trim(cfg.password) == "" then
        cfg.problem = "password"
    end
    return cfg
end

-- ── 格式化 ────────────────────────────────────────────────────────────────

--- 字节 → "172.19 GB" / "820 MB"（二进制进位，与面板一致）
function M.bytesText(bytes, decimals)
    local n = tonumber(bytes)
    if n == nil then
        return "--"
    end
    local units = { "B", "KB", "MB", "GB", "TB", "PB" }
    local index = 1
    while n >= 1024 and index < #units do
        n = n / 1024
        index = index + 1
    end
    local digits = decimals
    if digits == nil then
        digits = index >= 4 and 2 or 0
    end
    return string.format("%." .. tostring(digits) .. "f %s", n, units[index])
end

--- 只要数字，给栏上用（"172.2G"）
function M.bytesShort(bytes)
    local n = tonumber(bytes)
    if n == nil then
        return "--"
    end
    local units = { "B", "K", "M", "G", "T", "P" }
    local index = 1
    while n >= 1024 and index < #units do
        n = n / 1024
        index = index + 1
    end
    if index <= 2 then
        return string.format("%.0f%s", n, units[index])
    end
    return string.format("%.1f%s", n, units[index])
end

function M.percentText(ratio, decimals)
    local r = tonumber(ratio)
    if r == nil then
        return "--"
    end
    return string.format("%." .. tostring(decimals or 1) .. "f%%", r * 100)
end

function M.dateText(ts)
    local n = tonumber(ts)
    if n == nil or n <= 0 then
        return "长期"
    end
    local ok, text = pcall(noctalia.formatTime, "%Y-%m-%d", n)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return os.date("%Y-%m-%d", n)
end

function M.timeText(ts)
    local n = tonumber(ts)
    if n == nil or n <= 0 then
        return "--"
    end
    local ok, text = pcall(noctalia.formatTime, "%H:%M", n)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return os.date("%H:%M", n)
end

--- 金额：接口给的是「分」
function M.moneyText(cents)
    local n = tonumber(cents)
    if n == nil then
        return "--"
    end
    return string.format("%.2f", n / 100)
end

-- ── 本地文件（令牌缓存 / 提醒去重状态）───────────────────────────────────

function M.dataDir()
    local ok, dir = pcall(noctalia.pluginDataDir)
    if ok and type(dir) == "string" and dir ~= "" then
        return dir
    end
    return nil
end

local function path(name)
    local dir = M.dataDir()
    if not dir then
        return nil
    end
    return dir .. "/" .. name
end

local function readJson(name)
    local file = path(name)
    if not file then
        return nil
    end
    local ok, text = pcall(noctalia.readFile, file)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    local okj, value = pcall(noctalia.json.decode, text)
    if okj and type(value) == "table" then
        return value
    end
    return nil
end

local function writeJson(name, value)
    local file = path(name)
    if not file then
        return false
    end
    local okj, text = pcall(noctalia.json.encode, value, false)
    if not okj or type(text) ~= "string" then
        return false
    end
    local ok = pcall(noctalia.writeFile, file, text)
    return ok
end

-- ── 令牌缓存 ──────────────────────────────────────────────────────────────

--- 读缓存令牌（"Bearer xxx"）；keep_session 关掉时永远返回 nil
function M.loadSession()
    if not M.flag("keep_session", true) then
        return nil
    end
    local data = readJson(SESSION_FILE)
    if type(data) == "table" and type(data.auth) == "string" and data.auth ~= "" then
        return data.auth
    end
    return nil
end

function M.saveSession(auth)
    if not M.flag("keep_session", true) then
        return
    end
    if type(auth) ~= "string" or auth == "" then
        return
    end
    writeJson(SESSION_FILE, { auth = auth, at = os.time() })
end

function M.clearSession()
    local file = path(SESSION_FILE)
    if file then
        pcall(noctalia.removeFile, file)
    end
end

--- 提醒去重状态：{traffic = true, days = true}
function M.loadNotified()
    local data = readJson(NOTIFY_FILE)
    if type(data) == "table" then
        return data
    end
    return {}
end

function M.saveNotified(value)
    writeJson(NOTIFY_FILE, value or {})
end

-- ── HTTP ──────────────────────────────────────────────────────────────────

local function isGzip(body)
    return type(body) == "string" and #body >= 2 and body:byte(1) == 31 and body:byte(2) == 139
end

local function decodeJson(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local ok, value = pcall(noctalia.json.decode, body)
    if ok and type(value) == "table" then
        return value
    end
    return nil
end

--- 兜底通道：宿主 HTTP 拿不到可解析的 JSON 时（典型是响应被 gzip 压缩，
--- 宿主的 HTTP 层不解压）改用 curl --compressed。argv 形式，不经过 shell。
local function curlRequest(req, deliver)
    local dir = M.dataDir()
    if not dir or not noctalia.commandExists or not noctalia.commandExists("curl") then
        deliver(0, "")
        return
    end

    local outFile = dir .. "/_resp.json"
    local bodyFile = dir .. "/_req.json"

    local argv = {
        "curl", "-sS", "--compressed", "-m", "20",
        "-o", outFile, "-w", "%{http_code}",
        "-X", req.method or "GET",
    }
    if req.body then
        pcall(noctalia.writeFile, bodyFile, req.body)
        table.insert(argv, "--data-binary")
        table.insert(argv, "@" .. bodyFile)
    end
    for _, line in ipairs(req.headers or {}) do
        table.insert(argv, "-H")
        table.insert(argv, line)
    end
    table.insert(argv, req.url)

    noctalia.runAsync(argv, function(result)
        local status = 0
        if type(result) == "table" and type(result.stdout) == "string" then
            status = tonumber(M.trim(result.stdout)) or 0
        end
        local ok, body = pcall(noctalia.readFile, outFile)
        deliver(status, (ok and type(body) == "string") and body or "")
    end, 25000)
end

--- 发一个请求，cb(status, body) 保证只回调一次。
function M.http(req, cb)
    local done = false
    local function deliver(status, body)
        if done then
            return
        end
        done = true
        cb(tonumber(status) or 0, body or "")
    end

    if type(noctalia.http) ~= "function" then
        curlRequest(req, deliver)
        return
    end

    local ok = pcall(noctalia.http, {
        url = req.url,
        method = req.method or "GET",
        headers = req.headers or {},
        body = req.body,
        follow_redirects = true,
    }, function(response)
        if type(response) ~= "table" then
            curlRequest(req, deliver)
            return
        end
        local body = response.body or ""
        if not response.ok or isGzip(body) then
            curlRequest(req, deliver)
            return
        end
        deliver(tonumber(response.status) or 0, body)
    end)

    if not ok then
        curlRequest(req, deliver)
    end
end

local function baseHeaders(auth)
    local headers = {
        "Accept: application/json",
        "User-Agent: " .. UA,
        "Accept-Encoding: identity",
    }
    if type(auth) == "string" and auth ~= "" then
        table.insert(headers, "Authorization: " .. auth)
    end
    return headers
end

--- 拆 {status, message, data} 信封
local function envelope(httpStatus, body)
    local data = decodeJson(body)
    if not data then
        local hint = (httpStatus == 0) and "网络不通" or ("HTTP " .. tostring(httpStatus))
        return nil, { kind = "parse", status = httpStatus, message = "响应不是 JSON（" .. hint .. "）" }
    end
    if data.status ~= "success" then
        local message = data.message
        if type(message) ~= "string" or message == "" then
            message = "HTTP " .. tostring(httpStatus)
        end
        return nil, { kind = "api", status = httpStatus, message = message }
    end
    if httpStatus < 200 or httpStatus >= 300 then
        return nil, { kind = "http", status = httpStatus, message = "HTTP " .. tostring(httpStatus) }
    end
    return data, nil
end

local function isAuthError(err)
    if type(err) ~= "table" then
        return false
    end
    local status = tonumber(err.status) or 0
    if status == 401 or status == 403 then
        return true
    end
    local message = tostring(err.message or "")
    return message:find("未登录", 1, true) ~= nil
end

-- ── 接口 ──────────────────────────────────────────────────────────────────

--- 邮箱 + 密码换令牌；cb(auth, err)，auth 形如 "Bearer xxx"
function M.login(cfg, cb)
    local okJson, payload = pcall(noctalia.json.encode, {
        email = M.trim(cfg.email),
        password = M.trim(cfg.password),
    })
    if not okJson or type(payload) ~= "string" then
        cb(nil, { kind = "parse", status = 0, message = "账号密码无法编码成 JSON" })
        return
    end
    local headers = baseHeaders(nil)
    table.insert(headers, 1, "Content-Type: application/json")

    M.http({
        url = cfg.base .. "/api/v1/passport/auth/login",
        method = "POST",
        headers = headers,
        body = (type(payload) == "string" and payload) or "{}",
    }, function(status, body)
        local data, err = envelope(status, body)
        if not data then
            cb(nil, err)
            return
        end
        local inner = data.data
        local auth = type(inner) == "table" and inner.auth_data or nil
        if type(auth) ~= "string" or auth == "" then
            cb(nil, { kind = "api", status = status, message = "登录响应里没有 auth_data" })
            return
        end
        if not auth:match("^[Bb]earer ") then
            auth = "Bearer " .. auth
        end
        cb(auth, nil)
    end)
end

--- GET /api/v1/user/getSubscribe
function M.subscribe(cfg, auth, cb)
    M.http({
        url = cfg.base .. "/api/v1/user/getSubscribe",
        method = "GET",
        headers = baseHeaders(auth),
    }, function(status, body)
        local data, err = envelope(status, body)
        if not data then
            cb(nil, err)
            return
        end
        cb(type(data.data) == "table" and data.data or nil, nil)
    end)
end

--- GET /api/v1/user/info（只要余额一类的附加字段，失败不影响主数据）
function M.info(cfg, auth, cb)
    M.http({
        url = cfg.base .. "/api/v1/user/info",
        method = "GET",
        headers = baseHeaders(auth),
    }, function(status, body)
        local data, err = envelope(status, body)
        if not data or type(data.data) ~= "table" then
            cb(nil, err)
            return
        end
        cb(data.data, nil)
    end)
end

--- 面板原始响应 → 展示用快照
local function buildSnapshot(raw, cfg)
    local total = tonumber(raw.transfer_enable) or 0
    local up = tonumber(raw.u) or 0
    local down = tonumber(raw.d) or 0
    local used = up + down
    local unlimited = total <= 0
    local remain = unlimited and 0 or math.max(0, total - used)
    local percent = unlimited and 0 or math.min(1, used / total)
    local expiredAt = tonumber(raw.expired_at) or 0
    local days = nil
    if expiredAt > 0 then
        days = math.max(0, math.floor((expiredAt - os.time()) / 86400))
    end
    local plan = raw.plan
    return {
        email = tostring(raw.email or cfg.email),
        planName = (type(plan) == "table" and type(plan.name) == "string") and plan.name or nil,
        planId = tonumber(raw.plan_id),
        total = total,
        used = used,
        up = up,
        down = down,
        remain = remain,
        unlimited = unlimited,
        percent = percent,
        remainPercent = unlimited and 1 or (1 - percent),
        expiredAt = expiredAt,
        days = days,
        -- 本面板的 reset_day 是「距离下次流量重置还有多少天」（实测与面板文案一致），
        -- 不是 Xboard 原版的「每月几号」。
        resetInDays = tonumber(raw.reset_day),
        subscribeUrl = raw.subscribe_url,
        balance = nil,
        fetchedAt = os.time(),
    }
end

--- 主入口：拿一份快照。onSnap(snap, err) 可能被调用两次——
--- 第一次带主数据（没有余额），info 回来后补上余额再回调一次。
function M.ensure(cfg, onSnap)
    local cached = M.loadSession()
    local relogged = false

    local function publish(raw, auth)
        local snap = buildSnapshot(raw, cfg)
        onSnap(snap, nil)
        M.info(cfg, auth, function(detail)
            if detail then
                local balance = tonumber(detail.balance)
                if balance ~= nil then
                    snap.balance = balance
                    onSnap(snap, nil)
                end
            end
        end)
    end

    local function attempt(auth)
        M.subscribe(cfg, auth, function(raw, err)
            if raw then
                publish(raw, auth)
                return
            end
            if isAuthError(err) and not relogged then
                relogged = true
                M.clearSession()
                noctalia.log("[yangfan] 令牌失效，用邮箱密码重新登录")
                M.login(cfg, function(nextAuth, loginErr)
                    if not nextAuth then
                        onSnap(nil, loginErr)
                        return
                    end
                    M.saveSession(nextAuth)
                    M.subscribe(cfg, nextAuth, function(raw2, err2)
                        if not raw2 then
                            onSnap(nil, err2)
                            return
                        end
                        publish(raw2, nextAuth)
                    end)
                end)
                return
            end
            onSnap(nil, err)
        end)
    end

    if cached then
        attempt(cached)
    else
        M.login(cfg, function(auth, err)
            if not auth then
                onSnap(nil, err)
                return
            end
            M.saveSession(auth)
            attempt(auth)
        end)
    end
end

-- ── 共享状态 ──────────────────────────────────────────────────────────────

local memory = nil

function M.publish(snap)
    memory = snap
    pcall(noctalia.state.set, M.STATE_KEY, snap)
end

function M.state()
    local ok, shared = pcall(noctalia.state.get, M.STATE_KEY)
    if ok and type(shared) == "table" then
        memory = shared
        return shared
    end
    return memory
end

--- 快照 + 数据年龄（秒）
function M.stateInfo()
    local snap = M.state()
    if type(snap) ~= "table" then
        return nil, nil
    end
    local age = nil
    if type(snap.fetchedAt) == "number" then
        age = os.time() - snap.fetchedAt
    end
    return snap, age
end

function M.watchState(handler)
    return pcall(noctalia.state.watch, M.STATE_KEY, function()
        local snap, age = M.stateInfo()
        if snap then
            handler(snap, age)
        end
    end)
end

--- 发布运行状态：{ state = "config|loading|ok|error", at, message, failures }
function M.setStatus(status)
    pcall(noctalia.state.set, M.STATUS_KEY, status)
end

function M.status()
    local ok, shared = pcall(noctalia.state.get, M.STATUS_KEY)
    if ok and type(shared) == "table" then
        return shared
    end
    return nil
end

function M.watchStatus(handler)
    return pcall(noctalia.state.watch, M.STATUS_KEY, function(value)
        if type(value) == "table" then
            handler(value)
        end
    end)
end

--- UI → service 的一次性命令（靠 nonce 让同样的动作也能重复触发）
function M.request(action)
    pcall(noctalia.state.set, M.CMD_KEY, {
        action = action,
        at = os.time(),
        nonce = tostring(os.clock()),
    })
end

function M.watchCommand(handler)
    pcall(noctalia.state.watch, M.CMD_KEY, function(value)
        if type(value) == "table" then
            handler(value)
        end
    end)
end

--- 数据是否过期（超过刷新间隔的 2.5 倍）
function M.isStale(snap, age, minutes)
    if type(snap) ~= "table" then
        return true
    end
    local seconds = age
    if type(seconds) ~= "number" then
        if type(snap.fetchedAt) ~= "number" then
            return true
        end
        seconds = os.time() - snap.fetchedAt
    end
    return seconds > math.max(5, tonumber(minutes) or 10) * 60 * 2.5
end

--- 错误 → 一行中文
function M.describe(err)
    if type(err) ~= "table" then
        return "未知错误"
    end
    local message = tostring(err.message or "")
    if err.kind == "parse" then
        return message ~= "" and message or "响应无法解析"
    end
    local status = tonumber(err.status) or 0
    if status == 403 or status == 401 then
        return message ~= "" and message or "登录已失效，且自动登录失败"
    end
    if message ~= "" then
        return message
    end
    return "请求失败（HTTP " .. tostring(status) .. "）"
end

function M.t(key, fallback, subst)
    local ok, text = pcall(noctalia.tr, key, subst)
    if ok and type(text) == "string" and text ~= "" and text ~= key then
        return text
    end
    return fallback or key
end

return M

-- 冒烟测试：用 mock 的宿主环境跑 service / bar / panel，喂脱敏后的真实接口响应。
-- 不连网、不需要账号，检查登录 / 自动重登 / 渲染 / 告警这几条路径不报错、输出对得上。
-- 运行：lua5.4 tests/harness.luau <scenario>
--   auto      有缓存令牌但已失效 → 自动用邮箱密码重登 → 出数据
--   fresh     无缓存令牌 → 直接登录 → 出数据
--   noconfig  没填邮箱密码 → 未配置
--   badlogin  令牌失效且登录失败 → 错误态
--   unlimited transfer_enable = 0 → 不限量

local SCENARIO = arg[1] or "auto"
-- 以脚本自身位置推导插件根目录，方便 `lua5.4 tests/harness.luau auto`
local SELF = (arg and arg[0]) or "tests/harness.luau"
local TESTS = SELF:match("^(.*)/") or "."
local PLUGIN = TESTS .. "/../"
local DATADIR = TESTS .. "/.data"

os.execute("mkdir -p '" .. DATADIR .. "'")
os.execute("rm -f '" .. DATADIR .. "/session.json' '" .. DATADIR .. "/notified.json'")

-- ── require 垫片：把 "./lib/x.luau" 映射成 plugin 目录下的真实文件 ──────────
local cache = {}
local rawRequire = require
require = function(path)
    local rel = path:gsub("^%./", "")
    local full = PLUGIN .. rel
    if cache[full] ~= nil then
        return cache[full]
    end
    local chunk = assert(loadfile(full))
    local mod = chunk()
    cache[full] = mod
    return mod
end

local FIX = dofile(TESTS .. "/fixtures.luau")

-- ── 场景配置 ──────────────────────────────────────────────────────────────
local CONFIG = {
    email = "user@example.com",
    password = "secret-password",
    base_url = "https://panel.invalid", -- 测试用假域名（mock 不发真请求）
    keep_session = true,
    refresh_minutes = 10,
    notify_enabled = true,
    warn_traffic_percent = 10,
    warn_days = 3,
    show_glyph = true,
    glyph = "cloud",
    display = "remain",
}

if SCENARIO == "noconfig" then
    CONFIG.email = ""
    CONFIG.password = ""
end

if SCENARIO == "auto" or SCENARIO == "badlogin" then
    local f = assert(io.open(DATADIR .. "/session.json", "w"))
    f:write('{"auth":"Bearer STALE","at":1}')
    f:close()
end

-- ── mock 宿主 ─────────────────────────────────────────────────────────────
local store, watchers = {}, {}
local counters = { login = 0, subscribe = 0, info = 0 }
local SERVER = { valid = "Bearer VALIDTOKEN" }
local INTERVAL = 0
local RENDERED = { bar = nil, panel = nil, tooltip = nil }

local function markerDecode(text)
    if text == "AUTH_DATA" then
        return FIX.loginOk
    elseif text == "SUBSCRIBE" then
        if SCENARIO == "lowtraffic" or SCENARIO == "expiring" then
            local copy = { status = FIX.sub.status, message = FIX.sub.message, data = {} }
            for k, v in pairs(FIX.sub.data) do
                copy.data[k] = v
            end
            if SCENARIO == "lowtraffic" then
                copy.data.transfer_enable = 30 * 1024 * 1024 * 1024
            else
                copy.data.expired_at = os.time() + 2 * 86400
            end
            return copy
        end
        if SCENARIO == "unlimited" then
            local copy = {}
            for k, v in pairs(FIX.sub) do
                copy[k] = v
            end
            copy.data = {}
            for k, v in pairs(FIX.sub.data) do
                copy.data[k] = v
            end
            copy.data.transfer_enable = 0
            return copy
        end
        return FIX.sub
    elseif text == "INFO" then
        return FIX.info
    elseif text == "AUTH_FAIL" then
        return FIX.authFail
    elseif text == "LOGIN_FAIL" then
        return FIX.loginFail
    end
    return nil
end

noctalia = {
    log = function(msg)
        print("  [log] " .. tostring(msg))
    end,
    getConfig = function(key)
        return CONFIG[key]
    end,
    json = {
        decode = function(text)
            -- 会话文件是真 JSON；其余是测试用的标记串
            if type(text) == "string" and text:find('"auth"', 1, true) then
                return { auth = text:match('"auth"%s*:%s*"([^"]*)"'), at = 1 }
            end
            return markerDecode(text)
        end,
        encode = function(value)
            if type(value) ~= "table" then
                return "null"
            end
            if type(value.email) == "string" then
                return '{"email":"' .. value.email .. '","password":"' .. tostring(value.password) .. '"}'
            end
            local parts = {}
            for key, val in pairs(value) do
                local encoded = val
                if type(val) == "string" then
                    encoded = '"' .. val .. '"'
                elseif val == nil then
                    encoded = "null"
                end
                table.insert(parts, '"' .. tostring(key) .. '":' .. tostring(encoded))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end,
    },
    state = {
        set = function(key, value)
            store[key] = value
            for _, cb in ipairs(watchers[key] or {}) do
                cb(value)
            end
        end,
        get = function(key)
            return store[key]
        end,
        watch = function(key, cb)
            watchers[key] = watchers[key] or {}
            table.insert(watchers[key], cb)
        end,
    },
    http = function(req, cb)
        local url = req.url
        local auth = nil
        for _, line in ipairs(req.headers or {}) do
            local value = line:match("^Authorization: (.+)$")
            if value then
                auth = value
            end
        end

        print(string.format("  [http] %s %s auth=%s", req.method or "GET", url, tostring(auth)))

        if url:find("passport/auth/login", 1, true) then
            counters.login = counters.login + 1
            if SCENARIO == "badlogin" then
                cb({ ok = true, status = 400, body = "LOGIN_FAIL" })
                return
            end
            SERVER.valid = "Bearer NEWTOKEN"
            cb({ ok = true, status = 200, body = "AUTH_DATA" })
        elseif url:find("getSubscribe", 1, true) then
            counters.subscribe = counters.subscribe + 1
            if auth == SERVER.valid then
                cb({ ok = true, status = 200, body = "SUBSCRIBE" })
            else
                cb({ ok = true, status = 403, body = "AUTH_FAIL" })
            end
        elseif url:find("user/info", 1, true) then
            counters.info = counters.info + 1
            if auth == SERVER.valid then
                cb({ ok = true, status = 200, body = "INFO" })
            else
                cb({ ok = true, status = 403, body = "AUTH_FAIL" })
            end
        else
            cb({ ok = false, status = 0, body = "" })
        end
    end,
    formatTime = function(pattern, ts)
        return os.date(pattern, ts)
    end,
    tr = function(key)
        return key -- 让 y.t 回落到代码里的中文默认值
    end,
    pluginDataDir = function()
        return DATADIR
    end,
    readFile = function(path)
        local f = io.open(path, "rb")
        if not f then
            return nil, "not found"
        end
        local text = f:read("a")
        f:close()
        return text
    end,
    writeFile = function(path, text)
        local f = io.open(path, "wb")
        if not f then
            return false, "cannot write"
        end
        f:write(text)
        f:close()
        return true
    end,
    removeFile = function(path)
        return os.remove(path) ~= nil
    end,
    fileExists = function(path)
        local f = io.open(path, "rb")
        if f then
            f:close()
            return true
        end
        return false
    end,
    notify = function(title, body)
        print("  [notify] " .. tostring(title) .. " | " .. tostring(body))
    end,
    notifyError = function(title, body)
        print("  [notifyError] " .. tostring(title) .. " | " .. tostring(body))
    end,
    copyToClipboard = function(text)
        print("  [clipboard] " .. tostring(text))
        return true
    end,
    openSettings = function()
        print("  [openSettings]")
    end,
    togglePanel = function(id)
        print("  [togglePanel] " .. tostring(id))
    end,
    setUpdateInterval = function(ms)
        INTERVAL = ms
    end,
    nowMs = function()
        return os.time() * 1000
    end,
    commandExists = function()
        return false
    end,
}

-- ── mock ui / barWidget / panel ───────────────────────────────────────────
local function node(kind)
    return function(props, children)
        return { kind = kind, props = props or {}, children = children or {} }
    end
end

ui = {
    column = node("column"),
    row = node("row"),
    scroll = node("scroll"),
    box = node("box"),
    label = node("label"),
    markdown = node("markdown"),
    glyph = node("glyph"),
    image = node("image"),
    separator = node("separator"),
    spacer = node("spacer"),
    progress = node("progress"),
    button = node("button"),
    graph = node("graph"),
    input = node("input"),
    select = node("select"),
    slider = node("slider"),
    toggle = node("toggle"),
}

barWidget = {
    render = function(tree)
        RENDERED.bar = tree
    end,
    setText = function(text)
        RENDERED.text = text
    end,
    setGlyph = function() end,
    setTooltip = function(rows)
        RENDERED.tooltip = rows
    end,
    setColor = function() end,
    setGlyphColor = function() end,
    setVisible = function() end,
}

panel = {
    render = function(tree)
        RENDERED.panel = tree
    end,
    close = function() end,
    setWantsSecondTicks = function() end,
    openContextMenu = function()
        return false
    end,
}

-- ── 跑起来 ────────────────────────────────────────────────────────────────
local function collectLabels(tree, out)
    if type(tree) ~= "table" then
        return out
    end
    local props = tree.props or {}
    if props.text then
        table.insert(out, tostring(props.text))
    end
    if tree.kind == "progress" then
        table.insert(out, string.format("<progress %.3f>", tonumber(props.progress) or -1))
    end
    for _, child in ipairs(tree.children or {}) do
        collectLabels(child, out)
    end
    return out
end

print("=== 场景：" .. SCENARIO .. " ===")

print("[1] service.onEnable()")
dofile(PLUGIN .. "service.luau")
onEnable()

print(string.format("    登录 %d 次 / getSubscribe %d 次 / info %d 次 / 刷新间隔 %d ms",
    counters.login, counters.subscribe, counters.info, INTERVAL))

local status = store["yangfan.status"]
local snap = store["yangfan.snapshot"]
print("    状态：" .. tostring(status and status.state))
if status and status.message then
    print("    状态信息：" .. tostring(status.message))
end
if snap then
    print(string.format("    快照：剩余 %.2f GB / 共 %.2f GB / 剩 %s 天 / 余额 %s / 重置 %s 天",
        (snap.remain or 0) / 1073741824,
        (snap.total or 0) / 1073741824,
        tostring(snap.days),
        tostring(snap.balance),
        tostring(snap.resetInDays)))
end

print("[2] bar.update()")
dofile(PLUGIN .. "bar.luau")
update()
print("    栏上文字：" .. table.concat(collectLabels(RENDERED.bar, {}), " | "))
for _, row in ipairs(RENDERED.tooltip or {}) do
    print(string.format("      tooltip %-10s %s", tostring(row.key), tostring(row.value)))
end

print("[3] panel.onOpen()")
dofile(PLUGIN .. "panel.luau")
onOpen(nil)
local labels = collectLabels(RENDERED.panel, {})
print("    面板内容：" .. table.concat(labels, " · "))

print("[4] 会话文件")
local f = io.open(DATADIR .. "/session.json", "rb")
if f then
    print("    " .. f:read("a"))
    f:close()
else
    print("    （无）")
end

print("=== 完成 ===")

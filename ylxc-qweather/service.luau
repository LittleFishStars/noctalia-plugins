--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- service.luau —— 后台取数服务（插件里唯一请求网络的地方）
--
-- 职责：
--   · 按 refresh_minutes 定时向和风天气取数（实况 / 逐小时 / 逐日 / 预警 / 空气质量 / 生活指数）
--   · 把结果发布到共享状态并落盘缓存
--   · 失败时指数退避，且永远保留上一次的好数据（UI 不会突然空白）
--   · 响应 UI 发来的立刻刷新请求
--
-- 所有 UI 入口都只读快照，所以无论栏上放几个组件，配额都只花一份。
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./lib/qweather.luau")
local api = require("./lib/api.luau")
local jwt = require("./lib/jwt.luau")

local busy = false
local failures = 0
local lastLogged = ""
local lastError = ""

local SETUP_HINT = {
    host = "还没填 API Host（和风控制台 → 设置 → API Host，形如 abcxyz.qweatherapi.com）",
    jwt = "选用了 JWT 认证，但私钥 / 凭据 ID / 项目 ID / 开发者 ID 没填齐",
    key = "还没填 API Key（和风控制台 → 项目管理 → KEY）",
}

local function logOnce(message)
    if message ~= lastLogged then
        lastLogged = message
        noctalia.log("[qweather] " .. message)
    end
end

--- 除凭据之外，位置参数缺失也要说清楚
local function problem(cfg)
    if not cfg.ready then
        return SETUP_HINT[cfg.setup] or ("配置不完整（" .. tostring(cfg.setup) .. "）")
    end
    if cfg.place == "city" and q.trim(cfg.city_name) == "" then
        return "位置模式选了「城市名」，但没填城市名"
    end
    if cfg.place == "cityid" and q.trim(cfg.location_id) == "" then
        return "位置模式选了「LocationID」，但没填 ID"
    end
    if cfg.place == "coords"
        and (tonumber(cfg.latitude) == nil or tonumber(cfg.longitude) == nil) then
        return "位置模式选了「经纬度」，但经纬度不是数字"
    end
    return nil
end

local function applyInterval(cfg, factor)
    local minutes = math.max(5, math.min(360, tonumber(cfg and cfg.interval) or 20))
    local ms = minutes * 60 * 1000 * (factor or 1)
    noctalia.setUpdateInterval(math.floor(ms))
end

local function summarize(errors)
    local list = {}
    for key, err in pairs(errors or {}) do
        table.insert(list, key .. ": " .. api.describe(err))
    end
    table.sort(list)
    return list
end

local function poll(reason)
    if busy then
        return
    end

    local cfg = q.config()

    local missing = problem(cfg)
    if missing then
        q.setStatus({ state = "config", at = os.time(), message = missing })
        logOnce("等待配置：" .. missing)
        applyInterval(cfg, 1)
        return
    end

    -- 语言只接受和风认识的三种
    if cfg.lang ~= "zh" and cfg.lang ~= "zh-hant" and cfg.lang ~= "en" then
        cfg.lang = "zh"
    end

    busy = true
    q.setStatus({
        state = "loading",
        at = os.time(),
        reason = reason,
        failures = failures,
    })

    api.fetch(cfg, function(snap, err)
        busy = false

        if snap then
            q.publish(snap, true)
            local problems = summarize(snap.errors)
            q.setStatus({
                state = "ok",
                at = os.time(),
                fetchedAt = snap.fetchedAt,
                partial = snap.partial,
                problems = problems,
            })

            if failures > 0 then
                noctalia.log("[qweather] 已恢复正常（此前连续失败 " .. failures .. " 次）")
            end
            failures = 0
            lastError = ""
            lastLogged = ""
            applyInterval(cfg, 1)

            local where = (snap.location and snap.location.name ~= "" and snap.location.name)
                or "当前位置"
            local line = string.format(
                "[qweather] 更新成功：%s %s %s",
                where,
                q.tempText(snap.now and snap.now.temp, snap.imperial),
                (snap.now and snap.now.text) or ""
            )
            if snap.partial then
                line = line .. "（部分接口失败：" .. table.concat(problems, "；") .. "）"
            end
            noctalia.log(line)
        else
            failures = failures + 1
            local message = api.describe(err)

            -- 认证类的错误：把缓存过的 JWT 丢掉，下次重新签
            if err and err.kind == "http" and tonumber(err.status) == 401 then
                jwt.invalidate()
            end

            -- 连续失败退避：1x / 2x / 4x（最多 4 倍间隔）
            local factor = math.min(2 ^ math.min(failures - 1, 2), 4)
            applyInterval(cfg, factor)

            q.setStatus({
                state = "error",
                at = os.time(),
                message = message,
                failures = failures,
                backoff = factor,
            })

            if message ~= lastError then
                lastError = message
                noctalia.log("[qweather] 获取失败（第 " .. failures .. " 次）：" .. message)
            end
        end
    end)
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function onEnable()
    local cfg = q.config()
    applyInterval(cfg, 1)

    q.watchCommand(function(request)
        poll(request.action or "ipc")
    end)

    noctalia.log("[qweather] 服务已启动，刷新间隔 " .. tostring(cfg.interval) .. " 分钟")
    poll("start")
end

function update()
    poll("timer")
end

function onConfigChanged()
    failures = 0
    lastLogged = ""
    lastError = ""
    jwt.invalidate()
    local cfg = q.config()
    applyInterval(cfg, 1)
    poll("config")
end

function onIpc(event, payload)
    if event == "refresh" then
        poll("ipc")
    elseif event == "status" then
        local status = q.status()
        local text = status and status.state or "idle"
        noctalia.log("[qweather] 状态：" .. tostring(text)
            .. (status and status.message and (" · " .. status.message) or ""))
    elseif event == "forget" then
        q.clearCache()
        jwt.invalidate()
        noctalia.log("[qweather] 已清除本地缓存")
        poll("forget")
    end
end

function onExit(signal, reason)
    -- 热重载时不要打断正在进行的状态，也不做持久化清理
    if reason == "reload" then
        return
    end
    noctalia.log("[qweather] 服务退出（" .. tostring(reason or signal) .. "）")
end

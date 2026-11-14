--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- service.luau —— 后台取数服务（插件里唯一请求网络的地方）
--
-- 职责：
--   · 按 refresh_minutes 定时取一次「剩余流量 / 剩余天数 / 余额」
--   · 令牌失效（403）时用设置里的邮箱密码自动重新登录，并把新令牌落盘
--   · 把快照写进插件共享状态，栏组件和面板都只读快照（放几个组件都只花一次配额）
--   · 失败指数退避，且永远保留上一次的好数据，UI 不会突然空白
--   · 跨过「流量告急 / 即将到期」阈值时发一次系统通知（每档只提醒一次）
-- ══════════════════════════════════════════════════════════════════════════

local y = require("./lib/yangfan.luau")

local busy = false
local failures = 0
local lastLogged = ""
local lastError = ""

local function logOnce(message)
    if message ~= lastLogged then
        lastLogged = message
        noctalia.log("[yangfan] " .. message)
    end
end

local function applyInterval(cfg, factor)
    local minutes = math.max(1, tonumber(cfg and cfg.interval) or 10)
    noctalia.setUpdateInterval(math.floor(minutes * 60 * 1000 * (factor or 1)))
end

--- 跨阈值提醒：每档只发一次，回到阈值以上后重新武装
local function checkNotify(cfg, snap)
    if not y.flag("notify_enabled", true) then
        return
    end

    local flags = y.loadNotified() or {}
    local changed = false

    local lowTraffic = (not snap.unlimited) and snap.remainPercent <= (cfg.warnPercent / 100)
    if lowTraffic and not flags.traffic then
        flags.traffic = true
        changed = true
        noctalia.notify(
            y.t("notify.traffic_title", "扬帆云流量告急"),
            string.format(
                y.t("notify.traffic_body", "剩余 %s（%s），到期 %s"),
                y.bytesText(snap.remain),
                y.percentText(snap.remainPercent, 0),
                y.dateText(snap.expiredAt)
            )
        )
    elseif not lowTraffic and flags.traffic then
        flags.traffic = false
        changed = true
    end

    local lowDays = snap.days ~= nil and snap.days <= cfg.warnDays
    if lowDays and not flags.days then
        flags.days = true
        changed = true
        noctalia.notify(
            y.t("notify.days_title", "扬帆云套餐即将到期"),
            string.format(
                y.t("notify.days_body", "还剩 %d 天（%s 到期），剩余 %s"),
                snap.days,
                y.dateText(snap.expiredAt),
                snap.unlimited and y.t("bar.unlimited", "不限量") or y.bytesText(snap.remain)
            )
        )
    elseif not lowDays and flags.days then
        flags.days = false
        changed = true
    end

    if changed then
        y.saveNotified(flags)
    end
end

local function poll(reason)
    if busy then
        return
    end

    local cfg = y.config()

    if not cfg.ready then
        local message = cfg.problem == "password"
            and y.t("hint.need_password", "填了邮箱，但还没填密码")
            or y.t("hint.need_account", "还没填扬帆云的邮箱和密码")
        y.setStatus({ state = "config", at = os.time(), message = message })
        logOnce("等待配置：" .. message)
        applyInterval(cfg, 1)
        return
    end

    busy = true
    local settled = false
    y.setStatus({ state = "loading", at = os.time(), reason = reason, failures = failures })

    y.ensure(cfg, function(snap, err)
        if snap then
            -- 成功时 onSnap 会被调用两次（主数据一次、余额补上再一次），
            -- 只有第一次才做状态收尾，避免日志与间隔重复刷新。
            if settled then
                y.publish(snap)
                return
            end
            settled = true
            busy = false

            y.publish(snap)
            y.setStatus({
                state = "ok",
                at = os.time(),
                fetchedAt = snap.fetchedAt,
                message = nil,
                failures = 0,
            })

            if failures > 0 then
                noctalia.log("[yangfan] 已恢复正常（此前连续失败 " .. failures .. " 次）")
            end
            failures = 0
            lastError = ""
            lastLogged = ""
            applyInterval(cfg, 1)

            local line = string.format(
                "[yangfan] %s · 剩余 %s / 共 %s · 剩 %s 天",
                snap.planName or snap.email,
                snap.unlimited and y.t("bar.unlimited", "不限量") or y.bytesText(snap.remain),
                snap.unlimited and y.t("bar.unlimited", "不限量") or y.bytesText(snap.total),
                snap.days ~= nil and tostring(snap.days) or "∞"
            )
            noctalia.log(line)

            checkNotify(cfg, snap)
            return
        end

        if settled then
            return
        end
        settled = true
        busy = false

        failures = failures + 1
        local message = y.describe(err)
        local factor = math.min(2 ^ math.min(failures - 1, 2), 4)
        applyInterval(cfg, factor)

        y.setStatus({
            state = "error",
            at = os.time(),
            message = message,
            failures = failures,
            backoff = factor,
        })

        if message ~= lastError then
            lastError = message
            noctalia.log("[yangfan] 获取失败（第 " .. failures .. " 次）：" .. message)
        end
    end)
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function onEnable()
    local cfg = y.config()
    applyInterval(cfg, 1)

    y.watchCommand(function(request)
        poll(request.action or "ipc")
    end)

    noctalia.log("[yangfan] 服务已启动，刷新间隔 " .. tostring(cfg.interval) .. " 分钟")
    poll("start")
end

function update()
    poll("timer")
end

function onConfigChanged()
    failures = 0
    lastLogged = ""
    lastError = ""
    local cfg = y.config()
    applyInterval(cfg, 1)
    poll("config")
end

function onIpc(event, payload)
    if event == "refresh" then
        poll("ipc")
    elseif event == "logout" then
        y.clearSession()
        noctalia.log("[yangfan] 已清除缓存的登录令牌，下次取数会重新登录")
        poll("logout")
    elseif event == "status" then
        local status = y.status()
        noctalia.log("[yangfan] 状态：" .. tostring(status and status.state or "idle")
            .. (status and status.message and (" · " .. status.message) or ""))
    end
end

function onExit(signal, reason)
    if reason == "reload" then
        return
    end
    noctalia.log("[yangfan] 服务退出（" .. tostring(reason or signal) .. "）")
end

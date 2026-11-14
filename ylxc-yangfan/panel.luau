--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— 详情面板：剩余流量 / 剩余天数 / 到期 / 余额
--
-- 左键点栏上的组件（清单里绑的是 panel-toggle）或
--   noctalia msg panel-toggle ylxc/yangfan:panel
-- 打开。面板只读 service 发布的快照，「刷新」按钮通过共享状态让 service 去取数。
-- ══════════════════════════════════════════════════════════════════════════

local y = require("./lib/yangfan.luau")

local opened = false
local watched = false
local snap, age = nil, nil
local status = nil

local MUTED = "on_surface/0.62"

local function row(label, value, color)
    return ui.row({ justify = "space_between", align = "center", gap = 10, width = 320 }, {
        ui.label({ text = label, color = MUTED, fontSize = 12 }),
        ui.label({ text = tostring(value), color = color or "on_surface", fontSize = 12, fontWeight = "medium" }),
    })
end

local function refreshedAt()
    if not snap or not snap.fetchedAt then
        return "--"
    end
    return y.timeText(snap.fetchedAt)
end

--- 未配置 / 拿不到数据时的引导
local function emptyTree(reason, detail)
    return ui.column({ gap = 10, padding = 4 }, {
        ui.label({ text = reason, fontSize = 14, fontWeight = "medium" }),
        ui.label({ text = detail or "", color = MUTED, fontSize = 12, maxLines = 4 }),
        ui.row({ gap = 8 }, {
            ui.button({
                text = y.t("panel.open_settings", "打开设置"),
                glyph = "settings",
                variant = "primary",
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                text = y.t("panel.retry", "重试"),
                glyph = "refresh",
                variant = "ghost",
                onClick = function()
                    y.request("refresh")
                end,
            }),
        }),
    })
end

local function bodyTree()
    local cfg = y.config()

    if not cfg.ready then
        local detail = cfg.problem == "password"
            and y.t("hint.need_password", "填了邮箱，但还没填密码")
            or y.t("hint.need_account", "还没填扬帆云的邮箱和密码")
        return emptyTree(y.t("panel.not_configured", "还没配置扬帆云账号"), detail)
    end

    if not snap then
        if status and status.state == "error" then
            return emptyTree(y.t("panel.failed", "获取失败"), status.message)
        end
        return ui.column({ gap = 8, padding = 4 }, {
            ui.label({ text = y.t("panel.loading", "正在获取剩余流量…"), color = MUTED, fontSize = 13 }),
        })
    end

    local nodes = {}

    -- 头部：套餐 + 账号
    local header = {
        ui.glyph({ name = "cloud", size = 20, color = "primary" }),
        ui.column({ gap = 2 }, {
            ui.label({
                text = snap.planName or y.t("panel.plan_unknown", "未知套餐"),
                fontSize = 14,
                fontWeight = "semibold",
            }),
            ui.label({ text = snap.email or "", color = MUTED, fontSize = 11 }),
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = y.t("panel.refresh", "刷新"),
            onClick = function()
                y.request("refresh")
            end,
        }),
    }
    table.insert(nodes, ui.row({ gap = 8, align = "center", width = 320 }, header))

    -- 剩余大数字
    local remainText = snap.unlimited and y.t("bar.unlimited", "不限量") or y.bytesText(snap.remain)
    table.insert(nodes, ui.column({ gap = 0 }, {
        ui.label({ text = y.t("panel.remain", "剩余流量"), color = MUTED, fontSize = 11 }),
        ui.label({ text = remainText, fontSize = 30, fontWeight = "semibold" }),
    }))

    -- 进度条：显示剩余比例
    if not snap.unlimited then
        table.insert(nodes, ui.column({ gap = 4 }, {
            ui.progress({ progress = snap.remainPercent, fill = "primary", height = 8, radius = 4, width = 320 }),
            ui.row({ justify = "space_between", width = 320 }, {
                ui.label({ text = y.percentText(snap.remainPercent, 1) .. " " .. y.t("panel.left", "可用"), color = MUTED, fontSize = 11 }),
                ui.label({ text = y.bytesText(snap.total), color = MUTED, fontSize = 11 }),
            }),
        }))
    end

    table.insert(nodes, ui.separator({ spacing = 2 }))

    -- 明细
    table.insert(nodes, row(
        y.t("panel.used", "已用 / 总量"),
        snap.unlimited and y.bytesText(snap.used) or (y.bytesText(snap.used) .. " / " .. y.bytesText(snap.total))
    ))
    if not snap.unlimited then
        table.insert(nodes, row(y.t("panel.used_percent", "已用比例"), y.percentText(snap.percent, 1)))
    end
    table.insert(nodes, row(
        y.t("panel.expire", "到期时间"),
        y.dateText(snap.expiredAt),
        (snap.days ~= nil and snap.days <= 3) and "error" or nil
    ))
    table.insert(nodes, row(
        y.t("panel.days_left", "剩余天数"),
        snap.days ~= nil and string.format(y.t("panel.days_value", "%d 天"), snap.days) or y.t("bar.longterm", "长期"),
        (snap.days ~= nil and snap.days <= 3) and "error" or nil
    ))
    if snap.resetInDays then
        table.insert(nodes, row(
            y.t("panel.reset", "距流量重置"),
            string.format(y.t("tooltip.reset_value", "%d 天"), snap.resetInDays)
        ))
    end
    if snap.balance then
        table.insert(nodes, row(
            y.t("panel.balance", "账户余额"),
            y.moneyText(snap.balance) .. y.t("tooltip.yuan", " 元")
        ))
    end

    table.insert(nodes, ui.separator({ spacing = 2 }))

    -- 操作
    local actions = {
        ui.button({
            text = y.t("panel.refresh", "刷新"),
            glyph = "refresh",
            variant = "secondary",
            controlSize = "sm",
            onClick = function()
                y.request("refresh")
            end,
        }),
    }
    if snap.subscribeUrl then
        table.insert(actions, ui.button({
            text = y.t("panel.copy_sub", "复制订阅"),
            glyph = "copy",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                noctalia.copyToClipboard(tostring(snap.subscribeUrl), "text/plain")
                noctalia.notify(
                    y.t("panel.copied_title", "订阅链接已复制"),
                    y.t("panel.copied_body", "可直接粘进 Clash / v2rayN")
                )
            end,
        }))
    end
    table.insert(actions, ui.button({
        text = y.t("panel.relogin", "重新登录"),
        glyph = "key",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
            y.request("logout")
            noctalia.notify(
                y.t("panel.relogin_title", "已清除登录令牌"),
                y.t("panel.relogin_body", "下次取数会用设置里的邮箱密码重新登录")
            )
        end,
    }))
    table.insert(nodes, ui.row({ gap = 8, align = "center" }, actions))

    -- 页脚
    table.insert(nodes, ui.label({
        text = string.format(y.t("panel.updated_at", "更新于 %s · 每 %d 分钟自动刷新"), refreshedAt(), y.num("refresh_minutes", 10)),
        color = MUTED,
        fontSize = 11,
    }))
    if status and status.state == "error" and status.message then
        table.insert(nodes, ui.label({
            text = string.format(y.t("panel.last_error", "上次失败：%s"), status.message),
            color = "error",
            fontSize = 11,
            maxLines = 2,
        }))
    end

    return ui.column({ gap = 10, padding = 4 }, nodes)
end

local function render()
    if not opened then
        return
    end
    panel.render(bodyTree())
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function onOpen(context)
    opened = true
    if not watched then
        watched = true
        y.watchState(function(next, nextAge)
            snap, age = next, nextAge
            render()
        end)
        y.watchStatus(function(value)
            status = value
            render()
        end)
    end
    snap, age = y.stateInfo()
    status = y.status()
    render()
end

function onClose()
    opened = false
end

function onIpc(event, payload)
    if event == "refresh" then
        y.request("refresh")
    elseif event == "reload" then
        watched = false
        onOpen(nil)
    end
end

--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— 栏上的扬帆云组件
--
-- 只负责展示：数据由 service 统一取好放进插件共享状态，栏上放几个都只花一次请求。
-- 显示内容由 [[widget.setting]] display 决定：
--   remain       剩余流量（默认，如 172.2G）
--   used         已用流量
--   percent      剩余百分比
--   days         剩余天数
--   remain_days  剩余流量 · 剩余天数
-- 左键打开详情面板（清单里绑的是 panel-toggle），右键立刻刷新。
-- ══════════════════════════════════════════════════════════════════════════

local y = require("./lib/yangfan.luau")

local watched = false
local snap, age = nil, nil
local status = nil

local function displayMode()
    local mode = y.str("display")
    if mode == "" then
        return "remain"
    end
    return mode
end

local function glyphName()
    local name = y.str("glyph")
    if name == "" then
        return "cloud"
    end
    return name
end

--- 主文本 + 该用什么颜色角色
local function mainText(s, mode)
    if s.unlimited then
        if mode == "days" then
            return s.days and string.format(y.t("bar.days", "%d天"), s.days) or y.t("bar.longterm", "长期")
        end
        return y.t("bar.unlimited", "不限量")
    end
    if mode == "used" then
        return y.bytesShort(s.used)
    end
    if mode == "percent" then
        return y.percentText(s.remainPercent, 0)
    end
    if mode == "days" then
        return s.days and string.format(y.t("bar.days", "%d天"), s.days) or y.t("bar.longterm", "长期")
    end
    if mode == "remain_days" then
        local days = s.days and string.format(y.t("bar.days", "%d天"), s.days) or y.t("bar.longterm", "长期")
        return y.bytesShort(s.remain) .. " · " .. days
    end
    return y.bytesShort(s.remain)
end

local function render()
    local nodes = {}
    local color = "on_surface"
    local text
    local reason = nil

    local cfg = y.config()
    if not cfg.ready then
        text = y.t("bar.not_configured", "未配置")
        color = "on_surface"
        reason = cfg.problemText
    elseif not snap then
        local state = status and status.state or "loading"
        if state == "error" then
            text = "!"
            color = "error"
            reason = status and status.message or nil
        elseif state == "config" then
            text = y.t("bar.not_configured", "未配置")
            reason = status and status.message or nil
        else
            text = "--"
        end
    else
        text = mainText(snap, displayMode())
        if not snap.unlimited and snap.remainPercent <= 0.1 then
            color = "error"
        elseif snap.days ~= nil and snap.days <= 3 then
            color = "error"
        end
        if y.isStale(snap, age, y.num("refresh_minutes", 10)) and color == "on_surface" then
            color = "on_surface/0.6"
        end
    end

    if y.flag("show_glyph", true) then
        table.insert(nodes, ui.glyph({ name = glyphName(), size = 16, color = color }))
    end
    table.insert(nodes, ui.label({ text = tostring(text or "--"), color = color }))

    barWidget.render(ui.row({ gap = 6, align = "center" }, nodes))

    -- 悬停详情
    local rows = {}
    if snap then
        if snap.planName then
            table.insert(rows, { key = y.t("tooltip.plan", "套餐"), value = snap.planName })
        end
        table.insert(rows, {
            key = y.t("tooltip.remain", "剩余"),
            value = snap.unlimited and y.t("bar.unlimited", "不限量") or y.bytesText(snap.remain),
        })
        table.insert(rows, {
            key = y.t("tooltip.used", "已用"),
            value = snap.unlimited
                and y.bytesText(snap.used)
                or (y.bytesText(snap.used) .. " / " .. y.bytesText(snap.total)),
        })
        if snap.total > 0 then
            table.insert(rows, {
                key = y.t("tooltip.used_percent", "已用比例"),
                value = y.percentText(snap.percent, 1),
            })
        end
        table.insert(rows, {
            key = y.t("tooltip.expire", "到期"),
            value = y.dateText(snap.expiredAt)
                .. (snap.days ~= nil and string.format(y.t("tooltip.days_left", "（剩 %d 天）"), snap.days) or ""),
        })
        if snap.resetInDays then
            table.insert(rows, {
                key = y.t("tooltip.reset", "距重置"),
                value = string.format(y.t("tooltip.reset_value", "%d 天"), snap.resetInDays),
            })
        end
        if snap.balance then
            table.insert(rows, {
                key = y.t("tooltip.balance", "余额"),
                value = y.moneyText(snap.balance) .. y.t("tooltip.yuan", " 元"),
            })
        end
        if age then
            table.insert(rows, {
                key = y.t("tooltip.data", "数据"),
                value = string.format(y.t("tooltip.updated", "%d 分钟前更新"), math.floor(age / 60)),
            })
        end
    end
    if status and status.state == "error" and status.message then
        table.insert(rows, { key = y.t("tooltip.problem", "问题"), value = status.message })
    elseif reason then
        table.insert(rows, { key = y.t("tooltip.hint", "提示"), value = reason })
    end
    barWidget.setTooltip(rows)
end

-- ── 宿主回调 ──────────────────────────────────────────────────────────────

function update()
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

    -- 每分钟重画一次，让「N 分钟前更新」与过期提示保持正确
    noctalia.setUpdateInterval(60000)

    snap, age = y.stateInfo()
    status = y.status()
    render()
end

--- 左键：清单里默认绑成了 panel-toggle；用户改成 none 时这里兜底
function onClick()
    noctalia.togglePanel(y.PANEL)
end

--- 右键：立刻刷新
function onRightClick()
    y.request("refresh")
    noctalia.log("[yangfan] 已请求刷新")
end

function onIpc(event, payload)
    if event == "refresh" then
        y.request("refresh")
    elseif event == "toggle" then
        noctalia.togglePanel(y.PANEL)
    elseif event == "reload" then
        watched = false
        update()
    end
end

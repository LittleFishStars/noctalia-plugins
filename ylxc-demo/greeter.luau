--!nonstrict
-- 栏图标入口（[[widget]]）。宿主要调用的回调都是**全局函数**，你定义了它才会被调用。
--
--   update()                 按 setUpdateInterval 的间隔被调
--   onClick() / onRightClick() / onMiddleClick() / onHover(entered) / onScroll(axis, steps, startsGesture)
--   onIpc(event, payload)    由 `noctalia msg plugin <入口> <target> <event> [payload]` 触发
--   onConfigChanged()        设置变了
--   onExit(signal, reason)   卸载/重载/退出时清理
--
-- 呈现用 barWidget.*：setText / setGlyph / setImage / setTooltip / setColor / setVisible，
-- 或者 barWidget.render(ui.row{...}) 走声明式 UI。

local label = noctalia.getConfig("label") or "你好"
local glyph = noctalia.getConfig("glyph") or "hand-stop"
local showGlyph = noctalia.getConfig("show_glyph") ~= false

local clicks = 0
local tick = noctalia.state.get("tick") or 0   -- 由本插件的 [[service]] 写入

local function render()
  if showGlyph then
    barWidget.setGlyph(glyph)
  end
  barWidget.setText(label)
  barWidget.setTooltip(`{noctalia.trp("clicks", clicks)} · tick {tick}`)
end

-- 订阅共享状态：服务那边 set 之后，这里立刻收到
noctalia.state.watch("tick", function(value)
  tick = value
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)   -- 内容变化很慢，1 秒一次足够
  render()
end

function onClick()
  clicks += 1
  noctalia.notify(noctalia.tr("title"), noctalia.trp("clicks", clicks))
  render()
end

function onIpc(event, payload)
  noctalia.log(`greeter 收到 IPC：{event} / {payload or ""}`)   -- 调试入口：直接写进 noctalia.log
  if event == "set" then
    label = payload or label
    render()
  end
end

function onConfigChanged()
  label = noctalia.getConfig("label") or label
  glyph = noctalia.getConfig("glyph") or glyph
  showGlyph = noctalia.getConfig("show_glyph") ~= false
  render()
end

--!nonstrict
-- 后台服务入口（[[service]]）：无界面，只被 update() 驱动。
-- 各入口之间**不共享 Lua 内存**，跨入口数据一律走 noctalia.state。

local count = 0

noctalia.setUpdateInterval(1000)

function update()
  count += 1
  noctalia.state.set("tick", count)
end

function onEnable()
  noctalia.log("ylxc/demo ticker 启动")
end

function onExit(signal, reason)
  noctalia.log(`ylxc/demo ticker 退出：{reason}`)
end

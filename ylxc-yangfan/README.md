# ylxc/yangfan —— 扬帆云流量

Noctalia 插件：在栏上显示**扬帆云机场**的剩余流量与剩余天数，点开有详情面板。
登录令牌失效时，用设置里保存的邮箱 + 密码**自动重新登录**，不需要你去网页上重新点一遍。

```
栏：[icon] 172.2G          ← 可切换成 已用 / 剩余百分比 / 剩余天数 / 流量+天数
面板：剩余流量大数字 + 进度条 + 已用/总量 + 到期 + 剩余天数 + 距重置 + 余额 + 订阅链接
```

## 安装

1. 把整个目录放到 `~/.local/share/noctalia/plugins/ylxc-yangfan/`
2. 启用并填设置：

```sh
noctalia msg plugins enable ylxc/yangfan
```

然后在 **设置 → 插件 → 扬帆云流量** 里填：

| 设置 | 说明 |
| --- | --- |
| 邮箱 | 面板登录邮箱 |
| 密码 | 面板登录密码，令牌失效时用来重新登录 |
| 面板地址 | **必填**：你自己的面板域名。仓库里的默认值是占位符（脱敏），不填会提示「还没填面板地址」；粘了 `/dashboard` 之类后缀会自动去掉 |
| 缓存登录令牌 | 默认开；令牌存在插件数据目录，重载后不必重新登录 |
| 刷新间隔（分钟） | 默认 10；失败自动退避到 2×、4× |
| 低量与到期提醒 | 跨阈值发一次系统通知，每档只提醒一次 |
| 剩余流量低于（%）| 默认 10 |
| 剩余天数低于（天）| 默认 3 |

3. 往栏上加组件：**设置 → 栏 → 添加组件 → 扬帆云流量**，再在组件设置里选「栏上显示」内容。

## 用法

| 操作 | 效果 |
| --- | --- |
| 左键 | 打开详情面板 |
| 右击 | 立刻刷新 |
| 中键 | 打开该组件的设置 |

IPC：

```sh
noctalia msg plugin ylxc/yangfan:main focused refresh      # 立刻刷新
noctalia msg panel-toggle ylxc/yangfan:panel               # 开/关详情面板
noctalia msg plugin ylxc/yangfan:service info refresh      # 让后台服务重取一次
noctalia msg plugin ylxc/yangfan:service info logout       # 丢掉缓存令牌，下次用密码登录
noctalia msg plugin ylxc/yangfan:service info status       # 把当前状态写进日志
```

## 走的接口

面板是 Xboard 内核，三个接口就够：

| 接口 | 用途 | 关键字段 |
| --- | --- | --- |
| `POST /api/v1/passport/auth/login` | 邮箱 + 密码换令牌 | `data.auth_data` = `"Bearer <token>"` |
| `GET /api/v1/user/getSubscribe` | 流量与到期 | `transfer_enable` / `u` / `d` / `expired_at` / `plan` / `reset_day` |
| `GET /api/v1/user/info` | 余额 | `balance` / `commission_balance`（单位：分） |

计算方式：

- 剩余额度 = `transfer_enable - (u + d)`；`transfer_enable = 0` 视为不限量
- 剩余天数 = `floor((expired_at - now) / 86400)`；`expired_at = 0` 视为长期
- 距流量重置 = `reset_day`（本面板返回的就是「还有几天」，不是 Xboard 原版的「每月几号」）

令牌失效时接口回 `HTTP 403` + `{"status":"fail","message":"未登录或登陆已过期"}`，
插件捕获这个特征后清掉旧令牌、用邮箱密码重新登录，并把新令牌写回数据目录。

## 结构

```
plugin.toml            清单：设置、栏组件、面板、后台服务
lib/yangfan.luau       配置、HTTP、登录、取数、令牌缓存、格式化
service.luau           唯一的取数者：定时拉取 → 写共享状态 → 跨阈值提醒
bar.luau               栏组件（声明式 ui.row：图标 + 文本）
panel.luau             详情面板
translations/*.json    中文 / 英文文案
```

栏组件和面板都只读 `service` 发布的共享快照，**栏上放几个组件都只花一次请求**。

## 实现备注

- 每个请求都显式带 `User-Agent`：面板前面的 nginx 会拦掉没有 UA 的请求（回 403 空页）。
- 宿主 HTTP 层不解压 gzip，所以请求带 `Accept-Encoding: identity`；万一还是拿到 gzip
  字节（首两字节 `1f 8b`），自动退回 `curl --compressed` 通道。
- `service` 的 `onSnap` 成功时会被调用两次（主数据一次、余额补上再一次），
  状态收尾与日志只在第一次做，不会重复刷间隔。
- 修改设置会触发 `onConfigChanged()`：重置失败计数与退避、丢掉缓存令牌、立刻重取。

## 已知限制

- 密码以明文形式保存在 Noctalia 的 `plugin_settings`（`~/.local/state/noctalia/settings.toml`）。
  介意的话可以只填邮箱不填密码——那样令牌过期后需要手动点「重新登录」。
- 面板若改动接口路径（换内核），需要在 `lib/yangfan.luau` 里同步。
- 只读接口；不下单、不兑换、不改密码。

## 自测

不连网、不需要账号，用 mock 的宿主环境把 service / bar / panel 跑一遍，
夹具是脱敏后的真实接口响应：

```sh
for s in auto fresh noconfig badlogin unlimited lowtraffic expiring; do
  lua5.4 tests/harness.luau "$s"
done
```

| 场景 | 验证 |
| --- | --- |
| `auto` | 缓存令牌已失效 → 403 → 用邮箱密码重登 → 出数据、令牌回写 |
| `fresh` | 无令牌 → 直接登录 |
| `noconfig` | 没填账号 → 栏显示「未配置」、面板给引导 |
| `badlogin` | 令牌失效且密码错 → 错误态与提示 |
| `unlimited` | `transfer_enable = 0` → 显示「不限量」、不画进度条 |
| `lowtraffic` | 剩余 < 10% → 发一次「流量告急」通知 |
| `expiring` | 剩余 < 3 天 → 发一次「即将到期」通知 |

## 许可

MIT

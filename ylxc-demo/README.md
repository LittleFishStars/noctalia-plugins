# ylxc/demo — noctalia 插件最小模板

一个**能跑的最小插件**，用来当写新插件时的起点：删掉不需要的入口，改 id/name 即可另起一个。
位置：`~/.local/share/noctalia/plugins/ylxc-demo/`（这个目录被识别为 `local` 源，无需注册）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `plugin.toml` | 清单：id / name / version / plugin_api + 各入口（widget、service…）与设置项声明 |
| `greeter.luau` | `[[widget]]` 栏图标入口：读设置、被点击、收 IPC、订阅共享状态 |
| `ticker.luau` | `[[service]]` 后台服务入口：每秒把计数写进插件共享状态 |
| `translations/*.json` | `zh-Hans` / `en`，`noctalia.tr` / `trp` 取用 |

## 验证与调试

```bash
noctalia plugins lint ~/.local/share/noctalia/plugins/ylxc-demo   # 离线校验清单与设置项
noctalia msg plugins list                                        # 应显示 ylxc/demo [local] enabled
noctalia msg plugins enable ylxc/demo                            # 启用（首次）
```

触发 IPC（`<目标>` 可为 `focused`、连接器名、`连接器:bar名` 或 `all`）：

```bash
noctalia msg plugin ylxc/demo:greeter focused set "新文本"
```

看日志（`noctalia.log` 里能看到入口里的 `noctalia.log()` 输出）：

```bash
tail -f ~/.cache/noctalia/noctalia.log
```

改 `.luau` 保存即热重载（日志会打 `[plugin-widget] hot reload: reloaded 'greeter.luau'`）；
改 `plugin.toml` 需要 `noctalia msg config-reload`（或设置里重载）。

## 加到状态栏

方式一（推荐）：设置 → 状态栏 → 添加组件 → 选 **Demo: greeter**，图标手势在最右侧「设置」里配。

方式二：手改 `~/.local/state/noctalia/settings.toml`

```toml
[bar.default]
center = [ "wallpaper", "demo-greeter", "clock", "control-center" ]

[widget.demo-greeter]        # 实例名随便取，唯一即可
type = "ylxc/demo:greeter"   # 插件入口 id
```

然后 `noctalia msg config-reload`。

## 参考

- 官方示例插件与 API 声明（本机副本）：`~/.local/share/noctalia/plugin-dev-ref/`
  - `example/` 覆盖全部入口类型与 `ui.*` 声明式 UI（panel、drag&drop、launcher provider 等）
  - `noctalia.d.luau` 是给编辑器用的完整 API 类型声明，会跟着上游更新
- 文档：<https://docs.noctalia.dev/>

# Noctalia 插件合集

本仓库是 [Noctalia](https://github.com/noctalia-dev/noctalia) 桌面壳的插件工作区，**一个仓库装下全部插件**（2026-11-14 由 9 个独立插件目录合并而来；原先各自的 `noctalia-*` 仓库仍在 GitHub 上保留历史）。

## 插件一览

| 目录 | 插件 | 版本 | 说明 |
| --- | --- | --- | --- |
| `ylxc-color-tools` | Color Tools | 1.1.0 | 屏幕取色器，带历史、编辑字段与内置色板 |
| `ylxc-demo` | Demo | 0.1.0 | 插件最小结构演示：栏图标 + 后台服务 + 设置 + IPC |
| `ylxc-disk` | Disk Usage | 1.1.1 | 栏内显示磁盘占用，面板给出按文件系统 / btrfs 子卷的明细 |
| `ylxc-easytier` | EasyTier | 1.0.0 | EasyTier 组网状态：对端延迟、丢包、流量、路由与连接器 |
| `ylxc-flclash` | FlClash | 1.0.0 | FlClash / mihomo 实时流量，面板可切模式、选节点、测延迟、看连接 |
| `ylxc-llm-hub` | LLM Hub | 1.2.9 | 大模型控制中心：多 provider、规则路由、本地 OpenAI/Anthropic 兼容接口 |
| `ylxc-qweather` | QWeather | 1.0.0 | 和风天气：实况、逐小时、7 天预报、预警、空气质量、生活指数 |
| `ylxc-translator` | Translator | 1.0.0 | 启动器翻译搜索源，调用大模型翻译 |
| `ylxc-yangfan` | 扬帆云流量 | 1.0.0 | 机场面板剩余流量与天数，令牌失效时自动重新登录 |

## 目录结构

每个插件目录都是可独立安装的 Noctalia 插件，遵循同一套布局：

```
<plugin>/
├── plugin.toml          # 插件清单：id、版本、入口、设置 schema
├── bar.luau             # 栏组件（可选）
├── panel.luau           # 弹出面板（可选）
├── service.luau         # 后台服务（可选）
├── lib/                 # 插件内部模块，require 用相对路径且以 .luau 结尾
├── translations/        # zh-Hans / en 等
├── docs/                # 截图等文档资源
└── README.md            # 该插件的说明
```

## 约定

- `require` 路径必须相对当前文件且以 `.luau` 结尾，否则入口 chunk 加载失败、组件静默不渲染。
- 不修改 `~/.local/share/noctalia/plugins` 之外的东西；调试产物写进各插件的 `.scratch/`、`tmp/`、`*.log`（已被忽略）。
- 根目录 `.tmp/`、`.scratch/`、`.qweather-scratch/` 与 `.config-export.toml`（含本机硬件信息）不入库。

## 开发与验证

```bash
# 单元测试（若有）
ls */tests

# 语法/加载自检
for d in ylxc-*; do luau-analyze "$d"/*.luau 2>/dev/null; done
```

插件改动后需在 Noctalia 中重新加载插件（设置 → 插件 → 重新扫描），再观察栏与面板表现。

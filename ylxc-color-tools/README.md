# Color Tools（颜色工具）

Noctalia v5 的屏幕取色插件，底层使用 [hyprpicker](https://github.com/hyprwm/hyprpicker)。

本插件从社区插件 `oldirtty/color_picker` 修改而来，改动包括：改名为 **Color Tools**、
新增自由混色调色板（HSL / RGB / HSV 三种模式滑块）、补齐简体中文（`zh-Hans`）翻译。

## 插件信息

| 字段 | 值 |
| ---- | -- |
| ID | `ylxc/color-tools` |
| 入口 | 服务：`service`；栏图标：`widget`；面板：`panel` |

## 依赖

- [hyprpicker](https://github.com/hyprwm/hyprpicker)

## 使用

无界面的 `service` 按照插件设置拼装参数并调用 `hyprpicker`。

栏图标操作：

| 操作 | 行为 |
| ---- | ---- |
| 左键 | 打开插件面板。 |
| 右键 | 直接取色（不打开面板），并把颜色复制到剪贴板。 |

面板操作：

| 操作 | 行为 |
| ---- | ---- |
| 点击较大的色块 | 打开系统取色对话框。 |
| 点击「最近使用」中的色块 | 选中该颜色。 |
| 拖动调色板滑块 / 切换调整模式 | 实时混出任意颜色并选中。 |
| HEX / RGB / HSL 输入框 | 直接编辑颜色，回车生效。 |
| 输入框右侧的复制按钮 | 复制对应格式。 |

## 调色板

面板底部是内置调色板，用于自由混色，而不是从固定色块中挑颜色：

- **调整模式**：三个按钮在 `HSL` / `RGB` / `HSV` 三种颜色模型之间切换，当前模式高亮显示；默认模式由设置项 `palette-mode` 决定。
- **三条滑块**：随模式变化的三个分量，拖动即实时混色并同步选中颜色，右侧显示当前数值（HSL/HSV 的色相为角度、饱和度与明度/明度为百分比，RGB 为 0–255 整数）。
- 调色板与历史色块、HEX / RGB / HSL 输入框双向同步：从历史或取色得到的新颜色会立即反映到滑块上。
- 切换模式只影响面板内的滑块布局（会话内生效），不改动已验证的颜色值。
- 关闭「显示调色板」后整个调色板区域隐藏。

## 设置

| 设置 | 类型 | 默认值 | 说明 |
| ---- | ---- | ------ | ---- |
| `hyprpicker-format` | `select` | `"hex"` | 复制到剪贴板的默认格式（`hex` 或 `rgb`）。 |
| `hyprpicker-lowercase` | `bool` | `false` | 以小写输出十六进制色值。 |
| `swatch-radius` | `int` | `8` | 历史色块与当前颜色预览的圆角半径。 |
| `palette-visible` | `bool` | `true` | 在面板中显示内置调色板。 |
| `palette-mode` | `select` | `"hsl"` | 调色板默认调整模式（`hsl` / `rgb` / `hsv`）。 |
| `hyprpicker-no-zoom` | `bool` | `false` | 取色时关闭放大镜。 |
| `hyprpicker-scale` | `int` | `10` | 放大镜倍率，1 到 10。 |
| `hyprpicker-radius` | `int` | `100` | 放大镜半径（像素），1 到 1000。 |
| `hyprpicker-disable-preview` | `bool` | `false` | 取色时关闭实时颜色预览。 |
| `hyprpicker-cursor` | `bool` | `false` | 在冻结的屏幕预览中包含鼠标指针。 |
| `glyph` | `glyph` | `"palette"` | 栏图标。 |

## IPC / 命令行

```bash
noctalia msg panel-toggle ylxc/color-tools:panel

# 直接取色，不打开面板
noctalia msg plugin ylxc/color-tools:service all pick
```

## 翻译

`translations/` 目录：`en.json`（英文）、`zh-Hans.json`（简体中文）、`pt-BR.json` 与 `tr.json`（原插件自带，调色板相关键已同步）。
新增语言只需照 `en.json` 的键补一个同名 JSON 文件。

## 说明

- 通过插件的后台服务调用 `hyprpicker` 时存在超时限制：如果在限定时间内没有选取颜色，取色器会提前关闭，而不是一直等待点击。

## 许可

MIT。原始插件 `oldirtty/color_picker` 的版权归其作者所有。

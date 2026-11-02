# Binary Primary → Codex

- Dark：[binary-primary-dark.codex-theme.txt](binary-primary-dark.codex-theme.txt)，含针对 Codex 派生颜色的调整。
- Light：[binary-primary-light.codex-theme.txt](binary-primary-light.codex-theme.txt)，使用 Binary 浅色核心配色。

## 导入

1. 复制对应文件的全部内容，包含 `codex-theme-v1:` 前缀。macOS 可在仓库根目录执行以下一条命令：

   ```sh
   pbcopy < docs/themes/binary-primary-dark.codex-theme.txt
   # 或导入 Light
   pbcopy < docs/themes/binary-primary-light.codex-theme.txt
   ```

2. 打开 Settings → Appearance，在 Dark theme 或 Light theme 区域点击 Import，粘贴并应用。导入前可用 Copy theme 保存旧主题。
3. 选择 Dark、Light 或 System。两份文件分别导入后，System 可随系统外观切换。

## 配色

原始色值来自 [Theme.swift](../../client/Sources/Binary/Views/Theme.swift) 的 `Palette.primary`，由 HSL 转为六位 sRGB，四舍五入到 8 位通道。

| Codex 字段 | Binary 字段 | Dark 导入值 | Light 导入值 |
| --- | --- | --- | --- |
| Background / surface | background | `#29231d`（压暗补偿） | `#f8f5f1` |
| Foreground / ink | text | `#d7c0a3` | `#593e22` |
| Accent | accent | `#775c40` | `#a58a6f` |
| Diff added | success | `#4ec68e` | `#329562` |
| Diff removed | danger | `#f35044` | `#bf3f36` |
| Skill | external | `#8a87d9` | `#744596` |
| Contrast | — | 30 | 45 |

UI 字体为 Inter，代码字体优先 Cascadia Code、其次 Cascadia Mono；未安装时回退到系统字体。窗口使用不透明背景，代码高亮使用内置 Gruvbox（支持 Light 和 Dark）。

## Dark 校准与限制

2026-11-03 的并排截图取色：旧 Codex 和 Binary 的正文背景同为 `#2e261f`，但 Codex 侧栏为 `#312921`，Binary 侧栏为 `#26211c`。偏差主要来自派生表面，不能通过直接复制背景色解决。

修订版将 Dark 基础背景从 `#2e261f` 调为 `#29231d`，contrast 从 60 降到 30，以减小侧栏和控件的提亮幅度。这是折中：正文背景也会略深，侧栏与输入框仍无法独立匹配。文字、强调色和语义色保持 Binary 原值。Light 保留原始背景色，尚无并排截图校准。

Codex 自动派生侧栏、边框、卡片、次级文字和按钮颜色；导入格式不能逐项指定 Binary 的全部颜色，也不接受任意自定义代码主题 ID。布局、控件、蓝色选中行和红色链接等细节无法完整复刻。

## 验证范围

已核对本机 `codex-theme-v1` 导入字段、颜色格式、Light/Dark 变体、Gruvbox ID 及颜色派生公式，并校验与 Binary 源码的配色映射。Dark 调整以旧版实际截图和本机派生公式为依据；修订版和 Light 仍待手动导入、视觉验收。桌面工具禁止操作 Codex 自身界面。

官方说明：[Settings → Appearance](https://learn.chatgpt.com/docs/reference/settings#appearance)。

# Binary Primary Dark → Codex

主题文件：[binary-primary-dark.codex-theme.txt](binary-primary-dark.codex-theme.txt)。

## 导入

1. 复制主题文件的全部内容（包含 `codex-theme-v1:` 前缀）。macOS 可在仓库根目录执行：

   ```sh
   pbcopy < docs/themes/binary-primary-dark.codex-theme.txt
   ```

2. 打开 Codex 的 Settings → Appearance，选择 Dark。
3. 在 Dark theme 区域点击 Import，粘贴内容并应用。导入前可用 Copy theme 保存当前主题，以便恢复。

## 配色

色值来自 [Theme.swift](../../client/Sources/Binary/Views/Theme.swift) 中 `Palette.primary` 的深色分支，由 HSL 转为六位 sRGB，四舍五入到 8 位通道。

| Codex 字段 | Binary 字段 | 色值 |
| --- | --- | --- |
| Background / surface | background | `#2e261f` |
| Foreground / ink | text | `#d7c0a3` |
| Accent | accent | `#775c40` |
| Diff added | success | `#4ec68e` |
| Diff removed | danger | `#f35044` |
| Skill | external | `#8a87d9` |

UI 字体为 Inter，代码字体优先 Cascadia Code、其次 Cascadia Mono；未安装时回退到系统字体。关闭窗口透明效果，contrast 使用 Codex 深色默认值 60。

Codex 根据基础色和 contrast 派生侧栏、边框、卡片与次级文字，导入格式不能分别指定 Binary 的全部颜色。代码高亮使用内置 `gruvbox`；当前导入器只接受内置代码主题 ID。该文件迁移核心配色与字体，不能完整复刻 SwiftUI 的布局和控件样式。

## 验证范围

2026-11-03：根据本机桌面应用的 `codex-theme-v1` 导入器核对字段、色值格式、深色变体及 `gruvbox` ID，并检查文件结构。桌面工具禁止操作 Codex 自身界面，尚未完成实际导入和视觉验收。

官方外观设置说明：[Settings → Appearance](https://learn.chatgpt.com/docs/reference/settings#appearance)。

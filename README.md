# windows-enhancedthumbnail — 实时窗口预览 + 宏自动化工具（Windows）

> 中文说明在前，English below.

一款零依赖的 Windows 工具，将两大功能合二为一：

1. **实时预览（Live Preview）** — 将任意运行中的窗口以悬浮、置顶的实时缩略图显示
   （使用 DWM 硬件加速缩略图 API，不截屏、不录制）。
2. **自动化（Automate）** — 录制键盘/鼠标宏，并对你正在预览的窗口（按 PID/HWND）
   回放，支持延迟/重复/间隔调度以及多种回放模式。

全部由 Windows 自带的 PowerShell 5.1 + Win32 API 驱动。**无需安装、无需 pip、无需驱动。**

---

## 目录结构

你只需要关注根目录下的这两个文件：

- **`Launch.bat`** — 唯一的启动入口，双击即可。
- **`README.md`** — 本说明文档。

其余所有程序文件都在 **`app\`** 子文件夹中（内部使用相对路径，请勿单独移动）。

---

## 系统要求

- Windows 7 / 8 / 10 / 11（需启用 DWM 桌面合成，现代 Windows 默认开启）
- PowerShell 5.1（Windows 自带）
- 无第三方依赖

---

## 快速开始

双击 **`Launch.bat`** 即可。它会先做环境检查，然后打开实时预览。用工具栏选择一个
窗口；点击标题栏上的 **▶ 自动化** 按钮，即可对该窗口录制/回放宏。

其他方式：
- `app\console.bat` — 启动独立的 **MacroTool 控制台**（HTA），一个不带实时预览的
  自动化界面。

---

## 实时预览 + 自动化

实时预览把任意窗口以可移动、可缩放、可置顶的悬浮缩略图显示。

| 操作 | 方式 |
|------|------|
| 选择要监控的窗口 | 放大镜按钮、右键标题栏，或 `Ctrl+W` |
| 新建实例 | `+` 按钮或 `Ctrl+N`（可同时监控多个窗口） |
| 缩放尺寸 | `1x` 按钮或 `Ctrl+S`（在 1x/2x/3x/4x 之间循环） |
| 置顶 | 图钉按钮或 `Ctrl+T` |
| **自动化此窗口** | **标题栏上的 ▶ 按钮** |
| 移动 | 拖拽标题栏 |
| 调整大小 | 拖拽边缘/角落 |
| 关闭 | X 或 `Esc` |

### 自动化面板
点击 **▶** 会在标题栏下方展开一个面板，直接以当前预览的窗口为目标（无需再选窗口）：

- **宏（Macro）** — 从下拉列表选择一个已保存的宏。
- **延迟 / 重复 / 间隔 / 速度** — 调度参数。
- **回放模式** — 前台 / 闪回 / 后台（见下文）。
- **录制** — 录制新宏（按 **F9** 停止）。录制中该按钮变为 **停止**。
- **播放** — 对预览窗口回放。播放中该按钮变为 **停止**。
- **↻** — 刷新宏列表。
- **📁** — 打开宏文件夹。
- 一个带状态点的区域会实时显示任务状态（灰=空闲 / 红=录制 / 绿=播放）。

因为你在预览里能看到目标窗口，所以可以实时观察宏的运行。

**自动停止安全机制：** 播放会在以下任一情况自动停止——点击停止、按 Esc、启动它的
界面（windows-enhancedthumbnail）退出，或超过最大运行时长上限（默认 300 秒）。

---

## 回放模式

| 模式 | 行为 | 适用范围 |
|------|------|---------|
| **前台（Foreground）** | 将目标置于最前，注入真实输入（SendInput）。 | 一切程序 —— 最可靠 |
| **闪回（Flash-restore）** | 短暂聚焦目标注入真实输入，随后把焦点还给你的窗口。 | 一切程序（游戏、Chromium、右键菜单）；有轻微闪烁 |
| **后台（Background）** | 不聚焦，直接投递消息（PostMessage）。无闪烁。 | 仅限传统 Win32 程序；游戏/DirectX/Chromium/右键菜单会忽略 |

任意时刻按 **Esc** 可中止回放。

---

## 命令行参考（`app\MacroTool.ps1`）

```powershell
# 环境检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\MacroTool.ps1 checkenv

# 列出打开的程序窗口（友好名称 + 标题 + PID）
... .\MacroTool.ps1 windows [-ProcName chrome]

# 录制（F9 停止）
... .\MacroTool.ps1 record -Name mymacro [-NoMove]

# 对某个 PID 或精确窗口句柄回放
... .\MacroTool.ps1 play -Name mymacro -TargetPid 12345 -Delay 3 -Repeat 5 [-FlashRestore | -Background]
... .\MacroTool.ps1 play -Name mymacro -TargetHwnd 0x1234 ...

# 列出已保存的宏
... .\MacroTool.ps1 list
```

---

## 工作原理

- **实时预览**：`DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` —— 与任务栏
  悬停预览相同的 GPU 合成技术，不截屏。
- **录制**：轮询输入状态（`GetAsyncKeyState` / `GetCursorPos`），捕获包括
  Ctrl/Alt/Shift 在内的所有按键。
- **回放**：`SendInput`（前台/闪回）或 `PostMessage`（后台），并做窗口相对坐标映射。
- **窗口定位**：`EnumWindows` + 友好名称解析（文件描述 → 窗口标题 → 进程名）。

---

## 可选的 Python 版本

`app\macro_tool\` 内含自动化引擎的 Python 实现（`pip install -r requirements.txt`；
需要 `pynput`、`pywin32`、`psutil`）。PowerShell 工具本身并不需要它。

---

## 非目标

- **手柄/游戏控制器模拟** —— Windows 没有内置 API 可合成虚拟手柄输入；这需要带签名的
  内核驱动（ViGEmBus/vJoy），会破坏“零依赖”的承诺，故有意排除。
- **网页/DOM 自动化** —— 需要浏览器扩展、CDP 调试端口或重型运行时
  （Playwright/Selenium），不在范围内。

<br>

============================================================

<br>

# windows-enhancedthumbnail — Live Preview + Macro Automation for Windows

A zero-dependency Windows toolkit that combines two features into one:

1. **Live Preview** — a floating, always-on-top live thumbnail of any running
   window (hardware-accelerated DWM Thumbnail API, no screen capture).
2. **Automate** — record keyboard/mouse macros and replay them against the
   window you are previewing (by PID/HWND), with delay/repeat scheduling and
   multiple playback modes.

Both are driven by built-in Windows PowerShell 5.1 + Win32 APIs. **No installs,
no pip, no drivers.**

---

## Folder layout

You only need the two files in the root:

- **`Launch.bat`** — the single entry point. Just double-click it.
- **`README.md`** — this document.

All other program files live in the **`app\`** subfolder (they use relative
paths internally — don't move them individually).

---

## Requirements

- Windows 7 / 8 / 10 / 11 (DWM desktop composition enabled — default on modern Windows)
- PowerShell 5.1 (built into Windows)
- No third-party dependencies

---

## Quick start

Double-click **`Launch.bat`** — the main entry point. It runs an environment
check, then opens Live Preview. Use the toolbar to pick a window; click the
**▶ Automate** button in the title bar to record/play macros against it.

Alternatively:
- `app\console.bat` — launch the standalone **MacroTool console** (HTA), an
  alternative UI for the automation features without the live preview.

---

## Live Preview + Automate

Live Preview shows a real-time thumbnail of any window in a movable, resizable,
pin-to-top overlay.

| Action | How |
|--------|-----|
| Select window to monitor | Magnifier button, right-click title bar, or `Ctrl+W` |
| New instance | `+` button or `Ctrl+N` (monitor multiple windows at once) |
| Scale size | `1x` button or `Ctrl+S` (cycles 1x/2x/3x/4x) |
| Pin on top | Pin button or `Ctrl+T` |
| **Automate this window** | **▶ button in the title bar** |
| Move | Drag the title bar |
| Resize | Drag edges/corners |
| Close | X or `Esc` |

### The Automate flyout
Clicking **▶** opens a panel docked under the title bar that targets the exact
window currently being previewed (no separate window picker needed):

- **Macro** — pick a saved macro (dropdown).
- **Delay / Repeat / Interval / Speed** — scheduling.
- **Playback mode** — Foreground / Flash-restore / Background (see below).
- **Record** — capture a new macro (press **F9** to stop). Turns into **Stop** while recording.
- **Play** — replay against the previewed window. Turns into **Stop** while playing.
- **↻** — refresh the macro list.
- **📁** — open the macro folder.
- A status area with a colored dot shows the live state (grey idle / red recording / green playing).

Because you are watching the target in the preview, you can see the macro run in
real time.

**Auto-stop safety:** playback stops automatically on any of — clicking Stop,
pressing Esc, the launching UI (windows-enhancedthumbnail) exiting, or exceeding the max
runtime cap (default 300s).

---

## Playback modes

| Mode | Behaviour | Works with |
|------|-----------|-----------|
| **Foreground** | Brings target to front, injects real input (SendInput). | Everything — most reliable |
| **Flash-restore** | Focuses target briefly, injects real input, then restores focus to your window. | Everything (games, Chromium, context menus); small flicker |
| **Background** | Posts messages without focusing (PostMessage). No flicker. | Classic Win32 apps only; games/DirectX/Chromium/context menus ignore it |

Press **Esc** at any time to abort playback.

---

## CLI reference (`app\MacroTool.ps1`)

```powershell
# Environment check
powershell -NoProfile -ExecutionPolicy Bypass -File .\MacroTool.ps1 checkenv

# List open program windows (friendly name + title + PID)
... .\MacroTool.ps1 windows [-ProcName chrome]

# Record (F9 to stop)
... .\MacroTool.ps1 record -Name mymacro [-NoMove]

# Play against a PID or exact window handle
... .\MacroTool.ps1 play -Name mymacro -TargetPid 12345 -Delay 3 -Repeat 5 [-FlashRestore | -Background]
... .\MacroTool.ps1 play -Name mymacro -TargetHwnd 0x1234 ...

# List saved macros
... .\MacroTool.ps1 list
```

---

## How it works

- **Live Preview**: `DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` — the
  same GPU-composited technology as taskbar hover previews. No screen capture.
- **Recording**: polls input state (`GetAsyncKeyState` / `GetCursorPos`),
  capturing every key including Ctrl/Alt/Shift.
- **Playback**: `SendInput` (foreground/flash) or `PostMessage` (background),
  with window-relative coordinate mapping.
- **Window targeting**: `EnumWindows` + friendly-name resolution
  (FileDescription → window title → process name).

---

## Optional Python version

`app\macro_tool\` contains an alternative Python implementation of the automation
engine (`pip install -r requirements.txt`; needs `pynput`, `pywin32`, `psutil`).
Not required for the PowerShell toolkit.

---

## Non-goals

- **Controller/gamepad emulation** — Windows has no built-in API to synthesize
  virtual gamepad input; it would require a signed kernel driver (ViGEmBus/vJoy),
  which breaks the zero-dependency guarantee. Intentionally excluded.
- **Webpage/DOM automation** — would require a browser extension, CDP debug port,
  or a heavy runtime (Playwright/Selenium). Out of scope.

---

## 版本历史 / Version History

### v1.1.0 (Latest)
- **修复**：回放时不再因目标窗口失焦而“盲点”——每次运行前校验目标进程/窗口存活，
  并确认目标已在前台（按 PID 匹配），否则跳过该次运行，避免误点到其它窗口（如导致
  Chrome 被意外关闭）。
- **修复**：前台激活改为“最小侵入优先”——先尝试常规激活，仅在失败时才回退到 ALT 唤起，
  避免 ALT 与宏点击叠加触发目标应用的菜单快捷键；不再对已可见窗口调用 ShowWindow，
  避免打扰其大小/位置。
- **修复**：回放 Esc 键时不再误触发自身中止；负向滚轮增量回放不再崩溃。
- **改进**：可靠地将目标窗口带到前台并在回放后保持聚焦；按键“长按”按系统重复率合成
  自动重复；录制/回放鼠标滚轮（上/下）。
- **UX**：Automate 面板打开时自动放大窗口以完整显示（含日志区），关闭时还原；关闭面板
  时重置设置子面板。
- 全程零外部依赖（纯 PowerShell + user32.dll）。

- **Fix**: Playback no longer "blind-clicks" when the target loses focus — each
  run verifies the target process/window is alive and confirms the target is
  foreground (matched by PID), otherwise it skips the run to avoid clicking the
  wrong window (which could, e.g., unintentionally close Chrome).
- **Fix**: Foreground activation is now least-intrusive first — it tries normal
  activation and only falls back to the ALT key-tap if that fails, so ALT never
  coincides with the macro's own clicks to trigger menu shortcuts; visible
  windows are no longer disturbed by ShowWindow.
- **Fix**: Replaying the Esc key no longer self-aborts; negative wheel-delta
  scroll replay no longer crashes.
- **Improved**: Reliably bring the target to the foreground and keep it focused
  after playback; synthesize key-hold auto-repeat at the system rate; record and
  replay mouse-wheel scroll (up/down).
- **UX**: The Automate panel auto-grows the window to show its full content
  (including the log area) and restores height on close; the Settings sub-panel
  resets when the panel closes.
- Zero external dependencies throughout (pure PowerShell + user32.dll).

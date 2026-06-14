# Teams Wake ☕

[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Electron](https://img.shields.io/badge/electron-v31-brightgreen.svg)](https://www.electronjs.org/)

**Teams Wake** 是一款专为 macOS 设计的轻量级、高颜值桌面实用工具。旨在防止 Microsoft Teams（及其他办公聊天软件）因系统空闲而自动变更为“离开”或“忙碌”状态。

> **🚀 核心亮点：100% 权限免除**
> 本应用利用 macOS 原生 JXA (JavaScript for Automation) 以及 Cocoa `NSWorkspace` API 进行窗口状态与焦点切换，**无需系统“辅助功能 (Accessibility)”或“自动化 (Automation)”权限**，安全合规、即开即用。

---

## ✨ 功能特性

- **100% 免系统权限**：无需复杂的 macOS 安全设置（辅助功能权限等），下载即可直接运行。
- **两种唤醒模式**：
  1. **窗口切换模式 (Window Switch)**：每隔设定时间，自动将 Microsoft Teams 切换至前台获取短暂焦点，并**瞬间将焦点复原至您当时正在工作的应用程序**，实现无感静默唤醒。
  2. **鼠标抖动模式 (Mouse Jiggle)**：系统级鼠标微小抖动（自动向右下角移动 2 像素并瞬间复原），通用且极其隐蔽。
- **自动降级保护**：在窗口切换模式下，若 Teams 进程未运行，应用将自动临时转换为“鼠标抖动”以保障唤醒状态。
- **高颜值毛玻璃 UI**：深度适配 macOS Design Guidelines，提供毛玻璃（Vibrancy）暗色背景、呼吸状态光圈以及清晰的实时控制台日志。
- **状态栏快捷控制 (Mac Menu Bar)**：
  - 点击右上角状态栏的 **☕ 咖啡杯** 图标可拉起原生功能菜单。
  - 支持在状态栏直接“一键开关服务”、“切换运行模式”以及“调节间隔时间 (1m/3m/5m/8m/10m)”。
  - 状态栏操作与主窗口双向实时同步。
- **极简托盘驻留**：点击窗口最小化或关闭时自动隐藏至托盘后台运行，不占用 Dock 栏。

---

## 📸 界面预览

- **未激活状态**：高阶灰静谧设计。
- **激活状态**：霓虹翠绿呼吸灯环光效，伴随实时 keep-alive 执行日志。
- **状态栏快捷菜单**：☕ 图标在 macOS 深浅色主题下自适应反色，菜单选项丰富，操作一步到位。

---

## 📦 快速安装 (DMG)

您可以直接下载并安装已编译好的独立 DMG 安装包：

1. **下载安装包**：前往 **[GitHub Releases 页面](https://github.com/linrol/teams-wake/releases/latest)** 下载最新的 **[Teams Wake-1.0.0.dmg](https://github.com/linrol/teams-wake/releases/download/v1.0.0/Teams.Wake-1.0.0.dmg)**（若下载缓慢，亦可直接访问 [Release v1.0.0 详情页](https://github.com/linrol/teams-wake/releases/tag/v1.0.0)）。
2. **拖拽安装**：双击打开 `.dmg` 文件，将 **Teams Wake** 拖入系统的 **Applications (应用程序)** 目录中。
3. **打开使用**：在 Launchpad 或应用程序目录中打开它，即可在系统右上角菜单栏看到 ☕ 图标开始使用。

---

## 🛠️ 本地开发与编译

如果您希望克隆仓库进行二次开发或本地运行：

### 1. 克隆仓库与安装依赖
```bash
git clone https://gitee.com/linrol/teams-wake.git
cd teams-wake
npm install
```

### 2. 本地调试运行
```bash
npm start
```

### 3. 打包生成发布版 (.app & .dmg)
```bash
npm run dist
```
打包输出的文件将位于 `./dist` 目录中。

---

## 📝 技术细节说明

### 无需权限如何实现 Teams 状态保持？

很多类似软件需要获得 macOS 的“辅助功能”权限，因为它们通过模拟键盘按键（如 `Shift`）或直接干预系统输入来工作。这在受企业 IT 管控的 Mac 上经常被禁用，且有安全合规隐患。

**Teams Wake** 采用 Cocoa API 级别的窗口焦点转换：
```javascript
// JXA Cocoa API (JavaScript for Automation)
ObjC.import('Cocoa');
var workspace = $.NSWorkspace.sharedWorkspace;
var activeApp = workspace.frontmostApplication; // 记录当前工作的 App

// 激活目标 App（例如 Microsoft Teams）
targetApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
$.NSThread.sleepForTimeInterval(0.5);

// 瞬间还原焦点至原 App
activeApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
```
这种高级别的应用焦点获取可以由普通非沙盒进程发起，**属于合法系统操作，不需要任何 Accessibility 系统权限**。

---

## ⚖️ 许可证

本项目基于 **MIT License** 开源。

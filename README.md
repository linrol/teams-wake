# Teams Wake ☕

[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Electron](https://img.shields.io/badge/electron-v31-brightgreen.svg)](https://www.electronjs.org/)

**Teams Wake** 是一款专为 macOS 设计的轻量级、高阶拟物感桌面实用工具。旨在防止 Microsoft Teams（及其他办公软件）因系统空闲而自动变更为“离开”或“忙碌”状态。

> **🚀 核心特色：智能防打扰 & 智能退避**
> 应用基于 macOS 原生 JXA (JavaScript for Automation) 以及 Cocoa API 实现，独创 **Smart Wake (智能唤醒)** 机制，仅在系统真正空闲（用户离开）时运行，支持自动唤醒、自动取消最小化，且支持无缝降级保护。

---

## ✨ 功能特性

- **智能防打扰检测 (Smart Idle Detection)**：
  - 应用会自动检测系统空闲时间。只有当您离开电脑的时间**大于或等于设定的时间间隔**时，才会触发唤醒指令。
  - 只要检测到您正在使用电脑，唤醒操作就会自动退避，绝不干扰您的正常打字与工作流程。
  - 智能修复了模拟键盘输入导致 macOS 空闲计数归零、进而引发判定抖动的技术问题。
- **统一的 Smart Wake 智能唤醒模式**：
  - **首选模式（聊天窗口切换）**：自动唤醒 Microsoft Teams（支持将最小化的 Teams 窗口恢复），并切换到“聊天 (Chats)”标签页，以慢速（间隔 2.0s）在最近的 3 个聊天窗口中进行往返切换，并在操作完成后**瞬间恢复您离开前的前台应用焦点**。
  - **降级模式（鼠标微抖动）**：若 Microsoft Teams 未运行，或应用未获得系统“辅助功能”权限，将自动无缝降级为系统级鼠标微小抖动（自动向右下角移动 2 像素并瞬间复原），确保在受限环境下依然能保持系统活跃。
- **前置启用校验与引导**：
  - 必须确保 Microsoft Teams 处于运行状态且开启了 macOS “辅助功能”权限方可启用 Smart Wake 服务。
  - UI 界面中置有直观的“辅助功能权限警告卡片”，支持一键跳转至系统的“隐私与安全性 -> 辅助功能”设置页面。
- **高颜值毛玻璃 UI**：深度适配 macOS Design Guidelines，提供毛玻璃（Vibrancy）半透明暗色背景、呼吸状态光圈以及逆序排版（最新在最前）、可滑动的实时控制台日志。
- **状态栏快捷控制 (Mac Menu Bar)**：
  - 点击右上角状态栏的 **☕ 咖啡杯** 图标可拉起原生功能菜单。
  - 支持在状态栏直接“一键开关服务”、“调节间隔时间 (1m/3m/5m/8m/10m)”。
  - 状态栏操作与主窗口双向实时同步。
- **极简托盘驻留**：点击窗口最小化或关闭时自动隐藏至托盘后台运行，不占用 Dock 栏。

---

## 📸 界面预览

- **未激活状态**：高阶灰静谧设计。
- **激活状态**：霓虹翠绿呼吸灯环光效，伴随实时 keep-alive 执行日志（最新日志置顶，支持滑动查看完整历史）。
- **状态栏快捷菜单**：☕ 图标在 macOS 深浅色主题下自适应反色，菜单选项丰富，操作一步到位。

---

## 📦 快速安装 (DMG)

您可以直接下载并安装已编译好的独立 DMG 安装包：

1. **下载安装包**：前往 **[GitHub Releases 页面](https://github.com/linrol/teams-wake/releases/latest)** 下载最新的 **[Teams Wake-1.0.4.dmg](https://github.com/linrol/teams-wake/releases/download/v1.0.4/Teams.Wake-1.0.4.dmg)**（若下载缓慢，亦可直接访问 [Release v1.0.4 详情页](https://github.com/linrol/teams-wake/releases/tag/v1.0.4)）。
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

### 系统空闲与唤醒原理

很多类似软件需要获得 macOS 的“辅助功能”权限，因为它们通过模拟键盘按键或直接干预系统输入来工作。

**Teams Wake** 采用两阶段的智能唤醒策略：

1. **系统空闲判定**：
   通过调用 macOS 的 `IOHIDSystem` 原生接口获取当前用户已空闲的时间（`HIDIdleTime`）。若空闲时间小于设定的间隔阈值（例如 1 分钟/60 秒），说明用户正在使用电脑，程序立即退避，不进行任何模拟操作。
2. **智能唤醒指令（JXA & System Events）**：
   若判定系统处于空闲状态：
   - 首先利用 `NSWorkspace` 寻找并激活 Microsoft Teams（若窗口最小化，会自动执行 de-minimize 恢复显示）。
   - 通过系统 `System Events` 发送 `Cmd+2` 切换至聊天视图，并通过 `Option+Down/Up` 进行聊天频道切换。
   - 执行完毕后，利用 `NSWorkspace` 的 `activateWithOptions` 瞬间将焦点还原至用户之前的活动应用，完成无感静默唤醒。
   - 如果用户尚未授予“辅助功能”权限，应用会自动退避并无缝降级为普通的鼠标相对坐标位移抖动（通过 CGWarpMouseCursorPosition 瞬间移动并复原，此操作无需辅助功能权限）。

---

## ⚖️ 许可证

本项目基于 **MIT License** 开源。

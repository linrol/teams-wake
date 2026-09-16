# Teams Wake 2.0 ⚡

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/language-Swift%206-orange.svg)](https://swift.org)
[![Framework](https://img.shields.io/badge/framework-AppKit%20%7C%20SwiftUI-blue.svg)](https://developer.apple.com/xcode/swiftui/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Teams Wake 2.0** 是一款专为 macOS 设计的极致轻量、纯原生状态栏效率工具。
提供 **硬件级防休眠保活** 与 **全局划词智能翻译覆写** 双核心能力。

> **🚀 架构进化：彻底告别 Electron**
> 全新 2.0 版本采用纯 **Swift + SwiftUI + AppKit** 重构，二进制体积缩减至 **820 KB**（缩减 99.5%），内存常驻仅 **~60 MB**，CPU **0%**，真正实现零负载后台静默守护。

---

## ✨ 核心特性

### 1. 硬件级保活与定时计划
- **硬件级 IOHID 时钟清零**：通过直接读取 macOS 内核 `IOHIDSystem` 的 `HIDIdleTime`，并在空闲超过阈值时注入 1 像素瞬移微移动，使办公软件（Teams、Slack、飞书等）持续保持 Active 状态；
- **定时保活计划**：支持预设工作时段（如 `09:00 - 12:00`、`13:30 - 18:00`），并支持随时新增、删除自定义保活时段。工作时间内自动保活，下班后自动静默让电脑自然休眠；
- **空闲周期无级可调**：支持在 1 ~ 10 分钟之间自由配置检测周期。

### 2. 划词自动翻译与一键覆写
- **全局快捷唤起**：在任意软件中划选文本，按下快捷键（默认 `空格键`，或 `向下键 ↓`、`触控板/鼠标右键双击`、`⌥ D` 等 11 种预设）即可毫秒级唤起翻译浮窗；
- **极速免 Key 双引擎**：搭载极速 Microsoft Edge 专线通道（~150ms 极速响应）并支持 Google Translate 自动降级容灾；
- **一键原位替换**：点击「替换」或按下 `Enter` 键，译文直接平滑覆盖原编辑框中的选中内容，无需手动复制粘贴；
- **毛玻璃自适应浮窗**：浮窗尺寸根据文本长短智能伸缩（短句小巧精致，长文自然展开并支持滚轮），支持 30% ~ 100% 透明度无级调节。

---

## 📥 下载与使用

1. 从 [GitHub Releases](https://github.com/linrol/teams-wake/releases) 下载最新的 `TeamsWake-2.0.0.dmg`；
2. 打开 DMG 并将 `TeamsWake.app` 拖拽至 `Applications`（应用程序）文件夹；
3. **⚠️ macOS 15 (Sequoia) 首次打开提示“已损坏”或“无法打开”？**  
   由于个人开源软件未购买苹果年费企业公证，macOS 15 门禁机制较严格。若提示无法打开，只需在终端（Terminal）执行一行命令清除网络下载隔离标记即可：
   ```bash
   sudo xattr -cr /Applications/TeamsWake.app
   ```
   *(或者打开「系统设置」➔「隐私与安全性」➔ 往下滑至底部点击「仍要打开」并输入密码)*

---

## 🛠️ 构建与发布工作流

项目极简设计，仅保留两个核心脚本：

### 1. 日常开发本地验证（一键安装生效）
```bash
./scripts/install.sh
```
*本地增量极速编译、签名并自动覆盖安装到 `/Applications/TeamsWake.app`，重启应用直接体验验证。*

### 2. 正式版本打包发布（Universal 2 双架构 + 自动发布）
```bash
# 发布指定版本号（若远端该版本已存在则自动覆盖，不存在则新建）
./scripts/release.sh 2.0.1

# 默认发布当前版本
./scripts/release.sh
```
*自动编译 Apple Silicon + Intel 双架构 Universal 2 二进制、打包 DMG、同步 Git Tag、自动发布或覆盖更新 GitHub Releases。*

---

## ⚖️ 许可证

本项目基于 **MIT License** 开源。

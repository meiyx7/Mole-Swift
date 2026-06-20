# Mole App

Mole 的 macOS 原生图形界面，基于 SwiftUI 构建。通过调用本机 `mo` CLI 实现系统清理、应用卸载、磁盘分析、系统状态监控等功能。

A native macOS SwiftUI frontend for the Mole CLI. Provides a clean graphical interface for system cleanup, app uninstall, disk analysis, and status monitoring by invoking the local `mo` command.

## 主要功能 / Features

| 功能 / Feature | 说明 / Description |
|---|---|
| 系统状态 / Status | 实时展示 CPU、内存、GPU、温度、磁盘、网络、电池、蓝牙等系统指标，支持每 5 秒自动刷新 |
| 磁盘分析 / Disk Explorer | 可视化磁盘占用，支持逐级进入子目录，面包屑导航可点击返回任意层级 |
| 清理 / Clean | 深度清理系统缓存、应用残留，扫描后确认执行 |
| 优化 / Optimize | 刷新系统缓存与服务，维护 Mac 性能 |
| 清理项目 / Purge Projects | 回收项目构建产物（node_modules、build 目录等） |
| 安装包 / Installer Files | 查找并清理残留的安装包文件 |
| 卸载应用 / Uninstall Apps | 移除应用程序及其残留文件，支持按大小/日期/名称排序，移至废纸篓可恢复 |
| 历史记录 / History | 查看清理活动记录 |
| 设置 / Settings | 界面语言切换、应用更新检查（自动下载）、Touch ID for sudo、CLI 更新 |

## 系统要求 / Requirements

- macOS 13.0 (Ventura) 或更高版本
- Mole CLI ≥ 1.43.1（App 会自动检测并提示）

## 安装 / Installation

1. 从 [Releases](https://github.com/meiyx7/Mole-Swift/releases) 下载 `Mole-macOS-universal.zip`
2. 解压后将 `Mole.app` 拖入 `/Applications`
3. 首次打开时 App 会自动检测本机 `mo` CLI，若未安装会提示

## 更新 / Updates

- **App 更新**：设置 → 应用更新 → 检查更新，或菜单栏 App → 检查更新…
- **CLI 更新**：设置 → CLI 更新 → 检查并更新
- App 启动时会自动后台检查新版本

## 版本记录 / Changelog

### v1.5.6

- 应用内自动更新：检查到新版本后可直接下载、解压、替换并重启，无需再打开浏览器手动下载；特权安装位置会弹出系统密码授权
- 更新进度可视化：下载进度条、解压/替换状态、取消与重试，失败有明确错误提示
- 状态页刷新间隔可配置（3/5/10/30 秒），选择持久化跨启动保留
- 状态页窗口隐藏或应用进入后台时自动暂停实时刷新，回到前台立即刷新一次再恢复循环，降低后台资源占用
- 状态页仪表盘改为响应式布局，窄窗口下双列自动堆叠为单列，避免卡片挤压

### v1.4.2

- 统一术语：清理/优化/清理项目页面的「预览」全部改为「扫描」，与安装包页面一致
- 清理页面错误状态支持重试扫描，取消操作显示「已取消」而非失败
- 命令输出超过 3000 行时自动截断旧内容，避免界面卡顿
- 流式命令支持并发安全，取消不再影响其他正在运行的任务
- 状态页刷新间隔从 3 秒调整为 5 秒，降低资源占用
- 首次启动自动检测系统语言（中文/英文），无需手动切换
- 卸载页面开启永久删除时增加二次确认，非永久模式提示可从废纸篓恢复
- 调试日志移至 `~/Library/Logs/MoleApp/debug.log`，超过 5MB 自动轮转
- 修复打开废纸篓按钮因路径展开方法错误而无效的问题
- 修复切换侧边栏标签时页面状态被销毁的问题

### v1.4.1

- 修复设置页 CLI 版本一致时仍提示"版本过低"的问题（`mo --version` 输出含 "Mole version" 前缀导致解析失败）
- 修复卸载时取消 macOS 密码窗口后仍执行卸载的问题（不再自动回答 CLI 确认提示）
- 修复磁盘分析进入 container 后明细仍停留在上级目录的问题（加载时清除旧数据，显示加载状态）

### v1.4.0

- 状态页健康评分移至标题左侧，修复圆环上方和右侧遮挡
- 状态页卡片重排：左列 CPU/内存/电池，右列 存储/网络/GPU/蓝牙，消除空白区域
- 磁盘分析修复进入 container 后无法继续深入、面包屑重复显示的问题
- 设置页移除"移除 Mole"模块（危险操作）
- 设置页检查更新发现新版本时自动打开下载页面

### v1.3.0

- 状态页健康评分圆环修复上方遮挡，卡片重排为左 CPU/内存、右 存储/网络/GPU，消除右侧空白
- 磁盘分析修复进入 container 后面包屑重复显示 "container" 的问题
- 设置页移除 Shell 补全模块（终端用户功能，GUI 不需要）
- 设置页检查更新按钮统一放到左侧

### v1.2.0

- 状态页恢复 GPU 信息显示，无管理员权限时显示提示而非隐藏
- 设置页布局重排：高频交互项（语言、更新、Touch ID、补全）上移，关于模块下移
- Touch ID 设置根据硬件支持检测，不支持的 Mac 自动隐藏
- 磁盘分析新增可点击面包屑导航，支持返回任意层级

### v1.1.0

- 新增应用图标（极简鼹鼠 + 绿色渐变 + 闪光点缀）
- 关闭窗口后自动退出应用
- 新增版本号和自动更新检查（GitHub Releases）
- 设置页显示适配 CLI 版本及兼容性警告
- 修复卸载报错：CLI 确认提示自动回答 "y"（兼容上游 CLI 版本）
- 修复应用图标未编译进 bundle 的问题
- GPU/CPU 信息无权限时智能隐藏
- 卸载页面 UI/UX 优化：搜索框、排序选择器、行内加载指示
- 修复软件按大小排序结果错误（新增 effectiveSizeKB 回退解析）

### v1.0.0

- 初始版本
- 9 大功能模块：状态、磁盘分析、清理、优化、清理项目、安装包、卸载、历史记录、设置
- 中英双语界面
- 实时系统状态监控
- NavigationSplitView 双栏布局

## 技术栈 / Tech Stack

- Swift 5.9 + SwiftUI
- XcodeGen（`project.yml` 生成 Xcode 工程）
- GitHub Actions CI/CD（tag 驱动发布）
- 适配 Mole CLI（shell + Go）

## 构建 / Build

```bash
# 安装 XcodeGen
brew install xcodegen

# 生成工程
cd MoleApp && xcodegen generate

# 构建
xcodebuild -project MoleApp.xcodeproj -scheme MoleApp -configuration Release build
```

## 许可证 / License

遵循上游 [Mole](https://github.com/tw93/Mole) 项目许可证。

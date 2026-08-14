# KeelBar

macOS 底部任务栏（纯 Swift：AppKit + SwiftUI），交互参考本地 [uBar](https://brawer.ca/ubar/) 与 Windows 任务栏。

## 功能

- **运行中应用**：自动展示当前已打开的常规 App，底部指示条标记运行 / 前台状态
- **固定到任务栏**：右键图标 →「固定到任务栏 / 取消固定」；开始菜单里也可固定
- **开始菜单**：左下角「开始」按钮，可搜索并启动 `/Applications` 等目录下的应用
- **系统托盘（右侧）**：电量、当前桌面编号、废纸篓（非空红点）、时钟（`周三 12, 22:27`）
- **菜单栏图标**：状态栏可打开开始菜单 / 显示任务栏 / 退出
- **点击行为**：点击未前台应用则激活；再次点击前台应用则隐藏（类似 uBar）
- **修饰键**：开始菜单底部可配置修饰键（便于 Windows 键盘）

## 要求

- macOS 13+
- Xcode / Swift 5.9+

## 构建与运行

```bash
./Scripts/build.sh          # debug → dist/KeelBar.app
./Scripts/build.sh release  # release
open dist/KeelBar.app
```

建议：

1. 先退出或停用本机 **uBar**（两者会抢底部栏）
2. 将系统 Dock 设为 **自动隐藏**（系统设置 → 桌面与程序坞）

## 使用说明

| 操作 | 说明 |
|------|------|
| 点击「开始」 | 打开 / 关闭开始菜单 |
| 点击任务栏图标 | 启动或切换到该应用；前台再点则隐藏 |
| 右键任务栏图标 | 固定 / 取消固定 / 退出应用 |
| 开始菜单右键 | 打开、固定到任务栏、在 Finder 中显示 |
| 菜单栏图标 | 快捷入口与退出 |
| 开始菜单「修饰键」 | 配置 ⌃⌥⌘ 等映射 |
| 电量图标 | 悬停看百分比；点击打开电池设置 |
| 桌面编号 | 显示当前 Space；点击打开调度中心 |
| 废纸篓 | 点击打开；非空显示红点；右键可清倒 |
| 时钟 | `周几 日, HH:mm`；点击打开日历 |

固定列表保存在 `UserDefaults`（`pinnedBundleIdentifiers`）。

## 项目结构

```
Sources/TaskListBar/
  main.swift / AppDelegate.swift
  TaskbarController.swift      # 底部面板 + 开始菜单 + 状态栏
  Models/
  Services/                    # 运行中应用、固定、开始菜单扫描、修饰键
  ViewModels/
  Views/
```

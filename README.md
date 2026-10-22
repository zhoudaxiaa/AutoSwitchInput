# Auto Switch Input · 自动切换输入法

[![Build](https://github.com/zhoudaxiaa/AutoSwitchInput/actions/workflows/build.yml/badge.svg)](https://github.com/zhoudaxiaa/AutoSwitchInput/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/zhoudaxiaa/AutoSwitchInput)](https://github.com/zhoudaxiaa/AutoSwitchInput/releases)
[![Platform](https://img.shields.io/badge/macOS-12%2B-blue)](https://github.com/zhoudaxiaa/AutoSwitchInput)
[![License](https://img.shields.io/github/license/zhoudaxiaa/AutoSwitchInput)](LICENSE)

一个轻量的 macOS 菜单栏小工具：**为每个应用记住一个输入法，切过去时自动切回来。**

写它的原因很简单 —— 市面上同类工具经常"用着用着就不灵了"。这个版本把重点全放在**稳定性**上：多路触发、切换后校验、看门狗兜底，并且刻意不去缓存任何 `TISInputSource` 引用。

> 简体中文 · [English](#english)

<p align="center">
  <img src="docs/window-zh.png" width="640" alt="主界面">
</p>

<p align="center">
  <img src="docs/panel-zh.png" width="320" alt="菜单栏面板">
</p>

---

## 功能

- **按应用记忆输入法** —— 每个 App 一条规则，切到该 App 时自动切换，切走时恢复
- **菜单栏常驻** —— 左键点图标弹出小面板，可直接改当前应用的规则；右键是完整菜单
- **跟随学习** —— 手动切换输入法时自动记下，下次进入该应用直接生效（可关）
- **默认输入法** —— 没配规则的应用统一用哪个输入法
- **看门狗** —— 每秒自检一次，被别的程序抢走输入法会自己纠回来
- **无效规则清理** —— 应用卸载后残留的规则可以一键清掉
- **开机自启** —— 一个开关搞定
- **中英双语** —— 跟随系统，也可以在设置里手动切成「简体中文 / English」，即时生效不用重启
- 无 Dock 图标、无常驻内存泄漏、不联网

## 安装

### 下载现成包

到 [Releases](https://github.com/zhoudaxiaa/AutoSwitchInput/releases) 下载最新的 `AutoSwitchInput-*.zip`，解压后把 `AutoSwitchInput.app` 拖进 `/Applications`。

因为是没有开发者证书的临时签名，首次打开需要：

```bash
xattr -dr com.apple.quarantine /Applications/AutoSwitchInput.app
```

或者右键点 App → 打开 → 再点一次「打开」。

### 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/zhoudaxiaa/AutoSwitchInput.git
cd AutoSwitchInput
./build.sh            # 通用二进制（arm64 + x86_64）
./build.sh --native   # 只编译本机架构，快一些
open dist/AutoSwitchInput.app
```

产物在 `dist/AutoSwitchInput.app`。

## 使用

1. 启动后菜单栏出现一个 ⇄ 图标
2. 点图标 → 「打开设置…」，或者直接左键点图标弹出小面板
3. 切到你想配置的应用，点「添加当前应用」
4. 在列表里给它选一个输入法

之后每次切到那个应用，输入法会自动跟着变。

底部第二行是几个全局设置，从左到右依次是 **语言**（跟随系统 / 简体中文 / English）、**学习手动切换**、**开机启动**。语言切换是即时生效的，窗口会原地重建一次，不需要重启 App。

### 关于辅助功能权限

**不是必须的。** 不授权也能正常用 —— 应用切换触发走的是 `NSWorkspace` 通知，不需要任何权限。

授权之后会额外获得"焦点级触发"：同一个应用内不同窗口/输入框切换时也能纠正。系统设置 → 隐私与安全性 → 辅助功能 → 勾选 AutoSwitchInput 即可。应用只会提示一次，不会反复弹窗。

## 配置文件

```
~/Library/Application Support/InputGuard/config.json
~/Library/Logs/AutoSwitchInput.log
```

> 配置目录故意保留了旧名字 `InputGuard`（早期版本用的），这样升级不会丢规则。

改配置文件也能用，格式：

```json
{
  "enabled": true,
  "learn": true,
  "learnCreatesRules": false,
  "defaultSource": null,
  "apps": {
    "com.apple.Terminal": "com.apple.keylayout.ABC",
    "com.openai.codex": "com.sogou.inputmethod.sogou.pinyin"
  },
  "excluded": ["com.apple.SecurityAgent"],
  "verifyDelays": [0.06, 0.18, 0.45],
  "watchdogInterval": 1.5,
  "language": null
}
```

`language` 可选 `null`（跟随系统）、`"zh-Hans"`、`"en"`。

写入前会自动备份一份 `config.json.bak`，读取失败时自动回退到备份。

## 为什么比同类工具稳

调研旧版（AutoSwitchInput Lite 1.5.1）时用 TIS 探针实测发现：**切换 API 本身没问题**，`TISSelectInputSource` 返回 0、不需要辅助功能权限、也不会被系统回弹。失效发生在触发和校验环节。所以这里做了几件事：

| 问题 | 这里的做法 |
| --- | --- |
| 只有一个触发源，漏掉就失灵 | `NSWorkspace` 应用激活 + AX 焦点变化 + 1.5s 定时器，三路触发 |
| 切换被目标应用抢回去 | 切换后在 60ms / 180ms / 450ms 各校验一次，不对就重试 |
| 缓存了 `TISInputSource` 引用 | **永不缓存**，每次按 ID 重新查；输入法重启后旧引用会变成死对象，静默失败 |
| 把系统自己的切换误判成用户操作 | 记录 `expectedID` 和时间窗，激活后 1 秒内的变化不算用户操作 |
| 安全键盘输入时切换导致输入丢失 | 检测 `IsSecureEventInputEnabled()`，密码框里不动 |

## 常见问题

**菜单栏看不到图标？**
如果你用 Bartender / Ice 之类的工具，新图标默认会被丢进隐藏区。到那个工具里把它设成常显。

**某个应用切过去没反应？**
先看日志 `~/Library/Logs/AutoSwitchInput.log`，里面每次切换都有记录。另外确认该应用的 bundle id 在规则列表里 —— 有些应用（比如某些 Electron 套壳）实际 bundle id 和你想的不一样。

**关掉设置窗口后点 App 没反应？**
这个已经修了。无 Dock 图标的应用需要自己接管 `kAEReopenApplication` 事件，早期版本漏了。

**会不会和我原来的输入法切换工具打架？**
会。请先退出/卸载其它同类工具，尤其别同时开两个。

## 开发

```
src/main.swift        全部逻辑（TIS 封装、配置、窗口、状态栏、popover）
src/Loc.swift         本地化辅助函数
Resources/            Info.plist、图标、en/zh-Hans 语言包
tools/make_icon.sh    重新生成 App 图标和菜单栏图标
docs/                 README 截图
build.sh              构建脚本
```

图标是代码画的，改了 `tools/make_icon.swift` 之后跑 `./tools/make_icon.sh` 就会重新生成全套尺寸。

调试用的几个开关：

```bash
AutoSwitchInput --window-snapshot out.png   # 把主窗口渲染成 PNG
AutoSwitchInput --panel-snapshot out.png    # 把菜单栏面板渲染成 PNG
AutoSwitchInput --popover-demo              # 验证 popover 能否弹出
AutoSwitchInput --silent                    # 不输出日志
```

## English

A tiny macOS menu bar utility that **remembers one input source per app and restores it when you switch back**.

Most similar tools break after a while. This one is built around stability: three independent triggers, post-switch verification with retries, a watchdog, and — importantly — it never caches `TISInputSource` references, because those silently go stale when an input method restarts.

<p align="center">
  <img src="docs/window-en.png" width="640" alt="Settings window">
</p>

### Features

- Per-app input source rules
- Menu bar panel (left click) + full menu (right click)
- Learns your manual switches
- Default input source for apps without a rule
- Watchdog corrects the input source if something steals it
- Cleanup of rules pointing at uninstalled apps
- Launch at login
- English / Simplified Chinese UI, switchable in Settings (applies instantly, no restart)

### Install

Download the latest zip from [Releases](https://github.com/zhoudaxiaa/AutoSwitchInput/releases), unzip, and move `AutoSwitchInput.app` into `/Applications`. Since it is ad-hoc signed:

```bash
xattr -dr com.apple.quarantine /Applications/AutoSwitchInput.app
```

Or right-click → Open → Open.

### Build

```bash
./build.sh            # universal (arm64 + x86_64)
./build.sh --native   # current arch only
```

### Accessibility permission

Optional. App-switching triggers work through `NSWorkspace` notifications and need no permission at all. Granting accessibility only adds focus-level triggering (correcting the input source when you move between windows inside the same app).

### Config

```
~/Library/Application Support/InputGuard/config.json
~/Library/Logs/AutoSwitchInput.log
```

## License

MIT

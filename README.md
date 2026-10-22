# Codex Quota

一个 macOS 菜单栏小工具，显示当前账号的 Codex **剩余额度**。每 5 分钟自动刷新；点击菜单栏百分比可查看额度周期、重置时间，也可立即刷新。

**[下载最新版 Mac 应用](https://github.com/cicicjy/codex-quota-menubar/releases/latest)** · 支持 macOS 13 及更新版本，Apple Silicon 和 Intel Mac。

## 安装

1. 安装并登录 Codex 或 ChatGPT 桌面版；也支持已登录的 Codex CLI。额度取自你自己电脑上的登录状态。
2. 从 Releases 下载 ZIP，解压后把 `Codex Quota.app` 拖进“应用程序”文件夹并打开。应用只出现在菜单栏，不会显示主窗口或 Dock 图标。
3. 若 macOS 首次阻止打开，确认下载来源后，到“系统设置 → 隐私与安全性”找到对应提示并选择“仍要打开”。此工具仅做本地签名，未经 Apple 公证。
4. 如需开机运行，可在“系统设置 → 通用 → 登录项”中加入该 App。

安装成功后，菜单栏会显示百分比。也可以在终端运行：

```bash
"/Applications/Codex Quota.app/Contents/MacOS/CodexQuota" --check
```

成功时会输出“Codex：剩余 XX%”；读取失败时会说明原因。具体操作见 [使用说明](使用说明.txt)。

## 数据含义

菜单栏显示的是**剩余**百分比。有 5 小时和 7 天等多个限制周期时，显示剩余百分比较小的一个。数据通过本机 Codex 的 `account/rateLimits/read` 接口读取，不估算 token。接口、安装路径或账号模式变化时，可能需要更新此工具。

工具不会随包附带任何账号、密钥或登录文件；运行时只读取本机 Codex 当前登录账号的额度。不提供独立登录界面。

## 源码

- [`Source/App.swift`](Source/App.swift) 和 [`Source/Info.plist`](Source/Info.plist)：只监控 Codex 的版本。
- [`build.command`](build.command)：在 macOS 上重新构建双架构应用；需安装 Xcode Command Line Tools。执行 `bash build.command`。
- [`Original/BalanceMenuBar.swift`](Original/BalanceMenuBar.swift)：最初截图对应的双行版本。上行 ¥ 是 DeepSeek 余额，下行百分比才是 Codex 额度。它还需要使用者自己的 DeepSeek 配置；下载的 Codex Quota.app 无需 DeepSeek。

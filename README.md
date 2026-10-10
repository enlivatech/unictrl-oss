# Unictrl

**把指针推出 Mac 的屏幕边缘，它就出现在 Windows 上，键盘也跟着过去。** 键盘和鼠标始终连在 Mac 上，Unictrl 通过局域网把输入加密转发给 Windows。两端都是原生 App：macOS 上是 SwiftUI 菜单栏 App，Windows 上是 WinUI 3 App。

**Push the pointer past the Mac's screen edge and it appears on Windows, with the keyboard following.** The keyboard and mouse stay connected to the Mac; Unictrl forwards their input to Windows over your local network, encrypted. Native on both sides: a SwiftUI menu bar app on macOS and a WinUI 3 app on Windows.

它只做这一件事：没有剪贴板共享、文件传输或拖放。
It does one thing: no clipboard sharing, file transfer or drag and drop.

- 源码 / Source: https://github.com/enlivatech/unictrl-oss
- 出品 / By: [Enliva](https://www.enliva.org)

> **先读 [ADAPTING.md](ADAPTING.md)。** Unictrl 是作者为自己的桌面写的原型：一台 Mac、一台 Windows 笔记本、罗技 MX Keys 键盘和 MX Anywhere 3S 鼠标。有些按键动作和罗技相关功能是按这套设备和作者的习惯写死的，ADAPTING.md 列出了哪些地方、在哪个文件、怎么改成通用的。
>
> **Read [ADAPTING.md](ADAPTING.md) first.** Unictrl is a prototype written for one desk: a Mac, a Windows laptop, a Logitech MX Keys keyboard and an MX Anywhere 3S mouse. Some key actions and the Logitech features are hard-wired to that hardware and the author's habits; ADAPTING.md lists each one, where it lives and how to make it general.

## 能做什么 · What it does

- 指针在 Mac 和一台或几台 Windows PC 之间来回穿越，屏幕排成一行，可以拖动排列（按物理尺寸，毫米对毫米）。
  The pointer crosses between the Mac and one or more Windows PCs arranged in a row; drag the screens to arrange them, at physical size.
- 键盘、滚轮、鼠标按键跟着指针走；媒体键、亮度键、Caps Lock 状态同步。
  Keyboard, wheel and buttons follow the pointer; media keys, brightness and the Caps Lock state carry over.
- 指针在 PC 上时用 Windows 自己的指针速度和加速度，手感和鼠标直连 Windows 一样。
  On a PC the pointer uses Windows' own speed and acceleration, as if the mouse were plugged into it.
- 6 位数字配对，配对后所有流量用 AES-256-GCM 加密；设置里能实时看到连接质量。
  Pairing with a 6-digit code; afterwards all traffic is AES-256-GCM encrypted. Settings show live connection quality.

## 系统要求 · Requirements

- macOS 15 或更新（Apple 芯片或 Intel），Xcode 命令行工具（Swift 6）。
  macOS 15 or later (Apple silicon or Intel), Xcode command line tools (Swift 6).
- Windows 10 2004 / Windows 11，x64，[.NET 10 SDK](https://dotnet.microsoft.com/download)。
  Windows 10 2004 or Windows 11, x64, the [.NET 10 SDK](https://dotnet.microsoft.com/download).
- 两台电脑在同一个可信的局域网里（TCP 24860，UDP 24861 用于发现）。
  Both computers on the same trusted LAN (TCP 24860; UDP 24861 for discovery).

## 构建 · Build

**macOS**

```sh
# 需要一个代码签名身份（Apple Development 证书即可）：security find-identity -v -p codesigning
# A code signing identity is needed (an Apple Development certificate will do).
UNICTRL_SIGNING_IDENTITY=<certificate hash> macos/build-app.sh   # installs ~/Applications/Unictrl.app
open ~/Applications/Unictrl.app
cd macos && swift test                                             # unit tests
```

macOS 的辅助功能授权绑定在 bundle ID、安装路径和签名身份上，三者保持不变，重新构建后就不用重新授权。Fork 版建议把 `macos/Info.plist` 里的 bundle ID `com.enlivatech.unictrl` 改成自己的，否则和原版装在同一台 Mac 上时会共用同一个授权和同一份设置。
macOS ties the Accessibility grant to the bundle ID, install path and signing identity; keep all three stable and rebuilds keep the grant. A fork should change the bundle ID `com.enlivatech.unictrl` in `macos/Info.plist`, or it shares the grant and the settings with the original on the same Mac.

**Windows**（在 Windows 上 · on Windows）

```powershell
dotnet publish windows\Unictrl\Unictrl.csproj -c Release -p:Platform=x64 -o out
# 把 out 复制到 %LOCALAPPDATA%\Programs\Unictrl 后运行 Unictrl.exe
# Copy out to %LOCALAPPDATA%\Programs\Unictrl and run Unictrl.exe
dotnet test windows\Unictrl.Tests
```

在 Mac 上开发、通过 SSH 在 Windows 上构建：设置 `UNICTRL_WINDOWS_HOST=user@pc`，然后用 `tools/deploy-windows.sh`（构建、安装并启动）和 `tools/test-windows.sh`（单元测试）。
To develop on the Mac and build on Windows over SSH, set `UNICTRL_WINDOWS_HOST=user@pc` and use `tools/deploy-windows.sh` (build, install, start) and `tools/test-windows.sh` (unit tests).

## 首次使用 · First run

1. Mac：在 系统设置 → 隐私与安全性 里允许 Unictrl 使用「辅助功能」和「输入监控」。
   Mac: allow Unictrl under System Settings → Privacy & Security → Accessibility and Input Monitoring.
2. Mac：点菜单栏里的 Unictrl，选 **Pair a Windows PC…**，屏幕上会显示 6 位数字。
   Mac: click Unictrl in the menu bar and choose **Pair a Windows PC…**; a 6-digit code appears.
3. Windows：打开 Unictrl，输入这 6 位数字。配对码不经过网络传输。
   Windows: open Unictrl and enter the code. The code itself never crosses the network.
4. 在 Mac 的 Unictrl 设置的 **Screens** 里，把 PC 拖到 Mac 的左边或右边，然后把指针推过那条边。
   In the **Screens** section of Unictrl's Settings on the Mac, drag the PC to the Mac's left or right, then push the pointer past that edge.

两端默认开机自启。Windows 端以管理员权限运行，这样也能在管理员窗口里打字。
Both apps start at login by default. The Windows app runs elevated so it can also type into administrator windows.

## 原理与安全 · How it works and security

- Mac 用事件监听（event tap）截获输入；指针在 PC 上时，把 Mac 光标冻住并隐藏，把移动、按键、滚轮转发过去。Windows 用 `SendInput` 注入。
  The Mac captures input with an event tap; while the pointer is on a PC it freezes and hides the Mac cursor and forwards moves, keys and wheel. Windows injects them with `SendInput`.
- 配对用 P-256 ECDH 加 6 位码的 HMAC 确认；会话密钥用 HKDF-SHA256 派生，每一帧 AES-256-GCM 加密并防重放。没有不加密的模式。
  Pairing is P-256 ECDH confirmed by an HMAC of the 6-digit code; session keys come from HKDF-SHA256 and every frame is AES-256-GCM with replay protection. There is no unencrypted mode.
- 从不记录按键内容。配对密钥保存在本机设置文件里（Mac：`~/Library/Application Support/Unictrl/settings.json`；Windows：`%LOCALAPPDATA%\Unictrl\settings.json`）。
  Keystrokes are never logged. Pairing keys live in the local settings file (paths above).
- 完整的线上协议见 [docs/PROTOCOL.md](docs/PROTOCOL.md)，按键映射见 [docs/KEYMAP.md](docs/KEYMAP.md)。安全问题请按 [SECURITY.md](SECURITY.md) 报告。
  The full wire protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md) and the key mapping in [docs/KEYMAP.md](docs/KEYMAP.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## 目录 · Layout

| 路径 · Path | 内容 · Contents |
| --- | --- |
| `macos/` | Mac 端（Swift Package）· Mac app (Swift package) |
| `windows/` | Windows 端（WinUI 3）和单元测试 · Windows app (WinUI 3) and its tests |
| `tests/contract/` | 两端共用的协议样例，两边的测试都校验 · Protocol fixtures both test suites check |
| `docs/` | 协议与按键映射 · Protocol and key mapping |
| `tools/` | 构建、调试与测试工具 · Build, debug and test tools |
| `assets/` | 图标 · Icons |

## 许可 · License

代码和图标都以 [GNU GPL v3.0](LICENSE) 授权：可以自由使用、修改和分发，分发修改版时也必须以 GPL-3.0 开放源码。Fork 可以继续使用「Unictrl」这个名字和图标。
The code and the icons are licensed under the [GNU GPL v3.0](LICENSE): use, change and share them freely; modified versions you distribute must also be GPL-3.0 with source. Forks may keep the Unictrl name and icon.

[Issues](https://github.com/enlivatech/unictrl-oss/issues) 和 pull request 都欢迎，但这是个人项目，不承诺支持。
[Issues](https://github.com/enlivatech/unictrl-oss/issues) and pull requests are welcome; this is a personal project with no promise of support.

© 2026 Enliva LLC

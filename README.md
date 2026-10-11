# Unictrl

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

**One keyboard. One mouse. Every computer.**

![The pointer moves from a Mac onto a Windows PC and the keyboard follows](media/unictrl-demo.gif)

▶ Watch the 2-minute video: [English](https://github.com/enlivatech/unictrl-oss/releases/download/v0.1.0/unictrl-promo-en.mp4) · [繁體中文字幕](https://github.com/enlivatech/unictrl-oss/releases/download/v0.1.0/unictrl-promo-zh-hant-sub.mp4) · [中文配音](https://github.com/enlivatech/unictrl-oss/releases/download/v0.1.0/unictrl-promo-zh-hans-dub.mp4)

Push your pointer past the edge of your Mac's screen and it appears on your Windows PC. Your keyboard
follows. Push it back and you are on the Mac again. No switching, no waiting.

The keyboard and mouse stay connected to the Mac; Unictrl forwards their input to the PC over your local
network, encrypted. It feels like Apple's Universal Control, for a Mac and a Windows PC. Both sides are
native apps: a SwiftUI menu bar app on macOS and a WinUI 3 app on Windows.

Unictrl does one thing: your pointer and your keyboard, across your computers. There is no clipboard
sharing, file transfer or drag and drop.

- Source: https://github.com/enlivatech/unictrl-oss
- Website: [enliva.org](https://www.enliva.org), Enliva, the maker of Unictrl
- Licence: [GPL-3.0](LICENSE), free and open source

> **Read [ADAPTING.md](ADAPTING.md) before you rely on it.** Unictrl started as a tool for one desk (a
> Mac, a Windows laptop, a Logitech MX Keys and an MX Anywhere 3S). The core works with any keyboard and
> mouse, but a few key actions and the Logitech extras are tuned to that setup. ADAPTING.md lists each one
> and how to change it.

## Features

### Moving between computers

- **Cross at the screen edge.** Push the pointer past the Mac's left or right edge to reach the PC on that
  side; push it past the PC's edge to come back. The crossing happens in a few milliseconds.
- **Screens at their real size.** In Settings › Screens, drag the PC to the Mac's left or right and up or
  down. Screens are drawn at their physical size (millimetres from each display), so the pointer crosses
  at the height you expect even when the two screens have different resolutions.
- **Windows' own pointer feel.** On the PC the pointer uses Windows' speed and acceleration, as if the
  mouse were plugged into the PC. A separate *Pointer speed on PCs* slider fine-tunes it.
- **Scrolling that matches.** Smooth scrolling and reversed wheel direction (for a mouse wheel, leaving
  trackpads alone) work on the Mac and carry over to the PC, with a separate scroll speed for PCs.
- **Only one pointer at a time.** The Mac cursor hides while you are on the PC, and the Windows cursor
  hides while you are on the Mac, so you always know which computer has the pointer.
- **Several PCs** *(experimental)*. PCs sit in a row with the Mac; the pointer can move from one PC to the
  next.

### Keyboard

- **The whole keyboard follows the pointer**, including modifiers and key repeat.
- **Two layouts for Windows.** *Windows layout* follows the Windows legends on keyboards that have them
  (Option/⊞ is Win, Cmd/Alt is Alt). *Mac layout* maps by position (Option is Alt, Command is Win).
- **Media and system keys** (volume, play/pause, next, mute) work on whichever computer has the pointer.
  Brightness keys change the PC's built-in screen.
- **Caps Lock stays in step.** The PC takes the Mac's Caps Lock state when you cross.
- **Lock the PC** with Ctrl+Cmd+Q, the same shortcut that locks the Mac.
- **Dictation keys go where you are.** Keys used to start dictation (the middle mouse button, the right
  Command key) reach the computer under the pointer instead of being caught by the Mac.

### Pairing and security

- **Pair with a 6-digit code.** On the Mac choose *Pair a Windows PC…*; type the code shown there into
  Unictrl on the PC. The code itself never crosses the network.
- **Finds the Mac by itself.** The PC discovers the Mac on the local network; there is no IP address to
  type and no inbound firewall rule to add on Windows.
- **Encrypted, always.** Keys come from an ECDH exchange (P-256) confirmed by the code; every message is
  sealed with AES-256-GCM and protected against replay. There is no unencrypted mode.
- **No account, no cloud.** Everything stays on your network. Keystrokes are never logged.

### Settings and status

- **Live connection quality.** Settings on both computers show a grade (Smooth, Some hitches, Choppy),
  the round-trip time with a live graph, where hitches come from (mouse radio, Mac, network or PC), and a
  checklist of what to try when it is not smooth.
- **Names you choose.** Rename the Mac and each PC; the names appear on every screen.
- **Starts with your computer.** Both apps start at login by default. The Mac app can live in the menu bar
  and/or the Dock; the Windows app in the notification area and/or the taskbar.

### Reliability

- **The pointer always comes home.** If the PC stops answering, the connection drops, or Unictrl quits,
  the pointer returns to the Mac.
- **No stuck keys.** The PC releases every key and button it still holds when the pointer leaves or the
  connection ends.
- **Brief network blips are absorbed.** A dropped session is resumed when it comes back quickly.

### Logitech extras (optional)

For Logitech devices with Easy-Switch, such as the MX Keys:

- **Share only on one Easy-Switch channel.** Keep one channel for Unictrl and the others for using the
  keyboard directly on a single computer; Unictrl pauses when the keyboard is on another channel.
- **Hand the devices to the PC when the Mac sleeps**, and take them back when it wakes.
- **A sound when you are ready.** Optionally play a chime when the keyboard and mouse are both back on the
  sharing channel.

## Requirements

- macOS 15 or later (Apple silicon or Intel).
- Windows 10 version 2004 or later, or Windows 11, x64.
- Both computers on the same trusted local network (TCP 24860; UDP 24861 for discovery).
- To build: Xcode command line tools (Swift 6) on the Mac; the [.NET 10 SDK](https://dotnet.microsoft.com/download)
  on Windows.

## Install

There are no signed installers yet; build both apps from source.

**macOS**

```sh
# A code signing identity is needed (an Apple Development certificate will do):
#   security find-identity -v -p codesigning
UNICTRL_SIGNING_IDENTITY=<certificate hash> macos/build-app.sh   # installs ~/Applications/Unictrl.app
open ~/Applications/Unictrl.app
```

macOS ties the Accessibility permission to the bundle ID, install path and signing identity; keep them
the same and rebuilds keep the permission. A fork should change the bundle ID `com.enlivatech.unictrl`
in `macos/Info.plist`, so it does not share permission and settings with this app.

**Windows** (on the PC)

```powershell
dotnet publish windows\Unictrl\Unictrl.csproj -c Release -p:Platform=x64 -o out
# Copy out to %LOCALAPPDATA%\Programs\Unictrl and run Unictrl.exe
```

Developing on the Mac and building on the PC over SSH: set `UNICTRL_WINDOWS_HOST=user@pc` and run
`tools/deploy-windows.sh` (build, install, start) or `tools/test-windows.sh` (unit tests).

**Tests:** `cd macos && swift test` on the Mac; `dotnet test windows\Unictrl.Tests` on Windows.

## First run

1. **Mac:** allow Unictrl under System Settings › Privacy & Security › *Accessibility* and *Input
   Monitoring*.
2. **Mac:** click Unictrl in the menu bar and choose **Pair a Windows PC…**. A 6-digit code appears.
3. **PC:** open Unictrl and type the code.
4. **Mac:** in Settings › **Screens**, drag the PC to the side of the Mac where it sits on your desk.
5. Push the pointer past that edge.

The Windows app runs with administrator rights so it can also type into administrator windows.

## How it works

The Mac watches input with an event tap. While the pointer is on the Mac, Unictrl only looks for the
pointer reaching an outer edge. When it crosses, the Mac freezes and hides its own cursor and forwards
every move, click, scroll and key to the PC, which replays them with `SendInput`. The PC tells the Mac
when the pointer reaches its far edge, and the pointer comes back.

The PC connects out to the Mac (TCP 24860), so Windows needs no inbound firewall rule. The full wire
protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md) and the key mapping in [docs/KEYMAP.md](docs/KEYMAP.md).

## FAQ

**How is this different from Universal Control?** Universal Control works between Apple devices.
Unictrl brings the same idea to a Mac and a Windows PC. On a Mac with an iPad, both can be used together.

**How is it different from Synergy, Barrier or Deskflow?** Unictrl is smaller and native on each side:
one feature, a SwiftUI app and a WinUI 3 app, always encrypted, paired with a code, with the Windows
pointer speed and physical screen sizes built in. It is independent code, not a fork of those projects.

**Why no clipboard or file transfer?** To do one thing well. Clipboard sync is a separate product.

**Can Windows be the computer with the keyboard and mouse?** Not today: the Mac is always the sender.

**Does it work over the internet?** It is designed for a local network. Wi-Fi latency shows up as pointer
hitches; a cable on either computer helps, and the connection checklist says what else to try.

**Is anything sent to a server?** No. Unictrl talks only to your own computers.

## Adapting and contributing

[ADAPTING.md](ADAPTING.md) lists what is specific to the original setup (Logitech devices, a few key
actions, the topology that has been tested, the macOS private APIs used) and how to change it. Issues and
pull requests are welcome at <https://github.com/enlivatech/unictrl-oss/issues>, and questions or ideas
in [Discussions](https://github.com/enlivatech/unictrl-oss/discussions); this is a small project with no
promise of support. Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Licence

The code and the icons are licensed under the [GNU GPL v3.0](LICENSE): use, change and share them freely;
modified versions you distribute must also be GPL-3.0 with source. Forks may keep the Unictrl name and
icon.

© 2026 Enliva LLC · [enliva.org](https://www.enliva.org)

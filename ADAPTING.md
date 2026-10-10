# Adapting Unictrl to your setup

Unictrl was written for one desk and published as it is. The core (crossing, forwarding, pairing,
encryption, arrangement) works with any mouse and keyboard, but several pieces assume the author's
hardware and habits. This page lists them so you know what to expect and where to change things.

中文摘要：Unictrl 是作者给自己的桌面写的，原样公开。穿越、转发、配对、加密、屏幕排列这些核心功能任何键鼠都能用；但下面这些地方是按作者的设备（罗技 MX Keys、MX Anywhere 3S、一台 Mac 加一台 Windows 笔记本）和习惯写死的。用之前请先看一遍，fork 时按这里的说明改。

## 1. Logitech devices

| What | Where | Notes |
| --- | --- | --- |
| HID++ is started only for an MX Keys (product 0xB35B) and an MX Anywhere 3S (0xB037, or the same mouse through a Logi Bolt receiver) | `macos/Sources/Unictrl/AppController.swift` (`hidpp.start` / `mouseHidpp.start`), `macos/Sources/Unictrl/HidPP.swift`, `windows/Unictrl/LogitechHid.cs` | Other Logitech devices get no special-key or Easy-Switch handling. To generalise, look for any Logitech HID++ 2.0 device that has features 0x1814 (change host) and 0x1B04 (reprogrammable keys). |
| Special keys F3, F4, F5 are diverted by control ID 0x00E0 / 0x00E1 / 0x006E | `macos/Sources/Unictrl/SpecialKeys.swift` (`KeyAction.controls`) | These IDs belong to the first-generation MX Keys. Other keyboards use other IDs. |
| Easy-Switch channel sharing ("share only on channel N"), sending the devices to a PC when the Mac sleeps, and the "devices ready" sound | Settings on the Mac; `SleepHandoff.swift`, `HidPP.swift` | Shown even when no Logitech device is present. They do nothing harmful without one, but the UI should hide them. |

Standard media keys (volume, play, next, mute, brightness) work with any keyboard and need no change.

## 2. Key actions chosen for the author

| Key | Mac | Windows | Where |
| --- | --- | --- | --- |
| F3 | Mission Control | Task View | `SpecialKeys.swift`, `windows/Unictrl/Injector.cs` (`case 1`) |
| F4 | Apps | Start menu | same (`case 2`) |
| F5 | Show Desktop | Show desktop | same (`case 3`) |
| Screenshot key | Ctrl+Shift+A, the author's **CleanShot X** shortcut | Ctrl+Shift+A, the author's **PixPin** shortcut | `SpecialKeys.swift` (`post(keyCode: 0, …)`), `Injector.cs` (`case 4`) |
| Brightness keys on a PC | | Step the laptop panel 6 % through WMI (built-in screens only) | `windows/Unictrl/Brightness.cs` |

Without CleanShot X or PixPin the screenshot key does nothing useful. The system defaults would be
Cmd+Shift+4 on the Mac and Win+Shift+S on Windows. A proper fix is a Keys settings page: add a key by
pressing it, then pick an action for "pointer on the Mac" and "pointer on a PC" from a small library
(Mission Control / Task View, Apps / Start, Show Desktop, Screenshot, Lock, volume, brightness) or a
recorded shortcut.

## 3. Keyboard layout on Windows

The Windows app defaults to the `mx-keys-legends` profile: keys do what the **Windows** legend on an
MX Keys says (left opt/⊞ = Win, cmd/alt = Alt, right cmd/alt = right Alt). The other profile,
`mac-positions`, maps by Mac position (Option = Alt, Command = Win). With a Mac keyboard you probably
want `mac-positions`; it is a dropdown in the Windows app ("Windows layout" / "Mac layout").
Default: `windows/Unictrl/Settings.cs` (`KeyboardProfile`). Mapping: `windows/Unictrl/KeyTable.cs`,
`docs/KEYMAP.md`.

## 4. Dictation keys (Typeless)

The author dictates with Typeless on both computers, triggered by the middle mouse button and the right
Cmd/Alt key. Unictrl therefore:

- sends right Command as **right Alt** on Windows (`KeyTable.cs`);
- keeps its event tap at the head of the chain, ahead of other apps' taps, and re-checks every 3 s
  (`InputCapture.swift`, `ensureFirstInChain`, logged as `tap_reorder`), so the middle button and
  right Cmd reach the computer under the pointer instead of being swallowed by the Mac's Typeless;
- passes keystrokes other apps synthesise on the Mac (dictation, paste tools) to the Mac instead of
  forwarding them.

These are sensible defaults for most people, but they were tuned for Typeless.

## 5. Topology that has actually been used

- **Sender is always the Mac**, receivers are Windows PCs. Windows cannot be the sender, and Mac to Mac
  is not supported (Universal Control covers that).
- Daily use: **one Mac and one Windows PC**, PC on the Mac's right. Several PCs and PC-to-PC crossing
  were tested only with a stand-in PC (`tools/fake-pc`). The PC on the Mac's left, and dragging the
  screens in the arrangement canvas, have not been hand-tested.
- One display per computer. Multiple monitors on either side are not handled specially.
- The Windows secure desktop (lock screen, UAC prompts) cannot receive input; there is no service.

## 6. macOS private APIs

To feel like Universal Control the Mac app uses a few undocumented WindowServer / Core Graphics calls,
looked up at run time with `dlsym` (`macos/Sources/Unictrl/Displays.swift`):

- `CGSSetConnectionProperty(…, "SetsCursorInBackground", true)` so a background app may hide the cursor;
- `CGSetLocalEventsSuppressionInterval(0)` to remove the 0.25 s input freeze after warping the cursor;
- `CGCursorIsVisible` to check the cursor really is hidden.

Consequences: the app cannot go on the Mac App Store, and a future macOS may break these. Also, the
window server lets the Dock keep cursor control over areas it owns (the Dock and the desktop picture),
which blocks background hiding there. Unictrl works around it by covering the Mac screen with a
1 %-opacity window of its own while the pointer is on a PC (`CursorShield.swift`).

## 7. Building, signing and distribution

- There is no installer, no Developer ID signing or notarisation for the Mac app, and no code signing
  for the Windows app. You build both yourself.
- `macos/build-app.sh` needs `UNICTRL_SIGNING_IDENTITY` (an Apple Development certificate is enough)
  and installs to `~/Applications/Unictrl.app`. Changing the bundle ID `com.enlivatech.unictrl` in
  `macos/Info.plist` keeps a fork apart from the original (its own Accessibility grant and settings).
- The Windows app registers a logon task named `Unictrl` with highest privileges (so it can type into
  administrator windows) and starts with `--background`. It is installed per user under
  `%LOCALAPPDATA%\Programs\Unictrl`.
- The SSH scripts (`tools/deploy-windows.sh`, `tools/test-windows.sh`) assume you write code on the Mac
  and build on the PC: set `UNICTRL_WINDOWS_HOST=user@pc` (and `UNICTRL_WINDOWS_KEY` if your SSH key
  is not `~/.ssh/id_ed25519`). The PC needs the .NET 10 SDK; the scripts look for it in
  `%USERPROFILE%\.dotnet` (a per-user install from dotnet-install.ps1).

## 8. Network assumptions

- A trusted home or office LAN. Discovery is UDP broadcast on port 24861; the session is TCP 24860 from
  the PC to the Mac, so Windows needs no inbound firewall rule.
- Wi-Fi latency spikes show up as pointer hitches. The author's were caused by the router's 5 GHz
  channel (moving from channel 36 to 149 fixed them); wired Ethernet on either side helps. The
  Connection section in Settings grades the link and lists what to try.

## 9. Diagnostics

Extra log lines for chasing hitches are off by default. Mac: send the distributed notification
`com.enlivatech.unictrl.debug` with object `diagnostics-on` (or `-off`). Windows: set
`"Diagnostics": true` in `%LOCALAPPDATA%\Unictrl\settings.json` and restart. `tools/pointer-report.py`
sums both logs up by source. Logs never contain keystrokes.

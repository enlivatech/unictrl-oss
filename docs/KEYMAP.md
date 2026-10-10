# Keyboard mapping

The sender forwards the physical key (USB HID usage). The Windows receiver injects the matching
set-1 **scan code**, so the Windows keyboard layout and IME produce the character, as they would for a
locally connected keyboard.

## Profile `mx-keys-legends` (default; shown as "Windows layout")

On an MX Keys that stays on its Mac channel, each key does what its **Windows legend** says:

| Key cap | Mac | Windows |
| --- | --- | --- |
| left ctrl | Control | left Ctrl |
| left opt / ⊞ | Option | **left Win** |
| left cmd / alt | Command | **left Alt** |
| right cmd / alt | right Command | **right Alt** (Typeless dictation on both OSes) |
| right opt / ctrl | right Option | **right Ctrl** |

The left and right sides differ on MX Keys, so the mapping is per physical key, never per modifier type.

Profile `mac-positions` keeps the plain HID meaning instead (Option = Alt, Command = Win).

## Media keys

macOS media keys (volume, mute, play/pause, next, previous) are sent as HID consumer usages and
injected as Windows media virtual keys. Brightness up/down (consumer 0x6F/0x70) change the PC's
built-in screen by 6 % (about 16 steps, like the Mac) through WMI (`WmiMonitorBrightnessMethods`; external monitors do not support
it). Other Mac-only keys are logged as `unmapped_media_key` and not sent.

## Dictation keys (Typeless)

Typeless runs on both computers with the middle mouse button and the right cmd/alt key as its
trigger. Its Mac event tap is an active HID tap that swallows those inputs, so Unictrl re-inserts
its own tap at the head of the HID chain whenever something else is ahead of it (checked every 3 s
while the pointer is on the Mac). While the pointer is on Windows only Windows receives them.

## MX Keys special keys (no Logi Options+)

Unictrl takes over F3, F4 and F5 through HID++ feature 0x1B04 (control IDs 0xE0, 0xE1, 0x6E) and
recognises the screenshot and lock keys by their macros (Cmd+Shift+digit and Ctrl+Cmd+Q with both
modifiers down within 3 ms). Each runs on the computer under the pointer (`action` message):

| Key | Mac | Windows |
| --- | --- | --- |
| F3 | Mission Control | Task View (Win+Tab) |
| F4 | Apps (com.apple.apps.launcher; Launchpad is gone in macOS 27) | Start menu (Windows key) |
| F5 | Show Desktop (F11) | Show desktop (Win+D) |
| screenshot | CleanShot X area capture (Ctrl+Shift+A) | PixPin Screenshot (Ctrl+Shift+A, set in PixPin) |
| lock | native Ctrl+Cmd+Q | LockWorkStation |

With F4/F5 diverted, fn+F11/fn+F12 are plain F11/F12 again. F1/F2 brightness and F6/F7 backlight
stay native. The menu key clicks the right mouse button through the keyboard's built-in pointer
interface, so it works on both computers as a forwarded click. In Mac mode the calculator key sends
nothing, even when diverted.
Diversion is volatile; Unictrl reapplies it when the keyboard reconnects (retrying for about a minute,
since a keyboard waking over Bluetooth may not answer at once), every minute, and after the Mac wakes,
and hands the keys back on quit.

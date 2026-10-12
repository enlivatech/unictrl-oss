# Unictrl wire protocol v2

TCP port 24860. The computer the keyboard and mouse are connected to (the **sender**, today the Mac)
listens; each **receiver** (a Windows PC) connects out, so Windows needs no inbound firewall rule.
`TCP_NODELAY` on both ends. The Mac holds one session per paired PC, keyed by the PC's device ID.

## Several PCs

The screens form one row, left to right (the Mac's settings keep `order` and each PC's `offsets`: its
screen centre's height below the Mac's, in mm). The pointer can leave the Mac through either outer
edge toward the PC next to it, and a PC can hand it on to the next PC. A PC leaves only through edges
the Mac marked open in `enter` (a neighbour exists and is connected); the Mac then sends `enter` to the
neighbour, converting the height by the two offsets, or brings the pointer home.

## Handshake and encryption

1. Client sends `"UNICTRL2"` + 32 random salt bytes + its device ID (16 bytes, big-endian UUID).
   Server replies `"UNICTRL1"` + 32 random salt bytes and uses that PC's pairing key. A v1 client sends
   `"UNICTRL1"` + salt with no ID and gets the key of the PC paired before IDs existed; that PC's
   first v2 session binds its ID to the old key (after its hello authenticates), so no re-pairing.
   A PC the Mac does not know (removed there) gets `"UNICTRL0"` and the connection closes; it shows
   that it must pair again and retries only every 15 s.
2. Both derive two keys with HKDF-SHA256: input key = UTF-8 pairing key, salt = client salt ‖ server salt,
   info = `unictrl v1 client->server` / `unictrl v1 server->client`, 32 bytes each.
3. Every later message is a frame: `u16 big-endian length` ‖ AES-256-GCM ciphertext ‖ 16-byte tag.
   The 12-byte nonce is 4 zero bytes ‖ `u64 big-endian` per-direction counter starting at 0, never sent.
   A replayed, dropped, reordered or forged frame fails authentication and the connection is closed.
   Frames are at most 16384 bytes (v1 receivers accept 1024 and early v2 ones 4096, so arrangement messages go only to v2 and quality reports only to PCs that sent stats).
4. The first frame each way is `hello`. A wrong pairing key fails here.

Keystrokes cross the network, so there is no unencrypted mode.

## Messages

Plaintext = `u8 type` ‖ payload, little-endian.

| Type | Name | Direction | Payload |
| --- | --- | --- | --- |
| 0x01 | hello | both | `u8 platform` (1 macOS, 2 Windows), UTF-8 device name (≤ 64 bytes) |
| 0x02 | screen | receiver → sender | `f32 widthMm, f32 heightMm` of the screen the pointer enters (after hello) |
| 0x03 | arrangement | sender → v2 receiver | JSON `{"you": id, "screens": [{"id","name","widthMm","heightMm","offsetMm","online"}]}`, left to right; the Mac is `"mac"`. Sent on connect and on every change |
| 0x04 | arrangementEdit | v2 receiver → sender | JSON `{"order": [ids], "offsets": {id: mm}}`: the user dragged screens on the PC. The Mac saves it (its copy is authoritative) and re-sends 0x03 |
| 0x05 | reclaim | sender → v2 receiver | `u8 keyboardHost, u8 mouseHost`: Easy-Switch channels (0-based, 0xFF = leave it). The Mac woke after handing its devices to this PC at sleep; the PC reports `hosts`, then sends each device there with HID++ 0x1814 |
| 0x06 | hosts | v2 receiver → sender | `u8 keyboardHost, u8 mouseHost` the devices use on this PC (0xFF = not connected here); the Mac remembers them for the next sleep |
| 0x07 | rename | v2 receiver → sender | JSON `{"id": screen id or "mac", "name": text}`: the user renamed a screen on the PC; empty = the computer's own name. The Mac saves it (names are the Mac's, like the arrangement) and re-sends 0x03, whose `name` fields carry the shown names |
| 0x10 | enter | sender → receiver | `f32 yMm`: entry height, mm from the receiver screen's vertical centre, + down; `u8 edge` (0 left, 1 right; absent = left); `u8 flags`: bit 0 resume (a replacement session takes over, or the open edges changed: keep the pointer where it is), bit 1 left edge open, bit 2 right edge open (neither = only the entry edge). The edge toward the Mac is always open, even past an offline PC, so the pointer can always get home |
| 0x11 | leave | receiver → sender | `f32 yMm`: exit height, mm from the receiver screen's vertical centre; `u8 edge` it left through (v2; absent = the entry edge) |
| 0x12 | move | sender → receiver | `f32 dxMm, f32 dyMm`, then `u32 sentUs`: the sender's monotonic clock in µs (wrapping), so the receiver can see moves that arrived late. Older receivers ignore the extra bytes |
| 0x16 | moveRaw | sender → receiver | `f32 dx, f32 dy, u32 sentUs`: unaccelerated device counts (`pointerMode` = `native`, the default) |
| 0x13 | button | sender → receiver | `u8 button` (0 left, 1 right, 2 middle, 3 back, 4 forward), `u8 down` |
| 0x14 | wheel | sender → receiver | `f32 dyLines` (+ = content up), `f32 dxLines`; receiver multiplies by 120 |
| 0x15 | key | sender → receiver | `u8 usagePage` (0x07 keyboard, 0x0C consumer), `u16 usage`, `u8 down`. Caps Lock (0x07/0x39) is a state, not a press: `down` = the Mac's lock state, also sent right after each `enter`; the receiver switches only if it differs |
| 0x20 | ping | sender → receiver | `u64` sender clock |
| 0x21 | pong | receiver → sender | the same `u64` |
| 0x22 | stats | v2 receiver → sender | JSON, about once a second while moves arrive and every 10 s with the environment: `moves`, `hitches` (moves 20 ms or more later than the lowest one-way delay of the last 30 s, counted once per spike), `jitterMaxMs`, `jitterP95Ms`, `slowInjects` (moves that took 8 ms or more to apply), `injectMaxMs`; and when known `link` (`wifi`, `ethernet`, `other`), `linkMbps`, `signalBars` (0–5), `onBattery`, `batterySaver`, `powerMode` (`efficiency`, `balanced`, `performance`). See `tests/contract/pc-stats.json` |
| 0x23 | quality | sender → receiver that sent stats | JSON once a second: `grade` (`idle`, `smooth`, `fair`, `poor`), `rttMs`, `rttP95Ms`, `movingSeconds`, `hitchesPerMin` `{mouse, mac, network, pc}` over the last minute, and `tips` (the checklist: `id`, `status` `act`/`info`/`ok`, `title`, `summary`, `steps`, `seen`), left out when unchanged since the last report. See `tests/contract/quality-report.json` |

Pointer motion has two modes (Mac setting `pointerMode`):

- `native` (default, `moveRaw`): the Mac forwards the mouse's unaccelerated counts and Windows injects
  them as relative motion, so Windows' own pointer speed and "Enhance pointer precision" apply, exactly
  as when the mouse is connected to Windows by Bluetooth. In testing the physical mode felt slower than that.
- `physical` (`move`): Mac-accelerated motion in millimetres; the receiver multiplies by its monitor's
  pixels-per-mm and places the pointer absolutely, so a hand movement covers the same physical
  distance on both screens.

Keys travel as **USB HID usages of the physical key** (left and right kept apart). The receiver maps
them to its OS; see [KEYMAP.md](KEYMAP.md).

## Discovery (UDP 24861)

The PC sends `"UNICTRL?"` to the directed broadcast address of each physical Ethernet/Wi-Fi interface
(and 255.255.255.255). Each Mac answers by unicast with `"UNICTRL!"` + JSON
`{"v":1,"id":"<device UUID>","name":"<Mac name>","port":24860}`. Windows Firewall admits unicast
replies to our own broadcast, so no rule is needed. The PC rediscovers (at most every 10 s) when the
last known address stops answering, and picks the Mac whose `id` it paired with.

## Pairing (same TCP port, magic `UNICTRP2`)

The Mac accepts pairing only while it shows a 6-digit code (two minutes, five wrong attempts void it).

1. PC → Mac: `"UNICTRP2"` ‖ PC P-256 public key (64 bytes, raw X ‖ Y) ‖ PC device ID (16). (v1: `"UNICTRP1"` and no ID.)
2. Mac → PC: `"UNICTRP1"` ‖ Mac public key (64) ‖ Mac device UUID (16, raw), or `"UNICTRP0"` when no
   code is showing.
3. PC → Mac: HMAC-SHA256(key = code, `"unictrl pair client"` ‖ PC key ‖ Mac key).
4. Mac → PC: HMAC-SHA256(key = code, `"unictrl pair server"` ‖ PC key ‖ Mac key), or 32 zero bytes.
5. Both derive the pairing key = base64(HKDF-SHA256(ECDH x-coordinate, salt = PC key ‖ Mac key,
   info = `"unictrl pairing key v1"`, 32 bytes)) and store it. The code never crosses the network; a
   passive listener learns nothing, and an active one gets one guess per attempt.

A new connection replaces the active session only after its `hello` authenticates, so stray or
pairing connections never interrupt the pointer.

## Liveness and safety

- When the session drops while the pointer is on the receiver, the sender waits 1.2 s for a replacement
  (new pairing key, app restart) and resumes it with `enter` + resume flag; otherwise it takes the pointer back.
- The sender pings every 0.5 s. With no pong for 1.5 s while the pointer is away, it takes the pointer
  back. The pointer also returns on disconnect, on event-tap timeout, and when Unictrl is disabled or quits.
- The receiver releases every key and button it still holds on `leave` or disconnect.
- Events other apps synthesise on the Mac (Typeless, Uniclip pasting) are not forwarded.

## Easy-Switch when the Mac sleeps

Before sleep (IORegisterForSystemPower holds it briefly) the Mac sends MX Keys, then MX Anywhere 3S,
to an online PC with HID++ 0x1814 ChangeHost. The PC's keyboard channel is found by matching its name
against the keyboard's HID++ 0x1815 host names (or the channel the PC last reported); the mouse has no
host names, so it uses the PC's reported mouse channel or, until then, the keyboard's. When the screens
wake (not on dark wakes) and the session is back, the Mac sends `reclaim` with its own channels.

## Four-direction screen layout extension

Both clients must be updated for vertical layouts. Pairing and encryption are unchanged.
- Arrangement screens include optional `xMm`, `yMm` (screen-centre coordinates relative to Mac centre) and `layoutVersion: 2`. Old messages retain the row fallback.
- Arrangement edits include `positions: {id: {x, y}}` alongside legacy `order` and `offsets`. The Mac validates connected shared edges before saving.
- Enter/leave edge IDs: 0 left, 1 right, 2 top, 3 bottom. The f32 is now along-edge distance from the screen centre: Y for left/right, X for top/bottom.
- Enter flag bits: 0 resume, 1 left open, 2 right open, 3 top open, 4 bottom open.
- Crossings use only the overlap shared by adjacent screens. Windows native pointer and physical pointer modes both support four directions.

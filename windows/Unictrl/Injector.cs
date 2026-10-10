using System.Runtime.InteropServices;

namespace Unictrl;

/// Replays forwarded input with SendInput. Pointer motion arrives in millimetres and is placed with
/// absolute coordinates, so Windows' own pointer acceleration does not apply a second time.
internal sealed class Injector
{
    private const uint InputMouse = 0, InputKeyboard = 1;
    private const uint MouseMove = 0x0001, MouseAbsolute = 0x8000, MouseVirtualDesk = 0x4000;
    private const uint MouseWheel = 0x0800, MouseHWheel = 0x1000;
    private const uint KeyExtended = 0x0001, KeyUp = 0x0002, KeyScanCode = 0x0008;
    // Tags our injected events so a future Windows-side capture can ignore them.
    private static readonly nint Signature = 0x554E4943;

    private static readonly (uint Down, uint Up, uint Data)[] Buttons =
    [
        (0x0002, 0x0004, 0), // left
        (0x0008, 0x0010, 0), // right
        (0x0020, 0x0040, 0), // middle
        (0x0080, 0x0100, 1), // back (XBUTTON1)
        (0x0080, 0x0100, 2), // forward (XBUTTON2)
    ];

    private readonly Settings settings;
    /// Read for each key, so a change in the window applies at once.
    private string profile => settings.KeyboardProfile;
    private readonly double widthMmOverride;
    private readonly HashSet<(ushort Scan, bool Extended)> heldKeys = [];
    private readonly HashSet<ushort> heldVirtualKeys = [];
    private readonly bool[] heldButtons = new bool[5];
    private double x, y, pixelsPerMm = 8, wheelY, wheelX, rawX, rawY;
    /// Edges that lead to another screen (the Mac or another PC); the pointer leaves through these.
    private bool openLeft, openRight = true;

    public Injector(Settings settings)
    {
        this.settings = settings;
        widthMmOverride = settings.ScreenWidthMmOverride;
    }

    public bool Active { get; private set; }

    /// Which way the pointer left: false = left edge, true = right edge.
    public readonly record struct Exit(float YMm, bool Right);

    public void Enter(float yMm, bool fromRight, bool leftOpen, bool rightOpen)
    {
        CursorHider.Show("enter");
        var monitor = Displays.Primary(widthMmOverride);
        pixelsPerMm = monitor.PixelsPerMm;
        SetOpenEdges(fromRight, leftOpen, rightOpen);
        x = fromRight ? monitor.Bounds.Right - 2 : monitor.Bounds.Left + 1;
        y = Math.Clamp(monitor.CenterY + yMm * pixelsPerMm, monitor.Bounds.Top, monitor.Bounds.Bottom - 1);
        wheelX = wheelY = rawX = rawY = 0;
        Active = true;
        MoveTo(x, y);
        Log.Write("enter", $"y_mm={yMm:F1} px_per_mm={pixelsPerMm:F3} at={(int)x},{(int)y}");
    }

    /// A new session took over while the pointer was already here: carry on from where it is.
    public void Resume(bool fromRight, bool leftOpen, bool rightOpen)
    {
        CursorHider.Show("enter");
        var monitor = Displays.Primary(widthMmOverride);
        pixelsPerMm = monitor.PixelsPerMm;
        SetOpenEdges(fromRight, leftOpen, rightOpen);
        if (Native.GetCursorPos(out var at)) { x = at.X; y = at.Y; }
        wheelX = wheelY = rawX = rawY = 0;
        Active = true;
        Log.Write("resume");
    }

    /// A Mac from before multi-device support sends no edge flags: only the entry edge leads back.
    private void SetOpenEdges(bool fromRight, bool leftOpen, bool rightOpen)
    {
        if (!leftOpen && !rightOpen) (leftOpen, rightOpen) = (!fromRight, fromRight);
        openLeft = leftOpen;
        openRight = rightOpen;
    }

    /// Returns where the pointer left when it crosses an open outer edge.
    public Exit? Move(float dxMm, float dyMm)
    {
        if (!Active) return null;
        // Follow the real cursor if something else (the touchpad, an app) moved it.
        if (Native.GetCursorPos(out var actual) &&
            (Math.Abs(actual.X - Math.Round(x)) > 2 || Math.Abs(actual.Y - Math.Round(y)) > 2))
        {
            x = actual.X;
            y = actual.Y;
        }
        var current = Displays.At((int)Math.Round(x), (int)Math.Round(y));
        x += dxMm * pixelsPerMm;
        y += dyMm * pixelsPerMm;
        var outRight = openRight && x >= current.Bounds.Right && !Displays.Exists(current.Bounds.Right, (int)Math.Round(y));
        var outLeft = openLeft && x < current.Bounds.Left && !Displays.Exists(current.Bounds.Left - 1, (int)Math.Round(y));
        if (outRight || outLeft)
        {
            var yMm = (float)((Math.Clamp(y, current.Bounds.Top, current.Bounds.Bottom - 1) - current.CenterY) / pixelsPerMm);
            Leave(outRight ? "right_edge" : "left_edge");
            return new Exit(yMm, outRight);
        }
        var target = Displays.At((int)Math.Round(x), (int)Math.Round(y));
        x = Math.Clamp(x, target.Bounds.Left, target.Bounds.Right - 1);
        y = Math.Clamp(y, target.Bounds.Top, target.Bounds.Bottom - 1);
        MoveTo(x, y);
        return null;
    }

    /// Raw device counts injected as relative motion, so Windows applies its own pointer speed and
    /// "Enhance pointer precision" exactly as for a mouse connected to it. Returns where the pointer
    /// left when it is pushed past an open outer edge.
    public Exit? MoveRaw(float dx, float dy)
    {
        if (!Active) return null;
        rawX += dx;
        rawY += dy;
        var ix = (int)rawX;
        var iy = (int)rawY;
        rawX -= ix;
        rawY -= iy;
        if (Native.GetCursorPos(out var at))
        {
            var monitor = Displays.At(at.X, at.Y);
            var outRight = openRight && ix > 0 && at.X >= monitor.Bounds.Right - 1 && !Displays.Exists(monitor.Bounds.Right, at.Y);
            var outLeft = openLeft && ix < 0 && at.X <= monitor.Bounds.Left && !Displays.Exists(monitor.Bounds.Left - 1, at.Y);
            if (outRight || outLeft)
            {
                var yMm = (float)((at.Y - monitor.CenterY) / monitor.PixelsPerMm);
                Leave(outRight ? "right_edge" : "left_edge");
                return new Exit(yMm, outRight);
            }
        }
        if (ix != 0 || iy != 0)
        {
            SendMouse(ix, iy, 0, MouseMove);
            MouseProbe.RecordInjected(ix, iy);
        }
        return null;
    }

    public void Button(byte button, bool down)
    {
        if (!Active || button >= Buttons.Length || heldButtons[button] == down) return;
        heldButtons[button] = down;
        var (downFlag, upFlag, data) = Buttons[button];
        SendMouse(0, 0, data, down ? downFlag : upFlag);
    }

    public void Wheel(float dyLines, float dxLines)
    {
        if (!Active) return;
        wheelY += dyLines * 120;
        wheelX += dxLines * 120;
        var vertical = (int)wheelY;
        var horizontal = (int)wheelX;
        wheelY -= vertical;
        wheelX -= horizontal;
        if (vertical != 0)
        {
            SendMouse(0, 0, (uint)vertical, MouseWheel);
            MouseProbe.RecordWheel(vertical);
        }
        if (horizontal != 0) SendMouse(0, 0, (uint)(-horizontal), MouseHWheel);
    }

    public void Key(byte page, ushort usage, bool down)
    {
        if (!Active) return;
        if (page == 0x07 && usage == 0x39)
        {
            SetCapsLock(down);
            return;
        }
        if (page == 0x07 && KeyTable.TryGetScanCode(usage, profile, out var scan, out var extended))
        {
            // A release for a key Windows never saw pressed (or that an action already let go) is dropped.
            if (down) heldKeys.Add((scan, extended));
            else if (!heldKeys.Remove((scan, extended))) return;
            SendScan(scan, extended, down);
        }
        else if (page == 0x0C && usage is 0x6F or 0x70)
        {
            if (down) Brightness.Step(usage == 0x6F ? +6 : -6); // about 16 steps, like the Mac
        }
        else if (page == 0x0C && KeyTable.Consumer.TryGetValue(usage, out var virtualKey))
        {
            if (down) heldVirtualKeys.Add(virtualKey); else heldVirtualKeys.Remove(virtualKey);
            SendVirtualKey(virtualKey, down);
            if (down) Log.Write("media", $"usage=0x{usage:X2} vk=0x{virtualKey:X2}");
        }
    }

    /// Caps Lock arrives as the Mac's state, not as a press: the keyboard's light follows the Mac, so
    /// Windows is switched only when it differs, and the two never end up opposite.
    private static void SetCapsLock(bool on)
    {
        const ushort capsScan = 0x3A;
        var current = Native.CapsLockOn();
        Log.Write("caps_lock", $"mac={(on ? "on" : "off")} pc={(current ? "on" : "off")}");
        if (current == on) return;
        SendScan(capsScan, false, true);
        SendScan(capsScan, false, false);
    }

    /// Special-key functions (docs/KEYMAP.md). Modifiers the keyboard's own macro is still holding
    /// are let go first so they do not combine with the shortcut.
    public void Action(byte action)
    {
        if (!Active) return;
        ReleaseModifiers();
        const ushort win = 0x5B, tab = 0x0F, d = 0x20, a = 0x1E, shift = 0x2A, ctrl = 0x1D;
        switch (action)
        {
            case 1: Chord((win, true), (tab, false)); break;                 // Task View
            case 2: Chord((win, true)); break;                               // Start menu (Windows key alone)
            case 3: Chord((win, true), (d, false)); break;                   // Show desktop
            case 4: Chord((ctrl, false), (shift, false), (a, false)); break; // PixPin: Screenshot (Ctrl+Shift+A)
            case 5: Native.LockWorkStation(); break;                         // Win+L cannot be injected
            default: return;
        }
        Log.Write("action", $"id={action}");
    }

    private static void Chord(params (ushort Scan, bool Extended)[] keys)
    {
        foreach (var (scan, extended) in keys) SendScan(scan, extended, true);
        foreach (var (scan, extended) in keys.Reverse()) SendScan(scan, extended, false);
    }

    private void ReleaseModifiers()
    {
        var modifiers = heldKeys.Where(k => k.Scan is 0x1D or 0x2A or 0x36 or 0x38 or 0x5B or 0x5C).ToList();
        if (modifiers.Count == 0) return;
        // Releasing Alt on its own would open an app's menu bar; an unassigned key in between prevents it.
        if (modifiers.Any(k => k.Scan == 0x38)) { SendVirtualKey(0xE8, true); SendVirtualKey(0xE8, false); }
        foreach (var key in modifiers)
        {
            SendScan(key.Scan, key.Extended, false);
            heldKeys.Remove(key);
        }
    }

    /// Releases everything still held so no key or button sticks on Windows.
    public void Leave(string reason)
    {
        if (!Active) return;
        Active = false;
        foreach (var (scan, extended) in heldKeys) SendScan(scan, extended, false);
        foreach (var virtualKey in heldVirtualKeys) SendVirtualKey(virtualKey, false);
        for (byte i = 0; i < heldButtons.Length; i++)
        {
            if (!heldButtons[i]) continue;
            heldButtons[i] = false;
            SendMouse(0, 0, Buttons[i].Data, Buttons[i].Up);
        }
        heldKeys.Clear();
        heldVirtualKeys.Clear();
        Log.Write("leave", $"reason={reason}");
        // Gone to the Mac or another PC: hide the pointer here, as the Mac does. A disconnect keeps it
        // visible, since the PC may be used on its own now.
        if (reason.EndsWith("_edge", StringComparison.Ordinal)) CursorHider.Hide();
    }

    private static void MoveTo(double px, double py)
    {
        var desk = Displays.VirtualScreen();
        var nx = (int)Math.Round((px - desk.Left) * 65535.0 / Math.Max(1, desk.Width - 1));
        var ny = (int)Math.Round((py - desk.Top) * 65535.0 / Math.Max(1, desk.Height - 1));
        SendMouse(nx, ny, 0, MouseMove | MouseAbsolute | MouseVirtualDesk);
    }

    private static void SendMouse(int dx, int dy, uint data, uint flags)
    {
        var input = new Native.Input
        {
            Type = InputMouse,
            Data = { Mouse = new Native.MouseInput { Dx = dx, Dy = dy, MouseData = data, Flags = flags, ExtraInfo = Signature } },
        };
        Native.SendInput(1, [input], Marshal.SizeOf<Native.Input>());
    }

    private static void SendScan(ushort scan, bool extended, bool down)
    {
        var flags = KeyScanCode | (extended ? KeyExtended : 0) | (down ? 0 : KeyUp);
        var input = new Native.Input
        {
            Type = InputKeyboard,
            Data = { Keyboard = new Native.KeyboardInput { Scan = scan, Flags = flags, ExtraInfo = Signature } },
        };
        Native.SendInput(1, [input], Marshal.SizeOf<Native.Input>());
    }

    private static void SendVirtualKey(ushort virtualKey, bool down)
    {
        var input = new Native.Input
        {
            Type = InputKeyboard,
            Data = { Keyboard = new Native.KeyboardInput { VirtualKey = virtualKey, Flags = KeyExtended | (down ? 0 : KeyUp), ExtraInfo = Signature } },
        };
        Native.SendInput(1, [input], Marshal.SizeOf<Native.Input>());
    }
}

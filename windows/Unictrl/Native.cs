using System.Runtime.InteropServices;

namespace Unictrl;

internal static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point(int x, int y)
    {
        public int X = x;
        public int Y = y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect32 { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MonitorInfo
    {
        public int Size;
        public Rect32 Monitor;
        public Rect32 Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MouseInput
    {
        public int Dx, Dy;
        public uint MouseData, Flags, Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KeyboardInput
    {
        public ushort VirtualKey, Scan;
        public uint Flags, Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SystemPowerStatus
    {
        public byte AcLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public int BatteryLifeTime, BatteryFullLifeTime;
    }

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemPowerStatus(out SystemPowerStatus status);

    /// The power mode slider (Settings › Power & battery): an overlay on the power plan.
    [LibraryImport("powrprof.dll")]
    public static partial uint PowerGetEffectiveOverlayScheme(out Guid overlay);

    [LibraryImport("user32.dll", SetLastError = true)]
    public static partial uint SendInput(uint count, [In] Input[] inputs, int size);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetCursorPos(out Point point);

    [LibraryImport("user32.dll")]
    public static partial int GetSystemMetrics(int index);

    /// Low bit: the key's toggle state (Caps Lock on), as the calling thread's input state sees it.
    [LibraryImport("user32.dll")]
    public static partial short GetKeyState(int virtualKey);

    [LibraryImport("user32.dll")]
    public static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    public static partial uint GetWindowThreadProcessId(nint window, out uint processId);

    [LibraryImport("kernel32.dll")]
    public static partial uint GetCurrentThreadId();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AttachThreadInput(uint attach, uint to, [MarshalAs(UnmanagedType.Bool)] bool doAttach);

    /// Whether Caps Lock is on for the user. GetKeyState reports the calling thread's view, which on the
    /// receiver thread (it never reads keyboard messages) can be stale, so this reads it while attached
    /// to the foreground window's input thread, whose state follows the keyboard.
    public static bool CapsLockOn()
    {
        var foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        var self = GetCurrentThreadId();
        var attached = foreground != 0 && foreground != self && AttachThreadInput(self, foreground, true);
        try { return (GetKeyState(0x14) & 1) != 0; }
        finally { if (attached) AttachThreadInput(self, foreground, false); }
    }

    [LibraryImport("user32.dll")]
    public static partial nint MonitorFromPoint(Point point, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetMonitorInfo(nint monitor, ref MonitorInfo info);

    public delegate nint WndProc(nint hwnd, uint message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WndClass
    {
        public uint Style;
        public nint WndProc;
        public int ClassExtra, WindowExtra;
        public nint Instance, Icon, Cursor, Background;
        [MarshalAs(UnmanagedType.LPWStr)] public string? MenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string ClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Msg
    {
        public nint Hwnd;
        public uint Message;
        public nint WParam, LParam;
        public uint Time;
        public Point Point;
        public uint Private;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RawInputDevice
    {
        public ushort UsagePage, Usage;
        public uint Flags;
        public nint Target;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RawInputHeader
    {
        public uint Type, Size;
        public nint Device, WParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RawMouse
    {
        public ushort Flags;
        public uint Buttons, RawButtons;
        public int LastX, LastY;
        public uint ExtraInformation;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern ushort RegisterClassW(ref WndClass wc);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern nint CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);

    [DllImport("user32.dll")]
    public static extern uint GetRawInputData(nint rawInput, uint command, nint data, ref uint size, uint headerSize);

    [DllImport("user32.dll")]
    public static extern int GetMessageW(out Msg msg, nint hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref Msg msg);

    [DllImport("user32.dll")]
    public static extern nint DispatchMessageW(ref Msg msg);

    [DllImport("user32.dll")]
    public static extern nint DefWindowProcW(nint hwnd, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool LockWorkStation();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern nint LoadImageW(nint instance, string name, uint type, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll")]
    public static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool AppendMenuW(nint menu, uint flags, nint id, string? text);

    [DllImport("user32.dll")]
    public static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);

    [DllImport("user32.dll")]
    public static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    public static extern bool PostMessageW(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern nint FindWindowW(string className, string? windowName);

    [LibraryImport("shcore.dll")]
    public static partial int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
}

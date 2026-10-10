using System.Runtime.InteropServices;

namespace Unictrl;

/// Notification-area icon with Unictrl's menu. Runs its own thread and message loop; callbacks are
/// raised on that thread, so callers marshal to the UI thread themselves.
internal sealed class Tray : IDisposable
{
    public const string WindowClass = "UnictrlTray";
    /// Posted by a second Unictrl instance to ask this one to show its window.
    public const uint ShowRequest = 0x8001; // WM_APP + 1

    private const uint CallbackMessage = 0x8002;
    private const uint NimAdd = 0, NimModify = 1, NimDelete = 2, NimSetVersion = 4;
    private const uint NifMessage = 0x1, NifIcon = 0x2, NifTip = 0x4, NifShowTip = 0x80;
    private const uint NinSelect = 0x400, NinKeySelect = 0x401, WmContextMenu = 0x7B;
    private const uint MfString = 0x0, MfChecked = 0x8, MfSeparator = 0x800;
    private const uint TpmReturnCmd = 0x100, TpmRightButton = 0x2;
    private const int CmdOpen = 1, CmdEnabled = 2, CmdStartAtLogin = 3, CmdQuit = 4;

    public event Action? OpenRequested;
    public event Action? EnabledToggled;
    public event Action? StartAtLoginToggled;
    public event Action? QuitRequested;

    /// Read when the menu opens.
    public Func<bool> IsEnabled { get; set; } = () => true;
    public Func<bool> StartsAtLogin { get; set; } = () => false;

    private readonly string iconPath;
    private readonly ManualResetEventSlim ready = new();
    private Native.WndProc? procKeepAlive;
    private nint window, icon;
    private uint taskbarCreated;
    private string tip = "Unictrl";
    private volatile bool visible;

    public Tray(string iconPath, bool visible)
    {
        this.iconPath = iconPath;
        this.visible = visible;
        new Thread(Run) { IsBackground = true, Name = "Unictrl tray" }.Start();
        ready.Wait(2000);
    }

    public void SetTooltip(string text)
    {
        tip = text.Length > 120 ? text[..120] : text;
        if (window != 0 && visible) Update(NimModify);
    }

    /// Shows or removes the notification-area icon. The hidden window stays, so a second launch can
    /// still ask this instance to open its window.
    public void SetVisible(bool show)
    {
        if (visible == show) return;
        visible = show;
        if (window != 0) Update(show ? NimAdd : NimDelete);
    }

    private void Run()
    {
        procKeepAlive = WindowProc;
        var wc = new Native.WndClass { WndProc = Marshal.GetFunctionPointerForDelegate(procKeepAlive), ClassName = WindowClass };
        Native.RegisterClassW(ref wc);
        // A hidden top-level window: the popup menu needs a window that can take the foreground.
        window = Native.CreateWindowExW(0, WindowClass, "Unictrl", 0x80000000 /* WS_POPUP */, 0, 0, 0, 0, 0, 0, 0, 0);
        taskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");
        var size = Native.GetSystemMetrics(49); // SM_CXSMICON, already scaled for the DPI
        icon = Native.LoadImageW(0, iconPath, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */);
        if (visible) Update(NimAdd);
        ready.Set();
        while (Native.GetMessageW(out var msg, 0, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }
    }

    private void Update(uint action)
    {
        var data = new NotifyIconData
        {
            Size = Marshal.SizeOf<NotifyIconData>(), Window = window, Id = 1,
            Flags = NifMessage | NifIcon | NifTip | NifShowTip, CallbackMessage = CallbackMessage,
            Icon = icon, Tip = tip, VersionOrTimeout = 4, // NOTIFYICON_VERSION_4
        };
        Shell_NotifyIconW(action, ref data);
        if (action == NimAdd) Shell_NotifyIconW(NimSetVersion, ref data);
    }

    private nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message == CallbackMessage)
        {
            var @event = (uint)(lParam & 0xFFFF);
            if (@event is NinSelect or NinKeySelect) OpenRequested?.Invoke();
            else if (@event == WmContextMenu) ShowMenu();
            return 0;
        }
        if (message == ShowRequest) { OpenRequested?.Invoke(); return 0; }
        if (message == taskbarCreated && taskbarCreated != 0) { if (visible) Update(NimAdd); return 0; } // Explorer restarted
        return Native.DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        Native.AppendMenuW(menu, MfString, CmdOpen, "Open Unictrl");
        Native.AppendMenuW(menu, MfSeparator, 0, null);
        Native.AppendMenuW(menu, MfString | (IsEnabled() ? MfChecked : 0), CmdEnabled, "Enabled");
        Native.AppendMenuW(menu, MfString | (StartsAtLogin() ? MfChecked : 0), CmdStartAtLogin, "Start at login");
        Native.AppendMenuW(menu, MfSeparator, 0, null);
        Native.AppendMenuW(menu, MfString, CmdQuit, "Quit Unictrl");
        Native.GetCursorPos(out var at);
        Native.SetForegroundWindow(window);
        var command = Native.TrackPopupMenu(menu, TpmReturnCmd | TpmRightButton, at.X, at.Y, 0, window, 0);
        Native.PostMessageW(window, 0, 0, 0); // lets the menu close properly
        Native.DestroyMenu(menu);
        switch (command)
        {
            case CmdOpen: OpenRequested?.Invoke(); break;
            case CmdEnabled: EnabledToggled?.Invoke(); break;
            case CmdStartAtLogin: StartAtLoginToggled?.Invoke(); break;
            case CmdQuit: QuitRequested?.Invoke(); break;
        }
    }

    public void Dispose()
    {
        if (window == 0) return;
        Update(NimDelete);
        if (icon != 0) Native.DestroyIcon(icon);
        Native.PostMessageW(window, 0x0012 /* WM_QUIT */, 0, 0);
        window = 0;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int Size;
        public nint Window;
        public uint Id, Flags, CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint VersionOrTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Item;
        public nint BalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);
}

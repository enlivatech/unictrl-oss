using System.Runtime.InteropServices;

namespace Unictrl;

/// Hides the Windows pointer while it is on another screen, as the Mac hides its own. Windows has no
/// call to hide the pointer over other apps' windows, so every system cursor is swapped for a blank
/// one and the user's cursor scheme is reloaded to show it again (as Mouse Without Borders does).
/// It comes back when the pointer returns, when a local mouse or touchpad moves, and when Unictrl
/// starts or quits, so a crash cannot leave the pointer invisible for long.
internal static class CursorHider
{
    private const uint SpiSetCursors = 0x57;
    // OCR_NORMAL, IBEAM, WAIT, CROSS, UP, SIZENWSE, SIZENESW, SIZEWE, SIZENS, SIZEALL, NO, HAND,
    // APPSTARTING, HELP, PIN, PERSON.
    private static readonly uint[] SystemCursors =
        [32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651, 32671, 32672];
    private static readonly object Gate = new();
    private static bool hidden;
    private static Native.Point parkedAt;
    private static Timer? watch;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CreateCursor(nint instance, int hotX, int hotY, int width, int height, byte[] andPlane, byte[] xorPlane);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetSystemCursor(nint cursor, uint id);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfoW(uint action, uint param, nint value, uint flags);

    public static void Hide()
    {
        lock (Gate)
        {
            if (hidden) return;
            // SetSystemCursor takes ownership of the handle, so each cursor needs its own blank one.
            var and = Enumerable.Repeat((byte)0xFF, 32 * 32 / 8).ToArray(); // screen shows through
            var xor = new byte[32 * 32 / 8];
            foreach (var id in SystemCursors)
            {
                var blank = CreateCursor(0, 0, 0, 32, 32, and, xor);
                if (blank != 0) SetSystemCursor(blank, id);
            }
            hidden = true;
            Native.GetCursorPos(out parkedAt);
            // A local mouse or touchpad moving the pointer brings it back at once.
            watch = new Timer(_ => { if (Native.GetCursorPos(out var at) && Moved(at)) Show("local_move"); }, null, 200, 200);
        }
        Log.Write("cursor_hidden");
    }

    private static bool Moved(Native.Point at) => Math.Abs(at.X - parkedAt.X) > 2 || Math.Abs(at.Y - parkedAt.Y) > 2;

    public static void Show(string reason = "")
    {
        lock (Gate)
        {
            if (!hidden) return;
            hidden = false;
            watch?.Dispose();
            watch = null;
            Reload();
        }
        Log.Write("cursor_shown", reason);
    }

    /// Reloads the user's cursor scheme; also run at startup in case a crash left it blank.
    public static void Reload() => SystemParametersInfoW(SpiSetCursors, 0, 0, 0);
}

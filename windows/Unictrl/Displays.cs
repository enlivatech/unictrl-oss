namespace Unictrl;

internal readonly record struct Rect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
}

internal readonly record struct MonitorGeometry(Rect Bounds, double PixelsPerMm)
{
    public double CenterY => (Bounds.Top + Bounds.Bottom) / 2.0;
}

/// Monitor geometry in physical pixels (the process is per-monitor DPI aware).
internal static class Displays
{
    private const uint DefaultToNull = 0, DefaultToPrimary = 1, DefaultToNearest = 2;
    private const int RawDpi = 2;

    public static MonitorGeometry Primary(double widthMmOverride = 0) =>
        Describe(Native.MonitorFromPoint(new Native.Point(0, 0), DefaultToPrimary), widthMmOverride);

    public static MonitorGeometry At(int x, int y) =>
        Describe(Native.MonitorFromPoint(new Native.Point(x, y), DefaultToNearest), 0);

    public static bool Exists(int x, int y) =>
        Native.MonitorFromPoint(new Native.Point(x, y), DefaultToNull) != 0;

    public static Rect VirtualScreen()
    {
        int left = Native.GetSystemMetrics(76), top = Native.GetSystemMetrics(77);
        return new Rect(left, top, left + Native.GetSystemMetrics(78), top + Native.GetSystemMetrics(79));
    }

    private static MonitorGeometry Describe(nint monitor, double widthMmOverride)
    {
        var info = new Native.MonitorInfo { Size = System.Runtime.InteropServices.Marshal.SizeOf<Native.MonitorInfo>() };
        Native.GetMonitorInfo(monitor, ref info);
        var bounds = new Rect(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom);
        double pixelsPerMm;
        if (widthMmOverride > 0)
            pixelsPerMm = bounds.Width / widthMmOverride;
        else if (Native.GetDpiForMonitor(monitor, RawDpi, out var dpiX, out _) == 0 && dpiX > 0)
            pixelsPerMm = dpiX / 25.4; // raw DPI comes from the panel's reported physical size
        else
            pixelsPerMm = 96 / 25.4;
        return new MonitorGeometry(bounds, pixelsPerMm);
    }
}

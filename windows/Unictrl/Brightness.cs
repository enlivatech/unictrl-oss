using System.Management;

namespace Unictrl;

/// The Mac's brightness keys change the PC's built-in screen through WMI, the interface Windows'
/// own brightness slider uses for laptop panels. External monitors do not support it.
internal static class Brightness
{
    private static readonly object Gate = new();
    private static int? level;
    private static DateTime lastStep = DateTime.MinValue;

    /// Changes brightness by `delta` percent, off the receiver thread (WMI calls take tens of ms).
    public static void Step(int delta) => Task.Run(() =>
    {
        lock (Gate)
        {
            try
            {
                var scope = new ManagementScope(@"root\WMI");
                // Within a burst of presses keep counting from our own value (the panel may still be
                // fading); after a pause read it again, since the slider or auto-brightness may have moved it.
                if (DateTime.UtcNow - lastStep > TimeSpan.FromSeconds(1.5)) level = Current(scope);
                lastStep = DateTime.UtcNow;
                if (level is null) return;
                level = Math.Clamp(level.Value + delta, 0, 100);
                using var searcher = new ManagementObjectSearcher(scope, new SelectQuery("WmiMonitorBrightnessMethods"));
                foreach (ManagementObject monitor in searcher.Get())
                {
                    using (monitor) monitor.InvokeMethod("WmiSetBrightness", [1u, (byte)level.Value]);
                }
                Log.Write("brightness", $"level={level}");
            }
            catch (ManagementException ex)
            {
                Log.Write("brightness_failed", ex.Message);
                level = null;
            }
        }
    });

    private static int? Current(ManagementScope scope)
    {
        using var searcher = new ManagementObjectSearcher(scope, new SelectQuery("WmiMonitorBrightness"));
        foreach (ManagementObject monitor in searcher.Get())
        {
            using (monitor) return Convert.ToInt32(monitor["CurrentBrightness"]);
        }
        return null;
    }
}

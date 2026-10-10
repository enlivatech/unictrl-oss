using System.Diagnostics;

namespace Unictrl;

/// Start at login through a logon scheduled task that runs with highest privileges: Unictrl must be
/// elevated to type into administrator windows, and a task starts it without a UAC prompt.
internal static class AutoStart
{
    private const string TaskName = "Unictrl";

    public static bool IsEnabled() => Schtasks($"/query /tn {TaskName}") == 0;

    public static bool Enable()
    {
        var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Unictrl.exe");
        var ok = Schtasks($"/create /tn {TaskName} /tr \"\\\"{exe}\\\" --background\" /sc onlogon /rl highest /it /delay 0000:05 /f") == 0;
        Log.Write("autostart_enable", $"ok={ok}");
        return ok;
    }

    public static bool Disable()
    {
        var ok = Schtasks($"/delete /tn {TaskName} /f") == 0;
        Log.Write("autostart_disable", $"ok={ok}");
        return ok;
    }

    private static int Schtasks(string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("schtasks.exe", arguments)
            {
                CreateNoWindow = true, UseShellExecute = false,
                RedirectStandardOutput = true, RedirectStandardError = true,
            });
            if (process is null) return -1;
            process.WaitForExit(10_000);
            return process.HasExited ? process.ExitCode : -1;
        }
        catch { return -1; }
    }
}

namespace Unictrl;

/// Diagnostics at %LOCALAPPDATA%\Unictrl\unictrl.log. Never logs keystrokes or the pairing key.
internal static class Log
{
    private static readonly object Gate = new();
    private static readonly string FileName = Path.Combine(Settings.Directory, "unictrl.log");

    /// Settings.Diagnostics, read at start.
    public static bool Diagnostics;

    /// A diagnostics-only line: written only while Diagnostics is on.
    public static void Diagnostic(string eventName, string detail = "")
    {
        if (Diagnostics) Write(eventName, detail);
    }

    public static void Write(string eventName, string detail = "")
    {
        try
        {
            lock (Gate)
            {
                System.IO.Directory.CreateDirectory(Settings.Directory);
                if (File.Exists(FileName) && new FileInfo(FileName).Length > 2_000_000)
                    File.Move(FileName, FileName + ".previous", true);
                File.AppendAllText(FileName, $"{DateTimeOffset.Now:yyyy-MM-ddTHH:mm:ss.fffzzz} {eventName} {detail}\n");
            }
        }
        catch { /* Logging must never interrupt input. */ }
    }
}

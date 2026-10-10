using Microsoft.UI.Xaml;

namespace Unictrl;

public partial class App : Application
{
    private Window? window;
    private Mutex? singleInstance;

    public App()
    {
        UnhandledException += (_, e) =>
        {
            Log.Write("unhandled", e.Exception.GetType().Name + ": " + e.Exception.Message);
            CursorHider.Show("crash");
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => CursorHider.Show("exit");
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (RunDiagnostic(Environment.GetCommandLineArgs())) { Exit(); return; }
        singleInstance = new Mutex(true, @"Local\UnictrlSingleInstance", out var first);
        if (!first)
        {
            // Already running: bring its window up instead of starting a second copy.
            var existing = Native.FindWindowW(Tray.WindowClass, null);
            if (existing != 0) Native.PostMessageW(existing, Tray.ShowRequest, 0, 0);
            Exit();
            return;
        }
        CursorHider.Reload(); // a previous run may have ended with the pointer hidden
        var background = Environment.GetCommandLineArgs().Contains("--background");
        Log.Diagnostics = Settings.Load().Diagnostics;
        if (Log.Diagnostics) MouseProbe.Start();
        window = new MainWindow();
        if (!background) window.Activate();
        else ((MainWindow)window).StartInBackground();
    }

    /// Command-line checks used during development: --discover-test, --pair-test host port code.
    private static bool RunDiagnostic(string[] args)
    {
        if (args.Contains("--discover-test"))
        {
            var macs = Discovery.Find(TimeSpan.FromSeconds(2));
            Log.Write("discover_test", string.Join("; ", macs.Select(m => $"{m.Name} {m.Address}:{m.Port} {m.Id}")));
            return true;
        }
        var i = Array.IndexOf(args, "--pair-test");
        if (i < 0 || args.Length <= i + 3) return false;
        var result = PairingClient.Pair(args[i + 1], int.Parse(args[i + 2]), args[i + 3], Settings.Load().DeviceIdBytes);
        var fingerprint = result.PairingKey is null ? "-" :
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(result.PairingKey)))[..12];
        Log.Write("pair_test", $"outcome={result.Outcome} mac={result.MacId} key_fp={fingerprint}");
        return true;
    }
}

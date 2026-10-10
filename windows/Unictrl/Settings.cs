using System.Text.Json;

namespace Unictrl;

/// %LOCALAPPDATA%\Unictrl\settings.json. Kept out of Git: it holds the pairing key.
public sealed class Settings
{
    /// Last address the Mac was found at; refreshed by discovery when it stops answering there.
    public string MacAddress { get; set; } = "";
    /// The paired Mac's device ID, to pick it out when several Macs answer discovery.
    public string MacId { get; set; } = "";
    public string MacName { get; set; } = "";
    public int Port { get; set; } = 24860;
    public string PairingKey { get; set; } = "";
    /// This PC's ID, so the Mac can tell several PCs apart; generated once.
    public string DeviceId { get; set; } = "";
    /// "mx-keys-legends": keys do what the Windows legend on an MX Keys says (opt/⊞ = Win, cmd/alt = Alt).
    /// "mac-positions": Option = Alt, Command = Win.
    public string KeyboardProfile { get; set; } = "mx-keys-legends";
    /// 0 = use the monitor's reported physical size.
    public double ScreenWidthMmOverride { get; set; }
    public bool Enabled { get; set; } = true;
    public bool StartAtLogin { get; set; } = true;
    /// Where Unictrl shows its icon. With both off it is opened again from the Start menu.
    /// Taskbar on: a taskbar button all the time (closing the window minimizes it). Off: only while
    /// the window is open.
    public bool ShowTrayIcon { get; set; } = true;
    public bool ShowInTaskbar { get; set; }
    /// Extra log lines for chasing pointer hitches (mouse statistics, delay spikes). Off by default;
    /// set it here by hand and restart Unictrl.
    public bool Diagnostics { get; set; }
    /// Connection › Details and tips is open.
    public bool ShowConnectionDetails { get; set; }
    /// The window size the user left, in DIPs (0 = the default size).
    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }

    public static string Directory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Unictrl");

    private static string FileName => Path.Combine(Directory, "settings.json");
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Settings Load()
    {
        Settings settings;
        try { settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FileName)) ?? new(); }
        catch { settings = new(); }
        if (!Guid.TryParse(settings.DeviceId, out _))
        {
            settings.DeviceId = Guid.NewGuid().ToString("D").ToUpperInvariant();
            settings.Save();
        }
        return settings;
    }

    /// The device ID as the 16 big-endian bytes the Mac reads.
    [System.Text.Json.Serialization.JsonIgnore]
    public byte[] DeviceIdBytes => Guid.Parse(DeviceId).ToByteArray(bigEndian: true);

    private static readonly object SaveGate = new();

    /// Saved from the UI, the receiver thread and a resize timer, so writes are serialised.
    public void Save()
    {
        lock (SaveGate)
        {
            System.IO.Directory.CreateDirectory(Directory);
            var temp = FileName + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Options));
            File.Move(temp, FileName, true);
        }
    }
}

using System.Net;
using System.Net.NetworkInformation;

namespace Unictrl;

/// Reads this PC's network link to the Mac and its power state. Each part may be unknown.
internal static class PcEnvironment
{
    private static readonly Guid BestEfficiency = new("961cc777-2547-4f9d-8174-7d86181b8a7a");
    private static readonly Guid BestPerformance = new("ded574b5-45a0-4f42-8737-46345c09c238");

    public static PcEnvironmentInfo Read(IPAddress? local)
    {
        string? link = null;
        int? mbps = null, bars = null;
        try
        {
            if (local is not null && local.IsIPv4MappedToIPv6) local = local.MapToIPv4();
            var nic = local is null ? null : NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(n => n.GetIPProperties().UnicastAddresses.Any(a => a.Address.Equals(local)));
            if (nic is not null)
            {
                link = nic.NetworkInterfaceType switch
                {
                    NetworkInterfaceType.Wireless80211 => "wifi",
                    NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT
                        or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.Ethernet3Megabit => "ethernet",
                    _ => "other",
                };
                if (nic.Speed > 0) mbps = (int)Math.Min(int.MaxValue, nic.Speed / 1_000_000);
                if (link == "wifi") bars = SignalBars(nic.Id);
            }
        }
        catch (Exception ex) when (ex is NetworkInformationException or InvalidOperationException) { }

        bool? onBattery = null, saver = null;
        if (Native.GetSystemPowerStatus(out var power))
        {
            if (power.AcLineStatus is 0 or 1) onBattery = power.AcLineStatus == 0;
            saver = (power.SystemStatusFlag & 1) != 0;
        }
        string? mode = null;
        try
        {
            if (Native.PowerGetEffectiveOverlayScheme(out var overlay) == 0)
                mode = overlay == BestEfficiency ? "efficiency" : overlay == BestPerformance ? "performance" : "balanced";
        }
        catch (EntryPointNotFoundException) { }
        return new PcEnvironmentInfo(link, mbps, bars, onBattery, saver, mode);
    }

    private static int? SignalBars(string adapterId)
    {
        try
        {
            if (!Guid.TryParse(adapterId, out var id)) return null;
            foreach (var profile in Windows.Networking.Connectivity.NetworkInformation.GetConnectionProfiles())
                if (profile.NetworkAdapter?.NetworkAdapterId == id && profile.GetSignalBars() is { } bars) return bars;
        }
        catch (Exception) { /* WinRT networking unavailable */ }
        return null;
    }
}

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Unictrl;

/// Finds Unictrl Macs on the local network: a "UNICTRL?" broadcast on UDP 24861 from every LAN
/// interface, answered by each Mac with its device ID, name and port. Replies are unicast responses
/// to our own broadcast, which Windows Firewall lets in without a rule.
internal static class Discovery
{
    public sealed record Mac(string Id, string Name, string Address, int Port);

    private const int Port = 24861;
    private static readonly byte[] Query = "UNICTRL?"u8.ToArray();
    private static readonly byte[] Answer = "UNICTRL!"u8.ToArray();

    public static List<Mac> Find(TimeSpan wait)
    {
        var sockets = new List<UdpClient>();
        try
        {
            foreach (var (local, broadcast) in LanInterfaces())
            {
                try
                {
                    var udp = new UdpClient(new IPEndPoint(local, 0)) { EnableBroadcast = true };
                    udp.Send(Query, Query.Length, new IPEndPoint(broadcast, Port));
                    udp.Send(Query, Query.Length, new IPEndPoint(IPAddress.Broadcast, Port));
                    sockets.Add(udp);
                }
                catch (SocketException) { }
            }
            var found = new Dictionary<string, Mac>();
            var deadline = DateTime.UtcNow + wait;
            while (DateTime.UtcNow < deadline)
            {
                var any = false;
                foreach (var udp in sockets.Where(s => s.Available > 0))
                {
                    any = true;
                    var remote = new IPEndPoint(IPAddress.Any, 0);
                    var data = udp.Receive(ref remote);
                    if (Parse(data, remote.Address) is { } mac) found[mac.Id] = mac;
                }
                if (!any) Thread.Sleep(20);
            }
            Log.Write("discovery", $"found={found.Count}");
            return found.Values.ToList();
        }
        finally
        {
            foreach (var udp in sockets) udp.Dispose();
        }
    }

    private static Mac? Parse(byte[] data, IPAddress from)
    {
        if (data.Length <= Answer.Length || !data.AsSpan(0, Answer.Length).SequenceEqual(Answer)) return null;
        try
        {
            using var json = JsonDocument.Parse(data.AsMemory(Answer.Length));
            var root = json.RootElement;
            return new Mac(root.GetProperty("id").GetString() ?? "", root.GetProperty("name").GetString() ?? "Mac",
                from.ToString(), root.GetProperty("port").GetInt32());
        }
        catch { return null; }
    }

    /// Physical Ethernet and Wi-Fi adapters with an IPv4 address; VPN and virtual adapters are skipped.
    private static IEnumerable<(IPAddress Local, IPAddress Broadcast)> LanInterfaces()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType is not (NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211)) continue;
            var label = nic.Name + " " + nic.Description;
            if (label.Contains("Virtual", StringComparison.OrdinalIgnoreCase) || label.Contains("VMware", StringComparison.OrdinalIgnoreCase) ||
                label.Contains("Tunnel", StringComparison.OrdinalIgnoreCase) || label.Contains("Tailscale", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var ip = unicast.Address.GetAddressBytes();
                var mask = unicast.IPv4Mask.GetAddressBytes();
                var broadcast = new byte[4];
                for (var i = 0; i < 4; i++) broadcast[i] = (byte)(ip[i] | ~mask[i]);
                yield return (unicast.Address, new IPAddress(broadcast));
            }
        }
    }
}

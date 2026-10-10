using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Unictrl;

/// HID++ 2.0 Easy-Switch (feature 0x1814 ChangeHost) for the Logitech keyboard and mouse while they are
/// connected to this PC. Used to send them back to the Mac when it wakes; see docs/PROTOCOL.md.
internal static class LogitechHid
{
    private const int PresentInterfaces = 0x12;
    private const uint Read = 0x80000000, Write = 0x40000000, Share = 3, OpenExisting = 3, Overlapped = 0x40000000;
    private const int CapsSuccess = 0x00110000;
    private const byte SoftwareId = 0x0B;

    public const ushort MxKeys = 0xB35B, MxAnywhere3S = 0xB037;

    [StructLayout(LayoutKind.Sequential)]
    private struct InterfaceData { public int Size; public Guid Guid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Attributes { public int Size; public ushort Vendor, Product, Version; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Caps
    {
        public ushort Usage, UsagePage, InputLength, OutputLength, FeatureLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort LinkNodes, InputButtons, InputValues, InputIndices;
        public ushort OutputButtons, OutputValues, OutputIndices;
        public ushort FeatureButtons, FeatureValues, FeatureIndices;
    }

    private sealed record Candidate(string Path, ushort ProductId, ushort InputLength, ushort OutputLength);

    [DllImport("hid.dll")] private static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool HidD_GetAttributes(SafeFileHandle handle, ref Attributes attributes);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr data);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] private static extern int HidP_GetCaps(IntPtr data, ref Caps caps);
    [DllImport("setupapi.dll", SetLastError = true)] private static extern IntPtr SetupDiGetClassDevsW(ref Guid guid, IntPtr enumerator, IntPtr window, int flags);
    [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, int index, ref InterfaceData data);
    [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref InterfaceData data, IntPtr detail, int size, out int needed, IntPtr info);
    [DllImport("setupapi.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    /// Logitech vendor-defined HID collections (where HID++ lives) for the given products.
    private static List<Candidate> Enumerate(params ushort[] products)
    {
        var found = new List<Candidate>();
        HidD_GetHidGuid(out var guid);
        var set = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero, PresentInterfaces);
        if (set == new IntPtr(-1)) return found;
        try
        {
            for (var i = 0; ; i++)
            {
                var data = new InterfaceData { Size = Marshal.SizeOf<InterfaceData>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref data)) break;
                SetupDiGetDeviceInterfaceDetailW(set, ref data, IntPtr.Zero, 0, out var needed, IntPtr.Zero);
                if (needed < 16) continue;
                var detail = Marshal.AllocHGlobal(needed);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetailW(set, ref data, detail, needed, out _, IntPtr.Zero)) continue;
                    var path = Marshal.PtrToStringUni(detail + 4);
                    if (path is null) continue;
                    using var handle = CreateFileW(path, 0, Share, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
                    if (handle.IsInvalid) continue;
                    var attributes = new Attributes { Size = Marshal.SizeOf<Attributes>() };
                    if (!HidD_GetAttributes(handle, ref attributes) || attributes.Vendor != 0x046D || !products.Contains(attributes.Product)) continue;
                    if (!HidD_GetPreparsedData(handle, out var parsed)) continue;
                    var caps = new Caps { Reserved = new ushort[17] };
                    var ok = HidP_GetCaps(parsed, ref caps) == CapsSuccess;
                    HidD_FreePreparsedData(parsed);
                    if (!ok || caps.UsagePage < 0xFF00 || caps.OutputLength < 7 || caps.InputLength < 7) continue;
                    found.Add(new Candidate(path, attributes.Product, caps.InputLength, caps.OutputLength));
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }

    /// One device's HID++ ChangeHost feature, ready to use.
    public sealed class Device : IDisposable
    {
        private readonly FileStream stream;
        private readonly Candidate candidate;
        private byte index, report, feature;

        public ushort ProductId => candidate.ProductId;

        private Device(Candidate candidate)
        {
            this.candidate = candidate;
            var handle = CreateFileW(candidate.Path, Read | Write, Share, IntPtr.Zero, OpenExisting, Overlapped, IntPtr.Zero);
            if (handle.IsInvalid) throw new IOException("Cannot open HID collection");
            stream = new FileStream(handle, FileAccess.ReadWrite, 1, true);
        }

        /// Finds the device's ChangeHost feature over Bluetooth (index 0xFF) or a receiver slot.
        public static async Task<Device?> OpenAsync(ushort productId, CancellationToken token)
        {
            foreach (var candidate in Enumerate(productId))
            {
                Device? device = null;
                try
                {
                    device = new Device(candidate);
                    foreach (var index in new byte[] { 0xFF, 1, 2, 3 })
                    foreach (var report in new byte[] { 0x11, 0x10 })
                    {
                        if (candidate.OutputLength < (report == 0x11 ? 20 : 7)) continue;
                        var reply = await device.CallAsync(report, index, 0, 0, [0x18, 0x14], token);
                        if (reply is not { Length: >= 5 } || reply[4] == 0) continue;
                        (device.index, device.report, device.feature) = (index, report, reply[4]);
                        return device;
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                device?.Dispose();
            }
            return null;
        }

        /// The number of Easy-Switch channels and the one in use (0-based).
        public async Task<(int Count, int Current)?> HostInfoAsync(CancellationToken token) =>
            await CallAsync(report, index, feature, 0, [], token) is { Length: >= 6 } r ? (r[4], r[5]) : null;

        /// Sends the device to another channel. It disconnects at once, usually without replying.
        public async Task ChangeHostAsync(int host, CancellationToken token) =>
            await CallAsync(report, index, feature, 1, [(byte)host], token, wait: false);

        private async Task<byte[]?> CallAsync(byte report, byte index, byte feature, byte function, byte[] args,
            CancellationToken token, bool wait = true)
        {
            var frame = new byte[candidate.OutputLength];
            frame[0] = report; frame[1] = index; frame[2] = feature;
            frame[3] = (byte)((function << 4) | SoftwareId);
            Array.Copy(args, 0, frame, 4, Math.Min(args.Length, (report == 0x11 ? 20 : 7) - 4));
            try { await stream.WriteAsync(frame, token); await stream.FlushAsync(token); }
            catch (Exception ex) when (ex is IOException or OperationCanceledException) { return null; }
            if (!wait) return frame;
            var deadline = DateTime.UtcNow.AddMilliseconds(400);
            while (DateTime.UtcNow < deadline)
            {
                var buffer = new byte[candidate.InputLength];
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(120);
                int count;
                try { count = await stream.ReadAsync(buffer, timeout.Token); }
                catch (OperationCanceledException) { continue; }
                catch (IOException) { return null; }
                if (count < 5 || buffer[1] != index) continue;
                if (buffer[2] is 0xFF or 0x8F) return null; // HID++ error
                if (buffer[2] != feature || (buffer[3] & 0x0F) != SoftwareId) continue;
                return buffer[..count];
            }
            return null;
        }

        public void Dispose() => stream.Dispose();
    }

    /// The Mac woke: report which channels the devices use here, then send them back to the Mac's.
    /// 0xFF leaves a device alone.
    public static async Task ReturnToMacAsync(byte keyboardHost, byte mouseHost, Action<byte[]> send)
    {
        using var token = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        using var keyboard = await Device.OpenAsync(MxKeys, token.Token);
        using var mouse = await Device.OpenAsync(MxAnywhere3S, token.Token);
        var keyboardHere = keyboard is null ? null : await keyboard.HostInfoAsync(token.Token);
        var mouseHere = mouse is null ? null : await mouse.HostInfoAsync(token.Token);
        try { send(Messages.Hosts((byte)(keyboardHere?.Current ?? 0xFF), (byte)(mouseHere?.Current ?? 0xFF))); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }
        Log.Write("easy_switch_here", $"keyboard={keyboardHere?.Current.ToString() ?? "-"} mouse={mouseHere?.Current.ToString() ?? "-"}");
        if (keyboard is not null && keyboardHost != 0xFF && keyboardHere?.Current != keyboardHost)
        {
            await keyboard.ChangeHostAsync(keyboardHost, token.Token);
            Log.Write("easy_switch_sent", $"keyboard to={keyboardHost}");
        }
        if (mouse is not null && mouseHost != 0xFF && mouseHere?.Current != mouseHost)
        {
            await mouse.ChangeHostAsync(mouseHost, token.Token);
            Log.Write("easy_switch_sent", $"mouse to={mouseHost}");
        }
    }
}

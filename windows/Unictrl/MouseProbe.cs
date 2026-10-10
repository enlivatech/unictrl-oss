using System.Runtime.InteropServices;

namespace Unictrl;

/// Diagnostics: compares how far the Windows cursor travels per mouse count for a mouse connected
/// to Windows directly (raw input from a real device) and for counts Unictrl injects. Logs one line
/// per second of movement; never logs buttons or keys. Runs only with Settings.Diagnostics on.
internal static class MouseProbe
{
    private const int WmInput = 0x00FF;
    private const uint RidInput = 0x10000003, RimTypeMouse = 0, RidevInputSink = 0x100;
    private static readonly object Gate = new();
    private static Window native = new("native_mouse"), injected = new("injected_mouse");
    private static Native.WndProc? procKeepAlive;

    private sealed class Window(string name)
    {
        public readonly string Name = name;
        public long Started, Packets, Counts, LastTick;
        public double Pixels;
        public Native.Point? Last;
        private readonly List<double> gaps = [];

        public void Add(int dx, int dy)
        {
            var now = Environment.TickCount64;
            var tick = System.Diagnostics.Stopwatch.GetTimestamp();
            if (Packets == 0) Started = now;
            else gaps.Add((tick - LastTick) * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
            LastTick = tick;
            Packets++;
            Counts += Math.Abs(dx) + Math.Abs(dy);
            if (Native.GetCursorPos(out var at))
            {
                if (Last is { } last) Pixels += Math.Abs(at.X - last.X) + Math.Abs(at.Y - last.Y);
                Last = at;
            }
            if (now - Started >= 1000) Flush();
        }

        public void AddWheel(int units)
        {
            var now = Environment.TickCount64;
            var tick = System.Diagnostics.Stopwatch.GetTimestamp();
            if (Packets == 0) Started = now;
            else gaps.Add((tick - LastTick) * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
            LastTick = tick;
            Packets++;
            Counts += Math.Abs(units);
            if (now - Started >= 1000)
            {
                if (Packets >= 3)
                    Log.Write(Name, $"events={Packets} units={Counts} units_per_event={(double)Counts / Packets:F1} gap_ms_p50={(gaps.Count == 0 ? 0 : gaps.OrderBy(g => g).ElementAt(gaps.Count / 2)):F1}");
                gaps.Clear();
                Packets = Counts = 0;
            }
        }

        public void Flush()
        {
            if (Packets >= 20 && Counts > 0)
            {
                // Gaps over 100 ms are pauses in the hand movement, not jitter.
                var moving = gaps.Where(g => g < 100).OrderBy(g => g).ToList();
                string P(double q) => moving.Count == 0 ? "-" : moving[(int)Math.Min(moving.Count - 1, q * moving.Count)].ToString("F1");
                Log.Write(Name, $"packets={Packets} counts={Counts} px={Pixels:F0} px_per_count={Pixels / Counts:F3} counts_per_packet={(double)Counts / Packets:F1} gap_ms p50={P(0.5)} p90={P(0.9)} p99={P(0.99)} max={(moving.Count == 0 ? "-" : moving[^1].ToString("F1"))}");
            }
            gaps.Clear();
            Packets = Counts = 0;
            Pixels = 0;
            Last = null;
        }
    }

    private static readonly Window wheel = new("injected_wheel");

    /// Wheel units injected (120 = one notch); logs how finely scrolling arrives.
    public static void RecordWheel(int units)
    {
        if (!Log.Diagnostics) return;
        lock (Gate) wheel.AddWheel(units);
    }

    public static void RecordInjected(int dx, int dy)
    {
        if (!Log.Diagnostics) return;
        lock (Gate) injected.Add(dx, dy);
    }

    public static void Start()
    {
        var thread = new Thread(Run) { IsBackground = true, Name = "Unictrl mouse probe" };
        thread.Start();
    }

    private static void Run()
    {
        procKeepAlive = WindowProc;
        var wc = new Native.WndClass { WndProc = Marshal.GetFunctionPointerForDelegate(procKeepAlive), ClassName = "UnictrlMouseProbe" };
        if (Native.RegisterClassW(ref wc) == 0) return;
        var hwnd = Native.CreateWindowExW(0, "UnictrlMouseProbe", "", 0, 0, 0, 0, 0, -3 /* HWND_MESSAGE */, 0, 0, 0);
        if (hwnd == 0) return;
        var device = new Native.RawInputDevice { UsagePage = 1, Usage = 2, Flags = RidevInputSink, Target = hwnd };
        if (!Native.RegisterRawInputDevices([device], 1, (uint)Marshal.SizeOf<Native.RawInputDevice>()))
        {
            Log.Write("probe_failed", "RegisterRawInputDevices");
            return;
        }
        while (Native.GetMessageW(out var msg, 0, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }
    }

    private static nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message == WmInput)
        {
            uint size = 0;
            var headerSize = (uint)Marshal.SizeOf<Native.RawInputHeader>();
            Native.GetRawInputData(lParam, RidInput, 0, ref size, headerSize);
            if (size > 0 && size <= 256)
            {
                var buffer = Marshal.AllocHGlobal((int)size);
                try
                {
                    if (Native.GetRawInputData(lParam, RidInput, buffer, ref size, headerSize) == size)
                    {
                        var header = Marshal.PtrToStructure<Native.RawInputHeader>(buffer);
                        // Injected input arrives with no device handle; count only real mice.
                        if (header.Type == RimTypeMouse && header.Device != 0)
                        {
                            var mouse = Marshal.PtrToStructure<Native.RawMouse>(buffer + (int)headerSize);
                            if ((mouse.Flags & 1) == 0 && (mouse.LastX != 0 || mouse.LastY != 0))
                                lock (Gate) native.Add(mouse.LastX, mouse.LastY);
                        }
                    }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        return Native.DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

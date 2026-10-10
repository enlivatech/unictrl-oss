using System.Text.Json;
using System.Text.Json.Serialization;

namespace Unictrl;

/// One-way delay variation of moves: arrival time minus the Mac's send clock, against the lowest
/// of the last half minute. The clocks' offset cancels out; a spike is a move that arrived late.
internal sealed class DelayTracker
{
    public const double SpikeMs = 20;
    private const double CalmMs = 8;
    private const long BaselineSeconds = 30;

    private uint? lastRaw;
    private long high;
    private readonly Queue<(long Second, double Min)> minima = new();
    private long currentSecond = long.MinValue;
    private double currentMin = double.MaxValue;
    private bool inSpike;

    /// Spikes since the last Take, and each move's lateness in ms.
    public int Spikes { get; private set; }
    public List<double> Jitter { get; } = [];

    public void Reset()
    {
        lastRaw = null;
        high = 0;
        minima.Clear();
        currentSecond = long.MinValue;
        currentMin = double.MaxValue;
        inSpike = false;
    }

    /// `sentUs` is the Mac's clock in µs (wrapping at 2^32); `arrivalUs` this PC's monotonic clock.
    /// Returns the move's lateness in ms when it starts a new spike, else null.
    public double? Add(uint sentUs, long arrivalUs)
    {
        if (lastRaw is { } last)
        {
            if (sentUs < last && last - sentUs > uint.MaxValue / 2) high += 1L << 32; // wrapped
            else if (sentUs > last && sentUs - last > uint.MaxValue / 2) return null; // from before a wrap
        }
        lastRaw = sentUs;
        var delay = (arrivalUs - (high + sentUs)) / 1000.0;
        var second = arrivalUs / 1_000_000;
        if (second != currentSecond)
        {
            if (currentSecond != long.MinValue) minima.Enqueue((currentSecond, currentMin));
            while (minima.Count > 0 && minima.Peek().Second < second - BaselineSeconds) minima.Dequeue();
            currentSecond = second;
            currentMin = double.MaxValue;
        }
        currentMin = Math.Min(currentMin, delay);
        var baseline = currentMin;
        foreach (var m in minima) baseline = Math.Min(baseline, m.Min);
        var jitter = delay - baseline;
        Jitter.Add(jitter);
        if (jitter >= SpikeMs && !inSpike)
        {
            Spikes++;
            inSpike = true;
            return jitter;
        }
        if (jitter < CalmMs) inSpike = false;
        return null;
    }

    public void ClearCounts()
    {
        Spikes = 0;
        Jitter.Clear();
    }
}

/// A second of moves as the PC saw them.
internal sealed record MoveSecond(int Moves, int Hitches, double JitterMaxMs, double JitterP95Ms, int SlowInjects, double InjectMaxMs);

/// Counts moves, delay spikes and slow injections; thread-safe (the receiver adds, a timer takes).
internal sealed class MoveStats
{
    public const double SlowInjectMs = 8;
    private readonly object gate = new();
    private readonly DelayTracker delays = new();
    private int moves;
    private int slowInjects;
    private double injectMax;

    public void Reset()
    {
        lock (gate)
        {
            delays.Reset();
            Clear();
        }
    }

    /// Returns the lateness in ms when this move starts a delay spike.
    public double? Add(uint? sentUs, long arrivalUs, double injectMs)
    {
        lock (gate)
        {
            moves++;
            if (injectMs >= SlowInjectMs) slowInjects++;
            injectMax = Math.Max(injectMax, injectMs);
            return sentUs is { } sent ? delays.Add(sent, arrivalUs) : null;
        }
    }

    public MoveSecond Take()
    {
        lock (gate)
        {
            var sorted = delays.Jitter.Order().ToList();
            double P(double q) => sorted.Count == 0 ? 0 : sorted[Math.Min(sorted.Count - 1, (int)(q * sorted.Count))];
            var second = new MoveSecond(moves, delays.Spikes, Math.Round(P(1), 1), Math.Round(P(0.95), 1), slowInjects, Math.Round(injectMax, 1));
            Clear();
            return second;
        }
    }

    private void Clear()
    {
        delays.ClearCounts();
        moves = 0;
        slowInjects = 0;
        injectMax = 0;
    }
}

/// What the PC knows about its own connection and power, for the Mac's checklist.
internal sealed record PcEnvironmentInfo(string? Link, int? LinkMbps, int? SignalBars, bool? OnBattery, bool? BatterySaver, string? PowerMode);

/// The 0x22 stats message.
internal static class PcStatsMessage
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static byte[] Json(MoveSecond s, PcEnvironmentInfo? env) => JsonSerializer.SerializeToUtf8Bytes(new
    {
        moves = s.Moves,
        hitches = s.Hitches,
        jitterMaxMs = s.JitterMaxMs,
        jitterP95Ms = s.JitterP95Ms,
        slowInjects = s.SlowInjects,
        injectMaxMs = s.InjectMaxMs,
        link = env?.Link,
        linkMbps = env?.LinkMbps,
        signalBars = env?.SignalBars,
        onBattery = env?.OnBattery,
        batterySaver = env?.BatterySaver,
        powerMode = env?.PowerMode,
    }, Options);
}

/// The Mac's 0x23 report on how the pointer is doing here, with its checklist.
public sealed record QualityInfo(string Grade, double? RttMs, double? RttP95Ms, int MovingSeconds, HitchRates? HitchesPerMin, List<TipInfo>? Tips,
    List<string>? RecentHitches = null)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static QualityInfo? Parse(byte[] json)
    {
        try { return JsonSerializer.Deserialize<QualityInfo>(json, Options); }
        catch (JsonException) { return null; }
    }
}

public sealed record HitchRates(double Mouse, double Mac, double Network, double Pc);

public sealed record TipInfo(string Id, string Status, string Title, string Summary, List<string> Steps, string? Seen);

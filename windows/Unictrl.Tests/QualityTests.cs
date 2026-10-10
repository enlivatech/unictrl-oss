using System.Text.Json;
using Xunit;

namespace Unictrl.Tests;

public class QualityTests
{
    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "contract", name));

    /// Moves every 8 ms with a fixed 3 ms one-way delay (and an arbitrary clock offset).
    private static void Steady(DelayTracker tracker, long fromUs, int count, long offsetUs = 5_000_000_000)
    {
        for (var i = 0; i < count; i++)
        {
            var sent = fromUs + i * 8_000L;
            tracker.Add((uint)(sent & 0xFFFF_FFFF), sent + offsetUs + 3_000);
        }
    }

    [Fact]
    public void SteadyDelayHasNoSpikes()
    {
        var tracker = new DelayTracker();
        Steady(tracker, 1_000_000, 500);
        Assert.Equal(0, tracker.Spikes);
        Assert.True(tracker.Jitter.Max() < 0.01);
    }

    [Fact]
    public void ALateBurstCountsOnce()
    {
        var tracker = new DelayTracker();
        Steady(tracker, 1_000_000, 100);
        // Five moves held up by 40 ms on the way, then delivered together.
        const long offset = 5_000_000_000;
        for (var i = 0; i < 5; i++)
        {
            var sent = 1_800_000L + i * 8_000;
            tracker.Add((uint)sent, 1_840_000 + offset + 3_000 + i * 100);
        }
        Steady(tracker, 1_840_000, 100);
        Assert.Equal(1, tracker.Spikes);
        Assert.InRange(tracker.Jitter.Max(), 39, 41);
    }

    [Fact]
    public void TheMacsClockWrapping()
    {
        var tracker = new DelayTracker();
        var start = (1L << 32) - 400_000; // 0.4 s before the 32-bit µs clock wraps
        Steady(tracker, start, 200);       // runs past it
        Assert.Equal(0, tracker.Spikes);
        Assert.True(tracker.Jitter.Max() < 0.01);
    }

    [Fact]
    public void MoveStatsTakeResetsTheSecond()
    {
        var stats = new MoveStats();
        stats.Add(100, 10_000, 0.2);
        stats.Add(108, 10_008, 9.5);
        stats.Add(null, 10_016, 0.1); // a Mac that sends no clock still counts
        var second = stats.Take();
        Assert.Equal(3, second.Moves);
        Assert.Equal(1, second.SlowInjects);
        Assert.Equal(9.5, second.InjectMaxMs);
        Assert.Equal(0, stats.Take().Moves);
    }

    [Fact]
    public void StatsHaveTheShapeTheMacDecodes()
    {
        var json = PcStatsMessage.Json(new MoveSecond(118, 2, 34.2, 3.1, 0, 0.4),
            new PcEnvironmentInfo("wifi", 866, 4, false, false, "balanced"));
        using var ours = JsonDocument.Parse(json);
        using var expected = JsonDocument.Parse(Fixture("pc-stats.json"));
        Assert.Equal(
            expected.RootElement.EnumerateObject().Select(p => (p.Name, p.Value.ToString())).OrderBy(p => p.Name),
            ours.RootElement.EnumerateObject().Select(p => (p.Name, p.Value.ToString())).OrderBy(p => p.Name));
        // Without the environment, those keys are left out rather than sent as null.
        using var bare = JsonDocument.Parse(PcStatsMessage.Json(new MoveSecond(1, 0, 0, 0, 0, 0), null));
        Assert.False(bare.RootElement.TryGetProperty("link", out _));
    }

    [Fact]
    public void ParsesTheMacsQualityReport()
    {
        var info = QualityInfo.Parse(Fixture("quality-report.json"));
        Assert.NotNull(info);
        Assert.Equal("fair", info!.Grade);
        Assert.Equal(4.3, info.HitchesPerMin!.Network);
        Assert.Equal(2, info.Tips!.Count);
        Assert.Equal("act", info.Tips[0].Status);
        Assert.Equal(2, info.Tips[0].Steps.Count);
        Assert.Null(QualityInfo.Parse("{\"grade\":\"smooth\",\"movingSeconds\":5}"u8.ToArray())!.Tips);
    }
}

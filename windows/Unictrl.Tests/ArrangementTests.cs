using System.Text.Json;
using Xunit;
namespace Unictrl.Tests;
public class ArrangementTests
{
    private static ArrangementInfo Row() => new("pc", [new("mac", "Mac", 300, 200, 0, true, LayoutVersion: 2), new("pc", "PC", 400, 250, 0, true, LayoutVersion: 2)]);
    [Theory]
    [InlineData(ScreenEdge.Top, 0, -225)]
    [InlineData(ScreenEdge.Bottom, 0, 225)]
    [InlineData(ScreenEdge.Left, -350, 0)]
    [InlineData(ScreenEdge.Right, 350, 0)]
    public void PresetsAttachToAllFourSides(ScreenEdge edge, double x, double y)
    {
        var layout = Row().Place("pc", edge);
        var pc = layout.Screens.Single(s => s.Id == "pc");
        Assert.Equal(x, pc.XMm); Assert.Equal(y, pc.YMm);
        var opposite = edge switch { ScreenEdge.Top => ScreenEdge.Bottom, ScreenEdge.Bottom => ScreenEdge.Top, ScreenEdge.Left => ScreenEdge.Right, _ => ScreenEdge.Left };
        Assert.True(layout.CanExit(opposite, 0));
        Assert.False(layout.CanExit(edge, 0));
    }
    [Fact] public void DraggingMacWorks()
    {
        var layout = Row().Drop("mac", 350, 225);
        var pc = layout.Screens.Single(s => s.Id == "pc");
        Assert.Equal(0, pc.XMm); Assert.Equal(-225, pc.YMm);
        Assert.Equal(0, layout.Screens.Single(s => s.IsMac).XMm);
    }
    [Fact] public void ExitOnlyUsesSharedEdge()
    {
        var above = Row().Place("pc", ScreenEdge.Top);
        Assert.True(above.CanExit(ScreenEdge.Bottom, 75));
        Assert.False(above.CanExit(ScreenEdge.Bottom, 175));
        Assert.False(above.CanExit(ScreenEdge.Left, 0));
    }
    [Fact] public void OfflineScreensDoNotAcceptPointer()
    {
        var above = Row().Place("pc", ScreenEdge.Top);
        above = above with { Screens = above.Screens.Select(s => s with { Online = !s.IsMac }).ToList() };
        Assert.False(above.CanExit(ScreenEdge.Bottom, 0));
    }
    [Theory]
    [InlineData(ScreenEdge.Top, 1160, 1)]
    [InlineData(ScreenEdge.Bottom, 1160, 1078)]
    [InlineData(ScreenEdge.Left, 1, 740)]
    [InlineData(ScreenEdge.Right, 1918, 740)]
    public void EntryMapsAlongCoordinateOnCorrectAxis(ScreenEdge edge, double x, double y)
    {
        var entry = ArrangementInfo.EntryPoint(new(0, 0, 1920, 1080), 8, edge, 25);
        Assert.Equal(x, entry.X); Assert.Equal(y, entry.Y);
    }
    [Fact] public void EditCarriesTwoDimensionalCoordinates()
    {
        using var doc = JsonDocument.Parse(ArrangementInfo.Edit(["pc", "mac"], new Dictionary<string, double> { ["pc"] = -225 },
            new Dictionary<string, ScreenPosition> { ["pc"] = new(0, -225) }));
        Assert.Equal(-225, doc.RootElement.GetProperty("positions").GetProperty("pc").GetProperty("y").GetDouble());
    }
}

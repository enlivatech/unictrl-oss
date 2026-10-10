using System.Text.Json;
using Xunit;

namespace Unictrl.Tests;

/// The JSON the Mac sends and expects (tests/contract, also checked by the Swift tests).
public class ContractTests
{
    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "contract", name));

    [Fact]
    public void ParsesTheMacsArrangement()
    {
        var info = ArrangementInfo.Parse(Fixture("arrangement-message.json"));
        Assert.NotNull(info);
        Assert.Equal("7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B", info!.You);
        Assert.Equal(3, info.Screens.Count);
        Assert.True(info.Screens[0].IsMac);
        Assert.Equal(-12.5, info.Screens[1].OffsetMm);
        Assert.Equal(291.2, info.Screens[1].WidthMm);
        Assert.False(info.Screens[2].Online);
    }

    [Fact]
    public void EditHasTheShapeTheMacDecodes()
    {
        var order = new[] { "7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B", "mac", "3E9F0A12-6B7C-4D8E-8F90-1A2B3C4D5E6F" };
        var offsets = new Dictionary<string, double>
        {
            ["7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B"] = -12.5,
            ["3E9F0A12-6B7C-4D8E-8F90-1A2B3C4D5E6F"] = 30,
        };
        using var ours = JsonDocument.Parse(ArrangementInfo.Edit(order, offsets));
        using var expected = JsonDocument.Parse(Fixture("arrangement-edit.json"));
        Assert.Equal(
            expected.RootElement.GetProperty("order").EnumerateArray().Select(e => e.GetString()),
            ours.RootElement.GetProperty("order").EnumerateArray().Select(e => e.GetString()));
        var expectedOffsets = expected.RootElement.GetProperty("offsets").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetDouble());
        var ourOffsets = ours.RootElement.GetProperty("offsets").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetDouble());
        Assert.Equal(expectedOffsets, ourOffsets);
    }

    [Fact]
    public void RenameHasTheShapeTheMacDecodes()
    {
        using var ours = JsonDocument.Parse(ArrangementInfo.Rename("7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B", "Surface"));
        using var expected = JsonDocument.Parse(Fixture("rename-request.json"));
        Assert.Equal(expected.RootElement.GetProperty("id").GetString(), ours.RootElement.GetProperty("id").GetString());
        Assert.Equal(expected.RootElement.GetProperty("name").GetString(), ours.RootElement.GetProperty("name").GetString());
    }

    [Fact]
    public void RejectsGarbage() => Assert.Null(ArrangementInfo.Parse("{not json"u8.ToArray()));
}

public class KeyTableTests
{
    [Theory]
    [InlineData(0x04, "mac-positions", 0x1E, false)] // A
    [InlineData(0x28, "mac-positions", 0x1C, false)] // Return
    [InlineData(0x39, "mac-positions", 0x3A, false)] // Caps Lock (the injector sends it as a state)
    public void MapsKeyboardUsages(ushort usage, string profile, ushort scan, bool extended)
    {
        Assert.True(KeyTable.TryGetScanCode(usage, profile, out var code, out var ext));
        Assert.Equal(scan, code);
        Assert.Equal(extended, ext);
    }

    [Theory]
    [InlineData(0xE9, 0xAF)] // volume up
    [InlineData(0xEA, 0xAE)] // volume down
    [InlineData(0xE2, 0xAD)] // mute
    [InlineData(0xCD, 0xB3)] // play/pause
    [InlineData(0xB5, 0xB0)] // next
    [InlineData(0xB6, 0xB1)] // previous
    public void MapsMediaKeys(ushort usage, ushort virtualKey) => Assert.Equal(virtualKey, KeyTable.Consumer[usage]);

    [Fact]
    public void BrightnessIsNotAVirtualKey()
    {
        // 0x6F/0x70 are handled by Brightness (WMI) before the consumer table is consulted.
        Assert.False(KeyTable.Consumer.ContainsKey(0x6F));
        Assert.False(KeyTable.Consumer.ContainsKey(0x70));
    }
}

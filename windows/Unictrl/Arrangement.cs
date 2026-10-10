using System.Text.Json;

namespace Unictrl;

/// One screen in the row, as the Mac describes it.
public sealed record ScreenInfo(string Id, string Name, double WidthMm, double HeightMm, double OffsetMm, bool Online)
{
    public bool IsMac => Id == ArrangementInfo.Mac;
}

/// The screens left to right, sent by the Mac (whose copy is authoritative). `You` is this PC's ID.
public sealed record ArrangementInfo(string You, List<ScreenInfo> Screens)
{
    public const string Mac = "mac";
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static ArrangementInfo? Parse(byte[] json)
    {
        try { return JsonSerializer.Deserialize<ArrangementInfo>(json, Options); }
        catch (JsonException) { return null; }
    }

    /// A new name for a screen ("mac" or a PC's ID); empty goes back to the computer's own name.
    public static byte[] Rename(string id, string name) =>
        JsonSerializer.SerializeToUtf8Bytes(new { id, name }, Options);

    /// The edit the Mac expects: the order of IDs and each PC's offset below the Mac's centre in mm.
    public static byte[] Edit(IEnumerable<string> order, IReadOnlyDictionary<string, double> offsets) =>
        JsonSerializer.SerializeToUtf8Bytes(new { order = order.ToList(), offsets }, Options);
}

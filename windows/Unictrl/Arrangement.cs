using System.Text.Json;

namespace Unictrl;

public enum ScreenEdge : byte { Left = 0, Right = 1, Top = 2, Bottom = 3 }
public sealed record ScreenPosition(double X, double Y);
public readonly record struct ScreenRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double CenterX => X + Width / 2;
    public double CenterY => Y + Height / 2;
}

public sealed record ScreenInfo(string Id, string Name, double WidthMm, double HeightMm, double OffsetMm, bool Online,
    double? XMm = null, double? YMm = null, int LayoutVersion = 1)
{
    public bool IsMac => Id == ArrangementInfo.Mac;
}

/// The Mac saves the authoritative layout. Old messages describe a horizontal row.
public sealed record ArrangementInfo(string You, List<ScreenInfo> Screens)
{
    public const string Mac = "mac";
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
    public bool Supports2D => Screens.All(s => s.LayoutVersion >= 2);
    public static ArrangementInfo? Parse(byte[] json)
    {
        try { return JsonSerializer.Deserialize<ArrangementInfo>(json, Options); }
        catch (JsonException) { return null; }
    }
    public static byte[] Rename(string id, string name) => JsonSerializer.SerializeToUtf8Bytes(new { id, name }, Options);
    public static byte[] Edit(IEnumerable<string> order, IReadOnlyDictionary<string, double> offsets,
        IReadOnlyDictionary<string, ScreenPosition>? positions = null) =>
        JsonSerializer.SerializeToUtf8Bytes(new { order = order.ToList(), offsets, positions = positions ?? new Dictionary<string, ScreenPosition>() }, Options);

    public Dictionary<string, ScreenRect> Rectangles()
    {
        var x = 0.0;
        var result = new Dictionary<string, ScreenRect>();
        foreach (var s in Screens) { result[s.Id] = new(x, s.OffsetMm - s.HeightMm / 2, s.WidthMm, s.HeightMm); x += s.WidthMm; }
        var anchor = result.GetValueOrDefault(Mac).CenterX;
        foreach (var s in Screens)
        {
            var r = result[s.Id];
            result[s.Id] = new((s.XMm ?? (r.CenterX - anchor)) - r.Width / 2,
                (s.YMm ?? s.OffsetMm) - r.Height / 2, r.Width, r.Height);
        }
        return result;
    }

    public static bool Touches(ScreenRect a, ScreenRect b, ScreenEdge edge)
    {
        var horizontal = edge is ScreenEdge.Left or ScreenEdge.Right;
        var gap = edge switch { ScreenEdge.Left => Math.Abs(a.X - b.Right), ScreenEdge.Right => Math.Abs(a.Right - b.X),
            ScreenEdge.Top => Math.Abs(a.Y - b.Bottom), _ => Math.Abs(a.Bottom - b.Y) };
        var overlap = horizontal ? Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y) : Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X);
        var minOverlap = Math.Min(30, horizontal ? Math.Min(a.Height, b.Height) : Math.Min(a.Width, b.Width));
        return gap < 0.25 && overlap >= minOverlap - 0.25;
    }

    public bool CanExit(ScreenEdge edge, double alongMm)
    {
        var rects = Rectangles();
        if (!rects.TryGetValue(You, out var me)) return false;
        var horizontal = edge is ScreenEdge.Left or ScreenEdge.Right;
        var along = alongMm + (horizontal ? me.CenterY : me.CenterX);
        return Screens.Any(s => s.Id != You && s.Online && Touches(me, rects[s.Id], edge) &&
            (horizontal ? along >= rects[s.Id].Y && along < rects[s.Id].Bottom : along >= rects[s.Id].X && along < rects[s.Id].Right));
    }

    public ArrangementInfo Place(string id, ScreenEdge edge)
    {
        var rects = Rectangles();
        if (!rects.TryGetValue(id, out var moved) || !rects.TryGetValue(Mac, out var mac)) return this;
        var x = edge switch { ScreenEdge.Left => mac.X - moved.Width / 2, ScreenEdge.Right => mac.Right + moved.Width / 2, _ => mac.CenterX };
        var y = edge switch { ScreenEdge.Top => mac.Y - moved.Height / 2, ScreenEdge.Bottom => mac.Bottom + moved.Height / 2, _ => mac.CenterY };
        return Drop(id, x, y);
    }

    public ArrangementInfo Drop(string id, double centerX, double centerY)
    {
        var rects = Rectangles();
        if (!rects.TryGetValue(id, out var moved) || rects.Count < 2) return this;
        ScreenRect? best = null;
        var score = double.PositiveInfinity;
        foreach (var other in Screens.Where(s => s.Id != id))
        foreach (var side in Enum.GetValues<ScreenEdge>())
        {
            var n = rects[other.Id];
            var horizontal = side is ScreenEdge.Left or ScreenEdge.Right;
            var along = horizontal ? centerY : centerX;
            var center = horizontal ? n.CenterY : n.CenterX;
            var length = horizontal ? moved.Height : moved.Width;
            var theirs = horizontal ? n.Height : n.Width;
            var limit = (length + theirs) / 2 - Math.Min(30, Math.Min(length, theirs));
            var offset = Math.Clamp(along, center - limit, center + limit);
            foreach (var snap in new[] { center, center - (theirs - length) / 2, center + (theirs - length) / 2 })
                if (Math.Abs(offset - snap) < 6) { offset = snap; break; }
            var r = side switch {
                ScreenEdge.Left => new ScreenRect(n.X - moved.Width, offset - moved.Height / 2, moved.Width, moved.Height),
                ScreenEdge.Right => new ScreenRect(n.Right, offset - moved.Height / 2, moved.Width, moved.Height),
                ScreenEdge.Top => new ScreenRect(offset - moved.Width / 2, n.Y - moved.Height, moved.Width, moved.Height),
                _ => new ScreenRect(offset - moved.Width / 2, n.Bottom, moved.Width, moved.Height) };
            if (rects.Any(kv => kv.Key != id && Math.Min(r.Right, kv.Value.Right) - Math.Max(r.X, kv.Value.X) > 0.25 &&
                Math.Min(r.Bottom, kv.Value.Bottom) - Math.Max(r.Y, kv.Value.Y) > 0.25)) continue;
            var all = new Dictionary<string, ScreenRect>(rects) { [id] = r };
            if (!Connected(all)) continue;
            var distance = Math.Pow(r.CenterX - centerX, 2) + Math.Pow(r.CenterY - centerY, 2);
            if (distance < score) { best = r; score = distance; }
        }
        if (best is not { } chosen) return this;
        rects[id] = chosen;
        var anchor = rects[Mac];
        return this with { Screens = Screens.OrderBy(s => rects[s.Id].CenterX).ThenBy(s => rects[s.Id].CenterY)
            .Select(s => s with { XMm = Math.Round(rects[s.Id].CenterX - anchor.CenterX, 1),
                YMm = Math.Round(rects[s.Id].CenterY - anchor.CenterY, 1), OffsetMm = Math.Round(rects[s.Id].CenterY - anchor.CenterY, 1) }).ToList() };
    }

    private static bool Connected(Dictionary<string, ScreenRect> rects)
    {
        var seen = new HashSet<string>();
        var queue = new Stack<string>();
        queue.Push(rects.Keys.First());
        while (queue.TryPop(out var id))
        {
            if (!seen.Add(id)) continue;
            foreach (var (other, r) in rects)
                if (!seen.Contains(other) && Enum.GetValues<ScreenEdge>().Any(side => Touches(rects[id], r, side))) queue.Push(other);
        }
        return seen.Count == rects.Count;
    }

    /// Same coordinate convention as the wire: along-edge mm (Y on left/right, X on top/bottom).
    public static (double X, double Y) EntryPoint(ScreenRect bounds, double pixelsPerMm, ScreenEdge edge, double alongMm) => edge switch {
        ScreenEdge.Left => (bounds.X + 1, Math.Clamp(bounds.CenterY + alongMm * pixelsPerMm, bounds.Y, bounds.Bottom - 1)),
        ScreenEdge.Right => (bounds.Right - 2, Math.Clamp(bounds.CenterY + alongMm * pixelsPerMm, bounds.Y, bounds.Bottom - 1)),
        ScreenEdge.Top => (Math.Clamp(bounds.CenterX + alongMm * pixelsPerMm, bounds.X, bounds.Right - 1), bounds.Y + 1),
        _ => (Math.Clamp(bounds.CenterX + alongMm * pixelsPerMm, bounds.X, bounds.Right - 1), bounds.Bottom - 2) };
}

import SwiftUI

extension Color {
    /// Unictrl's pine green, the icon's gradient ends (#0B5550 → #26957F).
    static let pineDeep = Color(red: 0.043, green: 0.333, blue: 0.314)
    static let pine = Color(red: 0.149, green: 0.584, blue: 0.498)
    /// Text on the light pine tiles.
    static let pineInk = Color(red: 0.043, green: 0.290, blue: 0.251)  // #0B4A40
    static let pineGradient = LinearGradient(colors: [.pineDeep, .pine], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Connected screens the pointer is not on: a lighter pine, so they still read as connected.
    static let pineLightGradient = LinearGradient(colors: [Color(red: 0.365, green: 0.718, blue: 0.631),   // #5DB7A1
                                                           Color(red: 0.553, green: 0.820, blue: 0.749)],  // #8DD1BF
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// One screen as the canvas draws it.
struct ScreenTile: Identifiable, Equatable {
    let id: String
    var name: String
    var sizeMm: CGSize
    var online: Bool
    var isMac: Bool { id == Arrangement.mac }
}

/// The screens in a row at their real physical sizes, like the Displays pane in System Settings.
/// When `onCommit` is set, PCs can be dragged: left or right to change the order, up or down to line
/// their screens up with their neighbours. The Mac stays put; everything is placed relative to it.
struct ScreensCanvas: View {
    var tiles: [ScreenTile]
    var arrangement: Arrangement
    /// The screen the pointer is on.
    var activeID: String = Arrangement.mac
    var compact = false
    var onCommit: ((Arrangement) -> Void)?

    @State private var dragging: String?
    @State private var translation: CGSize = .zero

    /// Screens that share less than this height could not pass the pointer comfortably.
    private static let minOverlapMm = 30.0

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(tiles: tiles, arrangement: arrangement, in: geometry.size, padding: compact ? 6 : 14)
            ZStack(alignment: .topLeading) {
                ForEach(layout.frames, id: \.id) { item in
                    let isDragged = dragging == item.id
                    tile(item.tile, rect: item.rect.offsetBy(dx: isDragged ? translation.width : 0,
                                                             dy: isDragged ? translation.height : 0),
                         lifted: isDragged)
                        .zIndex(isDragged ? 1 : 0)
                        .gesture(onCommit == nil || item.tile.isMac ? nil : drag(item.id, layout: layout))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func drag(_ id: String, layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragging = id
                translation = value.translation
            }
            .onEnded { value in
                let result = layout.drop(id, by: value.translation, in: arrangement)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    dragging = nil
                    translation = .zero
                    onCommit?(result)
                }
            }
    }

    private func tile(_ tile: ScreenTile, rect: CGRect, lifted: Bool) -> some View {
        let active = tile.id == activeID
        let green = active || tile.online
        let ink: Color = active ? .white : tile.online ? .pineInk : .primary
        let radius: CGFloat = compact ? 4 : 8
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(active ? AnyShapeStyle(Color.pineGradient)
                      : tile.online ? AnyShapeStyle(Color.pineLightGradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                .shadow(color: .black.opacity(lifted ? 0.28 : 0.12), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(active ? Color.white.opacity(0.18) : green ? Color.pineInk.opacity(0.12) : Color.primary.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1, dash: tile.online ? [] : [3, 3]))
            if compact {
                Image(systemName: tile.isMac ? "macbook" : "display")
                    .font(.system(size: min(rect.height * 0.42, 15), weight: .medium))
                    .foregroundStyle(green ? ink : Color.secondary)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: tile.isMac ? "macbook" : "display")
                        .font(.system(size: 18, weight: .regular))
                        .padding(.bottom, 2)
                    Text(tile.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(tile.online ? String(format: "%.0f × %.0f cm", tile.sizeMm.width / 10, tile.sizeMm.height / 10) : "Offline")
                        .font(.system(size: 10)).opacity(0.7)
                }
                .foregroundStyle(ink)
                .padding(8)
            }
        }
        .opacity(tile.online || active ? 1 : 0.6)
        .frame(width: rect.width - 3, height: rect.height - 3)
        .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
        .contentShape(Rectangle())
    }

    /// Millimetre layout scaled to the view: screens edge to edge in order, each centred at its offset.
    struct Layout {
        struct Item { let id: String; let tile: ScreenTile; let rect: CGRect }
        let frames: [Item]
        let scale: CGFloat
        private let sizes: [String: CGSize]

        init(tiles: [ScreenTile], arrangement: Arrangement, in size: CGSize, padding: CGFloat) {
            let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = arrangement.order.compactMap { byID[$0] }
            sizes = byID.mapValues(\.sizeMm)
            var x = 0.0
            var mm: [(ScreenTile, CGRect)] = []
            for tile in ordered {
                let offset = arrangement.offset(of: tile.id)
                mm.append((tile, CGRect(x: x, y: offset - tile.sizeMm.height / 2, width: tile.sizeMm.width, height: tile.sizeMm.height)))
                x += tile.sizeMm.width
            }
            let bounds = mm.reduce(CGRect.null) { $0.union($1.1) }
            guard !bounds.isNull else { frames = []; scale = 1; return }
            // Leave room for a screen dragged a little past the ends.
            let s = min((size.width - 2 * padding) / bounds.width, (size.height - 2 * padding) / max(bounds.height, 200))
            scale = s
            let origin = CGPoint(x: (size.width - bounds.width * s) / 2 - bounds.minX * s,
                                 y: (size.height - bounds.height * s) / 2 - bounds.minY * s)
            frames = mm.map { tile, rect in
                Item(id: tile.id, tile: tile, rect: CGRect(x: origin.x + rect.minX * s, y: origin.y + rect.minY * s,
                                                           width: rect.width * s, height: rect.height * s))
            }
        }

        /// The arrangement after dropping `id` moved by `translation` points.
        func drop(_ id: String, by translation: CGSize, in arrangement: Arrangement) -> Arrangement {
            guard let moved = frames.first(where: { $0.id == id }) else { return arrangement }
            let centerX = moved.rect.midX + translation.width
            var result = arrangement
            result.order.removeAll { $0 == id }
            let others = frames.filter { $0.id != id }
            let index = others.firstIndex { centerX < $0.rect.midX } ?? others.count
            result.order.insert(id, at: index)

            // Height relative to the Mac, kept so it shares enough edge with each neighbour.
            var offset = arrangement.offset(of: id) + translation.height / scale
            let height = sizes[id]?.height ?? 190
            for side in [Side.left, .right] {
                guard let neighbor = result.neighbor(of: id, on: side) else { continue }
                let theirs = result.offset(of: neighbor)
                let limit = max(0, (height + (sizes[neighbor]?.height ?? 190)) / 2 - ScreensCanvas.minOverlapMm)
                offset = min(theirs + limit, max(theirs - limit, offset))
                if abs(offset - theirs) < 6 { offset = theirs } // snap to centred
            }
            result.offsets[id] = (offset * 10).rounded() / 10
            return result
        }
    }
}

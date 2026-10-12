import Foundation
import CoreGraphics

struct ScreenPosition: Codable, Equatable {
    var x: Double
    var y: Double
}

extension Arrangement {
    func rectangles(sizes: [String: CGSize]) -> [String: CGRect] {
        var x = 0.0
        var legacy: [String: CGRect] = [:]
        for id in order {
            let s = sizes[id] ?? CGSize(width: 290, height: 193)
            legacy[id] = CGRect(x: x, y: offset(of: id) - s.height / 2, width: s.width, height: s.height)
            x += s.width
        }
        let macX = legacy[Self.mac]?.midX ?? 0
        return legacy.mapValues { $0.offsetBy(dx: -macX, dy: 0) }.mapWithKey { id, rect in
            guard id != Self.mac, let p = positions[id] else { return rect }
            return CGRect(x: p.x - rect.width / 2, y: p.y - rect.height / 2, width: rect.width, height: rect.height)
        }
    }

    static func touches(_ a: CGRect, _ b: CGRect, on side: Side) -> Bool {
        let gap: Double
        switch side {
        case .left: gap = abs(a.minX - b.maxX)
        case .right: gap = abs(a.maxX - b.minX)
        case .top: gap = abs(a.minY - b.maxY)
        case .bottom: gap = abs(a.maxY - b.minY)
        }
        let overlap = side.horizontal ? min(a.maxY, b.maxY) - max(a.minY, b.minY)
                                     : min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return gap < 0.25 && overlap >= min(30, side.horizontal ? min(a.height, b.height) : min(a.width, b.width)) - 0.25
    }

    func neighbors(of id: String, on side: Side, sizes: [String: CGSize], coordinate: Double? = nil) -> [String] {
        let rects = rectangles(sizes: sizes)
        guard let a = rects[id] else { return [] }
        return order.filter { other in
            guard other != id, let b = rects[other], Self.touches(a, b, on: side) else { return false }
            guard let coordinate else { return true }
            return side.horizontal ? coordinate >= b.minY && coordinate < b.maxY : coordinate >= b.minX && coordinate < b.maxX
        }
    }

    /// Snap to a shared edge; moving the Mac changes the other screens relative to it.
    func placing(_ id: String, at point: CGPoint, sizes: [String: CGSize]) -> Arrangement {
        let rects = rectangles(sizes: sizes)
        guard let moved = rects[id], rects.count > 1 else { return self }
        var best: CGRect?
        var bestScore = Double.infinity
        for other in order where other != id {
            guard let neighbor = rects[other] else { continue }
            for side in Side.allCases {
                let along = side.horizontal ? point.y : point.x
                let center = side.horizontal ? neighbor.midY : neighbor.midX
                let length = side.horizontal ? moved.height : moved.width
                let theirs = side.horizontal ? neighbor.height : neighbor.width
                let limit = (length + theirs) / 2 - min(30, length, theirs)
                var offset = min(center + limit, max(center - limit, along))
                for snap in [center, center - (theirs - length) / 2, center + (theirs - length) / 2] {
                    if abs(offset - snap) < 6 { offset = snap; break }
                }
                var candidate = moved
                switch side {
                case .left: candidate.origin = CGPoint(x: neighbor.minX - moved.width, y: offset - moved.height / 2)
                case .right: candidate.origin = CGPoint(x: neighbor.maxX, y: offset - moved.height / 2)
                case .top: candidate.origin = CGPoint(x: offset - moved.width / 2, y: neighbor.minY - moved.height)
                case .bottom: candidate.origin = CGPoint(x: offset - moved.width / 2, y: neighbor.maxY)
                }
                if rects.contains(where: { key, r in key != id && candidate.intersection(r).width > 0.25 && candidate.intersection(r).height > 0.25 }) { continue }
                var all = rects
                all[id] = candidate
                guard Self.connected(all) else { continue }
                let score = pow(candidate.midX - point.x, 2) + pow(candidate.midY - point.y, 2)
                if score < bestScore { best = candidate; bestScore = score }
            }
        }
        guard let best else { return self }
        var all = rects
        all[id] = best
        let anchor = all[Self.mac]!
        var result = self
        result.positions = all.filter { $0.key != Self.mac }.mapValues {
            ScreenPosition(x: (($0.midX - anchor.midX) * 10).rounded() / 10,
                           y: (($0.midY - anchor.midY) * 10).rounded() / 10)
        }
        result.offsets = result.positions.mapValues(\.y)
        result.order.sort { a, b in
            let p = all[a]!, q = all[b]!
            return abs(p.midX - q.midX) > 0.1 ? p.midX < q.midX : p.midY < q.midY
        }
        return result
    }

    static func connected(_ rects: [String: CGRect]) -> Bool {
        guard let first = rects.keys.first else { return true }
        var seen: Set<String> = [first]
        var queue = [first]
        while let id = queue.popLast() {
            for (other, rect) in rects where !seen.contains(other) {
                if Side.allCases.contains(where: { touches(rects[id]!, rect, on: $0) }) { seen.insert(other); queue.append(other) }
            }
        }
        return seen.count == rects.count
    }
}

private extension Dictionary {
    func mapWithKey<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}

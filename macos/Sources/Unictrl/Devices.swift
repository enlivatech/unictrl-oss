import Foundation

/// A Windows PC paired with this Mac.
struct PeerConfig: Codable, Equatable, Identifiable {
    /// The PC's device UUID. "" marks a PC paired before device IDs existed; it gets its ID the
    /// first time it connects with the new handshake.
    var id: String
    /// The name the PC reports (its computer name); also matched against the keyboard's Easy-Switch hosts.
    var name: String
    /// A name the user chose, shown instead of `name`.
    var alias: String?
    var pairingKey: String
    /// Physical size of the PC's screen, as it last reported.
    var widthMm = 290.0
    var heightMm = 193.0
    /// Easy-Switch channels (0-based) of this PC on the keyboard and mouse, as the PC last reported.
    var keyboardHost: Int?
    var mouseHost: Int?
}

enum Side: UInt8, CaseIterable {
    case left = 0, right = 1, top = 2, bottom = 3
    var horizontal: Bool { self == .left || self == .right }
    var opposite: Side {
        switch self { case .left: return .right; case .right: return .left; case .top: return .bottom; case .bottom: return .top }
    }
}

/// The screens as a row, left to right, with each PC's vertical position. The Mac is "mac" and sits
/// at offset 0; a PC's offset is how far its screen centre is below the Mac's, in millimetres.
struct Arrangement: Codable, Equatable {
    static let mac = "mac"
    var order = [Arrangement.mac]
    var offsets: [String: Double] = [:]
    /// Screen centres in millimetres, with the Mac at (0, 0). Absent in old row layouts.
    var positions: [String: ScreenPosition] = [:]
    init(order: [String] = [Arrangement.mac], offsets: [String: Double] = [:], positions: [String: ScreenPosition] = [:]) {
        self.order = order; self.offsets = offsets; self.positions = positions
    }

    private enum CodingKeys: String, CodingKey { case order, offsets, positions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode([String].self, forKey: .order)
        offsets = try c.decodeIfPresent([String: Double].self, forKey: .offsets) ?? [:]
        positions = try c.decodeIfPresent([String: ScreenPosition].self, forKey: .positions) ?? [:]
    }


    func offset(of id: String) -> Double { id == Self.mac ? 0 : offsets[id] ?? 0 }

    /// The screen next to `id` on `side`, if any.
    func neighbor(of id: String, on side: Side) -> String? {
        guard side.horizontal else { return nil }
        guard let i = order.firstIndex(of: id) else { return nil }
        let j = side == .right ? i + 1 : i - 1
        return order.indices.contains(j) ? order[j] : nil
    }

    /// Adds a newly paired PC at the right end of the row.
    mutating func add(_ id: String) {
        guard !order.contains(id) else { return }
        order.append(id)
        offsets[id] = offsets[id] ?? 0
    }

    mutating func remove(_ id: String) {
        order.removeAll { $0 == id }
        offsets[id] = nil
        positions[id] = nil
    }

    /// The side of `id` the Mac is on (nil for the Mac itself or an unknown screen).
    func macSide(from id: String) -> Side? {
        if let p = positions[id] {
            return abs(p.x) > abs(p.y) ? (p.x > 0 ? .left : .right) : (p.y > 0 ? .top : .bottom)
        }
        guard let here = order.firstIndex(of: id), let mac = order.firstIndex(of: Self.mac), here != mac else { return nil }
        return mac < here ? .left : .right
    }

    /// Keeps the Mac and exactly the given PCs, each once, in their current order.
    mutating func normalize(peers: [String]) {
        var seen = Set<String>()
        order = order.filter { ($0 == Self.mac || peers.contains($0)) && seen.insert($0).inserted }
        if !order.contains(Self.mac) { order.insert(Self.mac, at: 0) }
        for id in peers where !order.contains(id) { add(id) }
        offsets = offsets.filter { peers.contains($0.key) }
        positions = positions.filter { peers.contains($0.key) && $0.value.x.isFinite && $0.value.y.isFinite }
    }

    mutating func rename(_ old: String, to new: String) {
        if let i = order.firstIndex(of: old) { order[i] = new }
        if let value = offsets.removeValue(forKey: old) { offsets[new] = value }
        if let value = positions.removeValue(forKey: old) { positions[new] = value }
    }
}

extension PeerConfig {
    var displayName: String { alias ?? name }
}

/// PC → Mac (0x07): the user renamed a screen on the PC. An empty name goes back to the default.
struct RenameRequest: Codable {
    var id: String
    var name: String
}

/// Sent to v2 PCs so they can show and edit the arrangement. The Mac's copy is authoritative.
struct ArrangementMessage: Codable {
    struct Screen: Codable {
        var id: String
        var name: String
        var widthMm: Double
        var heightMm: Double
        var offsetMm: Double
        var online: Bool
        var xMm: Double? = nil
        var yMm: Double? = nil
        var layoutVersion: Int? = 2
    }
    /// The receiving PC's ID.
    var you: String
    /// Left to right.
    var screens: [Screen]
}

/// What the pointer needs to know about the PC it is crossing to.
struct RemoteTarget {
    let id: String
    let offsetMm: Double
    var xMm = 0.0
    var widthMm = 290.0
    var heightMm = 193.0
    /// Edges of that PC's screen that lead on to another screen.
    let openLeft: Bool
    let openRight: Bool
    var openTop = false
    var openBottom = false
}

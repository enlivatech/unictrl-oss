import Foundation

/// ~/Library/Application Support/Unictrl/settings.json. Kept out of Git: it holds the pairing keys.
struct UnictrlSettings: Codable {
    /// Paired PCs and where their screens sit.
    var peers: [PeerConfig] = []
    var arrangement = Arrangement()
    /// Before multi-device support: the single PC's key, side and offset. Migrated into `peers`.
    var pairingKey = ""
    /// Identifies this Mac in discovery replies and pairing; generated once.
    var deviceID = ""
    var port: UInt16 = 24860
    /// Before multi-device support: which side of the Mac the PC sat on, and how far its centre was below.
    var peerSide = "right"
    var verticalOffsetMm = 0.0
    /// Flip Windows scrolling relative to the Mac (nil = same direction as the Mac).
    var invertScroll: Bool?
    var scrollScale = 1.0
    /// Mouse wheel only (trackpads keep macOS natural scrolling), like Mos. Applies on the PC too.
    var reverseMouseWheel = true
    /// Turn wheel notches into short eased glides, on the Mac and on the PC.
    var smoothScrolling = true
    /// "native": Windows applies its own pointer speed and acceleration to raw mouse counts, like a
    /// mouse connected to it directly. "physical": Mac acceleration, converted by millimetres.
    var pointerMode = "native"
    /// Scales pointer movement sent to PCs (native mode: before Windows' own speed and acceleration).
    var pcPointerScale = 1.0
    /// Scales scrolling sent to PCs; `scrollScale` is the Mac's own.
    var pcScrollScale = 1.0
    var enabled = true
    /// Share only while the keyboard (or, without it, the mouse) is on this Easy-Switch channel
    /// (0-based); nil = on any. Other channels are for using the devices on one computer only.
    var shareChannel: Int?
    /// Play a sound when the keyboard and mouse are both back on the sharing channel.
    var readySound = true
    /// Which system alert sound (/System/Library/Sounds) plays.
    var readySoundName = "Glass"
    /// Send the keyboard and mouse to a PC (Easy-Switch) when this Mac sleeps; they come back on wake.
    var sleepHandoff = true
    /// Where Unictrl shows its icon. With both off, opening the app again shows Settings.
    var showMenuBarIcon = true
    var showDockIcon = false
    /// A name for this Mac chosen by the user, shown on every screen instead of the computer name.
    var macAlias: String?
    /// Set once Unictrl has registered itself as a login item on first launch.
    var loginItemConfigured = false
    /// Extra log lines for chasing pointer hitches (mouse statistics, main-thread stalls). Off by
    /// default; switched with the debug notification ("diagnostics-on", "diagnostics-off").
    var diagnostics = false

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Unictrl/settings.json")

    private enum CodingKeys: String, CodingKey {
        case pcPointerScale, pcScrollScale, shareChannel, readySound, readySoundName
        case peers, arrangement, pairingKey, deviceID, port, peerSide, verticalOffsetMm, invertScroll, scrollScale,
             reverseMouseWheel, smoothScrolling, pointerMode, enabled, sleepHandoff, showMenuBarIcon, showDockIcon,
             macAlias, loginItemConfigured, diagnostics
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peers = try c.decodeIfPresent([PeerConfig].self, forKey: .peers) ?? []
        arrangement = try c.decodeIfPresent(Arrangement.self, forKey: .arrangement) ?? Arrangement()
        pairingKey = try c.decodeIfPresent(String.self, forKey: .pairingKey) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 24860
        peerSide = try c.decodeIfPresent(String.self, forKey: .peerSide) ?? "right"
        verticalOffsetMm = try c.decodeIfPresent(Double.self, forKey: .verticalOffsetMm) ?? 0
        invertScroll = try c.decodeIfPresent(Bool.self, forKey: .invertScroll)
        scrollScale = try c.decodeIfPresent(Double.self, forKey: .scrollScale) ?? 1
        reverseMouseWheel = try c.decodeIfPresent(Bool.self, forKey: .reverseMouseWheel) ?? true
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? true
        pointerMode = try c.decodeIfPresent(String.self, forKey: .pointerMode) ?? "native"
        pcPointerScale = try c.decodeIfPresent(Double.self, forKey: .pcPointerScale) ?? 1
        pcScrollScale = try c.decodeIfPresent(Double.self, forKey: .pcScrollScale) ?? 1
        shareChannel = try c.decodeIfPresent(Int.self, forKey: .shareChannel)
        readySound = try c.decodeIfPresent(Bool.self, forKey: .readySound) ?? true
        readySoundName = try c.decodeIfPresent(String.self, forKey: .readySoundName) ?? "Glass"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sleepHandoff = try c.decodeIfPresent(Bool.self, forKey: .sleepHandoff) ?? true
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        macAlias = try c.decodeIfPresent(String.self, forKey: .macAlias)
        loginItemConfigured = try c.decodeIfPresent(Bool.self, forKey: .loginItemConfigured) ?? false
        diagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? false
    }

    /// Moves a pre-multi-device pairing into `peers` (its PC's ID is learned on its next connection).
    mutating func migrate() {
        guard peers.isEmpty, !pairingKey.isEmpty else { return }
        peers = [PeerConfig(id: "", name: "Windows PC", pairingKey: pairingKey)]
        arrangement.order = peerSide == "left" ? ["", Arrangement.mac] : [Arrangement.mac, ""]
        arrangement.offsets[""] = verticalOffsetMm
        pairingKey = ""
    }

    /// Makes the arrangement list the Mac and every paired PC exactly once.
    mutating func normalize() {
        arrangement.normalize(peers: peers.map(\.id))
    }

    static func load() -> UnictrlSettings {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(UnictrlSettings.self, from: data) else {
            return UnictrlSettings()
        }
        return value
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        }
    }
}

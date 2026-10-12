import CoreGraphics
import Foundation
import Testing
@testable import Unictrl

@Suite struct ArrangementTests {
    @Test func neighbours() {
        let row = Arrangement(order: ["a", Arrangement.mac, "b", "c"], offsets: ["a": 10])
        #expect(row.neighbor(of: Arrangement.mac, on: .left) == "a")
        #expect(row.neighbor(of: Arrangement.mac, on: .right) == "b")
        #expect(row.neighbor(of: "c", on: .right) == nil)
        #expect(row.neighbor(of: "a", on: .left) == nil)
        #expect(row.neighbor(of: "missing", on: .left) == nil)
        #expect(row.offset(of: "a") == 10)
        #expect(row.offset(of: "b") == 0)
        #expect(row.offset(of: Arrangement.mac) == 0)
    }

    @Test func macSideDecidesTheWayHome() {
        let row = Arrangement(order: ["a", Arrangement.mac, "b", "c"])
        #expect(row.macSide(from: "a") == .right)
        #expect(row.macSide(from: "c") == .left) // past "b", even if "b" is offline
        #expect(row.macSide(from: Arrangement.mac) == nil)
        #expect(row.macSide(from: "missing") == nil)
    }

    @Test func addRemoveRename() {
        var row = Arrangement()
        row.add("a")
        row.add("a")
        #expect(row.order == [Arrangement.mac, "a"])
        row.offsets["a"] = 5
        row.rename("a", to: "b")
        #expect(row.order == [Arrangement.mac, "b"])
        #expect(row.offsets == ["b": 5])
        row.remove("b")
        #expect(row.order == [Arrangement.mac])
        #expect(row.offsets.isEmpty)
    }

    @Test func normalizeKeepsMacAndEachPeerOnce() {
        var row = Arrangement(order: ["x", "a", "a", "gone"], offsets: ["gone": 3, "a": 1])
        row.normalize(peers: ["a", "b"])
        #expect(row.order == [Arrangement.mac, "a", "b"])
        #expect(row.offsets == ["a": 1, "b": 0])
    }

    @Test func migratesSinglePCSettings() {
        var settings = UnictrlSettings()
        settings.pairingKey = "k"
        settings.peerSide = "left"
        settings.verticalOffsetMm = 20
        settings.migrate()
        #expect(settings.peers.map(\.id) == [""])
        #expect(settings.peers.first?.pairingKey == "k")
        #expect(settings.arrangement.order == ["", Arrangement.mac])
        #expect(settings.arrangement.offset(of: "") == 20)
        #expect(settings.pairingKey.isEmpty)
        // Running it again changes nothing.
        let before = settings.arrangement
        settings.migrate()
        #expect(settings.arrangement == before)
    }
}

@Suite struct CanvasDropTests {
    private let tiles = [
        ScreenTile(id: Arrangement.mac, name: "Mac", sizeMm: CGSize(width: 300, height: 200), online: true),
        ScreenTile(id: "pc", name: "PC", sizeMm: CGSize(width: 300, height: 200), online: true),
    ]
    private let row = Arrangement(order: [Arrangement.mac, "pc"], offsets: ["pc": 0])

    private func layout() -> ScreensCanvas.Layout {
        ScreensCanvas.Layout(tiles: tiles, arrangement: row, in: CGSize(width: 640, height: 300), padding: 20)
    }

    @Test func droppingPastTheMacMovesThePCToTheLeft() {
        let layout = layout()
        let pc = layout.frames.first { $0.id == "pc" }!.rect
        let mac = layout.frames.first { $0.id == Arrangement.mac }!.rect
        let result = layout.drop("pc", by: CGSize(width: mac.midX - pc.midX - 10, height: 0), in: row)
        #expect(result.order == ["pc", Arrangement.mac])
    }

    @Test func smallVerticalMovesSnapToCentred() {
        let layout = layout()
        let result = layout.drop("pc", by: CGSize(width: 0, height: 5 * layout.scale), in: row)
        #expect(result.offset(of: "pc") == 0)
    }

    @Test func largeVerticalMovePlacesPCBelowMac() {
        let layout = layout()
        let result = layout.drop("pc", by: CGSize(width: 0, height: 500 * layout.scale), in: row)
        #expect(result.positions["pc"]?.y == 200)
        #expect(result.positions["pc"]?.x == 270)
    }
}

@Suite struct TwoDimensionalArrangementTests {
    private let sizes = [Arrangement.mac: CGSize(width: 300, height: 200), "pc": CGSize(width: 400, height: 250)]
    private let row = Arrangement(order: [Arrangement.mac, "pc"])

    @Test func aboveAndBelowUseSharedHorizontalEdge() {
        let above = row.placing("pc", at: CGPoint(x: 0, y: -225), sizes: sizes)
        #expect(above.positions["pc"] == ScreenPosition(x: 0, y: -225))
        #expect(above.neighbors(of: Arrangement.mac, on: .top, sizes: sizes) == ["pc"])
        #expect(above.neighbors(of: "pc", on: .bottom, sizes: sizes, coordinate: 75) == [Arrangement.mac])
        #expect(above.neighbors(of: "pc", on: .bottom, sizes: sizes, coordinate: 175).isEmpty)
        #expect(above.neighbors(of: Arrangement.mac, on: .left, sizes: sizes).isEmpty)
        let below = above.placing("pc", at: CGPoint(x: 0, y: 225), sizes: sizes)
        #expect(below.positions["pc"] == ScreenPosition(x: 0, y: 225))
        #expect(below.neighbors(of: Arrangement.mac, on: .bottom, sizes: sizes) == ["pc"])
    }

    @Test func draggingMacChangesRelativePosition() {
        let rect = row.rectangles(sizes: sizes)["pc"]!
        let moved = row.placing(Arrangement.mac, at: CGPoint(x: rect.midX, y: rect.midY + 225), sizes: sizes)
        #expect(moved.positions["pc"] == ScreenPosition(x: 0, y: -225))
        #expect(moved.rectangles(sizes: sizes)[Arrangement.mac]!.midX == 0)
    }

    @Test func oldSettingsDecodeAndNewPositionsRoundTrip() throws {
        let decoded = try JSONDecoder().decode(Arrangement.self, from: Data(#"{"order":["mac","pc"],"offsets":{"pc":20}}"#.utf8))
        #expect(decoded.positions.isEmpty)
        #expect(decoded.rectangles(sizes: sizes)["pc"]!.midY == 20)
        let above = row.placing("pc", at: CGPoint(x: 0, y: -225), sizes: sizes)
        #expect(try JSONDecoder().decode(Arrangement.self, from: JSONEncoder().encode(above)) == above)
    }

    @Test func draggingCanvasMacUsesTheSameLayout() {
        let tiles = sizes.map { ScreenTile(id: $0.key, name: $0.key, sizeMm: $0.value, online: true) }
        let layout = ScreensCanvas.Layout(tiles: tiles, arrangement: row, in: CGSize(width: 640, height: 300), padding: 14)
        let mac = layout.frames.first { $0.id == Arrangement.mac }!.rect
        let pc = layout.frames.first { $0.id == "pc" }!.rect
        let moved = layout.drop(Arrangement.mac, by: CGSize(width: pc.midX - mac.midX, height: 225 * layout.scale), in: row)
        #expect(moved.positions["pc"] == ScreenPosition(x: 0, y: -225))
    }

    @Test func stackedScreensRemainConnectedWithoutOverlap() {
        let sizes = ["mac": CGSize(width: 300, height: 200), "a": CGSize(width: 300, height: 200), "b": CGSize(width: 300, height: 200)]
        let row = Arrangement(order: ["mac", "a", "b"])
        let vertical = row.placing("b", at: CGPoint(x: 300, y: -200), sizes: sizes)
        #expect(Arrangement.connected(vertical.rectangles(sizes: sizes)))
        #expect(vertical.neighbors(of: "a", on: .top, sizes: sizes) == ["b"])
    }
}

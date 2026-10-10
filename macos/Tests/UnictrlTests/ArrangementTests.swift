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

    @Test func offsetKeepsThirtyMillimetresOfSharedEdge() {
        let layout = layout()
        let result = layout.drop("pc", by: CGSize(width: 0, height: 500 * layout.scale), in: row)
        // Both screens are 200 mm tall: at most 200 - 30 = 170 mm apart.
        #expect(abs(result.offset(of: "pc") - 170) < 0.01)
    }
}

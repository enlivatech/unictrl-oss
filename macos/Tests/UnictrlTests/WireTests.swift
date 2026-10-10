import CryptoKit
import Foundation
import Testing
@testable import Unictrl

@Suite struct WireTests {
    @Test func messageRoundTrip() {
        var writer = MessageWriter(.enter)
        writer.f32(-12.5)
        writer.u8(1)
        writer.u8(0b110)
        var reader = MessageReader(writer.data)
        #expect(reader.type == .enter)
        #expect(reader.f32() == -12.5)
        #expect(reader.u8() == 1)
        #expect(reader.u8() == 6)
        #expect(reader.u8() == nil) // past the end
        #expect(reader.f32() == nil)
    }

    @Test func leaveWithoutEdgeByteReadsAsNil() {
        var writer = MessageWriter(.leave)
        writer.f32(3)
        var reader = MessageReader(writer.data)
        #expect(reader.f32() == 3)
        #expect(reader.u8() == nil) // v1 receivers send no edge; the Mac falls back to the entry edge
    }

    private func pair() -> (client: SecureChannel, server: SecureChannel) {
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        return (SecureChannel(pairingKey: "key", clientSalt: a, serverSalt: b, isServer: false),
                SecureChannel(pairingKey: "key", clientSalt: a, serverSalt: b, isServer: true))
    }

    @Test func secureChannelRoundTripAcrossPartialReads() throws {
        let (client, server) = pair()
        let frames = [client.seal(Data([1, 2, 3]))!, client.seal(Data(repeating: 9, count: 3000))!]
        let stream = frames[0] + frames[1]
        var buffer = Data(stream.prefix(10))
        #expect(server.open(from: &buffer)?.isEmpty == true) // incomplete frame waits
        buffer += stream.dropFirst(10)
        let messages = try #require(server.open(from: &buffer))
        #expect(messages == [Data([1, 2, 3]), Data(repeating: 9, count: 3000)])
        #expect(buffer.isEmpty)
    }

    @Test func secureChannelRejectsTamperingReplayAndWrongKey() {
        var (client, server) = pair()
        var frame = client.seal(Data([7]))!
        frame[frame.count - 1] ^= 1
        var buffer = frame
        #expect(server.open(from: &buffer) == nil)

        (client, server) = pair()
        let good = client.seal(Data([7]))!
        buffer = good
        #expect(server.open(from: &buffer) == [Data([7])])
        buffer = good
        #expect(server.open(from: &buffer) == nil) // replayed: nonce counter moved on

        let wrong = SecureChannel(pairingKey: "other", clientSalt: Data(repeating: 1, count: 32),
                                  serverSalt: Data(repeating: 2, count: 32), isServer: true)
        buffer = pair().client.seal(Data([7]))!
        #expect(wrong.open(from: &buffer) == nil)
    }

    /// The PC side of pairing, written from docs/PROTOCOL.md like PairingClient.cs.
    @Test func pairingAgreesOnTheKey() throws {
        let code = "482915"
        let client = P256.KeyAgreement.PrivateKey()
        let clientKey = client.publicKey.rawRepresentation
        let session = try #require(PairingSession(code: code, clientPublicKey: clientKey))
        let hello = session.hello(deviceID: UUID())
        #expect(hello.prefix(8) == Pairing.magic)
        let serverKey = hello.subdata(in: 8..<72)
        let clientProof = Pairing.proof(code: code, role: "client", clientKey: clientKey, serverKey: serverKey)

        #expect(session.verify(Pairing.proof(code: "000000", role: "client", clientKey: clientKey, serverKey: serverKey)) == nil)
        let result = try #require(session.verify(clientProof))
        #expect(Pairing.isValid(result.reply, code: code, role: "server", clientKey: clientKey, serverKey: serverKey))
        let shared = try client.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(rawRepresentation: serverKey))
        #expect(Pairing.pairingKey(shared: shared, clientKey: clientKey, serverKey: serverKey) == result.pairingKey)
    }
}

/// JSON the two apps exchange; the same fixtures are checked by the Windows tests.
@Suite struct ContractTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/contract/\(name)")
        return try Data(contentsOf: url)
    }

    @Test func arrangementMessageMatchesFixture() throws {
        let decoded = try JSONDecoder().decode(ArrangementMessage.self, from: fixture("arrangement-message.json"))
        #expect(decoded.screens.map(\.id).first == Arrangement.mac)
        #expect(decoded.screens[1].offsetMm == -12.5)
        #expect(decoded.screens[2].online == false)
        // Re-encoding keeps the same keys the PC reads.
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(keys.keys) == ["you", "screens"])
        let screen = try #require((keys["screens"] as? [[String: Any]])?.first)
        #expect(Set(screen.keys) == ["id", "name", "widthMm", "heightMm", "offsetMm", "online"])
    }

    @Test func renameFromThePCDecodes() throws {
        let request = try JSONDecoder().decode(RenameRequest.self, from: fixture("rename-request.json"))
        #expect(request.id == "7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B")
        #expect(request.name == "Surface")
    }

    @Test func arrangementEditFromThePCDecodes() throws {
        let edit = try JSONDecoder().decode(Arrangement.self, from: fixture("arrangement-edit.json"))
        #expect(edit.order.count == 3)
        #expect(edit.neighbor(of: Arrangement.mac, on: .left) == "7C1B2E40-5A3D-4F6E-9B21-0C8D4E5F6A7B")
        #expect(edit.offset(of: "3E9F0A12-6B7C-4D8E-8F90-1A2B3C4D5E6F") == 30)
    }
}

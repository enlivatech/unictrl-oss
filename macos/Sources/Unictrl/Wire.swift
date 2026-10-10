import CryptoKit
import Foundation

/// Message types. See docs/PROTOCOL.md; the Windows receiver mirrors these values.
enum MessageType: UInt8 {
    case hello = 0x01
    case screen = 0x02  // receiver -> sender: f32 widthMm, f32 heightMm of the screen the pointer enters
    case arrangement = 0x03     // sender -> receiver (v2): JSON ArrangementMessage, all screens left to right
    case arrangementEdit = 0x04 // receiver -> sender (v2): JSON Arrangement, the user moved screens on the PC
    case enter = 0x10   // sender -> receiver: f32 yMm (from receiver screen center, + down), u8 edge (0 left, 1 right),
                        // u8 flags (bit0 resume, bit1 left edge open, bit2 right edge open)
    case leave = 0x11   // receiver -> sender: f32 yMm (from receiver screen center, + down), u8 edge (v2)
    case move = 0x12    // f32 dxMm, f32 dyMm, u32 sentUs (the sender's clock in µs, wrapping; v2)
    case moveRaw = 0x16 // f32 dx, f32 dy, u32 sentUs: unaccelerated device counts; the receiver applies its own curve
    case button = 0x13  // u8 button (0 left, 1 right, 2 middle, 3 back, 4 forward), u8 down
    case wheel = 0x14   // f32 dyLines (+ = away from user), f32 dxLines
    case key = 0x15     // u8 usagePage (0x07 keyboard, 0x0C consumer), u16 usage, u8 down
    case action = 0x17  // u8 KeyAction: a special key's function, performed by the receiver
    case reclaim = 0x05 // sender -> v2 receiver: u8 keyboardHost, u8 mouseHost (Easy-Switch, 0-based; 0xFF = leave it):
                        // the Mac is awake again, send the devices back to it
    case hosts = 0x06   // v2 receiver -> sender: u8 keyboardHost, u8 mouseHost the PC's devices use (0xFF = not here)
    case rename = 0x07  // v2 receiver -> sender: JSON RenameRequest; the Mac saves it and re-sends 0x03
    case ping = 0x20    // u64 sender clock (ns)
    case pong = 0x21    // echoed u64
    case stats = 0x22   // v2 receiver -> sender: JSON PcStats, about once a second
    case quality = 0x23 // sender -> receiver that sent stats: JSON QualityReport, once a second
}

struct MessageWriter {
    private(set) var data: Data

    init(_ type: MessageType) { data = Data([type.rawValue]) }

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    mutating func utf8(_ value: String) { data.append(contentsOf: Array(value.utf8.prefix(64))) }
    mutating func bytes(_ value: Data) { data.append(value) }
}

struct MessageReader {
    let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex + 1
    }

    var type: MessageType? { data.first.flatMap(MessageType.init(rawValue:)) }

    mutating func u8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        offset += 1
        return data[offset - 1]
    }

    mutating func f32() -> Float? {
        guard offset + 4 <= data.endIndex else { return nil }
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return Float(bitPattern: bits)
    }

    mutating func u64() -> UInt64? {
        guard offset + 8 <= data.endIndex else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
        offset += 8
        return value
    }

    mutating func rest() -> Data { data[offset..<data.endIndex] }
}

/// AES-256-GCM framing over TCP. Keys come from HKDF-SHA256 over the shared pairing key and
/// fresh salts from both peers, one key per direction; nonces are per-direction counters, so a
/// replayed or reordered frame fails authentication.
final class SecureChannel {
    static let magic = Data("UNICTRL1".utf8)
    static let saltLength = 32
    /// v1 receivers accept 1024 and early v2 ones 4096; arrangement messages go only to v2 receivers,
    /// and quality reports (the largest) only to PCs that sent stats.
    static let maxFrame = 16_384

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(pairingKey: String, clientSalt: Data, serverSalt: Data, isServer: Bool) {
        let ikm = SymmetricKey(data: Data(pairingKey.utf8))
        let salt = clientSalt + serverSalt
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                   info: Data(label.utf8), outputByteCount: 32)
        }
        let c2s = derive("unictrl v1 client->server")
        let s2c = derive("unictrl v1 server->client")
        sendKey = isServer ? s2c : c2s
        receiveKey = isServer ? c2s : s2c
    }

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// Returns a length-prefixed frame ready to write to the socket.
    func seal(_ plaintext: Data) -> Data? {
        guard let box = try? AES.GCM.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter)) else {
            return nil
        }
        sendCounter += 1
        let body = box.ciphertext + box.tag
        var frame = Data()
        frame.append(UInt8(body.count >> 8))
        frame.append(UInt8(body.count & 0xff))
        frame.append(body)
        return frame
    }

    /// Consumes complete frames from `buffer`. Returns nil if authentication fails.
    func open(from buffer: inout Data) -> [Data]? {
        var messages: [Data] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
            guard length >= 17, length <= Self.maxFrame else { return nil }
            guard buffer.count >= 2 + length else { break }
            let body = buffer[(start + 2)..<(start + 2 + length)]
            buffer.removeSubrange(start..<(start + 2 + length))
            let ciphertext = body.prefix(length - 16)
            let tag = body.suffix(16)
            guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(receiveCounter),
                                                   ciphertext: ciphertext, tag: tag),
                  let plaintext = try? AES.GCM.open(box, using: receiveKey) else { return nil }
            receiveCounter += 1
            messages.append(plaintext)
        }
        return messages
    }
}

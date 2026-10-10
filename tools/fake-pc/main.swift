// A stand-in Windows PC for testing several PCs with one: pairs like Unictrl.exe (v2), then connects,
// reports a screen and logs what the Mac sends. With "pass" it hands the pointer on through the far
// edge half a second after it arrives; with "back" it returns it the way it came.
//   swiftc -O -o /tmp/fake-pc ../../macos/Sources/Unictrl/Wire.swift main.swift
//   /tmp/fake-pc pair <mac-ip> <code> <state-file>      (state-file keeps the test ID and key; not in Git)
//   /tmp/fake-pc run <mac-ip> <state-file> [pass|back]
import CryptoKit
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let host = NWEndpoint.Host(args[2])
let port = NWEndpoint.Port(rawValue: 24860)!
let statePath = args[args[1] == "pair" ? 4 : 3]

struct State: Codable { var id: String; var key: String }

func uuidBytes(_ id: String) -> Data { withUnsafeBytes(of: UUID(uuidString: id)!.uuid) { Data($0) } }

func connect(_ then: @escaping (NWConnection) -> Void) {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let connection = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: then(connection)
        case .failed(let error): print("failed \(error)"); exit(1)
        default: break
        }
    }
    connection.start(queue: .main)
}

func read(_ connection: NWConnection, _ count: Int, _ then: @escaping (Data) -> Void) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
        guard let data, data.count == count else { print("short read"); exit(1) }
        then(data)
    }
}

if args[1] == "pair" {
    let code = args[3]
    let id = UUID().uuidString
    let privateKey = P256.KeyAgreement.PrivateKey()
    let clientKey = privateKey.publicKey.rawRepresentation
    func proof(_ role: String, _ serverKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("unictrl pair \(role)".utf8) + clientKey + serverKey,
                                             using: SymmetricKey(data: Data(code.utf8))))
    }
    connect { connection in
        connection.send(content: Data("UNICTRP2".utf8) + clientKey + uuidBytes(id), completion: .contentProcessed { _ in })
        read(connection, 8 + 64 + 16) { reply in
            guard reply.prefix(8) == Data("UNICTRP1".utf8) else { print("not pairing"); exit(1) }
            let serverKey = reply.subdata(in: 8..<72)
            connection.send(content: proof("client", serverKey), completion: .contentProcessed { _ in })
            read(connection, 32) { serverProof in
                guard serverProof == proof("server", serverKey),
                      let shared = try? privateKey.sharedSecretFromKeyAgreement(
                        with: P256.KeyAgreement.PublicKey(rawRepresentation: serverKey)) else { print("wrong code"); exit(1) }
                let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: clientKey + serverKey,
                                                         sharedInfo: Data("unictrl pairing key v1".utf8), outputByteCount: 32)
                let state = State(id: id, key: key.withUnsafeBytes { Data($0) }.base64EncodedString())
                try! JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath))
                print("paired id=\(id)")
                exit(0)
            }
        }
    }
} else {
    let state = try! JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
    let pass = args.count > 4 ? args[4] == "pass" : true
    var salt = Data(count: 32)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    connect { connection in
        connection.send(content: Data("UNICTRL2".utf8) + salt + uuidBytes(state.id), completion: .contentProcessed { _ in })
        read(connection, 40) { reply in
            let channel = SecureChannel(pairingKey: state.key, clientSalt: salt, serverSalt: reply.suffix(32), isServer: false)
            func send(_ message: MessageWriter) {
                connection.send(content: channel.seal(message.data)!, completion: .contentProcessed { _ in })
            }
            var hello = MessageWriter(.hello)
            hello.u8(2)
            hello.utf8("FAKE-PC")
            send(hello)
            var screen = MessageWriter(.screen)
            screen.f32(345)
            screen.f32(194)
            send(screen)
            var buffer = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, _ in
                    if let data { buffer.append(data) }
                    guard let messages = channel.open(from: &buffer) else { print("auth failed"); exit(1) }
                    for message in messages {
                        var reader = MessageReader(message)
                        switch reader.type {
                        case .ping:
                            var pong = MessageWriter(.pong)
                            pong.u64(reader.u64()!)
                            send(pong)
                        case .enter:
                            let y = reader.f32()!, edge = reader.u8()!, flags = reader.u8() ?? 0
                            print(String(format: "enter y_mm=%.1f edge=%d resume=%d open_left=%d open_right=%d",
                                         y, edge, flags & 1, flags >> 1 & 1, flags >> 2 & 1))
                            guard flags & 1 == 0 else { break }
                            let out: UInt8 = pass ? (edge == 0 ? 1 : 0) : edge
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                var leave = MessageWriter(.leave)
                                leave.f32(y + 10)
                                leave.u8(out)
                                send(leave)
                                print("leave edge=\(out) y_mm=\(y + 10)")
                            }
                        case .arrangement:
                            print("arrangement \(String(decoding: reader.rest(), as: UTF8.self))")
                        case .hello:
                            print("hello from Mac")
                        default:
                            break
                        }
                    }
                    if complete { print("closed"); exit(0) }
                    receive()
                }
            }
            receive()
        }
    }
}
dispatchMain()

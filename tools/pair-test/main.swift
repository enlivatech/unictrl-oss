// Pairing interoperability check: a one-shot pairing server on a spare port with a fixed code, built
// from the app's own Pairing.swift. Prints a fingerprint of the derived key to compare with the PC's
// `Unictrl.exe --pair-test <mac-ip> <port> <code>` log line. Never touches the real pairing key.
//   swiftc -O -o /tmp/pair-test ../../macos/Sources/Unictrl/Pairing.swift main.swift && /tmp/pair-test 24870 123456
import CryptoKit
import Foundation
import Network

let port = NWEndpoint.Port(rawValue: UInt16(CommandLine.arguments[1])!)!
let code = CommandLine.arguments[2]
let listener = try NWListener(using: .tcp, on: port)
listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 72, maximumLength: 72) { data, _, _, _ in
        guard let data, data.prefix(8) == Pairing.magic,
              let session = PairingSession(code: code, clientPublicKey: data.suffix(64)) else { print("bad hello"); exit(1) }
        connection.send(content: session.hello(deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
                        completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 32, maximumLength: 32) { proof, _, _, _ in
            guard let proof, let result = session.verify(proof) else {
                print("outcome=WrongCode")
                connection.send(content: Data(count: 32), completion: .contentProcessed { _ in exit(0) })
                return
            }
            let fp = SHA256.hash(data: Data(result.pairingKey.utf8)).map { String(format: "%02X", $0) }.joined().prefix(12)
            print("outcome=Paired key_fp=\(fp)")
            connection.send(content: result.reply, completion: .contentProcessed { _ in exit(0) })
        }
    }
}
listener.start(queue: .main)
print("listening on \(port) with code \(code)")
dispatchMain()

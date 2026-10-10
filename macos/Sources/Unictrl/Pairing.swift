import CryptoKit
import Foundation

/// Pairing with a 6-digit code (docs/PROTOCOL.md). Both sides run a P-256 key agreement; each proves
/// it knows the code with an HMAC over both public keys, and the long-term pairing key is derived from
/// the shared secret. The code never crosses the network and is only accepted while the Mac shows it.
enum Pairing {
    static let magic = Data("UNICTRP1".utf8)
    static let publicKeyLength = 64
    static let proofLength = 32

    static func newCode() -> String {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return String(format: "%06d", value % 1_000_000)
    }

    static func proof(code: String, role: String, clientKey: Data, serverKey: Data) -> Data {
        let key = SymmetricKey(data: Data(code.utf8))
        let message = Data("unictrl pair \(role)".utf8) + clientKey + serverKey
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func isValid(_ proof: Data, code: String, role: String, clientKey: Data, serverKey: Data) -> Bool {
        let key = SymmetricKey(data: Data(code.utf8))
        let message = Data("unictrl pair \(role)".utf8) + clientKey + serverKey
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key)
    }

    static func pairingKey(shared: SharedSecret, clientKey: Data, serverKey: Data) -> String {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: clientKey + serverKey,
                                       sharedInfo: Data("unictrl pairing key v1".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}

/// The server half of one pairing attempt on an accepted connection.
final class PairingSession {
    private let code: String
    private let serverKey = P256.KeyAgreement.PrivateKey()
    private let clientKey: Data
    private let shared: SharedSecret

    init?(code: String, clientPublicKey: Data) {
        guard let client = try? P256.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey),
              let shared = try? serverKey.sharedSecretFromKeyAgreement(with: client) else { return nil }
        self.code = code
        clientKey = clientPublicKey
        self.shared = shared
    }

    /// Sent right after the client's key: magic, the server's public key and the Mac's device ID.
    func hello(deviceID: UUID) -> Data {
        var id = deviceID.uuid
        return Pairing.magic + serverKey.publicKey.rawRepresentation + Data(bytes: &id, count: 16)
    }

    /// Checks the client's proof; on success returns the reply proof and the new pairing key.
    func verify(_ clientProof: Data) -> (reply: Data, pairingKey: String)? {
        let server = serverKey.publicKey.rawRepresentation
        guard clientProof.count == Pairing.proofLength,
              Pairing.isValid(clientProof, code: code, role: "client", clientKey: clientKey, serverKey: server) else {
            return nil
        }
        return (Pairing.proof(code: code, role: "server", clientKey: clientKey, serverKey: server),
                Pairing.pairingKey(shared: shared, clientKey: clientKey, serverKey: server))
    }
}

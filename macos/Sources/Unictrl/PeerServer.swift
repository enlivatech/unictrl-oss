import Foundation
import Network
import Security

/// Listens for Windows PCs. The Mac is the server so Windows needs no inbound firewall rule.
/// Each paired PC has its own key and at most one live session; a new connection handshakes on its own
/// and replaces that PC's session only once it has proven its key, so stray or failed connections
/// never interrupt the pointer. Callbacks run on the main queue.
final class PeerServer {
    var onConnected: ((_ peer: String, _ name: String) -> Void)?
    var onDisconnected: ((_ peer: String, _ reason: String) -> Void)?
    var onMessage: ((_ peer: String, Data) -> Void)?
    /// A PC finished pairing: its device ID ("" for a PC that did not send one) and new pairing key.
    var onPaired: ((_ peer: String, _ key: String) -> Void)?
    /// A PC paired before device IDs connected with its ID for the first time.
    var onBound: ((_ peer: String) -> Void)?
    /// The pairing key for a PC's device ID ("" = the PC paired before device IDs).
    var keyFor: (String) -> String? = { _ in nil }
    /// Set while the Mac shows a pairing code; nil rejects pairing attempts.
    var pairingCode: String?
    var deviceID = UUID()
    /// The Mac's name as the user sees it, sent in hello.
    var displayName: () -> String = { Host.current().localizedName ?? "Mac" }

    private final class Session {
        let connection: NWConnection
        var peer = ""
        var boundLegacy = false
        var channel: SecureChannel?
        var buffer = Data()
        var name: String?
        /// Connected with the v2 handshake: understands arrangement messages.
        var modern = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private static let sessionV1 = Data("UNICTRL1".utf8)
    private static let sessionV2 = Data("UNICTRL2".utf8)
    private static let pairingV2 = Data("UNICTRP2".utf8)
    private static let notPaired = Data("UNICTRL0".utf8)

    private let port: UInt16
    private var listener: NWListener?
    /// Live sessions by peer. Guarded by `lock`: the event tap thread sends too. Sealing and handing the
    /// frame to the connection happen under the same lock, so frames leave in nonce order.
    private let lock = NSLock()
    private var table: [String: Session] = [:]
    private func session(_ peer: String) -> Session? { lock.withLock { table[peer] } }
    private var sessions: [String: Session] { lock.withLock { table } }
    private var failedPairingAttempts = 0

    init(settings: UnictrlSettings) { port = settings.port }

    func isConnected(_ peer: String) -> Bool { session(peer) != nil }
    var connectedPeers: [String] { Array(sessions.keys) }
    func isModern(_ peer: String) -> Bool { session(peer)?.modern ?? false }
    /// The kind of network the session with a PC runs over (a VPN tunnel shows as .other).
    func interfaceType(_ peer: String) -> NWInterface.InterfaceType? {
        session(peer)?.connection.currentPath?.availableInterfaces.first?.type
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { Log.write("listener_failed", "\(error)") }
        }
        listener.start(queue: .main)
        self.listener = listener
        Log.write("listening", "port=\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values { end(session, "stopped") }
    }

    /// Ends a PC's session, e.g. after it was removed.
    func disconnect(_ peer: String) {
        if let session = session(peer) { end(session, "removed") }
    }

    func send(_ message: MessageWriter, to peer: String) {
        lock.withLock {
            guard let session = table[peer], let frame = session.channel?.seal(message.data) else { return }
            session.connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func broadcast(_ message: MessageWriter) {
        for peer in sessions.keys { send(message, to: peer) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let session = Session(connection)
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .failed(let error): end(session, "failed \(error)")
            case .cancelled: end(session, "cancelled")
            default: break
            }
        }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] data, _, _, _ in
            guard let self else { return }
            switch data {
            case Self.sessionV1?: readSession(session, withID: false)
            case Self.sessionV2?: readSession(session, withID: true)
            case Pairing.magic?: readPairing(session, withID: false)
            case Self.pairingV2?: readPairing(session, withID: true)
            default: connection.cancel()
            }
        }
    }

    private func end(_ session: Session, _ reason: String) {
        session.connection.stateUpdateHandler = nil
        session.connection.cancel()
        let removed = lock.withLock {
            guard table[session.peer] === session else { return false }
            table[session.peer] = nil
            return true
        }
        guard removed else { return }
        Log.write("peer_dropped", "reason=\(reason)")
        onDisconnected?(session.peer, reason)
    }

    // MARK: Session handshake

    private func readSession(_ session: Session, withID: Bool) {
        let connection = session.connection
        let length = SecureChannel.saltLength + (withID ? 16 : 0)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data, data.count == length, error == nil else {
                connection.cancel()
                return
            }
            let salt = data.prefix(SecureChannel.saltLength)
            let peer = withID ? Self.uuidString(data.suffix(16)) : ""
            var key = keyFor(peer)
            if key == nil, withID, let legacy = keyFor("") {
                // A PC paired before device IDs: try its key, and bind the ID once the hello checks out.
                key = legacy
                session.boundLegacy = true
            }
            guard let key else {
                // Tell the PC plainly (it was removed here), so it asks to pair instead of searching.
                Log.write("peer_unknown", "id=\(peer.prefix(8))")
                connection.send(content: Self.notPaired, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            session.peer = peer
            session.modern = withID
            var serverSalt = Data(count: SecureChannel.saltLength)
            _ = serverSalt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, SecureChannel.saltLength, $0.baseAddress!) }
            connection.send(content: SecureChannel.magic + serverSalt, completion: .contentProcessed { _ in })
            let channel = SecureChannel(pairingKey: key, clientSalt: Data(salt), serverSalt: serverSalt, isServer: true)
            session.channel = channel
            var hello = MessageWriter(.hello)
            hello.u8(1) // platform: macOS
            hello.utf8(displayName())
            if let frame = channel.seal(hello.data) { connection.send(content: frame, completion: .contentProcessed { _ in }) }
            readFrames(session)
        }
    }

    private func readFrames(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, let channel = session.channel else { return }
            if let data { session.buffer.append(data) }
            guard let messages = channel.open(from: &session.buffer) else {
                // Wrong pairing key or tampered frame.
                Log.write("peer_auth_failed", session.name == nil ? "before hello" : "")
                end(session, "auth_failed")
                return
            }
            for message in messages {
                if session.name == nil {
                    guard message.first == MessageType.hello.rawValue else { end(session, "no_hello"); return }
                    session.name = String(decoding: message.dropFirst(2), as: UTF8.self)
                    if session.boundLegacy {
                        onBound?(session.peer)
                        if let old = self.session("") { end(old, "rebound") }
                    }
                    if let old = self.session(session.peer) { end(old, "replaced") }
                    lock.withLock { self.table[session.peer] = session }
                    Log.write("peer_connected", "name=\(session.name ?? "?") id=\(session.peer.prefix(8))")
                    onConnected?(session.peer, session.name ?? "Windows")
                    continue
                }
                if self.session(session.peer) === session { onMessage?(session.peer, message) }
            }
            if complete || error != nil {
                end(session, error.map { "error \($0)" } ?? "closed")
                return
            }
            readFrames(session)
        }
    }

    // MARK: Pairing

    private func readPairing(_ session: Session, withID: Bool) {
        let connection = session.connection
        let length = Pairing.publicKeyLength + (withID ? 16 : 0)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let code = pairingCode, let data, data.count == length,
                  let pairing = PairingSession(code: code, clientPublicKey: data.prefix(Pairing.publicKeyLength)) else {
                // Not showing a code: the PC tells the user to choose "Pair a Windows PC…" on the Mac.
                connection.send(content: Data("UNICTRP0".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let peer = withID ? Self.uuidString(data.suffix(16)) : ""
            connection.send(content: pairing.hello(deviceID: deviceID), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: Pairing.proofLength, maximumLength: Pairing.proofLength) { [weak self] proof, _, _, _ in
                guard let self else { return }
                guard let proof, let result = pairing.verify(proof) else {
                    connection.send(content: Data(count: Pairing.proofLength), completion: .contentProcessed { _ in connection.cancel() })
                    failedPairingAttempts += 1
                    Log.write("pairing_rejected", "attempt=\(failedPairingAttempts)")
                    if failedPairingAttempts >= 5 { pairingCode = nil } // someone is guessing: void the code
                    return
                }
                connection.send(content: result.reply, completion: .contentProcessed { _ in connection.cancel() })
                pairingCode = nil
                failedPairingAttempts = 0
                Log.write("paired", "id=\(peer.prefix(8))")
                onPaired?(peer, result.pairingKey)
            }
        }
    }

    private static func uuidString(_ bytes: Data) -> String {
        let b = Array(bytes)
        guard b.count == 16 else { return "" }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }
}

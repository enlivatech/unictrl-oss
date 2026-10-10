import Foundation
import Network

/// Answers "UNICTRL?" datagrams on UDP 24861 so a Windows PC can find this Mac when its address
/// changes. The reply carries the Mac's device ID (to tell several Macs apart), name and TCP port.
final class DiscoveryResponder {
    static let port: UInt16 = 24861
    private var listener: NWListener?
    private let deviceID: UUID
    private let port: UInt16
    /// The Mac's name as the user sees it (it can be renamed); read for each reply.
    var name: () -> String = { Host.current().localizedName ?? "Mac" }

    init(deviceID: UUID, port: UInt16) {
        self.deviceID = deviceID
        self.port = port
    }

    private var reply: Data {
        let info: [String: Any] = ["v": 1, "id": deviceID.uuidString, "name": name(), "port": Int(port)]
        return Data("UNICTRL!".utf8) + ((try? JSONSerialization.data(withJSONObject: info)) ?? Data())
    }

    func start() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            Log.write("discovery_failed")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, _ in
                guard let self, data == Data("UNICTRL?".utf8) else { connection.cancel(); return }
                connection.send(content: self.reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }
}

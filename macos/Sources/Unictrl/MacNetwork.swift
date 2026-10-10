import CoreWLAN
import Network

/// This Mac's side of the link to a PC, for the checklist. Reading it needs no location permission:
/// only the network's name would.
enum MacNetwork {
    static func link(over interface: NWInterface.InterfaceType?) -> MacLink? {
        switch interface {
        case .wiredEthernet?:
            return MacLink(kind: .ethernet)
        case .wifi?:
            var link = MacLink(kind: .wifi)
            guard let wifi = CWWiFiClient.shared().interface() else { return link }
            if let channel = wifi.wlanChannel() {
                link.channel = channel.channelNumber
                switch channel.channelBand {
                case .band2GHz: link.bandGHz = 2.4
                case .band5GHz: link.bandGHz = 5
                case .band6GHz: link.bandGHz = 6
                default: break
                }
                switch channel.channelWidth {
                case .width20MHz: link.widthMHz = 20
                case .width40MHz: link.widthMHz = 40
                case .width80MHz: link.widthMHz = 80
                case .width160MHz: link.widthMHz = 160
                default: break
                }
            }
            let rssi = wifi.rssiValue()
            if rssi != 0 { link.rssi = rssi }
            let noise = wifi.noiseMeasurement()
            if noise != 0 { link.noise = noise }
            return link
        case .other?:
            return MacLink(kind: .other) // a VPN tunnel
        default:
            return nil
        }
    }
}

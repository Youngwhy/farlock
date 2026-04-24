import Foundation
import CoreWLAN

final class WifiMonitor {
    private let client = CWWiFiClient.shared()

    func currentSSID() -> String? {
        guard let iface = client.interface() else { return nil }
        return iface.ssid()
    }

    // Returns the SSID if it matches the trust list, else nil.
    func trustedSSID(in list: [String]) -> String? {
        guard let ssid = currentSSID() else { return nil }
        return list.contains(ssid) ? ssid : nil
    }
}

import Foundation
import SystemConfiguration

enum OnboardNetwork {
    /// The domains the networks' DHCP servers hand out, e.g. "guest.freewlan.sbb.ch" on SBB trains. Every
    /// service, not just the primary one: a VPN can be primary while Wi-Fi does the work.
    static var dhcpDomains: [String] {
        guard let store = SCDynamicStoreCreate(nil, "Zugbar" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DHCP" as CFString) as? [String]
        else { return [] }
        return keys.sorted().compactMap { key in
            guard let dhcp = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let data = dhcp["Option_15"] as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

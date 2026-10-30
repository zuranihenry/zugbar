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

    /// The primary network's router, e.g. "10.0.0.1"; only private IPv4 addresses, which stay on the train.
    static var router: String? {
        guard let store = SCDynamicStoreCreate(nil, "Zugbar" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = global["Router"] as? String
        else { return nil }
        let parts = router.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let isPrivate = parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
        return isPrivate ? router : nil
    }
}

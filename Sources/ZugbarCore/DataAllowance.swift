import Foundation

/// How much data the train Wi-Fi lets this Mac use, as its router counts it: on DB Regio trains 100 MB a session,
/// after which the Mac is cut off or slowed to a crawl for the rest of the ride.
public struct DataAllowance: Sendable, Equatable {
    /// Bytes, everything on the Mac, not just Zugbar.
    public var used: Int64
    public var limit: Int64
    /// Bits per second once it's used up, where the Wi-Fi slows down rather than cutting off.
    public var throttledTo: Int?

    public init(used: Int64, limit: Int64, throttledTo: Int? = nil) {
        self.used = used
        self.limit = limit
        self.throttledTo = throttledTo
    }

    public var remaining: Int64 { max(limit - used, 0) }
    public var fractionUsed: Double { min(Double(used) / Double(limit), 1) }
}

extension Icomera {
    static let userURL = URL(string: "https://www.ombord.info/api/jsonp/user/")!

    /// The Mac's data allowance on this train's Wi-Fi; `nil` when it has none.
    public func allowance() async throws -> DataAllowance? {
        try Self.parseAllowance(await loader(Self.userURL))
    }

    /// JSONP like the position, every value a string. A limit of 0, or none, means no limit; some routers only
    /// count downloads.
    public static func parseAllowance(_ data: Data) throws -> DataAllowance? {
        guard let text = String(data: data, encoding: .utf8),
              let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any]
        else { throw ProviderError.missingResource("data allowance") }
        func bytes(_ key: String) -> Int64? {
            switch object[key] {
            case let number as NSNumber: number.int64Value
            case let text as String: Int64(text) ?? Double(text).flatMap { $0.isFinite ? Int64($0) : nil }
            default: nil
            }
        }
        for kind in ["total", "download"] {
            if let limit = bytes("data_\(kind)_limit"), limit > 0, let used = bytes("data_\(kind)_used"), used >= 0 {
                return DataAllowance(used: used, limit: limit)
            }
        }
        return nil
    }
}

/// Hotspot Wi-Fi on regional trains and buses (hotsplots and other CoovaChilli gateways) counts each session's
/// data and slows it down past a limit. The gateway, the network's router, tells how much is left.
public enum HotspotGateway {
    /// Plain HTTP to the router's private address, which never leaves the train: CoovaChilli's own port first,
    /// which answers before and after the login, then the usual one.
    public static func statusURLs(router: String) -> [URL] {
        ["http://\(router):3990/json/status", "http://\(router)/json/status"].compactMap(URL.init(string:))
    }

    /// `maxOctetsBeforeNextRate` is what's left before the slower rate, `inputOctets` and `outputOctets` what the
    /// session used; `nil` when the answer has no such session, e.g. from a home router.
    /// A CoovaChilli answer, with or without a session yet: before the login page, the session is missing.
    public static func isGateway(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["clientState"] != nil
    }

    public static func parseStatus(_ data: Data) -> DataAllowance? {
        struct Status: Decodable {
            struct Session: Decodable {
                let maxOctetsBeforeNextRate: Int64?
                let maxNextRateDown: Int?
            }
            struct Accounting: Decodable {
                let inputOctets: Int64?
                let outputOctets: Int64?
            }
            let session: Session?
            let accounting: Accounting?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data),
              let left = status.session?.maxOctetsBeforeNextRate, left >= 0
        else { return nil }
        let used = max(status.accounting?.inputOctets ?? 0, 0) + max(status.accounting?.outputOctets ?? 0, 0)
        guard used + left > 0 else { return nil }
        return DataAllowance(used: used, limit: used + left, throttledTo: status.session?.maxNextRateDown.flatMap { $0 > 0 ? $0 : nil })
    }
}

/// When Zugbar saves data: leaves out what can wait, and asks for the rest less often.
public enum DataSaving: String, CaseIterable, Identifiable, Sendable {
    /// While the train Wi-Fi has a data limit, or macOS's Low Data Mode is on for the network.
    case automatic
    case always
    case off

    public var id: String { rawValue }

    public func isOn(allowance: DataAllowance?, lowDataMode: Bool) -> Bool {
        switch self {
        case .automatic: allowance != nil || lowDataMode
        case .always: true
        case .off: false
        }
    }
}

/// Warns once when most of the allowance is used, so there's time to pause other things on the Mac.
public struct AllowanceWarning: Sendable {
    public static let threshold = 0.8

    private var warnedLimit: Int64?
    private var lastUsed: Int64 = 0

    public init() {}

    /// Whether to warn now. Warns again on a new session, where the router starts counting from zero, or under a
    /// different limit; not when a gateway's limit, added up from its counters, is off by a few bytes.
    public mutating func check(_ allowance: DataAllowance) -> Bool {
        defer { lastUsed = allowance.used }
        let otherLimit = warnedLimit.map { abs(Double($0 - allowance.limit)) > Double($0) * 0.05 } == true
        if allowance.used < lastUsed || otherLimit {
            warnedLimit = nil
        }
        guard warnedLimit == nil, allowance.fractionUsed >= Self.threshold else { return false }
        warnedLimit = allowance.limit
        return true
    }
}

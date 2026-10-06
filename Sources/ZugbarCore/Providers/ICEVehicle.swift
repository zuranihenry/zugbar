import Foundation

/// Identifies an ICE trainset from its Triebzugnummer (e.g. "Tz9018" → ICE 4 „Gießen“).
enum ICEVehicle {
    static func describe(tzn: String?) -> String? {
        guard let tzn, let number = Int(tzn.filter(\.isNumber)), number > 0 else { return nil }
        var parts = [model(for: number), "Tz \(number)"].compactMap { $0 }
        if let name = names[String(number)] {
            parts[parts.count - 1] += " „\(name)“"
        }
        return parts.joined(separator: " · ")
    }

    static func model(for number: Int) -> String? {
        switch number {
        case 101...199: "ICE 1"
        case 201...299: "ICE 2"
        case 301...399, 4601...4699, 701...799, 4701...4799: "ICE 3"
        case 8001...8099: "ICE 3neo"
        case 1101...1199, 1501...1599: "ICE T"
        case 9001...9999: "ICE 4"
        default: nil
        }
    }

    /// Trainset names, from felix-zenk/onboardapis (MIT).
    private static let names: [String: String] = {
        guard let data = try? DemoProvider.resource("ice_names") else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
}

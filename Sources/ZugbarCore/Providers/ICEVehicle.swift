import Foundation

/// Trains that look alike from the side, for the drawing in the panel. Only what a portal identifies reliably.
public enum TrainFamily: String, Sendable, CaseIterable {
    /// ICE 1 and ICE 2: a power car without passenger windows.
    case ice1
    /// The first ICE 3 (series 403 and 406).
    case ice3
    /// Velaro D and ICE 3neo (series 407 and 408), which share a body.
    case velaro
    case ice4
    case iceT
    /// ÖBB Railjet: a locomotive with coaches.
    case railjet
    case tgv
}

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

    /// The family to draw, from the portal's series ("412") and the trainset number.
    /// Either one is enough when the other is missing or not in the list; `nil` when they name different families.
    static func family(series: String?, tzn: String?) -> TrainFamily? {
        let fromNumber = tzn.flatMap { Int($0.filter(\.isNumber)) }.flatMap(family(for:))
        guard let fromSeries = series.flatMap({ family(series: $0.trimmingCharacters(in: .whitespaces)) }) else { return fromNumber }
        return fromNumber == nil || fromNumber == fromSeries ? fromSeries : nil
    }

    static func family(series: String) -> TrainFamily? {
        switch series {
        case "401", "402": .ice1
        case "403", "406": .ice3
        case "407", "408": .velaro
        case "411", "415": .iceT
        case "412": .ice4
        default: nil
        }
    }

    static func family(for number: Int) -> TrainFamily? {
        switch number {
        case 101...199, 201...299: .ice1
        case 301...399, 4601...4699: .ice3
        case 701...799, 4701...4799, 8001...8099: .velaro
        case 1101...1199, 1501...1599: .iceT
        case 9001...9999: .ice4
        default: nil
        }
    }

    /// Trainset names, from felix-zenk/onboardapis (MIT).
    private static let names: [String: String] = {
        guard let data = try? DemoProvider.resource("ice_names") else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
}

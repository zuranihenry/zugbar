import Foundation

public struct MenuTitleOptions: Sendable, Equatable {
    public enum StationStyle: String, Sendable, CaseIterable {
        case full, compact, short
    }

    public var showSpeed: Bool
    /// Show estimated speed, as "≈ 180", when there's no live speed.
    public var showEstimate: Bool
    public var showStation: Bool
    public var showCountdown: Bool
    public var showTopSpeedFlame: Bool
    public var stationStyle: StationStyle
    public var showUnit: Bool
    public var minutesOnly: Bool

    public init(
        showSpeed: Bool = true, showEstimate: Bool = true, showStation: Bool = true, showCountdown: Bool = true, showTopSpeedFlame: Bool = true,
        stationStyle: StationStyle = .full, showUnit: Bool = true, minutesOnly: Bool = false
    ) {
        self.showSpeed = showSpeed
        self.showEstimate = showEstimate
        self.showStation = showStation
        self.showCountdown = showCountdown
        self.showTopSpeedFlame = showTopSpeedFlame
        self.stationStyle = stationStyle
        self.showUnit = showUnit
        self.minutesOnly = minutesOnly
    }
}

public enum MenuTitle {
    /// e.g. "🔥 248 km/h · → Augsburg Hbf 6:42", or "≈ 180 km/h · …" from `estimatedSpeed` when there's no live speed.
    public static func make(
        status: TrainStatus,
        displaySpeed: Int?,
        isTopSpeed: Bool,
        now: Date,
        options: MenuTitleOptions,
        nowLabel: String = "now",
        estimatedSpeed: Int? = nil
    ) -> String {
        var parts: [String] = []
        let unit = options.showUnit ? " km/h" : ""

        if options.showSpeed, let displaySpeed {
            let flame = options.showTopSpeedFlame && isTopSpeed && displaySpeed > 0 ? "🔥 " : ""
            parts.append("\(flame)\(displaySpeed)" + unit)
        } else if options.showSpeed, options.showEstimate, let estimatedSpeed {
            parts.append("≈ \(estimatedSpeed)" + unit)
        }

        if options.showStation, let stop = status.nextStop {
            let name = shorten(stop.name, style: options.stationStyle)
            if stop.isCurrent(at: now) {
                parts.append("● \(name)")
            } else if options.showCountdown, let arrival = stop.arrival {
                let time = options.minutesOnly
                    ? minutesLeft(to: arrival, from: now, nowLabel: nowLabel)
                    : countdown(to: arrival, from: now, nowLabel: nowLabel)
                parts.append("→ \(name) \(time)")
            } else {
                parts.append("→ \(name)")
            }
        }

        return parts.joined(separator: " · ")
    }

    /// "7′" style: whole minutes, rounded up.
    public static func minutesLeft(to date: Date, from now: Date, nowLabel: String = "now") -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return nowLabel }
        return "\(Int((seconds / 60).rounded(.up)))′"
    }

    /// Shorter station names for a narrow menu bar.
    /// compact: "Frankfurt (Main) Flughafen Fernbahnhof" → "Frankfurt Flugh."; short: compact, cut to 12 characters.
    public static func shorten(_ name: String, style: MenuTitleOptions.StationStyle) -> String {
        guard style != .full else { return name }
        var result = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        for (long, short) in [("Fernbahnhof", ""), ("Flughafen", "Flugh."), ("Bahnhof", "Bf"), ("Hauptbahnhof", "Hbf"), ("Sankt ", "St. ")] {
            result = result.replacingOccurrences(of: long, with: short)
        }
        result = result.split(separator: " ").joined(separator: " ")
        if style == .short, result.count > 12 {
            result = String(result.prefix(11)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return result.isEmpty ? name : result
    }

    /// "6:42" below an hour, "1h 05m" above, `nowLabel` when due.
    public static func countdown(to date: Date, from now: Date, nowLabel: String = "now") -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.down))
        if seconds <= 0 { return nowLabel }
        if seconds >= 3600 {
            return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

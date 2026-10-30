import Foundation

public struct MenuTitleOptions: Sendable, Equatable {
    public enum StationStyle: String, Sendable, CaseIterable {
        /// Full names, shortened when the title gets too wide; see `MenuTitle.fitted`.
        case automatic
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
        estimatedSpeed: Int? = nil,
        waitingAt boarding: Stop? = nil,
        trackLabel: (String) -> String = { "Pl. \($0)" },
        cancelledLabel: String = "cancelled"
    ) -> String {
        // Waiting for the train: when it leaves, not how fast it goes somewhere else.
        if let boarding {
            var parts: [String] = []
            var head = "🚶"
            if options.showStation { head += " " + shorten(boarding.name, style: options.stationStyle) }
            if boarding.cancelled { return [head, cancelledLabel].joined(separator: " · ") }
            if let departure = boarding.departure {
                // Rounded down: overstating the time left to catch a train is worse than understating it.
                head += " " + (options.minutesOnly
                    ? minutesLeft(to: departure, from: now, nowLabel: nowLabel, roundingUp: false)
                    : countdown(to: departure, from: now, nowLabel: nowLabel))
            }
            parts.append(head)
            if let delay = boarding.departureDelayMinutes, delay > 0 { parts.append("+\(delay)") }
            if let track = boarding.track { parts.append(trackLabel(track)) }
            return parts.joined(separator: " · ")
        }

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

    /// "7′" style: whole minutes, rounded up unless `roundingUp` is false.
    public static func minutesLeft(to date: Date, from now: Date, nowLabel: String = "now", roundingUp: Bool = true) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(roundingUp ? .up : .down))
        if minutes <= 0 { return nowLabel }
        return "\(minutes)′"
    }

    /// The title with `.automatic` station names: full when it's no wider than `maxWidth` as measured by `width`,
    /// else compact, else short, so a long name doesn't push the item off a full menu bar. Other styles as chosen.
    public static func fitted(
        _ options: MenuTitleOptions, maxWidth: Double = 260, width: (String) -> Double, make: (MenuTitleOptions) -> String
    ) -> String {
        var title = make(options)
        guard options.stationStyle == .automatic else { return title }
        for style in [MenuTitleOptions.StationStyle.compact, .short] where width(title) > maxWidth {
            var shorter = options
            shorter.stationStyle = style
            title = make(shorter)
        }
        return title
    }

    /// Shorter station names for a narrow menu bar.
    /// compact: "Düsseldorf Flughafen Fernbahnhof" → "Düsseldorf Flugh."; short: compact, cut to 12 characters.
    public static func shorten(_ name: String, style: MenuTitleOptions.StationStyle) -> String {
        guard style == .compact || style == .short else { return name }
        // "Halle(Saale)Hbf" has no spaces around the parentheses, so leave one in their place.
        var result = name.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
        for (long, short) in [("Fernbahnhof", ""), ("Flughafen", "Flugh."), ("Hauptbahnhof", "Hbf"), ("Bahnhof", "Bf"), ("Sankt ", "St. ")] {
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

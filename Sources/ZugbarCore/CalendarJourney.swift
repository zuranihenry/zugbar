import Foundation

/// A rail connection as a booking app writes it into the calendar: the trains in order, with where and when the
/// user gets on and off each. Made from an event's plain text; an event that isn't exactly such an entry gives nil.
public struct CalendarJourney: Equatable, Sendable {
    public struct Leg: Equatable, Sendable {
        /// As passengers know it, "RE 5".
        public var train: String
        /// The same train by the number the entry adds in brackets, "RE 4711"; some sources name it by that.
        public var alias: String?
        public var from: String
        public var departure: Date
        public var to: String
        public var arrival: Date

        public init(train: String, alias: String? = nil, from: String, departure: Date, to: String, arrival: Date) {
            self.train = train
            self.alias = alias
            self.from = from
            self.departure = departure
            self.to = to
            self.arrival = arrival
        }
    }

    public var legs: [Leg]

    public init(legs: [Leg]) {
        self.legs = legs
    }

    /// How far ahead the calendar is looked at.
    public static let lookAhead: TimeInterval = 6 * 60 * 60
}

extension CalendarJourney {
    /// What a journey has for the followed train: where to get off, and the train after that.
    public struct Suggestion: Equatable, Sendable {
        /// The stop in the followed train's own list.
        public var stopID: String
        public var stopName: String
        /// False when the plan already has this stop and only the connection is new.
        public var setsStop: Bool
        public var onward: Onward?
    }

    /// The next train of the journey, to be found among the connections from where the user gets off.
    public struct Onward: Equatable, Sendable {
        public var train: String
        public var alias: String?
        public var departure: Date
        public var to: String

        func isTrain(_ name: String) -> Bool {
            TrainName.same(train, name) || alias.map { TrainName.same($0, name) } == true
        }

        /// The one of `options` that is this train: the same name leaving within a few minutes of the booked
        /// time, or, named differently, the only one leaving at that very minute. Nil when that's not certain.
        public func pick(from options: [Connection]) -> Connection? {
            func gap(_ option: Connection) -> TimeInterval? {
                option.scheduledDeparture.map { abs($0.timeIntervalSince(departure)) }
            }
            let named = options.filter { isTrain($0.name) && (gap($0) ?? .infinity) <= 5 * 60 }
            if named.count == 1 { return named[0] }
            let timed = options.filter { (gap($0) ?? .infinity) < 60 }
            return named.isEmpty && timed.count == 1 ? timed[0] : nil
        }
    }

    /// The leg on the train `status` shows, as a stop of that train still ahead. Nothing when the user's plan
    /// already says as much, or says something else: what they entered themselves isn't second-guessed.
    public func suggestion(for status: TrainStatus, plan: JourneyPlan?, now: Date) -> Suggestion? {
        guard let name = status.trainName, let index = legs.firstIndex(where: { leg in
            TrainName.same(leg.train, name) || leg.alias.map { TrainName.same($0, name) } == true
        }) else { return nil }
        let leg = legs[index]
        // After where the user gets on, when the train's list has that stop; a ring line calls twice at some.
        let start = status.stops.firstIndex { StationName.same($0.name, leg.from) }.map { $0 + 1 } ?? 0
        guard let stop = status.stops[start...].first(where: { StationName.same($0.name, leg.to) }),
              !stop.cancelled, !stop.passed, (stop.arrival ?? leg.arrival) > now,
              // The same train number runs again tomorrow, and on some lines every hour.
              (stop.scheduledArrival ?? stop.arrival).map({ abs($0.timeIntervalSince(leg.arrival)) <= 30 * 60 }) ?? true
        else { return nil }
        let plan = plan.flatMap { TrainName.same($0.trainName, name) ? $0 : nil }
        let onward = legs.dropFirst(index + 1).first.map { Onward(train: $0.train, alias: $0.alias, departure: $0.departure, to: $0.to) }
        if let destination = plan?.destinationStopID ?? plan?.pendingDestination {
            guard destination == stop.id || StationName.same(destination, stop.name),
                  plan?.connection == nil, let onward else { return nil }
            return Suggestion(stopID: stop.id, stopName: stop.name, setsStop: false, onward: onward)
        }
        return Suggestion(stopID: stop.id, stopName: stop.name, setsStop: true, onward: onward)
    }
}

extension CalendarJourney {
    /// Reads an event that is a connection from bahn.de or DB's apps, in the two shapes they have written:
    ///
    ///     Astadt Hbf ➞ Cstadt                      Astadt Hbf -> Cstadt
    ///     Datum: 01.02.2026                        Reise: Astadt Hbf nach Cstadt
    ///                                              Datum: 01.02.26
    ///     Astadt Hbf ➞ Bstadt                      -
    ///     ICE 123 (4567)                           ab 10:00 Astadt Hbf - Gleis 1 (ICE  123)
    ///     ● ab 10:00 Astadt Hbf ▷ Gleis 1          an 11:00 Bstadt - Gleis 2
    ///     ○ an 11:00 Bstadt ▷ Gleis 2
    ///
    /// Strictly: the title names the first and last station, every leg is complete and starts where the last one
    /// ended, and the event runs from the first departure to the last arrival. Anything else is not a journey.
    public init?(title: String, location: String? = nil, notes: String?, start: Date, end: Date) {
        guard let notes, start < end, end.timeIntervalSince(start) < 24 * 60 * 60 else { return nil }
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = title.trimmingCharacters(in: .whitespaces)
        guard lines.contains(where: { $0.hasPrefix("Datum: ") }) else { return nil }

        let drafts: [Draft]?
        let ends: [String]
        if title.contains(" ➞ ") {
            ends = title.components(separatedBy: " ➞ ")
            // The departure station, when the entry has a location at all.
            if let location, !location.isEmpty, location.trimmingCharacters(in: .whitespaces) != ends[0] { return nil }
            drafts = Self.currentLegs(lines)
        } else if title.contains(" -> ") {
            ends = title.components(separatedBy: " -> ")
            guard ends.count == 2, lines.contains("Reise: \(ends[0]) nach \(ends[1])") else { return nil }
            drafts = Self.formerLegs(lines)
        } else {
            return nil
        }
        guard ends.count == 2, let drafts, let first = drafts.first, let last = drafts.last,
              first.from == ends[0], last.to == ends[1],
              zip(drafts, drafts.dropFirst()).allSatisfy({ $0.to == $1.from })
        else { return nil }

        // The entry's times are the clock's where the train runs: usually this Mac's, else Germany's.
        for zone in [TimeZone.current, TimeZone(identifier: "Europe/Berlin")].compactMap({ $0 }) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var time = start.addingTimeInterval(-1)
            var legs: [Leg] = []
            for draft in drafts {
                guard let departure = calendar.next(draft.departure, after: time),
                      let arrival = calendar.next(draft.arrival, after: departure.addingTimeInterval(-1)) else { break }
                legs.append(Leg(train: draft.train, alias: draft.alias, from: draft.from, departure: departure, to: draft.to, arrival: arrival))
                time = arrival.addingTimeInterval(-1)
            }
            if legs.count == drafts.count, legs[0].departure.timeIntervalSince(start) < 60,
               abs(legs[legs.count - 1].arrival.timeIntervalSince(end)) < 60 {
                self.legs = legs
                return
            }
        }
        return nil
    }

    private struct Draft {
        var train: String
        var alias: String?
        var from: String
        var departure: (hour: Int, minute: Int)
        var to: String
        var arrival: (hour: Int, minute: Int)
    }

    /// bahn.de since 2023: a block of four lines per train.
    private static func currentLegs(_ lines: [String]) -> [Draft]? {
        var drafts: [Draft] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("●") || line.hasPrefix("○") else { index += 1; continue }
            // A departure with its train and stations above and its arrival below, or it's something else.
            guard index >= 2, index + 1 < lines.count,
                  let departure = groups(#"^● ab (\d{1,2}):(\d{2}) (.+?) ▷ Gleis ?\S*( \S+)?$"#, in: line),
                  let arrival = groups(#"^○ an (\d{1,2}):(\d{2}) (.+?) ▷ Gleis ?\S*( \S+)?$"#, in: lines[index + 1]),
                  let train = groups(#"^(\p{L}{1,4}) ?(\d{1,5})(?: \((\d{1,6})\))?$"#, in: lines[index - 1]),
                  lines[index - 2] == "\(departure[2]) ➞ \(arrival[2])",
                  let from = clock(departure), let to = clock(arrival)
            else { return nil }
            drafts.append(Draft(
                train: "\(train[0]) \(train[1])", alias: train[2].isEmpty ? nil : "\(train[0]) \(train[2])",
                from: departure[2], departure: from, to: arrival[2], arrival: to
            ))
            index += 2
        }
        return drafts.isEmpty ? nil : drafts
    }

    /// bahn.de until 2023: two lines per train, the train in brackets after the departure.
    private static func formerLegs(_ lines: [String]) -> [Draft]? {
        var drafts: [Draft] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("ab ") || line.hasPrefix("an ") else { index += 1; continue }
            guard index + 1 < lines.count,
                  let departure = groups(#"^ab (\d{1,2}):(\d{2}) (.+?)(?: - Gleis \S+(?: \S+)?)? \((\p{L}{1,4}) *(\d{1,5})\)$"#, in: line),
                  let arrival = groups(#"^an (\d{1,2}):(\d{2}) (.+?)(?: - Gleis \S+(?: \S+)?)?$"#, in: lines[index + 1]),
                  let from = clock(departure), let to = clock(arrival)
            else { return nil }
            drafts.append(Draft(
                train: "\(departure[3]) \(departure[4])", from: departure[2], departure: from, to: arrival[2], arrival: to
            ))
            index += 2
        }
        return drafts.isEmpty ? nil : drafts
    }

    private static func clock(_ groups: [String]) -> (hour: Int, minute: Int)? {
        guard let hour = Int(groups[0]), let minute = Int(groups[1]), hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }

    /// The capture groups of `pattern` when it matches the whole of `text`; a group that took no part is empty.
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

private extension Calendar {
    /// The first time the clock shows `time` after `date`.
    func next(_ time: (hour: Int, minute: Int), after date: Date) -> Date? {
        nextDate(after: date, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0), matchingPolicy: .nextTime)
    }
}

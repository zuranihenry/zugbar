import Foundation

/// SBB trains, e.g. the ECE's Giruno, have Wi-Fi but no trip portal. Being on it still tells which train the
/// user is on, among the few that just left their boarding stop.
public enum SBB {
    /// The DHCP domain of SBB's train Wi-Fi, "guest.freewlan.sbb.ch".
    public static func isTrainWiFi(domain: String?) -> Bool {
        guard let domain = domain?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).lowercased()
        else { return false }
        return domain == "freewlan.sbb.ch" || domain.hasSuffix(".freewlan.sbb.ch")
    }

    /// Trains from the boarding stop that may be the SBB train the user is on: leaving in the last 75 or the next
    /// 15 minutes (boarding early), and run by SBB in Germany: an ECE, or an EC or IC going to or coming from
    /// Switzerland. ICEs to Switzerland are DB's, with DB's Wi-Fi. Closest to when the user joined the Wi-Fi first.
    public static func candidates(_ departures: [TransitousClient.Departure], now: Date, joined: Date) -> [TransitousClient.Departure] {
        departures
            .filter { departure in
                guard !departure.cancelled, !departure.isRegional, let time = departure.time,
                      time <= now.addingTimeInterval(15 * 60), time >= now.addingTimeInterval(-75 * 60)
                else { return false }
                let name = Transitous.normalize(departure.displayName)
                return name.hasPrefix("ECE") || (departure.servesSwitzerland && !name.hasPrefix("ICE"))
            }
            .sorted { abs(($0.time ?? .distantPast).timeIntervalSince(joined)) < abs(($1.time ?? .distantPast).timeIntervalSince(joined)) }
    }

    /// The Transitous stop ID in a stop ID of a train followed online, "2-de-DELFI_de:00001:10:15:3".
    public static func transitousStopID(_ id: String?) -> String? {
        guard let id, let dash = id.firstIndex(of: "-"), !id[..<dash].isEmpty, id[..<dash].allSatisfy(\.isNumber)
        else { return nil }
        let stopID = id[id.index(after: dash)...]
        return stopID.contains(":") ? String(stopID) : nil
    }

    /// Whether the train still takes the user from `boarding` to `destination`, by station name.
    public static func serves(_ status: TrainStatus, from boarding: String, to destination: String) -> Bool {
        guard let start = status.stops.firstIndex(where: { !$0.cancelled && StationName.same($0.name, boarding) }) else { return false }
        return status.stops[(start + 1)...].contains { !$0.cancelled && !$0.passed && StationName.same($0.name, destination) }
    }

    /// The plan moved to the train the user actually got on: the same stops by name, and the same connection.
    public static func plan(_ plan: JourneyPlan, on trainName: String, from boarding: String, to destination: String,
                            now: Date = Date()) -> JourneyPlan {
        var moved = JourneyPlan(trainName: trainName, connection: plan.connection)
        moved.updated = now
        moved.pendingBoarding = boarding
        moved.pendingDestination = destination
        return moved
    }
}

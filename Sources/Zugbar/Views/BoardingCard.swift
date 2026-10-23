import SwiftUI
import ZugbarCore

/// While waiting for a train followed online: when and where it leaves from the user's stop, and how far away it still is.
struct BoardingCard: View {
    @Bindable var monitor: TrainMonitor
    let status: TrainStatus
    let stop: Stop
    @Environment(\.strings) private var strings

    var body: some View {
        let now = monitor.now
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(strings.boardingAt, systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                Button { monitor.journey.toggleBoarding(stop) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(strings.removeBoarding)
                    .accessibilityLabel(strings.removeBoarding)
            }
            // One element for VoiceOver, without the remove button above.
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.name).font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    if !stop.cancelled, let departure = stop.departure {
                        Label(MenuTitle.countdown(to: departure, from: now, nowLabel: strings.now), systemImage: "timer")
                            .monospacedDigit()
                    }
                    DepartureTime(stop: stop)
                    if stop.cancelled {
                        Text(strings.cancelled).foregroundStyle(.red).fontWeight(.semibold)
                    } else if let track = strings.track(of: stop) {
                        Label(track, systemImage: "signpost.right")
                            .foregroundStyle(stop.trackChanged ? Color.orange : Color.primary)
                    }
                }
                .font(.callout)
                if !stop.cancelled, let approach = approach(at: now) {
                    Text(approach)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !stop.delayReasons.isEmpty {
                    Label(stop.delayReasons.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(at: now))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .cardStyle()
    }

    /// e.g. "Boarding at Dornstadt, 27:00, 09:27, Track 4, 1 stop before yours".
    private func spoken(at now: Date) -> String {
        var parts = [strings.boardingAt + " " + stop.name]
        if stop.cancelled {
            parts.append(strings.cancelled)
        } else {
            if let departure = stop.departure {
                parts.append(strings.spokenCountdown(to: departure, from: now, roundingUp: false))
                parts.append(departure.formatted(date: .omitted, time: .shortened))
            }
            if let track = strings.track(of: stop) { parts.append(track) }
            if let approach = approach(at: now) { parts.append(approach) }
        }
        parts += stop.delayReasons
        return parts.joined(separator: ", ")
    }

    /// e.g. "3 stops before yours · last Brückenfeld · 64 km away", or "Train arrives in 2:30".
    private func approach(at now: Date) -> String? {
        if stop.isCurrent(at: now) { return strings.trainAtPlatform }
        guard let count = status.stopsBefore(stop, at: now) else { return nil }
        var parts: [String] = []
        if count == 0, let arrival = stop.arrival {
            parts.append(strings.trainArrives(MenuTitle.countdown(to: arrival, from: now, nowLabel: strings.now)))
        } else if count > 0 {
            parts.append(strings.stopsBefore(count))
            if let last = status.lastStop(before: stop, at: now) { parts.append(strings.lastStop(last.name)) }
        }
        if let position = monitor.trainPosition, let coordinate = stop.coordinate {
            let kilometers = Int(position.distance(to: coordinate).rounded())
            if kilometers >= 1 { parts.append(strings.kilometersAway(kilometers)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The planned departure, and the expected one next to it when they differ, like on DB's departure boards.
private struct DepartureTime: View {
    let stop: Stop

    var body: some View {
        HStack(spacing: 4) {
            if let planned = stop.scheduledDeparture ?? stop.scheduledArrival {
                Text(planned, format: .dateTime.hour().minute())
                    .strikethrough(stop.cancelled)
                    .foregroundStyle(isLate ? .secondary : .primary)
            }
            if isLate, let expected = stop.departure, let delay = stop.departureDelayMinutes {
                Text(expected, format: .dateTime.hour().minute())
                    .foregroundStyle(delay >= 5 ? .red : .orange)
                    .fontWeight(.semibold)
            }
        }
        .monospacedDigit()
    }

    private var isLate: Bool { (stop.departureDelayMinutes ?? 0) > 0 && !stop.cancelled }
}

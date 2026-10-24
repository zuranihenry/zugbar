import SwiftUI
import ZugbarCore

/// The user's destination on the followed train, and the train they change to there.
struct JourneyCard: View {
    @Bindable var monitor: TrainMonitor
    let destination: Stop
    /// When the destination is the next stop, which then has no card of its own.
    var showsDelayReasons = false
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(strings.yourDestination, systemImage: "flag.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let arrival = destination.arrival, arrival > monitor.now {
                    Label(MenuTitle.countdown(to: arrival, from: monitor.now, nowLabel: strings.now), systemImage: "timer")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { monitor.journey.toggleDestination(destination) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(strings.removeDestination)
                    .accessibilityLabel(strings.removeDestination)
            }
            HStack(spacing: 8) {
                Text(destination.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                if let arrival = destination.arrival {
                    Text(arrival, format: .dateTime.hour().minute()).monospacedDigit().strikethrough(destination.cancelled)
                }
                if destination.cancelled {
                    Text(strings.cancelled).fontWeight(.semibold).foregroundStyle(.red)
                } else {
                    DelayBadge(minutes: destination.delayMinutes)
                    if let track = strings.track(of: destination) {
                        Text(track).foregroundStyle(destination.trackChanged ? Color.orange : Color.secondary)
                    }
                }
            }
            .font(.callout)
            if destination.cancelled {
                Label(strings.noStopHere, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if showsDelayReasons, !destination.delayReasons.isEmpty {
                Label(destination.delayReasons.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !destination.cancelled, CoachSequence.numbersCoaches(monitor.status?.trainName) {
                SeatRow(
                    editor: monitor.journey.seatEditor, field: .destination, seat: monitor.journey.plan?.seat,
                    sequence: monitor.journey.coachSequence(at: destination)
                ) { monitor.journey.setSeat($0) }
            }

            Divider()

            if let connection = monitor.journey.plan?.connection {
                ConnectionRow(
                    connection: connection, arrival: destination.arrival, editor: monitor.journey.seatEditor,
                    sequence: monitor.journey.coachSequence(at: destination, connection: connection),
                    setSeat: { monitor.journey.setSeat($0, connection: true) }
                ) { monitor.journey.removeConnection() }
            } else if monitor.journey.connections.isAdding {
                ConnectionPicker(monitor: monitor)
            } else {
                Button { monitor.journey.connections.isAdding = true } label: {
                    Label(strings.addConnection, systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            PermissionNotice(monitor: monitor, compact: true)
        }
        .padding(10)
        .cardStyle()
    }
}

private struct ConnectionRow: View {
    let connection: Connection
    let arrival: Date?
    let editor: SeatEditor
    /// Where the connection's coaches stop where it leaves.
    let sequence: CoachSequence?
    let setSeat: (Seat?) -> Void
    let remove: () -> Void
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary)
                Text(connection.name).fontWeight(.semibold)
                Text("→ \(connection.finalStop ?? connection.headsign ?? "")").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(strings.removeConnection)
                    .accessibilityLabel(strings.removeConnection)
            }
            HStack(spacing: 8) {
                if let departure = connection.departure {
                    Text(departure, format: .dateTime.hour().minute()).monospacedDigit()
                }
                DelayBadge(minutes: connection.delayMinutes)
                if let track = connection.track {
                    Text(strings.track(track)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let transfer = connection.transfer(after: arrival) {
                    Text(strings.transfer(transfer))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: transfer))
                }
            }
            .font(.callout)
            .padding(.leading, 22)
            if !connection.cancelled, CoachSequence.numbersCoaches(connection.name) {
                SeatRow(editor: editor, field: .connection, seat: connection.seat, sequence: sequence, save: setSeat)
                    .padding(.leading, 22)
            }
        }
    }

    private func color(for transfer: Connection.Transfer) -> Color {
        switch transfer {
        case .comfortable: .green
        case .tight: .orange
        case .atRisk, .cancelled: .red
        }
    }
}

private struct ConnectionPicker: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings

    var body: some View {
        @Bindable var search = monitor.journey.connections
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary)
                TextField(strings.continueTo, text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = monitor.journey.connections.targets.first { monitor.journey.connections.choose(first) } }
                    .onExitCommand { monitor.journey.connections.isAdding = false }
                Button { monitor.journey.connections.isAdding = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(strings.cancel)
                    .accessibilityLabel(strings.cancel)
            }
            .font(.callout)

            ForEach(monitor.journey.connections.targets.prefix(4)) { station in
                Button { monitor.journey.connections.choose(station) } label: {
                    Label(station.name, systemImage: "tram")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
            }

            ForEach(monitor.journey.connections.options, id: \.tripID) { option in
                ConnectionOption(option: option) { monitor.journey.chooseConnection(option) }
            }

            if let message = monitor.journey.connections.message {
                HStack {
                    Text(strings.message(message)).font(.caption).foregroundStyle(.secondary)
                    if message == .regionalOff {
                        Spacer()
                        Button(strings.enableRegional) { monitor.journey.connections.enableRegionalAndRetry() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct ConnectionOption: View {
    let option: Connection
    let action: () -> Void
    @Environment(\.strings) private var strings

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let departure = option.departure {
                    Text(departure, format: .dateTime.hour().minute()).monospacedDigit().frame(width: 42, alignment: .leading)
                }
                Text(option.name)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                if let finalArrival = option.finalArrival {
                    Text(strings.arrives(finalArrival.formatted(.dateTime.hour().minute()))).foregroundStyle(.secondary)
                } else if let finalStop = option.finalStop {
                    Text("→ \(finalStop)").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                DelayBadge(minutes: option.delayMinutes).font(.caption)
                if let track = option.track {
                    Text(track).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

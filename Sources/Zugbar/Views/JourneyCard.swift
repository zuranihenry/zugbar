import SwiftUI
import ZugbarCore

/// The user's destination on the followed train, and the train they change to there.
struct JourneyCard: View {
    @Bindable var monitor: TrainMonitor
    let destination: Stop
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
                Button { monitor.toggleDestination(destination) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(strings.removeDestination)
            }
            HStack(spacing: 8) {
                Text(destination.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                if let arrival = destination.arrival {
                    Text(arrival, format: .dateTime.hour().minute()).monospacedDigit()
                }
                DelayBadge(minutes: destination.delayMinutes)
                if let track = destination.track {
                    Text(strings.track(track)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Divider()

            if let connection = monitor.plan?.connection {
                ConnectionRow(connection: connection, arrival: destination.arrival) { monitor.removeConnection() }
            } else if monitor.isAddingConnection {
                ConnectionPicker(monitor: monitor)
            } else {
                Button { monitor.isAddingConnection = true } label: {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary)
                TextField(strings.continueTo, text: $monitor.connectionQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = monitor.connectionTargets.first { monitor.chooseConnectionTarget(first) } }
                    .onExitCommand { monitor.isAddingConnection = false }
                Button { monitor.isAddingConnection = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if !monitor.portalConnections.isEmpty, monitor.connectionQuery.isEmpty {
                Text(strings.fromICEPortal).font(.caption).foregroundStyle(.secondary)
                ForEach(monitor.portalConnections, id: \.tripID) { option in
                    ConnectionOption(option: option) { monitor.chooseConnection(option) }
                }
            }

            ForEach(monitor.connectionTargets.prefix(4)) { station in
                Button { monitor.chooseConnectionTarget(station) } label: {
                    Label(station.name, systemImage: "tram")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
            }

            ForEach(monitor.connectionOptions, id: \.tripID) { option in
                ConnectionOption(option: option) { monitor.chooseConnection(option) }
            }

            if let message = monitor.connectionMessage {
                Text(strings.message(message)).font(.caption).foregroundStyle(.secondary)
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

import SwiftUI
import ZugbarCore

/// Shown when no train is connected: follow a long-distance train by name, or a regional one via a station.
struct TrainPicker: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings
    @AppStorage("regionalTrains") private var regionalTrains = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(strings.notConnected).font(.headline)
            Text(strings.joinHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // MenuBarExtra windows truncate multi-line text unless it may grow vertically.
                .fixedSize(horizontal: false, vertical: true)

            if !monitor.suggestions.isEmpty {
                Suggestions(monitor: monitor, regionalTrains: regionalTrains)
            }

            HStack {
                TextField(strings.trainPlaceholder, text: $monitor.trainDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { monitor.trackTrain() }
                Button(strings.followButton) { monitor.trackTrain() }
                    .disabled(monitor.trainDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)

            if let message = monitor.lookupMessage {
                Text(strings.message(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if monitor.selectedStation == nil {
                LiveNow(monitor: monitor)
            }

            if regionalTrains {
                StationPicker(monitor: monitor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear { monitor.loadLiveTrains() }
    }
}

private struct Suggestions: View {
    let monitor: TrainMonitor
    let regionalTrains: Bool
    @Environment(\.strings) private var strings

    var body: some View {
        let items = monitor.suggestions.filter { item in
            if case .line = item { return regionalTrains }
            return true
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(strings.forYou)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items, id: \.self) { item in
                            Button { monitor.open(item) } label: {
                                Label(item.title, systemImage: "clock.arrow.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .chipStyle()
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button(strings.forget) { monitor.forget(item) } }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct LiveNow: View {
    let monitor: TrainMonitor
    @Environment(\.strings) private var strings

    var body: some View {
        let fastest = LiveTrain.fastest(monitor.liveTrains)
        let delayed = LiveTrain.mostDelayed(monitor.liveTrains.filter { !fastest.contains($0) })
        if !monitor.liveTrains.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    SectionTitle(strings.liveNow)
                    Spacer()
                    Button { monitor.surpriseMe() } label: {
                        Label(strings.surpriseMe, systemImage: "dice")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                ForEach(fastest) { train in
                    LiveRow(train: train, icon: "bolt.fill", tint: .yellow, value: strings.averageSpeed(train.averageSpeed)) {
                        monitor.follow(train)
                    }
                    .help(strings.fastestHelp)
                }
                ForEach(delayed) { train in
                    LiveRow(train: train, icon: "tortoise.fill", tint: .red, value: strings.delay(train.delayMinutes)) {
                        monitor.follow(train)
                    }
                    .help(strings.delayedHelp)
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct LiveRow: View {
    let train: LiveTrain
    let icon: String
    let tint: Color
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 14)
                Text(train.name).fontWeight(.semibold).lineLimit(1).fixedSize()
                Text("→ \(train.to)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value).monospacedDigit().foregroundStyle(tint == .red ? Color.red : Color.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StationPicker: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.regionalHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(strings.stationPlaceholder, text: $monitor.stationQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = monitor.stations.first { monitor.choose(first) } }
                if !monitor.stationQuery.isEmpty {
                    Button { monitor.clearStation() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(strings.otherStation)
                        .accessibilityLabel(strings.otherStation)
                }
            }

            if monitor.selectedStation == nil {
                ForEach(monitor.stations.prefix(5)) { station in
                    Button { monitor.choose(station) } label: {
                        Label(station.name, systemImage: "tram")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            } else if !monitor.departures.isEmpty {
                LineChips(lines: monitor.lines, selection: $monitor.selectedLine)
                DepartureList(monitor: monitor)
            }

            if let message = monitor.pickerMessage {
                Text(strings.message(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LineChips: View {
    let lines: [String]
    @Binding var selection: String?
    @Environment(\.strings) private var strings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(strings.allLines, selected: selection == nil) { selection = nil }
                ForEach(lines, id: \.self) { line in
                    chip(line, selected: selection == line) { selection = selection == line ? nil : line }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .chipStyle(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

private struct DepartureList: View {
    let monitor: TrainMonitor

    var body: some View {
        let departures = monitor.filteredDepartures
        let likely = monitor.likelyDeparture
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(departures) { departure in
                        DepartureRow(departure: departure, now: monitor.now, isLikely: departure.id == likely?.id) {
                            monitor.follow(departure)
                        }
                        .id(departure.id)
                    }
                }
            }
            .frame(height: min(CGFloat(max(departures.count, 1)) * 40, 240))
            .onAppear { scroll(proxy, departures: departures, likely: likely) }
            .onChange(of: monitor.selectedLine) { scroll(proxy, departures: monitor.filteredDepartures, likely: monitor.likelyDeparture) }
        }
    }

    /// Start at the train that just left, with upcoming ones below it.
    private func scroll(_ proxy: ScrollViewProxy, departures: [TransitousClient.Departure], likely: TransitousClient.Departure?) {
        let target = likely ?? departures.first { ($0.time ?? .distantFuture) > monitor.now }
        if let target { proxy.scrollTo(target.id, anchor: .top) }
    }
}

private struct DepartureRow: View {
    let departure: TransitousClient.Departure
    let now: Date
    let isLikely: Bool
    let action: () -> Void
    @Environment(\.strings) private var strings

    var body: some View {
        let departed = (departure.time ?? .distantFuture) <= now
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    if let time = departure.time {
                        Text(time, format: .dateTime.hour().minute())
                            .monospacedDigit()
                            .frame(width: 42, alignment: .leading)
                    }
                    Text(departure.line)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Text(departure.headsign ?? "")
                        .lineLimit(1)
                        .strikethrough(departure.cancelled)
                    Spacer(minLength: 4)
                    DelayBadge(minutes: departure.delayMinutes).font(.caption)
                    if let track = departure.track {
                        Text(track).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if departed, let time = departure.time {
                    HStack(spacing: 6) {
                        Text(strings.departedAgo(Int(now.timeIntervalSince(time) / 60)))
                        if isLikely {
                            Text(strings.likelyYours)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 50)
                }
            }
            .font(.callout)
            .opacity(departed && !isLikely ? 0.55 : 1)
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.trailing, 12)
        }
        .buttonStyle(.plain)
        .help(strings.follow(departure.displayName))
    }
}

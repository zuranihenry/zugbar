import ServiceManagement
import SwiftUI
import ZugbarCore

/// How the panel arranges itself. The popover is one fixed-width column; the window adapts to its size.
enum PanelLayout: Equatable {
    case popover
    /// One column; the map is hidden when there's no room for it.
    case column(mapHeight: CGFloat?)
    /// Details on the left, a large map on the right.
    case split
}

struct StatusPanel: View {
    @Bindable var monitor: TrainMonitor
    var layout: PanelLayout = .popover
    @AppStorage("showMap") private var showMap = true
    @AppStorage("estimatedSpeed") private var estimatedSpeed = true
    @Environment(\.strings) private var strings

    private var isWindow: Bool { layout != .popover }

    var body: some View {
        Group {
            if layout == .split, let status = monitor.status {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        details(status, map: nil)
                        Divider()
                        Footer(monitor: monitor, isWindow: true)
                    }
                    .frame(width: 360)
                    TrainMap(monitor: monitor, status: status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let status = monitor.status {
                        details(status, map: mapHeight)
                    } else {
                        TrainPicker(monitor: monitor)
                            .overlay(alignment: .topTrailing) { if !isWindow { PopOutButton() } }
                    }
                    Divider()
                    Footer(monitor: monitor, isWindow: isWindow)
                }
            }
        }
        .padding(14)
        .frame(width: isWindow ? nil : 340)
        .frame(maxWidth: isWindow ? .infinity : nil, maxHeight: isWindow ? .infinity : nil, alignment: .top)
        .modifier(ClassicBackground())
        .onAppear { monitor.refreshNotificationPermission() }
    }

    private var mapHeight: CGFloat? {
        switch layout {
        case .popover: showMap ? 180 : nil
        case .column(let height): height
        case .split: nil
        }
    }

    @ViewBuilder
    private func details(_ status: TrainStatus, map: CGFloat?) -> some View {
        TripHeader(status: status, showsPopOut: !isWindow)
        // Data that stopped coming, e.g. while the train Wi-Fi is down: the times shown may be stale.
        if let last = monitor.lastUpdate, monitor.now.timeIntervalSince(last) > 90 {
            Label(strings.offlineSince(last.formatted(date: .omitted, time: .shortened)), systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        let waitingAt = status.waitingStop(monitor.journey.plan?.boardingStopID, at: monitor.now)
        if let waitingAt {
            BoardingCard(monitor: monitor, status: status, stop: waitingAt)
        }
        let estimate = estimatedSpeed ? monitor.estimates.speed(status, at: monitor.now) : nil
        SpeedRow(speed: monitor.displaySpeed, top: monitor.topSpeed, online: status.isOnline,
                 estimate: estimate?.speed, source: estimate?.source ?? .basic)
        if estimate != nil, monitor.estimates.profileState == .serverDown {
            Label(strings.overpassDown, systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let internet = status.internet {
            WiFiRow(internet: internet, measured: monitor.link.reading, now: monitor.now)
        }
        if DataSaver.shared.allowance != nil || DataSaver.shared.isOn {
            DataRow(saver: DataSaver.shared)
        }
        if let progress = status.progress {
            ProgressView(value: progress)
        }
        if let map {
            TrainMap(monitor: monitor, status: status).frame(height: map)
        }
        if waitingAt == nil, let next = status.nextStop, next.id != monitor.journey.destination?.id {
            NextStopCard(stop: next, now: monitor.now)
        }
        if let destination = monitor.journey.destination {
            // Takes over the delay reasons from the next stop card hidden above.
            JourneyCard(monitor: monitor, destination: destination,
                        showsDelayReasons: waitingAt == nil && status.nextStop?.id == destination.id)
        }
        StopList(monitor: monitor, status: status, fillsHeight: isWindow)
        if let ride = monitor.trips.live, (ride.samples?.count ?? 0) > 1 {
            RideSection(trip: ride)
        }
    }
}

/// The ride so far below the stop list; folded away until opened, to keep the popover short.
private struct RideSection: View {
    let trip: Trip
    @AppStorage("showRideCharts") private var showCharts = false
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { showCharts.toggle() } } label: {
                Label(strings.rideCharts, systemImage: showCharts ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showCharts { RideCharts(trip: trip) }
        }
    }
}

private struct TripHeader: View {
    let status: TrainStatus
    let showsPopOut: Bool
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.trainName ?? "–").font(.headline)
                    if let destination = status.destination {
                        Text(strings.to(destination)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(status.provider)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .badgeStyle()
                if showsPopOut { PopOutButton() }
            }
            if let vehicle = status.vehicle {
                Text(vehicle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Opens the panel as its own window; sits top right so it's easy to find.
private struct PopOutButton: View {
    @Environment(\.strings) private var strings
    @Environment(\.appActions) private var actions

    var body: some View {
        Button { actions.openWindow() } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.callout.weight(.medium))
                .frame(width: 26, height: 26)
                .mapButtonStyle()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(strings.openWindow)
        .accessibilityLabel(strings.openWindow)
    }
}

private struct SpeedRow: View {
    let speed: Int?
    let top: Int
    let online: Bool
    let estimate: Int?
    var source: SpeedEstimator.Source = .basic
    @Environment(\.strings) private var strings

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            if let speed {
                Text("\(speed)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
                Text("km/h").foregroundStyle(.secondary).fixedSize()
            } else if let estimate {
                Text("≈ \(estimate)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text("km/h").foregroundStyle(.secondary).fixedSize()
                Text(strings.estimateLabel(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(strings.estimateHelp(source))
            } else if online {
                Label(strings.speedOnlyOnBoard, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(strings.noGPS, systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if top > 0 {
                Label(strings.top(top), systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .help(strings.topHelp)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts: [String] = []
        if let speed {
            parts.append(strings.spokenSpeed(speed))
        } else if let estimate {
            parts.append(strings.spokenEstimate(estimate, source: strings.estimateLabel(source)))
        } else {
            parts.append(online ? strings.speedOnlyOnBoard : strings.noGPS)
        }
        if top > 0 { parts.append(strings.top(top)) }
        return parts.joined(separator: ", ")
    }
}

private struct WiFiRow: View {
    let internet: Internet
    /// What Zugbar measured itself, when it decides the level shown.
    let measured: LinkProbe.Reading?
    let now: Date
    @Environment(\.strings) private var strings

    var body: some View {
        HStack {
            Label(wifiText, systemImage: icon(for: internet.current))
                .foregroundStyle(internet.current == .good ? Color.secondary : Color.orange)
                .help(help)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var help: String {
        var lines: [String] = []
        if let measured { lines.append(strings.wifiMeasured(measured)) }
        if internet.learned { lines.append(strings.wifiForecastHelp) }
        return lines.joined(separator: "\n")
    }

    private var wifiText: String {
        let reading = measured.flatMap { $0.quality == internet.current ? $0 : nil }
        var text = strings.wifi(internet.current, measured: reading)
        if let next = internet.next, next != internet.current, let change = internet.nextChange, change > now {
            let minutes = max(1, Int((change.timeIntervalSince(now) / 60).rounded()))
            text += " · " + strings.wifiChange(to: next, minutes: minutes)
        }
        return text
    }

    private func icon(for quality: Internet.Quality) -> String {
        switch quality {
        case .good: "wifi"
        case .weak: "wifi.exclamationmark"
        case .none: "wifi.slash"
        }
    }
}

/// What's left of the Wi-Fi's data limit, and whether Zugbar holds back because of it.
private struct DataRow: View {
    let saver: DataSaver
    @Environment(\.strings) private var strings

    var body: some View {
        HStack {
            if let allowance = saver.allowance {
                Label(strings.allowanceLeft(allowance) + (saver.isOn ? " · " + strings.savingData : ""), systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(allowance.fractionUsed >= AllowanceWarning.threshold ? Color.orange : Color.secondary)
            } else {
                Label(strings.savingData, systemImage: "leaf")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(strings.dataSavingHint)
    }
}

private struct NextStopCard: View {
    let stop: Stop
    let now: Date
    @Environment(\.strings) private var strings

    var body: some View {
        let isCurrent = stop.isCurrent(at: now)
        VStack(alignment: .leading, spacing: 4) {
            Text(isCurrent ? strings.nowAt : strings.nextStop)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(stop.name).font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                if isCurrent {
                    if let departure = stop.departure {
                        Label(strings.departs(departure.formatted(.dateTime.hour().minute())), systemImage: "arrow.right")
                    }
                } else if let arrival = stop.arrival {
                    Label(MenuTitle.countdown(to: arrival, from: now, nowLabel: strings.now), systemImage: "timer")
                        .monospacedDigit()
                    Text(arrival, format: .dateTime.hour().minute())
                }
                if stop.cancelled {
                    Text(strings.cancelled).foregroundStyle(.red).fontWeight(.semibold)
                } else {
                    DelayBadge(minutes: stop.delayMinutes)
                    if let track = strings.track(of: stop) {
                        Label(track, systemImage: "signpost.right")
                            .foregroundStyle(stop.trackChanged ? Color.orange : Color.primary)
                    }
                }
            }
            .font(.callout)
            if !stop.delayReasons.isEmpty {
                Label(stop.delayReasons.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(isCurrent: isCurrent))
    }

    /// "Next stop Altstadt in 15 min, 18:28, 3 min late, Track 10", instead of each piece on its own.
    private func spoken(isCurrent: Bool) -> String {
        var parts = ["\(isCurrent ? strings.nowAt : strings.nextStop) \(stop.name)"]
        if isCurrent {
            if let departure = stop.departure { parts.append(strings.departs(departure.formatted(.dateTime.hour().minute()))) }
        } else if let arrival = stop.arrival {
            parts.append(strings.spokenCountdown(to: arrival, from: now))
            parts.append(arrival.formatted(.dateTime.hour().minute()))
        }
        if stop.cancelled {
            parts.append(strings.cancelled)
        } else {
            if let delay = stop.delayMinutes, delay != 0 { parts.append(strings.spokenDelay(delay)) }
            if let track = strings.track(of: stop) { parts.append(track) }
        }
        parts += stop.delayReasons
        return parts.joined(separator: ", ")
    }
}

struct DelayBadge: View {
    let minutes: Int?

    var body: some View {
        if let minutes, minutes != 0 {
            Text(minutes > 0 ? "+\(minutes)" : "\(minutes)")
                .foregroundStyle(minutes >= 5 ? .red : .orange)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
}

private struct StopList: View {
    let monitor: TrainMonitor
    let status: TrainStatus
    var fillsHeight = false
    @Environment(\.strings) private var strings
    @AppStorage("showPassedStops") private var showPassedStops = false

    var body: some View {
        let passed = status.stops.filter(\.passed)
        let visible = showPassedStops ? status.stops : status.stops.filter { !$0.passed }
        VStack(alignment: .leading, spacing: 4) {
            if !passed.isEmpty {
                Button { withAnimation { showPassedStops.toggle() } } label: {
                    Label(strings.passedStops(passed.count), systemImage: showPassedStops ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { stop in
                            // A button rather than a tap gesture, so the keyboard and VoiceOver can reach it too.
                            Button { monitor.journey.toggleDestination(stop) } label: {
                                StopRow(
                                    stop: stop,
                                    isNext: stop.id == status.nextStop?.id,
                                    isDestination: stop.id == monitor.journey.plan?.destinationStopID,
                                    isBoarding: stop.id == monitor.journey.plan?.boardingStopID
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(stop.passed)
                            .id(stop.id)
                            .contextMenu { menu(for: stop) }
                        }
                    }
                }
                // Popovers size to their content, so the list needs an explicit height there.
                .frame(minHeight: fillsHeight ? 150 : nil, maxHeight: fillsHeight ? .infinity : nil)
                .frame(height: fillsHeight ? nil : min(CGFloat(visible.count) * 27, 220))
                .onAppear { proxy.scrollTo(status.nextStop?.id, anchor: .center) }
            }
            if monitor.journey.plan?.destinationStopID == nil {
                Text(strings.destinationHint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for stop: Stop) -> some View {
        if !stop.passed {
            let isDestination = stop.id == monitor.journey.plan?.destinationStopID
            Button(isDestination ? strings.removeDestination : strings.getOffHere) { monitor.journey.toggleDestination(stop) }
            // Only useful before boarding, i.e. when following a train online.
            if monitor.isOnline {
                let isBoarding = stop.id == monitor.journey.plan?.boardingStopID
                Button(isBoarding ? strings.removeBoarding : strings.getOnHere) { monitor.journey.toggleBoarding(stop) }
            }
        }
    }
}

private struct StopRow: View {
    let stop: Stop
    let isNext: Bool
    let isDestination: Bool
    let isBoarding: Bool
    @Environment(\.strings) private var strings

    var body: some View {
        HStack(spacing: 10) {
            marker.frame(width: 14)
            Text(stop.name)
                .fontWeight(isNext || isDestination ? .semibold : .regular)
                .strikethrough(stop.cancelled)
                .lineLimit(1)
            Spacer()
            if stop.cancelled {
                Text(strings.cancelled).font(.caption.weight(.semibold)).foregroundStyle(.red)
            } else {
                DelayBadge(minutes: stop.delayMinutes).font(.caption)
            }
            if let time = stop.arrival ?? stop.departure {
                Text(time, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .strikethrough(stop.cancelled)
                    .foregroundStyle(.secondary)
            }
        }
        .help(stop.cancelled ? strings.noStopHere : "")
        .font(.callout)
        .opacity(stop.passed ? 0.45 : 1)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.spokenStop(stop, isNext: isNext, isDestination: isDestination, isBoarding: isBoarding))
        .accessibilityHint(stop.passed ? "" : isDestination ? strings.removeDestination : strings.getOffHere)
    }

    @ViewBuilder
    private var marker: some View {
        if isDestination {
            Image(systemName: "flag.checkered").font(.caption).foregroundStyle(Color.accentColor)
        } else if isBoarding {
            Image(systemName: "figure.walk").font(.caption).foregroundStyle(Color.accentColor)
        } else {
            Circle()
                .fill(isNext ? Color.accentColor : Color.secondary)
                .frame(width: isNext ? 10 : 7, height: isNext ? 10 : 7)
        }
    }
}

private struct Footer: View {
    @Bindable var monitor: TrainMonitor
    let isWindow: Bool
    @Environment(\.strings) private var strings
    @Environment(\.appActions) private var actions
    @AppStorage("showMap") private var showMap = true
    @AppStorage("windowShowMap") private var windowShowMap = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        HStack(spacing: 14) {
            if monitor.status != nil {
                Button { monitor.endTracking() } label: {
                    Label(strings.stop, systemImage: "stop.fill")
                }
                .actionButtonStyle()
                .controlSize(.small)
                .help(strings.endTracking)
            }
            Spacer()
            if let status = monitor.status {
                if isWindow {
                    Button { windowShowMap.toggle() } label: { Image(systemName: windowShowMap ? "map.fill" : "map") }
                        .help(strings.map)
                        .accessibilityLabel(strings.map)
                    Button { alwaysOnTop.toggle() } label: { Image(systemName: alwaysOnTop ? "pin.fill" : "pin") }
                        .help(strings.alwaysOnTop)
                        .accessibilityLabel(strings.alwaysOnTop)
                } else {
                    Button { showMap.toggle() } label: { Image(systemName: showMap ? "map.fill" : "map") }
                        .help(strings.map)
                        .accessibilityLabel(strings.map)
                }
                Button {
                    let waiting = status.waitingStop(monitor.journey.plan?.boardingStopID, at: monitor.now)
                    SharePicker.show(strings.shareText(status, destination: monitor.journey.destination,
                                                       connection: monitor.journey.plan?.connection, waitingAt: waiting),
                                     copyTitle: strings.copy)
                } label: { Image(systemName: "square.and.arrow.up") }
                    .help(strings.share)
            }
            Button { PopUpMenu.show(menuItems) } label: { Image(systemName: "ellipsis.circle") }
                .help(strings.moreOptions)
                .accessibilityLabel(strings.moreOptions)
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private var menuItems: [PopUpMenu.Item] {
        var items: [PopUpMenu.Item] = []
        if let release = monitor.updates.available {
            items.append(.init(title: strings.updateAvailable(release.version)) { NSWorkspace.shared.open(release.url) })
            items.append(.separator)
        }
        if let links = monitor.status?.links, !links.isEmpty {
            items.append(.header(strings.openIn))
            items += links.map { link in .init(title: strings.title(of: link.kind)) { NSWorkspace.shared.open(link.url) } }
            items.append(.separator)
        }
        if let plan = monitor.journey.plan, plan.connection != nil || (monitor.isOnline && plan.boardingStopID != nil) {
            items.append(.init(title: strings.takeNextTrain) { monitor.takeNextTrain() })
        }
        if monitor.status != nil {
            items.append(.init(title: strings.reload) { monitor.refresh() })
        }
        if !isWindow {
            items.append(.init(title: strings.openWindow) { actions.openWindow() })
        }
        items.append(.init(title: strings.settings) { actions.openSettings() })
        items.append(.separator)
        items.append(.init(title: strings.quit) { NSApp.terminate(nil) })
        return items
    }
}

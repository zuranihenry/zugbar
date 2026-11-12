import ServiceManagement
import SwiftUI
import ZugbarCore

enum SettingsTab: CaseIterable {
    case general, menuBar, notifications, trips, debug

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell.badge"
        case .trips: "clock.arrow.circlepath"
        case .debug: "ladybug"
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: strings.general
        case .menuBar: strings.menuBar
        case .notifications: strings.notifications
        case .trips: strings.trips
        case .debug: strings.debug
        }
    }

    @MainActor @ViewBuilder
    func view(monitor: TrainMonitor) -> some View {
        switch self {
        case .general: GeneralSettings(monitor: monitor)
        case .menuBar: MenuBarSettings()
        case .notifications: NotificationSettingsView(monitor: monitor)
        case .trips: TripsView(monitor: monitor)
        case .debug: DebugSettings(monitor: monitor)
        }
    }
}

/// Common frame for all tabs; the window resizes to each tab's height.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// Scrolls when the content outgrows the window (rows that appear later, a tall tab on a small screen).
    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(width: 480)
    }
}

struct GeneralSettings: View {
    let monitor: TrainMonitor
    @Environment(\.strings) private var strings
    @AppStorage("language") private var language = AppLanguage.system
    @AppStorage("regionalTrains") private var regionalTrains = true
    @AppStorage("estimatedSpeed") private var estimatedSpeed = true
    @AppStorage("trackProfiles") private var trackProfiles = false
    @AppStorage("learnSpeeds") private var learnSpeeds = true
    @AppStorage(UpdateChecker.enabledKey) private var checkForUpdates = true
    @AppStorage(DataSaver.settingKey) private var dataSaving = DataSaving.automatic

    var body: some View {
        SettingsPane {
            Section {
                Picker(strings.language, selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(strings.name(of: $0)).tag($0) }
                }
                Toggle(strings.launchAtLogin, isOn: Binding(get: { LoginItem.shared.isEnabled }, set: { LoginItem.shared.set($0) }))
                Toggle(strings.checkForUpdates, isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, enabled in if enabled { monitor.updates.check() } }
            }
            Section {
                Toggle(isOn: $regionalTrains) {
                    Text(strings.regionalTrains)
                    Text(strings.regionalTrainsHint)
                }
                Toggle(isOn: $estimatedSpeed) {
                    Text(strings.estimatedSpeedSetting)
                    Text(strings.estimatedHelp)
                }
                Toggle(isOn: $trackProfiles) {
                    Text(strings.trackProfiles)
                    Text(strings.trackProfilesHint)
                }
                .disabled(!estimatedSpeed)
                Toggle(isOn: $learnSpeeds) {
                    Text(strings.learnSpeeds)
                    Text(strings.learnHint)
                }
                Toggle(isOn: Binding(get: { monitor.calendar.isOn }, set: { monitor.calendar.set($0) })) {
                    Text(strings.calendarJourney)
                    Text(strings.calendarJourneyHint)
                }
                .disabled(!monitor.calendar.isAvailable)
                Picker(selection: $dataSaving) {
                    ForEach(DataSaving.allCases) { Text(strings.name(of: $0)).tag($0) }
                } label: {
                    Text(strings.dataSaving)
                    Text(strings.dataSavingHint)
                }
            }
            Section(strings.data) {
                LabeledContent(strings.suggestionHistory) {
                    Button(strings.clear, role: .destructive) { monitor.clearHistory() }
                }
                LabeledContent(strings.destinationAndConnection) {
                    Button(strings.clear, role: .destructive) { monitor.journey.clear() }
                }
                LabeledContent(strings.learnedSpeeds(monitor.estimates.learnedCellCount)) {
                    Button(strings.clear, role: .destructive) { monitor.estimates.clearLearnedSpeeds() }
                        .disabled(monitor.estimates.learnedCellCount == 0)
                }
                LabeledContent(strings.learnedWiFi(monitor.wifi.learnedCellCount)) {
                    Button(strings.clear, role: .destructive) { monitor.wifi.clear() }
                        .disabled(monitor.wifi.learnedCellCount == 0)
                }
            }
        }
    }

}

/// Trips recorded on board, with totals and CSV export.
struct TripsView: View {
    let monitor: TrainMonitor
    /// Made-up trips to show instead of the user's own, for screenshots.
    var madeUp: TripLog?
    /// The year under review once the user stepped away from the default. A plain `State` value: the `@State`
    /// macro needs a plugin the Command Line Tools lack.
    private var chosenYear = State<Int?>(initialValue: nil)
    @Environment(\.strings) private var strings

    var body: some View {
        // Demo mode shows made-up trips, so the tab has something on it without a ride.
        let log = madeUp ?? (monitor.demoMode ? DemoTrips.log : monitor.trips.log)
        let network = TravelledNetwork(trips: log.trips)
        // Latest first. This year, or the last one with trips; a chosen year stays until its trips are gone.
        let years = log.years()
        let year = chosenYear.wrappedValue.flatMap { years.contains($0) ? $0 : nil } ?? years.first ?? 0
        let index = years.firstIndex(of: year) ?? 0
        SettingsPane {
            if log.trips.isEmpty {
                Text(strings.noTrips).foregroundStyle(.secondary)
            } else {
                Section {
                    YearReviewGrid(review: log.review(year: year))
                    Button(strings.exportCSV) { export(log) }
                } header: {
                    HStack(spacing: 4) {
                        Text(String(year)).monospacedDigit()
                        Spacer()
                        // Only years with trips, and no arrows while there is just one.
                        if years.count > 1 {
                            Button { chosenYear.wrappedValue = years[index + 1] } label: { Image(systemName: "chevron.left") }
                                .disabled(index + 1 >= years.count)
                                .help(strings.earlierYear).accessibilityLabel(strings.earlierYear)
                            Button { chosenYear.wrappedValue = years[index - 1] } label: { Image(systemName: "chevron.right") }
                                .disabled(index == 0)
                                .help(strings.laterYear).accessibilityLabel(strings.laterYear)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Section {
                    if network.isEmpty {
                        // Trips from before paths were kept: nothing to draw yet.
                        Text(strings.travelledMapEmpty).font(.caption).foregroundStyle(.secondary)
                    } else if DataSaver.shared.isOn {
                        Text(strings.travelledMapSavingData).font(.caption).foregroundStyle(.secondary)
                    } else {
                        TravelledMap(network: network)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(strings.travelledMap)
                    }
                } footer: {
                    if !network.isEmpty, !DataSaver.shared.isOn {
                        Text(strings.travelledMapHint(missing: log.trips.count - network.tripCount))
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    ForEach(log.trips) { trip in
                        Group {
                            // Trips recorded before there were charts have no samples.
                            if (trip.samples?.count ?? 0) > 1 {
                                DisclosureGroup { RideCharts(trip: trip).padding(.vertical, 4) } label: { TripRow(trip: trip) }
                            } else {
                                TripRow(trip: trip)
                            }
                        }
                        .contextMenu {
                            Button(strings.deleteTrip, role: .destructive) { monitor.trips.delete(trip.id) }
                                .disabled(madeUp != nil || monitor.demoMode)
                        }
                    }
                }
            }
        }
    }

    private func export(_ log: TripLog) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Zugbar.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.csv().write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A year in a few figures, three to a row. A figure without data behind it is left out.
private struct YearReviewGrid: View {
    let review: YearReview
    @Environment(\.strings) private var strings

    private struct Figure: Identifiable {
        let value: String
        let label: String
        var help: String?
        var id: String { label }
    }

    var body: some View {
        let figures = figures
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: figures.count, by: 3)), id: \.self) { row in
                GridRow {
                    ForEach(figures[row..<min(row + 3, figures.count)]) { cell($0) }
                }
            }
            // Two station names need the whole width.
            if let pair = review.mostRidden {
                cell(Figure(value: "\(pair.from) ↔ \(pair.to)", label: strings.reviewMostRidden(pair.count)))
                    .gridCellColumns(3)
            }
        }
        .padding(.vertical, 2)
    }

    private var figures: [Figure] {
        var figures = [
            Figure(value: review.trips.formatted(), label: strings.reviewTrips(review.trips)),
            Figure(value: "\(Int(review.distance.rounded()).formatted()) km", label: strings.reviewDistance),
            Figure(value: Self.duration(review.duration), label: strings.reviewDuration),
        ]
        if let percent = review.onTimePercent {
            figures.append(Figure(value: strings.reviewPercent(percent), label: strings.reviewOnTime(of: review.tripsWithDelay),
                                  help: strings.reviewOnTimeHelp))
            figures.append(Figure(value: "\(review.delayMinutes.formatted()) min", label: strings.reviewDelay))
        }
        if let fastest = review.fastest {
            figures.append(Figure(value: "\(fastest.topSpeed) km/h", label: strings.reviewFastest(fastest.train)))
        }
        return figures
    }

    private func cell(_ figure: Figure) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(figure.value).font(.title3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(figure.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(figure.help ?? "")
        .accessibilityElement(children: .combine)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600), minutes = Int(seconds / 60) % 60
        return hours > 0 ? "\(hours.formatted()) h \(minutes) min" : "\(minutes) min"
    }
}

private struct TripRow: View {
    let trip: Trip
    @Environment(\.strings) private var strings
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // The origin gives way first: the destination is what tells trips apart.
                HStack(spacing: 0) {
                    Text("\(trip.train) · \(trip.from)").lineLimit(1)
                    Text(" → \(trip.to)").lineLimit(1).layoutPriority(1)
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let refund = trip.refund, let delay = trip.arrivalDelay {
                // An hour or more late: part of the fare may be due back.
                Image(systemName: "eurosign.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(strings.refundMarker(delay, percent: refund.rawValue))
                    .accessibilityLabel(strings.refundMarker(delay, percent: refund.rawValue))
            }
            DelayBadge(minutes: trip.arrivalDelay).font(.caption)
        }
        .help("\(trip.train) · \(trip.from) → \(trip.to)")
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let date = trip.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        let hours = Int(trip.duration / 3600), minutes = Int(trip.duration / 60) % 60
        let duration = hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
        return "\(date) · \(Int(trip.distance.rounded())) km · \(duration) · \(strings.top(trip.topSpeed))"
    }
}

/// Mirrors the system's login item state, which SwiftUI can't observe. Only works from the bundled .app.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    /// Reads the state back so the toggle shows what actually happened.
    func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        try? enabled ? service.register() : service.unregister()
        // Login items are switched off for Zugbar in System Settings; take the user there.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        isEnabled = service.status == .enabled
    }
}

struct MenuBarSettings: View {
    @Environment(\.strings) private var strings
    @AppStorage("showSpeed") private var showSpeed = true
    @AppStorage("showUnit") private var showUnit = true
    @AppStorage("menuBarEstimate") private var menuBarEstimate = true
    /// The General setting the estimate in the menu bar needs.
    @AppStorage("estimatedSpeed") private var estimatedSpeed = true
    @AppStorage("showTopSpeedFlame") private var showTopSpeedFlame = true
    @AppStorage("showStation") private var showStation = true
    @AppStorage("stationStyle") private var stationStyle = MenuTitleOptions.StationStyle.automatic
    @AppStorage("showCountdown") private var showCountdown = true
    @AppStorage("minutesOnly") private var minutesOnly = false

    var body: some View {
        SettingsPane {
            // One line at a fixed height: a preview that wraps differently per option would resize the
            // window on every toggle, and quick toggling made the form lose its sections.
            Section(strings.preview) {
                Text(preview)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            }
            Section {
                Toggle(strings.speed, isOn: $showSpeed)
                Toggle(strings.showUnit, isOn: $showUnit).disabled(!showSpeed)
                Toggle(strings.flame, isOn: $showTopSpeedFlame).disabled(!showSpeed)
                Toggle(isOn: $menuBarEstimate) {
                    Text(strings.menuBarEstimate)
                    Text(strings.menuBarEstimateHint)
                }
                .disabled(!showSpeed || !estimatedSpeed)
            }
            Section {
                Toggle(strings.nextStation, isOn: $showStation)
                Picker(strings.stationNames, selection: $stationStyle) {
                    Text(strings.stationAutomatic).tag(MenuTitleOptions.StationStyle.automatic)
                    Text(strings.stationFull).tag(MenuTitleOptions.StationStyle.full)
                    Text(strings.stationCompact).tag(MenuTitleOptions.StationStyle.compact)
                    Text(strings.stationShort).tag(MenuTitleOptions.StationStyle.short)
                }
                .disabled(!showStation)
                Toggle(strings.countdown, isOn: $showCountdown).disabled(!showStation)
                Toggle(strings.minutesOnly, isOn: $minutesOnly).disabled(!showStation || !showCountdown)
            }
        }
    }

    private var preview: String {
        let now = Date()
        let stop = Stop(id: "x", name: "Düsseldorf Flughafen Fernbahnhof", expectedArrival: now.addingTimeInterval(402))
        let options = MenuTitleOptions(
            showSpeed: showSpeed, showStation: showStation, showCountdown: showCountdown,
            showTopSpeedFlame: showTopSpeedFlame, stationStyle: stationStyle, showUnit: showUnit, minutesOnly: minutesOnly
        )
        // Shortened like the menu bar's, so "Automatic" shows what it does.
        let title = MenuTitle.fitted(options, width: MenuTitle.width) {
            MenuTitle.make(status: TrainStatus(provider: "", stops: [stop], nextStopID: "x"),
                           displaySpeed: 287, isTopSpeed: true, now: now, options: $0, nowLabel: strings.now)
        }
        return title.isEmpty ? "🚆" : title
    }
}

struct NotificationSettingsView: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings
    @AppStorage("notifications") private var notifications = true
    @AppStorage("wifiAlerts") private var wifiAlerts = false
    /// The General setting the Wi-Fi forecast comes from.
    @AppStorage("learnSpeeds") private var learnSpeeds = true

    var body: some View {
        @Bindable var journey = monitor.journey
        SettingsPane {
            if monitor.notificationPermission != .allowed, monitor.notificationPermission != nil {
                Section { PermissionNotice(monitor: monitor, compact: false) }
            }
            Section {
                Toggle(strings.notifications, isOn: $notifications)
            }
            Section(strings.arrivalReminders) {
                HStack(spacing: 6) {
                    ForEach(NotificationSettings.reminderChoices, id: \.self) { minutes in
                        Toggle(strings.minutesBefore(minutes), isOn: reminder(minutes, in: \.arrivalReminders))
                            .toggleStyle(.button)
                    }
                }
            }
            .disabled(!notifications)
            Section {
                HStack(spacing: 6) {
                    ForEach(NotificationSettings.reminderChoices, id: \.self) { minutes in
                        Toggle(strings.minutesBefore(minutes), isOn: reminder(minutes, in: \.departureReminders))
                            .toggleStyle(.button)
                    }
                }
            } header: {
                Text(strings.departureReminders)
            } footer: {
                Text(strings.departureRemindersHint).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!notifications)
            Section {
                Picker(strings.delayThreshold, selection: $journey.notificationSettings.delayThreshold) {
                    ForEach(NotificationSettings.thresholdChoices, id: \.self) { Text(strings.minutesBefore($0)).tag($0) }
                }
                Toggle(strings.trackChanges, isOn: $journey.notificationSettings.trackChanges)
                Toggle(strings.connectionAlerts, isOn: $journey.notificationSettings.connectionAlerts)
                Toggle(strings.passengerRightsHint, isOn: $journey.notificationSettings.passengerRights)
            }
            .disabled(!notifications)
            Section {
                Toggle(isOn: $wifiAlerts) {
                    Text(strings.wifiAlerts)
                    Text(strings.wifiAlertsHint)
                }
                .disabled(!learnSpeeds)
            }
            .disabled(!notifications)
        }
        .onAppear { monitor.refreshNotificationPermission() }
    }

    private func reminder(_ minutes: Int, in reminders: WritableKeyPath<NotificationSettings, Set<Int>>) -> Binding<Bool> {
        Binding(
            get: { monitor.journey.notificationSettings[keyPath: reminders].contains(minutes) },
            set: { on in
                if on { monitor.journey.notificationSettings[keyPath: reminders].insert(minutes) }
                else { monitor.journey.notificationSettings[keyPath: reminders].remove(minutes) }
            }
        )
    }
}

struct DebugSettings: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings
    @AppStorage("classicDesign") private var classicDesign = false
    @AppStorage(PortalRecorder.enabledKey) private var recordPortals = false
    @AppStorage("debugNotification") private var selectedSample = 0

    var body: some View {
        SettingsPane {
            Section(strings.state) {
                LabeledContent(strings.source, value: monitor.status?.provider ?? strings.none)
                LabeledContent(strings.lastUpdate, value: monitor.lastUpdate?.formatted(date: .omitted, time: .standard) ?? "–")
                LabeledContent(strings.permission, value: strings.permissionName(monitor.notificationPermission))
                LabeledContent(strings.trackProfiles, value: strings.profileStateName(monitor.estimates.profileState))
                if let error = monitor.lastError {
                    LabeledContent(strings.lastError, value: error).lineLimit(2)
                }
            }
            Section(strings.testNotifications) {
                HStack {
                    Picker(strings.testNotifications, selection: $selectedSample) {
                        ForEach(samples.indices, id: \.self) { index in
                            Text(strings.notification(samples[index]).0 + (index == 1 ? " + " + strings.connection : "")).tag(index)
                        }
                    }
                    .labelsHidden()
                    Button(strings.send) {
                        let index = min(selectedSample, samples.count - 1)
                        monitor.postTestNotification(samples[index], withConnection: index == 1)
                    }
                }
            }
            Section {
                Toggle(strings.demoMode, isOn: $monitor.demoMode)
                HStack {
                    Button(strings.planDemoJourney) { demo(monitor.demoPlanJourney) }
                    Spacer()
                    Button(strings.resetDemo) { monitor.demoResetScenario() }
                }
                HStack {
                    Button(strings.addDelay) { demo(monitor.demoAddDelay) }
                    Button(strings.changeTrack) { demo(monitor.demoChangeTrack) }
                    Button(strings.skipAhead) { demo(monitor.demoSkipAhead) }
                }
            } header: {
                Text(strings.demoScenario)
            }
            Section {
                Toggle(isOn: $recordPortals) {
                    Text(strings.recordPortals)
                    Text(strings.recordPortalsHint)
                }
                Button(strings.showRecordings) { PortalRecorder.showInFinder() }
            }
            Section {
                Toggle(strings.classicDesign, isOn: $classicDesign)
            }
        }
    }

    private var samples: [JourneyEvent] {
        [
            .arrivingSoon(stop: "Nürnberg Hbf", minutes: 5, track: "8"),
            .arrivingSoon(stop: "Nürnberg Hbf", minutes: 5, track: "8"),
            .departingSoon(stop: "Halle (Saale) Hbf", minutes: 10, track: "7"),
            .stopCancelled(stop: "Nürnberg Hbf"),
            .delayChanged(stop: "Nürnberg Hbf", from: 2, to: 9),
            .trackChanged(stop: "Nürnberg Hbf", from: "8", to: "10"),
            .connectionDelayChanged(name: "RE 1", from: 0, to: 6),
            .connectionTrackChanged(name: "RE 1", from: "12", to: "14"),
            .transferChanged(name: "RE 1", .tight(minutes: 3)),
            .transferChanged(name: "RE 1", .cancelled),
        ]
    }

    private func demo(_ action: () -> Void) {
        if !monitor.demoMode { monitor.demoMode = true }
        action()
    }
}

/// Explains that notifications need permission, with a button to grant it.
struct PermissionNotice: View {
    let monitor: TrainMonitor
    let compact: Bool
    @Environment(\.strings) private var strings
    @AppStorage("notifications") private var notificationsOn = true

    var body: some View {
        // Zugbar's own switch is off: the system's permission doesn't matter.
        switch notificationsOn ? monitor.notificationPermission : .allowed {
        case .notAsked, .denied:
            let denied = monitor.notificationPermission == .denied
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                Text(denied ? strings.notificationsOff : strings.notificationsNotAsked)
                    .font(compact ? .caption : .callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(denied ? strings.openSystemSettings : strings.allow) { monitor.requestNotificationPermission() }
                    .controlSize(compact ? .small : .regular)
            }
        case .unavailable:
            Text(strings.notificationsUnavailable).font(.caption).foregroundStyle(.secondary)
        case .allowed, nil:
            EmptyView()
        }
    }
}

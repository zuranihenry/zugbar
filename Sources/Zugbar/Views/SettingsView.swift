import ServiceManagement
import SwiftUI
import ZugbarCore

enum SettingsTab: CaseIterable {
    case general, menuBar, notifications, debug

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell.badge"
        case .debug: "ladybug"
        }
    }

    func title(_ strings: Strings) -> String {
        switch self {
        case .general: strings.general
        case .menuBar: strings.menuBar
        case .notifications: strings.notifications
        case .debug: strings.debug
        }
    }

    @MainActor @ViewBuilder
    func view(monitor: TrainMonitor) -> some View {
        switch self {
        case .general: GeneralSettings(monitor: monitor)
        case .menuBar: MenuBarSettings()
        case .notifications: NotificationSettingsView(monitor: monitor)
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
    @AppStorage("regionalTrains") private var regionalTrains = false
    @AppStorage("estimatedSpeed") private var estimatedSpeed = true
    @AppStorage("trackProfiles") private var trackProfiles = false
    @AppStorage("learnSpeeds") private var learnSpeeds = true
    @AppStorage(UpdateChecker.enabledKey) private var checkForUpdates = true

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
                    Text(strings.learnSpeedsHint)
                }
            }
            Section(strings.data) {
                LabeledContent(strings.suggestionHistory) {
                    Button(strings.clear, role: .destructive) { monitor.clearHistory() }
                }
                LabeledContent(strings.destinationAndConnection) {
                    Button(strings.clear, role: .destructive) { monitor.clearPlan() }
                }
                LabeledContent(strings.learnedSpeeds(monitor.learnedCellCount)) {
                    Button(strings.clear, role: .destructive) { monitor.clearLearnedSpeeds() }
                        .disabled(monitor.learnedCellCount == 0)
                }
            }
        }
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
    @AppStorage("showTopSpeedFlame") private var showTopSpeedFlame = true
    @AppStorage("showStation") private var showStation = true
    @AppStorage("stationStyle") private var stationStyle = MenuTitleOptions.StationStyle.full
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
                .disabled(!showSpeed)
            }
            Section {
                Toggle(strings.nextStation, isOn: $showStation)
                Picker(strings.stationNames, selection: $stationStyle) {
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
        let stop = Stop(id: "x", name: "Frankfurt (Main) Flughafen Fernbahnhof", expectedArrival: now.addingTimeInterval(402))
        let options = MenuTitleOptions(
            showSpeed: showSpeed, showStation: showStation, showCountdown: showCountdown,
            showTopSpeedFlame: showTopSpeedFlame, stationStyle: stationStyle, showUnit: showUnit, minutesOnly: minutesOnly
        )
        let title = MenuTitle.make(status: TrainStatus(provider: "", stops: [stop], nextStopID: "x"),
                                   displaySpeed: 287, isTopSpeed: true, now: now, options: options, nowLabel: strings.now)
        return title.isEmpty ? "🚆" : title
    }
}

struct NotificationSettingsView: View {
    @Bindable var monitor: TrainMonitor
    @Environment(\.strings) private var strings
    @AppStorage("notifications") private var notifications = true

    var body: some View {
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
                Picker(strings.delayThreshold, selection: $monitor.notificationSettings.delayThreshold) {
                    ForEach(NotificationSettings.thresholdChoices, id: \.self) { Text(strings.minutesBefore($0)).tag($0) }
                }
                Toggle(strings.trackChanges, isOn: $monitor.notificationSettings.trackChanges)
                Toggle(strings.connectionAlerts, isOn: $monitor.notificationSettings.connectionAlerts)
            }
            .disabled(!notifications)
        }
        .onAppear { monitor.refreshNotificationPermission() }
    }

    private func reminder(_ minutes: Int, in reminders: WritableKeyPath<NotificationSettings, Set<Int>>) -> Binding<Bool> {
        Binding(
            get: { monitor.notificationSettings[keyPath: reminders].contains(minutes) },
            set: { on in
                if on { monitor.notificationSettings[keyPath: reminders].insert(minutes) }
                else { monitor.notificationSettings[keyPath: reminders].remove(minutes) }
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
                LabeledContent(strings.trackProfiles, value: strings.profileStateName(monitor.profileState))
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
            .departingSoon(stop: "Frankfurt (Main) Hbf", minutes: 10, track: "7"),
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

    var body: some View {
        switch monitor.notificationPermission {
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

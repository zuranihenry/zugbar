import AppKit
import SwiftUI
import ZugbarCore

/// `Zugbar --screenshots docs/screenshots [station]` renders the panel with demo data for the README.
/// With a station, it also renders the regional picker with that station's live departures.
@MainActor
enum Screenshots {
    static func render(to directory: URL, station: String? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = settings(regional: false)

        // Fixed afternoon times so the timetable reads naturally.
        let iceNow = try! Date("2026-06-12T16:56:00Z", strategy: .iso8601)
        var ice = try! ICEPortal.parse(
            status: DemoProvider.resource("demo_db_status"), trip: DemoProvider.resource("demo_db_trip"), now: iceNow
        )
        ice.speed = 287

        let nuremberg = ice.stops.first { $0.name == "Nürnberg Hbf" }!
        let connection = Connection(
            tripID: "demo", name: "RE 1", headsign: "Regensburg Hbf", station: nuremberg.name,
            scheduledDeparture: nuremberg.scheduledArrival!.addingTimeInterval(14 * 60),
            expectedDeparture: nuremberg.scheduledArrival!.addingTimeInterval(14 * 60), track: "12",
            finalStop: "Regensburg Hbf", finalArrival: nuremberg.scheduledArrival!.addingTimeInterval(74 * 60)
        )
        let plan = JourneyPlan(trainName: ice.trainName!, destinationStopID: nuremberg.id, connection: connection)
        save(TrainMonitor(snapshot: ice, topSpeed: 300, now: iceNow, plan: plan), .english, dark: true, "panel-ice-dark", in: directory, defaults: defaults)

        var history = TrainHistory()
        for day in 1...4 {
            let date = Date().addingTimeInterval(Double(-day) * 86_400)
            history.record(.train("ICE 591"), at: date)
            history.record(.train("ICE 1081"), at: date.addingTimeInterval(-3600))
        }

        let discover = TrainMonitor(snapshot: nil, history: history)
        discover.loadLiveTrains()
        wait { !discover.liveTrains.isEmpty }
        save(discover, .english, dark: true, "panel-discover", in: directory, defaults: settings(regional: false))

        if let station {
            let monitor = TrainMonitor(snapshot: nil)
            monitor.stationQuery = station
            wait { !monitor.stations.isEmpty }
            if let first = monitor.stations.first { monitor.choose(first) }
            wait { !monitor.departures.isEmpty }
            monitor.loadLiveTrains()
            wait { !monitor.liveTrains.isEmpty }
            save(monitor, .german, dark: true, "panel-regional", in: directory, defaults: settings(regional: true))
        }
        exit(0)
    }

    private static func settings(regional: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "zugbar.screenshots")!
        defaults.removePersistentDomain(forName: "zugbar.screenshots")
        defaults.set(regional, forKey: "regionalTrains")
        // Liquid Glass doesn't render offscreen, so screenshots use the classic look.
        defaults.set(true, forKey: "classicDesign")
        return defaults
    }

    private static func wait(timeout: TimeInterval = 15, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func save(
        _ monitor: TrainMonitor, _ language: AppLanguage, dark: Bool, _ name: String,
        in directory: URL, defaults: UserDefaults
    ) {
        save(StatusPanel(monitor: monitor), language, dark: dark, name, in: directory, defaults: defaults)
    }

    /// Settings tabs, for checking layout (not used in the README).
    static func renderSettings(to directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let monitor = TrainMonitor(snapshot: nil)
        let defaults = settings(regional: false)
        save(GeneralSettings(monitor: monitor), .german, dark: true, "settings-general", in: directory, defaults: defaults)
        save(NotificationSettingsView(monitor: monitor), .german, dark: true, "settings-notifications", in: directory, defaults: defaults)
        save(DebugSettings(monitor: monitor), .german, dark: true, "settings-debug", in: directory, defaults: defaults)
        save(MenuBarSettings(), .german, dark: true, "settings-menubar", in: directory, defaults: defaults)
        save(TripsView(monitor: monitor), .german, dark: true, "settings-trips", in: directory, defaults: defaults)
        let iceNow = try! Date("2026-06-12T16:56:00Z", strategy: .iso8601)
        let ice = try! ICEPortal.parse(status: DemoProvider.resource("demo_db_status"), trip: DemoProvider.resource("demo_db_trip"), now: iceNow)
        let window = StatusPanel(monitor: TrainMonitor(snapshot: ice, now: iceNow), layout: .column(mapHeight: 240))
        save(window, .german, dark: true, "window", in: directory, defaults: defaults)
        let split = StatusPanel(monitor: TrainMonitor(snapshot: ice, now: iceNow), layout: .split).frame(width: 820, height: 620)
        save(split, .german, dark: true, "window-split", in: directory, defaults: defaults)
        exit(0)
    }

    private static func save<Content: View>(
        _ content: Content, _ language: AppLanguage, dark: Bool, _ name: String,
        in directory: URL, defaults: UserDefaults
    ) {
        let view = content
            .environment(\.strings, Strings(language))
            .environment(\.locale, language.locale)
            .defaultAppStorage(defaults)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .padding(1)

        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    }
}

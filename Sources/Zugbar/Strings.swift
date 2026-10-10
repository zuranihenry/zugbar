import SwiftUI
import ZugbarCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, german

    var id: String { rawValue }

    var isGerman: Bool {
        switch self {
        case .system: Locale.preferredLanguages.first?.hasPrefix("de") ?? false
        case .english: false
        case .german: true
        }
    }

    /// Keeps the user's region (24h clock etc.) and only swaps the language.
    var locale: Locale {
        switch self {
        case .system: .current
        case .english: Locale(languageCode: .english, languageRegion: Locale.current.region)
        case .german: Locale(languageCode: .german, languageRegion: Locale.current.region)
        }
    }
}

/// Two languages don't justify a string catalog, and catalogs need Xcode to compile.
struct Strings {
    let de: Bool

    init(_ language: AppLanguage) {
        de = language.isGerman
    }

    private func t(_ en: String, _ de: String) -> String { self.de ? de : en }

    // Panel
    func to(_ destination: String) -> String { t("to \(destination)", "nach \(destination)") }
    var noGPS: String { t("No GPS fix", "Kein GPS-Signal") }
    var speedOnlyOnBoard: String { t("Live speed is only available on board", "Live-Geschwindigkeit nur im Zug-WLAN") }
    func top(_ speed: Int) -> String { t("Top \(speed) km/h", "Max. \(speed) km/h") }
    var estimated: String { t("estimated", "geschätzt") }
    func estimateLabel(_ source: TrainMonitor.EstimateSource) -> String {
        switch source {
        case .basic: estimated
        case .learned: t("estimated · from your trips", "geschätzt · aus deinen Fahrten")
        case .trackProfile: estimatedFromProfile
        }
    }
    func estimateHelp(_ source: TrainMonitor.EstimateSource) -> String {
        switch source {
        case .basic: estimatedHelp
        case .learned: learnSpeedsHint
        case .trackProfile: trackProfilesHint
        }
    }
    var learnSpeeds: String { t("Learn from your trips", "Aus eigenen Fahrten lernen") }
    var learnSpeedsHint: String {
        t("On board, Zugbar notes how fast the train really is on each stretch and uses that for estimates. Stays on this Mac.",
          "Im Zug-WLAN merkt sich Zugbar, wie schnell der Zug auf jedem Streckenstück wirklich fährt, und nutzt das für Schätzungen. Bleibt auf diesem Mac.")
    }
    func learnedSpeeds(_ count: Int) -> String { t("Learned speeds (\(count) stretches)", "Gelernte Geschwindigkeiten (\(count) Streckenstücke)") }
    var estimatedFromProfile: String { t("estimated · track profile", "geschätzt · Streckenprofil") }
    var trackProfiles: String { t("Track profile from OpenStreetMap (experimental)", "Streckenprofil aus OpenStreetMap (experimentell)") }
    var trackProfilesHint: String {
        t("Uses the line's speed limits, acceleration and braking for a more realistic speed. Loads data from OpenStreetMap per section.",
          "Nutzt Streckenhöchstgeschwindigkeiten, Anfahren und Bremsen für eine realistischere Geschwindigkeit. Lädt pro Abschnitt Daten von OpenStreetMap.")
    }
    func profileStateName(_ state: TrainMonitor.ProfileState) -> String {
        switch state {
        case .off: t("not used", "nicht aktiv")
        case .loading: t("loading…", "lädt…")
        case .ready: t("ready", "bereit")
        case .unavailable: t("no data for this section", "keine Daten für diesen Abschnitt")
        case .serverDown: t("OpenStreetMap unreachable, retrying", "OpenStreetMap nicht erreichbar, neuer Versuch läuft")
        }
    }
    var overpassDown: String {
        t("OpenStreetMap is down right now, so this is a simpler estimate. Zugbar reconnects automatically.",
          "OpenStreetMap ist gerade nicht erreichbar, daher eine einfachere Schätzung. Zugbar verbindet sich automatisch neu.")
    }
    var menuBarEstimate: String { t("Estimated speed for trains followed online", "Geschätzte Geschwindigkeit bei online verfolgten Zügen") }
    var menuBarEstimateHint: String { t("Shown as “≈ 180”.", "Wird als „≈ 180“ angezeigt.") }
    var estimatedSpeedSetting: String { t("Estimated speed for trains followed online", "Geschätzte Geschwindigkeit bei online verfolgten Zügen") }
    var estimatedHelp: String { t("Average speed between the last and next stop, from the timetable", "Durchschnitt zwischen letztem und nächstem Halt, aus dem Fahrplan") }
    var topHelp: String { t("Highest speed this trip", "Höchstgeschwindigkeit dieser Fahrt") }
    var nowAt: String { t("Now at", "Aktuell in") }
    var nextStop: String { t("Next stop", "Nächster Halt") }
    var now: String { t("now", "jetzt") }
    func departs(_ time: String) -> String { t("departs \(time)", "ab \(time)") }
    func track(_ track: String) -> String { t("Track \(track)", "Gleis \(track)") }
    func wagonClass(_ number: Int) -> String {
        number == 1 ? t("1st class", "1. Klasse") : t("2nd class", "2. Klasse")
    }
    func quality(_ quality: Internet.Quality) -> String {
        switch quality {
        case .good: t("good", "gut")
        case .weak: t("weak", "schwach")
        case .none: t("offline", "kein Netz")
        }
    }
    func wifi(_ quality: Internet.Quality) -> String { t("Wi-Fi \(self.quality(quality))", "WLAN \(self.quality(quality))") }
    func wifiChange(to quality: Internet.Quality, minutes: Int) -> String {
        t("\(self.quality(quality)) in \(minutes) min", "in \(minutes) Min. \(self.quality(quality))")
    }
    var openIn: String { t("Open in", "Öffnen in") }
    func title(of link: TrainLink.Kind) -> String {
        switch link {
        case .portal(let name): name
        case .bahnExpert: "bahn.expert"
        case .zugfinder: "Zugfinder"
        }
    }

    // Picker
    var notConnected: String { t("Not connected to a train", "Nicht mit einem Zug verbunden") }
    var joinHint: String {
        t("Connect to the train's Wi-Fi (ICE, ÖBB Railjet, TGV INOUI) and it's picked up automatically. Or follow a train online:",
          "Verbinde dich mit dem Zug-WLAN (ICE, ÖBB Railjet, TGV INOUI), dann wird der Zug automatisch erkannt. Oder verfolge einen Zug online:")
    }
    var trainPlaceholder: String { t("Long-distance train, e.g. ICE 591", "Fernzug, z. B. ICE 591") }
    var followButton: String { t("Track", "Verfolgen") }
    var regionalHint: String { t("Regional train? Pick it from a station:", "Regionalzug? Wähle ihn an einem Bahnhof aus:") }
    var stationPlaceholder: String { t("Station, e.g. Köln Hbf", "Bahnhof, z. B. Köln Hbf") }
    var otherStation: String { t("Choose another station", "Anderen Bahnhof wählen") }
    var forYou: String { t("For you", "Für dich") }
    var forget: String { t("Forget", "Vergessen") }
    var liveNow: String { t("Live right now", "Gerade unterwegs") }
    func averageSpeed(_ speed: Int) -> String { "⌀ \(speed) km/h" }
    func delay(_ minutes: Int) -> String { "+\(minutes) min" }
    var fastestHelp: String { t("Fastest between two stops right now", "Gerade am schnellsten zwischen zwei Halten") }
    var delayedHelp: String { t("Most delayed right now", "Gerade am stärksten verspätet") }
    var surpriseMe: String { t("Surprise me", "Überrasch mich") }
    var allLines: String { t("All", "Alle") }
    func departedAgo(_ minutes: Int) -> String {
        minutes < 1 ? t("just left", "gerade abgefahren") : t("left \(minutes) min ago", "vor \(minutes) Min. abgefahren")
    }
    var likelyYours: String { t("probably yours", "vermutlich deiner") }
    func follow(_ name: String) -> String { t("Follow \(name)", "\(name) verfolgen") }

    func message(_ message: TrainMonitor.LookupMessage) -> String {
        switch message {
        case .lookingUp(let train): t("Looking up \(train)…", "Suche \(train)…")
        case .notRunning(let train): t("\(train) isn't running right now.", "\(train) fährt gerade nicht.")
        case .tripEnded: t("This trip has ended.", "Diese Fahrt ist beendet.")
        case .unreachable: t("Couldn't reach Transitous.", "Transitous ist nicht erreichbar.")
        }
    }

    func message(_ message: TrainMonitor.PickerMessage) -> String {
        switch message {
        case .noStation: t("No station found.", "Kein Bahnhof gefunden.")
        case .loadingDepartures: t("Loading departures…", "Lade Abfahrten…")
        case .noDepartures: t("No trains leaving soon.", "In Kürze keine Abfahrten.")
        case .failed: t("Couldn't load data.", "Daten konnten nicht geladen werden.")
        case .noDirectConnection: t("No direct connection found.", "Keine direkte Verbindung gefunden.")
        case .regionalOff: t("No direct long-distance connection.", "Keine direkte Fernverkehrsverbindung.")
        }
    }

    // Journey
    var getOffHere: String { t("Get off here", "Hier aussteigen") }
    var removeDestination: String { t("Remove destination", "Ziel entfernen") }
    var getOnHere: String { t("Get on here", "Hier einsteigen") }
    var removeBoarding: String { t("Remove boarding stop", "Einstieg entfernen") }
    var destinationHint: String { t("Click a stop to set it as your destination.", "Klicke auf einen Halt, um ihn als Ziel zu setzen.") }
    var yourDestination: String { t("Your destination", "Dein Ziel") }
    var boardingAt: String { t("Boarding at", "Einstieg in") }
    var addConnection: String { t("Add connection…", "Anschluss hinzufügen…") }
    var continueTo: String { t("Continue to, e.g. Wunstorf", "Weiter nach, z. B. Wunstorf") }
    var connection: String { t("Connection", "Anschluss") }
    var enableRegional: String { t("Include regional trains", "Regionalzüge einschalten") }
    func arrives(_ time: String) -> String { t("arr. \(time)", "an \(time)") }
    func transfer(_ transfer: Connection.Transfer) -> String {
        switch transfer {
        case .comfortable(let minutes): t("\(minutes) min to change", "\(minutes) Min. Umstieg")
        case .tight(let minutes): t("Tight: \(minutes) min", "Knapp: \(minutes) Min.")
        case .atRisk: t("Connection at risk", "Anschluss gefährdet")
        case .cancelled: t("Cancelled", "Fällt aus")
        }
    }
    var reload: String { t("Reload train data", "Zugdaten neu laden") }
    var cancelled: String { t("Cancelled", "Fällt aus") }
    var noStopHere: String { t("The train no longer stops here.", "Der Zug hält hier nicht mehr.") }
    var notifications: String { t("Notifications", "Benachrichtigungen") }

    func notification(_ event: JourneyEvent) -> (String, String?) {
        func trackText(_ track: String?) -> String? { track.map { self.track($0) } }
        switch event {
        case .arrivingSoon(let stop, let minutes, let track):
            return (t("\(stop) in \(minutes) min", "In \(minutes) Min. in \(stop)"), trackText(track))
        case .departingSoon(let stop, let minutes, let track):
            return (t("Departs \(stop) in \(minutes) min", "Abfahrt in \(stop) in \(minutes) Min."), trackText(track))
        case .stopCancelled(let stop):
            return (t("No stop at \(stop)", "Kein Halt in \(stop)"), t("The train no longer stops there.", "Der Zug hält dort nicht mehr."))
        case .delayChanged(let stop, let from, let to):
            return (t("\(stop): now \(signed(to)) min", "\(stop): jetzt \(signed(to)) Min."), t("Was \(signed(from)) min", "Vorher \(signed(from)) Min."))
        case .trackChanged(let stop, let from, let to):
            return (t("Track change at \(stop)", "Gleiswechsel in \(stop)"), t("Now track \(to) instead of \(from)", "Jetzt Gleis \(to) statt \(from)"))
        case .connectionDelayChanged(let name, let from, let to):
            return (t("\(name): now \(signed(to)) min", "\(name): jetzt \(signed(to)) Min."), t("Was \(signed(from)) min", "Vorher \(signed(from)) Min."))
        case .connectionTrackChanged(let name, let from, let to):
            return (t("\(name) now leaves from track \(to)", "\(name) fährt jetzt von Gleis \(to)"), t("Instead of track \(from)", "Statt Gleis \(from)"))
        case .transferChanged(let name, let transfer):
            return ("\(name): \(self.transfer(transfer))", nil)
        }
    }

    /// "then RE 1 at 19:15 from track 12 (10 min to change)"
    func connectionSummary(_ connection: Connection, arrival: Date?) -> String {
        var text = t("then \(connection.name)", "weiter mit \(connection.name)")
        if let departure = connection.departure {
            text += t(" at ", " um ") + departure.formatted(.dateTime.hour().minute())
        }
        if let track = connection.track {
            text += t(" from track \(track)", " von Gleis \(track)")
        }
        if let transfer = connection.transfer(after: arrival) {
            text += " (\(self.transfer(transfer)))"
        }
        return text
    }

    private func signed(_ minutes: Int) -> String { minutes > 0 ? "+\(minutes)" : "\(minutes)" }

    // Tracking, map, share, window
    var endTracking: String { t("Stop tracking", "Tracking beenden") }
    var stop: String { t("Stop", "Beenden") }
    var map: String { t("Map", "Karte") }
    var followTrain: String { t("Follow train", "Zug folgen") }
    var headingUp: String { t("Turn map with the train", "Karte in Fahrtrichtung drehen") }
    var zoomIn: String { t("Zoom in", "Vergrößern") }
    var zoomOut: String { t("Zoom out", "Verkleinern") }
    var wholeRoute: String { t("Whole route", "Ganze Strecke") }
    func passedStops(_ count: Int) -> String {
        count == 1 ? t("1 passed stop", "1 vergangener Halt") : t("\(count) passed stops", "\(count) vergangene Halte")
    }
    var share: String { t("Share trip", "Fahrt teilen") }
    var openWindow: String { t("Open in window", "In eigenem Fenster öffnen") }
    var alwaysOnTop: String { t("Keep on top", "Immer im Vordergrund") }
    var settings: String { t("Settings…", "Einstellungen…") }
    var settingsTitle: String { t("Zugbar Settings", "Zugbar-Einstellungen") }
    var fromICEPortal: String { t("From the ICE Portal", "Laut ICE Portal") }

    func shareText(_ status: TrainStatus, destination: Stop?, connection: Connection?) -> String {
        let train = status.trainName ?? "Zug"
        var text = t("I'm on \(train)", "Ich sitze im \(train)")
        if let destination, let arrival = destination.arrival {
            let time = arrival.formatted(.dateTime.hour().minute())
            text += t(", arriving at \(destination.name) at \(time)", " und komme um \(time) in \(destination.name) an")
            if let delay = destination.delayMinutes, delay > 0 { text += " (+\(delay))" }
        } else if let to = status.destination {
            text += t(" to \(to)", " nach \(to)")
        }
        text += "."
        if let connection, let departure = connection.departure {
            let time = departure.formatted(.dateTime.hour().minute())
            text += t(" Then \(connection.name) at \(time).", " Weiter mit \(connection.name) um \(time).")
        }
        if let link = status.links.first(where: { $0.kind == .bahnExpert }) { text += "\n\(link.url.absoluteString)" }
        return text
    }

    // Notification permission
    var notificationsOff: String { t("Notifications are off for Zugbar", "Benachrichtigungen sind für Zugbar aus") }
    var notificationsNotAsked: String { t("Allow notifications to get alerts for this trip", "Erlaube Benachrichtigungen, um zu dieser Fahrt informiert zu werden") }
    var allow: String { t("Allow", "Erlauben") }
    var openSystemSettings: String { t("Open System Settings", "Systemeinstellungen öffnen") }
    var notificationsUnavailable: String { t("Notifications only work in the installed app.", "Benachrichtigungen gehen nur in der installierten App.") }

    // Settings window
    var general: String { t("General", "Allgemein") }
    var arrivalReminders: String { t("Remind me before arrival", "Erinnerung vor Ankunft") }
    var departureReminders: String { t("Remind me before departure", "Erinnerung vor Abfahrt") }
    var departureRemindersHint: String {
        t("For trains followed online, once you've picked where you get on.", "Bei online verfolgten Zügen, sobald du einen Einstieg gewählt hast.")
    }
    func minutesBefore(_ minutes: Int) -> String { t("\(minutes) min", "\(minutes) Min.") }
    var delayThreshold: String { t("Report delay changes from", "Verspätungsänderungen melden ab") }
    var trackChanges: String { t("Track changes", "Gleiswechsel") }
    var connectionAlerts: String { t("Connection alerts", "Anschluss-Warnungen") }
    var debug: String { "Debug" }
    var testNotifications: String { t("Test notifications", "Testbenachrichtigungen") }
    var demoScenario: String { t("Demo train", "Demo-Zug") }
    var demoHint: String { t("Turns on demo mode. Changes show up within a few seconds.", "Schaltet den Demo-Modus ein. Änderungen erscheinen nach ein paar Sekunden.") }
    var planDemoJourney: String { t("Set destination and connection", "Ziel und Anschluss setzen") }
    var addDelay: String { t("+5 min delay", "+5 Min. Verspätung") }
    var changeTrack: String { t("Change track", "Gleis ändern") }
    var skipAhead: String { t("Skip 5 min ahead", "5 Min. vorspulen") }
    var resetDemo: String { t("Reset", "Zurücksetzen") }
    var state: String { t("State", "Zustand") }
    var source: String { t("Source", "Quelle") }
    var lastUpdate: String { t("Last update", "Letzte Daten") }
    var lastError: String { t("Last error", "Letzter Fehler") }
    var permission: String { t("Notification permission", "Benachrichtigungsrecht") }
    func permissionName(_ permission: Notifier.Permission?) -> String {
        switch permission {
        case .allowed: t("allowed", "erlaubt")
        case .denied: t("denied", "abgelehnt")
        case .notAsked: t("not asked yet", "noch nicht gefragt")
        case .unavailable: t("unavailable (not bundled)", "nicht verfügbar (kein App-Bundle)")
        case nil: "–"
        }
    }
    var reset: String { t("Reset", "Zurücksetzen") }
    var clearHistory: String { t("Clear suggestion history", "Verlauf der Vorschläge löschen") }
    var clearPlan: String { t("Clear destination and connection", "Ziel und Anschluss löschen") }
    var none: String { t("none", "keine") }
    var design: String { "Design" }
    var recordPortals: String { t("Record on-board portal data", "Zugportal-Daten aufzeichnen") }
    var recordPortalsHint: String {
        t("Saves the train Wi-Fi's raw responses about once a minute, for testing. Stays on this Mac.",
          "Speichert etwa einmal pro Minute die Rohdaten des Zug-WLANs, zum Testen. Bleibt auf diesem Mac.")
    }
    var showRecordings: String { t("Show recordings in Finder", "Aufzeichnungen im Finder zeigen") }
    var send: String { t("Send", "Senden") }
    var data: String { t("Data", "Daten") }
    var clear: String { t("Clear", "Löschen") }
    var suggestionHistory: String { t("Suggestion history", "Verlauf der Vorschläge") }
    var destinationAndConnection: String { t("Destination and connection", "Ziel und Anschluss") }
    var regionalTrainsHint: String { t("Pick S-Bahn and regional trains from a station's departures.", "S-Bahn und Regionalzüge über die Abfahrten eines Bahnhofs wählen.") }
    var preview: String { t("Preview", "Vorschau") }
    var showUnit: String { t("Show “km/h”", "„km/h“ anzeigen") }
    var stationNames: String { t("Station names", "Stationsnamen") }
    var stationFull: String { t("Full", "Voll") }
    var stationCompact: String { t("Compact", "Kompakt") }
    var stationShort: String { t("Short (12 characters)", "Kurz (12 Zeichen)") }
    var minutesOnly: String { t("Countdown in minutes only", "Countdown nur in Minuten") }
    var classicDesign: String { t("Classic design (macOS 14/15 look)", "Klassisches Design (Look von macOS 14/15)") }

    // Settings menu
    var menuBar: String { t("Menu bar", "Menüleiste") }
    var speed: String { t("Speed", "Geschwindigkeit") }
    var nextStation: String { t("Next station", "Nächster Halt") }
    var countdown: String { t("Countdown", "Countdown") }
    var flame: String { t("🔥 at top speed", "🔥 bei Höchstgeschwindigkeit") }
    var trainsSection: String { t("Trains", "Züge") }
    var appSection: String { t("App", "App") }
    var regionalTrains: String { t("Regional trains (beta)", "Regionalzüge (Beta)") }
    var language: String { t("Language", "Sprache") }
    func name(of language: AppLanguage) -> String {
        switch language {
        case .system: t("System", "System")
        case .english: "English"
        case .german: "Deutsch"
        }
    }
    var demoMode: String { t("Demo mode", "Demo-Modus") }
    var launchAtLogin: String { t("Launch at login", "Beim Anmelden starten") }
    var checkForUpdates: String { t("Check for updates", "Nach Updates suchen") }
    func updateAvailable(_ version: String) -> String { t("Update available: \(version)", "Update verfügbar: \(version)") }
    func updateNotification(_ version: String) -> (String, String) {
        (t("Zugbar \(version) is available", "Zugbar \(version) ist verfügbar"), t("Click to see what's new.", "Klicke, um die Neuerungen zu sehen."))
    }
    func stopFollowing(_ name: String) -> String { t("Stop following \(name)", "\(name) nicht mehr verfolgen") }
    var quit: String { t("Quit Zugbar", "Zugbar beenden") }
}

private struct StringsKey: EnvironmentKey {
    static let defaultValue = Strings(.system)
}

extension EnvironmentValues {
    var strings: Strings {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }
}

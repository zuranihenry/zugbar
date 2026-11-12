import AppKit
import EventKit
import Observation
import ZugbarCore

/// The journey from a booked connection in the calendar, as booking apps put it there. Off unless the user turns
/// it on. What's read stays in memory: nothing of it is saved, logged or recorded, and nothing is sent anywhere
/// until the user takes the suggestion, which then looks up the connection like picking it by hand does.
@MainActor
@Observable
final class CalendarJourneys {
    static let settingKey = "calendarJourney"

    /// Connections found in the next few hours' events; everything else in the calendar is dropped right away.
    private(set) var journeys: [CalendarJourney] = []
    /// The switch as the settings show it: on only with the system's permission.
    private(set) var isOn = false
    /// Suggestions the user waved off, until the app quits.
    private var dismissed: [CalendarJourney.Suggestion] = []

    /// Only while switched on, so that Zugbar holds no way into the calendar otherwise.
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var lastRead: Date?

    /// The system only asks an app that says what it wants the calendar for; `swift run` has no Info.plist to say it.
    let isAvailable = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil

    init() {
        isOn = isAvailable && UserDefaults.standard.bool(forKey: Self.settingKey)
            && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for calendar access the first time it's switched on; after a "no", only System Settings can change it.
    func set(_ on: Bool) {
        guard on, isAvailable else { return turnOff() }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            turnOn()
        case .notDetermined:
            let store = EKEventStore()
            Task {
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                if granted { turnOn() } else { turnOff() }
            }
        default:
            turnOff()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func turnOn() {
        UserDefaults.standard.set(true, forKey: Self.settingKey)
        isOn = true
    }

    private func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.settingKey)
        isOn = false
        store = nil
        lastRead = nil
        journeys = []
        dismissed = []
    }

    /// Looks at the next few hours once a minute while a train is followed.
    func refresh(now: Date) {
        guard isOn else { return }
        // Taken away in System Settings since.
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return turnOff() }
        if let lastRead, now.timeIntervalSince(lastRead) < 60 { return }
        lastRead = now
        let store = store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(CalendarJourney.lookAhead), calendars: nil
        )
        let found = store.events(matching: predicate).compactMap { event -> CalendarJourney? in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { return nil }
            return CalendarJourney(title: event.title ?? "", location: event.location, notes: event.notes, start: start, end: end)
        }
        if found != journeys { journeys = found }
    }

    /// No train to match: nothing is kept until there is one again.
    func pause() {
        lastRead = nil
        if !journeys.isEmpty { journeys = [] }
    }

    func suggestion(for status: TrainStatus?, plan: JourneyPlan?, now: Date) -> CalendarJourney.Suggestion? {
        guard isOn, let status else { return nil }
        return journeys.lazy.compactMap { $0.suggestion(for: status, plan: plan, now: now) }
            .first { !self.dismissed.contains($0) }
    }

    func dismiss(_ suggestion: CalendarJourney.Suggestion) {
        dismissed.append(suggestion)
    }
}

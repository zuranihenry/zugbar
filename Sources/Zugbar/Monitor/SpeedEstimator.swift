import Foundation
import Observation
import ZugbarCore

/// Speed and position of trains followed online, which have no GPS: from the timetable, sharpened by track
/// profiles (OpenStreetMap speed limits) and by speeds learned on board.
@MainActor
@Observable
final class SpeedEstimator {
    enum Source { case basic, learned, trackProfile }

    /// `serverDown`: no OpenStreetMap server answered; retried every two minutes. `unavailable`: no data for the section.
    enum ProfileState: Equatable { case off, loading, ready, unavailable, serverDown }

    /// OpenStreetMap speed limits per section; turned into a profile for the section's current times on use,
    /// since delays change them.
    private(set) var sectionLimits: [String: [Int]] = [:]
    /// Profiles for a section at given times, with learned speeds applied; built once, not every second.
    @ObservationIgnored private var timedProfiles: [String: SpeedProfile?] = [:]
    /// Where a train standing at a stop is; worked out once a second instead of every frame.
    @ObservationIgnored private var standing: Coordinate?
    private(set) var profileState: ProfileState = .off
    private(set) var learnedCellCount = 0

    /// Failed sections and when; retried after two minutes.
    @ObservationIgnored private var profileFailures: [String: Date] = [:]
    @ObservationIgnored private var profileRequests: Set<String> = []
    private let overpass = OverpassClient()
    private let limitCache = LimitCache()
    private let learnedStore = LearnedStore(file: "learned-speeds.json", empty: LearnedSpeeds())
    /// A copy of the learned speeds for synchronous use when building profiles; refreshed from the store.
    @ObservationIgnored private var learned = LearnedSpeeds()
    /// The current section and its speed profile, refreshed once a second so frames only interpolate.
    @ObservationIgnored private var section: (estimate: RouteEstimate, profile: SpeedProfile?, source: Source)?
    /// Basic profiles lowered to learned speeds, per section; built once instead of every second.
    @ObservationIgnored private var learnedProfiles: [String: SpeedProfile?] = [:]

    private var profilesEnabled: Bool { UserDefaults.standard.bool(forKey: "trackProfiles") }
    private var learningEnabled: Bool { UserDefaults.standard.object(forKey: "learnSpeeds") as? Bool ?? true }

    /// Estimated speed for a train followed online, from the section's speed profile when loaded, else from the timetable.
    /// `nil` when the setting is off or the train has live speed.
    func speed(_ status: TrainStatus, at now: Date) -> (speed: Int, source: Source)? {
        let enabled = UserDefaults.standard.object(forKey: "estimatedSpeed") as? Bool ?? true
        guard enabled, status.isOnline, status.speed == nil else { return nil }
        if let profile = profileEstimate(status, at: now) { return (profile.speed, .trackProfile) }
        if let section, section.source == .learned, let profile = section.profile,
           section.estimate == status.routeEstimate(at: now) {
            return (profile.state(after: now.timeIntervalSince(section.estimate.departure)).speed, .learned)
        }
        return status.estimatedSpeed(at: now).map { ($0, .basic) }
    }

    /// Speed and position from the section's speed profile, once loaded.
    func profileEstimate(_ status: TrainStatus, at date: Date) -> (speed: Int, position: Coordinate?)? {
        guard profilesEnabled, status.isOnline, let route = status.route, let estimate = status.routeEstimate(at: date),
              let profile = trackProfile(for: estimate, route: route)
        else { return nil }
        let state = profile.state(after: date.timeIntervalSince(estimate.departure))
        return (state.speed, route.coordinate(at: estimate.startDistance + state.distance))
    }

    /// Where a train without GPS is at `date`, along its route when the current section is known.
    func position(of status: TrainStatus, at date: Date) -> Coordinate? {
        guard let section, let route = status.route else { return standing ?? status.position(at: date) }
        let elapsed = date.timeIntervalSince(section.estimate.departure)
        let distance = section.profile?.state(after: elapsed).distance
            ?? section.estimate.sectionLength * min(max(elapsed / section.estimate.duration, 0), 1)
        return route.coordinate(at: section.estimate.startDistance + distance)
    }

    /// Picks the profile for the section the train is on; called once a second.
    func refreshSection(for status: TrainStatus?, at now: Date) {
        guard let status, status.position == nil, let estimate = status.routeEstimate(at: now) else {
            section = nil
            standing = status.flatMap { $0.position == nil ? $0.position(at: now) : nil }
            return
        }
        standing = nil
        let next: (SpeedProfile?, Source)
        if profilesEnabled, let route = status.route, let profile = trackProfile(for: estimate, route: route) {
            next = (profile, .trackProfile)
        } else if learningEnabled, let route = status.route, let profile = learnedProfile(for: estimate, route: route) {
            next = (profile, .learned)
        } else {
            next = (estimate.basicProfile, .basic)
        }
        if section?.estimate != estimate || section?.profile != next.0 { section = (estimate, next.0, next.1) }
    }

    /// Loads the profile for the section the train is on, if enabled. Called after each update.
    func prepareProfile(for status: TrainStatus) {
        guard profilesEnabled, status.isOnline else {
            if profileState != .off { profileState = .off }
            return
        }
        guard let route = status.route, let estimate = status.routeEstimate(at: Date()) else { return }
        if sectionLimits[estimate.key] != nil {
            if profileState != .ready { profileState = .ready }
        } else {
            loadProfile(for: estimate, route: route)
        }
    }

    /// On board, remember how fast the train really is here, to improve estimates for trains followed online.
    func learn(from status: TrainStatus) {
        guard learningEnabled, !status.isOnline, let position = status.position, let speed = status.speed else { return }
        let kind = TrainKind.of(status.trainName)
        // Near a stop this train is braking or speeding up, which says nothing about trains running through.
        let metersPerSecond = Double(speed) / 3.6
        let reach = metersPerSecond * metersPerSecond / (2 * min(kind.acceleration, kind.braking)) + 300
        if status.stops.contains(where: { stop in
            !stop.cancelled && (stop.coordinate.map { $0.distance(to: position) * 1000 < reach } ?? false)
        }) {
            return
        }
        learned.record(position, speed: speed, kind: kind)
        learnedCellCount = learned.cellCount
        let store = learnedStore
        Task { await store.update { $0.record(position, speed: speed, kind: kind) } }
    }

    func loadLearnedSpeeds() {
        let store = learnedStore
        Task {
            learned = await store.value
            learnedCellCount = learned.cellCount
            timedProfiles.removeAll()
        }
    }

    func clearLearnedSpeeds() {
        learned = LearnedSpeeds()
        learnedCellCount = 0
        learnedProfiles.removeAll()
        timedProfiles.removeAll()
        let store = learnedStore
        Task { await store.clear() }
    }

    /// The basic profile with learned speeds applied, when they cover at least a fifth of the section.
    private func learnedProfile(for estimate: RouteEstimate, route: Route) -> SpeedProfile? {
        let key = "\(estimate.key)|\(estimate.departure.timeIntervalSince1970)|\(estimate.arrival.timeIntervalSince1970)"
        if let cached = learnedProfiles[key] { return cached }
        let points = route.points(from: estimate.startDistance, to: estimate.endDistance)
        let samples = min(400, max(2, Int(estimate.sectionLength / 200) + 1))
        let cap = min(estimate.kind.maxSpeed, max(80, estimate.averageSpeed * 14 / 10))
        let applied = learned.apply(to: Array(repeating: cap, count: samples), along: points, kind: estimate.kind)
        let profile = applied.covered * 5 >= samples
            ? SpeedProfile(length: estimate.sectionLength, limits: applied.limits, duration: estimate.duration, kind: estimate.kind)
            : nil
        if learnedProfiles.count > 200 { learnedProfiles.removeAll() }
        learnedProfiles[key] = profile
        return profile
    }

    /// The track profile for the section at its current times.
    private func trackProfile(for estimate: RouteEstimate, route: Route) -> SpeedProfile? {
        guard let limits = sectionLimits[estimate.key] else { return nil }
        let key = "\(estimate.key)|\(estimate.departure.timeIntervalSince1970)|\(estimate.arrival.timeIntervalSince1970)"
        if let cached = timedProfiles[key] { return cached }
        let applied = learningEnabled
            ? learned.apply(to: limits, along: route.points(from: estimate.startDistance, to: estimate.endDistance), kind: estimate.kind).limits
            : limits
        let profile = SpeedProfile(length: estimate.sectionLength, limits: applied, duration: estimate.duration, kind: estimate.kind)
        if timedProfiles.count > 200 { timedProfiles.removeAll() }
        timedProfiles[key] = profile
        return profile
    }

    private func loadProfile(for estimate: RouteEstimate, route: Route) {
        guard !profileRequests.contains(estimate.key) else { return }
        if let failed = profileFailures[estimate.key], Date().timeIntervalSince(failed) < 120 { return }
        profileRequests.insert(estimate.key)
        profileState = .loading
        let points = route.points(from: estimate.startDistance, to: estimate.endDistance)
        let cacheKey = LimitCache.key(for: points)
        let overpass = overpass, cache = limitCache
        Task {
            // Matching tracks to the route is a bit of work, so keep it off the main thread.
            let result: Result<[Int]?, Error> = await Task.detached {
                if let cached = await cache.limits(for: cacheKey) { return .success(cached) }
                guard points.count >= 2 else { return .success(nil) }
                let samples = min(2000, max(2, Int(estimate.sectionLength / 100) + 1))
                // Main lines ship with the app; only other sections need a public Overpass server.
                if let tracks = TrackBundle.shared?.tracks(along: points) {
                    let limits = SpeedProfile.limits(along: points, samples: samples, tracks: tracks)
                    await cache.store(limits, for: cacheKey)
                    return .success(limits)
                }
                do {
                    let tracks = try await overpass.tracks(along: points)
                    // No tagged tracks is an answer too: remembered, so it isn't asked again every two minutes.
                    guard !tracks.isEmpty else {
                        await cache.store([], for: cacheKey)
                        return .success(nil)
                    }
                    let limits = SpeedProfile.limits(along: points, samples: samples, tracks: tracks)
                    await cache.store(limits, for: cacheKey)
                    return .success(limits)
                } catch {
                    return .failure(error)
                }
            }.value
            profileRequests.remove(estimate.key)
            if case .success(let limits?) = result, limits.count >= 2 {
                sectionLimits[estimate.key] = limits
                profileState = .ready
            } else {
                profileFailures[estimate.key] = Date()
                if case .failure = result { profileState = .serverDown } else { profileState = .unavailable }
            }
        }
    }
}

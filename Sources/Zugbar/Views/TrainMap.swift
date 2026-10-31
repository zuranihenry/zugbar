import MapKit
import SwiftUI
import ZugbarCore

/// Route and current position. On board this is GPS; for trains followed online it's estimated from the timetable.
struct TrainMap: View {
    @Bindable var monitor: TrainMonitor
    let status: TrainStatus
    @Environment(\.strings) private var strings
    @AppStorage("mapHeadingUp") private var headingUp = false
    @AppStorage("mapTrackSpeeds") private var showsTrackSpeeds = false
    /// Whether the map can be seen. A plain `State` value: the `@State` macro needs a plugin the Command Line Tools lack.
    private var visibility = State(initialValue: Visibility())

    private final class Visibility {
        var appeared = false
        var onScreen = true
        /// In the monitor's count of maps shown, which asks for smooth frames.
        var counted = false
    }

    /// Spelled out: older compilers make the memberwise one private because of `visibility`.
    init(monitor: TrainMonitor, status: TrainStatus) {
        self.monitor = monitor
        self.status = status
    }

    var body: some View {
        let stretches = monitor.map.trackStretches
        let route = status.route.map { Self.thinned($0.points).map(CLLocationCoordinate2D.init) }
            ?? status.stops.compactMap { $0.coordinate.map(CLLocationCoordinate2D.init) }
        let position = monitor.trainPosition
        let highlighted = [monitor.journey.plan?.destinationStopID, monitor.journey.plan?.boardingStopID].compactMap { $0 }
        @Bindable var map = monitor.map

        Map(position: $map.camera) {
            if showsTrackSpeeds, !stretches.isEmpty {
                ForEach(stretches.indices, id: \.self) { index in
                    MapPolyline(coordinates: stretches[index].points.map(CLLocationCoordinate2D.init))
                        .stroke(Self.color(for: stretches[index].band), lineWidth: 4)
                }
            } else if route.count > 1 {
                MapPolyline(coordinates: route).stroke(.secondary, lineWidth: 3)
            }
            ForEach(status.stops) { stop in
                if let coordinate = stop.coordinate {
                    Annotation(stop.name, coordinate: CLLocationCoordinate2D(coordinate), anchor: .center) {
                        Circle()
                            .fill(highlighted.contains(stop.id) ? Color.accentColor : (stop.passed ? Color.gray : Color.white))
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                            .frame(width: highlighted.contains(stop.id) ? 10 : 7)
                    }
                    .annotationTitles(highlighted.contains(stop.id) ? .visible : .hidden)
                }
            }
            if let position {
                Annotation(status.trainName ?? "", coordinate: CLLocationCoordinate2D(position)) {
                    Image(systemName: "tram.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 2)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {}
        .overlay(alignment: .topTrailing) {
            MapControlGroup {
                // Like Apple Maps: free → follow the train → follow, turned with it → free.
                MapControl(icon: trackingIcon, help: trackingHelp) { cycleTracking(position) }
                    .disabled(position == nil)
                Divider().frame(width: 18)
                MapControl(icon: "arrow.up.left.and.arrow.down.right", help: strings.wholeRoute) {
                    monitor.map.followsTrain = false
                    withAnimation { fitRoute(route + [position].compactMap { $0.map(CLLocationCoordinate2D.init) }) }
                }
                Divider().frame(width: 18)
                MapControl(icon: showsTrackSpeeds ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent",
                           help: strings.trackSpeeds(shown: showsTrackSpeeds)) { showsTrackSpeeds.toggle() }
                    .disabled(status.route == nil)
            }
            .padding(8)
        }
        .overlay(alignment: .topLeading) {
            if showsTrackSpeeds, !stretches.isEmpty { SpeedLegend().padding(8) }
        }
        // Keyed by the route's size, not its points: cheap to compare on every frame.
        .task(id: showsTrackSpeeds ? status.route.map { "\($0.points.count)|\($0.length)" } : nil) {
            guard showsTrackSpeeds, let points = status.route.map({ Self.thinned($0.points) }) else {
                monitor.map.trackStretches = []
                return
            }
            monitor.map.trackStretches = await Task.detached(priority: .utility) {
                TrackSpeeds.stretches(along: points) { TrackBundle.shared?.limit(at: $0) }
            }.value
        }
        .overlay(alignment: .bottomTrailing) {
            MapControlGroup {
                MapControl(icon: "plus", help: strings.zoomIn) { zoom(by: 0.5, train: position) }
                Divider().frame(width: 18)
                MapControl(icon: "minus", help: strings.zoomOut) { zoom(by: 2, train: position) }
            }
            .padding(8)
        }
        .onAppear {
            if !monitor.map.followsTrain { fitRoute(route + [position].compactMap { $0.map(CLLocationCoordinate2D.init) }) }
        }
        .onChange(of: position) { _, newPosition in
            guard monitor.map.followsTrain, let newPosition, !monitor.map.movingProgrammatically,
                  Date().timeIntervalSince(monitor.map.touchedAt) > 2
            else { return }
            // Follow frame by frame without animation; the marker itself moves at a constant pace.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                monitor.map.camera = .camera(camera(at: newPosition))
            }
            monitor.map.expectedCenter = newPosition
        }
        // Counts as shown only while its window can be seen: a window minimized or behind others stays open.
        .background(WindowVisibility { visibility.wrappedValue.onScreen = $0; countShown() })
        .onAppear { visibility.wrappedValue.appeared = true; countShown() }
        .onDisappear { visibility.wrappedValue.appeared = false; countShown() }
        .onMapCameraChange(frequency: .continuous) { context in
            let camera = context.camera
            let center = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
            monitor.map.center = center
            monitor.map.cameraDistance = camera.distance
            guard !monitor.map.movingProgrammatically else { return }
            let expected = monitor.map.followsTrain ? monitor.map.followingDistance : monitor.map.followDistance
            if abs(camera.distance - expected) > expected * 0.03 {
                // Zoom changed, beyond following's own easing: only the user does that (pinch, scroll).
                monitor.map.userZoomed(to: camera.distance)
                monitor.map.gestureZoomed = true
                monitor.map.touchedAt = Date()
            } else if let expected = monitor.map.expectedCenter, monitor.map.followsTrain,
                      center.distance(to: expected) * 1000 > camera.distance * 0.1 {
                // The camera left where following put it: the user is panning.
                monitor.map.touchedAt = Date()
            } else if !monitor.map.followsTrain {
                monitor.map.touchedAt = Date()
            }
        }
        // Dragging the map well away from the train ends following; a gesture that zoomed never does.
        .onMapCameraChange(frequency: .onEnd) { context in
            defer { monitor.map.gestureZoomed = false }
            // While following, only a zooming gesture changes the zoom; following's own easing doesn't.
            if !monitor.map.movingProgrammatically, !monitor.map.followsTrain || monitor.map.gestureZoomed {
                monitor.map.userZoomed(to: context.camera.distance)
            }
            guard monitor.map.followsTrain, !monitor.map.movingProgrammatically, !monitor.map.gestureZoomed, let position else { return }
            let camera = context.camera
            let offset = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
                .distance(to: position) * 1000
            if offset > camera.distance * 0.5 { monitor.map.followsTrain = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var trackingIcon: String {
        guard monitor.map.followsTrain else { return "location" }
        return headingUp ? "location.north.line.fill" : "location.fill"
    }

    private var trackingHelp: String {
        guard monitor.map.followsTrain else { return strings.followTrain }
        return headingUp ? strings.stopFollowingTrain : strings.headingUp
    }

    private func countShown() {
        let state = visibility.wrappedValue
        let shown = state.appeared && state.onScreen
        guard shown != state.counted else { return }
        state.counted = shown
        monitor.mapsShown += shown ? 1 : -1
    }

    private func cycleTracking(_ position: Coordinate?) {
        // All three steps use the same animation, so turning one way doesn't feel faster than the other.
        if !monitor.map.followsTrain {
            headingUp = false
            monitor.map.followsTrain = true
            turn(to: 0)
        } else if !headingUp {
            headingUp = true
            turn(to: monitor.map.heading.degrees ?? 0)
        } else {
            headingUp = false
            monitor.map.followsTrain = false
            turn(to: 0)
        }
    }

    /// Zooms to the route with a little margin; `.automatic` leaves too much empty map around it.
    private func fitRoute(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        let points = coordinates.map(MKMapPoint.init)
        var rect = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        rect = rect.insetBy(dx: -rect.width * 0.12 - 2_000, dy: -rect.height * 0.12 - 2_000)
        moveCamera(to: .rect(rect))
    }

    /// Following the train: north up, or turned with the train when that's switched on. Zooms in on its own while
    /// the train crawls or nears its next stop, unless saving data.
    private func camera(at position: Coordinate) -> MapCamera {
        let toStop = status.nextStop?.coordinate.map { position.distance(to: $0) * 1000 }
        let closeIn = MapZoom.closeIn(speed: monitor.displaySpeed, toNextStop: toStop, savingData: DataSaver.shared.isOn)
        let distance = monitor.map.cameraDistance(closeIn: closeIn, at: Date())
        return MapCamera(centerCoordinate: CLLocationCoordinate2D(position), distance: distance,
                         heading: monitor.map.cameraHeading(toward: headingUp ? monitor.map.heading.degrees ?? 0 : 0, at: Date()))
    }

    /// Zooms around the train when following, else around the map's center. Works from the remembered zoom,
    /// so quick repeated clicks add up instead of fighting the running animation.
    private func zoom(by factor: Double, train: Coordinate?) {
        guard let center = (monitor.map.followsTrain ? train : nil) ?? monitor.map.center else { return }
        // From where the map is, e.g. after fitting the route, unless following or mid-zoom from quick clicks.
        let base = monitor.map.followsTrain ? monitor.map.followingDistance
            : monitor.map.movingProgrammatically ? monitor.map.followDistance : monitor.map.cameraDistance ?? monitor.map.followDistance
        monitor.map.userZoomed(to: min(max(base * factor, 400), 4_000_000))
        moveCamera(to: .camera(monitor.map.followsTrain ? camera(at: center)
            : MapCamera(centerCoordinate: CLLocationCoordinate2D(center), distance: monitor.map.followDistance)), duration: 0.25)
    }

    private func moveCamera(to camera: MapCameraPosition, duration: Double = 0.6, settle: Double = 0.3) {
        monitor.map.programmaticMoves += 1
        withAnimation(.easeInOut(duration: duration)) { monitor.map.camera = camera }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + settle) { monitor.map.programmaticMoves -= 1 }
    }

    /// Turns the map with MapKit's own animation, at the display's frame rate; stepping the heading frame by frame
    /// only gets the marker's 30 updates a second and stutters. Ends where the train will be by then, so following
    /// picks up without a jump.
    private func turn(to heading: Double) {
        let duration = 0.8
        let end = Date().addingTimeInterval(duration)
        // Following: where the train will be by then. Not following: stay where the map is.
        let center = monitor.map.followsTrain ? monitor.predictedPosition(at: end) : monitor.map.center
        guard let target = center else { return }
        monitor.map.setCameraHeading(heading, at: end)
        let distance = monitor.map.followsTrain ? monitor.map.followingDistance : monitor.map.followDistance
        moveCamera(to: .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(target), distance: distance,
                                         heading: heading)), duration: duration, settle: 0)
    }

    /// Slow to fast as blue to red; gray where the bundled main lines don't reach.
    static func color(for band: Int?) -> Color {
        switch band {
        case 120: .blue
        case 160: .green
        case 200: .yellow
        case 250: .orange
        case 300: .red
        default: .secondary
        }
    }

    /// At most ~1500 points; full Transitous shapes have up to ten thousand, which slows redraws.
    private static func thinned(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 1500 else { return points }
        let step = Double(points.count - 1) / 1499
        return (0..<1500).map { points[Int((Double($0) * step).rounded())] }
    }
}

/// What the track colors mean, in km/h.
private struct SpeedLegend: View {
    @Environment(\.strings) private var strings

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TrackSpeeds.bands, id: \.self) { band in
                HStack(spacing: 2) {
                    Circle().fill(TrainMap.color(for: band)).frame(width: 6, height: 6)
                    Text(band == TrackSpeeds.bands.first ? "≤\(band)" : "\(band)")
                }
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.trackSpeedsLegend)
    }
}

private struct MapControlGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .mapControlGroupStyle()
    }
}

private struct MapControl: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Reports whether the hosting window can be seen: not minimized and not fully covered by other windows.
private struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }

    final class Watcher: NSView {
        var changed: (Bool) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            windowChanged()
        }

        @objc private func windowChanged() {
            guard let window else { return }
            // A popover has no title bar and closes rather than hiding, which ends the map anyway.
            let visible = !window.styleMask.contains(.titled)
                || window.occlusionState.contains(.visible) && !window.isMiniaturized
            // Not during a SwiftUI update.
            DispatchQueue.main.async { [changed] in changed(visible) }
        }
    }
}

extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

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
    private var lines = State(initialValue: Lines())

    private final class Visibility {
        var appeared = false
        var onScreen = true
        /// In the monitor's count of maps shown, which asks for smooth frames.
        var counted = false
    }

    /// The lines on the map, made once per route. MapKit lays out a line again whenever it's handed a new one; when
    /// the marker was still part of the map's content, that was 30 times a second. Right after a wake from sleep that
    /// outran freeing the old ones, and the app grew by gigabytes a minute.
    fileprivate final class Lines {
        struct Stretch: Equatable {
            let line: MKPolyline
            let band: Int?
        }

        private var routeSource: [Coordinate]?
        private var routeLine: MKPolyline?
        private var stretchesSource: [TrackSpeeds.Stretch]?
        private var stretchLines: [Stretch] = []

        /// Arrays compare by storage first, so an unchanged route costs next to nothing to check.
        func route(_ points: [Coordinate]) -> MKPolyline? {
            defer { routeSource = points } // Keeps the cheap check once a new poll brings the same route again.
            if points != routeSource {
                let coordinates = TrainMap.thinned(points).map(CLLocationCoordinate2D.init)
                routeLine = coordinates.count > 1 ? MKPolyline(coordinates: coordinates, count: coordinates.count) : nil
            }
            return routeLine
        }

        func stretches(_ stretches: [TrackSpeeds.Stretch]) -> [Stretch] {
            defer { stretchesSource = stretches }
            if stretches != stretchesSource {
                stretchLines = stretches.map { stretch in
                    let coordinates = stretch.points.map(CLLocationCoordinate2D.init)
                    return Stretch(line: MKPolyline(coordinates: coordinates, count: coordinates.count), band: stretch.band)
                }
            }
            return stretchLines
        }
    }

    /// Spelled out: older compilers make the memberwise one private because of `visibility`.
    init(monitor: TrainMonitor, status: TrainStatus) {
        self.monitor = monitor
        self.status = status
    }

    var body: some View {
        let stretches = lines.wrappedValue.stretches(monitor.map.trackStretches)
        let routeLine = lines.wrappedValue.route(routePoints)
        let highlighted = [monitor.journey.plan?.destinationStopID, monitor.journey.plan?.boardingStopID].compactMap { $0 }

        // Neither the train's position nor the camera is read here: both change up to 30 times a second while
        // following, and the map takes them straight from the monitor instead of through a new view each time.
        RouteMap(monitor: monitor, stops: status.stops, highlighted: highlighted, routeLine: routeLine,
                 stretches: showsTrackSpeeds ? stretches : [], trainName: status.trainName, follow: follow)
        .overlay(alignment: .topTrailing) {
            MapControlGroup {
                // Like Apple Maps: free → follow the train → follow, turned with it → free.
                MapControl(icon: trackingIcon, help: trackingHelp) { cycleTracking() }
                    .disabled(!monitor.placesTrain)
                Divider().frame(width: 18)
                MapControl(icon: "arrow.up.left.and.arrow.down.right", help: strings.wholeRoute) {
                    monitor.map.followsTrain = false
                    fitRoute(routeAndTrain)
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
        // Keyed by the route's size, not its points: cheap to compare.
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
                MapControl(icon: "plus", help: strings.zoomIn) { zoom(by: 0.5, train: monitor.trainPosition) }
                Divider().frame(width: 18)
                MapControl(icon: "minus", help: strings.zoomOut) { zoom(by: 2, train: monitor.trainPosition) }
            }
            .padding(8)
        }
        .onAppear {
            if !monitor.map.followsTrain { fitRoute(routeAndTrain) }
        }
        // Counts as shown only while its window can be seen: a window minimized or behind others stays open.
        .background(WindowVisibility { visibility.wrappedValue.onScreen = $0; countShown() })
        .onAppear { visibility.wrappedValue.appeared = true; countShown() }
        .onDisappear { visibility.wrappedValue.appeared = false; countShown() }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The route's shape, else its stops.
    private var routePoints: [Coordinate] {
        status.route?.points ?? status.stops.compactMap(\.coordinate)
    }

    /// What fitting the map to the route shows: the route and where the train is now.
    private var routeAndTrain: [CLLocationCoordinate2D] {
        (routePoints + [monitor.trainPosition].compactMap { $0 }).map(CLLocationCoordinate2D.init)
    }

    /// Keeps the camera on the train, frame by frame, while following it and the user isn't moving the map.
    private func follow(_ position: Coordinate) {
        guard monitor.map.followsTrain, !monitor.map.movingProgrammatically,
              Date().timeIntervalSince(monitor.map.touchedAt) > 2
        else { return }
        // Without animation; the marker itself moves at a constant pace.
        monitor.map.move(to: camera(at: position))
        monitor.map.expectedCenter = position
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

    private func cycleTracking() {
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
    private func camera(at position: Coordinate) -> MapState.CameraMove.Target {
        let toStop = status.nextStop?.coordinate.map { position.distance(to: $0) * 1000 }
        let closeIn = MapZoom.closeIn(speed: monitor.displaySpeed, toNextStop: toStop, savingData: DataSaver.shared.isOn)
        let distance = monitor.map.cameraDistance(closeIn: closeIn, at: Date())
        return .camera(center: position, distance: distance,
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
        moveCamera(to: monitor.map.followsTrain ? camera(at: center)
            : .camera(center: center, distance: monitor.map.followDistance, heading: monitor.map.shownCameraHeading ?? 0), duration: 0.25)
    }

    private func moveCamera(to camera: MapState.CameraMove.Target, duration: Double = 0.6, settle: Double = 0.3) {
        monitor.map.programmaticMoves += 1
        monitor.map.move(to: camera, duration: duration)
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
        moveCamera(to: .camera(center: target, distance: distance, heading: heading), duration: duration, settle: 0)
    }

    /// Slow to fast as blue to red; gray where the bundled main lines don't reach.
    static func color(for band: Int?) -> NSColor {
        switch band {
        case 120: .systemBlue
        case 160: .systemGreen
        case 200: .systemYellow
        case 250: .systemOrange
        case 300: .systemRed
        default: .secondaryLabelColor
        }
    }

    /// At most ~1500 points; full Transitous shapes have up to ten thousand, which slows redraws.
    private static func thinned(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 1500 else { return points }
        let step = Double(points.count - 1) / 1499
        return (0..<1500).map { points[Int((Double($0) * step).rounded())] }
    }
}

/// The route, its stops and the train on a map view of our own. SwiftUI's `Map` took every camera move and every
/// step of the marker as new content and added all of its lines again: with the track colored by speed, following
/// the train kept a whole CPU core busy. Here the lines are added once, and the train and the camera move alone.
private struct RouteMap: NSViewRepresentable {
    let monitor: TrainMonitor
    let stops: [Stop]
    let highlighted: [String]
    let routeLine: MKPolyline?
    let stretches: [TrainMap.Lines.Stretch]
    let trainName: String?
    let follow: (Coordinate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(monitor: monitor) }

    func makeNSView(context: Context) -> MKMapView {
        let view = SizedMapView()
        let configuration = MKStandardMapConfiguration()
        configuration.pointOfInterestFilter = .excludingAll
        view.preferredConfiguration = configuration
        view.showsCompass = false
        view.showsZoomControls = false
        view.showsPitchControl = false
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.sized = { [weak coordinator = context.coordinator] in coordinator?.applyCamera() }
        context.coordinator.show(self)
        context.coordinator.watchTrain()
        context.coordinator.watchCamera()
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.show(self)
    }

    static func dismantleNSView(_ view: MKMapView, coordinator: Coordinator) {
        coordinator.view = nil
    }

    /// Tells when the map first has a size: a camera set before that fits nothing.
    private final class SizedMapView: MKMapView {
        var sized: () -> Void = {}
        private var hadSize = false

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard !hadSize, newSize.width > 0, newSize.height > 0 else { return }
            hadSize = true
            sized()
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let monitor: TrainMonitor
        /// Gone once the map is taken down, which ends the watching below.
        weak var view: MKMapView?
        private var follow: (Coordinate) -> Void = { _ in }
        private var lines: [MKPolyline] = []
        private var colors: [ObjectIdentifier: NSColor] = [:]
        private var dots: [StopDot] = []
        private let train = TrainAnnotation()
        private var trainShown = false
        private var appliedCamera: Int?

        init(monitor: TrainMonitor) {
            self.monitor = monitor
        }

        /// Takes over what the panel shows now. Lines and stops are only touched when they changed.
        func show(_ map: RouteMap) {
            guard let view else { return }
            follow = map.follow
            train.title = map.trainName

            let wanted = map.stretches.isEmpty ? [map.routeLine].compactMap { $0 } : map.stretches.map(\.line)
            if !wanted.elementsEqual(lines, by: ===) {
                view.removeOverlays(lines)
                lines = wanted
                colors = Dictionary(map.stretches.map { (ObjectIdentifier($0.line), TrainMap.color(for: $0.band)) }) { first, _ in first }
                view.addOverlays(wanted, level: .aboveRoads)
            }

            let wantedDots = map.stops.compactMap { stop in
                stop.coordinate.map {
                    StopDot(id: stop.id, name: stop.name, coordinate: CLLocationCoordinate2D($0), passed: stop.passed,
                            highlighted: map.highlighted.contains(stop.id))
                }
            }
            if !wantedDots.elementsEqual(dots, by: { $0.same(as: $1) }) {
                view.removeAnnotations(dots)
                dots = wantedDots
                view.addAnnotations(wantedDots)
            }
        }

        /// Moves the marker whenever the monitor places the train anew, without a pass through SwiftUI.
        func watchTrain() {
            guard let view else { return }
            let position = withObservationTracking { monitor.trainPosition } onChange: { [weak self] in
                DispatchQueue.main.async { self?.watchTrain() }
            }
            if let position {
                train.coordinate = CLLocationCoordinate2D(position)
                if !trainShown { view.addAnnotation(train) }
                follow(position)
            } else if trainShown {
                view.removeAnnotation(train)
            }
            trainShown = position != nil
        }

        func watchCamera() {
            guard view != nil else { return }
            withObservationTracking { applyCamera() } onChange: { [weak self] in
                DispatchQueue.main.async { self?.watchCamera() }
            }
        }

        /// Sends the map where the app last asked for, once. A map that just appeared jumps there.
        func applyCamera() {
            let move = monitor.map.camera
            guard let view, move.serial != appliedCamera, view.frame.width > 0, view.frame.height > 0 else { return }
            let first = appliedCamera == nil
            appliedCamera = move.serial
            let apply: () -> Void
            switch move.target {
            case .automatic:
                return
            case let .camera(center, distance, heading):
                // A new one each time: the map keeps the one it's given.
                let camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(center), fromDistance: distance,
                                         pitch: 0, heading: heading)
                apply = { view.camera = camera }
            case let .rect(rect):
                apply = { view.visibleMapRect = rect }
            }
            guard move.duration > 0, !first else { return apply() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = move.duration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                apply()
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            let color = colors[ObjectIdentifier(line)]
            renderer.strokeColor = color ?? .secondaryLabelColor
            renderer.lineWidth = color == nil ? 3 : 4
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let dot = annotation as? StopDot { return StopDotView(annotation: dot, reuseIdentifier: nil) }
            guard annotation is TrainAnnotation else { return nil }
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            // Like the panel's `.title2`.
            let symbol = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(.init(paletteColors: [.white, .controlAccentColor]))
            view.image = NSImage(systemSymbolName: "tram.circle.fill", accessibilityDescription: annotation.title ?? nil)?
                .withSymbolConfiguration(symbol)
            // Standing on the track: its bottom at the train.
            view.centerOffset = CGPoint(x: 0, y: -(view.image?.size.height ?? 0) / 2)
            view.wantsLayer = true
            view.shadow = NSShadow()
            view.layer?.shadowRadius = 2
            view.layer?.shadowOpacity = 0.33
            view.layer?.shadowOffset = .zero
            view.zPriority = .max
            view.isEnabled = false
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let map = monitor.map
            let camera = mapView.camera
            let center = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
            let distance = camera.centerCoordinateDistance
            map.center = center
            map.cameraDistance = distance
            map.shownCameraHeading = camera.heading
            // Measured across the middle, which holds when the map is turned.
            let middle = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
            let left = mapView.convert(CGPoint(x: middle.x - 50, y: middle.y), toCoordinateFrom: mapView)
            let right = mapView.convert(CGPoint(x: middle.x + 50, y: middle.y), toCoordinateFrom: mapView)
            map.metersPerPoint = MKMapPoint(left).distance(to: MKMapPoint(right)) / 100
            guard !map.movingProgrammatically else { return }
            let expected = map.followsTrain ? map.followingDistance : map.followDistance
            if abs(distance - expected) > expected * 0.03 {
                // Zoom changed, beyond following's own easing: only the user does that (pinch, scroll).
                map.userZoomed(to: distance)
                map.gestureZoomed = true
                map.touchedAt = Date()
            } else if let expected = map.expectedCenter, map.followsTrain,
                      center.distance(to: expected) * 1000 > distance * 0.1 {
                // The camera left where following put it: the user is panning.
                map.touchedAt = Date()
            } else if !map.followsTrain {
                map.touchedAt = Date()
            }
        }

        /// Dragging the map well away from the train ends following; a gesture that zoomed never does.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let map = monitor.map
            defer { map.gestureZoomed = false }
            let camera = mapView.camera
            // While following, only a zooming gesture changes the zoom; following's own easing doesn't.
            if !map.movingProgrammatically, !map.followsTrain || map.gestureZoomed {
                map.userZoomed(to: camera.centerCoordinateDistance)
            }
            guard map.followsTrain, !map.movingProgrammatically, !map.gestureZoomed,
                  let position = monitor.trainPosition else { return }
            let offset = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
                .distance(to: position) * 1000
            if offset > camera.centerCoordinateDistance * 0.5 { map.followsTrain = false }
        }
    }
}

/// The train. Its coordinate is set up to 30 times a second; the map moves the marker and leaves the rest alone.
private final class TrainAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var title: String?
}

private final class StopDot: NSObject, MKAnnotation {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let passed: Bool
    let highlighted: Bool

    init(id: String, name: String, coordinate: CLLocationCoordinate2D, passed: Bool, highlighted: Bool) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.passed = passed
        self.highlighted = highlighted
    }

    func same(as other: StopDot) -> Bool {
        id == other.id && name == other.name && passed == other.passed && highlighted == other.highlighted
            && coordinate.latitude == other.coordinate.latitude && coordinate.longitude == other.coordinate.longitude
    }
}

/// A stop: a small dot, larger and named where the user gets on or off.
private final class StopDotView: MKAnnotationView {
    init(annotation dot: StopDot, reuseIdentifier: String?) {
        super.init(annotation: dot, reuseIdentifier: reuseIdentifier)
        let size: CGFloat = dot.highlighted ? 10 : 7
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        isEnabled = false
        setAccessibilityLabel(dot.name)
        guard dot.highlighted else { return }
        zPriority = .defaultSelected
        let label = NSTextField(labelWithString: dot.name)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .labelColor
        // A halo in the map's own tone keeps the name readable over roads and rails.
        let halo = NSShadow()
        halo.shadowColor = .textBackgroundColor
        halo.shadowBlurRadius = 2
        halo.shadowOffset = .zero
        label.shadow = halo
        label.sizeToFit()
        // Below the dot. Annotation views aren't flipped: down is negative.
        label.setFrameOrigin(CGPoint(x: (size - label.frame.width) / 2, y: -label.frame.height - 1))
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let dot = annotation as? StopDot else { return }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (dot.highlighted ? NSColor.controlAccentColor : dot.passed ? .gray : .white).setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }
}

/// What the track colors mean, in km/h.
private struct SpeedLegend: View {
    @Environment(\.strings) private var strings

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TrackSpeeds.bands, id: \.self) { band in
                HStack(spacing: 2) {
                    Circle().fill(Color(nsColor: TrainMap.color(for: band))).frame(width: 6, height: 6)
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

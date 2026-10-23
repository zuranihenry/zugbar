import MapKit
import SwiftUI
import ZugbarCore

/// Route and current position. On board this is GPS; for trains followed online it's estimated from the timetable.
struct TrainMap: View {
    @Bindable var monitor: TrainMonitor
    let status: TrainStatus
    @Environment(\.strings) private var strings
    @AppStorage("mapHeadingUp") private var headingUp = false

    var body: some View {
        let route = status.route.map { Self.thinned($0.points).map(CLLocationCoordinate2D.init) }
            ?? status.stops.compactMap { $0.coordinate.map(CLLocationCoordinate2D.init) }
        let position = monitor.trainPosition
        let highlighted = [monitor.journey.plan?.destinationStopID, monitor.journey.plan?.boardingStopID].compactMap { $0 }
        @Bindable var map = monitor.map

        Map(position: $map.camera) {
            if route.count > 1 {
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
            }
            .padding(8)
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
        .onAppear { monitor.mapsShown += 1 }
        .onDisappear { monitor.mapsShown -= 1 }
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
    /// the train crawls or nears its next stop.
    private func camera(at position: Coordinate) -> MapCamera {
        let toStop = status.nextStop?.coordinate.map { position.distance(to: $0) * 1000 }
        let distance = monitor.map.cameraDistance(closeIn: MapZoom.closeIn(speed: monitor.displaySpeed, toNextStop: toStop), at: Date())
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

    /// At most ~1500 points; full Transitous shapes have up to ten thousand, which slows redraws.
    private static func thinned(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 1500 else { return points }
        let step = Double(points.count - 1) / 1499
        return (0..<1500).map { points[Int((Double($0) * step).rounded())] }
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

extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

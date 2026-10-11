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
        let destinationID = monitor.journey.plan?.destinationStopID
        @Bindable var map = monitor.map

        Map(position: $map.camera) {
            if route.count > 1 {
                MapPolyline(coordinates: route).stroke(.secondary, lineWidth: 3)
            }
            ForEach(status.stops) { stop in
                if let coordinate = stop.coordinate {
                    Annotation(stop.name, coordinate: CLLocationCoordinate2D(coordinate), anchor: .center) {
                        Circle()
                            .fill(stop.id == destinationID ? Color.accentColor : (stop.passed ? Color.gray : Color.white))
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                            .frame(width: stop.id == destinationID ? 10 : 7)
                    }
                    .annotationTitles(stop.id == destinationID ? .visible : .hidden)
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
            VStack(spacing: 6) {
                MapButton(icon: monitor.map.followsTrain ? "location.fill" : "location", help: strings.followTrain) {
                    monitor.map.followsTrain.toggle()
                    if monitor.map.followsTrain, let position { center(on: position) }
                }
                .disabled(position == nil)
                MapButton(icon: headingUp ? "location.north.line.fill" : "location.north.line", help: strings.headingUp) {
                    headingUp.toggle()
                    monitor.map.followsTrain = monitor.map.followsTrain || headingUp
                    if monitor.map.followsTrain, let position { center(on: position) }
                }
                .disabled(position == nil)
                MapButton(icon: "plus", help: strings.zoomIn) { zoom(by: 0.5, train: position) }
                MapButton(icon: "minus", help: strings.zoomOut) { zoom(by: 2, train: position) }
                MapButton(icon: "arrow.up.left.and.arrow.down.right", help: strings.wholeRoute) {
                    monitor.map.followsTrain = false
                    withAnimation { fitRoute(route + [position].compactMap { $0.map(CLLocationCoordinate2D.init) }) }
                }
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
        .onMapCameraChange(frequency: .continuous) { context in
            let camera = context.camera
            let center = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
            monitor.map.center = center
            guard !monitor.map.movingProgrammatically else { return }
            if abs(camera.distance - monitor.map.followDistance) > monitor.map.followDistance * 0.03 {
                // Zoom changed: only the user does that (pinch, scroll).
                monitor.map.followDistance = camera.distance
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
            if !monitor.map.movingProgrammatically { monitor.map.followDistance = context.camera.distance }
            guard monitor.map.followsTrain, !monitor.map.movingProgrammatically, !monitor.map.gestureZoomed, let position else { return }
            let camera = context.camera
            let offset = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
                .distance(to: position) * 1000
            if offset > camera.distance * 0.5 { monitor.map.followsTrain = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Zooms to the route with a little margin; `.automatic` leaves too much empty map around it.
    private func fitRoute(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        let points = coordinates.map(MKMapPoint.init)
        var rect = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        rect = rect.insetBy(dx: -rect.width * 0.12 - 2_000, dy: -rect.height * 0.12 - 2_000)
        moveCamera(to: .rect(rect))
    }

    private func center(on position: Coordinate) {
        moveCamera(to: .camera(camera(at: position)))
    }

    /// Following the train: north up, or turned with the train when that's switched on.
    private func camera(at position: Coordinate) -> MapCamera {
        MapCamera(centerCoordinate: CLLocationCoordinate2D(position), distance: monitor.map.followDistance,
                  heading: headingUp ? monitor.map.heading.degrees ?? 0 : 0)
    }

    /// Zooms around the train when following, else around the map's center. Works from the remembered zoom,
    /// so quick repeated clicks add up instead of fighting the running animation.
    private func zoom(by factor: Double, train: Coordinate?) {
        guard let center = (monitor.map.followsTrain ? train : nil) ?? monitor.map.center else { return }
        monitor.map.followDistance = min(max(monitor.map.followDistance * factor, 400), 4_000_000)
        moveCamera(to: .camera(monitor.map.followsTrain ? camera(at: center)
            : MapCamera(centerCoordinate: CLLocationCoordinate2D(center), distance: monitor.map.followDistance)), duration: 0.25)
    }

    private func moveCamera(to camera: MapCameraPosition, duration: Double = 0.6) {
        monitor.map.programmaticMoves += 1
        withAnimation(.easeInOut(duration: duration)) { monitor.map.camera = camera }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.3) { monitor.map.programmaticMoves -= 1 }
    }

    /// At most ~1500 points; full Transitous shapes have up to ten thousand, which slows redraws.
    private static func thinned(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 1500 else { return points }
        let step = Double(points.count - 1) / 1499
        return (0..<1500).map { points[Int((Double($0) * step).rounded())] }
    }
}

private struct MapButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .mapButtonStyle()
        .help(help)
        .accessibilityLabel(help)
    }
}

extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

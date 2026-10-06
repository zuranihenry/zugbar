import MapKit
import SwiftUI
import ZugbarCore

/// Route and current position. On board this is GPS; for trains followed online it's estimated from the timetable.
struct TrainMap: View {
    @Bindable var monitor: TrainMonitor
    let status: TrainStatus
    @Environment(\.strings) private var strings

    var body: some View {
        let route = status.route.map { $0.points.map(CLLocationCoordinate2D.init) }
            ?? status.stops.compactMap { $0.coordinate.map(CLLocationCoordinate2D.init) }
        let position = monitor.profileEstimate(status)?.position ?? status.position(at: monitor.now)
        let destinationID = monitor.plan?.destinationStopID

        Map(position: $monitor.mapCamera) {
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
        .mapControls { MapZoomStepper() }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 6) {
                MapButton(icon: monitor.mapFollowsTrain ? "location.fill" : "location", help: strings.followTrain) {
                    monitor.mapFollowsTrain.toggle()
                    if monitor.mapFollowsTrain, let position { center(on: position) }
                }
                .disabled(position == nil)
                MapButton(icon: "arrow.up.left.and.arrow.down.right", help: strings.wholeRoute) {
                    monitor.mapFollowsTrain = false
                    withAnimation { fitRoute(route + [position].compactMap { $0.map(CLLocationCoordinate2D.init) }) }
                }
            }
            .padding(8)
        }
        .onAppear {
            if !monitor.mapFollowsTrain { fitRoute(route + [position].compactMap { $0.map(CLLocationCoordinate2D.init) }) }
        }
        .onChange(of: position) { _, newPosition in
            if monitor.mapFollowsTrain, let newPosition { center(on: newPosition) }
        }
        // Dragging the map ends following.
        .onMapCameraChange(frequency: .onEnd) { _ in
            if monitor.mapCamera.positionedByUser { monitor.mapFollowsTrain = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Zooms to the route with a little margin; `.automatic` leaves too much empty map around it.
    private func fitRoute(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        let points = coordinates.map(MKMapPoint.init)
        var rect = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        rect = rect.insetBy(dx: -rect.width * 0.12 - 2_000, dy: -rect.height * 0.12 - 2_000)
        monitor.mapCamera = .rect(rect)
    }

    private func center(on position: Coordinate) {
        withAnimation {
            monitor.mapCamera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(position), latitudinalMeters: 40_000, longitudinalMeters: 40_000
            ))
        }
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
    }
}

extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

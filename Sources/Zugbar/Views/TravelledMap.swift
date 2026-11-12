import MapKit
import SwiftUI
import ZugbarCore

/// Every trip with a path as lines on one map, stronger where ridden more often. Fits all of them; the user can
/// pan and zoom from there.
struct TravelledMap: NSViewRepresentable {
    let network: TravelledNetwork

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        // A size from the start: fitting the lines needs one.
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsZoomControls = true
        map.delegate = context.coordinator
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        guard context.coordinator.shown != network else { return }
        context.coordinator.shown = network
        map.removeOverlays(map.overlays)
        // One overlay per strength, weakest first so the often ridden lines end up on top.
        let overlays = network.lines.enumerated().compactMap { strength, lines -> MKMultiPolyline? in
            guard !lines.isEmpty else { return nil }
            let overlay = MKMultiPolyline(lines.map { line in
                MKPolyline(coordinates: line.map(CLLocationCoordinate2D.init), count: line.count)
            })
            overlay.title = String(strength)
            return overlay
        }
        map.addOverlays(overlays)
        let bounds = overlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        guard !bounds.isNull else { return }
        map.setVisibleMapRect(bounds, edgePadding: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var shown: TravelledNetwork?

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let lines = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let strength = lines.title.flatMap(Int.init) ?? 0
            let renderer = MKMultiPolylineRenderer(multiPolyline: lines)
            renderer.strokeColor = NSColor.controlAccentColor.withAlphaComponent([0.6, 0.8, 1][min(strength, 2)])
            renderer.lineWidth = [2, 3.5, 5][min(strength, 2)]
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}

/// Made-up trips for demo mode: the demo train's line, some of it ridden more than once.
enum DemoTrips {
    @MainActor static let log: TripLog = {
        guard let points = DemoProvider.route?.points, points.count > 10 else { return TripLog() }
        let start = Date(timeIntervalSince1970: 1_781_272_800)
        func trip(_ day: Int, _ train: String, _ from: String, _ to: String, _ part: ClosedRange<Double>, top: Int, delay: Int) -> Trip {
            let line = Array(points[Int(part.lowerBound * Double(points.count - 1))...Int(part.upperBound * Double(points.count - 1))])
            let distance = zip(line, line.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let begin = start.addingTimeInterval(Double(day) * 86400)
            return Trip(train: train, from: from, to: to, start: begin, end: begin.addingTimeInterval(distance / 150 * 3600),
                        distance: distance, topSpeed: top, arrivalDelay: delay, path: TripPath(lines: [line]))
        }
        return TripLog(trips: [
            trip(0, "ICE 503", "Berlin Hbf", "München Hbf", 0...1, top: 283, delay: 3),
            trip(-9, "ICE 1001", "Berlin Hbf", "Nürnberg Hbf", 0...0.72, top: 297, delay: 0),
            trip(-16, "ICE 505", "Halle (Saale) Hbf", "Nürnberg Hbf", 0.28...0.72, top: 291, delay: 12),
            trip(-23, "ICE 1005", "Halle (Saale) Hbf", "Erfurt Hbf", 0.28...0.42, top: 268, delay: 1),
            trip(-30, "ICE 507", "Halle (Saale) Hbf", "Erfurt Hbf", 0.28...0.42, top: 271, delay: 0),
            trip(-37, "ICE 1003", "Halle (Saale) Hbf", "Erfurt Hbf", 0.28...0.42, top: 265, delay: 4),
            // Recorded before paths were kept: listed, but not on the map.
            Trip(train: "RE 1", from: "Nürnberg Hbf", to: "Regensburg Hbf", start: start.addingTimeInterval(-44 * 86400),
                 end: start.addingTimeInterval(-44 * 86400 + 3900), distance: 101, topSpeed: 158, arrivalDelay: 2),
        ])
    }()
}

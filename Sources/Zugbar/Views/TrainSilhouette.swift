import SwiftUI
import ZugbarCore

/// A small side view of the train's family, nose to the right and fading out towards the rest of the train.
/// Drawn here in code: schematic and not to scale, so it says which kind of train this is and no more.
struct TrainSilhouette: View {
    let family: TrainFamily
    var height: CGFloat = 13

    static let aspectRatio = TrainArt.size.width / TrainArt.size.height

    var body: some View {
        let art = TrainArt(family)
        Rectangle()
            .fill(.secondary)
            .mask { canvas(fill: [art.body, art.wheels], stroke: art.lines, minus: [art.cutouts, art.stripe]) }
            .overlay {
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .mask { canvas(fill: [art.stripe], stroke: nil, minus: [art.cutouts]) }
            }
            .mask(LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                startPoint: .leading, endPoint: .trailing
            ))
            .frame(width: height * Self.aspectRatio, height: height)
            .accessibilityHidden(true)
    }

    private func canvas(fill: [Path], stroke: Path?, minus: [Path]) -> some View {
        Canvas { context, size in
            let scale = size.height / TrainArt.size.height
            context.scaleBy(x: scale, y: scale)
            context.drawLayer { layer in
                for path in fill { layer.fill(path, with: .color(.black)) }
                if let stroke {
                    layer.stroke(stroke, with: .color(.black), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
                }
                layer.blendMode = .destinationOut
                for path in minus { layer.fill(path, with: .color(.black)) }
            }
        }
    }
}

private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The parts of one drawing, in a 140 × 20 box with the rail along the bottom edge.
private struct TrainArt {
    static let size = CGSize(width: 140, height: 20)
    private static let floor: CGFloat = 16.4

    var body = Path()
    /// Windows, grilles and the gaps between cars: holes in the body.
    var cutouts = Path()
    /// The red line along an ICE.
    var stripe = Path()
    var wheels = Path()
    /// Pantographs and couplings.
    var lines = Path()

    init(_ family: TrainFamily) {
        switch family {
        case .ice1: ice1()
        case .ice3: ice3()
        case .velaro: velaro()
        case .ice4: ice4()
        case .iceT: iceT()
        case .railjet: railjet()
        case .tgv: tgv()
        }
    }

    // MARK: Families

    /// Power car: a long sloped nose, grilles instead of windows, a pantograph; coaches behind.
    private mutating func ice1() {
        hull(roof: 3.2) { path in
            path.addLine(to: p(108, 3.2))
            path.addCurve(to: p(131, 10.2), control1: p(115, 3.4), control2: p(124, 6.6))
            path.addCurve(to: p(138.6, 13.6), control1: p(134.5, 11.4), control2: p(138, 12.4))
            path.addCurve(to: p(134.5, 16.4), control1: p(139, 15.2), control2: p(137, 16.4))
        }
        glass(p(114.5, 5.4), p(127.5, 9.6), control1: p(119, 6.2), control2: p(124, 8), back: [p(119, 9.6), p(113.5, 7.2)])
        slats(from: 72, to: 84)
        slats(from: 90, to: 102)
        pantograph(at: 76, roof: 3.2)
        gap(at: 62)
        windows(from: 2, to: 58)
        redLine(to: 133)
        bogies(118, 72, 52)
    }

    /// End car: a long, evenly curved nose with a deep windscreen and windows right up to the cab.
    private mutating func ice3() {
        hull(roof: 3.2) { path in
            path.addLine(to: p(98, 3.2))
            path.addCurve(to: p(138.6, 13.2), control1: p(118, 3.3), control2: p(134, 7.6))
            path.addCurve(to: p(133.5, 16.4), control1: p(139.4, 15), control2: p(137, 16.4))
        }
        glass(p(111, 5.6), p(131, 10.4), control1: p(118, 5.8), control2: p(127, 7.8), back: [p(112.5, 10.4)])
        gap(at: 44)
        windows(from: 3, to: 107)
        redLine(to: 134)
        bogies(112, 52, 36)
    }

    /// Like the ICE 3, with a raised roof that steps down ahead of the cab and no windows next to it.
    private mutating func velaro() {
        hull(roof: 2.2) { path in
            path.addLine(to: p(92, 2.2))
            path.addLine(to: p(99, 3.8))
            path.addLine(to: p(103, 3.8))
            path.addCurve(to: p(138.6, 13.2), control1: p(120, 3.9), control2: p(134.5, 7.8))
            path.addCurve(to: p(133.5, 16.4), control1: p(139.4, 15), control2: p(137, 16.4))
        }
        glass(p(116, 6), p(131, 10.4), control1: p(121, 6.3), control2: p(127.5, 8.2), back: [p(117, 10.4)])
        gap(at: 44)
        windows(from: 3, to: 100)
        redLine(to: 134)
        bogies(112, 52, 36)
    }

    /// Tall, long cars and a short, steep nose.
    private mutating func ice4() {
        hull(roof: 2.6) { path in
            path.addLine(to: p(112, 2.6))
            path.addCurve(to: p(137.6, 11.6), control1: p(124, 2.7), control2: p(134.5, 5.6))
            path.addCurve(to: p(135, 16.4), control1: p(138.8, 13.8), control2: p(137.6, 16.4))
        }
        glass(p(122, 4.9), p(134.4, 10.6), control1: p(127, 5.2), control2: p(132.5, 7.4), back: [p(123, 10.6)])
        gap(at: 34)
        windows(from: 3, to: 112, width: 8.6, top: 6)
        redLine(to: 134)
        bogies(118, 44, 26)
    }

    /// A lower body and a shorter, rounder nose than the ICE 3.
    private mutating func iceT() {
        hull(roof: 3.6) { path in
            path.addLine(to: p(110, 3.6))
            path.addCurve(to: p(138.2, 12.6), control1: p(125, 3.7), control2: p(136, 7.2))
            path.addCurve(to: p(133.5, 16.4), control1: p(139.4, 14.8), control2: p(137, 16.4))
        }
        glass(p(119, 6), p(132.4, 10.4), control1: p(124, 6.2), control2: p(130, 8.2), back: [p(120, 10.4)])
        gap(at: 40)
        windows(from: 3, to: 114)
        redLine(to: 134)
        bogies(114, 48, 32)
    }

    /// A locomotive with a rounded cab at each end and two pantographs, pulling coaches.
    private mutating func railjet() {
        body.addRect(CGRect(x: -5, y: 3.2, width: 69, height: Self.floor - 3.2))
        body.move(to: p(70.5, 16.4))
        body.addCurve(to: p(68.6, 13), control1: p(69.2, 16.4), control2: p(68.6, 15.4))
        body.addCurve(to: p(74, 3.4), control1: p(68.8, 7), control2: p(70.5, 3.6))
        body.addLine(to: p(127, 3.4))
        body.addCurve(to: p(138.6, 11.4), control1: p(132.5, 3.5), control2: p(137.4, 6.4))
        body.addLine(to: p(138.8, 14.6))
        body.addCurve(to: p(136.5, 16.4), control1: p(138.8, 15.8), control2: p(138, 16.4))
        body.closeSubpath()
        glass(p(129, 5.4), p(136.2, 9.6), control1: p(132, 5.6), control2: p(135.2, 7.4), back: [p(129, 9.6)])
        cutouts.addLines([p(71.2, 9.6), p(72.4, 5.8), p(76, 5.4), p(76, 9.6)])
        cutouts.closeSubpath()
        slats(from: 86, to: 116, top: 5, count: 2)
        pantograph(at: 84, roof: 3.4)
        pantograph(at: 120, roof: 3.4, mirrored: true)
        lines.move(to: p(64, 14.4))
        lines.addLine(to: p(69, 14.4))
        lines.move(to: p(138.6, 14))
        lines.addLine(to: p(139.6, 14))
        windows(from: 2, to: 60)
        bogies(126, 81, 54)
    }

    /// Power car: a steep windscreen over a long flat nose, grilles on the side; the trailers behind stay plain,
    /// as the portal doesn't say whether they have one deck or two.
    private mutating func tgv() {
        body.addRect(CGRect(x: -5, y: 3, width: 61.5, height: Self.floor - 3))
        body.move(to: p(60, 16.4))
        body.addLine(to: p(60, 3))
        body.addLine(to: p(103, 3))
        body.addCurve(to: p(119, 8.4), control1: p(110, 3.1), control2: p(115, 5.6))
        body.addCurve(to: p(138.6, 14.2), control1: p(126, 11), control2: p(135, 12.4))
        body.addCurve(to: p(135, 16.4), control1: p(139, 15.4), control2: p(137.5, 16.4))
        body.closeSubpath()
        glass(p(108, 5.2), p(116, 8.8), control1: p(111.5, 5.6), control2: p(114.2, 7.2), back: [p(109.5, 8.8)])
        cutouts.addRoundedRect(in: CGRect(x: 101, y: 5.6, width: 4.6, height: 3.2), cornerSize: CGSize(width: 0.8, height: 0.8))
        slats(from: 68, to: 80)
        slats(from: 84, to: 96)
        pantograph(at: 66, roof: 3)
        lines.move(to: p(56.5, 13.5))
        lines.addLine(to: p(60, 13.5))
        bogies(124, 70, 50)
    }

    // MARK: Parts

    /// The body from beyond the left edge along the roof, then `nose` down to the floor line, and back.
    private mutating func hull(roof: CGFloat, nose: (inout Path) -> Void) {
        body.move(to: p(-5, roof))
        nose(&body)
        body.addLine(to: p(-5, Self.floor))
        body.closeSubpath()
    }

    /// Windscreen and cab window as one pane: a curve along the nose, closed over the `back` points.
    private mutating func glass(_ start: CGPoint, _ end: CGPoint, control1: CGPoint, control2: CGPoint, back: [CGPoint]) {
        cutouts.move(to: start)
        cutouts.addCurve(to: end, control1: control1, control2: control2)
        for point in back { cutouts.addLine(to: point) }
        cutouts.closeSubpath()
    }

    private mutating func windows(from start: CGFloat, to end: CGFloat, width: CGFloat = 7, top: CGFloat = 6.4) {
        var x = end - width
        while x >= start {
            cutouts.addRoundedRect(in: CGRect(x: x, y: top, width: width, height: 10.2 - top), cornerSize: CGSize(width: 0.9, height: 0.9))
            x -= width + 2.2
        }
    }

    private mutating func slats(from start: CGFloat, to end: CGFloat, top: CGFloat = 5.4, count: Int = 3) {
        for row in 0..<count {
            cutouts.addRect(CGRect(x: start, y: top + CGFloat(row) * 1.6, width: end - start, height: 0.8))
        }
    }

    private mutating func gap(at x: CGFloat) {
        cutouts.addRect(CGRect(x: x - 0.7, y: 0, width: 1.4, height: 14.6))
    }

    private mutating func redLine(to end: CGFloat) {
        stripe.addRect(CGRect(x: -5, y: 12.1, width: end + 5, height: 0.9))
    }

    private mutating func bogies(_ centers: CGFloat...) {
        for center in centers {
            for x in [center - 3.3, center + 3.3] {
                wheels.addEllipse(in: CGRect(x: x - 1.9, y: 15.7, width: 3.8, height: 3.8))
            }
        }
    }

    private mutating func pantograph(at x: CGFloat, roof: CGFloat, mirrored: Bool = false) {
        let d: CGFloat = mirrored ? -1 : 1
        lines.move(to: p(x - 2.5 * d, roof))
        lines.addLine(to: p(x + 1.5 * d, roof - 1.4))
        lines.addLine(to: p(x - 1.5 * d, roof - 2.7))
        lines.move(to: p(x - 3.6 * d, roof - 2.7))
        lines.addLine(to: p(x + 0.6 * d, roof - 2.7))
    }
}

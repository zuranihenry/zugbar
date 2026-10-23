import Charts
import SwiftUI
import ZugbarCore

/// A trip's speed and the delay at the next stop over time, with where delay reasons came up. Hovering either chart
/// shows the values at that time in both.
struct RideCharts: View {
    let trip: Trip
    /// Where the pointer is. A plain `State` value: the `@State` macro needs a plugin the Command Line Tools lack.
    private var hover = State<Date?>(initialValue: nil)
    @Environment(\.strings) private var strings

    /// Wide enough for "300" and "+12", so both plots start at the same x and their times line up.
    private static let axisWidth: CGFloat = 26

    var body: some View {
        let samples = trip.samples ?? []
        let domain = trip.start...max(trip.end, trip.start.addingTimeInterval(60))
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let selected = hover.wrappedValue, let sample = nearest(to: selected, in: samples) {
                    Text(strings.rideReadout(sample, at: date(of: sample))).monospacedDigit()
                } else {
                    Text(strings.rideLegend)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            speedChart(samples, domain: domain).frame(height: 80)
            delayChart(samples, domain: domain).frame(height: 54)
            ForEach(samples.filter { $0.reasons != nil }, id: \.time) { sample in
                let text = "\(date(of: sample).formatted(.dateTime.hour().minute())) \((sample.reasons ?? []).joined(separator: ", "))"
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(text)
            }
        }
    }

    private func speedChart(_ samples: [RideSample], domain: ClosedRange<Date>) -> some View {
        let fastest = samples.filter { $0.speed != nil }.max { $0.speed! < $1.speed! }
        return Chart {
            ForEach(Array(samples.runs(of: \.speed).enumerated()), id: \.offset) { run, part in
                ForEach(part, id: \.time) { sample in
                    AreaMark(x: .value(strings.time, date(of: sample)), y: .value(strings.speed, sample.speed ?? 0),
                             series: .value("Run", run), stacking: .unstacked)
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value(strings.time, date(of: sample)), y: .value(strings.speed, sample.speed ?? 0),
                             series: .value("Run", run))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            if let fastest, let speed = fastest.speed, speed > 0 {
                PointMark(x: .value(strings.time, date(of: fastest)), y: .value(strings.speed, speed))
                    .symbol { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    .accessibilityLabel(strings.top(speed))
            }
            if let selected = hover.wrappedValue { RuleMark(x: .value(strings.time, selected)).foregroundStyle(Color.secondary.opacity(0.6)) }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(Double(fastest?.speed ?? 0) * 1.1, 50))
        // Times only under the delay chart below.
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine() } }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text("\(value.as(Int.self) ?? 0)").frame(width: Self.axisWidth, alignment: .trailing)
                }
            }
        }
        .chartXSelection(value: hover.projectedValue)
    }

    private func delayChart(_ samples: [RideSample], domain: ClosedRange<Date>) -> some View {
        let delays = samples.compactMap(\.delay)
        return Chart {
            ForEach(Array(samples.runs(of: \.delay).enumerated()), id: \.offset) { run, part in
                ForEach(part, id: \.time) { sample in
                    LineMark(x: .value(strings.time, date(of: sample)), y: .value(strings.delayAtNextStop, sample.delay ?? 0),
                             series: .value("Run", run))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(samples.filter { $0.reasons != nil }, id: \.time) { sample in
                PointMark(x: .value(strings.time, date(of: sample)), y: .value(strings.delayAtNextStop, sample.delay ?? 0))
                    .symbol { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    .accessibilityLabel((sample.reasons ?? []).joined(separator: ", "))
            }
            if let selected = hover.wrappedValue { RuleMark(x: .value(strings.time, selected)).foregroundStyle(Color.secondary.opacity(0.6)) }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: min(0, delays.min() ?? 0)...max(5, delays.max() ?? 0))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    let minutes = value.as(Int.self) ?? 0
                    Text(minutes > 0 ? "+\(minutes)" : "\(minutes)").frame(width: Self.axisWidth, alignment: .trailing)
                }
            }
        }
        .chartXSelection(value: hover.projectedValue)
    }

    private func date(of sample: RideSample) -> Date {
        trip.start.addingTimeInterval(TimeInterval(sample.time))
    }

    private func nearest(to date: Date, in samples: [RideSample]) -> RideSample? {
        samples.min { abs(self.date(of: $0).timeIntervalSince(date)) < abs(self.date(of: $1).timeIntervalSince(date)) }
    }
}

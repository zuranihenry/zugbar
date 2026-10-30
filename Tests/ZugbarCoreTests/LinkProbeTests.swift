import Foundation
import Testing
@testable import ZugbarCore

struct LinkProbeTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// Requests every 15 s from `start`, with these answer times (`nil`: none came).
    func probe(_ latencies: [TimeInterval?]) -> (LinkProbe, Date) {
        var probe = LinkProbe()
        var date = start
        for latency in latencies {
            probe.record(latency: latency, at: date)
            date += 15
        }
        return (probe, date - 15)
    }

    @Test func fastAnswersAreGood() {
        let (probe, now) = probe([0.1, 0.12, 0.09])
        let reading = probe.reading(at: now)
        #expect(reading?.quality == .good)
        #expect(reading?.latency == 0.1)
        #expect(reading?.lost == 0)
    }

    @Test func slowAnswersAreWeakAndSlow() {
        let (probe, now) = probe([1.4, 2.1, 1.2])
        let reading = probe.reading(at: now)
        #expect(reading?.quality == .weak)
        #expect(reading?.isSlow == true)
    }

    @Test func oneLostRequestIsWeakTwoInARowNoInternet() {
        #expect(probe([0.1, 0.1, nil]).0.reading(at: start + 30)?.quality == .weak)
        #expect(probe([0.1, nil, nil]).0.reading(at: start + 30)?.quality == Internet.Quality.none)
    }

    /// Between tunnels: answers again, but it doesn't count as good until the window has no dropout in it.
    @Test func staysWeakForAWhileAfterADropout() {
        let (probe, now) = probe([0.1, nil, nil, 0.1, 0.1, 0.1])
        let reading = probe.reading(at: now)
        #expect(reading?.quality == .weak)
        #expect(reading?.isSlow == false)
        #expect(reading?.lost == 2)
        // Learning goes by the last request alone.
        #expect(reading?.latest == .good)

        var later = probe
        var date = now
        for _ in 0..<8 {
            date += 15
            later.record(latency: 0.1, at: date)
        }
        #expect(later.reading(at: date)?.quality == .good)
    }

    @Test func noReadingLongAfterTheLastRequest() {
        let (probe, now) = probe([0.1, 0.1])
        #expect(probe.reading(at: now + 60) != nil)
        #expect(probe.reading(at: now + 120) == nil)
    }

    @Test func asksLessOftenWhileSteadyAndGood() {
        #expect(probe([0.1, 0.1, 0.1]).0.interval(at: start + 30) == 20)
        #expect(probe([0.1]).0.interval(at: start) == 15)
        #expect(probe([0.1, nil, 0.1]).0.interval(at: start + 30) == 15)
        #expect(probe([0.1, 0.1, nil]).0.interval(at: start + 30) == 5)
        #expect(LinkProbe().interval(at: start) == 15)
    }

    // MARK: - With the portal's level

    @Test func theWorseOfPortalAndMeasurementWins() {
        let portal = Internet(current: .good, next: .weak, nextChange: start + 300)
        let measured = probe([0.1, nil, nil]).0.reading(at: start + 30)?.quality
        let combined = Internet.combining(portal: portal, measured: measured)
        #expect(combined?.current == Internet.Quality.none)
        // The portal's forecast stays.
        #expect(combined?.next == .weak)

        let good = probe([0.1, 0.1]).0.reading(at: start + 15)?.quality
        #expect(Internet.combining(portal: Internet(current: .weak), measured: good)?.current == .weak)
        #expect(Internet.combining(portal: nil, measured: good)?.current == .good)
        #expect(Internet.combining(portal: portal, measured: nil) == portal)
        #expect(Internet.combining(portal: nil, measured: nil) == nil)
    }
}

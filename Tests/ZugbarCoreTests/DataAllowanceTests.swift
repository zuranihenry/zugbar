import Foundation
import Testing
@testable import ZugbarCore

struct DataAllowanceTests {
    @Test func readsTheRoutersAllowance() throws {
        let jsonp = #"({"version":"1.9","ip":"10.0.0.2","online":"1","data_download_used":"40000000","data_upload_used":"2000000","data_total_used":"42000000","data_download_limit":"0","data_upload_limit":"0","data_total_limit":"104857600"});"#
        let allowance = try #require(try Icomera.parseAllowance(Data(jsonp.utf8)))
        #expect(allowance == DataAllowance(used: 42_000_000, limit: 104_857_600))
        #expect(allowance.remaining == 62_857_600)
        #expect(abs(allowance.fractionUsed - 0.4) < 0.01)
    }

    @Test func noLimitIsNoAllowance() throws {
        #expect(try Icomera.parseAllowance(Data(#"({"data_total_used":"5000","data_total_limit":"0"});"#.utf8)) == nil)
        #expect(try Icomera.parseAllowance(Data(#"({"online":"1"});"#.utf8)) == nil)
    }

    @Test func someRoutersOnlyCountDownloads() throws {
        let jsonp = #"({"data_download_used":1000,"data_download_limit":2000,"data_total_limit":""});"#
        #expect(try Icomera.parseAllowance(Data(jsonp.utf8)) == DataAllowance(used: 1000, limit: 2000))
    }

    @Test func readsAHotspotGatewaysSession() {
        let json = #"{"version":"1.0","clientState":1,"session":{"sessionTimeout":0,"maxOctetsBeforeNextRate":96327609,"maxRateDown":2048000,"maxNextRateDown":64000},"accounting":{"sessionTime":104,"inputOctets":3756650,"outputOctets":4772317}}"#
        let allowance = HotspotGateway.parseStatus(Data(json.utf8))
        #expect(allowance == DataAllowance(used: 8_528_967, limit: 104_856_576, throttledTo: 64000))
        #expect(allowance?.remaining == 96_327_609)
        // A home router answers with something else, or not at all.
        #expect(HotspotGateway.parseStatus(Data(#"{"status":"ok"}"#.utf8)) == nil)
        #expect(HotspotGateway.parseStatus(Data("<html>".utf8)) == nil)
        #expect(HotspotGateway.isGateway(Data(json.utf8)))
        #expect(HotspotGateway.isGateway(Data(#"{"version":"1.0","clientState":0}"#.utf8)))
        #expect(!HotspotGateway.isGateway(Data(#"{"status":"ok"}"#.utf8)))
        #expect(HotspotGateway.statusURL(router: "10.0.0.1")?.absoluteString == "http://10.0.0.1/json/status")
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try Icomera.parseAllowance(Data("<html>".utf8)) }
    }

    @Test func savesDataWhereTheWiFiHasALimit() {
        let allowance = DataAllowance(used: 0, limit: 100)
        #expect(DataSaving.automatic.isOn(allowance: allowance, lowDataMode: false))
        #expect(DataSaving.automatic.isOn(allowance: nil, lowDataMode: true))
        #expect(!DataSaving.automatic.isOn(allowance: nil, lowDataMode: false))
        #expect(DataSaving.always.isOn(allowance: nil, lowDataMode: false))
        #expect(!DataSaving.off.isOn(allowance: allowance, lowDataMode: true))
    }

    @Test func warnsOncePerSession() {
        var warning = AllowanceWarning()
        let warnings = [50, 80, 90, 5, 85].map { warning.check(DataAllowance(used: $0, limit: 100)) }
        // Once at 80 %, and again in a new session, which counts from zero.
        #expect(warnings == [false, true, false, false, true])
        // A gateway's limit wobbles by a few bytes between reads; another limit is another allowance.
        let wobbled = warning.check(DataAllowance(used: 90, limit: 101))
        let doubled = warning.check(DataAllowance(used: 180, limit: 200))
        #expect(!wobbled)
        #expect(doubled)
    }
}

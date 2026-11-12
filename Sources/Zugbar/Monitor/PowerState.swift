import Foundation
import IOKit.ps

/// Whether the Mac runs on its battery or in Low Power Mode; the map then places the train less often.
@MainActor
final class PowerState {
    static let shared = PowerState()

    private(set) var onBattery = false
    private(set) var lowPowerMode = false

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { PowerState.shared.refresh() } }
        // Fires on the main run loop when the charger is plugged in or pulled.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerState.shared.refresh() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func refresh() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let providing = sources.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        onBattery = providing == kIOPSBatteryPowerValue
    }
}

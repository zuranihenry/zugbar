import AppKit
import SwiftUI

/// The panel as a regular window. Layout steps with the size: wide → details plus a large map,
/// narrow → one column with a map that scales with the height (dropped only when very short).
struct PanelWindow: View {
    let monitor: TrainMonitor
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("windowShowMap") private var showMap = true

    var body: some View {
        GeometryReader { geometry in
            StatusPanel(monitor: monitor, layout: layout(for: geometry.size))
        }
        .frame(minWidth: 340, minHeight: 420)
        .background(WindowLevel(floating: alwaysOnTop))
    }

    private func layout(for size: CGSize) -> PanelLayout {
        guard showMap else { return .column(mapHeight: nil) }
        if size.width >= 720 { return .split }
        if size.height >= 480 { return .column(mapHeight: min(max(size.height * 0.28, 150), 320)) }
        return .column(mapHeight: nil)
    }
}

/// Sets the hosting window's level, which SwiftUI doesn't expose.
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
            view.window?.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}

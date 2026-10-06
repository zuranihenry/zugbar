import AppKit

/// Shows a native menu at the mouse pointer. SwiftUI's `Menu` closes on the first click inside an NSPopover.
@MainActor
enum PopUpMenu {
    struct Item {
        var title: String
        var isHeader = false
        var action: () -> Void = {}
        static var separator: Item { Item(title: "") }
        static func header(_ title: String) -> Item { Item(title: title, isHeader: true) }
    }

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        for item in items {
            if item.title.isEmpty {
                menu.addItem(.separator())
            } else if item.isHeader {
                if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: item.title)) }
            } else {
                menu.addItem(ClosureMenuItem(title: item.title, action: item.action))
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

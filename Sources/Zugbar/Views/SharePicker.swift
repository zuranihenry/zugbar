import AppKit

/// The system share menu for a text, with Copy on top. `ShareLink` can't add Copy, and messengers without a
/// share extension (WhatsApp, Signal, Discord on the Mac) never show up there, so copying is the way into them.
@MainActor
enum SharePicker {
    private static var delegate: CopyFirst?

    static func show(_ text: String, copyTitle: String) {
        let mouse = NSEvent.mouseLocation
        // The topmost window under the pointer: the one whose button was just clicked.
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number) ?? NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let picker = NSSharingServicePicker(items: [text])
        delegate = CopyFirst(text: text, title: copyTitle)
        picker.delegate = delegate
        // An empty rect makes the picker point at the middle of the whole window; a button-sized one at the button.
        picker.show(relativeTo: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16), of: view, preferredEdge: .minY)
    }
}

private final class CopyFirst: NSObject, NSSharingServicePickerDelegate {
    let copy: NSSharingService

    init(text: String, title: String) {
        let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage()
        copy = NSSharingService(title: title, image: image, alternateImage: nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        [copy] + proposed
    }
}

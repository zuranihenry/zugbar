import AppKit
import Observation
import SwiftUI
import UserNotifications
import ZugbarCore

/// Owns the menu bar item, its popover and the app's windows.
/// AppKit instead of SwiftUI's MenuBarExtra: NSPopover anchors to the icon, follows content size changes,
/// and picks up Liquid Glass on macOS 26 by itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = TrainMonitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panelWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil
        )

        let actions = AppActions(
            openSettings: { [weak self] in self?.showSettings() },
            openWindow: { [weak self] in self?.showPanelWindow() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        )
        let hosting = NSHostingController(rootView: AppEnvironment(actions: actions) { StatusPanel(monitor: self.monitor) })
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        self.actions = actions
        updateLabel()
    }

    private var actions: AppActions!

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this the first click inside (e.g. on a menu) only makes the popover key.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let strings = Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
        let menu = NSMenu()
        menu.addItem(withTitle: strings.openWindow, action: #selector(openPanelWindowFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: strings.settings, action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanelWindowFromMenu() { showPanelWindow() }
    @objc private func openSettingsFromMenu() { showSettings() }

    /// A Dock icon while a real window is open, menu bar only otherwise.
    private func updateActivationPolicy() {
        let hasWindow = [panelWindow, settingsWindow].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == panelWindow || window == settingsWindow else { return }
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPanelWindow() }
        return true
    }

    /// Re-renders the menu bar text whenever the observed monitor state changes.
    private func updateLabel() {
        withObservationTracking {
            renderLabel()
        } onChange: {
            Task { @MainActor [weak self] in self?.updateLabel() }
        }
    }

    private func renderLabel() {
        guard let button = statusItem.button else { return }
        let defaults = UserDefaults.standard
        let options = MenuTitleOptions(
            showSpeed: defaults.object(forKey: "showSpeed") as? Bool ?? true,
            showStation: defaults.object(forKey: "showStation") as? Bool ?? true,
            showCountdown: defaults.object(forKey: "showCountdown") as? Bool ?? true,
            showTopSpeedFlame: defaults.object(forKey: "showTopSpeedFlame") as? Bool ?? true,
            stationStyle: MenuTitleOptions.StationStyle(rawValue: defaults.string(forKey: "stationStyle") ?? "") ?? .full,
            showUnit: defaults.object(forKey: "showUnit") as? Bool ?? true,
            minutesOnly: defaults.bool(forKey: "minutesOnly")
        )
        let strings = Strings(AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system)
        let title = monitor.status.map {
            MenuTitle.make(status: $0, displaySpeed: monitor.displaySpeed, isTopSpeed: monitor.isTopSpeed,
                           now: monitor.now, options: options, nowLabel: strings.now)
        } ?? ""

        if title.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.image = NSImage(systemSymbolName: monitor.status == nil ? "tram" : "tram.fill", accessibilityDescription: "Zugbar")
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
        }
    }

    private func showPanelWindow() {
        popover.performClose(nil)
        if panelWindow == nil {
            let hosting = NSHostingController(rootView: AppEnvironment(actions: actions) { PanelWindow(monitor: self.monitor) })
            hosting.sizingOptions = .minSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Zugbar"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 420, height: 760))
            window.setFrameAutosaveName("PanelWindow")
            window.isReleasedWhenClosed = false
            panelWindow = window
        }
        panelWindow?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApp.activate()
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            // Toolbar tabs with icons, like the system's own settings windows.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let strings = Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
            for tab in SettingsTab.allCases {
                let hosting = NSHostingController(rootView: AppEnvironment(actions: actions) { tab.view(monitor: self.monitor) })
                hosting.sizingOptions = .preferredContentSize
                let item = NSTabViewItem(viewController: hosting)
                item.label = tab.title(strings)
                item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApp.activate()
    }
}

/// Window and settings actions for views hosted outside SwiftUI scenes.
struct AppActions: Sendable {
    var openSettings: @MainActor @Sendable () -> Void = {}
    var openWindow: @MainActor @Sendable () -> Void = {}
    var closePopover: @MainActor @Sendable () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions()
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

/// Applies language, locale and actions to every hosted root view.
struct AppEnvironment<Content: View>: View {
    let actions: AppActions
    @ViewBuilder let content: () -> Content
    @AppStorage("language") private var language = AppLanguage.system

    var body: some View {
        content()
            .environment(\.strings, Strings(language))
            .environment(\.locale, language.locale)
            .environment(\.appActions, actions)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// macOS hides notifications from the frontmost app unless told otherwise, e.g. while Settings is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

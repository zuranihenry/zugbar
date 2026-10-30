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

    func applicationWillTerminate(_ notification: Notification) {
        monitor.trips.finish()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        NSApp.setActivationPolicy(.accessory)
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
        // A change made in System Settings shows when coming back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.monitor.refreshNotificationPermission() } }

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
        monitor.updates.start()

        // Settings tabs are AppKit items, so their titles follow a language change by hand.
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil
        )
    }

    private var settingsLanguage: String?

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { self.updateSettingsTitles() }
    }

    private var menuLanguage: String?

    /// A menu bar app shows no main menu, but the shortcuts behind one (⌘C, ⌘V, ⌘A, ⌘Z in text fields, ⌘W, ⌘Q, ⌘,)
    /// only work with one.
    private func buildMainMenu() {
        let language = UserDefaults.standard.string(forKey: "language") ?? ""
        guard language != menuLanguage else { return }
        menuLanguage = language
        let strings = Strings(AppLanguage(rawValue: language) ?? .system)
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        add("Zugbar", [item(strings.settings, #selector(openSettingsFromMenu), ",", target: self), .separator(),
                       item(strings.quit, #selector(NSApplication.terminate(_:)), "q")])
        add(strings.menuEdit, [item(strings.menuUndo, Selector(("undo:")), "z"), item(strings.menuRedo, Selector(("redo:")), "Z"),
                               .separator(), item(strings.menuCut, #selector(NSText.cut(_:)), "x"),
                               item(strings.copy, #selector(NSText.copy(_:)), "c"), item(strings.menuPaste, #selector(NSText.paste(_:)), "v"),
                               item(strings.menuSelectAll, #selector(NSText.selectAll(_:)), "a")])
        add(strings.menuWindow, [item(strings.menuClose, #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }

    private func updateSettingsTitles() {
        buildMainMenu()
        let language = UserDefaults.standard.string(forKey: "language") ?? ""
        guard language != settingsLanguage, let tabs = settingsWindow?.contentViewController as? NSTabViewController else { return }
        settingsLanguage = language
        let strings = Strings(AppLanguage(rawValue: language) ?? .system)
        for (item, tab) in zip(tabs.tabViewItems, SettingsTab.allCases) { item.label = tab.title(strings) }
        let selected = tabs.selectedTabViewItemIndex
        if tabs.tabViewItems.indices.contains(selected) { settingsWindow?.title = tabs.tabViewItems[selected].label }
    }

    private var actions: AppActions!

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// Opens the popover, or the window when the menu bar item is hidden behind a full menu bar.
    private func showTrip() {
        guard statusItem.button?.window?.isVisible == true else { return showPanelWindow() }
        if !popover.isShown { togglePopover() }
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
            showEstimate: defaults.object(forKey: "menuBarEstimate") as? Bool ?? true,
            showStation: defaults.object(forKey: "showStation") as? Bool ?? true,
            showCountdown: defaults.object(forKey: "showCountdown") as? Bool ?? true,
            showTopSpeedFlame: defaults.object(forKey: "showTopSpeedFlame") as? Bool ?? true,
            // Never chosen reads as automatic, as before there was a choice for it.
            stationStyle: MenuTitleOptions.StationStyle(rawValue: defaults.string(forKey: "stationStyle") ?? "") ?? .automatic,
            showUnit: defaults.object(forKey: "showUnit") as? Bool ?? true,
            minutesOnly: defaults.bool(forKey: "minutesOnly")
        )
        let strings = Strings(AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system)
        let status = monitor.status
        let estimate = options.showEstimate ? status.flatMap { monitor.estimates.speed($0, at: monitor.now)?.speed } : nil
        let waiting = status?.waitingStop(monitor.journey.plan?.boardingStopID, at: monitor.now)
        func makeTitle(_ options: MenuTitleOptions) -> String {
            status.map {
                MenuTitle.make(status: $0, displaySpeed: monitor.displaySpeed, isTopSpeed: monitor.isTopSpeed,
                               now: monitor.now, options: options, nowLabel: strings.now, estimatedSpeed: estimate,
                               waitingAt: waiting, trackLabel: strings.track, cancelledLabel: strings.cancelled)
            } ?? ""
        }
        let title = MenuTitle.fitted(options, width: MenuTitle.width, make: makeTitle)

        if title.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.image = NSImage(systemSymbolName: status == nil ? "tram" : "tram.fill", accessibilityDescription: "Zugbar")
            button.setAccessibilityLabel(nil)
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: MenuTitle.font])
            // VoiceOver would read the countdown as a time of day and name each symbol.
            button.setAccessibilityLabel(status.flatMap {
                strings.spokenMenuTitle($0, speed: monitor.displaySpeed, estimate: estimate, waitingAt: waiting,
                                        now: monitor.now, options: options)
            })
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
        // Built again when reopened, so each tab is measured with what it shows now (e.g. trips logged since).
        if settingsWindow?.isVisible == false { settingsWindow = nil }
        if settingsWindow == nil {
            // Toolbar tabs with icons, like the system's own settings windows.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let strings = Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
            for tab in SettingsTab.allCases {
                let hosting = NSHostingController(rootView: AppEnvironment(actions: actions) { tab.view(monitor: self.monitor) })
                // Size each tab once from its natural height, capped so tall tabs scroll instead of being cut off.
                // Re-measuring on every change resized the window while toggling and made the form drop sections.
                let measure = NSHostingController(rootView: AppEnvironment(actions: actions) {
                    tab.view(monitor: self.monitor).fixedSize(horizontal: false, vertical: true)
                })
                let natural = measure.view.fittingSize
                hosting.sizingOptions = []
                hosting.preferredContentSize = NSSize(width: 480, height: min(natural.height + 24, 640))
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
            settingsLanguage = UserDefaults.standard.string(forKey: "language") ?? ""
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApp.activate()
    }
}

extension MenuTitle {
    /// The menu bar's font, which the settings preview measures with too.
    @MainActor static var font: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    @MainActor static func width(_ title: String) -> Double {
        NSAttributedString(string: title, attributes: [.font: font]).size().width
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

    /// Opens the link a notification carries, e.g. the release page for an update.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: text) else {
            // A journey notification: show the trip.
            await MainActor.run { self.showTrip() }
            return
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

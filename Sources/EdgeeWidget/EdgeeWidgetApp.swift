import AppKit
import SwiftUI
import UserNotifications

@main enum EdgeeWidgetApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var store: AppStore!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        store = AppStore(demo: args.contains("--demo"))
        if args.contains("--agents") { store.selectedTab = .agents }
        if args.contains("--watchdog") { store.selectedTab = .watchdog }
        if args.contains("--settings") { store.showSettings = true }
        UNUserNotificationCenter.current().delegate = self
        configureMenu()
        configureStatusItem()
        popover.contentSize = NSSize(width: 456, height: 760)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView().environmentObject(store))
        store.onStatusChange = { [weak self] in self?.updateStatus() }
        store.onPinChange = { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" { self.store.refresh(force: true); return nil }
            if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            return event
        }
        store.start()
        if args.contains("--window") || args.contains("--snapshot") { openWindow() }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.saveSnapshot(path) }
        }
    }
    private func configureMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Edgee Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        main.addItem(item)
        NSApplication.shared.mainMenu = main
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "Edgee Pulse")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatus()
    }
    private func updateStatus() {
        statusItem.button?.title = " " + store.statusTitle
        statusItem.button?.toolTip = store.statusDescription
        statusItem.button?.setAccessibilityLabel(store.statusDescription)
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Edgee Pulse", action: #selector(showPopover), keyEquivalent: "")
            menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
    @objc private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func refresh() { store.refresh(force: true) }
    private func openWindow() {
        let controller = NSHostingController(rootView: PanelView().environmentObject(store))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 456, height: 760), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Edgee Pulse"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = controller
        panel.setContentSize(NSSize(width: 456, height: 760))
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(Theme.background)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = panel
    }
    private func saveSnapshot(_ path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)); print("Snapshot saved.") }
        catch { fputs("Snapshot could not be saved.\n", stderr) }
        if ProcessInfo.processInfo.arguments.contains("--exit-after-snapshot") { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) { store.stop(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.store.selectedTab = .watchdog; self.showPopover() }
    }
}

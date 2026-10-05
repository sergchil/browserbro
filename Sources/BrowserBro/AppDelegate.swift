import AppKit
import RoutingCore
import SwiftUI

private let keyDirectObject = AEKeyword(0x2D2D_2D2D)   // '----'
private let keySenderPID = AEKeyword(0x7370_6964)      // 'spid'

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var launchedWithLink = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        model = AppModel()
        if DemoMode.isOn { DemoMode.prepare(model) }
        // Register before launch finishes, so the link that launched the app is not lost.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "BrowserBro")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshDefaultStatus() }
        }
        if SelfTest.requested {
            Task { await SelfTest(model: model).run() }
            return
        }
        if DemoMode.isOn && DemoTour.requested {
            Task { await DemoTour(model: model).run() }
            return
        }
        // First launch by hand (not by a link): show Settings so the user can set things up.
        if !launchedWithLink && !SystemIntegration.isDefaultBrowser {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.launchedWithLink else { return }
                self.openSettings(pane: .general)
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(pane: .general)
        return true
    }

    /// HTML files opened with BrowserBro.
    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithLink = true
        model.handle(urls: urls, sourceBundleID: nil, modifiers: currentModifiers())
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        launchedWithLink = true
        let modifiers = currentModifiers()
        var urls: [URL] = []
        if let direct = event.paramDescriptor(forKeyword: keyDirectObject) {
            if direct.numberOfItems > 0 {
                for i in 1...direct.numberOfItems {
                    if let s = direct.atIndex(i)?.stringValue, let u = URL(string: s) { urls.append(u) }
                }
            } else if let s = direct.stringValue, let u = URL(string: s) {
                urls.append(u)
            }
        }
        let source = senderBundleID(event)
        model.handle(urls: urls, sourceBundleID: source, modifiers: modifiers)
    }

    private func senderBundleID(_ event: NSAppleEventDescriptor) -> String? {
        let me = Bundle.main.bundleIdentifier
        if let pid = event.attributeDescriptor(forKeyword: keySenderPID)?.int32Value, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier, id != me {
            return id
        }
        // Fallback: the app in front when the link arrived.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == me ? nil : front
    }

    private func currentModifiers() -> ModifierSet {
        let flags = NSEvent.modifierFlags
        var m: ModifierSet = []
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    // MARK: Menu bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshDefaultStatus()
        menu.removeAllItems()

        let header = NSMenuItem(title: model.isDefaultBrowser ? "BrowserBro is your default browser" : "BrowserBro is not the default browser", action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: model.isDefaultBrowser ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        header.isEnabled = false
        menu.addItem(header)
        if !model.isDefaultBrowser {
            menu.addItem(item("Set as Default Browser…", #selector(setDefault)))
        }
        if let err = model.rules.loadError {
            let e = NSMenuItem(title: "rules.json error: \(err)", action: #selector(revealRules), keyEquivalent: "")
            e.target = self
            e.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
            menu.addItem(e)
        }

        menu.addItem(.separator())
        let recentTitle = NSMenuItem(title: model.recent.isEmpty ? "No recent links" : "Recent", action: nil, keyEquivalent: "")
        recentTitle.isEnabled = false
        menu.addItem(recentTitle)
        for (i, r) in model.recent.enumerated() {
            let host = r.request.url.host() ?? r.request.url.absoluteString
            let it = NSMenuItem(title: "\(host) → \(r.target.fullName)", action: #selector(reopenRecent(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.toolTip = "\(r.ruleName.map { "Rule: \($0)" } ?? "Chosen in picker")\nClick to open elsewhere."
            it.image = { let img = AppIcons.icon(for: r.target.appURL).copy() as! NSImage; img.size = NSSize(width: 16, height: 16); return img }()
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let fallback = NSMenuItem(title: "When No Rule Matches", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for kind in FallbackKind.allCases {
            let it = NSMenuItem(title: kind == .picker ? "Show Picker" : "Open in Default Target", action: #selector(setFallback(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = kind.rawValue
            it.state = model.rules.file.fallback == kind ? .on : .off
            sub.addItem(it)
        }
        fallback.submenu = sub
        menu.addItem(fallback)
        menu.addItem(item("Open Link from Clipboard", #selector(openClipboard)))
        menu.addItem(.separator())
        menu.addItem(item("Rules…", #selector(openRules), key: ","))
        menu.addItem(item("Test a Link…", #selector(openTester)))
        menu.addItem(item("Reveal Rules File", #selector(revealRules)))
        menu.addItem(.separator())
        menu.addItem(item("Quit BrowserBro", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func setDefault() {
        Task {
            do { try await SystemIntegration.becomeDefaultBrowser(settings: model.settings) } catch { Log.app.error("Set default failed: \(error.localizedDescription, privacy: .public)") }
            model.refreshDefaultStatus()
        }
    }

    @objc private func reopenRecent(_ sender: NSMenuItem) {
        guard model.recent.indices.contains(sender.tag) else { return }
        model.reopen(model.recent[sender.tag].request)
    }

    @objc private func setFallback(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = FallbackKind(rawValue: raw) else { return }
        model.rules.update { $0.fallback = kind }
    }

    @objc private func openClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            NSSound.beep()
            return
        }
        model.reopen(RouteRequest(url: url))
    }

    @objc private func openRules() { openSettings(pane: .rules) }
    @objc private func openTester() { openSettings(pane: .tester) }
    @objc private func revealRules() { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.rulesFile]) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Settings window

    func openSettings(pane: SettingsPane) {
        model.settingsPane = pane
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "BrowserBro"
            w.toolbarStyle = .unified
            w.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            w.setContentSize(NSSize(width: 1020, height: 680))
            w.minSize = NSSize(width: 980, height: 520)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("BrowserBroSettingsWindow")
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                // Back to a menu bar-only app when Settings closes.
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

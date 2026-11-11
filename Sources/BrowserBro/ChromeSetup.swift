import AppKit
import RoutingCore
import SwiftUI

/// Chrome mode: Chrome stays the default browser, and the BrowserBro extension in each Chrome profile
/// hands links from other apps to BrowserBro (see Bridge.swift and extension/).
///
/// The extension ships inside the app and is copied to one fixed folder. Chrome keeps that path, so the
/// extension keeps its ID and gets new files with each app update (the user clicks Reload in Chrome).
@MainActor
enum ChromeSetup {
    static let extensionName = "BrowserBro for Chrome"
    static var bundled: URL? { Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) }
    static var folder: URL { AppPaths.supportDir.appending(path: "ChromeExtension") }
    static var chromeDataDir: URL { KnownBrowsers.supportDir.appending(path: "Google/Chrome") }
    static var chromeAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeBridge.chromeID) }

    static var isChromeDefault: Bool {
        guard let url = SystemIntegration.currentDefaultBrowser else { return false }
        return Bundle(url: url)?.bundleIdentifier == ChromeBridge.chromeID
    }

    /// Copies the bundled extension to `folder` when its files changed.
    static func syncExtension() {
        guard let source = bundled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
            guard let data = try? Data(contentsOf: source.appending(path: name)) else { continue }
            let target = folder.appending(path: name)
            if data != (try? Data(contentsOf: target)) { try? data.write(to: target, options: .atomic) }
        }
    }

    enum InstallState: Equatable {
        case missing
        /// Loaded from BrowserBro's folder: gets updates.
        case installed
        /// Loaded from another folder (for example a git checkout): works, but does not get app updates.
        case otherFolder
    }

    /// Reads Chrome's own record of the extensions loaded in one profile.
    static func state(profile dir: String) -> InstallState {
        if DemoMode.isOn { return .missing }
        var best = InstallState.missing
        for file in ["Secure Preferences", "Preferences"] {
            let url = chromeDataDir.appending(path: dir).appending(path: file)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (object["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for case let entry as [String: Any] in settings.values {
                guard let path = entry["path"] as? String, path.hasPrefix("/"), isOurExtension(at: URL(fileURLWithPath: path)) else { continue }
                if URL(fileURLWithPath: path).standardizedFileURL == folder.standardizedFileURL { return .installed }
                best = .otherFolder
            }
        }
        return best
    }

    private static func isOurExtension(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return manifest["name"] as? String == extensionName
    }

    /// Chrome profiles BrowserBro knows about, in picker order.
    static func profiles(_ model: AppModel) -> [BrowserTarget] {
        model.allTargetsOrdered.filter { $0.id.app == ChromeBridge.chromeID && $0.id.profile != nil }
    }

    static func setupURL(for target: BrowserTarget) -> URL {
        var c = URLComponents(string: "http://127.0.0.1:\(ChromeBridge.port)/setup")!
        c.queryItems = [URLQueryItem(name: "profile", value: target.id.profile), URLQueryItem(name: "name", value: target.profileName ?? "")]
        return c.url!
    }

    /// Opens the setup page in each given profile. Chrome does not let an app open chrome://extensions,
    /// so the page walks the user through it, and the extension pairs itself with the page when loaded.
    static func openSetup(_ targets: [BrowserTarget], model: AppModel) {
        syncExtension()
        Task {
            for target in targets {
                try? await model.launch(setupURL(for: target), in: target, options: TargetOptions())
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    /// macOS asks the user to confirm.
    static func makeChromeDefault(settings: SettingsStore) async throws {
        guard let chrome = chromeAppURL else { throw LaunchError(message: "Google Chrome is not installed.") }
        if let current = SystemIntegration.currentDefaultBrowser, Bundle(url: current)?.bundleIdentifier != Bundle.main.bundleIdentifier,
           Bundle(url: current)?.bundleIdentifier != ChromeBridge.chromeID {
            settings.settings.previousDefaultBrowser = current.path
        }
        for scheme in ["http", "https"] {
            // Same as for BrowserBro: the second call can report an error even though it worked.
            try? await NSWorkspace.shared.setDefaultApplication(at: chrome, toOpenURLsWithScheme: scheme)
        }
        if !isChromeDefault { throw LaunchError(message: "macOS did not make Chrome the default browser.") }
    }

    // MARK: Setup page

    static func setupPage(profile: String, name: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let path = esc(folder.path)
        let title = name.isEmpty ? "this profile" : "“\(esc(name))”"
        let query = esc(profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Set up BrowserBro</title>
        <style>
        :root { color-scheme: light dark; font: 15px/1.5 -apple-system, system-ui, sans-serif; }
        body { max-width: 640px; margin: 48px auto; padding: 0 24px; }
        h1 { font-size: 24px; margin-bottom: 4px; }
        p.sub { color: GrayText; margin-top: 0; }
        ol { padding-left: 22px; } li { margin: 14px 0; }
        code { font: 13px ui-monospace, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); padding: 2px 6px; border-radius: 6px; word-break: break-all; }
        button { font: inherit; padding: 3px 12px; margin-left: 6px; border-radius: 7px; border: 1px solid color-mix(in srgb, CanvasText 25%, transparent); background: Canvas; color: CanvasText; cursor: pointer; }
        kbd { font: 13px ui-monospace, monospace; border: 1px solid color-mix(in srgb, CanvasText 25%, transparent); border-radius: 5px; padding: 0 5px; }
        #status { margin-top: 28px; padding: 12px 16px; border-radius: 10px; background: color-mix(in srgb, CanvasText 6%, transparent); }
        #status.done { background: color-mix(in srgb, #34c759 22%, transparent); }
        </style></head><body>
        <h1>Set up BrowserBro in \(title)</h1>
        <p class="sub">Chrome stays your default browser. This extension hands links from other apps to BrowserBro, which opens them in the right profile.</p>
        <ol>
        <li>Open <code>chrome://extensions</code><button data-copy="chrome://extensions">Copy</button><br>Paste it into the address bar of a new tab (<kbd>⌘T</kbd>, <kbd>⌘V</kbd>, <kbd>Return</kbd>). Chrome does not let apps open this page.</li>
        <li>Turn on <b>Developer mode</b> (top right).</li>
        <li>Click <b>Load unpacked</b>, press <kbd>⌘⇧G</kbd>, paste this folder and press <kbd>Return</kbd>, then <b>Select</b>:<br>
        <code>\(path)</code><button data-copy="\(path)">Copy</button></li>
        </ol>
        <div id="status">Waiting for the extension…</div>
        <script>
        for (const b of document.querySelectorAll('button[data-copy]')) {
          b.onclick = async () => { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = 'Copied'; setTimeout(() => b.textContent = 'Copy', 1500); };
        }
        const status = document.getElementById('status');
        const poll = async () => {
          try {
            const r = await fetch('/status?profile=\(query)');
            if ((await r.json()).installed) {
              status.textContent = 'Done. BrowserBro now gets links in this profile. You can close this tab.';
              status.className = 'done';
              return;
            }
          } catch (e) {}
          setTimeout(poll, 1500);
        };
        poll();
        </script></body></html>
        """
    }
}

// MARK: - Settings section

/// General pane → "Chrome": keep Chrome as the default browser and set the extension up per profile.
struct ChromeSection: View {
    @Bindable var model: AppModel
    @State private var states: [String: ChromeSetup.InstallState] = [:]
    @State private var chromeDefault = ChromeSetup.isChromeDefault
    @State private var errorText: String?

    var body: some View {
        let profiles = ChromeSetup.profiles(model)
        if !profiles.isEmpty {
            Section("Keep Chrome as the default browser") {
                Text("Chrome opens every link, and the BrowserBro extension in each Chrome profile hands links from other apps to BrowserBro. Your rules and the picker still work. Rules by source app don't.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(profiles) { target in
                    HStack {
                        Text(model.settings.settings.customLabels[target.id.description] ?? target.profileName ?? target.id.profile ?? "")
                        Spacer()
                        switch states[target.id.profile ?? ""] ?? .missing {
                        case .installed:
                            Label("Extension installed", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor).foregroundStyle(.secondary)
                        case .otherFolder:
                            Text("Installed from another folder: no updates").foregroundStyle(.secondary)
                            Button("Set Up Again") { ChromeSetup.openSetup([target], model: model) }
                        case .missing:
                            Button("Set Up") { ChromeSetup.openSetup([target], model: model) }
                        }
                    }
                }
                HStack {
                    let missing = profiles.filter { states[$0.id.profile ?? ""] != .installed }
                    Button("Set Up All Profiles") { ChromeSetup.openSetup(missing, model: model) }
                        .disabled(missing.isEmpty)
                    Button("Reveal Extension Folder") {
                        ChromeSetup.syncExtension()
                        NSWorkspace.shared.activateFileViewerSelecting([ChromeSetup.folder])
                    }
                    Spacer()
                    if chromeDefault {
                        Label("Chrome is the default", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                    } else {
                        Button("Make Chrome the Default…") {
                            Task {
                                do { try await ChromeSetup.makeChromeDefault(settings: model.settings); errorText = nil } catch { errorText = error.localizedDescription }
                                refresh()
                            }
                        }
                    }
                }
                if let errorText {
                    Label(errorText, systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor).font(.callout)
                }
                Text("After a BrowserBro update, click Reload on the extension in chrome://extensions in each profile.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .task {
                // Chrome writes its extension list a moment after "Load unpacked": keep the rows fresh.
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func refresh() {
        var next: [String: ChromeSetup.InstallState] = [:]
        for target in ChromeSetup.profiles(model) {
            if let dir = target.id.profile { next[dir] = ChromeSetup.state(profile: dir) }
        }
        if next != states { states = next }
        chromeDefault = ChromeSetup.isChromeDefault
        model.refreshDefaultStatus()
    }
}

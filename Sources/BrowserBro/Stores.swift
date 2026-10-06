import AppKit
import RoutingCore
import ServiceManagement
import SwiftUI

enum AppPaths {
    /// `BROWSERBRO_SUPPORT_DIR` points the app at another folder (used by the self-test).
    static var supportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["BROWSERBRO_SUPPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        // Demo mode never touches the real rules and settings.
        if DemoMode.isOn { return FileManager.default.temporaryDirectory.appending(path: "BrowserBro-demo") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/BrowserBro")
    }
    static var rulesFile: URL { supportDir.appending(path: "rules.json") }
    static var settingsFile: URL { supportDir.appending(path: "settings.json") }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Rules

/// Loads, saves and watches `rules.json`. An invalid file never replaces the last good rules.
@MainActor
@Observable
final class RuleStore {
    private(set) var file = RulesFile()
    private(set) var compiled = CompiledRules(RulesFile())
    /// Set when the file on disk can't be used. The previous rules stay active.
    private(set) var loadError: String?

    @ObservationIgnored private var lastData: Data?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init() {
        if !FileManager.default.fileExists(atPath: AppPaths.rulesFile.path) {
            try? AppPaths.atomicWrite(RulesCodec.encode(RulesFile()), to: AppPaths.rulesFile)
        }
        reload()
        watch()
    }

    func reload() {
        guard let data = try? Data(contentsOf: AppPaths.rulesFile) else {
            loadError = "Can't read \(AppPaths.rulesFile.path)."
            return
        }
        guard data != lastData else { return }
        lastData = data
        do {
            let f = try RulesCodec.decode(data)
            file = f
            compiled = CompiledRules(f)
            loadError = nil
            Log.app.info("Loaded \(f.rules.count) rules")
        } catch {
            loadError = error.message
            Log.app.error("rules.json rejected: \(error.message, privacy: .public)")
        }
    }

    func update(_ change: (inout RulesFile) -> Void) {
        var f = file
        change(&f)
        save(f)
    }

    func save(_ f: RulesFile) {
        let data = RulesCodec.encode(f)
        do {
            try AppPaths.atomicWrite(data, to: AppPaths.rulesFile)
            lastData = data
            file = f
            compiled = CompiledRules(f)
            loadError = nil
        } catch {
            loadError = "Couldn't save rules: \(error.localizedDescription)"
        }
    }

    func warnings(available: Set<TargetID>) -> [RuleWarning] {
        ConflictAnalyzer.analyze(file, available: available)
    }

    /// Watch the folder (editors and `atomicWrite` replace the file) and the file itself (some tools write in place).
    private func watch() {
        watcher = makeSource(path: AppPaths.supportDir.path)
        armFileWatcher()
    }

    private func armFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = makeSource(path: AppPaths.rulesFile.path)
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.debounce?.cancel()
                self.debounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self.armFileWatcher() // the file may be a new inode now
                    self.reload()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var pulseEnabled = true
    var hiddenTargets: Set<String> = []
    /// Non-browser apps (hidden by default) that the user chose to show.
    var shownTargets: Set<String> = []
    var targetOrder: [String] = []
    var customLabels: [String: String] = [:]
    var customKeys: [String: Int] = [:]
    /// App path of the default browser before BrowserBro took over. Used as last-resort fallback.
    var previousDefaultBrowser: String?
    /// The "Start with presets?" sheet was shown once (or rules already existed).
    var presetsOffered = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pulseEnabled = try c.decodeIfPresent(Bool.self, forKey: .pulseEnabled) ?? true
        hiddenTargets = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenTargets) ?? []
        shownTargets = try c.decodeIfPresent(Set<String>.self, forKey: .shownTargets) ?? []
        targetOrder = try c.decodeIfPresent([String].self, forKey: .targetOrder) ?? []
        customLabels = try c.decodeIfPresent([String: String].self, forKey: .customLabels) ?? [:]
        customKeys = try c.decodeIfPresent([String: Int].self, forKey: .customKeys) ?? [:]
        previousDefaultBrowser = try c.decodeIfPresent(String.self, forKey: .previousDefaultBrowser)
        presetsOffered = try c.decodeIfPresent(Bool.self, forKey: .presetsOffered) ?? false
    }
}

@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet { if settings != oldValue { persist() } }
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.settingsFile), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
    }

    func isVisible(_ t: BrowserTarget) -> Bool {
        let key = t.id.description
        return t.isKnownBrowser ? !settings.hiddenTargets.contains(key) : settings.shownTargets.contains(key)
    }

    func setVisible(_ t: BrowserTarget, _ visible: Bool) {
        let key = t.id.description
        if t.isKnownBrowser {
            if visible { settings.hiddenTargets.remove(key) } else { settings.hiddenTargets.insert(key) }
        } else {
            if visible { settings.shownTargets.insert(key) } else { settings.shownTargets.remove(key) }
        }
    }

    func binding<V>(_ kp: WritableKeyPath<AppSettings, V>) -> Binding<V> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? AppPaths.atomicWrite(data, to: AppPaths.settingsFile) }
    }
}

// MARK: - Default browser and login item

@MainActor
enum SystemIntegration {
    static let probe = URL(string: "https://example.com")!

    static var currentDefaultBrowser: URL? { NSWorkspace.shared.urlForApplication(toOpen: probe) }

    static var isDefaultBrowser: Bool {
        currentDefaultBrowser?.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            || Bundle(url: currentDefaultBrowser ?? probe)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS shows its own confirmation dialog for this.
    static func becomeDefaultBrowser(settings: SettingsStore) async throws {
        if let current = currentDefaultBrowser, Bundle(url: current)?.bundleIdentifier != Bundle.main.bundleIdentifier {
            settings.settings.previousDefaultBrowser = current.path
        }
        for scheme in ["http", "https"] {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            } catch {
                // macOS asks once for both schemes; the second call can report an error even though it worked.
                // Trust the real state, not the error.
                Log.app.notice("setDefaultApplication(\(scheme, privacy: .public)) reported: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !isDefaultBrowser {
            throw LaunchError(message: "macOS did not make BrowserBro the default browser. You can also set it in System Settings → Desktop & Dock → Default web browser.")
        }
    }

    static func restorePreviousBrowser(settings: SettingsStore) async throws {
        guard let path = settings.settings.previousDefaultBrowser else { return }
        for scheme in ["http", "https"] {
            try await NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: path), toOpenURLsWithScheme: scheme)
        }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

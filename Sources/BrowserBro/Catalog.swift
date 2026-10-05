import AppKit
import RoutingCore
import SQLite3

/// How a browser accepts a profile on the command line.
enum BrowserFamily: String, Hashable, Sendable {
    case chromium
    case gecko
    /// Arc: ignores command-line flags; a profile is reached through its Space (AppleScript).
    case arc
    case safari
    case other

    var supportsPrivate: Bool { self == .chromium || self == .gecko }
}

/// One choice in the picker: a browser, or a browser + profile.
struct BrowserTarget: Identifiable, Hashable, Sendable {
    let id: TargetID
    let appName: String
    let profileName: String?
    let appURL: URL
    let family: BrowserFamily
    /// Absolute path / directory name used when launching (Gecko: absolute profile path, Arc: Space ID).
    let launchProfile: String?
    /// Profile color (sRGB 0…1), when the browser stores one.
    let tint: RGB?
    /// Profile picture on disk, when the browser stores one.
    let avatarURL: URL?
    /// Known web browser. Other apps that accept https links (terminals, editors) start hidden in the picker.
    var isKnownBrowser: Bool { KnownBrowsers.isBrowser(id.app) }

    var title: String { appName }
    /// "Google Chrome" → "Chrome", "Brave Browser" → "Brave": fits a picker tile.
    var shortAppName: String {
        var n = appName
        for prefix in ["Google ", "Microsoft "] where n.hasPrefix(prefix) { n.removeFirst(prefix.count) }
        for suffix in [" Browser"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        return n
    }
    var subtitle: String? { profileName }
    var fullName: String { profileName.map { "\(appName) · \($0)" } ?? appName }
}

struct RGB: Hashable, Sendable {
    let r: Double, g: Double, b: Double

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    var saturation: Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    /// Chromium stores colors as signed 32-bit ARGB integers.
    init(argb: Int) {
        let v = UInt32(truncatingIfNeeded: argb)
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Parses Firefox CSS colors like "rgb(0,73,51)" or "rgba(21, 20, 26, 1)".
    init?(css: String) {
        let nums = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        self.init(r: nums[0] / 255, g: nums[1] / 255, b: nums[2] / 255)
    }
}

/// Known browsers and where they keep profile data (relative to ~/Library/Application Support).
enum KnownBrowsers {
    static let chromium: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
        "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary": "Microsoft Edge Canary",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    static let gecko: [String: String] = [
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "org.mozilla.nightly": "Firefox",
        "app.zen-browser.zen": "zen",
        "io.gitlab.librewolf-community": "librewolf",
        "net.waterfox.waterfox": "Waterfox",
    ]

    /// Arc: profiles are opened through their Space with AppleScript, never with flags.
    static let arc = "company.thebrowser.Browser"
    static let arcDir = "Arc"

    /// Chromium-based apps where `--profile-directory` is not reliable: listed as browser only.
    static let chromiumWithoutProfileFlag: Set<String> = [
        "company.thebrowser.dia",     // Dia
        "com.operasoftware.Opera",
    ]

    /// Chromium-based apps without profile support here, but which accept --incognito.
    static let chromiumLike: Set<String> = chromiumWithoutProfileFlag.union(["com.operasoftware.Opera"])

    /// Other known browsers (no profile support here).
    static let otherBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.operasoftware.OperaGX", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser",
        "org.torproject.torbrowser", "net.mullvad.mullvadbrowser", "net.imput.helium", "ai.perplexity.comet",
        "com.sigmaos.sigmaos.macos", "one.ablaze.floorp",
    ]

    static func isBrowser(_ id: String) -> Bool {
        chromium[id] != nil || gecko[id] != nil || id == arc || chromiumLike.contains(id) || otherBrowsers.contains(id)
    }

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }
}

/// Finds installed browsers and their profiles, and keeps the list fresh.
@MainActor
@Observable
final class BrowserCatalog {
    private(set) var targets: [BrowserTarget] = []
    /// Every ID a rule may point to: each target, plus each browser without a profile.
    private(set) var availableIDs: Set<TargetID> = []
    private(set) var apps: [(bundleID: String, name: String, url: URL)] = []

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        refresh()
    }

    func target(for id: TargetID) -> BrowserTarget? {
        targets.first { $0.id == id } ?? appOnlyTarget(id)
    }

    /// A browser-only target for an app, even when the picker lists it per profile.
    func appOnlyTarget(_ id: TargetID) -> BrowserTarget? {
        guard id.profile == nil, let app = apps.first(where: { $0.bundleID == id.app }) else { return nil }
        return BrowserTarget(id: id, appName: app.name, profileName: nil, appURL: app.url, family: Self.family(of: id.app),
                             launchProfile: nil, tint: nil, avatarURL: nil)
    }

    func refresh() {
        let selfID = Bundle.main.bundleIdentifier ?? "com.sergchil.BrowserBro"
        let probe = URL(string: "https://example.com")!
        var seen: Set<String> = []
        var found: [(String, String, URL)] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != selfID, !seen.contains(id) else { continue }
            // Skip other link routers; routing to them would loop or double-prompt.
            if ["se.johnste.finicky", "com.sindresorhus.Velja", "com.choosyosx.Choosy"].contains(id) { continue }
            seen.insert(id)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found.append((id, name, url))
        }
        // Stable order: Safari first, then by name.
        found.sort { a, b in
            if a.0 == "com.apple.Safari" { return true }
            if b.0 == "com.apple.Safari" { return false }
            return a.1.localizedStandardCompare(b.1) == .orderedAscending
        }
        apps = found.map { (bundleID: $0.0, name: $0.1, url: $0.2) }

        var list: [BrowserTarget] = []
        var ids: Set<TargetID> = []
        for (id, name, url) in found {
            ids.insert(TargetID(app: id))
            let family = Self.family(of: id)
            var profiles: [BrowserTarget] = []
            if let sub = KnownBrowsers.chromium[id] {
                profiles = ChromiumProfiles.read(dataDir: KnownBrowsers.supportDir.appending(path: sub), app: id, name: name, url: url)
            } else if let sub = KnownBrowsers.gecko[id] {
                profiles = GeckoProfiles.read(dataDir: KnownBrowsers.supportDir.appending(path: sub), app: id, name: name, url: url)
            } else if id == KnownBrowsers.arc {
                profiles = ArcProfiles.read(dataDir: KnownBrowsers.supportDir.appending(path: KnownBrowsers.arcDir), app: id, name: name, url: url)
            }
            if profiles.count > 1 {
                list.append(contentsOf: profiles)
                profiles.forEach { ids.insert($0.id) }
            } else {
                // One profile (or none known): list the browser itself.
                list.append(BrowserTarget(id: TargetID(app: id), appName: name, profileName: nil, appURL: url, family: family,
                                          launchProfile: nil, tint: profiles.first?.tint, avatarURL: nil))
                profiles.forEach { ids.insert($0.id) }
            }
        }
        targets = list
        availableIDs = ids
        rewatch()
    }

    static func family(of bundleID: String) -> BrowserFamily {
        if bundleID == KnownBrowsers.arc { return .arc }
        if KnownBrowsers.chromium[bundleID] != nil || KnownBrowsers.chromiumLike.contains(bundleID) { return .chromium }
        if KnownBrowsers.gecko[bundleID] != nil { return .gecko }
        if bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.SafariTechnologyPreview") { return .safari }
        return .other
    }

    /// Watch profile folders: browsers replace their files atomically, so watch the folder, not the file.
    private func rewatch() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        var dirs: [URL] = []
        for app in apps {
            if let sub = KnownBrowsers.chromium[app.bundleID] { dirs.append(KnownBrowsers.supportDir.appending(path: sub)) }
            if let sub = KnownBrowsers.gecko[app.bundleID] {
                let base = KnownBrowsers.supportDir.appending(path: sub)
                dirs.append(base)
                dirs.append(base.appending(path: "Profile Groups"))
            }
            if app.bundleID == KnownBrowsers.arc {
                let base = KnownBrowsers.supportDir.appending(path: KnownBrowsers.arcDir)
                dirs.append(base)                              // StorableSidebar.json (Spaces)
                dirs.append(base.appending(path: "User Data")) // Local State (profiles)
            }
        }
        for dir in Set(dirs) {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let before = self.targets
            self.refresh()
            if before != self.targets { Log.app.info("Browser catalog changed: \(self.targets.count) targets") }
        }
    }
}

// MARK: - Chromium profiles

enum ChromiumProfiles {
    static func read(dataDir: URL, app: String, name: String, url: URL) -> [BrowserTarget] {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? []
        let dirs = cache.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            if a == "Default" { return true }
            if b == "Default" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return dirs.compactMap { dir in
            let info = cache[dir] ?? [:]
            let profileName = (info["name"] as? String) ?? dir
            if profileName.hasPrefix("__") { return nil } // internal profiles (e.g. Arc's system profile)
            let colorValue = (info["profile_highlight_color"] as? Int) ?? (info["default_avatar_fill_color"] as? Int)
            let picture = dataDir.appending(path: dir).appending(path: (info["gaia_picture_file_name"] as? String) ?? "Google Profile Picture.png")
            return BrowserTarget(id: TargetID(app: app, profile: dir), appName: name, profileName: profileName, appURL: url,
                                 family: .chromium, launchProfile: dir, tint: colorValue.map(RGB.init(argb:)),
                                 avatarURL: FileManager.default.fileExists(atPath: picture.path) ? picture : nil)
        }
    }
}

// MARK: - Arc profiles

enum ArcProfiles {
    /// Arc profiles from `User Data/Local State`, kept only when they have a Space (the only way to target one).
    static func read(dataDir: URL, app: String, name: String, url: URL) -> [BrowserTarget] {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "StorableSidebar.json")) else { return [] }
        let spaces = ArcSidebar.spaceIDsByProfile(json: data)
        return ChromiumProfiles.read(dataDir: dataDir.appending(path: "User Data"), app: app, name: name, url: url).compactMap { p in
            guard let dir = p.id.profile, let space = spaces[dir] else { return nil }
            return BrowserTarget(id: p.id, appName: p.appName, profileName: p.profileName, appURL: p.appURL, family: .arc,
                                 launchProfile: space, tint: p.tint, avatarURL: p.avatarURL)
        }
    }
}

// MARK: - Gecko profiles

enum GeckoProfiles {
    struct IniProfile { var name: String; var path: String; var isRelative: Bool; var storeID: String? }

    static func read(dataDir: URL, app: String, name: String, url: URL) -> [BrowserTarget] {
        guard let text = try? String(contentsOf: dataDir.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
        let ini = parseINI(text)
        var iniProfiles: [IniProfile] = []
        for (section, values) in ini where section.hasPrefix("Profile") {
            guard let path = values["Path"] else { continue }
            iniProfiles.append(IniProfile(name: values["Name"] ?? path, path: path, isRelative: values["IsRelative"] == "1", storeID: values["StoreID"]))
        }
        iniProfiles.sort { $0.path < $1.path }

        func absolute(_ path: String, relative: Bool) -> String {
            relative ? dataDir.appending(path: path).path : path
        }

        // Newer Firefox keeps user-visible profiles in "Profile Groups/<StoreID>.sqlite".
        if let storeID = iniProfiles.compactMap(\.storeID).first {
            let db = dataDir.appending(path: "Profile Groups/\(storeID).sqlite")
            let rows = readGroupProfiles(db)
            if !rows.isEmpty {
                return rows.map { row in
                    let tint = [RGB(css: row.themeFg), RGB(css: row.themeBg)].compactMap { $0 }.max { $0.saturation < $1.saturation }
                    return BrowserTarget(id: TargetID(app: app, profile: row.path), appName: name, profileName: row.name, appURL: url,
                                         family: .gecko, launchProfile: absolute(row.path, relative: !row.path.hasPrefix("/")),
                                         tint: (tint?.saturation ?? 0) > 0.25 ? tint : nil, avatarURL: nil)
                }
            }
        }
        return iniProfiles.map { p in
            BrowserTarget(id: TargetID(app: app, profile: p.path), appName: name, profileName: p.name, appURL: url,
                          family: .gecko, launchProfile: absolute(p.path, relative: p.isRelative), tint: nil, avatarURL: nil)
        }
    }

    static func parseINI(_ text: String) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                out.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !out.isEmpty {
                out[out.count - 1].1[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return out
    }

    struct GroupRow { let path: String; let name: String; let themeFg: String; let themeBg: String }

    /// Reads the profile list read-only (immutable mode never takes a lock on Firefox's database).
    static func readGroupProfiles(_ db: URL) -> [GroupRow] {
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var handle: OpaquePointer?
        let uri = "file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT path, name, themeFg, themeBg FROM Profiles ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [GroupRow] = []
        func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(GroupRow(path: col(0), name: col(1), themeFg: col(2), themeBg: col(3)))
        }
        return rows
    }
}

import AppKit
import RoutingCore

/// Demo mode for screenshots and recordings: `BROWSERBRO_DEMO=1`.
///
/// The picker and Settings show a fixed, made-up list of browsers and profiles (real app icons,
/// monogram badges, no profile pictures), so no real profile names or photos ever appear.
/// Links are recorded, never opened. Rules and settings live in `BROWSERBRO_SUPPORT_DIR`, or in a
/// temporary folder when it is not set: the real files are never touched.
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.environment["BROWSERBRO_DEMO"] == "1" }

    /// `--demo-url <url>`: pre-fills the Tester (demo mode only).
    static var testerURL: String? { isOn ? argument(after: "--demo-url") : nil }

    static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Links are recorded, never opened. The demo rules are added when the rules file is empty.
    @MainActor
    static func prepare(_ model: AppModel) {
        model.launchOverride = { url, target, options in
            let line = "Demo: would open \(url.absoluteString) in \(target.fullName)\(options.privateWindow ? " (private)" : "")"
            Log.app.notice("\(line, privacy: .public)")
            print(line)
            fflush(stdout)
        }
        if model.rules.file.rules.isEmpty { model.rules.save(rules()) }
    }

    // Muted tints: they color the monogram badge and the picker lens.
    private static let slate = RGB(r: 0.33, g: 0.42, b: 0.58)
    private static let sage = RGB(r: 0.36, g: 0.55, b: 0.45)
    private static let sand = RGB(r: 0.70, g: 0.52, b: 0.33)

    static let safari = TargetID(app: "com.apple.Safari")
    static let chromeWork = TargetID(app: "com.google.Chrome", profile: "Profile 1")
    static let chromePersonal = TargetID(app: "com.google.Chrome", profile: "Profile 2")
    static let firefoxSide = TargetID(app: "org.mozilla.firefox", profile: "demo.side-project")
    static let arcWork = TargetID(app: KnownBrowsers.arc, profile: "Profile 1")
    static let brave = TargetID(app: "com.brave.Browser")

    /// Safari; Chrome · Work; Chrome · Personal; Firefox · Side project; Arc · Work; Brave.
    @MainActor
    static func targets() -> [BrowserTarget] {
        func make(_ id: TargetID, _ name: String, _ profile: String?, _ tint: RGB?) -> BrowserTarget {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.app)
                ?? URL(fileURLWithPath: "/Applications/Safari.app")
            return BrowserTarget(id: id, appName: name, profileName: profile, appURL: url, family: BrowserCatalog.family(of: id.app),
                                 launchProfile: id.profile, tint: tint, avatarURL: nil)
        }
        return [
            make(safari, "Safari", nil, nil),
            make(chromeWork, "Google Chrome", "Work", slate),
            make(chromePersonal, "Google Chrome", "Personal", sage),
            make(firefoxSide, "Firefox", "Side project", sand),
            make(arcWork, "Arc", "Work", slate),
            make(brave, "Brave Browser", nil, nil),
        ]
    }

    /// Example rules shown in the screenshots.
    static func rules() -> RulesFile {
        var f = RulesFile()
        f.rules = [
            Rule(name: "Work tools", mode: .any,
                 conditions: [Condition(.wildcard, "*.acme.com"), Condition(.domain, "linear.app")], target: chromeWork),
            Rule(name: "Slack links", mode: .any, conditions: [Condition(.sourceApp, "com.tinyspeck.slackmacgap")], target: arcWork),
            Rule(name: "Videos", mode: .any, conditions: [Condition(.domain, "youtube.com")], target: safari),
        ]
        return f
    }
}

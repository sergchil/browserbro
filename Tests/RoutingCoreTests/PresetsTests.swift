import Foundation
import Testing
@testable import RoutingCore

@Suite("Presets")
struct PresetTests {
    static let work = TargetID(app: "com.google.Chrome", profile: "Profile 1")
    static let personal = TargetID(app: "com.google.Chrome", profile: "Profile 2")

    func pack(_ id: String) throws -> PresetPack { try #require(Presets.pack(id: id)) }

    /// Every pack, Work packs → work profile, Personal packs → personal profile.
    func allPacks(codeFilter: String = "") -> RulesFile {
        let choices = Presets.all.map { p in
            PresetChoice(pack: p, target: p.side == .work ? Self.work : Self.personal, pathFilter: p.takesPathFilter ? codeFilter : "")
        }
        return Presets.apply(choices, to: RulesFile())
    }

    func winner(_ file: RulesFile, _ r: RouteRequest) -> String? {
        guard case .open(_, _, let id?) = RoutingEngine.decide(r, rules: CompiledRules(file)) else { return nil }
        return file.rules.first { $0.id == id }?.preset
    }

    @Test("pack IDs are unique and every pack has conditions")
    func table() {
        #expect(Set(Presets.all.map(\.id)).count == Presets.all.count)
        for p in Presets.all { #expect(!p.conditions.isEmpty, "\(p.id)") }
        #expect(Presets.all.first?.matchesSourceApp == true)
    }

    @Test("all packs compile without warnings")
    func noWarnings() {
        let f = allPacks(codeFilter: "acme")
        #expect(CompiledRules(f).issues.isEmpty)
        #expect(ConflictAnalyzer.analyze(f).isEmpty, "\(ConflictAnalyzer.analyze(f).map(\.message))")
    }

    @Test("each pack routes its sample links", arguments: [
        ("https://acme.atlassian.net/browse/X-1", nil, "work-tools"),
        ("https://jira.acme.com/browse/X-1", nil, "work-tools"),
        ("https://confluence.acme.io/wiki", nil, "work-tools"),
        ("https://linear.app/acme/issue/A-1", nil, "work-tools"),
        ("https://www.notion.so/page", nil, "work-tools"),
        ("https://acme.slack.com/archives/C1", nil, "work-tools"),
        ("https://www.figma.com/file/1", nil, "work-tools"),
        ("https://us02web.zoom.us/j/123", nil, "meetings"),
        ("https://meet.google.com/abc-defg-hij", nil, "meetings"),
        ("https://teams.microsoft.com/l/meetup-join/x", nil, "meetings"),
        ("https://acme.webex.com/meet/x", nil, "meetings"),
        ("https://github.com/anyone/x", nil, "code"),
        ("https://gitlab.com/group/x", nil, "code"),
        ("https://youtu.be/abc", nil, "media"),
        ("https://www.youtube.com/watch?v=1", nil, "media"),
        ("https://open.spotify.com/track/1", nil, "media"),
        ("https://music.apple.com/album/1", nil, "media"),
        ("https://x.com/someone", nil, "social"),
        ("https://old.reddit.com/r/swift", nil, "social"),
        ("https://www.youtube.com/watch?v=1", "com.tinyspeck.slackmacgap", "work-apps"),
        ("https://example.com/", "com.microsoft.Outlook", "work-apps"),
        ("https://example.com/", "us.zoom.xos", "work-apps"),
        ("https://example.com/", nil, nil),
        ("https://notjira.acme.com/", nil, nil),
        ("https://www.linkedin.com/in/someone", nil, nil),
    ] as [(String, String?, String?)])
    func routes(url: String, from: String?, expected: String?) {
        #expect(winner(allPacks(), req(url, from: from)) == expected)
    }

    @Test("From work apps beats Media for a YouTube link from Slack")
    func sourceAppFirst() throws {
        let f = allPacks()
        #expect(f.rules.first?.preset == "work-apps")
        #expect(f.rules.map(\.preset) == Presets.all.map(\.id))
        let d = RoutingEngine.decide(req("https://youtu.be/abc", from: "com.tinyspeck.slackmacgap"), rules: CompiledRules(f))
        #expect(d == .open(Self.work, TargetOptions(), ruleID: f.rules[0].id))
        #expect(f.rules[0].name == "From work apps (preset)")
    }

    @Test("Code org filter limits the rule to that org")
    func codeFilter() {
        let f = allPacks(codeFilter: "acme")
        #expect(winner(f, req("https://github.com/acme/x")) == "code")
        #expect(winner(f, req("https://github.com/acme")) == "code")
        #expect(winner(f, req("https://gitlab.com/acme/sub/project/-/merge_requests/1")) == "code")
        #expect(winner(f, req("https://github.com/other/x")) == nil)
        #expect(winner(f, req("https://github.com/acme-other/x")) == nil)
    }

    @Test("path filter input is cleaned", arguments: [
        ("acme", "acme"), (" /acme/ ", "acme"), ("acme/*", "acme"), ("github.com/acme/*", "acme"),
        ("https://github.com/acme/**", "acme"), ("group/sub", "group/sub"), ("", ""), ("github.com", ""),
    ])
    func cleanFilter(raw: String, expected: String) {
        #expect(Presets.cleanPathFilter(raw) == expected)
    }

    @Test("the filter can be read back from the rule")
    func filterRoundTrip() throws {
        let code = try pack("code")
        #expect(Presets.pathFilter(of: Presets.rule(for: PresetChoice(pack: code, target: Self.work, pathFilter: "acme/*"))) == "acme")
        #expect(Presets.pathFilter(of: Presets.rule(for: PresetChoice(pack: code, target: Self.work))) == "")
    }

    @Test("adding a pack twice updates the rule instead of adding a second one")
    func noDuplicates() throws {
        let media = try pack("media")
        let user = Rule(name: "mine", conditions: [Condition(.domain, "example.com")], target: Self.work)
        var f = Presets.apply([PresetChoice(pack: media, target: Self.personal)], to: RulesFile(rules: [user]))
        #expect(f.rules.count == 2 && f.rules[1].preset == "media")
        let id = f.rules[1].id
        // The user renames and disables it, then adds the pack again with another target.
        f.rules[1].name = "Videos"
        f.rules[1].enabled = false
        f.rules[1].options.openInBackground = true
        f = Presets.apply([PresetChoice(pack: media, target: Self.work), PresetChoice(pack: media, target: Self.work)], to: f)
        #expect(f.rules.count == 2)
        #expect(f.rules[1].id == id && f.rules[1].name == "Videos" && f.rules[1].enabled)
        #expect(f.rules[1].target == Self.work && f.rules[1].options.openInBackground)
        #expect(Presets.existingRule(for: media, in: f)?.id == id)
    }

    @Test("a new source-app pack goes above existing rules; site packs go below")
    func insertOrder() throws {
        let user = Rule(name: "mine", conditions: [Condition(.domain, "example.com")], target: Self.work)
        let f = Presets.apply([PresetChoice(pack: try pack("social"), target: Self.personal),
                               PresetChoice(pack: try pack("work-apps"), target: Self.work)], to: RulesFile(rules: [user]))
        #expect(f.rules.map(\.name) == ["From work apps (preset)", "mine", "Social (preset)"])
    }

    @Test("preset ID survives the rules file; user rules don't get one")
    func codec() throws {
        let f = allPacks()
        let back = try RulesCodec.decode(RulesCodec.encode(f))
        #expect(back == f)
        let plain = String(decoding: RulesCodec.encode(RulesFile(rules: [Rule(name: "x", conditions: [], target: Self.work)])), as: UTF8.self)
        #expect(!plain.contains("preset"))
    }

    @Test("target guess uses Work / Personal words in profile labels")
    func guess() {
        let c: [(id: TargetID, label: String)] = [
            (TargetID(app: "com.apple.Safari"), ""),
            (TargetID(app: "a", profile: "1"), "Networking"),
            (Self.work, "Work"),
            (Self.personal, "Personal"),
            (TargetID(app: "b", profile: "2"), "Work 2"),
        ]
        #expect(Presets.guessTarget(for: .work, among: c) == Self.work)
        #expect(Presets.guessTarget(for: .personal, among: c) == Self.personal)
        #expect(Presets.guessTarget(for: .work, among: [(TargetID(app: "a"), "Side project")]) == nil)
    }
}

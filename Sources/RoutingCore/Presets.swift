import Foundation

// MARK: - Preset rule packs

/// Which kind of profile a pack suits. Used only to guess a target; the user always confirms it.
public enum PresetSide: String, Sendable {
    case work
    case personal
}

/// A ready-made group of conditions. Added, it becomes one normal rule the user can edit.
public struct PresetPack: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let side: PresetSide
    /// Short list of what it matches, shown in the sheet.
    public let summary: String
    public let conditions: [Condition]
    /// Code pack: an optional org or path, e.g. "acme" → only github.com/acme/….
    public let takesPathFilter: Bool

    public var ruleName: String { "\(name) (preset)" }
    /// Matches the app the link came from, not the site. Such packs go first in the rules list.
    public var matchesSourceApp: Bool { conditions.allSatisfy { $0.kind == .sourceApp } }
}

/// One pack the user ticked, with the target they picked.
public struct PresetChoice: Hashable, Sendable {
    public var pack: PresetPack
    public var target: TargetID
    public var pathFilter: String

    public init(pack: PresetPack, target: TargetID, pathFilter: String = "") {
        self.pack = pack
        self.target = target
        self.pathFilter = pathFilter
    }
}

public enum Presets {
    static let codeHosts = ["github.com", "gitlab.com", "bitbucket.org"]

    /// In rules-list order: the source-app pack first (the app is a stronger signal than the site).
    public static let all: [PresetPack] = [
        PresetPack(id: "work-apps", name: "From work apps", side: .work,
                   summary: "Links clicked in Slack, Teams, Outlook, Zoom",
                   conditions: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.Outlook", "us.zoom.xos"]
                       .map { Condition(.sourceApp, $0) },
                   takesPathFilter: false),
        PresetPack(id: "work-tools", name: "Work tools", side: .work,
                   summary: "Jira, Confluence, Linear, Notion, Miro, Figma, Slack, Asana, ClickUp, monday.com, Trello",
                   conditions: [
                       Condition(.domain, "atlassian.net"),
                       Condition(.wildcard, "jira.**"),
                       Condition(.wildcard, "confluence.**"),
                       Condition(.domain, "linear.app"),
                       Condition(.domain, "notion.so"),
                       Condition(.domain, "notion.site"),
                       Condition(.domain, "miro.com"),
                       Condition(.domain, "figma.com"),
                       Condition(.domain, "slack.com"),
                       Condition(.domain, "asana.com"),
                       Condition(.domain, "clickup.com"),
                       Condition(.domain, "monday.com"),
                       Condition(.domain, "trello.com"),
                   ],
                   takesPathFilter: false),
        PresetPack(id: "meetings", name: "Meetings", side: .work,
                   summary: "Zoom, Google Meet, Microsoft Teams, Webex",
                   conditions: ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com", "webex.com"]
                       .map { Condition(.domain, $0) },
                   takesPathFilter: false),
        PresetPack(id: "code", name: "Code", side: .work,
                   summary: "GitHub, GitLab, Bitbucket",
                   conditions: codeHosts.map { Condition(.domain, $0) },
                   takesPathFilter: true),
        PresetPack(id: "media", name: "Media", side: .personal,
                   summary: "YouTube, Spotify, Netflix, Twitch, Apple Music",
                   conditions: ["youtube.com", "youtu.be", "spotify.com", "netflix.com", "twitch.tv", "music.apple.com"]
                       .map { Condition(.domain, $0) },
                   takesPathFilter: false),
        PresetPack(id: "social", name: "Social", side: .personal,
                   summary: "X, Instagram, Reddit, Facebook, TikTok",
                   conditions: ["x.com", "twitter.com", "instagram.com", "reddit.com", "facebook.com", "tiktok.com"]
                       .map { Condition(.domain, $0) },
                   takesPathFilter: false),
    ]

    public static func pack(id: String) -> PresetPack? { all.first { $0.id == id } }

    /// The rule made from this pack earlier, if any (found by its preset ID, so renaming it is fine).
    public static func existingRule(for pack: PresetPack, in file: RulesFile) -> Rule? {
        file.rules.first { $0.preset == pack.id }
    }

    // MARK: Path filter (Code pack)

    /// "https://github.com/acme/*", "/acme/", "acme" → "acme". Empty = the whole site.
    public static func cleanPathFilter(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = v.range(of: "://") { v = String(v[r.upperBound...]) }
        for host in codeHosts + codeHosts.map({ "www." + $0 }) {
            if v.lowercased() == host { v = "" }
            if v.lowercased().hasPrefix(host + "/") { v = String(v.dropFirst(host.count + 1)) }
        }
        while v.hasSuffix("*") || v.hasSuffix("/") { v.removeLast() }
        while v.hasPrefix("/") { v.removeFirst() }
        return v
    }

    /// The org/path filter of a Code rule made by `rule(for:)`, or "" for the whole site.
    public static func pathFilter(of rule: Rule) -> String {
        for c in rule.conditions where c.kind == .wildcard {
            for host in codeHosts where c.value.hasPrefix(host + "/") {
                var v = String(c.value.dropFirst(host.count + 1))
                if v.hasSuffix("/**") { v.removeLast(3) }
                return v
            }
        }
        return ""
    }

    // MARK: Pack → rule

    public static func conditions(for pack: PresetPack, pathFilter: String = "") -> [Condition] {
        let filter = pack.takesPathFilter ? cleanPathFilter(pathFilter) : ""
        guard !filter.isEmpty else { return pack.conditions }
        // "github.com/acme" and "github.com/acme/…", but not "github.com/acme-other".
        return codeHosts.flatMap { [Condition(.wildcard, "\($0)/\(filter)"), Condition(.wildcard, "\($0)/\(filter)/**")] }
    }

    public static func rule(for choice: PresetChoice) -> Rule {
        Rule(name: choice.pack.ruleName, mode: .any, conditions: conditions(for: choice.pack, pathFilter: choice.pathFilter),
             target: choice.target, preset: choice.pack.id)
    }

    /// Adds the chosen packs as rules. A pack that is already in the file is updated in place
    /// (conditions, target, enabled), so adding a pack twice never makes a second rule.
    /// New source-app packs go to the top of the list; new site packs go to the end, in pack order.
    public static func apply(_ choices: [PresetChoice], to file: RulesFile) -> RulesFile {
        var f = file
        var latest: [String: PresetChoice] = [:]
        for c in choices { latest[c.pack.id] = c }
        let ordered = all.compactMap { latest[$0.id] }
        var topInsert = 0
        for choice in ordered {
            var new = rule(for: choice)
            if let i = f.rules.firstIndex(where: { $0.preset == choice.pack.id }) {
                let old = f.rules[i]
                new.id = old.id
                new.name = old.name
                new.options = old.options
                f.rules[i] = new
            } else if choice.pack.matchesSourceApp {
                f.rules.insert(new, at: topInsert)
                topInsert += 1
            } else {
                f.rules.append(new)
            }
        }
        return f
    }

    // MARK: Target guess

    static let sideWords: [PresetSide: Set<String>] = [
        .work: ["work", "job", "office"],
        .personal: ["personal", "private", "home"],
    ]

    /// First candidate whose label (profile name or the user's own label) has a word like "Work"
    /// or "Personal". nil = no good guess: the user must choose.
    public static func guessTarget(for side: PresetSide, among candidates: [(id: TargetID, label: String)]) -> TargetID? {
        let words = sideWords[side] ?? []
        return candidates.first { c in
            c.label.lowercased().split { !$0.isLetter }.contains { words.contains(String($0)) }
        }?.id
    }
}

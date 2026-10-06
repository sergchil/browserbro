import Foundation

// MARK: - Modifier keys

/// Modifier keys held when a link arrives.
public struct ModifierSet: OptionSet, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let option = ModifierSet(rawValue: 1 << 0)
    public static let shift = ModifierSet(rawValue: 1 << 1)
    public static let command = ModifierSet(rawValue: 1 << 2)
    public static let control = ModifierSet(rawValue: 1 << 3)

    public static let all: [(ModifierSet, String, String)] = [
        (.control, "control", "⌃"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘"),
    ]

    /// Parses "option", "option+shift", "⌥⇧". Empty string = no modifiers.
    public init?(string: String) {
        var result: ModifierSet = []
        let parts = string.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" || $0 == "," })
        for part in parts {
            if let match = ModifierSet.all.first(where: { $0.1 == part || $0.2 == part || (part == "alt" && $0.1 == "option") || (part == "cmd" && $0.1 == "command") || (part == "ctrl" && $0.1 == "control") }) {
                result.insert(match.0)
            } else {
                // Accept symbol strings like "⌥⇧".
                var symbols: ModifierSet = []
                for ch in part {
                    guard let m = ModifierSet.all.first(where: { $0.2 == String(ch) }) else { return nil }
                    symbols.insert(m.0)
                }
                result.formUnion(symbols)
            }
        }
        self = result
    }

    public var name: String {
        ModifierSet.all.filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }

    public var symbols: String {
        ModifierSet.all.filter { contains($0.0) }.map(\.2).joined()
    }

    public var description: String { isEmpty ? "none" : symbols }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = ModifierSet(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown modifier '\(s)'. Use option, shift, command, control.")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

// MARK: - Targets

/// A browser, or a browser + profile. Stable identity used by rules.
public struct TargetID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Bundle identifier of the browser app.
    public var app: String
    /// Profile key: Chromium profile directory ("Profile 1") or Gecko profile path. nil = browser's own choice.
    public var profile: String?

    public init(app: String, profile: String? = nil) {
        self.app = app
        self.profile = (profile?.isEmpty ?? true) ? nil : profile
    }

    public var description: String { profile.map { "\(app)#\($0)" } ?? app }

    enum CodingKeys: String, CodingKey { case app, profile }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(app: try c.decode(String.self, forKey: .app),
                  profile: try c.decodeIfPresent(String.self, forKey: .profile))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

public struct TargetOptions: Hashable, Codable, Sendable {
    public var privateWindow: Bool
    public var openInBackground: Bool

    public init(privateWindow: Bool = false, openInBackground: Bool = false) {
        self.privateWindow = privateWindow
        self.openInBackground = openInBackground
    }

    enum CodingKeys: String, CodingKey { case privateWindow, openInBackground }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privateWindow = try c.decodeIfPresent(Bool.self, forKey: .privateWindow) ?? false
        openInBackground = try c.decodeIfPresent(Bool.self, forKey: .openInBackground) ?? false
    }
}

// MARK: - Conditions

public enum ConditionKind: String, Codable, CaseIterable, Sendable {
    case domain
    case hostIs
    case pathPrefix
    case urlContains
    case wildcard
    case regex
    case sourceApp
    case modifier

    public var title: String {
        switch self {
        case .domain: "Domain"
        case .hostIs: "Host is"
        case .pathPrefix: "Path starts with"
        case .urlContains: "URL contains"
        case .wildcard: "Wildcard"
        case .regex: "Regex"
        case .sourceApp: "Source app"
        case .modifier: "Modifier held"
        }
    }

    public var placeholder: String {
        switch self {
        case .domain: "example.com"
        case .hostIs: "www.example.com"
        case .pathPrefix: "/work/"
        case .urlContains: "project=work"
        case .wildcard: "*.example.com/**"
        case .regex: "^https://(www\\.)?example\\.com/"
        case .sourceApp: "com.tinyspeck.slackmacgap"
        case .modifier: "shift"
        }
    }

    public var help: String {
        switch self {
        case .domain: "The host or any subdomain. example.com matches docs.example.com, not notexample.com. Not case-sensitive."
        case .hostIs: "The exact host, without port or path. Not case-sensitive."
        case .pathPrefix: "The URL path starts with this text. Case-sensitive."
        case .urlContains: "This text appears anywhere in the full URL. Not case-sensitive."
        case .wildcard: "Pattern against host + path + query (no scheme). * = one host label or path segment, ** = anything."
        case .regex: "Regular expression against the full URL. Case-sensitive; add (?i) to ignore case."
        case .sourceApp: "Bundle ID of the app where you clicked the link."
        case .modifier: "These keys are held when the link arrives."
        }
    }
}

public struct Condition: Hashable, Codable, Sendable {
    public var kind: ConditionKind
    public var value: String
    public var negate: Bool

    public init(_ kind: ConditionKind, _ value: String, negate: Bool = false) {
        self.kind = kind
        self.value = value
        self.negate = negate
    }

    enum CodingKeys: String, CodingKey { case type, value, negate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .type)
        guard let kind = ConditionKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown condition type '\(raw)'. Valid: \(ConditionKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self.kind = kind
        self.value = try c.decode(String.self, forKey: .value)
        self.negate = try c.decodeIfPresent(Bool.self, forKey: .negate) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .type)
        try c.encode(value, forKey: .value)
        if negate { try c.encode(true, forKey: .negate) }
    }

    public var summary: String {
        let shown = kind == .modifier ? (ModifierSet(string: value)?.symbols ?? value) : value
        return "\(negate ? "NOT " : "")\(kind.title.lowercased()) \(shown)"
    }
}

public enum MatchMode: String, Codable, CaseIterable, Sendable {
    case all
    case any
}

// MARK: - Rules

public struct Rule: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var mode: MatchMode
    public var conditions: [Condition]
    public var target: TargetID
    public var options: TargetOptions
    /// ID of the preset pack this rule was made from (see `Presets`). nil = a rule the user made.
    /// Only used to find the rule again when the pack is added a second time; matching ignores it.
    public var preset: String?

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, mode: MatchMode = .any,
                conditions: [Condition], target: TargetID, options: TargetOptions = TargetOptions(), preset: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.mode = mode
        self.conditions = conditions
        self.target = target
        self.options = options
        self.preset = preset
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, match, target, options, preset }
    enum MatchKeys: String, CodingKey { case mode, conditions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled rule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let m = try c.nestedContainer(keyedBy: MatchKeys.self, forKey: .match)
        mode = try m.decodeIfPresent(MatchMode.self, forKey: .mode) ?? .any
        conditions = try m.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        target = try c.decode(TargetID.self, forKey: .target)
        options = try c.decodeIfPresent(TargetOptions.self, forKey: .options) ?? TargetOptions()
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        var m = c.nestedContainer(keyedBy: MatchKeys.self, forKey: .match)
        try m.encode(mode, forKey: .mode)
        try m.encode(conditions, forKey: .conditions)
        try c.encode(target, forKey: .target)
        if options != TargetOptions() { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(preset, forKey: .preset)
    }
}

public enum FallbackKind: String, Codable, CaseIterable, Sendable {
    /// Show the picker when no rule matches.
    case picker
    /// Open in `defaultTarget` when no rule matches.
    case defaultTarget
}

/// The whole rules file (`rules.json`).
public struct RulesFile: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var fallback: FallbackKind
    public var defaultTarget: TargetID?
    /// Holding these keys forces the picker, even when a rule matches. Empty = feature off.
    public var pickerOverrideModifier: ModifierSet
    public var rules: [Rule]

    public init(schemaVersion: Int = RulesFile.currentSchemaVersion, fallback: FallbackKind = .picker,
                defaultTarget: TargetID? = nil, pickerOverrideModifier: ModifierSet = .option, rules: [Rule] = []) {
        self.schemaVersion = schemaVersion
        self.fallback = fallback
        self.defaultTarget = defaultTarget
        self.pickerOverrideModifier = pickerOverrideModifier
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, fallback, defaultTarget, pickerOverrideModifier, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        fallback = try c.decodeIfPresent(FallbackKind.self, forKey: .fallback) ?? .picker
        defaultTarget = try c.decodeIfPresent(TargetID.self, forKey: .defaultTarget)
        pickerOverrideModifier = try c.decodeIfPresent(ModifierSet.self, forKey: .pickerOverrideModifier) ?? .option
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }
}

// MARK: - Requests and decisions

public struct RouteRequest: Hashable, Sendable {
    public var url: URL
    /// Bundle ID of the app where the link was clicked. nil = unknown.
    public var sourceBundleID: String?
    public var modifiers: ModifierSet

    public init(url: URL, sourceBundleID: String? = nil, modifiers: ModifierSet = []) {
        self.url = url
        self.sourceBundleID = sourceBundleID
        self.modifiers = modifiers
    }
}

public enum PickerReason: Hashable, Sendable {
    case noMatch
    case override
    case brokenTarget(ruleID: UUID)
    case noDefaultTarget
}

public enum Decision: Hashable, Sendable {
    case open(TargetID, TargetOptions, ruleID: UUID?)
    case showPicker(PickerReason)
}

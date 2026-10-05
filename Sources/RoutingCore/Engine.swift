import Foundation

// MARK: - Host helpers

public enum HostNormalizer {
    /// Lower-cases, removes a trailing dot, and converts Unicode labels to punycode ("xn--…").
    public static func normalize(_ host: String) -> String {
        var h = (host.removingPercentEncoding ?? host).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard h.unicodeScalars.contains(where: { !$0.isASCII }) else { return h }
        return h.split(separator: ".", omittingEmptySubsequences: false).map { label in
            label.unicodeScalars.allSatisfy(\.isASCII) ? String(label) : "xn--" + Punycode.encode(String(label))
        }.joined(separator: ".")
    }

    /// Normalized host of a URL ("" when the URL has no host).
    public static func host(of url: URL) -> String {
        normalize(url.host(percentEncoded: true) ?? "")
    }

    /// Strips a scheme, path and leading "*." or "." from what a user typed as a domain.
    public static func cleanDomainInput(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = v.range(of: "://") { v = String(v[range.upperBound...]) }
        if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]) }
        if let colon = v.firstIndex(of: ":") { v = String(v[..<colon]) }
        while v.hasPrefix("*.") { v.removeFirst(2) }
        while v.hasPrefix(".") { v.removeFirst() }
        return normalize(v)
    }

    /// "www.linear.app" → "linear.app". Used when the picker saves "always open this site here".
    public static func siteDomain(of url: URL) -> String {
        var h = host(of: url)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    public static func domainMatches(host: String, domain: String) -> Bool {
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}

// MARK: - Wildcards

public enum Wildcard {
    /// Converts a wildcard pattern to an anchored regex.
    /// `*` = one host label or path segment, `**` = anything.
    public static func regexPattern(_ pattern: String) -> String {
        var out = "^"
        var chars = Array(pattern)
        // A scheme-less pattern with an explicit "*://" or "https://" is matched against the full URL.
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out += ".*"
                    i += 2
                    continue
                }
                out += "[^./?#]*"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        chars.removeAll()
        return out + "$"
    }

    /// The text a wildcard pattern is compared with.
    static func subject(for url: URL, pattern: String) -> String {
        if pattern.contains("://") {
            return url.absoluteString
        }
        let host = HostNormalizer.host(of: url)
        let hostPart = pattern.split(separator: "/", maxSplits: 1).first.map(String.init) ?? pattern
        var s = host
        if hostPart.contains(":"), let port = url.port { s += ":\(port)" }
        guard pattern.contains("/") || pattern.contains("?") else { return s }
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        s += path
        if pattern.contains("?"), let q = url.query(percentEncoded: true) { s += "?" + q }
        return s
    }
}

// MARK: - Compiled rules

enum CompiledCondition: Sendable {
    case domain(String)
    case hostIs(String)
    case pathPrefix(String)
    case urlContains(String)
    case regex(NSRegularExpressionBox, wildcard: String?)
    case sourceApp(String)
    case modifier(ModifierSet)
    case invalid(String)
}

/// NSRegularExpression is thread-safe for matching; this box lets it cross concurrency domains.
final class NSRegularExpressionBox: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ regex: NSRegularExpression) { self.regex = regex }
}

public struct ConditionIssue: Hashable, Sendable {
    public let ruleID: UUID
    public let conditionIndex: Int
    public let message: String
}

extension Condition {
    func compile() -> CompiledCondition {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .domain:
            let d = HostNormalizer.cleanDomainInput(v)
            return d.isEmpty ? .invalid("Domain is empty.") : .domain(d)
        case .hostIs:
            let h = HostNormalizer.cleanDomainInput(v)
            return h.isEmpty ? .invalid("Host is empty.") : .hostIs(h)
        case .pathPrefix:
            guard !v.isEmpty else { return .invalid("Path is empty.") }
            return .pathPrefix(v.hasPrefix("/") ? v : "/" + v)
        case .urlContains:
            return v.isEmpty ? .invalid("Text is empty.") : .urlContains(v.lowercased())
        case .wildcard:
            guard !v.isEmpty else { return .invalid("Pattern is empty.") }
            let pattern = v.contains("://") ? v : v.lowercased()
            do {
                let re = try NSRegularExpression(pattern: Wildcard.regexPattern(pattern), options: v.contains("://") ? [] : [.caseInsensitive])
                return .regex(NSRegularExpressionBox(re), wildcard: pattern)
            } catch {
                return .invalid("Pattern can't be compiled.")
            }
        case .regex:
            guard !v.isEmpty else { return .invalid("Regex is empty.") }
            do {
                return .regex(NSRegularExpressionBox(try NSRegularExpression(pattern: v)), wildcard: nil)
            } catch {
                return .invalid("Regex doesn't compile: \((error as NSError).localizedDescription)")
            }
        case .sourceApp:
            return v.isEmpty ? .invalid("Source app is empty.") : .sourceApp(v.lowercased())
        case .modifier:
            guard let m = ModifierSet(string: v), !m.isEmpty else {
                return .invalid("Unknown modifier '\(v)'. Use option, shift, command, control.")
            }
            return .modifier(m)
        }
    }
}

extension CompiledCondition {
    func evaluate(_ req: RouteRequest, host: String) -> Bool {
        switch self {
        case .domain(let d):
            return HostNormalizer.domainMatches(host: host, domain: d)
        case .hostIs(let h):
            return host == h
        case .pathPrefix(let p):
            let path = req.url.path(percentEncoded: false)
            return (path.isEmpty ? "/" : path).hasPrefix(p)
        case .urlContains(let s):
            return req.url.absoluteString.lowercased().contains(s)
        case .regex(let box, let wildcard):
            let subject = wildcard.map { Wildcard.subject(for: req.url, pattern: $0) } ?? req.url.absoluteString
            let range = NSRange(subject.startIndex..., in: subject)
            return box.regex.firstMatch(in: subject, options: [], range: range) != nil
        case .sourceApp(let id):
            return req.sourceBundleID?.lowercased() == id
        case .modifier(let m):
            return req.modifiers.isSuperset(of: m)
        case .invalid:
            return false
        }
    }
}

struct CompiledRule: Sendable {
    let rule: Rule
    let conditions: [(CompiledCondition, negate: Bool)]
}

/// Rules prepared for fast matching. Build once per rules change.
public struct CompiledRules: Sendable {
    public let file: RulesFile
    let rules: [CompiledRule]
    public let issues: [ConditionIssue]

    public init(_ file: RulesFile) {
        self.file = file
        var issues: [ConditionIssue] = []
        rules = file.rules.map { rule in
            let compiled = rule.conditions.enumerated().map { idx, cond -> (CompiledCondition, negate: Bool) in
                let c = cond.compile()
                if case .invalid(let msg) = c {
                    issues.append(ConditionIssue(ruleID: rule.id, conditionIndex: idx, message: msg))
                }
                return (c, cond.negate)
            }
            return CompiledRule(rule: rule, conditions: compiled)
        }
        self.issues = issues
    }
}

// MARK: - Trace

public struct ConditionTrace: Hashable, Sendable {
    public let condition: Condition
    public let passed: Bool
    public let invalidReason: String?
}

public struct RuleTrace: Hashable, Sendable, Identifiable {
    public var id: UUID { ruleID }
    public let ruleID: UUID
    public let index: Int
    public let name: String
    public let enabled: Bool
    public let matched: Bool
    public let targetAvailable: Bool
    public let conditions: [ConditionTrace]

    /// One-line reason, e.g. "domain linear.app ≠ docs.google.com".
    public var explanation: String {
        if !enabled { return "disabled" }
        if conditions.isEmpty { return matched ? "no conditions: matches every link" : "no conditions" }
        if matched {
            let passing = conditions.filter(\.passed).map(\.condition.summary)
            return (targetAvailable ? "" : "matched, but target is missing: ") + passing.joined(separator: ", ")
        }
        let failing = conditions.filter { !$0.passed }.map { c in
            c.invalidReason.map { "\(c.condition.summary) (invalid: \($0))" } ?? c.condition.summary
        }
        return "failed: " + failing.joined(separator: ", ")
    }
}

public struct Trace: Hashable, Sendable {
    public let request: RouteRequest
    public let overrideHeld: Bool
    public let rules: [RuleTrace]
    public let decision: Decision
    public let winningRuleID: UUID?
}

// MARK: - Router

public enum RoutingEngine {
    /// Decides where a link goes. Pure and synchronous.
    /// - Parameter available: targets that exist on this Mac. nil = assume every target exists (CLI / tests).
    public static func decide(_ req: RouteRequest, rules: CompiledRules, available: Set<TargetID>? = nil) -> Decision {
        let file = rules.file
        if !file.pickerOverrideModifier.isEmpty, req.modifiers.isSuperset(of: file.pickerOverrideModifier) {
            return .showPicker(.override)
        }
        let host = HostNormalizer.host(of: req.url)
        for r in rules.rules where r.rule.enabled {
            if matches(r, req, host: host) {
                if let available, !isAvailable(r.rule.target, in: available) {
                    return .showPicker(.brokenTarget(ruleID: r.rule.id))
                }
                return .open(r.rule.target, r.rule.options, ruleID: r.rule.id)
            }
        }
        switch file.fallback {
        case .picker:
            return .showPicker(.noMatch)
        case .defaultTarget:
            guard let t = file.defaultTarget, available.map({ isAvailable(t, in: $0) }) ?? true else {
                return .showPicker(.noDefaultTarget)
            }
            return .open(t, TargetOptions(), ruleID: nil)
        }
    }

    /// Same as `decide`, plus a per-rule explanation. Used by the tester and the CLI.
    public static func trace(_ req: RouteRequest, rules: CompiledRules, available: Set<TargetID>? = nil) -> Trace {
        let decision = decide(req, rules: rules, available: available)
        let host = HostNormalizer.host(of: req.url)
        let overrideHeld = !rules.file.pickerOverrideModifier.isEmpty && req.modifiers.isSuperset(of: rules.file.pickerOverrideModifier)
        let traces = rules.rules.enumerated().map { idx, r in
            let conds = zip(r.rule.conditions, r.conditions).map { cond, compiled in
                let raw = compiled.0.evaluate(req, host: host)
                var invalid: String? = nil
                if case .invalid(let msg) = compiled.0 { invalid = msg }
                return ConditionTrace(condition: cond, passed: invalid == nil && (compiled.negate ? !raw : raw), invalidReason: invalid)
            }
            return RuleTrace(ruleID: r.rule.id, index: idx + 1, name: r.rule.name, enabled: r.rule.enabled,
                             matched: r.rule.enabled && matches(r, req, host: host),
                             targetAvailable: available.map { isAvailable(r.rule.target, in: $0) } ?? true,
                             conditions: conds)
        }
        var winner: UUID? = nil
        switch decision {
        case .open(_, _, let id): winner = id
        case .showPicker(.brokenTarget(let id)): winner = id
        default: break
        }
        return Trace(request: req, overrideHeld: overrideHeld, rules: traces, decision: decision, winningRuleID: winner)
    }

    /// Does this single rule match? (Used by the editor's mini tester.)
    public static func ruleMatches(_ rule: Rule, _ req: RouteRequest) -> Bool {
        let compiled = CompiledRule(rule: rule, conditions: rule.conditions.map { ($0.compile(), $0.negate) })
        return matches(compiled, req, host: HostNormalizer.host(of: req.url))
    }

    static func matches(_ r: CompiledRule, _ req: RouteRequest, host: String) -> Bool {
        // A rule with no conditions is a catch-all.
        if r.conditions.isEmpty { return true }
        let results = r.conditions.lazy.map { c -> Bool in
            if case .invalid = c.0 { return false }
            let v = c.0.evaluate(req, host: host)
            return c.negate ? !v : v
        }
        switch r.rule.mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        }
    }

    static func isAvailable(_ t: TargetID, in available: Set<TargetID>) -> Bool {
        available.contains(t)
    }
}

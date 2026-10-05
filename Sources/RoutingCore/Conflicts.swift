import Foundation

// MARK: - Conflict analysis

public struct RuleWarning: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// An earlier rule matches every link this rule matches, so this rule never runs.
        case coveredBy(ruleID: UUID, sameTarget: Bool)
        /// Same conditions as an earlier rule, but a different target.
        case duplicateConditions(ruleID: UUID)
        /// A condition can't be used (empty, bad regex, unknown modifier).
        case invalidCondition(index: Int, message: String)
        /// The target browser or profile is not installed.
        case missingTarget
    }

    public var id: String { "\(ruleID)-\(kind)" }
    public let ruleID: UUID
    public let kind: Kind
    public let message: String

    public var isError: Bool {
        if case .invalidCondition = kind { return true }
        if case .missingTarget = kind { return true }
        return false
    }
}

public enum ConflictAnalyzer {
    /// Finds rules that can never run, duplicates, and invalid conditions.
    /// The analysis is conservative: it reports only cases it can prove.
    public static func analyze(_ file: RulesFile, available: Set<TargetID>? = nil) -> [RuleWarning] {
        var warnings: [RuleWarning] = []
        let compiled = CompiledRules(file)
        for issue in compiled.issues {
            warnings.append(RuleWarning(ruleID: issue.ruleID, kind: .invalidCondition(index: issue.conditionIndex, message: issue.message),
                                        message: "Condition \(issue.conditionIndex + 1): \(issue.message)"))
        }
        let rules = file.rules
        for (j, later) in rules.enumerated() where later.enabled {
            if let available, !available.contains(later.target) {
                warnings.append(RuleWarning(ruleID: later.id, kind: .missingTarget,
                                            message: "Target \(later.target) is not installed. Links that match will show the picker."))
            }
            guard !compiled.issues.contains(where: { $0.ruleID == later.id }) else { continue }
            for earlier in rules[..<j] where earlier.enabled {
                guard !compiled.issues.contains(where: { $0.ruleID == earlier.id }) else { continue }
                let name = "rule \(rules.firstIndex(of: earlier)! + 1) “\(earlier.name)”"
                if sameConditions(earlier, later) {
                    if earlier.target != later.target || earlier.options != later.options {
                        warnings.append(RuleWarning(ruleID: later.id, kind: .duplicateConditions(ruleID: earlier.id),
                                                    message: "Same conditions as \(name), which opens a different target. This rule never runs."))
                    } else {
                        warnings.append(RuleWarning(ruleID: later.id, kind: .coveredBy(ruleID: earlier.id, sameTarget: true),
                                                    message: "Duplicate of \(name). This rule never runs."))
                    }
                    break
                }
                if implies(later, earlier) {
                    let same = earlier.target == later.target && earlier.options == later.options
                    warnings.append(RuleWarning(ruleID: later.id, kind: .coveredBy(ruleID: earlier.id, sameTarget: same),
                                                message: "Fully covered by \(name)\(same ? " (same target)" : ""). This rule never runs."))
                    break
                }
            }
        }
        return warnings
    }

    static func sameConditions(_ a: Rule, _ b: Rule) -> Bool {
        let na = Set(a.conditions.map(normalized)), nb = Set(b.conditions.map(normalized))
        guard na == nb else { return false }
        return a.mode == b.mode || na.count <= 1
    }

    static func normalized(_ c: Condition) -> Condition {
        var c = c
        switch c.kind {
        case .domain, .hostIs: c.value = HostNormalizer.cleanDomainInput(c.value)
        case .urlContains, .sourceApp, .wildcard: c.value = c.value.lowercased().trimmingCharacters(in: .whitespaces)
        case .modifier: c.value = ModifierSet(string: c.value)?.name ?? c.value
        case .pathPrefix:
            let v = c.value.trimmingCharacters(in: .whitespaces)
            c.value = v.hasPrefix("/") ? v : "/" + v
        case .regex: break
        }
        return c
    }

    /// True when every link matching `b` also matches `a`.
    static func implies(_ b: Rule, _ a: Rule) -> Bool {
        if a.conditions.isEmpty { return true }   // catch-all covers everything
        if b.conditions.isEmpty { return false }
        let bc = b.conditions.map(normalized), ac = a.conditions.map(normalized)
        func single(_ x: Condition) -> Bool {
            switch a.mode {
            case .all: return ac.allSatisfy { condImplies(x, $0) }
            case .any: return ac.contains { condImplies(x, $0) }
            }
        }
        switch b.mode {
        case .any:
            return bc.allSatisfy(single)
        case .all:
            switch a.mode {
            case .all: return ac.allSatisfy { aCond in bc.contains { condImplies($0, aCond) } }
            case .any: return ac.contains { aCond in bc.contains { condImplies($0, aCond) } }
            }
        }
    }

    /// True when condition x being true proves condition y is true.
    static func condImplies(_ x: Condition, _ y: Condition) -> Bool {
        if x == y { return true }
        if x.negate || y.negate {
            // NOT p ⇒ NOT q  when  q ⇒ p.
            guard x.negate, y.negate else { return false }
            var px = x, py = y
            px.negate = false; py.negate = false
            return condImplies(py, px)
        }
        switch (x.kind, y.kind) {
        case (.domain, .domain), (.hostIs, .domain):
            return HostNormalizer.domainMatches(host: x.value, domain: y.value)
        case (.hostIs, .urlContains), (.domain, .urlContains):
            // Host text always appears in the URL.
            return x.value.contains(y.value)
        case (.pathPrefix, .pathPrefix):
            return x.value.hasPrefix(y.value)
        case (.pathPrefix, .urlContains):
            return x.value.lowercased().contains(y.value)
        case (.urlContains, .urlContains):
            return x.value.contains(y.value)
        case (.modifier, .modifier):
            guard let mx = ModifierSet(string: x.value), let my = ModifierSet(string: y.value) else { return false }
            return mx.isSuperset(of: my)
        default:
            return false
        }
    }
}

// MARK: - Codec

public struct RulesFileError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum RulesCodec {
    public static func decode(_ data: Data) throws(RulesFileError) -> RulesFile {
        // First pass: JSONSerialization gives line/column for syntax errors.
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            throw RulesFileError(message: "Invalid JSON: \(detail)")
        }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let file: RulesFile
        do {
            file = try decoder.decode(RulesFile.self, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw RulesFileError(message: "\(path(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw RulesFileError(message: "\(path(ctx.codingPath)): missing “\(key.stringValue)”.")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw RulesFileError(message: "\(path(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw RulesFileError(message: "\(path(ctx.codingPath)): \(ctx.debugDescription)")
        } catch {
            throw RulesFileError(message: error.localizedDescription)
        }
        guard file.schemaVersion <= RulesFile.currentSchemaVersion else {
            throw RulesFileError(message: "schemaVersion \(file.schemaVersion) is newer than this app supports (\(RulesFile.currentSchemaVersion)). Update BrowserBro.")
        }
        return migrate(file)
    }

    public static func encode(_ file: RulesFile) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding plain value types can't fail.
        return (try? encoder.encode(file)) ?? Data()
    }

    /// Upgrades older schema versions. Version 1 is the first, so nothing to do yet.
    static func migrate(_ file: RulesFile) -> RulesFile {
        var f = file
        f.schemaVersion = RulesFile.currentSchemaVersion
        return f
    }

    static func path(_ keys: [CodingKey]) -> String {
        guard !keys.isEmpty else { return "File" }
        return keys.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

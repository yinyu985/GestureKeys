import Foundation

private struct IndexedRule: Sendable {
    let rule: Rule
    let templates: [Shape.Template]

    init?(_ rule: Rule) {
        guard rule.enabled else { return nil }
        let points = rule.kind == .gesture ? Shape.normalize(rule.points) : nil
        guard rule.validationError(gestureIsValid: points != nil) == nil else { return nil }
        self.rule = rule
        self.templates = points.map { Shape.templates(rule: rule, normalized: $0) } ?? []
    }
}

public struct MouseBindings: Sendable {
    public static let empty = MouseBindings()
    public private(set) var count = 0
    public private(set) var singleClick: Rule?
    public private(set) var doubleClick: Rule?
    public private(set) var templates: [Shape.Template] = []

    fileprivate mutating func append(_ entry: IndexedRule) {
        count += 1
        if !entry.templates.isEmpty {
            templates.append(contentsOf: entry.templates)
        } else if entry.rule.clickCount == 2 {
            if doubleClick == nil { doubleClick = entry.rule }
        } else if singleClick == nil {
            singleClick = entry.rule
        }
    }
}

/// Effective bindings for one foreground application. The input thread only needs lookups.
public struct ScopedRules: Sendable {
    public static let empty = ScopedRules([])
    public private(set) var keyboardRules: [Rule] = []
    public let shortcuts: Set<Shortcut>
    private var keyboardByShortcut: [Shortcut: Rule] = [:]
    private var mouseByButton: [Int: MouseBindings] = [:]

    fileprivate init(_ active: [IndexedRule]) {
        for entry in active {
            let rule = entry.rule
            if rule.kind == .keyboard, let shortcut = rule.triggerKey {
                keyboardRules.append(rule)
                // The first effective binding wins when inspecting a conflicting configuration.
                if keyboardByShortcut[shortcut] == nil { keyboardByShortcut[shortcut] = rule }
            } else {
                mouseByButton[rule.mouseButton, default: .empty].append(entry)
            }
        }
        shortcuts = Set(keyboardByShortcut.keys)
    }

    public func keyboardRule(for key: Shortcut) -> Rule? { keyboardByShortcut[key] }
    public func mouseBindings(for button: Int) -> MouseBindings { mouseByButton[button] ?? .empty }
}

/// Rebuild for a rules edit. Validation, conflict checks, and template sampling are independent of focus.
public final class RuleIndex: Sendable {
    private let byScope: [String: [IndexedRule]]
    private let global: ScopedRules
    public let hasConflicts: Bool
    public let activeKeyboardRules: [Rule]
    public var hasEnabledRules: Bool { !byScope.isEmpty }

    public init(_ rules: [Rule]) {
        var byScope: [String: [IndexedRule]] = [:]
        var foundConflict = false
        var keyboard: [Rule] = []
        for rule in rules {
            guard let entry = IndexedRule(rule) else { continue }
            if !foundConflict, let prior = byScope[rule.bundleID],
               prior.contains(where: { RuleResolver.sameTrigger($0.rule, rule) }) {
                foundConflict = true
            }
            byScope[rule.bundleID, default: []].append(entry)
            if rule.kind == .keyboard { keyboard.append(rule) }
        }
        self.byScope = byScope
        self.hasConflicts = foundConflict
        self.activeKeyboardRules = keyboard
        self.global = ScopedRules(byScope[""] ?? [])
    }

    public func scoped(to bundleID: String) -> ScopedRules {
        guard !bundleID.isEmpty, let local = byScope[bundleID] else { return global }
        let remainingGlobal = (byScope[""] ?? []).filter { entry in
            !local.contains { RuleResolver.sameTrigger($0.rule, entry.rule) }
        }
        return ScopedRules(local + remainingGlobal)
    }
}

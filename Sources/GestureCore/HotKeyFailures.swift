import Foundation

/// Leaving an app drops its registrations, but is not a successful retry of its shortcuts.
public struct HotKeyFailures: Equatable, Sendable {
    private struct Binding: Hashable, Sendable {
        let scope: String, key: Shortcut
        init?(_ rule: Rule) {
            guard rule.kind == .keyboard, rule.enabled, let key = rule.triggerKey, rule.validationError == nil else { return nil }
            self.key = key; scope = rule.bundleID
        }
    }
    private var failed: Set<Binding> = []
    public init() {}
    public var shortcuts: Set<Shortcut> { Set(failed.map(\.key)) }

    public mutating func update(rules: [Rule], attempted: [Rule], rejected: Set<Shortcut>) {
        if !failed.isEmpty { failed.formIntersection(rules.compactMap(Binding.init)) }
        for binding in attempted.compactMap(Binding.init) {
            if rejected.contains(binding.key) { failed.insert(binding) } else { failed.remove(binding) }
        }
    }
}

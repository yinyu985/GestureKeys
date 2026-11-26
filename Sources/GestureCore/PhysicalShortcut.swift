import Foundation

extension Shortcut {
    public struct ModifierSide: Sendable {
        public let common: UInt64, device: UInt64
        public let label: String
        init(_ common: UInt64, _ device: UInt64, _ label: String) {
            self.common = common; self.device = device; self.label = label
        }
    }
    // macOS virtual key codes and NX_DEVICE*KEYMASK values.
    public static let sides: [UInt16: ModifierSide] = [
        56: .init(0x20000, 2, "L⇧"), 60: .init(0x20000, 4, "R⇧"),
        59: .init(0x40000, 1, "L⌃"), 62: .init(0x40000, 0x2000, "R⌃"),
        58: .init(0x80000, 32, "L⌥"), 61: .init(0x80000, 64, "R⌥"),
        55: .init(0x100000, 8, "L⌘"), 54: .init(0x100000, 16, "R⌘")]
    public static func flags(for keys: [UInt16]) -> UInt64 {
        keys.compactMap { sides[$0] }.reduce(0) { $0 | $1.common | $1.device }
    }
    public var validPhysicalOutput: Bool {
        guard let keys = physicalModifiers else { return true }
        return !keys.isEmpty && keys.count <= 8 && Set(keys).count == keys.count && keys.allSatisfy { Self.sides[$0] != nil } && Self.flags(for: keys) & Self.mask == modifiers && (Self.sides[keyCode] == nil || keys.last == keyCode)
    }
    public init?(physical keys: [UInt16], main: UInt16? = nil) {
        guard let last = keys.last else { return nil }
        self.init(main ?? last, Self.flags(for: keys)); physicalModifiers = keys
        guard validPhysicalOutput else { return nil }
    }
    public typealias KeyStep = (key: UInt16, down: Bool, modifier: Bool, flags: UInt64)
    public var physicalSteps: [KeyStep]? {
        guard let keys = physicalModifiers, validPhysicalOutput else { return nil }
        var steps: [KeyStep] = [], held: [UInt16] = []
        for k in keys { held.append(k); steps.append((k, true, true, Self.flags(for: held))) }
        if !keys.contains(keyCode) {
            for down in [true, false] { steps.append((keyCode, down, false, Self.flags(for: held))) }
        }
        while let k = held.popLast() { steps.append((k, false, true, Self.flags(for: held))) }
        return steps
    }
}

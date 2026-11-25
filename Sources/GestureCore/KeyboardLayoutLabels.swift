import Carbon
import Foundation

/// Read HIToolbox only on the main thread. The input worker may read the same labels for diagnostics.
public enum KeyboardLayoutLabels {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var labels: [UInt16: String] = [:]
    }
    private static let cache = Cache()

    static func label(for code: UInt16) -> String? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.labels[code]
    }

    @discardableResult @MainActor public static func refresh(from source: TISInputSource? = nil) -> Bool {
        var labels: [UInt16: String] = [:]
        if let layout = source ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            withExtendedLifetime(data) {
                guard let bytes = CFDataGetBytePtr(data) else { return }
                let table = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                let keyboard = UInt32(LMGetKbdType())
                // Printable key positions only. Keep the existing names for Return, Space, arrows, F-keys, etc.
                for code: UInt16 in Array(0...35) + Array(37...47) + [50, 93, 94] {
                    var dead: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(table, code, UInt16(kUCKeyActionDisplay), 0, keyboard,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    guard text.rangeOfCharacter(from: .controlCharacters.union(.whitespacesAndNewlines)) == nil else { continue }
                    let upper = text.uppercased()
                    labels[code] = upper.count == 1 ? upper : text
                }
            }
        }
        cache.lock.lock(); defer { cache.lock.unlock() }
        guard labels != cache.labels else { return false }
        cache.labels = labels; return true
    }
}

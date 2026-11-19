import Carbon
import GestureCore

/// Register only the configured chords with macOS; no global keyboard event tap.
final class GlobalHotKeys {
    private static let signature: OSType = 0x474B4832
    private struct Entry {
        let id: UInt32
        let ref: EventHotKeyRef
        var held = false
    }
    private var handler: EventHandlerRef?
    private var entries: [Shortcut: Entry] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var rejectedStatuses: [Shortcut: OSStatus] = [:]
    private var lastHandlerError: OSStatus?
    private var nextID: UInt32 = 0
    var onPress: ((Shortcut) -> Void)?

    func replace(with desired: Set<Shortcut>) -> [Shortcut] {
        rejectedStatuses = rejectedStatuses.filter { desired.contains($0.key) }
        for key in Array(entries.keys) where !desired.contains(key) {
            if let entry = entries.removeValue(forKey: key) {
                let result = UnregisterEventHotKey(entry.ref); shortcuts.removeValue(forKey: entry.id)
                diagnostics.record("hotkey.unregistered", ["shortcut": key.display, "os_status": String(result)])
            }
        }
        guard !desired.isEmpty else { return [] }
        if handler == nil {
            var types = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            let count = types.count
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue().receive(event)
            }, count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else {
                if lastHandlerError != result { diagnostics.record("hotkey.handler_failed", ["os_status": String(result)]); lastHandlerError = result }
                return desired.sorted { $0.display < $1.display }
            }
            diagnostics.record("hotkey.handler_installed")
            lastHandlerError = nil
        }
        var rejected: [Shortcut] = []
        for key in desired where entries[key] == nil {
            var modifiers: UInt32 = 0
            if key.modifiers & 0x20000 != 0 { modifiers |= UInt32(shiftKey) }
            if key.modifiers & 0x40000 != 0 { modifiers |= UInt32(controlKey) }
            if key.modifiers & 0x80000 != 0 { modifiers |= UInt32(optionKey) }
            if key.modifiers & 0x100000 != 0 { modifiers |= UInt32(cmdKey) }
            nextID &+= 1
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key.keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: nextID),
                                             GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
            if result == noErr, let ref {
                entries[key] = Entry(id: nextID, ref: ref); shortcuts[nextID] = key
                let recovered = rejectedStatuses.removeValue(forKey: key) != nil
                diagnostics.record("hotkey.registered", ["shortcut": key.display, "recovered": String(recovered)])
            } else {
                if rejectedStatuses[key] != result {
                    diagnostics.record("hotkey.registration_failed", ["shortcut": key.display, "os_status": String(result)])
                    rejectedStatuses[key] = result
                }
                rejected.append(key)
            }
        }
        return rejected.sorted { $0.display < $1.display }
    }
    private func receive(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == Self.signature, let key = shortcuts[id.id], var entry = entries[key] else {
            return OSStatus(eventNotHandledErr)
        }
        let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let initialPress = down && !entry.held
        entry.held = down; entries[key] = entry
        if initialPress { onPress?(key) }
        return noErr
    }
    deinit {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

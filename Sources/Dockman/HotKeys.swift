import AppKit
import Carbon.HIToolbox

/// System-wide ⌃⌥ shortcuts: 1…9 per Dock (`Behavior.hotkeyDigit`), 0 = keyboard focus, Space = search.
/// Uses Carbon's RegisterEventHotKey: event-driven, needs no permission, costs nothing idle.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private static let digitKeyCodes: [Int: Int] = [
        1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
        6: kVK_ANSI_6, 7: kVK_ANSI_7, 8: kVK_ANSI_8, 9: kVK_ANSI_9,
    ]

    /// ⌃⌥0 focuses a dock for keyboard navigation; ⌃⌥Space opens type-to-launch search.
    static let focusKey = kVK_ANSI_0
    static let searchKey = kVK_Space

    /// Replace all shortcuts: `digits` (1–9 → action) plus fixed ⌃⌥ keys (key code → action).
    func register(_ digits: [Int: () -> Void], fixed: [Int: () -> Void] = [:]) {
        unregisterAll()
        var all: [(code: Int, action: () -> Void)] = fixed.map { ($0.key, $0.value) }
        for (digit, action) in digits { if let code = Self.digitKeyCodes[digit] { all.append((code, action)) } }
        guard !all.isEmpty else { return }
        installHandlerIfNeeded()
        for (n, entry) in all.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x444B_4D4E), id: UInt32(n + 1))   // 'DKMN'
            if RegisterEventHotKey(UInt32(entry.code), UInt32(controlKey | optionKey), id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[UInt32(n + 1)] = entry.action
            }
        }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}

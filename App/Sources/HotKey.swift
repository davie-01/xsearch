import AppKit
import Carbon.HIToolbox

/// Global shortcut through Carbon's RegisterEventHotKey: no Accessibility permission needed.
/// Registration fails when another app owns the combination; callers surface that (§13).
@MainActor
final class HotKey {
    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32  // Carbon modifier mask (optionKey, cmdKey, ...)

        static let optionSpace = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

        var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + Self.keyName(keyCode)
        }

        static func keyName(_ code: UInt32) -> String {
            switch Int(code) {
            case kVK_Space: "Space"
            case kVK_Return: "↵"
            case kVK_Tab: "Tab"
            case kVK_Escape: "Esc"
            default:
                if let s = Self.characters(for: code) { s.uppercased() } else { "#\(code)" }
            }
        }

        private static func characters(for code: UInt32) -> String? {
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            return data.withUnsafeBytes { buf -> String? in
                guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let rc = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
                return rc == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len) : nil
            }
        }

        static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            if flags.contains(.option) { m |= UInt32(optionKey) }
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.shift) { m |= UInt32(shiftKey) }
            return m
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var combo: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Returns false when the combination is taken.
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5853_4348), id: 1)  // 'XSCH'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        self.combo = combo
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        combo = nil
    }
}

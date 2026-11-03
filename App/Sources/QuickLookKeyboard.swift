import AppKit
import Quartz

/// Shared by the launcher and full window. The preview's embedded viewer can consume keys
/// before its delegate, so close shortcuts are caught while Quick Look owns the keyboard.
@MainActor
enum QuickLookKeyboard {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let closed = MainActor.assumeIsolated {
                guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
                      panel.isVisible, panel.isKeyWindow || event.window === panel else { return false }
                return closeIfRequested(event, panel: panel)
            }
            return closed ? nil : event
        }
    }

    static func isCloseKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Caps Lock, Fn and numeric-pad flags do not change these shortcut meanings.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty { return event.keyCode == 49 || event.keyCode == 53 }
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    @discardableResult
    static func closeIfRequested(_ event: NSEvent, panel: QLPreviewPanel) -> Bool {
        guard isCloseKey(event) else { return false }
        panel.orderOut(nil)
        return true
    }
}

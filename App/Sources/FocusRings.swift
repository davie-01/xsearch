import AppKit
import ObjectiveC

/// XSearch draws no keyboard focus rings anywhere: the caret, the selection and the
/// highlighted row already show where you are (as in Spotlight and Finder). Rather than
/// setting `focusRingType = .none` on every control, the getter answers `.none` on the four
/// AppKit classes that implement it (NSView, NSControl, NSTableView, NSCell; every other
/// control inherits from one of them), which also covers the AppKit controls SwiftUI builds
/// on. SwiftUI's own focus effect is turned off at the root of each hosted view.
enum FocusRings {
    /// Once, before any window exists.
    static func disable() {
        let getter = #selector(getter: NSView.focusRingType)
        let none: @convention(block) (AnyObject) -> UInt = { _ in NSFocusRingType.none.rawValue }
        let imp = imp_implementationWithBlock(none)
        for cls in [NSView.self, NSControl.self, NSTableView.self, NSCell.self] as [AnyClass] {
            guard let method = class_getInstanceMethod(cls, getter) else { continue }
            // Replaces the class's own implementation (each of these has one), not its superclass's.
            class_replaceMethod(cls, getter, imp, method_getTypeEncoding(method))
        }
    }
}

import Foundation

/// Which part of a large document the preview shows, and how hits map onto it. A hit is not
/// assumed to fit: `regex:a+` can match more text than the window holds, and passing such a
/// range to the text system raises NSRangeException.
public enum PreviewWindow {
    /// Documents above this size (UTF-16 units) are shown as a window around the current hit:
    /// handing millions of characters to the text system costs ~100 ms per document even with
    /// non-contiguous layout, and typing must not wait for previews.
    public static let limit = 300_000
    public static let size = 200_000

    /// The range to show for `hit`. A hit too long to center starts at the window's top.
    public static func range(for hit: NSRange, in text: NSString) -> NSRange {
        let length = text.length
        guard length > limit else { return NSRange(location: 0, length: length) }
        let start = hit.length >= size / 2 ? hit.location : max(0, hit.location - size / 2)
        let end = min(length, start + size)
        return text.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, end - size), length: min(size, end)))
    }

    /// The shown part of `hit`, in window coordinates; nil when none of it is shown.
    public static func visible(_ hit: NSRange, in window: NSRange) -> NSRange? {
        guard window.location != NSNotFound else { return nil }
        let part = NSIntersectionRange(hit, window)
        return part.length > 0 ? NSRange(location: part.location - window.location, length: part.length) : nil
    }

    /// Whether the window must move for `hit`: it shows less of the hit than it could.
    public static func needsMove(_ hit: NSRange, window: NSRange) -> Bool {
        guard let part = visible(hit, in: window) else { return true }
        return part.length < min(hit.length, window.length)
    }
}

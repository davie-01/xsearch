import CXSearchCore

/// Literal name key: NFC → Unicode 17 full case fold → NFC, implemented once in Rust (D12).
/// Index and query must both go through this type; never compare names with Foundation folding.
public enum NameKey {
    public static let version: String = String(cString: xs_name_key_version())

    public static func key(_ name: String) -> String {
        String(decoding: bytes(name), as: UTF8.self)
    }

    public static func bytes(_ name: String) -> [UInt8] {
        var name = name
        return name.withUTF8 { utf8 in
            // ASCII fast path: full folding of ASCII is exactly A–Z → a–z and NFC is a no-op.
            // Tests check this against the Rust implementation for every printable ASCII byte.
            if !utf8.contains(where: { $0 >= 0x80 }) {
                return utf8.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 }
            }
            return rust(utf8)
        }
    }

    /// Always uses the Rust implementation; exposed so tests can verify the fast path.
    public static func rust(_ utf8: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var capacity = utf8.count * 3 + 16
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = out.withUnsafeMutableBufferPointer {
                xs_name_key(utf8.baseAddress, utf8.count, $0.baseAddress, capacity)
            }
            // File names reaching here are valid Swift strings, so -1 means a Rust panic; fall back
            // to the raw bytes rather than dropping the entry from the index.
            if n < 0 { return Array(utf8) }
            if n <= capacity { out.removeSubrange(n...); return out }
            capacity = n
        }
    }
}

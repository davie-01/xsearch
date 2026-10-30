import Foundation

/// The part of an archive document that belongs to one member (preview and reader): text from
/// the member's start (a scalar offset) to the next member marker, highlights clipped and
/// shifted (UTF-16), the member's own anchors shifted (markers dropped).
public func memberSlice(text: String, anchorsJson: String, highlights: [Utf16Range], start: UInt32)
    -> (text: String, anchorsJson: String, highlights: [Utf16Range]) {
    let anchors = (try? JSONSerialization.jsonObject(with: Data(anchorsJson.utf8)) as? [[String: Any]]) ?? []
    let end = anchors.filter { $0["kind"] as? String == "member" }.compactMap { $0["start"] as? Int }.filter { $0 > Int(start) }.min()
    var lo: Int?, hi: Int?
    var scalar = 0, u = 0
    for s in text.unicodeScalars {
        if scalar == Int(start) { lo = u }
        if let end, scalar == end { hi = u; break }
        scalar += 1
        u += s.utf16.count
    }
    let u0 = lo ?? u
    let u1 = max(u0, hi ?? (text as NSString).length)
    let sliced = (text as NSString).substring(with: NSRange(location: u0, length: u1 - u0))
    let shifted: [[String: Any]] = anchors.compactMap { a in
        guard a["kind"] as? String != "member", let s = a["start"] as? Int, s >= Int(start), end.map({ s < $0 }) ?? true else { return nil }
        var b = a
        b["start"] = s - Int(start)
        return b
    }
    let json = (try? JSONSerialization.data(withJSONObject: shifted)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    let hl = highlights.filter { Int($0.start) >= u0 && Int($0.end) <= u1 }
        .map { Utf16Range(start: $0.start - UInt32(u0), end: $0.end - UInt32(u0)) }
    return (sliced, json, hl)
}

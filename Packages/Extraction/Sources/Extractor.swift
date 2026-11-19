import AppKit
import ContentEngine
import Foundation
import PDFKit
import XSearchCore

/// What a worker returns for one file. Anchors / pages are JSON in the `xs_index` formats
/// (`Anchor`, `PageState`), so they go to the index writer unchanged.
public struct ExtractionResult: Codable, Sendable, Equatable {
    public var text: String
    public var anchorsJSON: String
    public var pagesJSON: String
    /// "complete" | "partial" | "waiting_ocr" | "failed"
    public var state: String
    public var warnings: [String]
    public var method: String
    public var extractorVersion: UInt64
}

public struct ExtractionLimits: Codable, Sendable, Equatable {
    /// Settings → 单文件上限 (default 100 MB).
    public var maxFileBytes: UInt64
    public var maxUnpackedBytes: UInt64

    public init(maxFileBytes: UInt64 = 100 << 20, maxUnpackedBytes: UInt64 = 256 << 20) {
        self.maxFileBytes = maxFileBytes
        self.maxUnpackedBytes = maxUnpackedBytes
    }
}

public enum ExtractionError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case encrypted
    case tooLarge(UInt64)
    case unreadable(String)

    public var description: String {
        switch self {
        case .unsupported(let ext): "不支持的类型：\(ext)"
        case .encrypted: "PDF 已加密，无法提取"
        case .tooLarge(let n): "超过单文件上限（\(n >> 20) MB）"
        case .unreadable(let m): m
        }
    }
}

/// Formats handled in M2; the extension table lives in `XSearchCore.ContentType`.
public typealias ExtractionKind = ContentType

extension ContentType {
    public static func of(path: String) -> ContentType? { of(name: (path as NSString).lastPathComponent) }
}

public enum Extractor {
    public static let pdfVersion: UInt64 = 1
    public static let docVersion: UInt64 = 2
    public static let rtfVersion: UInt64 = 1
    public static let wpsVersion: UInt64 = 2

    /// OpenDocument text and presentations (.odt / .odp) have a parser of their own inside the
    /// Word and slide types: versioned apart, so a change re-extracts only them.
    public static var odfVersion: UInt64 { engineVersions()["extractor.odf"].flatMap(UInt64.init) ?? 1 }
    public static let odfExtensions: Set<String> = ["odt", "odp"]

    /// Current extractor version per type (Rust ones come from the engine).
    public static func version(of type: ContentType) -> UInt64 {
        switch type {
        case .pdf: pdfVersion
        case .doc: docVersion
        case .text: engineVersions()["extractor.text"].flatMap(UInt64.init) ?? 1
        case .docx: engineVersions()["extractor.docx"].flatMap(UInt64.init) ?? 1
        case .sheet: engineVersions()["extractor.sheet"].flatMap(UInt64.init) ?? 1
        case .slide: engineVersions()["extractor.slide"].flatMap(UInt64.init) ?? 1
        case .ofd: engineVersions()["extractor.ofd"].flatMap(UInt64.init) ?? 1
        case .web: engineVersions()["extractor.web"].flatMap(UInt64.init) ?? 1
        case .ebook: engineVersions()["extractor.ebook"].flatMap(UInt64.init) ?? 1
        case .rtf: rtfVersion
        case .archive: archiveVersion
        case .wps: wpsVersion
        case .email: engineVersions()["extractor.email"].flatMap(UInt64.init) ?? 1
        }
    }

    public static func extract(path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        limited(try extractAny(path: path, limits: limits), to: limits.maxUnpackedBytes)
    }

    /// The one budget every kind ends with: UTF-8 text, cut on a character boundary, partial.
    static func limited(_ result: ExtractionResult, to maxBytes: UInt64) -> ExtractionResult {
        guard result.text.utf8.count > maxBytes else { return result }
        var end = result.text.utf8.index(result.text.utf8.startIndex, offsetBy: Int(maxBytes))
        while end.samePosition(in: result.text.unicodeScalars) == nil { end = result.text.utf8.index(before: end) }
        var r = result
        r.text = String(result.text[..<end])
        let scalars = r.text.unicodeScalars.count
        let anchors = (try? JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8)) as? [[String: Any]]) ?? []
        r.anchorsJSON = json(anchors.filter { ($0["start"] as? Int ?? 0) < scalars })
        r.state = "partial"
        r.warnings.append("内容超过上限，后续部分未索引")
        return r
    }

    private static func extractAny(path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        guard let kind = ExtractionKind.of(path: path) else { throw ExtractionError.unsupported((path as NSString).pathExtension) }
        switch kind {
        case .text:
            return try rust { try extractPlainText(path: path, maxFileBytes: limits.maxFileBytes) }
        case .docx:
            try checkSize(path, limits)
            return try rust { try extractDocx(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .pdf:
            try checkSize(path, limits)
            return try pdf(path, maxBytes: limits.maxUnpackedBytes)
        case .doc:
            try checkSize(path, limits)
            return try doc(path, limits: limits)
        case .wps:
            // WPS Writer saves either an OOXML package (= docx) or Word 97 binary (= doc).
            try checkSize(path, limits)
            if (FileHandle(forReadingAtPath: path).flatMap { try? $0.read(upToCount: 2) }) == Data("PK".utf8) {
                var r = try rust { try extractDocx(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
                r.method = "wps/docx"
                r.extractorVersion = wpsVersion
                return r
            }
            var r = try word97(path, limits: limits, fallback: "wps/doc", version: wpsVersion)
            if r.method == "word97" { r.method = "wps/word97" }
            return r
        case .rtf:
            try checkSize(path, limits)
            return try attributed(path, type: .rtf, method: "rtf", version: rtfVersion)
        case .web:
            try checkSize(path, limits)
            return try rust { try extractHtml(path: path, maxFileBytes: limits.maxFileBytes) }
        case .archive:
            // Not bound by the single-file limit: members are (size, total and count limits).
            return try archive(path, limits: limits)
        case .ebook:
            // An Apple Books ePub can be a folder: its size is the sum of its files.
            return try rust { try extractEpub(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .sheet:
            try checkSize(path, limits)
            return try rust { try extractSpreadsheet(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .slide:
            try checkSize(path, limits)
            return try rust { try extractPptx(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .ofd:
            try checkSize(path, limits)
            return try rust { try extractOfd(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .email:
            // Large messages are mostly attachments: the first part is read, the rest is noted.
            return try rust { try extractEmail(path: path, maxFileBytes: limits.maxFileBytes) }
        }
    }

    static func checkSize(_ path: String, _ limits: ExtractionLimits) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        if size > limits.maxFileBytes { throw ExtractionError.tooLarge(limits.maxFileBytes) }
    }

    static func rust(_ body: () throws -> ExtractionOutput) throws -> ExtractionResult {
        do {
            let o = try body()
            return ExtractionResult(text: o.text, anchorsJSON: o.anchorsJson, pagesJSON: o.pagesJson, state: o.state.code,
                                    warnings: o.warnings, method: o.method, extractorVersion: o.extractorVer)
        } catch let e as EngineError {
            throw ExtractionError.unreadable("\(e)")
        }
    }

    // MARK: PDF

    /// Page text from the PDF text layer. Each page gets a page anchor and a page state:
    /// blank → waiting_ocr (§14), NUL / U+FFFD present → partial (the layer lost characters;
    /// M0 found 𠀀 turning into NUL). Raw page text is kept unchanged so PDFKit selections
    /// still line up for highlighting.
    /// Stops at `maxBytes` of text: a small file can hold far more text than its size suggests.
    static func pdf(_ path: String, maxBytes: UInt64) throws -> ExtractionResult {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw ExtractionError.unreadable("PDF 无法打开") }
        if doc.isLocked || doc.isEncrypted && !doc.unlock(withPassword: "") { throw ExtractionError.encrypted }
        var text = ""
        var scalars = 0
        var anchors: [[String: Any]] = []
        var pages: [[String: Any]] = []
        var waiting = 0, partial = 0, stopped = false
        for i in 0..<doc.pageCount {
            if text.utf8.count >= maxBytes { stopped = true; break }
            // Each page's objects go back at once.
            let s = autoreleasepool { doc.page(at: i)?.string ?? "" }
            let state: String
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = "waiting_ocr"; waiting += 1
            } else if s.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0xFFFD }) {
                state = "partial"; partial += 1
            } else {
                state = "complete"
            }
            anchors.append(["start": scalars, "kind": "page", "page": i + 1])
            pages.append(["page": i + 1, "source": "text", "state": state, "extractor_ver": pdfVersion, "config": ""])
            text += s + "\n"
            scalars += s.unicodeScalars.count + 1
        }
        var warnings: [String] = []
        if waiting > 0 { warnings.append("\(waiting) 页没有文字层，等待 OCR") }
        if partial > 0 { warnings.append("\(partial) 页文字层有缺失字符") }
        let state = doc.pageCount > 0 && waiting == doc.pageCount ? "waiting_ocr" : (waiting + partial > 0 || stopped ? "partial" : "complete")
        if stopped { warnings.append("内容超过上限，后续页面未索引") }
        return ExtractionResult(text: text, anchorsJSON: json(anchors), pagesJSON: json(pages), state: state,
                                warnings: warnings, method: "pdfkit", extractorVersion: pdfVersion)
    }

    // MARK: DOC

    /// Legacy Word: our own Word 97 reader first (AppKit returns no text at all for some real
    /// documents), AppKit / textutil when it fails or finds nothing. No text from either is
    /// partial, not complete: the file is then worth another try with a later version.
    static func doc(_ path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        try word97(path, limits: limits, fallback: "nsattributedstring", version: docVersion)
    }

    static func word97(_ path: String, limits: ExtractionLimits, fallback: String, version: UInt64) throws -> ExtractionResult {
        if var r = try? rust({ try extractWord97(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }),
           !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r.extractorVersion = version
            return r
        }
        var r = try attributed(path, type: .docFormat, method: fallback, version: version)
        if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { r.state = "partial"; r.warnings.append("没有读到正文") }
        return r
    }

    /// AppKit's readers (.doc, RTF), textutil as fallback; a paragraph anchor per non-empty line.
    static func attributed(_ path: String, type: NSAttributedString.DocumentType, method preferred: String, version: UInt64) throws -> ExtractionResult {
        var method = preferred
        var text: String
        do {
            text = try NSAttributedString(url: URL(fileURLWithPath: path), options: [.documentType: type], documentAttributes: nil).string
        } catch {
            method = "textutil"
            text = try textutil(path)
        }
        var anchors: [[String: Any]] = []
        var scalars = 0, index = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                anchors.append(["start": scalars, "kind": "paragraph", "index": index])
            }
            scalars += line.unicodeScalars.count + 1
        }
        return ExtractionResult(text: text, anchorsJSON: json(anchors), pagesJSON: "[]", state: "complete",
                                warnings: [], method: method, extractorVersion: version)
    }

    static func textutil(_ path: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "txt", "-stdout", "-encoding", "UTF-8", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { throw ExtractionError.unreadable("DOC 无法读取") }
        return s
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension ExtractStateKind {
    public var code: String {
        switch self {
        case .complete: "complete"
        case .partial: "partial"
        case .waitingOcr: "waiting_ocr"
        case .failed: "failed"
        }
    }

    public init(code: String) {
        switch code {
        case "partial": self = .partial
        case "waiting_ocr": self = .waitingOcr
        case "failed": self = .failed
        default: self = .complete
        }
    }
}

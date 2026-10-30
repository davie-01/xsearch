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
    public static let docVersion: UInt64 = 1

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
        }
    }

    public static func extract(path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        guard let kind = ExtractionKind.of(path: path) else { throw ExtractionError.unsupported((path as NSString).pathExtension) }
        switch kind {
        case .text:
            return try rust { try extractPlainText(path: path, maxFileBytes: limits.maxFileBytes) }
        case .docx:
            try checkSize(path, limits)
            return try rust { try extractDocx(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .pdf:
            try checkSize(path, limits)
            return try pdf(path)
        case .doc:
            try checkSize(path, limits)
            return try doc(path)
        case .sheet:
            try checkSize(path, limits)
            return try rust { try extractSpreadsheet(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .slide:
            try checkSize(path, limits)
            return try rust { try extractPptx(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
        case .ofd:
            try checkSize(path, limits)
            return try rust { try extractOfd(path: path, maxUnpackedBytes: limits.maxUnpackedBytes) }
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
    static func pdf(_ path: String) throws -> ExtractionResult {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw ExtractionError.unreadable("PDF 无法打开") }
        if doc.isLocked || doc.isEncrypted && !doc.unlock(withPassword: "") { throw ExtractionError.encrypted }
        var text = ""
        var scalars = 0
        var anchors: [[String: Any]] = []
        var pages: [[String: Any]] = []
        var waiting = 0, partial = 0
        for i in 0..<doc.pageCount {
            let s = doc.page(at: i)?.string ?? ""
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
        let state = doc.pageCount > 0 && waiting == doc.pageCount ? "waiting_ocr" : (waiting + partial > 0 ? "partial" : "complete")
        return ExtractionResult(text: text, anchorsJSON: json(anchors), pagesJSON: json(pages), state: state,
                                warnings: warnings, method: "pdfkit", extractorVersion: pdfVersion)
    }

    // MARK: DOC

    /// Legacy Word: NSAttributedString first (M0: identical to textutil on all real samples),
    /// textutil as fallback. One paragraph anchor per non-empty line.
    static func doc(_ path: String) throws -> ExtractionResult {
        var method = "nsattributedstring"
        var text: String
        do {
            text = try NSAttributedString(url: URL(fileURLWithPath: path), options: [.documentType: NSAttributedString.DocumentType.docFormat],
                                          documentAttributes: nil).string
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
                                warnings: [], method: method, extractorVersion: docVersion)
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

/// Coarse file categories for `kind:` and the result type block (UI-SPEC 2.1).
public enum FileKind: String, CaseIterable, Sendable {
    case folder, app, pdf, word, sheet, slide, ofd, text, image, video, audio, archive, other

    /// Extensions (already name-key folded) for extension-based kinds.
    public var extensions: Set<String> {
        switch self {
        case .pdf: ["pdf"]
        case .word: ["doc", "docx", "wps", "rtf", "pages", "odt"]
        case .sheet: ["xls", "xlsx", "csv", "numbers", "ods", "et"]
        case .slide: ["ppt", "pptx", "key", "odp", "dps"]
        case .ofd: ["ofd"]
        case .text: ["txt", "md", "markdown", "log", "json", "xml", "yaml", "yml", "toml", "ini", "swift", "rs", "c", "h", "m", "mm", "cpp", "hpp", "py", "js", "ts", "tsx", "jsx", "go", "java", "kt", "rb", "sh", "zsh", "html", "css", "sql"]
        case .image: ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng"]
        case .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        case .audio: ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"]
        case .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso"]
        case .folder, .app, .other: []
        }
    }

    /// Words accepted after `kind:`. Chinese aliases follow the UI copy.
    public static func parse(_ word: String) -> FileKind? {
        switch NameKey.key(word) {
        case "folder", "dir", "directory", "文件夹", "目录": .folder
        case "app", "application", "应用": .app
        case "pdf": .pdf
        case "doc", "word", "文档": .word
        case "xls", "excel", "sheet", "表格": .sheet
        case "ppt", "slide", "powerpoint", "演示": .slide
        case "ofd": .ofd
        case "text", "txt", "code", "文本", "代码": .text
        case "image", "img", "picture", "图片": .image
        case "video", "视频": .video
        case "audio", "music", "音频": .audio
        case "archive", "zip", "压缩包": .archive
        default: nil
        }
    }

    public static func of(extension ext: String, isDirectory: Bool, isApp: Bool) -> FileKind {
        if isApp { return .app }
        if isDirectory { return .folder }
        return allCases.first { $0.extensions.contains(ext) } ?? .other
    }

    /// Short label shown in the result type block.
    public func badge(extension ext: String) -> String {
        switch self {
        case .folder: "DIR"
        case .app: "APP"
        default: ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
        }
    }
}

/// Extension of an already-folded key: the part after the last dot, unless the dot is leading.
public func keyExtension<C: BidirectionalCollection>(_ key: C) -> C.SubSequence? where C.Element == UInt8 {
    guard let dot = key.lastIndex(of: 0x2E), dot != key.startIndex else { return nil }
    let ext = key[key.index(after: dot)...]
    return ext.isEmpty ? nil : ext
}

import Foundation
import UniformTypeIdentifiers

/// The documents an app declares it can open (its Info.plist `CFBundleDocumentTypes`): the
/// scope of a Spotlight-style "Tab on an app" search. Spotlight (macOS 26) narrows to the
/// documents an app can open; XSearch does the same with the app's declared types, checked by
/// UTI conformance (so `public.image` covers PNG, HEIC, …) plus legacy extension lists.
public struct DocumentTypes: Sendable, Equatable {
    public var appName: String
    public var appPath: String
    /// Declared content types (UTIs), roles Viewer / Editor / Shell.
    public var types: [String]
    /// Legacy `CFBundleTypeExtensions`, folded.
    public var extensions: Set<String>

    public init(appName: String, appPath: String, types: [String], extensions: Set<String>) {
        self.appName = appName
        self.appPath = appPath
        self.types = types
        self.extensions = extensions
    }

    /// Reads the app bundle's declarations; types whose role is "None" are declared but not
    /// opened, and wildcards ("*", "****") would mean "everything", so both are left out.
    public init(appPath: String) {
        let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        var types: [String] = []
        var exts = Set<String>()
        for entry in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            if (entry["CFBundleTypeRole"] as? String) == "None" { continue }
            types += (entry["LSItemContentTypes"] as? [String] ?? []).filter { !Self.notDocuments.contains($0) }
            for e in entry["CFBundleTypeExtensions"] as? [String] ?? [] where !e.contains("*") { exts.insert(NameKey.key(e)) }
        }
        self.init(appName: name, appPath: appPath, types: Array(Set(types)).sorted(), extensions: exts)
    }

    /// Declared but not documents: catch-alls, and containers (Preview declares folders,
    /// packages and app bundles, which would list every `.app`).
    static let notDocuments: Set<String> = [
        "public.item", "public.data", "public.content", "public.folder", "public.directory",
        "com.apple.package", "com.apple.bundle", "com.apple.application-bundle", "com.apple.application",
    ]

    public var isEmpty: Bool { types.isEmpty && extensions.isEmpty }

    /// Whether a file with this (folded) extension is one of the app's documents.
    public func allows(extension ext: String) -> Bool {
        // Real extensions are short and alphanumeric; names such as "报告.2024-v3" would each
        // create a dynamic type in Launch Services (slow, and tens of thousands of them).
        guard (1...12).contains(ext.utf8.count), ext.utf8.allSatisfy({ $0 < 0x80 && (isalnum(Int32($0)) != 0) }) else { return false }
        if extensions.contains(ext) { return true }
        guard let t = UTType(filenameExtension: ext) else { return false }
        return types.contains { declared in UTType(declared).map { t.conforms(to: $0) } ?? false }
    }
}

import Foundation

/// IndexService.xpc (ARCHITECTURE §5): the content indexer — the only Tantivy writer, and the
/// supervisor of the extraction workers — runs in an XPC service bundled in the app. The app
/// keeps the name index, the catalog's change detection and all reading. Both sides share the
/// catalog SQLite (WAL, busy timeout) exactly as two connections in one process did before.
@objc public protocol IndexServiceProtocol {
    /// Starts (or keeps running) the indexer on `dataDirectory`; replies an error message or nil.
    func start(dataDirectory: String, workerPath: String, workers: Int, maxFileBytes: UInt64, reply: @escaping (String?) -> Void)
    /// The single-file limit changed in settings: only the files it affects are extracted again.
    func setMaxFileBytes(_ bytes: UInt64)
    /// JSON `IndexServiceSnapshot`.
    func snapshot(reply: @escaping (Data) -> Void)
    func rebuildContentIndex(reply: @escaping (String?) -> Void)
    /// Stops the indexer (writer closed, workers stopped); the app calls this before quitting.
    func stop(reply: @escaping () -> Void)
}

/// What the app shows and needs: progress, and the instance directory readers open.
public struct IndexServiceSnapshot: Codable, Sendable, Equatable {
    public var status: ContentIndexer.Status
    public var indexPath: String?

    public init(status: ContentIndexer.Status, indexPath: String?) {
        self.status = status
        self.indexPath = indexPath
    }
}

public enum IndexServiceInfo {
    public static let serviceName = "org.xsearch.XSearch.IndexService"
}

import Catalog
import Foundation

/// The app's side of IndexService.xpc (ARCHITECTURE §5). Connects at launch (warm-up), keeps
/// the latest snapshot for the status line and the readers, reconnects and restarts the
/// indexer when the service dies. Without the bundled service (swift run, tests) the indexer
/// runs in-process instead, with the same interface.
@MainActor
final class IndexServiceClient {
    private let dataDirectory: URL
    private let worker: URL
    private var connection: NSXPCConnection?
    private var local: ContentIndexer?
    /// Latest snapshot; read from any thread through `indexPath`.
    private(set) var snapshot = IndexServiceSnapshot(status: ContentIndexer.Status(), indexPath: nil)
    private let pathLock = NSLock()
    nonisolated(unsafe) private var cachedPath: String?
    var onError: ((String) -> Void)?
    var onUpdate: (() -> Void)?

    var status: ContentIndexer.Status? { snapshot.status.running ? snapshot.status : nil }

    init(dataDirectory: URL, worker: URL) {
        self.dataDirectory = dataDirectory
        self.worker = worker
    }

    static var serviceBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/IndexService.xpc").path)
    }

    /// The active instance's directory for readers (any thread).
    nonisolated var indexPath: String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        return cachedPath
    }

    private func setPath(_ p: String?) {
        pathLock.lock()
        cachedPath = p
        pathLock.unlock()
    }

    func start() {
        guard Self.serviceBundled && ProcessInfo.processInfo.environment["XS_INPROCESS_INDEX"] != "1" else {
            let ix = ContentIndexer(directory: dataDirectory, workerExecutable: worker, workers: 2)
            do { try ix.start(); local = ix } catch { onError?(String(describing: error)) }
            refresh()
            return
        }
        let c = NSXPCConnection(serviceName: IndexServiceInfo.serviceName)
        c.remoteObjectInterface = NSXPCInterface(with: IndexServiceProtocol.self)
        // A crash or kill: launchd starts the service again on the next message.
        c.interruptionHandler = { [weak self] in Task { @MainActor in self?.startRemote() } }
        c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        c.resume()
        connection = c
        startRemote()
    }

    private var proxy: IndexServiceProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        } as? IndexServiceProtocol
    }

    private var startAttempts = 0

    /// A start can fail transiently (e.g. while the catalog is being rebuilt after a
    /// downgrade): retried every 3 s, up to 5 times.
    private func startRemote() {
        proxy?.start(dataDirectory: dataDirectory.path, workerPath: worker.path, workers: 2) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.onError?(error)
                    self.startAttempts += 1
                    if self.startAttempts < 5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startRemote() }
                    }
                } else {
                    self.startAttempts = 0
                }
                self.refresh()
            }
        }
    }

    /// Pulls a fresh snapshot (asynchronous; `onUpdate` fires when it arrives).
    func refresh() {
        if let local {
            snapshot = IndexServiceSnapshot(status: local.status, indexPath: local.indexURL.path)
            setPath(snapshot.indexPath)
            onUpdate?()
            return
        }
        proxy?.snapshot { [weak self] data in
            guard let snap = try? JSONDecoder().decode(IndexServiceSnapshot.self, from: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snap
                self.setPath(snap.indexPath)
                self.onUpdate?()
            }
        }
    }

    func rebuildContentIndex() {
        if let local { try? local.rebuildContentIndex(); refresh(); return }
        proxy?.rebuildContentIndex { [weak self] error in
            Task { @MainActor in
                if let error { self?.onError?(error) }
                self?.refresh()
            }
        }
    }

    /// Synchronous: the writer is closed before the app quits or deletes the index.
    func stop() {
        if let local { local.stop(); self.local = nil; return }
        guard let c = connection else { return }
        let sync = c.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? IndexServiceProtocol
        sync?.stop {}
        c.invalidate()
        connection = nil
        setPath(nil)
    }
}

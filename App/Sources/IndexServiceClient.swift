import Catalog
import Foundation

/// The app's side of IndexService.xpc (ARCHITECTURE §5). Connects at launch (warm-up), keeps
/// the latest snapshot for the status line and the readers, reconnects and restarts the
/// indexer when the service dies. Without the bundled service (swift run, tests) the indexer
/// runs in-process instead, with the same interface.
private struct UncheckedConnection: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

@MainActor
final class IndexServiceClient {
    private let dataDirectory: URL
    private let worker: URL
    private var connection: NSXPCConnection?
    private var generation = 0
    private var stopping = false
    private var reconnectDelay: TimeInterval = 1
    private var local: ContentIndexer?
    /// Latest snapshot; read from any thread through `indexPath`.
    private(set) var snapshot = IndexServiceSnapshot(status: ContentIndexer.Status(), indexPath: nil)
    private let pathLock = NSLock()
    nonisolated(unsafe) private var cachedPath: String?
    var onError: ((String) -> Void)?
    var onUpdate: (() -> Void)?
    /// Single-file limit from the settings; set before `start`.
    var maxFileBytes: UInt64 = 100 << 20
    /// Content indexing paused by the user; set before `start`, then through `setPaused`.
    private(set) var paused = false

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
            ix.setMaxFileBytes(maxFileBytes)
            ix.setPaused(paused)
            do { try ix.start(); local = ix } catch { onError?(String(describing: error)) }
            refresh()
            return
        }
        stopping = false
        connect()
    }

    /// One connection per generation: callbacks of a replaced connection do nothing.
    private func connect() {
        generation += 1
        let gen = generation
        let c = NSXPCConnection(serviceName: IndexServiceInfo.serviceName)
        c.remoteObjectInterface = NSXPCInterface(with: IndexServiceProtocol.self)
        // A crash or kill: launchd starts the service again on the next message.
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.startRemote()
            }
        }
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.connection = nil
                self.reconnectLater()
            }
        }
        c.resume()
        connection = c
        startRemote()
    }

    /// The connection is gone for good (service could not be launched…): a new one, with growing
    /// pauses so a broken install does not spin. Reset once a start succeeds.
    private func reconnectLater() {
        guard !stopping else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping, self.connection == nil else { return }
            self.connect()
        }
    }

    private var proxy: IndexServiceProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        } as? IndexServiceProtocol
    }

    private var startAttempts = 0
    private var startRetry: DispatchWorkItem?

    /// A start can fail transiently (e.g. while the catalog is being rebuilt after a
    /// downgrade): retried every 3 s, up to 5 times. Replies and retries belong to their
    /// connection's generation: once stopping (to delete the index) or replaced, a late one
    /// must not start the writer again.
    private func startRemote() {
        guard !stopping else { return }
        let gen = generation
        proxy?.start(dataDirectory: dataDirectory.path, workerPath: worker.path, workers: 2, maxFileBytes: maxFileBytes, paused: paused) { [weak self] error in
            Task { @MainActor in
                guard let self, !self.stopping, gen == self.generation else { return }
                if let error {
                    self.onError?(error)
                    self.startAttempts += 1
                    if self.startAttempts < 5 {
                        let retry = DispatchWorkItem { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self, !self.stopping, gen == self.generation else { return }
                                self.startRemote()
                            }
                        }
                        self.startRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)
                    }
                } else {
                    self.startAttempts = 0
                    self.reconnectDelay = 1
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
        let gen = generation
        proxy?.snapshot { [weak self] data in
            guard let snap = try? JSONDecoder().decode(IndexServiceSnapshot.self, from: data) else { return }
            Task { @MainActor in
                // A reply from before a stop or reconnect must not bring back an old path.
                guard let self, !self.stopping, gen == self.generation else { return }
                self.snapshot = snap
                self.setPath(snap.indexPath)
                self.onUpdate?()
            }
        }
    }

    /// The catalog queued tasks.
    func wake() {
        if let local { local.wake() } else { proxy?.wake() }
    }

    func setMaxFileBytes(_ bytes: UInt64) {
        guard bytes != maxFileBytes else { return }
        maxFileBytes = bytes
        if let local { local.setMaxFileBytes(bytes) } else { proxy?.setMaxFileBytes(bytes) }
    }

    /// Also the value every later (re)start passes on.
    func setPaused(_ p: Bool) {
        paused = p
        if let local { local.setPaused(p) } else { proxy?.setPaused(p) }
        refresh()
    }

    /// Replies how many files were queued (0: not in the content scope, or no service).
    func reindex(fileIds: [Int64], done: @escaping @MainActor @Sendable (Int) -> Void) {
        if let local {
            let n = (try? local.reindex(fileIds: fileIds)) ?? 0
            refresh()
            done(n)
            return
        }
        guard let proxy, let data = try? JSONEncoder().encode(fileIds) else { done(0); return }
        proxy.reindexFiles(data) { [weak self] n in
            Task { @MainActor in
                self?.refresh()
                done(n)
            }
        }
    }

    func retryFailed(done: @escaping @MainActor @Sendable (Int) -> Void) {
        if let local {
            let n = (try? local.retryFailed()) ?? 0
            refresh()
            done(n)
            return
        }
        guard let proxy else { done(0); return }
        proxy.retryFailed { [weak self] n in
            Task { @MainActor in
                self?.refresh()
                done(n)
            }
        }
    }

    func clearContentIndex(done: @escaping @MainActor () -> Void) {
        if let local {
            do { try local.clearContentIndex() } catch { onError?(String(describing: error)) }
            refresh()
            done()
            return
        }
        proxy?.clearContentIndex { [weak self] error in
            Task { @MainActor in
                if let error { self?.onError?(error) }
                self?.refresh()
                done()
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

    /// For deleting the index: reports whether the service answered that its writer is closed
    /// (or the connection died with it), without blocking the main thread. false after `timeout`:
    /// the writer may still be working, so nothing may be deleted; `resume` reconnects.
    /// An error on this connection counts as closed because it only comes once the service
    /// process is gone, and the writer with it. Checked with a stop slowed in the service: killed
    /// during the stop, the error came with no IndexService left and no one holding the index;
    /// suspended (SIGSTOP) or hung, no error came and the timeout said false (2026-11-05).
    func stopAndConfirm(timeout: TimeInterval = 20, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        stopping = true
        generation += 1
        startRetry?.cancel()
        startRetry = nil
        if let local {
            local.stop()
            self.local = nil
            done(true)
            return
        }
        guard let c = connection else { done(true); return }
        let answered = DispatchSemaphore(value: 0)
        let remote = c.remoteObjectProxyWithErrorHandler { @Sendable _ in answered.signal() } as? IndexServiceProtocol
        remote?.stop { @Sendable in answered.signal() }
        let box = UncheckedConnection(c)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let closed = answered.wait(timeout: .now() + timeout) == .success
            DispatchQueue.main.async {
                if closed {
                    box.connection.invalidate()
                    self?.connection = nil
                    self?.setPath(nil)
                }
                done(closed)
            }
        }
    }

    /// After a `stopAndConfirm` that timed out: back to normal.
    func resume() {
        stopping = false
        connection?.invalidate()
        connection = nil
        start()
    }

    /// Waits for the writer to close before the app quits, at most 2 s so
    /// quitting never hangs; the service stops by itself when the connection goes away, and
    /// the next start recovers anything left unfinished.
    func stop() {
        stopping = true
        generation += 1
        startRetry?.cancel()
        startRetry = nil
        if let local { local.stop(); self.local = nil; return }
        guard let c = connection else { return }
        let done = DispatchSemaphore(value: 0)
        let remote = c.remoteObjectProxyWithErrorHandler { @Sendable _ in done.signal() } as? IndexServiceProtocol
        remote?.stop { @Sendable in done.signal() }
        _ = done.wait(timeout: .now() + 2)
        c.invalidate()
        connection = nil
        setPath(nil)
    }
}

// IndexService.xpc: hosts the content indexer (ARCHITECTURE §5). One instance per app; it
// stops the indexer and exits when the app's connection goes away, so it never outlives the
// app nor writes without it.
import Catalog
import Foundation

final class Service: NSObject, IndexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var indexer: ContentIndexer?
    private var directory: String?
    private var shape: (workers: Int, background: Bool)?
    /// The app, told about status changes (set when it connects).
    var client: IndexServiceClientProtocol? {
        get { lock.withLock { _client } }
        set { lock.withLock { _client = newValue } }
    }
    private var _client: IndexServiceClientProtocol?
    private let notifyQueue = DispatchQueue(label: "xsearch.service.status")
    private var lastNotified = Date.distantPast  // on notifyQueue
    private var notifyScheduled = false  // on notifyQueue

    func start(dataDirectory: String, workerPath: String, workers: Int, background: Bool, maxFileBytes: UInt64, paused: Bool, reply: @escaping (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Same index, same indexing mode: keep it. Another mode needs new workers and queue: the
        // indexer is stopped (running extractions go back to the queue) and started again.
        if let indexer, directory == dataDirectory, shape.map({ $0.workers == workers && $0.background == background }) == true {
            indexer.setMaxFileBytes(maxFileBytes)
            indexer.setPaused(paused)
            reply(nil)
            return
        }
        indexer?.stop()
        let ix = ContentIndexer(directory: URL(fileURLWithPath: dataDirectory), workerExecutable: URL(fileURLWithPath: workerPath), workers: workers, background: background)
        ix.setMaxFileBytes(maxFileBytes)
        ix.setPaused(paused)
        ix.onSettled = { [weak self] in self?.recycleIfLarge() }
        ix.onStatusChange = { [weak self] in self?.statusChanged() }
        do {
            try ix.start()
            indexer = ix
            directory = dataDirectory
            shape = (workers, background)
            reply(nil)
        } catch {
            indexer = nil
            reply(String(describing: error))
        }
    }

    func snapshot(reply: @escaping (Data) -> Void) {
        reply(snapshotData())
    }

    private func snapshotData() -> Data {
        lock.lock()
        let ix = indexer
        lock.unlock()
        let status = ix?.status ?? ContentIndexer.Status()
        let snap = IndexServiceSnapshot(status: status, indexPath: ix?.indexURL(of: status).path)
        return (try? JSONEncoder().encode(snap)) ?? Data()
    }

    /// At most one message a second while the indexer works: the first change goes out at once,
    /// later ones within the second fold into one at its end. Idle sends nothing.
    private func statusChanged() {
        notifyQueue.async { [self] in
            guard !notifyScheduled else { return }
            let wait = 1 - Date().timeIntervalSince(lastNotified)
            if wait <= 0 { sendStatus(); return }
            notifyScheduled = true
            notifyQueue.asyncAfter(deadline: .now() + wait) { [self] in
                notifyScheduled = false
                sendStatus()
            }
        }
    }

    private func sendStatus() {
        lastNotified = Date()
        client?.statusChanged(snapshotData())
    }

    func rebuildContentIndex(reply: @escaping (String?) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        do { try ix?.rebuildContentIndex(); reply(nil) } catch { reply(String(describing: error)) }
    }

    func reindexFiles(_ fileIds: Data, reply: @escaping (Int) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        let ids = (try? JSONDecoder().decode([Int64].self, from: fileIds)) ?? []
        reply((try? ix?.reindex(fileIds: ids)) ?? 0)
    }

    func retryFailed(reply: @escaping (Int) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        reply((try? ix?.retryFailed()) ?? 0)
    }

    func clearContentIndex(reply: @escaping (String?) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        do { try ix?.clearContentIndex(); reply(nil) } catch { reply(String(describing: error)) }
    }

    func setMaxFileBytes(_ bytes: UInt64) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        ix?.setMaxFileBytes(bytes)
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        ix?.setPaused(paused)
    }

    func wake() {
        lock.lock()
        let ix = indexer
        lock.unlock()
        ix?.wake()
    }

    /// Text and index buffers of a large batch stay with the allocator after they are freed
    /// (hundreds of MB, which `malloc_zone_pressure_relief` does not return). The clean way to
    /// give them back is to leave: nothing is lost, and the app's next message starts a new
    /// service, the same path as after a crash. Searching runs in the app and does not notice.
    private func recycleIfLarge() {
        guard footprintBytes() > Self.recycleAbove else { return }
        stop {}
        exit(0)
    }

    private static let recycleAbove: UInt64 = 64 << 20

    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func stop(reply: @escaping () -> Void) {
        lock.lock()
        let ix = indexer
        indexer = nil
        directory = nil
        shape = nil
        lock.unlock()
        // Outside the lock: snapshots must not wait for the stop.
        ix?.stop()
        reply()
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    let service = Service()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: IndexServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: IndexServiceClientProtocol.self)
        service.client = connection.remoteObjectProxy as? IndexServiceClientProtocol
        // The app quit or crashed: finish cleanly and leave.
        connection.invalidationHandler = { [service] in
            service.stop {}
            exit(0)
        }
        connection.resume()
        return true
    }
}

signal(SIGPIPE, SIG_IGN)
let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()  // never returns

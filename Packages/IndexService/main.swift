// IndexService.xpc: hosts the content indexer (ARCHITECTURE §5). One instance per app; it
// stops the indexer and exits when the app's connection goes away, so it never outlives the
// app nor writes without it.
import Catalog
import Foundation

final class Service: NSObject, IndexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var indexer: ContentIndexer?
    private var directory: String?

    func start(dataDirectory: String, workerPath: String, workers: Int, maxFileBytes: UInt64, paused: Bool, reply: @escaping (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let indexer, directory == dataDirectory {
            indexer.setMaxFileBytes(maxFileBytes)
            indexer.setPaused(paused)
            reply(nil)
            return
        }
        indexer?.stop()
        let ix = ContentIndexer(directory: URL(fileURLWithPath: dataDirectory), workerExecutable: URL(fileURLWithPath: workerPath), workers: workers)
        ix.setMaxFileBytes(maxFileBytes)
        ix.setPaused(paused)
        ix.onSettled = { [weak self] in self?.recycleIfLarge() }
        do {
            try ix.start()
            indexer = ix
            directory = dataDirectory
            reply(nil)
        } catch {
            indexer = nil
            reply(String(describing: error))
        }
    }

    func snapshot(reply: @escaping (Data) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        let status = ix?.status ?? ContentIndexer.Status()
        let snap = IndexServiceSnapshot(status: status, indexPath: ix?.indexURL(of: status).path)
        reply((try? JSONEncoder().encode(snap)) ?? Data())
    }

    func rebuildContentIndex(reply: @escaping (String?) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        do { try ix?.rebuildContentIndex(); reply(nil) } catch { reply(String(describing: error)) }
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

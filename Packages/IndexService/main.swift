// IndexService.xpc: hosts the content indexer (ARCHITECTURE §5). One instance per app; it
// stops the indexer and exits when the app's connection goes away, so it never outlives the
// app nor writes without it.
import Catalog
import Foundation

final class Service: NSObject, IndexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var indexer: ContentIndexer?
    private var directory: String?

    func start(dataDirectory: String, workerPath: String, workers: Int, reply: @escaping (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if indexer != nil && directory == dataDirectory { reply(nil); return }
        indexer?.stop()
        let ix = ContentIndexer(directory: URL(fileURLWithPath: dataDirectory), workerExecutable: URL(fileURLWithPath: workerPath), workers: workers)
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
        let snap = IndexServiceSnapshot(status: ix?.status ?? ContentIndexer.Status(),
                                        indexPath: ix?.indexURL.path)
        reply((try? JSONEncoder().encode(snap)) ?? Data())
    }

    func rebuildContentIndex(reply: @escaping (String?) -> Void) {
        lock.lock()
        let ix = indexer
        lock.unlock()
        do { try ix?.rebuildContentIndex(); reply(nil) } catch { reply(String(describing: error)) }
    }

    func stop(reply: @escaping () -> Void) {
        lock.lock()
        indexer?.stop()
        indexer = nil
        directory = nil
        lock.unlock()
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

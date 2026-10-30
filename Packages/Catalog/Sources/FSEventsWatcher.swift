import CoreServices
import Foundation

/// File-level FSEvents stream delivered on a caller-owned serial queue.
final class FSEventsWatcher {
    struct Event {
        var path: String
        var flags: UInt32
        var id: UInt64
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void

    init?(paths: [String], since: FSEventStreamEventId, latency: TimeInterval, queue: DispatchQueue, handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                events.append(Event(path: String(cString: cPaths[i]), flags: flags[i], id: ids[i]))
            }
            me.handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since, latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
    }

    func start() -> Bool {
        guard let stream else { return false }
        return FSEventStreamStart(stream)
    }

    /// Asks FSEvents to deliver pending events now. Asynchronous on purpose: a synchronous flush
    /// from another thread deadlocks if the stream's queue is stopping this stream meanwhile.
    func flush() {
        if let stream { FSEventStreamFlushAsync(stream) }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    static var currentEventId: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the FSEvents database of a device; a change means stored event ids are void.
    static func databaseUUID(forPath path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

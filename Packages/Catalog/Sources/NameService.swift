import Foundation
import NameEngine
import os
import XSearchCore

/// Owns the file-name pipeline (ARCHITECTURE §5 ChangeCoordinator, name side):
/// FSEvents → op_journal → reconcile into the catalog → name view overlay → background merge →
/// snapshot on disk. All catalog work runs on one serial queue; queries read an immutable view.
///
/// Restart without rescanning: load the snapshot, replay catalog rows changed after it, then
/// resume FSEvents from the persisted event id and replay journal entries not yet applied.
public final class NameService: @unchecked Sendable {
    public enum Phase: Sendable, Equatable {
        case starting, scanning, ready
        case failed(String)
    }

    public struct Status: Sendable, Equatable {
        public var phase: Phase
        public var count: Int
        public var memoryBytes: Int
        /// Journal entries not yet applied.
        public var backlog: Int
    }

    public let directory: URL
    public let home: String
    private let queue = DispatchQueue(label: "xsearch.catalog", qos: .utility)
    private let mergeQueue = DispatchQueue(label: "xsearch.names.merge", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var catalog: FileCatalog?
    private var watcher: FSEventsWatcher?
    private var scope = NameScope.default
    private var context: Reconciler.Context?
    private var persistedSeq: Int64 = -1
    private var lastPersist = Date.distantPast
    private var persistTimer: DispatchSourceTimer?
    private var processing = false
    /// Recursive rescans (initial scan, scope change, dropped events) applied since start.
    /// Restart must not need one; tests assert this.
    private(set) var rescanOps = 0
    private var failedBatch: (jseq: Int64, count: Int)?
    /// Last reconcile error (diagnostics and tests).
    private(set) var lastBatchError: String?

    struct State {
        var view = NameView(base: .empty(fingerprint: ""))
        /// Every catalog change up to this sequence is in `view`.
        var completeSeq: Int64 = 0
        var merging = false
        var lastMergeEnd = Date.distantPast
        var lastMergeDuration: TimeInterval = 0
        var status = Status(phase: .starting, count: 0, memoryBytes: 0, backlog: 0)
    }

    /// Called on an internal queue whenever the status changes.
    public var onStatus: (@Sendable (Status) -> Void)?

    public var snapshotURL: URL { directory.appendingPathComponent("names/local.idx") }

    public init(directory: URL, home: String = NSHomeDirectory()) {
        self.directory = directory
        self.home = home
    }

    public var view: NameView { state.withLock { $0.view } }
    public var status: Status { state.withLock { $0.status } }

    public func search(_ q: NameQuery, limit: Int = 200, usage: [Int64: Int] = [:]) -> NameView.Result {
        view.search(q, limit: limit, usage: usage)
    }

    // MARK: Lifecycle

    public func start(scope: NameScope) {
        queue.async { [self] in
            do { try open(scope: scope) } catch { fail(error) }
        }
    }

    public func setScope(_ scope: NameScope) {
        queue.async { [self] in
            do {
                guard let catalog else { return }
                self.scope = scope
                context = makeContext(scope)
                try catalog.append([(.scope, "", 0)], lastEventId: nil)
                try catalog.setMeta("fingerprint", scope.fingerprint(home: home))
                restartWatcher(since: try catalog.meta("fsevents_last_id").flatMap(UInt64.init) ?? FSEventsWatcher.currentEventId)
                process()
            } catch { fail(error) }
        }
    }

    /// Stops watching, folds the overlay and writes the snapshot. Safe to call more than once.
    public func shutdown() {
        queue.sync {
            persistTimer?.cancel(); persistTimer = nil
            watcher?.stop(); watcher = nil
            mergeQueue.sync {}
            try? persist(force: true)
            try? catalog?.db.checkpoint()
        }
    }

    /// Test hook: stop like a crash (no merge, no snapshot write, no catalog close).
    func simulateCrash() {
        queue.sync {
            persistTimer?.cancel(); persistTimer = nil
            watcher?.stop(); watcher = nil
            catalog = nil
        }
        mergeQueue.sync {}
    }

    /// Delivers pending FSEvents and waits until the journal is fully applied (tests, diagnostics).
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let idle: Bool = queue.sync {
                watcher?.flush()
                return (try? catalog?.journalBacklog()) == 0 && !processing
            }
            if idle { mergeQueue.sync {}; return true }
            usleep(20_000)
        }
        return false
    }

    // MARK: Startup

    private func makeContext(_ scope: NameScope) -> Reconciler.Context {
        var s = scope
        // Never index our own data directory: writing it would feed events back to us.
        s.excludes.append(directory.path)
        return .init(roots: scope.roots(home: home), rules: ExclusionRules(s, home: home), home: home)
    }

    private func open(scope: NameScope) throws {
        self.scope = scope
        context = makeContext(scope)
        let catalog = try FileCatalog(url: directory.appendingPathComponent("catalog.sqlite"))
        self.catalog = catalog
        if try catalog.meta("catalog_id") == nil { try catalog.setMeta("catalog_id", UUID().uuidString) }
        let catalogId = try catalog.meta("catalog_id")!
        let applied = try catalog.consumer(FileCatalog.nameConsumer)

        // Base: the snapshot when it belongs to this catalog and name-key version, otherwise
        // rebuilt from catalog rows (still no disk rescan).
        var base: NameSnapshot
        do {
            base = try NameSnapshot.load(from: snapshotURL, expectedFingerprint: catalogId)
            persistedSeq = base.seq
        } catch {
            base = NameSnapshot.build(try catalog.liveRecords(), seq: applied, fingerprint: catalogId)
        }
        let replay = try catalog.changes(after: base.seq)
        let view = NameView(base: base).applying(replay)
        state.withLock {
            $0.view = view
            $0.completeSeq = applied
        }

        // FSEvents cursor: resume from the persisted id unless the event database changed.
        let uuids = (["/", home] + context!.roots).compactMap(FSEventsWatcher.databaseUUID(forPath:)).joined(separator: ",")
        var since = try catalog.meta("fsevents_last_id").flatMap(UInt64.init)
        var ops: [(JournalOp.Kind, String, UInt32)] = []
        if try catalog.meta("fsevents_uuids") != uuids {
            if since != nil { ops.append((.scope, "", 0)) }  // history unusable: reconcile everything
            since = nil
        }
        let fingerprint = scope.fingerprint(home: home)
        if try catalog.meta("fingerprint") != fingerprint && !ops.contains(where: { $0.0 == .scope }) {
            ops.append((.scope, "", 0))
        }
        // Start watching before scanning: the scan op precedes every event journaled after it.
        let start = since ?? FSEventsWatcher.currentEventId
        try catalog.append(ops, lastEventId: since == nil ? start : nil)
        try catalog.setMeta("fsevents_uuids", uuids)
        try catalog.setMeta("fingerprint", fingerprint)
        restartWatcher(since: start)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in try? self?.persist(force: false) }
        timer.resume()
        persistTimer = timer
        process()
    }

    private func restartWatcher(since: UInt64) {
        watcher?.stop()
        guard let roots = context?.roots, !roots.isEmpty else { watcher = nil; return }
        watcher = FSEventsWatcher(paths: roots, since: since, latency: 0.3, queue: queue) { [weak self] events in
            self?.received(events)
        }
        if watcher?.start() != true {
            // Without a stream we cannot keep up; reconcile on next start instead of trusting the cursor.
            try? catalog?.setMeta("fsevents_uuids", "")
        }
    }

    // MARK: Events

    /// Runs on `queue`. Filters events that cannot concern the index, journals the rest together
    /// with the cursor, then applies them.
    private func received(_ events: [FSEventsWatcher.Event]) {
        guard let catalog, let context, let maxId = events.map(\.id).max() else { return }
        let probe = Reconciler(catalog: catalog, context: context, seq: 0, publish: { _ in })
        let structural = EventFlag.mustScanSubDirs | EventFlag.userDropped | EventFlag.kernelDropped | EventFlag.eventIdsWrapped | EventFlag.rootChanged
        var ops: [(JournalOp.Kind, String, UInt32)] = []
        var seen = Set<String>()
        for e in events {
            let path = Self.canonicalEventPath(e.path)
            let structuralEvent = e.flags & structural != 0
            if !structuralEvent && !probe.isIndexable(path) { continue }
            let key = "\(path)\u{0}\(e.flags & structural)"
            if seen.insert(key).inserted { ops.append((.fsevent, path, e.flags & structural)) }
        }
        do {
            try catalog.append(ops, lastEventId: maxId)
            if !ops.isEmpty { process() }
        } catch { fail(error) }
    }

    /// Data-volume events can arrive under the firmlink target; the catalog uses the "/" view.
    static func canonicalEventPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    // MARK: Processing

    private func process() {
        guard let catalog, let context, !processing else { return }
        processing = true
        defer { processing = false }
        do {
            while true {
                let applied = try catalog.consumer(FileCatalog.nameConsumer)
                let batch = try catalog.journal(after: applied, limit: 2000)
                guard let last = batch.last else { break }
                let large = batch.contains { $0.kind != .fsevent || $0.flags != 0 }
                rescanOps += batch.filter { $0.kind != .fsevent || $0.flags != 0 }.count
                if large { updateStatus { $0.phase = .scanning } }
                let reconciler = Reconciler(catalog: catalog, context: context, seq: last.jseq) { [weak self] changes in
                    self?.publish(changes)
                }
                do {
                    try reconciler.run(batch)
                    failedBatch = nil
                } catch {
                    lastBatchError = String(describing: error)
                    // A batch that keeps failing must not stall the pipeline: skip it and reconcile
                    // every root instead, which re-derives the same state from the disk.
                    let attempts = failedBatch?.jseq == last.jseq ? failedBatch!.count + 1 : 1
                    failedBatch = (last.jseq, attempts)
                    guard attempts >= 2 else { continue }  // retry once right away
                    // The fallback itself failing means the catalog is unusable: stop, don't loop.
                    if batch.contains(where: { $0.kind == .scope }) { throw error }
                    try catalog.db.transaction {
                        try catalog.setConsumer(FileCatalog.nameConsumer, last.jseq)
                        try catalog.append([(.scope, "", 0)], lastEventId: nil)
                    }
                    failedBatch = nil
                    continue
                }
                let done = last.jseq
                state.withLock { $0.completeSeq = done }
                try catalog.trimJournal()
                if large { mergeNow() }
            }
            updateStatus { $0.phase = .ready; $0.backlog = 0 }
            if persistedSeq < 0 { try persist(force: true) }
        } catch { fail(error) }
    }

    private func publish(_ changes: [NameChange]) {
        state.withLock { $0.view = $0.view.applying(changes) }
        scheduleMerge()
        updateStatus { _ in }
    }

    /// Merge when the overlay exceeds ~0.2% of the base (M0-B: 1% already slows queries).
    private func scheduleMerge() {
        let start: (NameView, Int64)? = state.withLock { s in
            let threshold = max(4096, s.view.base.count / 500)
            // Spend at most about a third of the time merging while a large scan streams in.
            let pause = max(1, 2 * s.lastMergeDuration)
            guard !s.merging, s.view.overlayCount >= threshold, Date().timeIntervalSince(s.lastMergeEnd) > pause else { return nil }
            s.merging = true
            return (s.view, s.completeSeq)
        }
        guard let (captured, complete) = start else { return }
        mergeQueue.async { [self] in
            let began = Date()
            let merged = captured.merged(completeSeq: complete)
            state.withLock { s in
                s.view = s.view.rebased(onto: merged)
                s.merging = false
                s.lastMergeEnd = Date()
                s.lastMergeDuration = s.lastMergeEnd.timeIntervalSince(began)
            }
            updateStatus { _ in }
            scheduleMerge()
        }
    }

    /// Synchronous full merge after a scan, so the result is a compact base.
    private func mergeNow() {
        mergeQueue.sync {}
        let (captured, complete) = state.withLock { s -> (NameView, Int64) in
            s.merging = true
            return (s.view, s.completeSeq)
        }
        let merged = captured.merged(completeSeq: complete)
        state.withLock { s in
            s.view = s.view.rebased(onto: merged)
            s.merging = false
            s.lastMergeEnd = Date()
        }
        updateStatus { _ in }
    }

    /// Writes the base snapshot when it advanced, then drops tombstones it covers. Runs on `queue`.
    private func persist(force: Bool) throws {
        guard let catalog else { return }
        if force && state.withLock({ $0.view.overlayCount > 0 }) { mergeNow() }
        let base = state.withLock { $0.view.base }
        guard base.seq > persistedSeq || (force && persistedSeq < 0) else { return }
        guard force || Date().timeIntervalSince(lastPersist) > 25 else { return }
        try base.write(to: snapshotURL)
        persistedSeq = base.seq
        lastPersist = Date()
        try catalog.purgeTombstones(upTo: base.seq)
        // Fold the WAL back into the database file; after a large scan it would otherwise stay
        // tens of MB and be re-read on every start.
        try catalog.db.checkpoint()
    }

    private func updateStatus(_ change: (inout Status) -> Void) {
        let (status, changed): (Status, Bool) = state.withLockUnchecked { s in
            let before = s.status
            change(&s.status)
            s.status.count = s.view.count
            s.status.memoryBytes = s.view.base.memoryBytes
            return (s.status, s.status != before)
        }
        if changed { onStatus?(status) }
    }

    private func fail(_ error: Error) {
        updateStatus { $0.phase = .failed(String(describing: error)) }
    }
}

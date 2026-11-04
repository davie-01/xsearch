import ContentEngine
import CryptoKit
import Extraction
import Foundation
import os
import XSearchCore

/// IndexService (ARCHITECTURE §5, §9.3): the only writer of the content index. Claims tasks the
/// catalog wrote, extracts in killable worker processes, and commits batches so that a crash at
/// any step neither loses an update nor lets an old result overwrite a newer one:
///
/// 1. tasks carry the file's op_seq; results whose op_seq is not newer than the writer's
///    sequence table (committed + staged) are dropped;
/// 2. the file version is checked before and after extraction;
/// 3. before committing, every staged task must still be the file's latest op, otherwise the
///    whole batch is rolled back and the sequence table rebuilt. Leases are not checked here:
///    this process is the only writer and holds its batch; a lease only tells a later start or
///    cycle that a task was abandoned, however long healthy extraction takes;
/// 4. batch members are recorded in SQLite, then the index commits with (instance, batch) in
///    its payload, then SQLite confirms. At most one unconfirmed batch exists; on restart the
///    payload tells whether it was committed.
public final class ContentIndexer: @unchecked Sendable {
    public struct Status: Codable, Sendable, Equatable {
        public var pending: Int
        public var failed: Int
        /// Content-scope files with indexed text (complete, partial or waiting for OCR).
        public var indexed: Int
        public var committedBatches: UInt64
        public var running: Bool
        /// The last cycle failed; it is retried automatically.
        public var lastError: String?
        /// Active instance, published together with the figures.
        public var instanceId = ""

        public init(pending: Int = 0, failed: Int = 0, indexed: Int = 0, committedBatches: UInt64 = 0, running: Bool = false, lastError: String? = nil) {
            self.pending = pending
            self.failed = failed
            self.indexed = indexed
            self.committedBatches = committedBatches
            self.running = running
            self.lastError = lastError
        }
    }

    public enum Fault: String, CaseIterable, Sendable {
        case afterStage, afterBatchRecorded, afterIndexCommit, afterConfirm
    }

    struct Crash: Error {}

    public let directory: URL
    private let workerURL: URL
    private let workerCount: Int
    private let queue = DispatchQueue(label: "xsearch.indexer", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: Status(pending: 0, failed: 0, indexed: 0, committedBatches: 0, running: false))
    private var catalog: FileCatalog?
    private var writer: ContentIndexWriter?
    private var workers: [ExtractionWorker] = []
    private var timer: DispatchSourceTimer?
    /// Read by extraction threads and set by `stop()` before it waits for the queue.
    private let stopFlag = OSAllocatedUnfairLock(initialState: true)
    private var stopped: Bool {
        get { stopFlag.withLock { $0 } }
        set { stopFlag.withLock { $0 = newValue } }
    }
    private var cycling = false
    private var needsRecovery = false
    private var errorBackoffUntil = Date.distantPast
    /// Switched-out instances, deleted after the grace period (readers need up to a status
    /// refresh to move to the new path; a restart collects whatever is left).
    private var retired: [(url: URL, removeAt: Date)] = []
    /// Committed op_seq per file (rebuilt from the index on open and after rollbacks).
    private var committedSeq: [UInt64: UInt64] = [:]
    private var lastBatch: UInt64 = 0
    public private(set) var instanceId: String {
        get { status.instanceId }
        set { state.withLock { $0.instanceId = newValue } }
    }

    // Tunables (tests shorten them).
    var leaseSeconds: TimeInterval = 600
    var backoffBase: TimeInterval = 30
    var maxAttempts = 3
    var batchSize = 64
    /// A batch ends when this much text has been extracted: it all stays in memory until staged.
    /// What was not reached goes back to the queue. One text can exceed it, so a batch always
    /// makes progress. Measured: 64 texts of 20 MiB took 3.4 GB without this.
    var batchBytes = 64 << 20
    /// Files above this size are extracted one at a time, whichever worker gets them.
    var largeFileBytes: Int64 = 32 << 20
    /// Per-file extraction timeout = base + 2 s per MB.
    var baseTimeout: TimeInterval = 30
    var limits = ExtractionLimits()
    var errorBackoff: TimeInterval = 5
    var settleDelay: TimeInterval = 30
    /// A burst of work has finished and nothing has arrived for a while (any thread).
    public var onSettled: (@Sendable () -> Void)?
    private var lastWork: Date?
    var oldInstanceGrace: TimeInterval = 60
    /// Test hooks: crash at a protocol step; inject a worker fault for a path; run between
    /// extraction and staging (to change the file mid-flight).
    var fault: ((Fault) -> Bool)?
    var workerFault: ((String) -> String?)?
    var afterExtract: ((String) -> Void)?
    /// Extractions served from the cache (tests, diagnostics).
    private(set) var cacheHits = 0
    private let lock = NSLock()
    /// Timer wake-ups so far (tests: idle and back-off waits must not spin).
    let timerFirings = OSAllocatedUnfairLock(initialState: 0)
    private var lastFullCount = Date.distantPast

    /// nil when the file cannot be read to its end, or `cancelled` says stop (no partial digest).
    static func digest(_ path: String, cancelled: () -> Bool = { false }) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            if cancelled() { return nil }
            // Each chunk goes back at once: without the pool a file's whole size piles up here.
            let more: Bool? = autoreleasepool { () -> Bool? in
                let read: Data?
                do { read = try h.read(upToCount: 1 << 20) } catch { return nil }
                // nil is the end of the file.
                guard let chunk = read, !chunk.isEmpty else { return false }
                sha.update(data: chunk)
                return true
            }
            guard let more else { return nil }
            if !more { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public init(directory: URL, workerExecutable: URL, workers: Int = 2, environment: [String: String] = [:]) {
        self.directory = directory
        workerURL = workerExecutable
        workerCount = max(1, workers)
        self.workers = (0..<workerCount).map { _ in ExtractionWorker(executable: workerExecutable, environment: environment) }
    }

    public var status: Status { state.withLock { $0 } }

    /// Instance being rebuilt (written to) while readers stay on `instanceId` until it catches up.
    private var rebuildId: String?

    /// Directory readers open: the active instance (also during a rebuild).
    public var indexURL: URL { indexURL(of: status) }
    /// For a status already read, so the figures and the path belong together.
    public func indexURL(of status: Status) -> URL { directory.appendingPathComponent("content").appendingPathComponent(status.instanceId) }
    /// Directory the writer uses: the rebuild instance while one is running.
    var writeURL: URL { directory.appendingPathComponent("content").appendingPathComponent(rebuildId ?? instanceId) }
    public var isRebuilding: Bool { queue.sync { rebuildId != nil } }

    // MARK: Lifecycle

    public func start() throws {
        try queue.sync {
            let catalog = try FileCatalog(url: directory.appendingPathComponent("catalog.sqlite"))
            self.catalog = catalog
            if try catalog.meta("content_instance") == nil { try catalog.setMeta("content_instance", UUID().uuidString) }
            instanceId = try catalog.meta("content_instance")!
            rebuildId = try catalog.meta("content_rebuild_instance")
            do {
                try openWriter()
            } catch EngineError.Rebuild {
                // The index on disk has another schema (an upgrade changed it, or a downgrade):
                // start a fresh instance and extract everything again instead of staying down.
                try resetIndexInstance()
            }
            try recover()
            removeUnknownInstances()
            try removeOrphanDocuments()
            try applyLimits()
            try reindexUpgradedExtractors()
            workers.forEach { $0.resume() }
            stopped = false
            state.withLock { $0.running = true }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2)
            t.setEventHandler { [weak self] in
                self?.timerFirings.withLock { $0 += 1 }
                self?.cycleAndReschedule()
            }
            t.resume()
            timer = t
        }
    }

    /// Returns quickly even with hung parsers: running extractions are killed first, and their
    /// tasks stay queued without counting as attempts.
    public func stop() {
        stopped = true
        workers.forEach { $0.cancel() }
        queue.sync {
            timer?.cancel(); timer = nil
            writer = nil
            catalog = nil
            workers.forEach { $0.stop() }
            state.withLock { $0.running = false }
        }
    }

    /// New tasks were written (the catalog's owner calls this): look now, not at the next timer.
    public func wake() {
        queue.async { [weak self] in self?.cycleAndReschedule() }
    }

    private func cycleAndReschedule() {
        cycle()
        reportSettled()
        scheduleNextCycle()
    }

    /// Once per burst of work, after `settleDelay` with nothing to do.
    private func reportSettled() {
        guard let last = lastWork, Date().timeIntervalSince(last) >= settleDelay,
              status.pending == 0, rebuildId == nil, !needsRecovery, !stopped else { return }
        lastWork = nil
        if let onSettled { DispatchQueue.global().async(execute: onSettled) }
    }

    /// Idle stays idle: the timer fires for the earliest retry or lease expiry, and otherwise
    /// only as a fallback in case a wake-up was lost.
    private func scheduleNextCycle() {
        guard let timer, !stopped else { return }
        var delay = Self.fallbackInterval
        // The settle report waits only for an idle indexer (see reportSettled): with tasks still
        // waiting for a retry, an elapsed settle delay pinned the timer to 50 ms until the retry.
        if let last = lastWork, status.pending == 0, rebuildId == nil, !needsRecovery {
            delay = min(delay, max(0.05, settleDelay - Date().timeIntervalSince(last)))
        }
        if needsRecovery {
            delay = max(0.05, errorBackoffUntil.timeIntervalSinceNow)
        } else if let catalog,
                  let s = try? catalog.db.prepare("SELECT MIN(CASE state WHEN 0 THEN not_before ELSE lease_until END) FROM content_tasks WHERE state IN (0, 1)"),
                  let next = (try? s.first { s in s.isNull(0) ? nil : s.double(0) }) ?? nil {
            delay = min(delay, max(0.2, next - Date().timeIntervalSince1970))
        }
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(max(50, delay * 100))))
    }

    /// Runs cycles until no task is ready (tests, diagnostics).
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let idle: Bool = queue.sync {
                cycle()
                return (try? readyCount()) == 0 && !cycling
            }
            if idle { return true }
            usleep(20_000)
        }
        return false
    }

    private func openWriter() throws {
        try FileManager.default.createDirectory(at: writeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let w = try ContentIndexWriter.open(path: writeURL.path, newInstanceId: rebuildId ?? instanceId)
        writer = w
        if try w.lastCommit() == nil { try w.commit(batchId: 0) }  // readers can open at once
        committedSeq = try w.appliedSeqs()
        lastBatch = try w.lastCommit()?.batchId ?? 0
        state.withLock { $0.committedBatches = lastBatch }
    }

    /// Replaces an unreadable index instance (schema mismatch) with a new, empty one; every
    /// content file is queued again. Old instance directories and unconfirmed batches go away.
    /// Switch and requeue are one transaction: a crash cannot leave an empty index with no work.
    private func resetIndexInstance() throws {
        guard let catalog else { return }
        writer = nil
        let old = [instanceId, rebuildId].compactMap { $0 }
        let id = UUID().uuidString
        try catalog.db.transaction {
            try catalog.setMeta("content_instance", id)
            try catalog.setMeta("content_rebuild_instance", nil)
            try clearBatchRecords()
            _ = try requeue { _, _ in true }
        }
        instanceId = id
        rebuildId = nil
        for name in old {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("content").appendingPathComponent(name))
        }
        try openWriter()
    }

    /// Batch numbers belong to one index instance.
    private func clearBatchRecords() throws {
        try catalog?.db.exec("DELETE FROM content_batch; DELETE FROM meta WHERE key IN ('content_batch_pending', 'content_batch_confirmed');")
    }

    /// Directories a crash left behind: neither the active instance nor the rebuild.
    private func removeUnknownInstances() {
        let root = directory.appendingPathComponent("content")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name != instanceId && name != rebuildId {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func removeRetiredInstances() {
        let now = Date()
        retired.removeAll { old in
            guard old.removeAt <= now else { return false }
            try? FileManager.default.removeItem(at: old.url)
            return true
        }
    }

    /// Once: documents of files the catalog no longer knows, from versions that purged
    /// tombstones with their delete tasks still queued. Each gets a delete task.
    private func removeOrphanDocuments() throws {
        guard let catalog, let writer, try catalog.meta("content_orphans_checked") == nil else { return }
        let ids = try writer.liveFileIds()
        try catalog.db.transaction {
            var counter = try catalog.opSeqCounter()
            for fid in ids {
                let id = Int64(fid)
                let info = try catalog.contentInfo(id)
                if let info, !info.deleted, info.inContent { continue }
                let task = try catalog.db.prepare("SELECT COUNT(*) FROM content_tasks WHERE file_id = ?").bind(id)
                if try task.first({ $0.int(0) > 0 }) == true { continue }
                counter += 1
                if let info { try catalog.setContent(id, inContent: info.inContent, opSeq: counter) }
                try catalog.enqueue(id, opSeq: counter, kind: .delete, priority: 0)
            }
            try catalog.setOpSeqCounter(counter)
            try catalog.setMeta("content_orphans_checked", "1")
        }
    }

    // MARK: Versions and rebuild

    static func extractorFingerprint() -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: ContentType.allCases.map { ($0.rawValue, Extractor.version(of: $0)) })
    }

    static let fallbackInterval: TimeInterval = 30

    /// Single-file limit from the settings. Before `start` it is simply used; later the files it
    /// affects are queued (on the indexer's queue: a running cycle may take a while).
    public func setMaxFileBytes(_ bytes: UInt64) {
        queue.async { [self] in
            limits.maxFileBytes = bytes
            guard catalog != nil else { return }
            do {
                try applyLimits()
                try refreshCounts()
                scheduleNextCycle()
            } catch {
                state.withLock { $0.lastError = String(describing: error) }
            }
        }
    }

    /// Against the limits the index was built with: files between the old and the new size
    /// limit change their outcome; an archive's members are bound by it whatever its own size.
    private func applyLimits() throws {
        guard let catalog else { return }
        let old = try catalog.meta("content_limits").flatMap { try? JSONDecoder().decode(ExtractionLimits.self, from: Data($0.utf8)) } ?? ExtractionLimits()
        let encoded = String(decoding: try JSONEncoder().encode(limits), as: UTF8.self)
        guard old != limits else {
            if try catalog.meta("content_limits") == nil { try catalog.setMeta("content_limits", encoded) }
            return
        }
        let smaller = Int64(clamping: min(old.maxFileBytes, limits.maxFileBytes))
        let everything = old.maxUnpackedBytes != limits.maxUnpackedBytes
        try catalog.db.transaction {
            _ = try requeue { name, size in everything || size > smaller || ContentType.of(name: name) == .archive }
            try catalog.setMeta("content_limits", encoded)
        }
    }

    /// Bumps op_seq and queues an index task for content files passing `filter` (name, size).
    private func requeue(where filter: (String, Int64) -> Bool) throws -> Int {
        guard let catalog else { return 0 }
        return try catalog.db.transactionIfNeeded {
            let s = try catalog.db.prepare("SELECT id, name, mtime_ns, size FROM files WHERE deleted = 0 AND in_content = 1")
            var rows: [(Int64, String, Int64, Int64)] = []
            while try s.step() { rows.append((s.int(0), s.text(1), s.int(2), s.int(3))) }
            var counter = try catalog.opSeqCounter()
            var n = 0
            for (id, name, mtime, size) in rows where filter(name, size) {
                counter += 1
                try catalog.setContent(id, inContent: true, opSeq: counter)
                try catalog.enqueue(id, opSeq: counter, kind: .index, priority: mtime / 1_000_000_000)
                n += 1
            }
            try catalog.setOpSeqCounter(counter)
            return n
        }
    }

    /// §9.1 extractor_ver: when an extractor changes, only files of its type are re-extracted.
    private func reindexUpgradedExtractors() throws {
        guard let catalog else { return }
        let current = Self.extractorFingerprint()
        let stored = try catalog.meta("content_extractors").flatMap { try? JSONDecoder().decode([String: UInt64].self, from: Data($0.utf8)) }
        if let stored {
            let changed = Set(current.filter { stored[$0.key] != $0.value }.keys)
            if !changed.isEmpty {
                _ = try requeue { name, _ in ContentType.of(name: name).map { changed.contains($0.rawValue) } ?? false }
            }
        }
        try catalog.setMeta("content_extractors", String(decoding: try JSONEncoder().encode(current), as: UTF8.self))
    }

    /// Rebuilds the content index into a new instance (§9.3 step 7, simplified): the writer moves
    /// to the new instance and every content file is re-queued; readers keep the old instance
    /// until the new one has caught up, then the active instance switches and the old
    /// directory is deleted (disk space reclaimed, §6.2). The new writer opens first (a crash
    /// leaves only an unused directory); the rebuild mark and the requeue are one transaction, so
    /// a rebuild never looks caught up before its tasks exist.
    public func rebuildContentIndex() throws {
        try queue.sync {
            guard let catalog, rebuildId == nil else { return }
            try recoverIfNeeded()
            let id = UUID().uuidString
            writer = nil
            rebuildId = id
            do {
                try openWriter()
                try catalog.db.transaction {
                    try catalog.setMeta("content_rebuild_instance", id)
                    try clearBatchRecords()
                    _ = try requeue { _, _ in true }
                }
            } catch {
                writer = nil
                try? FileManager.default.removeItem(at: writeURL)
                rebuildId = nil
                try openWriter()
                throw error
            }
            try refreshCounts()
            scheduleNextCycle()
        }
    }

    /// When no task is left, a running rebuild becomes the active instance.
    private func finishRebuildIfCaughtUp() throws {
        guard let catalog, let id = rebuildId, try readyCount() == 0, status.pending == 0 else { return }
        let old = indexURL
        try catalog.db.transaction {
            try catalog.setMeta("content_instance", id)
            try catalog.setMeta("content_rebuild_instance", nil)
        }
        instanceId = id
        rebuildId = nil
        retired.append((old, Date().addingTimeInterval(oldInstanceGrace)))
    }

    /// Startup and after a failed cycle: resolve the unconfirmed batch, release leases (only
    /// this process indexes, and no cycle is running).
    private func recover() throws {
        guard let catalog, let writer else { return }
        // The index payload alone says whether it was committed.
        if let pending = try catalog.meta("content_batch_pending").flatMap(UInt64.init) {
            if try writer.lastCommit()?.batchId == pending {
                try confirm(batch: pending)  // committed, confirmation lost
            } else {
                try catalog.db.transaction {
                    try catalog.db.exec("DELETE FROM content_batch")
                    try catalog.setMeta("content_batch_pending", nil)
                }
            }
        }
        try catalog.db.exec("UPDATE content_tasks SET state = 0, lease_until = 0 WHERE state = 1")
        try refreshCounts()
    }

    private func recoverIfNeeded() throws {
        guard needsRecovery else { return }
        if writer == nil { try openWriter() }
        try recover()
        if let writer {
            committedSeq = try writer.appliedSeqs()
            lastBatch = try writer.lastCommit()?.batchId ?? 0
            state.withLock { $0.committedBatches = lastBatch }
        }
        needsRecovery = false
    }

    // MARK: Cycle

    struct Task {
        var fileId: Int64
        var opSeq: Int64
        var kind: FileCatalog.TaskKind
        var attempts: Int
    }

    enum Staged {
        case put(ContentInput)
        /// Handed to the writer: only what confirming the batch needs, the text is gone.
        case written(ExtractStateKind)
        case remove
        /// Superseded / stale: finish the task without touching the index.
        case drop
        /// Try again later (file changed during extraction, transient worker failure).
        case retry(after: TimeInterval, error: String?, countAttempt: Bool)
        /// Give up on this file (extraction error, or too many timeouts / crashes).
        case failed(String)
    }

    /// Due tasks, and leases that expired. Binds: now, now.
    private static let claimable = "(state = 0 AND not_before <= ?) OR (state = 1 AND lease_until < ?)"

    private func readyCount() throws -> Int {
        guard let catalog else { return 0 }
        let now = Date().timeIntervalSince1970
        let s = try catalog.db.prepare("SELECT COUNT(*) FROM content_tasks WHERE \(Self.claimable)").bind(now, now)
        return try s.first { s in Int(s.int(0)) } ?? 0
    }

    private func cycle() {
        guard !stopped, !cycling, catalog != nil, Date() >= errorBackoffUntil else { return }
        cycling = true
        defer { cycling = false }
        do {
            try recoverIfNeeded()
            // Idle must stay idle: a read decides, so no write lock is taken without work.
            var worked = false
            while !stopped, try readyCount() > 0 {
                let tasks = try claim(limit: batchSize)
                if tasks.isEmpty { break }
                try process(tasks)
                worked = true
            }
            try refreshCounts(full: worked || Date().timeIntervalSince(lastFullCount) > 30)
            if worked { lastWork = Date() }
            try finishRebuildIfCaughtUp()
            removeRetiredInstances()
            if status.lastError != nil { state.withLock { $0.lastError = nil } }
        } catch is Crash {
            crash()
        } catch {
            // Unexpected I/O or SQLite error (busy for over 5 s, disk full): drop staged work,
            // wait a little, then resolve the batch and leases as a restart would.
            try? writer?.rollback()
            committedSeq = (try? writer?.appliedSeqs()) ?? committedSeq
            needsRecovery = true
            errorBackoffUntil = Date().addingTimeInterval(errorBackoff)
            state.withLock { $0.lastError = String(describing: error) }
        }
    }

    /// Simulated crash: abandon writer and catalog without rollback or cleanup.
    private func crash() {
        stopped = true
        timer?.cancel(); timer = nil
        writer = nil
        catalog = nil
        workers.forEach { $0.stop() }
        state.withLock { $0.running = false }
    }

    private func check(_ f: Fault) throws {
        if fault?(f) == true { throw Crash() }
    }

    private func claim(limit: Int) throws -> [Task] {
        guard let catalog else { return [] }
        let now = Date().timeIntervalSince1970
        return try catalog.db.transaction {
            // A kind this version cannot name could never be marked claimed and would spin the cycle.
            try catalog.db.exec("DELETE FROM content_tasks WHERE kind NOT IN (1, 2)")
            // Deletions first (stale text must disappear), then newest files first (§9.2).
            let s = try catalog.db.prepare("""
                SELECT file_id, op_seq, kind, attempts FROM content_tasks WHERE \(Self.claimable)
                ORDER BY kind DESC, priority DESC LIMIT ?
                """).bind(now, now, limit)
            var out: [Task] = []
            while try s.step() {
                out.append(Task(fileId: s.int(0), opSeq: s.int(1), kind: FileCatalog.TaskKind(rawValue: s.int(2)) ?? .index, attempts: Int(s.int(3))))
            }
            let u = try catalog.db.prepare("UPDATE content_tasks SET state = 1, lease_until = ? WHERE file_id = ? AND op_seq = ? AND kind = ?")
            for t in out { try u.bind(now + leaseSeconds, t.fileId, t.opSeq, t.kind.rawValue).run(); u.reset() }
            return out
        }
    }

    private struct FileVersion: Equatable { var size: Int64; var mtimeNs: Int64; var ino: Int64 }

    private struct Prepared {
        var task: Task
        var path: String
        var info: FileCatalog.ContentInfo
        var version: FileVersion
    }

    private func process(_ tasks: [Task]) throws {
        guard let catalog else { return }
        var outcomes: [(Task, Staged)] = []
        var toExtract: [Prepared] = []
        for t in tasks {
            // The row is gone (purged, or the catalog forgot it): its text must not stay.
            guard let info = try catalog.contentInfo(t.fileId) else { outcomes.append((t, .remove)); continue }
            // Superseded: a newer op for this file exists (its own task will handle it).
            if info.opSeq != t.opSeq { outcomes.append((t, .drop)); continue }
            if t.kind == .delete || info.deleted || !info.inContent { outcomes.append((t, .remove)); continue }
            guard let path = try catalog.path(of: t.fileId), let row = try catalog.row(id: t.fileId) else { outcomes.append((t, .remove)); continue }
            toExtract.append(Prepared(task: t, path: path, info: info, version: FileVersion(size: row.size, mtimeNs: row.mtimeNs, ino: row.ino)))
        }
        // Extract in parallel, one file per worker at a time.
        var results = [Staged?](repeating: nil, count: toExtract.count)
        let lock = NSLock()
        let largeFile = NSLock()
        let extracted = OSAllocatedUnfairLock(initialState: 0)
        let items = toExtract
        let budget = batchBytes, large = largeFileBytes
        DispatchQueue.concurrentPerform(iterations: min(workerCount, max(1, toExtract.count))) { w in
            var i = w
            while i < toExtract.count {
                defer { i += workerCount }
                if extracted.withLock({ $0 >= budget }) { continue }  // stays nil: back to the queue
                let isLarge = items[i].version.size > large
                if isLarge { largeFile.lock() }
                let r = autoreleasepool { extract(items[i], worker: workers[w]) }
                if isLarge { largeFile.unlock() }
                let bytes = if case .put(let doc) = r { doc.text.utf8.count } else { 0 }
                extracted.withLock { $0 += bytes }
                lock.lock(); results[i] = r; lock.unlock()
            }
        }
        for (p, r) in zip(toExtract, results) { outcomes.append((p.task, r ?? .retry(after: 0, error: nil, countAttempt: false))) }
        results = []  // `outcomes` is now the only owner of the texts; staging releases them
        try stageAndCommit(&outcomes)
    }

    private func diskVersion(_ path: String) -> FileVersion? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileVersion(size: Int64(st.st_size), mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), ino: Int64(bitPattern: UInt64(st.st_ino)))
    }

    private func extract(_ p: Prepared, worker: ExtractionWorker) -> Staged {
        let interrupted = Staged.retry(after: 0, error: nil, countAttempt: false)
        if stopped { return interrupted }
        // Before: the file must still be what the catalog recorded for this op.
        guard diskVersion(p.path) == p.version else { return .retry(after: 2, error: nil, countAttempt: false) }
        let dir = (p.path as NSString).deletingLastPathComponent
        let type = ContentType.of(name: p.info.name)
        // §10 cache key: strong digest + extractor version + config. Same key → reuse the stored
        // extraction (moves, renames, copies) instead of parsing again.
        // Not for a file over the limit (the extractor refuses or truncates it after a moment; an
        // archive's limit is per member), and no longer than its extraction may take.
        let timeout = baseTimeout + Double(p.version.size) / Double(1 << 20) * 2
        let hashable = type == .archive || UInt64(max(0, p.version.size)) <= limits.maxFileBytes
        let hashDeadline = Date().addingTimeInterval(timeout)
        let digest = hashable ? Self.digest(p.path, cancelled: { self.stopped || Date() > hashDeadline }) : nil
        let key = digest.map { "\($0):\(type?.rawValue ?? "?"):v\(type.map(Extractor.version) ?? 0):\(limits.maxFileBytes):\(limits.maxUnpackedBytes)" } ?? ""
        if stopped { return interrupted }
        if !key.isEmpty, let cached = (try? writer?.findByExtractKey(key: key)) ?? nil {
            // The digest describes what was read: the file must not have changed since.
            guard diskVersion(p.path) == p.version else { return .retry(after: 2, error: nil, countAttempt: false) }
            lock.withLock { cacheHits += 1 }
            return .put(ContentInput(fileId: UInt64(p.task.fileId), opSeq: UInt64(p.task.opSeq), revision: UInt64(bitPattern: p.version.mtimeNs),
                                     extractorVer: type.map(Extractor.version) ?? 0, scopeIds: [1], dir: dir, name: p.info.name,
                                     size: p.version.size, mtime: p.version.mtimeNs / 1_000_000_000, text: cached.text,
                                     anchorsJson: cached.anchorsJson, pagesJson: cached.pagesJson, state: cached.state, extractKey: key))
        }
        let outcome = worker.extract(path: p.path, limits: limits, timeout: timeout, fault: workerFault?(p.path))
        if outcome == .cancelled { return interrupted }
        afterExtract?(p.path)
        // After: changed during extraction → the result describes neither version.
        guard diskVersion(p.path) == p.version else { return .retry(after: 2, error: nil, countAttempt: false) }
        switch outcome {
        case .extracted(let r):
            return .put(ContentInput(fileId: UInt64(p.task.fileId), opSeq: UInt64(p.task.opSeq), revision: UInt64(bitPattern: p.version.mtimeNs),
                                     extractorVer: r.extractorVersion, scopeIds: [1], dir: dir, name: p.info.name,
                                     size: p.version.size, mtime: p.version.mtimeNs / 1_000_000_000, text: r.text,
                                     anchorsJson: r.anchorsJSON, pagesJson: r.pagesJSON, state: ExtractStateKind(code: r.state), extractKey: key))
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return interrupted
        case .tooMuchMemory:
            return .failed("解析占用内存过多，已隔离")
        case .timedOut, .crashed:
            let reason = outcome == .timedOut ? "解析超时" : "解析器崩溃"
            if p.task.attempts + 1 >= maxAttempts { return .failed("\(reason)，已隔离") }
            return .retry(after: backoffBase * pow(4, Double(p.task.attempts)), error: reason, countAttempt: true)
        }
    }

    // MARK: Commit protocol

    private func stageAndCommit(_ outcomes: inout [(Task, Staged)]) throws {
        guard let catalog, let writer else { return }
        var staged: [(Task, Staged)] = []
        var stagedSeq: [UInt64: UInt64] = [:]
        var finished: [(Task, Staged)] = []
        for i in outcomes.indices {
            let (t, s) = outcomes[i]
            outcomes[i].1 = .drop  // this entry's text must not outlive the call below
            let fid = UInt64(t.fileId), seq = UInt64(t.opSeq)
            switch s {
            case .put, .remove, .failed:
                // Sequence fence: never apply an op that is not newer than what the index has.
                if seq <= max(committedSeq[fid] ?? 0, stagedSeq[fid] ?? 0) { finished.append((t, .drop)); continue }
                stagedSeq[fid] = seq
                switch s {
                case .put(let doc):
                    try writer.put(doc: doc)
                    staged.append((t, .written(doc.state)))
                default:
                    try writer.remove(fileId: fid, opSeq: seq)  // failed: stale text must not stay
                    staged.append((t, s))
                }
            case .written:
                break  // only ever made here
            case .drop, .retry:
                finished.append((t, s))
            }
        }
        try finishWithoutIndex(finished)
        guard !staged.isEmpty else { return }
        try check(.afterStage)

        // Re-validate before publishing: still the latest op.
        var invalid = false
        for (t, _) in staged {
            let s = try catalog.db.prepare("""
                SELECT COALESCE(f.op_seq, t.op_seq) FROM content_tasks t LEFT JOIN files f ON f.id = t.file_id
                WHERE t.file_id = ? AND t.op_seq = ? AND t.kind = ?
                """).bind(t.fileId, t.opSeq, t.kind.rawValue)
            let ok = try s.first { s in s.int(0) == t.opSeq } ?? false
            if !ok { invalid = true; break }
        }
        if invalid {
            try writer.rollback()
            committedSeq = try writer.appliedSeqs()
            // Superseded ones are dropped by the next claim's op_seq check.
            try catalog.db.exec("UPDATE content_tasks SET state = 0 WHERE state = 1")
            return
        }

        let batch = lastBatch + 1
        try catalog.db.transaction {
            try catalog.db.exec("DELETE FROM content_batch")
            let ins = try catalog.db.prepare("INSERT INTO content_batch(file_id, op_seq, kind, state, error) VALUES(?, ?, ?, ?, ?)")
            for (t, s) in staged {
                let (code, error): (Int64, String?) = switch s {
                case .written(let state): (Self.stateCode(state), nil)
                case .failed(let msg): (4, msg)
                default: (0, nil)
                }
                try ins.bind(t.fileId, t.opSeq, t.kind.rawValue, code, error).run()
                ins.reset()
            }
            try catalog.setMeta("content_batch_pending", String(batch))
        }
        try check(.afterBatchRecorded)
        do {
            try writer.commit(batchId: batch)
        } catch {
            // Commit outcome uncertain: reopen and read what the index says.
            self.writer = nil
            try openWriter()
            guard lastBatch == batch else {
                try catalog.db.transaction {
                    try catalog.db.exec("DELETE FROM content_batch")
                    try catalog.setMeta("content_batch_pending", nil)
                    try catalog.db.exec("UPDATE content_tasks SET state = 0 WHERE state = 1")
                }
                return
            }
        }
        try check(.afterIndexCommit)
        try confirm(batch: batch)
        for (fid, seq) in stagedSeq { committedSeq[fid] = seq }
        lastBatch = batch
        state.withLock { $0.committedBatches = batch }
        try check(.afterConfirm)
    }

    /// SQLite side of a committed batch: tasks done, per-file content state recorded.
    private func confirm(batch: UInt64) throws {
        guard let catalog else { return }
        try catalog.db.transaction {
            try catalog.db.exec("""
                UPDATE files SET content_state = (SELECT b.state FROM content_batch b WHERE b.file_id = files.id),
                  content_error = (SELECT b.error FROM content_batch b WHERE b.file_id = files.id)
                WHERE id IN (SELECT file_id FROM content_batch)
                """)
            try catalog.db.exec("""
                UPDATE content_tasks SET state = 2 WHERE EXISTS (SELECT 1 FROM content_batch b
                    WHERE b.file_id = content_tasks.file_id AND b.op_seq = content_tasks.op_seq AND b.kind = content_tasks.kind)
                """)
            try catalog.db.exec("DELETE FROM content_batch")
            try catalog.setMeta("content_batch_confirmed", String(batch))
            try catalog.setMeta("content_batch_pending", nil)
            // Done tasks are history; keep the table small.
            try catalog.db.exec("DELETE FROM content_tasks WHERE state = 2")
        }
        lastBatch = max(lastBatch, batch)
    }

    static func stateCode(_ s: ExtractStateKind) -> Int64 {
        switch s {
        case .complete: 1
        case .partial: 2
        case .waitingOcr: 3
        case .failed: 4
        }
    }

    private func finishWithoutIndex(_ items: [(Task, Staged)]) throws {
        guard let catalog, !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try catalog.db.transaction {
            for (t, s) in items {
                switch s {
                case .drop:
                    try catalog.db.prepare("DELETE FROM content_tasks WHERE file_id = ? AND op_seq = ? AND kind = ?").bind(t.fileId, t.opSeq, t.kind.rawValue).run()
                case .retry(let after, let error, let countAttempt):
                    try catalog.db.prepare("""
                        UPDATE content_tasks SET state = 0, lease_until = 0, not_before = ?, attempts = attempts + ?, error = ?
                        WHERE file_id = ? AND op_seq = ? AND kind = ?
                        """).bind(now + after, countAttempt ? 1 : 0, error, t.fileId, t.opSeq, t.kind.rawValue).run()
                default:
                    break
                }
            }
        }
    }

    /// Pending comes from the small task table, every cycle. The per-file figures change only
    /// through tasks this indexer processes, so they are recounted then (and every 30 s).
    private func refreshCounts(full: Bool = true) throws {
        guard let catalog else { return }
        let p = try catalog.db.prepare("SELECT COUNT(*) FROM content_tasks WHERE state IN (0, 1)")
        let pending = try p.first { p in Int(p.int(0)) } ?? 0
        guard full else {
            catalog.db.resetStatements()
            state.withLock { $0.pending = pending }
            return
        }
        lastFullCount = Date()
        let f = try catalog.db.prepare("SELECT COUNT(*) FROM files WHERE deleted = 0 AND in_content = 1 AND content_state = 4")
        let failed = try f.first { f in Int(f.int(0)) } ?? 0
        let i = try catalog.db.prepare("SELECT COUNT(*) FROM files WHERE deleted = 0 AND in_content = 1 AND content_state IN (1, 2, 3)")
        let indexed = try i.first { i in Int(i.int(0)) } ?? 0
        catalog.db.resetStatements()
        state.withLock { $0.pending = pending; $0.failed = failed; $0.indexed = indexed }
    }
}

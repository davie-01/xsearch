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
/// 3. before committing, every staged task must still be the file's latest op and hold a valid
///    lease, otherwise the whole batch is rolled back and the sequence table rebuilt;
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

        public init(pending: Int = 0, failed: Int = 0, indexed: Int = 0, committedBatches: UInt64 = 0, running: Bool = false) {
            self.pending = pending
            self.failed = failed
            self.indexed = indexed
            self.committedBatches = committedBatches
            self.running = running
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
    private var stopped = true
    private var cycling = false
    /// Committed op_seq per file (rebuilt from the index on open and after rollbacks).
    private var committedSeq: [UInt64: UInt64] = [:]
    private var lastBatch: UInt64 = 0
    public private(set) var instanceId = ""

    // Tunables (tests shorten them).
    var leaseSeconds: TimeInterval = 600
    var backoffBase: TimeInterval = 30
    var maxAttempts = 3
    var batchSize = 64
    /// Per-file extraction timeout = base + 2 s per MB.
    var baseTimeout: TimeInterval = 30
    var limits = ExtractionLimits()
    /// Test hooks: crash at a protocol step; inject a worker fault for a path; run between
    /// extraction and staging (to change the file mid-flight).
    var fault: ((Fault) -> Bool)?
    var workerFault: ((String) -> String?)?
    var afterExtract: ((String) -> Void)?
    /// Extractions served from the cache (tests, diagnostics).
    private(set) var cacheHits = 0
    private let lock = NSLock()

    static func digest(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
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
    public var indexURL: URL { directory.appendingPathComponent("content").appendingPathComponent(instanceId) }
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
            try openWriter()
            try recover()
            try reindexUpgradedExtractors()
            stopped = false
            state.withLock { $0.running = true }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.cycle() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            writer = nil
            catalog = nil
            workers.forEach { $0.stop() }
            state.withLock { $0.running = false }
        }
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

    // MARK: Versions and rebuild

    static func extractorFingerprint() -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: ContentType.allCases.map { ($0.rawValue, Extractor.version(of: $0)) })
    }

    /// Bumps op_seq and queues an index task for content files whose name passes `filter`.
    private func requeue(where filter: (String) -> Bool) throws -> Int {
        guard let catalog else { return 0 }
        return try catalog.db.transaction {
            let s = try catalog.db.prepare("SELECT id, name, mtime_ns FROM files WHERE deleted = 0 AND in_content = 1")
            var rows: [(Int64, String, Int64)] = []
            while try s.step() { rows.append((s.int(0), s.text(1), s.int(2))) }
            var counter = try catalog.opSeqCounter()
            var n = 0
            for (id, name, mtime) in rows where filter(name) {
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
                _ = try requeue { name in ContentType.of(name: name).map { changed.contains($0.rawValue) } ?? false }
            }
        }
        try catalog.setMeta("content_extractors", String(decoding: try JSONEncoder().encode(current), as: UTF8.self))
    }

    /// Rebuilds the content index into a new instance (§9.3 step 7, simplified): the writer moves
    /// to the new instance and every content file is re-queued; readers keep the old instance
    /// until the new one has caught up, then the active instance switches and the old
    /// directory is deleted (disk space reclaimed, §6.2).
    public func rebuildContentIndex() throws {
        try queue.sync {
            guard let catalog, rebuildId == nil else { return }
            let id = UUID().uuidString
            try catalog.setMeta("content_rebuild_instance", id)
            rebuildId = id
            writer = nil
            try openWriter()
            _ = try requeue { _ in true }
            try refreshCounts()
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
        try? FileManager.default.removeItem(at: old)
    }

    /// Startup: resolve the unconfirmed batch, release leases of the previous process.
    private func recover() throws {
        guard let catalog, let writer else { return }
        let pending = try catalog.meta("content_batch_pending").flatMap(UInt64.init)
        let confirmed = try catalog.meta("content_batch_confirmed").flatMap(UInt64.init) ?? 0
        if let pending, pending > confirmed {
            if try writer.lastCommit()?.batchId == pending {
                try confirm(batch: pending)  // committed, confirmation lost
            } else {
                try catalog.db.transaction {
                    try catalog.db.exec("DELETE FROM content_batch")
                    try catalog.setMeta("content_batch_pending", nil)
                }
            }
        }
        // Only this process indexes: every lease left behind is dead.
        try catalog.db.exec("UPDATE content_tasks SET state = 0, lease_until = 0 WHERE state = 1")
        try refreshCounts()
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
        case remove
        /// Superseded / stale: finish the task without touching the index.
        case drop
        /// Try again later (file changed during extraction, transient worker failure).
        case retry(after: TimeInterval, error: String?, countAttempt: Bool)
        /// Give up on this file (extraction error, or too many timeouts / crashes).
        case failed(String)
    }

    private func readyCount() throws -> Int {
        guard let catalog else { return 0 }
        let s = try catalog.db.prepare("SELECT COUNT(*) FROM content_tasks WHERE state = 0 AND not_before <= ?").bind(Date().timeIntervalSince1970)
        return try s.first { s in Int(s.int(0)) } ?? 0
    }

    private func cycle() {
        guard !stopped, !cycling, catalog != nil else { return }
        cycling = true
        defer { cycling = false }
        do {
            while !stopped {
                let tasks = try claim(limit: batchSize)
                if tasks.isEmpty { break }
                try process(tasks)
            }
            try refreshCounts()
            try finishRebuildIfCaughtUp()
        } catch is Crash {
            crash()
        } catch {
            // Unexpected I/O or SQLite error: drop staged work; the next cycle starts clean.
            try? writer?.rollback()
            committedSeq = (try? writer?.appliedSeqs()) ?? committedSeq
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
            // Deletions first (stale text must disappear), then newest files first (§9.2).
            let s = try catalog.db.prepare("""
                SELECT file_id, op_seq, kind, attempts FROM content_tasks WHERE state = 0 AND not_before <= ?
                ORDER BY kind DESC, priority DESC LIMIT ?
                """).bind(now, limit)
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
            guard let info = try catalog.contentInfo(t.fileId) else { outcomes.append((t, .drop)); continue }
            // Superseded: a newer op for this file exists (its own task will handle it).
            if info.opSeq != t.opSeq { outcomes.append((t, .drop)); continue }
            if t.kind == .delete || info.deleted || !info.inContent { outcomes.append((t, .remove)); continue }
            guard let path = try catalog.path(of: t.fileId), let row = try catalog.row(id: t.fileId) else { outcomes.append((t, .remove)); continue }
            toExtract.append(Prepared(task: t, path: path, info: info, version: FileVersion(size: row.size, mtimeNs: row.mtimeNs, ino: row.ino)))
        }
        // Extract in parallel, one file per worker at a time.
        var results = [Staged?](repeating: nil, count: toExtract.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(workerCount, max(1, toExtract.count))) { w in
            var i = w
            while i < toExtract.count {
                let r = extract(toExtract[i], worker: workers[w])
                lock.lock(); results[i] = r; lock.unlock()
                i += workerCount
            }
        }
        for (p, r) in zip(toExtract, results) { outcomes.append((p.task, r ?? .retry(after: 1, error: nil, countAttempt: false))) }
        try stageAndCommit(outcomes)
    }

    private func diskVersion(_ path: String) -> FileVersion? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileVersion(size: Int64(st.st_size), mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), ino: Int64(bitPattern: UInt64(st.st_ino)))
    }

    private func extract(_ p: Prepared, worker: ExtractionWorker) -> Staged {
        // Before: the file must still be what the catalog recorded for this op.
        guard diskVersion(p.path) == p.version else { return .retry(after: 2, error: nil, countAttempt: false) }
        let dir = (p.path as NSString).deletingLastPathComponent
        let type = ContentType.of(name: p.info.name)
        // §10 cache key: strong digest + extractor version + config. Same key → reuse the stored
        // extraction (moves, renames, copies) instead of parsing again.
        let key = Self.digest(p.path).map { "\($0):\(type?.rawValue ?? "?"):v\(type.map(Extractor.version) ?? 0):\(limits.maxFileBytes)" } ?? ""
        if !key.isEmpty, let cached = (try? writer?.findByExtractKey(key: key)) ?? nil {
            lock.withLock { cacheHits += 1 }
            return .put(ContentInput(fileId: UInt64(p.task.fileId), opSeq: UInt64(p.task.opSeq), revision: UInt64(bitPattern: p.version.mtimeNs),
                                     extractorVer: type.map(Extractor.version) ?? 0, scopeIds: [1], dir: dir, name: p.info.name,
                                     size: p.version.size, mtime: p.version.mtimeNs / 1_000_000_000, text: cached.text,
                                     anchorsJson: cached.anchorsJson, pagesJson: cached.pagesJson, state: cached.state, extractKey: key))
        }
        let timeout = baseTimeout + Double(p.version.size) / Double(1 << 20) * 2
        let outcome = worker.extract(path: p.path, limits: limits, timeout: timeout, fault: workerFault?(p.path))
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
        case .timedOut, .crashed:
            let reason = outcome == .timedOut ? "解析超时" : "解析器崩溃"
            if p.task.attempts + 1 >= maxAttempts { return .failed("\(reason)，已隔离") }
            return .retry(after: backoffBase * pow(4, Double(p.task.attempts)), error: reason, countAttempt: true)
        }
    }

    // MARK: Commit protocol

    private func stageAndCommit(_ outcomes: [(Task, Staged)]) throws {
        guard let catalog, let writer else { return }
        var staged: [(Task, Staged)] = []
        var stagedSeq: [UInt64: UInt64] = [:]
        var finished: [(Task, Staged)] = []
        for (t, s) in outcomes {
            let fid = UInt64(t.fileId), seq = UInt64(t.opSeq)
            switch s {
            case .put, .remove, .failed:
                // Sequence fence: never apply an op that is not newer than what the index has.
                if seq <= max(committedSeq[fid] ?? 0, stagedSeq[fid] ?? 0) { finished.append((t, .drop)); continue }
                switch s {
                case .put(let doc): try writer.put(doc: doc)
                default: try writer.remove(fileId: fid, opSeq: seq)  // failed: stale text must not stay
                }
                stagedSeq[fid] = seq
                staged.append((t, s))
            case .drop, .retry:
                finished.append((t, s))
            }
        }
        try finishWithoutIndex(finished)
        guard !staged.isEmpty else { return }
        try check(.afterStage)

        // Re-validate before publishing: still the latest op, lease still valid.
        let now = Date().timeIntervalSince1970
        var invalid = false
        for (t, _) in staged {
            let s = try catalog.db.prepare("""
                SELECT f.op_seq, t.lease_until FROM files f JOIN content_tasks t ON t.file_id = f.id
                WHERE f.id = ? AND t.op_seq = ? AND t.kind = ?
                """).bind(t.fileId, t.opSeq, t.kind.rawValue)
            let ok = try s.first { s in s.int(0) == t.opSeq && s.double(1) > now } ?? false
            if !ok { invalid = true; break }
        }
        if invalid {
            try writer.rollback()
            committedSeq = try writer.appliedSeqs()
            // Superseded ones are dropped by the next claim's op_seq check; expired leases requeue.
            try catalog.db.exec("UPDATE content_tasks SET state = 0 WHERE state = 1")
            return
        }

        let batch = lastBatch + 1
        try catalog.db.transaction {
            try catalog.db.exec("DELETE FROM content_batch")
            let ins = try catalog.db.prepare("INSERT INTO content_batch(file_id, op_seq, kind, state, error) VALUES(?, ?, ?, ?, ?)")
            for (t, s) in staged {
                let (code, error): (Int64, String?) = switch s {
                case .put(let doc): (Self.stateCode(doc.state), nil)
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

    private func refreshCounts() throws {
        guard let catalog else { return }
        let p = try catalog.db.prepare("SELECT COUNT(*) FROM content_tasks WHERE state IN (0, 1)")
        let pending = try p.first { p in Int(p.int(0)) } ?? 0
        let f = try catalog.db.prepare("SELECT COUNT(*) FROM files WHERE deleted = 0 AND in_content = 1 AND content_state = 4")
        let failed = try f.first { f in Int(f.int(0)) } ?? 0
        let i = try catalog.db.prepare("SELECT COUNT(*) FROM files WHERE deleted = 0 AND in_content = 1 AND content_state IN (1, 2, 3)")
        let indexed = try i.first { i in Int(i.int(0)) } ?? 0
        catalog.db.resetStatements()
        state.withLock { $0.pending = pending; $0.failed = failed; $0.indexed = indexed }
    }
}

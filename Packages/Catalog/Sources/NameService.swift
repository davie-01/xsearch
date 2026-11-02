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
        /// false: file changes are not being followed (FSEvents could not start); retried.
        public var watching = true
    }

    public let directory: URL
    public let home: String
    private let queue = DispatchQueue(label: "xsearch.catalog", qos: .utility)
    private let mergeQueue = DispatchQueue(label: "xsearch.names.merge", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var catalog: FileCatalog?
    private var watcher: FSEventsWatcher?
    private var watcherRetry: DispatchWorkItem?
    var watcherDelay: TimeInterval = 5
    /// Test hook: this many watcher starts fail.
    var failWatcherStarts = 0
    private var scope = NameScope.default
    /// nil: content indexing disabled.
    private var contentScope: ContentScope?
    private var context: Reconciler.Context?
    private var persistedSeq: Int64 = -1
    private var lastPersist = Date.distantPast
    private var persistTimer: DispatchSourceTimer?
    private var processing = false
    /// Newest event id seen but not yet written (see `received`).
    private var unsavedCursor: UInt64?
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
        var catalogId: String?
    }

    /// Called on an internal queue when content tasks wait for the indexer.
    public var onContentTasks: (@Sendable () -> Void)?
    /// Identity of the open catalog: file ids mean something only within it.
    public var catalogId: String? { state.withLock { $0.catalogId } }

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

    public func start(scope: NameScope, content: ContentScope? = nil) {
        queue.async { [self] in
            do { try open(scope: scope, content: content) } catch { fail(error) }
        }
    }

    public func setScope(_ scope: NameScope) {
        queue.async { [self] in setScopes(scope, content: contentScope) }
    }

    /// Changes the content scope: one reconcile re-decides which files are content-indexed and
    /// writes index / delete tasks for the difference (§6.2).
    public func setContentScope(_ content: ContentScope?) {
        queue.async { [self] in setScopes(scope, content: content) }
    }

    /// On `queue`: the other half of the settings is read there, so two quick changes in a row
    /// both take effect.
    private func setScopes(_ scope: NameScope, content: ContentScope?) {
        do {
            guard let catalog else { return }
            self.scope = scope
            contentScope = content
            context = makeContext(scope)
            saveCursor()
            try catalog.append([(.scope, "", 0)], lastEventId: nil)
            try catalog.setMeta("fingerprint", fingerprint())
            restartWatcher(since: try catalog.meta("fsevents_last_id").flatMap(UInt64.init) ?? FSEventsWatcher.currentEventId)
            process()
        } catch { fail(error) }
    }

    /// Stops watching, folds the overlay and writes the snapshot. Safe to call more than once.
    public func shutdown() {
        queue.sync {
            persistTimer?.cancel(); persistTimer = nil
            watcher?.stop(); watcher = nil
            saveCursor()
            mergeQueue.sync {}
            try? persist(force: true)
            try? catalog?.db.checkpoint()
        }
    }

    /// One line of "为什么搜不到" (UI-SPEC §6.4): what was checked, the outcome, what to do.
    public struct DiagnosisItem: Sendable, Equatable {
        public enum Level: Sendable { case ok, warning, problem }
        public var label: String
        public var level: Level
        public var detail: String
    }

    /// Explains where a path stands in both indexes (ARCHITECTURE §6.2 diagnostics).
    public func diagnose(_ rawPath: String) -> [DiagnosisItem] {
        let path = PathUtil.standardize((rawPath as NSString).expandingTildeInPath)
        return queue.sync {
            guard let catalog, let context else { return [DiagnosisItem(label: "索引", level: .problem, detail: "索引尚未打开")] }
            var out: [DiagnosisItem] = []
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                return [DiagnosisItem(label: "文件", level: .problem, detail: "路径不存在（可能已被移动或删除）")]
            }
            let name = (path as NSString).lastPathComponent
            let probe = Reconciler(catalog: catalog, context: context, seq: 0, publish: { _ in })
            // 1. File-name scope.
            let inRoots = context.roots.contains { PathUtil.isWithin(path, $0) }
            var row: Row?
            if inRoots, let root = try? catalog.rootRows().filter({ PathUtil.isWithin(path, $0.name) }).max(by: { $0.name.count < $1.name.count }),
               let (r, rp) = try? catalog.nearest(path, root: root), rp == path {
                row = r
            } else if inRoots, let root = try? catalog.rootRows().filter({ PathUtil.isWithin(path, $0.name) }).max(by: { $0.name.count < $1.name.count }) {
                let parent = (path as NSString).deletingLastPathComponent
                if let (dirRow, dp) = try? catalog.nearest(parent, root: root), dp == parent { row = try? catalog.child(of: dirRow.id, named: name) }
            }
            if !context.nameRoots.contains(where: { PathUtil.isWithin(path, $0) }) {
                out.append(.init(label: "文件名范围", level: .problem, detail: "不在文件名索引范围内。在 设置 › 索引范围 中把它所在的文件夹加入。"))
            } else if !probe.isInNameScope(path) || ((name.hasPrefix(".")) && !context.rules.includeHidden) {
                out.append(.init(label: "文件名范围", level: .problem, detail: "被排除规则排除（或是隐藏文件）。在 设置 › 索引范围 › 排除规则 中调整。"))
            } else if row == nil {
                out.append(.init(label: "文件名范围", level: .warning, detail: "在范围内，但还没有进入索引：可能正在扫描，稍后再试。"))
            } else {
                out.append(.init(label: "文件名范围", level: .ok, detail: "已在文件名索引中，可以按名称搜到。"))
            }
            // 2. Access.
            if fm.isReadableFile(atPath: path) {
                out.append(.init(label: "访问权限", level: .ok, detail: "XSearch 可以读取这个文件。"))
            } else {
                out.append(.init(label: "访问权限", level: .problem, detail: "没有读取权限。可在 系统设置 › 隐私与安全性 中为 XSearch 授予文件访问或完全磁盘访问权限。"))
            }
            // 3. Content scope.
            guard let rules = context.content else {
                out.append(.init(label: "内容范围", level: .warning, detail: "内容索引未开启。"))
                return out
            }
            if isDir.boolValue {
                out.append(.init(label: "内容范围", level: .warning, detail: "这是文件夹；内容索引只提取其中的文件。"))
                return out
            }
            if !rules.roots.contains(where: { PathUtil.isWithin(path, $0) }) {
                out.append(.init(label: "内容范围", level: .problem, detail: "不在内容索引范围内。把 \(PathUtil.abbreviate((path as NSString).deletingLastPathComponent, home: home)) 加入内容范围后即可搜索正文。"))
                return out
            }
            guard ContentType.of(name: name) != nil else {
                out.append(.init(label: "内容范围", level: .problem, detail: "暂不支持提取这种文件类型（.\((name as NSString).pathExtension)）。"))
                return out
            }
            guard rules.eligible(path: path, name: name, isDirectory: false) else {
                out.append(.init(label: "内容范围", level: .problem, detail: "被内容范围的排除规则或类型设置排除。"))
                return out
            }
            out.append(.init(label: "内容范围", level: .ok, detail: "在内容索引范围内。"))
            // 4. Extraction state.
            guard let row, let s = try? catalog.db.prepare("SELECT content_state, content_error, op_seq FROM files WHERE id = ?").bind(row.id),
                  let (state, error, opSeq) = try? s.first({ s in (s.int(0), s.isNull(1) ? nil : s.text(1), s.int(2)) }) else {
                out.append(.init(label: "提取状态", level: .warning, detail: "还没有进入内容任务队列。"))
                return out
            }
            let queued = (try? catalog.db.prepare("SELECT 1 FROM content_tasks WHERE file_id = ? AND op_seq = ?").bind(row.id, opSeq).first { _ in true }) ?? nil
            switch (state, queued != nil) {
            case (_, true): out.append(.init(label: "提取状态", level: .warning, detail: "索引待更新：已排队，正在等待提取。"))
            case (1, _): out.append(.init(label: "提取状态", level: .ok, detail: "已提取并建立内容索引。"))
            case (2, _): out.append(.init(label: "提取状态", level: .warning, detail: "部分索引：只提取到一部分文字（超出大小上限或文字层有缺失）。"))
            case (3, _): out.append(.init(label: "提取状态", level: .warning, detail: "等待 OCR：没有文字层，OCR 在后续版本提供。"))
            case (4, _): out.append(.init(label: "提取状态", level: .problem, detail: "提取失败：\(error ?? "未知原因")"))
            default: out.append(.init(label: "提取状态", level: .warning, detail: "还没有建立内容索引。"))
            }
            let mtime = row.mtimeNs / 1_000_000_000
            out.append(.init(label: "最近修改", level: .ok, detail: Self.dateText(mtime)))
            return out
        }
    }

    static func dateText(_ seconds: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    struct TaskRow: Equatable { var fileId: Int64; var opSeq: Int64; var kind: Int64; var state: Int64 }

    /// Test / diagnostics: content tasks and the file each belongs to.
    func contentTasks() -> [(task: TaskRow, path: String?)] {
        queue.sync {
            guard let catalog, let s = try? catalog.db.prepare("SELECT file_id, op_seq, kind, state FROM content_tasks ORDER BY op_seq") else { return [] }
            var out: [(TaskRow, String?)] = []
            while (try? s.step()) == true {
                out.append((TaskRow(fileId: s.int(0), opSeq: s.int(1), kind: s.int(2), state: s.int(3)), nil))
            }
            return out.map { ($0.0, try? catalog.path(of: $0.0.fileId)) }
        }
    }

    /// Test / diagnostics: per-file content state and error.
    func contentStates() -> [(name: String, state: Int64, error: String?)] {
        queue.sync {
            guard let catalog, let s = try? catalog.db.prepare("SELECT name, content_state, content_error FROM files WHERE in_content = 1 AND deleted = 0") else { return [] }
            var out: [(String, Int64, String?)] = []
            while (try? s.step()) == true { out.append((s.text(0), s.int(1), s.isNull(2) ? nil : s.text(2))) }
            catalog.db.resetStatements()
            return out
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
        // One catalog covers the union of both scopes (§6.2): content folders outside the name
        // scope are scanned too.
        var roots = scope.roots(home: home)
        for r in contentScope?.roots(home: home) ?? [] where !roots.contains(where: { PathUtil.isWithin(r, $0) }) {
            roots.removeAll { PathUtil.isWithin($0, r) }
            roots.append(r)
        }
        return .init(roots: roots.sorted(), nameRoots: scope.roots(home: home), rules: ExclusionRules(s, home: home), home: home,
                     content: contentScope.map { ContentRules($0, home: home) })
    }

    private func fingerprint() -> String {
        // "m2": rows carry the content-only flag; older catalogs need one pass to set it.
        "m2\u{3}" + scope.fingerprint(home: home) + "\u{3}" + (contentScope?.fingerprint(home: home) ?? "no-content")
    }

    private func open(scope: NameScope, content: ContentScope?) throws {
        self.scope = scope
        contentScope = content
        context = makeContext(scope)
        let catalog: FileCatalog
        do {
            catalog = try FileCatalog(url: directory.appendingPathComponent("catalog.sqlite"))
        } catch is Migrations.NewerFormat {
            // Downgrade: the catalog (like the name and content indexes built from it) is
            // rebuildable; start over instead of misreading a newer layout.
            for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "names", "content"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            catalog = try FileCatalog(url: directory.appendingPathComponent("catalog.sqlite"))
        }
        self.catalog = catalog
        if try catalog.meta("catalog_id") == nil { try catalog.setMeta("catalog_id", UUID().uuidString) }
        let catalogId = try catalog.meta("catalog_id")!
        state.withLock { $0.catalogId = catalogId }
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
        let fingerprint = fingerprint()
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
        timer.setEventHandler { [weak self] in
            self?.saveCursor()
            try? self?.persist(force: false)
        }
        timer.resume()
        persistTimer = timer
        process()
    }

    private func restartWatcher(since: UInt64) {
        watcher?.stop()
        watcherRetry?.cancel()
        watcherRetry = nil
        guard let roots = context?.roots, !roots.isEmpty else {
            watcher = nil
            updateStatus { $0.watching = true }
            return
        }
        watcher = FSEventsWatcher(paths: roots, since: since, latency: 0.3, queue: queue) { [weak self] events in
            self?.received(events)
        }
        if failWatcherStarts == 0, watcher?.start() == true {
            // Back after a failure: what happened meanwhile is in the history from `since`.
            watcherDelay = 5
            updateStatus { $0.watching = true }
            return
        }
        failWatcherStarts = max(0, failWatcherStarts - 1)
        watcher = nil
        // Without a stream we cannot keep up; reconcile on next start instead of trusting the cursor.
        try? catalog?.setMeta("fsevents_uuids", "")
        updateStatus { $0.watching = false }
        let retry = DispatchWorkItem { [weak self] in self?.restartWatcher(since: since) }
        watcherRetry = retry
        queue.asyncAfter(deadline: .now() + watcherDelay, execute: retry)
        watcherDelay = min(watcherDelay * 2, 300)
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
        // Watching "/" reports every file change on the system. Events that concern nothing
        // only move the cursor in memory: writing it (with fsync) each time cost about three
        // database writes per second at idle. Losing it in a crash replays events that are
        // filtered out again.
        guard !ops.isEmpty else {
            unsavedCursor = maxId
            return
        }
        do {
            try catalog.append(ops, lastEventId: maxId)
            unsavedCursor = nil
            process()
        } catch { fail(error) }
    }

    /// Runs on `queue`: the 30 s timer, scope changes, shutdown.
    private func saveCursor() {
        guard let cursor = unsavedCursor, let catalog else { return }
        if (try? catalog.setMeta("fsevents_last_id", String(cursor))) != nil { unsavedCursor = nil }
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
            let waiting = try catalog.db.prepare("SELECT 1 FROM content_tasks WHERE state = 0 LIMIT 1")
            if try waiting.first({ _ in true }) == true { onContentTasks?() }
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

import ContentEngine
import Foundation
import XSearchCore

/// One delivery of content results (first screen, or a later progressive batch).
struct ContentOutput: @unchecked Sendable {
    var text: String
    var query: ContentQuery
    var hits: [ContentHit]
    /// false: replace the list; true: append to it.
    var append: Bool
    var recall: RecallKind?
    var verified: UInt64
    var candidates: UInt64
    var done: Bool
    /// Stopped at the result limit: more matches may exist.
    var capped = false
    var error: String?
    /// Live scan batch (§8.7): files without a content index, read directly.
    var live = false
    var scanned = 0
    var scanTotal = 0
}

/// A file for the live scan, taken from the name index.
struct LiveFile: Sendable {
    var fileId: Int64
    var path: String
    var size: Int64
    var mtime: Int64
}

struct PreviewData: @unchecked Sendable {
    var document: ContentDocument
    /// The first hits, at most `ContentSearcher.previewHitCap`.
    var highlights: [Utf16Range]
    var totalHits: UInt64
}

/// Content QuerySession (ARCHITECTURE §5, UI-SPEC §6.1): starts ~80 ms after typing stops, a
/// new input cancels the running query, the first verified screen comes from a short budget,
/// later batches keep arriving until the query is complete (or 1,000 results are shown).
final class ContentSearcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "xsearch.content", qos: .userInteractive)
    private let previewQueue = DispatchQueue(label: "xsearch.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    /// Only the newest preview is worth computing: older ones waiting in the queue are skipped.
    private var previewGeneration = 0
    private var current: ContentSearch?
    private var pendingWork: DispatchWorkItem?
    private var index: ContentIndex?
    private var openedPath: String?
    /// Where the active index instance lives (set once the indexer has started).
    var indexPath: (@Sendable () -> String?)?
    /// Another searcher whose reader to use: one reader per index, whichever window asks.
    var indexSource: ContentSearcher?
    var mode: MatchMode = .loose
    /// Live scan and its preview follow the single-file limit in the settings.
    var maxFileBytes: UInt64 = 100 << 20

    static let resultCap = 1000
    /// A one-letter query can hit millions of times; only this many are mapped and listed.
    static let previewHitCap: UInt64 = 5000

    /// Opens (or reopens after an instance switch) the reader. nil until the indexer committed once.
    func openIndex() -> ContentIndex? {
        if let indexSource { return indexSource.openIndex() }
        lock.lock()
        defer { lock.unlock() }
        guard let path = indexPath?() else { return nil }
        if openedPath != path || index == nil {
            index = try? ContentIndex.open(path: path)
            openedPath = index == nil ? nil : path
        }
        return index
    }

    func cancel() {
        lock.lock()
        generation += 1
        previewGeneration += 1
        current?.cancel()
        current = nil
        pendingWork?.cancel()
        pendingWork = nil
        lock.unlock()
    }

    func search(_ text: String, home: String, syntax: QuerySyntax, deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        cancel()
        let q = ContentQuery.parse(text, home: home, syntax: syntax)
        lock.lock()
        let gen = generation
        lock.unlock()
        let empty = ContentOutput(text: text, query: q, hits: [], append: false, recall: nil, verified: 0, candidates: 0, done: true, error: nil)
        if q.isEmpty {
            send(empty, generation: gen, to: deliver)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.run(q, text: text, generation: gen, deliver: deliver) }
        lock.lock()
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func nextPreview() -> Int {
        lock.lock()
        defer { lock.unlock() }
        previewGeneration += 1
        return previewGeneration
    }

    private func isCurrentPreview(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == previewGeneration
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    /// Every delivery of a query goes through here: a replaced query delivers nothing.
    private func send(_ out: ContentOutput, generation gen: Int, to deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrent(gen) == true else { return }
            deliver(out)
        }
    }

    private func run(_ q: ContentQuery, text: String, generation gen: Int, deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        guard isCurrent(gen) else { return }
        var out = ContentOutput(text: text, query: q, hits: [], append: false, recall: nil, verified: 0, candidates: 0, done: true, error: nil)
        guard let index = openIndex() else {
            out.error = L("内容索引还没有建立完成")
            send(out, generation: gen, to: deliver)
            return
        }
        try? index.reload()
        let search: ContentSearch
        do {
            search = try index.search(query: q.expression, mode: mode, filters: SearchFilters(dirs: q.dirs, exts: q.exts, scopes: [],
                                                                                            sizeRange: q.size.map { [$0.lowerBound, $0.upperBound] },
                                                                                            mtimeRange: q.modified.map { [$0.lowerBound, $0.upperBound] },
                                                                                            names: q.names))
        } catch EngineError.Query(let message) {
            // Engine messages in Chinese are already user-facing (regex needs a scope…).
            out.error = message.unicodeScalars.contains { $0.value >= 0x4E00 } ? message : L("查询无法解析：%@", "\(message)")
            send(out, generation: gen, to: deliver)
            return
        } catch {
            out.error = "\(error)"
            send(out, generation: gen, to: deliver)
            return
        }
        lock.lock()
        guard gen == generation else { lock.unlock(); search.cancel(); return }
        current = search
        lock.unlock()
        out.recall = search.recall()
        var shown = 0
        var first = true
        while isCurrent(gen) {
            // First screen within ~60 ms; later batches are larger.
            let b: ContentBatch
            do {
                b = try search.next(budgetMs: first ? 60 : 120, maxHits: first ? 40 : 200)
            } catch {
                // A definite end, or the list would claim "still searching" for ever.
                out.hits = []
                out.append = !first
                out.done = true
                out.error = L("搜索中断：%@", "\(error)")
                send(out, generation: gen, to: deliver)
                break
            }
            let hits = b.hits
            let kept = hits.prefix(Self.resultCap - shown)
            shown += kept.count
            out.hits = Array(kept)
            out.append = !first
            out.verified = b.verified
            out.candidates = b.candidates
            // Exactly at the limit with nothing left to check is simply the whole list.
            out.capped = shown >= Self.resultCap && (!b.done || kept.count < hits.count)
            out.done = b.done || out.capped
            send(out, generation: gen, to: deliver)
            first = false
            if out.done { break }
        }
        // Finished or replaced: its snapshot is not needed any more.
        lock.lock()
        if gen == generation { current = nil }
        lock.unlock()
    }

    private let liveQueue = DispatchQueue(label: "xsearch.live", qos: .userInitiated)
    private var liveGeneration = 0

    /// Live scan (§8.7, explicit only): checks `files` one by one with the same matching as
    /// the index and delivers appended batches with progress; a new query or scan stops it.
    func liveScan(_ q: ContentQuery, text: String, files: [LiveFile], deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        lock.lock()
        let gen = generation
        liveGeneration += 1
        let live = liveGeneration
        lock.unlock()
        let mode = self.mode, maxFileBytes = self.maxFileBytes
        liveQueue.async { [weak self] in
            guard let self else { return }
            func current() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return gen == self.generation && live == self.liveGeneration
            }
            var out = ContentOutput(text: text, query: q, hits: [], append: true, recall: nil, verified: 0, candidates: 0, done: false, error: nil,
                                    live: true, scanned: 0, scanTotal: files.count)
            guard let scan = try? LiveScan(query: q.expression, mode: mode, maxFileBytes: maxFileBytes) else {
                out.done = true
                out.error = L("这个查询无法实时扫描")
                let batch = out
                DispatchQueue.main.async { if current() { deliver(batch) } }
                return
            }
            var pending: [ContentHit] = []
            var last = Date()
            for (i, f) in files.enumerated() {
                guard current() else { return }
                if q.allows(size: f.size, mtime: f.mtime), q.allows(name: (f.path as NSString).lastPathComponent), let h = scan.check(path: f.path) {
                    let url = URL(fileURLWithPath: f.path)
                    pending.append(ContentHit(fileId: UInt64(f.fileId), name: url.lastPathComponent, dir: url.deletingLastPathComponent().path,
                                              mtime: f.mtime, size: f.size, state: .complete, hitCount: h.hitCount, snippet: h.snippet,
                                              snippetHighlights: h.snippetHighlights, member: "", memberStart: 0))
                }
                let finished = i == files.count - 1
                if finished || pending.count >= 50 || Date().timeIntervalSince(last) > 0.15 {
                    out.hits = pending
                    out.scanned = i + 1
                    out.done = finished
                    let batch = out
                    DispatchQueue.main.async { if current() { deliver(batch) } }
                    pending = []
                    last = Date()
                }
            }
            if files.isEmpty {
                out.done = true
                let batch = out
                DispatchQueue.main.async { if current() { deliver(batch) } }
            }
        }
    }

    /// Preview of a live hit: the file itself, decoded, with every hit.
    func livePreview(path: String, expression: String, deliver: @escaping @MainActor @Sendable (PreviewData?) -> Void) {
        let mode = self.mode, maxFileBytes = self.maxFileBytes
        let gen = nextPreview()
        previewQueue.async { [weak self] in
            guard self?.isCurrentPreview(gen) == true else { return }
            guard let scan = try? LiveScan(query: expression, mode: mode, maxFileBytes: maxFileBytes), let t = scan.preview(path: path) else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            var st = stat()
            lstat(path, &st)
            let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            let url = URL(fileURLWithPath: path)
            let doc = ContentDocument(fileId: 0, opSeq: 0, revision: UInt64(bitPattern: ns), name: url.lastPathComponent,
                                      dir: url.deletingLastPathComponent().path, mtime: Int64(st.st_mtimespec.tv_sec), size: Int64(st.st_size),
                                      text: t.text, anchorsJson: "[]", pagesJson: "[]", state: .complete)
            let data = PreviewData(document: doc, highlights: t.highlights, totalHits: t.totalHits)
            DispatchQueue.main.async { deliver(data) }
        }
    }

    /// Stored text + hit ranges for the preview, from one snapshot (background queue). `mode`
    /// is the one the hit was found with, when another searcher found it.
    func preview(fileId: UInt64, expression: String, mode: MatchMode? = nil, member: String = "", memberStart: UInt32 = 0,
                 deliver: @escaping @MainActor @Sendable (PreviewData?) -> Void) {
        let mode = mode ?? self.mode
        let gen = nextPreview()
        previewQueue.async { [weak self] in
            guard self?.isCurrentPreview(gen) == true else { return }
            guard let index = self?.openIndex() else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            // A hit may come from a search newer than this reader's last reload.
            try? index.reload()
            guard let p = try? index.preview(fileId: fileId, query: expression, mode: mode, memberStart: member.isEmpty ? nil : memberStart, maxHits: Self.previewHitCap) else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            var doc = p.document
            if !member.isEmpty { doc.name = (member as NSString).lastPathComponent }
            let result = PreviewData(document: doc, highlights: p.highlights, totalHits: p.totalHits)
            DispatchQueue.main.async { deliver(result) }
        }
    }
}

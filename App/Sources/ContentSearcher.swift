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
    var highlights: [Utf16Range]
}

/// Content QuerySession (ARCHITECTURE §5, UI-SPEC §6.1): starts ~80 ms after typing stops, a
/// new input cancels the running query, the first verified screen comes from a short budget,
/// later batches keep arriving until the query is complete (or 1,000 results are shown).
final class ContentSearcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "xsearch.content", qos: .userInteractive)
    private let previewQueue = DispatchQueue(label: "xsearch.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var current: ContentSearch?
    private var pendingWork: DispatchWorkItem?
    private var index: ContentIndex?
    private var openedPath: String?
    /// Where the active index instance lives (set once the indexer has started).
    var indexPath: (@Sendable () -> String?)?
    var mode: MatchMode = .loose

    static let resultCap = 1000

    /// Opens (or reopens after an instance switch) the reader. nil until the indexer committed once.
    func openIndex() -> ContentIndex? {
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
            DispatchQueue.main.async { deliver(empty) }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.run(q, text: text, generation: gen, deliver: deliver) }
        lock.lock()
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    private func run(_ q: ContentQuery, text: String, generation gen: Int, deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        guard isCurrent(gen) else { return }
        var out = ContentOutput(text: text, query: q, hits: [], append: false, recall: nil, verified: 0, candidates: 0, done: true, error: nil)
        guard let index = openIndex() else {
            out.error = "内容索引还没有建立完成"
            DispatchQueue.main.async { deliver(out) }
            return
        }
        try? index.reload()
        let search: ContentSearch
        do {
            search = try index.search(query: q.expression, mode: mode, filters: SearchFilters(dirs: q.dirs, exts: q.exts, scopes: []))
        } catch EngineError.Query(let message) {
            // Engine messages in Chinese are already user-facing (regex needs a scope…).
            out.error = message.unicodeScalars.contains { $0.value >= 0x4E00 } ? message : "查询无法解析：\(message)"
            DispatchQueue.main.async { deliver(out) }
            return
        } catch {
            out.error = "\(error)"
            DispatchQueue.main.async { deliver(out) }
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
            guard let b = try? search.next(budgetMs: first ? 60 : 120, maxHits: first ? 40 : 200) else { break }
            // size: / dm: are checked here, after verification.
            let hits = q.size == nil && q.modified == nil ? b.hits : b.hits.filter { q.allows(size: $0.size, mtime: $0.mtime) }
            shown += hits.count
            out.hits = hits
            out.append = !first
            out.verified = b.verified
            out.candidates = b.candidates
            out.done = b.done || shown >= Self.resultCap
            let batch = out
            DispatchQueue.main.async { [weak self] in
                guard self?.isCurrent(gen) == true else { return }
                deliver(batch)
            }
            first = false
            if out.done { break }
        }
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
        let mode = self.mode
        liveQueue.async { [weak self] in
            guard let self else { return }
            func current() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return gen == self.generation && live == self.liveGeneration
            }
            var out = ContentOutput(text: text, query: q, hits: [], append: true, recall: nil, verified: 0, candidates: 0, done: false, error: nil,
                                    live: true, scanned: 0, scanTotal: files.count)
            guard let scan = try? LiveScan(query: q.expression, mode: mode, maxFileBytes: 100 << 20) else { return }
            var pending: [ContentHit] = []
            var last = Date()
            for (i, f) in files.enumerated() {
                guard current() else { return }
                if q.allows(size: f.size, mtime: f.mtime), let h = scan.check(path: f.path) {
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
                DispatchQueue.main.async { deliver(batch) }
            }
        }
    }

    /// Preview of a live hit: the file itself, decoded, with every hit.
    func livePreview(path: String, expression: String, deliver: @escaping @MainActor @Sendable (PreviewData?) -> Void) {
        let mode = self.mode
        previewQueue.async {
            guard let scan = try? LiveScan(query: expression, mode: mode, maxFileBytes: 100 << 20), let t = scan.preview(path: path) else {
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
            let data = PreviewData(document: doc, highlights: t.highlights)
            DispatchQueue.main.async { deliver(data) }
        }
    }

    /// Stored text + all hit ranges for the preview (background queue).
    func preview(fileId: UInt64, expression: String, member: String = "", memberStart: UInt32 = 0,
                 deliver: @escaping @MainActor @Sendable (PreviewData?) -> Void) {
        let mode = self.mode
        previewQueue.async { [weak self] in
            guard let index = self?.openIndex(), let doc = try? index.document(fileId: fileId) else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            let hl = (try? index.highlights(fileId: fileId, query: expression, mode: mode)) ?? []
            var data = PreviewData(document: doc, highlights: hl)
            if !member.isEmpty { data = data.member(member, startingAt: memberStart) }
            let result = data
            DispatchQueue.main.async { deliver(result) }
        }
    }
}

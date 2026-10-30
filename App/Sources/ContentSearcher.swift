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

    func search(_ text: String, home: String, deliver: @escaping @MainActor @Sendable (ContentOutput) -> Void) {
        cancel()
        let q = ContentQuery.parse(text, home: home)
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
            out.error = "查询无法解析：\(message)"
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
            shown += b.hits.count
            out.hits = b.hits
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

    /// Stored text + all hit ranges for the preview (background queue).
    func preview(fileId: UInt64, expression: String, deliver: @escaping @MainActor @Sendable (PreviewData?) -> Void) {
        let mode = self.mode
        previewQueue.async { [weak self] in
            guard let index = self?.openIndex(), let doc = try? index.document(fileId: fileId) else {
                DispatchQueue.main.async { deliver(nil) }
                return
            }
            let hl = (try? index.highlights(fileId: fileId, query: expression, mode: mode)) ?? []
            let data = PreviewData(document: doc, highlights: hl)
            DispatchQueue.main.async { deliver(data) }
        }
    }
}

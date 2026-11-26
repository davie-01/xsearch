import Catalog
import Foundation
import XSearchCore

/// One wording for the indexes' state, shared by the menu bar menu and the Settings status
/// bar. Content: 正在打开 / 未设置文件夹 / 已暂停 / 出错 / 索引中 (progress of this round, time left) /
/// 正在核对文件 / 已就绪.
enum ContentStatusText {
    /// `checking`: the catalog is listing folders (scope change, 重新扫描, first scan), so tasks
    /// may still be on their way.
    static func summary(_ st: ContentIndexer.Status?, paused: Bool, checking: Bool, hasFolders: Bool) -> String {
        guard let st else { return L("正在打开") }
        guard hasFolders else { return L("未设置文件夹") }
        if paused {
            return st.pending > 0
                ? L("已暂停 · %@ 个文件 · 待处理 %@", Theme.count(st.indexed), Theme.count(st.pending))
                : L("已暂停 · %@ 个文件", Theme.count(st.indexed))
        }
        if st.lastError != nil { return L("写入暂时出错，正在自动重试") }
        if st.working, st.roundTotal > 0 {
            let done = Theme.count(min(st.roundDone, st.roundTotal)), total = Theme.count(st.roundTotal)
            var s = st.roundRemovalsOnly ? L("正在移除 %@ / %@（%@%）", done, total, "\(percent(st))")
                                         : L("索引中 %@ / %@（%@%）", done, total, "\(percent(st))")
            if let eta = timeLeft(st) { s += " · " + eta }
            return s
        }
        if checking { return L("正在核对文件…") }
        var parts = [L("已就绪 · %@ 个文件", Theme.count(st.indexed))]
        if st.failed > 0 { parts.append(L("%@ 个失败", "\(Theme.count(st.failed))")) }
        if st.delayed > 0 { parts.append(L("%@ 个稍后重试", Theme.count(st.delayed))) }
        return parts.joined(separator: " · ")
    }

    /// The file name index's line.
    static func nameLine(_ st: NameService.Status) -> String {
        switch st.phase {
        case .starting: L("文件名索引：正在打开")
        case .scanning: L("文件名索引：正在建立 · %@ 项", "\(Theme.count(st.count))")
        case .ready: L("文件名索引：%@ · %@ 项", st.watching ? L("已就绪") : L("未实时更新"), Theme.count(st.count))
        case .failed(let message): L("文件名索引出错：%@", "\(message.prefix(60))")
        }
    }

    /// Share of this round done, as shown: never 100 before the round is over.
    static func percent(_ st: ContentIndexer.Status) -> Int {
        guard st.roundTotal > 0 else { return 0 }
        return min(99, st.roundDone * 100 / st.roundTotal)
    }

    /// A finished round's note stays this long, so a short round does not just flash by.
    static let recentLinger: TimeInterval = 60

    private static func endedAgo(_ st: ContentIndexer.Status, now: Date) -> TimeInterval? {
        guard !st.working, st.roundEnded > 0, st.roundDone > 0 else { return nil }
        return max(0, now.timeIntervalSince1970 - st.roundEnded)
    }

    /// The round that just finished: what it did and how long it took. nil after a minute.
    static func recent(_ st: ContentIndexer.Status?, now: Date = Date()) -> String? {
        guard let st, let ago = endedAgo(st, now: now), ago < recentLinger else { return nil }
        let took = duration(st.roundEnded - st.roundStarted)
        return st.roundRemovalsOnly ? L("刚刚移除了 %@ 个文件的内容 · 用时 %@", Theme.count(st.roundDone), took)
                                    : L("刚刚处理完 %@ 个文件 · 用时 %@", Theme.count(st.roundDone), took)
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return L("%@ 秒", "\(s)") }
        if s < 3600 { return s % 60 == 0 ? L("%@ 分钟", "\(s / 60)") : L("%@ 分 %@ 秒", "\(s / 60)", "\(s % 60)") }
        return L("%@ 小时 %@ 分", "\(s / 3600)", "\((s % 3600) / 60)")
    }

    /// From the speed of the last two minutes; nil until the indexer has measured one.
    static func timeLeft(_ st: ContentIndexer.Status) -> String? {
        let remaining = st.roundTotal - st.roundDone
        guard st.rate > 0, remaining > 0 else { return nil }
        let seconds = Double(remaining) / st.rate
        if seconds < 60 { return L("不到 1 分钟") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return L("约 %@ 分钟", "\(minutes)") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? L("约 %@ 小时", "\(h)") : L("约 %@ 小时 %@ 分钟", "\(h)", "\(m)")
    }

    /// One folder's line in Settings; empty until its first figures arrive.
    /// `counted`: figures for some folder have arrived (one missing is then a folder just added).
    static func folder(_ f: ContentIndexer.FolderStatus?, counted: Bool, paused: Bool, checking: Bool, exists: Bool) -> String {
        guard let f else { return counted ? L("正在核对…") : "" }
        guard f.known else { return exists ? L("正在核对…") : L("文件夹不存在") }
        if f.pending > 0 {
            return paused
                ? L("已暂停 · 待处理 %@", Theme.count(f.pending))
                : L("索引中 · 已索引 %@ · 待处理 %@", Theme.count(f.indexed), Theme.count(f.pending))
        }
        if checking && f.indexed == 0 && f.failed == 0 { return L("正在核对…") }
        var parts = [L("已就绪 · %@ 个文件", Theme.count(f.indexed))]
        if f.failed > 0 { parts.append(L("%@ 个失败", "\(Theme.count(f.failed))")) }
        return parts.joined(separator: " · ")
    }
}

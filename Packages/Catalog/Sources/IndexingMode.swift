import Foundation

/// Settings › 内容索引 › 索引速度 (ARCHITECTURE §9.2): how much of the machine extraction may
/// use. Defined by XSearch's own knobs: parallel extraction processes, and their quality of
/// service (background runs on the efficiency cores of Apple silicon and yields to everything).
public enum IndexingMode: String, Codable, CaseIterable, Sendable {
    case performance, balanced, quiet

    /// Extraction processes working at once.
    public var workers: Int {
        switch self {
        case .performance: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        case .balanced: 2
        case .quiet: 1
        }
    }

    /// Background priority: the indexer's queue and the extraction processes.
    public var background: Bool { self == .quiet }

    /// What runs given the power situation: Low Power Mode always means quiet, and on battery
    /// performance steps down to balanced.
    public func effective(onBattery: Bool, lowPower: Bool) -> IndexingMode {
        if lowPower { return .quiet }
        if onBattery && self == .performance { return .balanced }
        return self
    }
}

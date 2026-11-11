import Foundation

/// ログ 1 行分（アシスタントの応答 1 回分）のトークン使用量。
struct UsageEntry {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    /// 集計に使うトークン数。キャッシュ読み込みは桁違いに多く安価なので含めない。
    var countedTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
}

/// 5 時間の利用ブロック。最初のメッセージの時刻（正時に切り捨て）から 5 時間続く。
struct UsageBlock {
    static let duration: TimeInterval = 5 * 60 * 60

    let start: Date
    var tokens = 0
    var byModel: [String: Int] = [:]

    var end: Date { start.addingTimeInterval(Self.duration) }

    static func build(from entries: [UsageEntry]) -> [UsageBlock] {
        var blocks: [UsageBlock] = []
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            if blocks.isEmpty || entry.timestamp >= blocks[blocks.count - 1].end {
                let hour = (entry.timestamp.timeIntervalSince1970 / 3600).rounded(.down) * 3600
                blocks.append(UsageBlock(start: Date(timeIntervalSince1970: hour)))
            }
            blocks[blocks.count - 1].tokens += entry.countedTokens
            blocks[blocks.count - 1].byModel[entry.model, default: 0] += entry.countedTokens
        }
        return blocks
    }
}

/// ある時点での 5 時間ブロックのログ上の使用量。
struct UsageSummary {
    let activeBlock: UsageBlock?

    var usedTokens: Int { activeBlock?.tokens ?? 0 }

    init(blocks: [UsageBlock], now: Date) {
        activeBlock = blocks.last.flatMap { now < $0.end ? $0 : nil }
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, interval)) ?? ""
    }
}

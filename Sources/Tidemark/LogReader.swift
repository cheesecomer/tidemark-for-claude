import Foundation

/// Claude Code のセッションログ (JSONL) を差分で読み込み、トークン使用量を集める。
/// 内部状態を排他制御していないので、単一のシリアルキューからだけ使うこと。
final class LogReader: @unchecked Sendable {
    let roots: [URL]
    private(set) var entries: [UsageEntry] = []

    private var offsets: [URL: UInt64] = [:]
    /// 1 つの応答はコンテンツブロックごとに複数行へ書かれるので、message.id + requestId で重複を除く。
    private var seenKeys = Set<String>()
    private let decoder = JSONDecoder()
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormatter = ISO8601DateFormatter()
    private static let usageMarker = Data("\"usage\"".utf8)

    init(roots: [URL] = LogReader.defaultRoots()) {
        self.roots = roots
    }

    /// `CLAUDE_CONFIG_DIR`（カンマ区切り）があればそれを、なければ ~/.config/claude と ~/.claude を見る。
    static func defaultRoots() -> [URL] {
        let configDirs: [URL]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            configDirs = env.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
            }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            configDirs = [home.appendingPathComponent(".config/claude"), home.appendingPathComponent(".claude")]
        }
        return configDirs.map { $0.appendingPathComponent("projects") }
    }

    /// 前回からファイルに追記された分だけ読む。新しいエントリがあれば true。
    @discardableResult
    func refresh() -> Bool {
        let before = entries.count
        for file in logFiles() {
            readNewLines(of: file)
        }
        return entries.count != before
    }

    private func logFiles() -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files
    }

    private func readNewLines(of file: URL) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        var offset = offsets[file] ?? 0
        // 切り詰められたファイルは頭から読み直す（読み済みの応答は seenKeys で除かれる）
        if UInt64(size) < offset { offset = 0 }
        guard UInt64(size) > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            // 書き込み途中の最終行は次回に回す
            guard let data = try handle.readToEnd(),
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: UInt8(ascii: "\n"))
            where line.range(of: Self.usageMarker) != nil {
                if let entry = parse(line) {
                    entries.append(entry)
                }
            }
            offsets[file] = offset + UInt64(complete.count)
        } catch {
            return
        }
    }

    private func parse(_ line: Data) -> UsageEntry? {
        guard let record = try? decoder.decode(LogRecord.self, from: line),
              record.type == "assistant",
              let message = record.message,
              let usage = message.usage,
              let timestamp = record.timestamp,
              let date = fractionalDateFormatter.date(from: timestamp) ?? dateFormatter.date(from: timestamp)
        else { return nil }

        let model = message.model ?? "unknown"
        // API を呼ばずに Claude Code が生成したメッセージ
        if model == "<synthetic>" { return nil }
        if let messageID = message.id, let requestID = record.requestId,
           !seenKeys.insert("\(messageID):\(requestID)").inserted {
            return nil
        }

        return UsageEntry(
            timestamp: date,
            model: model,
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0
        )
    }
}

private struct LogRecord: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
}

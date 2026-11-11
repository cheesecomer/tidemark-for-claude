import CryptoKit
import Foundation

/// claude.ai の「プラン使用量」と同じ利用率。値はすべて 0〜100（%）。
struct PlanUsage {
    struct Window {
        let utilization: Double
        let resetsAt: Date?

        var remainingPercent: Int { Int((100 - min(max(utilization, 0), 100)).rounded()) }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let fetchedAt: Date
}

enum PlanUsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case rateLimited
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials: "Claude Code のログイン情報が見つかりません"
        case .tokenExpired: "トークンの期限切れ。Claude Code を使うと更新されます"
        case .rateLimited: "取得回数の制限中。しばらく待って再取得します"
        case .http(let status): "取得に失敗しました（HTTP \(status)）"
        case .invalidResponse: "レスポンスを読めません（API が変わった可能性があります）"
        }
    }
}

/// Claude Code が内部で使っている非公式の使用量 API（`/api/oauth/usage`）を呼ぶ。
/// 仕様が変わると壊れるので、その場合はこのファイルを直す。
enum PlanUsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> PlanUsage {
        let token = try ClaudeCredentials.accessToken()

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Tidemark/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw PlanUsageError.invalidResponse }
        switch status {
        case 200: break
        case 401: throw PlanUsageError.tokenExpired
        case 429: throw PlanUsageError.rateLimited
        default: throw PlanUsageError.http(status)
        }

        guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
            throw PlanUsageError.invalidResponse
        }
        return PlanUsage(
            fiveHour: body.five_hour?.window,
            sevenDay: body.seven_day?.window,
            sevenDayOpus: body.seven_day_opus?.window,
            sevenDaySonnet: body.seven_day_sonnet?.window,
            fetchedAt: Date()
        )
    }

    private struct Response: Decodable {
        let five_hour: RawWindow?
        let seven_day: RawWindow?
        let seven_day_opus: RawWindow?
        let seven_day_sonnet: RawWindow?
    }

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resets_at: String?

        /// 利用率が null の期間（プランに無い上限など）は表示しない。
        var window: PlanUsage.Window? {
            guard let utilization else { return nil }
            return PlanUsage.Window(utilization: utilization, resetsAt: resets_at.flatMap(parseDate))
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Claude Code が保存した OAuth トークンを読む。期限切れでも自分では更新しない
/// （更新するとリフレッシュトークンが切り替わり、Claude Code 側のログインが切れるため）。
enum ClaudeCredentials {
    static func accessToken() throws -> String {
        guard let data = keychainData() ?? fileData(),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let oauth = stored.claudeAiOauth
        else { throw PlanUsageError.noCredentials }

        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            throw PlanUsageError.tokenExpired
        }
        return oauth.accessToken
    }

    private static var configDir: String? {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Claude Code と同じ名前: "Claude Code-credentials"。CLAUDE_CONFIG_DIR があればそのハッシュが付く。
    private static var serviceName: String {
        var name = "Claude Code-credentials"
        if let configDir {
            let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
            name += "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        }
        return name
    }

    /// Claude Code は `security` コマンドで保存しているので、同じコマンドで読むと許可ダイアログが出ない。
    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", serviceName, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    private static func fileData() -> Data? {
        let dir = configDir.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return try? Data(contentsOf: dir.appendingPathComponent(".credentials.json"))
    }

    private struct Stored: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String
            /// ミリ秒
            let expiresAt: Double?
        }
    }
}

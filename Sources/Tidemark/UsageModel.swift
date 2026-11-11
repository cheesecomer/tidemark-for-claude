import Foundation
import ServiceManagement

/// ログの読み込み、使用量 API の取得、画面表示用の状態を持つ。
@MainActor
final class UsageModel: ObservableObject {
    /// API の取得間隔。制限中（429）は長めに待つ。
    private static let fetchInterval: TimeInterval = 120
    private static let rateLimitedInterval: TimeInterval = 600
    /// パネルを開いたときに取り直すのは、前回からこれ以上たっているときだけ。
    private static let refetchOnOpenInterval: TimeInterval = 30

    @Published private(set) var blocks: [UsageBlock] = []
    @Published private(set) var now = Date()

    @Published private(set) var planUsage: PlanUsage?
    @Published private(set) var planUsageError: String?
    @Published private(set) var isFetching = false
    private var nextFetch = Date.distantPast

    @Published private(set) var loginItemStatus = SMAppService.mainApp.status
    @Published private(set) var loginItemError: String?

    private let reader = LogReader()
    private let queue = DispatchQueue(label: "tidemark.log-reader")
    private var watcher: DirectoryWatcher?
    private var timer: Timer?

    init() {
        let existingRoots = reader.roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        watcher = DirectoryWatcher(paths: existingRoots, queue: queue) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        // カウントダウンの更新と API の定期取得。ログ監視を始められなかった場合の取りこぼしもここで拾う。
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.fetchPlanUsage()
            }
        }
        reload()
        fetchPlanUsage()
    }

    /// ログ上の使用量
    var logUsage: UsageSummary {
        UsageSummary(blocks: blocks, now: now)
    }

    var menuBarTitle: String {
        let percent = planUsage?.fiveHour.map { "\($0.remainingPercent)%" } ?? "—"
        return "\u{2733}\u{FE0E} \(percent)"
    }

    func fetchPlanUsage(force: Bool = false) {
        guard !isFetching, force || Date() >= nextFetch else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                planUsage = try await PlanUsageAPI.fetch()
                planUsageError = nil
                nextFetch = Date().addingTimeInterval(Self.fetchInterval)
            } catch {
                planUsageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let isRateLimited = if case PlanUsageError.rateLimited = error { true } else { false }
                nextFetch = Date().addingTimeInterval(isRateLimited ? Self.rateLimitedInterval : Self.fetchInterval)
            }
        }
    }

    func panelDidOpen() {
        refreshLoginItemStatus()
        now = Date()
        if let fetchedAt = planUsage?.fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.refetchOnOpenInterval {
            return
        }
        fetchPlanUsage()
    }

    /// 承認待ち（requiresApproval）も「オン」として扱い、システム設定での許可を促す。
    var launchAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    /// システム設定側で変更されることがあるので、パネルを開くたびに読み直す。
    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    func reload() {
        queue.async { [reader] in
            reader.refresh()
            let blocks = UsageBlock.build(from: reader.entries)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.blocks = blocks
                self.now = Date()
            }
        }
    }
}

import AppKit
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        // `Tidemark --print` で GUI を起動せずに取得結果だけ出す（動作確認用）
        if CommandLine.arguments.contains("--print") {
            printSummary()
        } else {
            TidemarkApp.main()
        }
    }

    private static func printSummary() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let usage = try await PlanUsageAPI.fetch()
                func describe(_ window: PlanUsage.Window?) -> String {
                    guard let window else { return "—" }
                    let reset = window.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
                    return "使用 \(window.utilization)% / 残り \(window.remainingPercent)%（リセット \(reset)）"
                }
                print("プラン使用量（API）")
                print("  5時間: \(describe(usage.fiveHour))")
                print("  7日間: \(describe(usage.sevenDay))")
                print("  7日間 Opus: \(describe(usage.sevenDayOpus))")
                print("  7日間 Sonnet: \(describe(usage.sevenDaySonnet))")
            } catch {
                print("プラン使用量（API）: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            done.signal()
        }
        done.wait()

        let reader = LogReader()
        reader.refresh()
        let blocks = UsageBlock.build(from: reader.entries)
        let now = Date()
        let logUsage = UsageSummary(blocks: blocks, now: now)
        print("ログ（エントリ \(reader.entries.count) / ブロック \(blocks.count)）")
        print("  5時間: \(Format.tokens(logUsage.usedTokens))")
    }
}

struct TidemarkApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel()
                .environmentObject(model)
        } label: {
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsagePanel: View {
    @EnvironmentObject private var model: UsageModel

    var body: some View {
        let usage = model.planUsage
        let logUsage = model.logUsage

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tidemark").font(.headline)
                Spacer()
                Text("プラン使用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 5 時間
            VStack(alignment: .leading, spacing: 6) {
                Text("5時間").font(.subheadline.weight(.semibold))
                if let window = usage?.fiveHour {
                    percentView(window.remainingPercent, large: true)
                    ProgressView(value: Double(window.remainingPercent), total: 100)
                } else if model.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").font(.title2)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("リセット").foregroundStyle(.secondary)
                        if let resetsAt = usage?.fiveHour?.resetsAt {
                            Text(resetText(resetsAt))
                        } else if let block = logUsage.activeBlock {
                            Text(resetText(block.end))
                        } else {
                            Text("—")
                        }
                    }
                    GridRow {
                        Text("トークン").foregroundStyle(.secondary)
                        Text(Format.tokens(logUsage.usedTokens))
                    }
                }
                .font(.callout)
                .monospacedDigit()

                if let block = logUsage.activeBlock, block.byModel.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(block.byModel.sorted(by: { $0.value > $1.value }), id: \.key) { model, tokens in
                            HStack {
                                Text(model)
                                Spacer()
                                Text(Format.tokens(tokens)).monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // 7 日間
            VStack(alignment: .leading, spacing: 6) {
                if let window = usage?.sevenDay {
                    weeklyRow("7日間", window)
                } else {
                    HStack {
                        Text("7日間").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                if let window = usage?.sevenDayOpus {
                    weeklyRow("7日間 Opus", window)
                }
                if let window = usage?.sevenDaySonnet {
                    weeklyRow("7日間 Sonnet", window)
                }
            }

            if let error = model.planUsageError {
                HStack(alignment: .firstTextBaseline) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("再取得") { model.fetchPlanUsage(force: true) }
                        .controlSize(.small)
                        .disabled(model.isFetching)
                }
            }

            Divider()

            Toggle("ログイン時に起動", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginItemStatus == .requiresApproval {
                HStack {
                    Text("システム設定で許可が必要です")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("開く") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let error = model.loginItemError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if let fetchedAt = usage?.fetchedAt {
                    Text("更新 \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { model.panelDidOpen() }
    }

    private func percentView(_ percent: Int, large: Bool) -> some View {
        Text("残り \(percent)%")
            .font(large ? .system(size: 28, weight: .semibold, design: .rounded) : .subheadline.weight(.semibold))
            .monospacedDigit()
    }

    private func weeklyRow(_ title: String, _ window: PlanUsage.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                percentView(window.remainingPercent, large: false)
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
            if let resetsAt = window.resetsAt {
                Text("リセット \(resetsAt.formatted(.dateTime.month().day().weekday().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        "あと \(Format.duration(date.timeIntervalSince(model.now)))（\(date.formatted(date: .omitted, time: .shortened))）"
    }
}

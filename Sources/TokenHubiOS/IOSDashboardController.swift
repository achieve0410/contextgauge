import Foundation
import OSLog
import TokenHubCore

protocol ReadOnlyDashboardDataSource: Sendable {
    func fetch() async throws -> CloudSyncPayload
}

struct CloudKitDashboardDataSource: ReadOnlyDashboardDataSource {
    let sync: CloudKitSync

    func fetch() async throws -> CloudSyncPayload {
        try await sync.dashboardPayload(
            since: DashboardHistoryWindow.earliestRequiredDay()
        )
    }
}

struct SeededDashboardDataSource: ReadOnlyDashboardDataSource {
    func fetch() async throws -> CloudSyncPayload {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let usage = (0..<7).flatMap { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)
                ?? today
            return [
                DailyUsage(
                    day: day,
                    deviceID: "MacBook",
                    source: .senpi,
                    provider: "openai-codex",
                    model: "gpt-5.6-sol",
                    inputTokens: 420_000 - offset * 10_000,
                    outputTokens: 80_000,
                    cacheReadTokens: 120_000,
                    cacheWriteTokens: 10_000,
                    totalTokens: 630_000 - offset * 10_000,
                    estimatedCostUSD: Decimal(52 - offset),
                    eventCount: 24
                ),
                DailyUsage(
                    day: day,
                    deviceID: "Mac mini",
                    source: .claude,
                    provider: "anthropic",
                    model: "claude-opus-4-1",
                    inputTokens: 120_000,
                    outputTokens: 30_000,
                    cacheReadTokens: 40_000,
                    cacheWriteTokens: 0,
                    totalTokens: 190_000,
                    estimatedCostUSD: Decimal(18),
                    eventCount: 8
                ),
            ]
        }
        let quota = QuotaSnapshot(
            provider: "openai-codex",
            accountPseudonym: "ui-test-account",
            capturedAt: .now,
            windowKind: "weekly",
            usedPercent: 42,
            resetsAt: calendar.date(byAdding: .day, value: 3, to: .now),
            source: "api"
        )
        let devices = [
            Device(
                id: "MacBook",
                name: "MacBook",
                lastCollectedAt: .now,
                lastSyncedAt: .now
            ),
            Device(
                id: "Mac mini",
                name: "Mac mini",
                lastCollectedAt: .now,
                lastSyncedAt: .now
            ),
        ]
        return CloudSyncPayload(
            dailyUsage: usage,
            quotaSnapshots: [quota],
            devices: devices,
            providerStatuses: [
                LiveQuotaProviderStatus(
                    deviceID: "MacBook",
                    provider: .codex,
                    accountPseudonym: "ui-test-account",
                    freshness: .fresh,
                    checkedAt: .now,
                    capturedAt: .now,
                    errorCode: nil
                ),
            ]
        )
    }
}

@MainActor
final class IOSDashboardController: ObservableObject {
    @Published var period = DashboardPeriod.today
    @Published var selectedDeviceID: String?
    @Published var selectedProvider: String?
    @Published var selectedModel: String?
    @Published private(set) var payload: CloudSyncPayload?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorCode: String?
    private let dataSource: any ReadOnlyDashboardDataSource
    private let logger = Logger(
        subsystem: "com.example.contextgauge.ios",
        category: "dashboard"
    )

    init(dataSource: any ReadOnlyDashboardDataSource) {
        self.dataSource = dataSource
    }

    var model: ReadOnlyDashboardViewModel {
        ReadOnlyDashboardViewModel(
            payload: payload,
            fetchedAt: fetchedAt,
            period: period,
            deviceID: selectedDeviceID,
            provider: selectedProvider,
            model: selectedModel
        )
    }

    func reload() async {
        isLoading = true
        errorCode = nil
        defer { isLoading = false }
        do {
            payload = try await dataSource.fetch()
            fetchedAt = .now
            logger.notice("TOKENHUB_UI_READY")
        } catch {
            errorCode = "cloud-read-failed"
            logger.error("TOKENHUB_UI_FAILED")
        }
    }
}

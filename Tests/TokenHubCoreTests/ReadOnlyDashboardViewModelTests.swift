import Foundation
import Testing
@testable import TokenHubCore

@Suite("iOS read-only dashboard")
struct ReadOnlyDashboardViewModelTests {
    @Test("Builds device filters and chart-ready state from cloud aggregates")
    func aggregatePayload() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 12))
        )
        let payload = CloudSyncPayload(
            dailyUsage: [
                usage(day: now, device: "macbook", tokens: 10),
                usage(day: now, device: "mini", tokens: 20),
            ],
            quotaSnapshots: [],
            devices: [
                Device(
                    id: "macbook",
                    name: "Work MacBook",
                    lastCollectedAt: now,
                    lastSyncedAt: now
                ),
            ]
        )

        let model = ReadOnlyDashboardViewModel(
            payload: payload,
            fetchedAt: now,
            period: .today,
            deviceID: "macbook",
            now: now,
            calendar: calendar
        )

        #expect(model.availableDeviceIDs == ["macbook", "mini"])
        #expect(model.dashboard.deviceName(for: "macbook") == "Work MacBook")
        #expect(model.dashboard.deviceName(for: "mini") == "mini")
        #expect(model.dashboard.totalTokens == 10)
        #expect(model.dashboard.dailySeries.map(\.totalTokens) == [10])
        #expect(model.emptyState == nil)
        #expect(model.isReadOnly)
        #expect(!model.canCollectLocalLogs)
        #expect(!model.canAuthenticateProviders)
        #expect(!model.canWriteCloudAggregates)
    }

    @Test("Filters aggregate usage by provider and model")
    func providerAndModelFilters() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8))
        )
        let payload = CloudSyncPayload(
            dailyUsage: [
                usage(
                    day: now,
                    device: "macbook",
                    tokens: 10,
                    provider: "openai",
                    model: "gpt-5"
                ),
                usage(
                    day: now,
                    device: "mini",
                    tokens: 20,
                    provider: "anthropic",
                    model: "claude-opus"
                ),
            ],
            quotaSnapshots: []
        )

        let model = ReadOnlyDashboardViewModel(
            payload: payload,
            fetchedAt: now,
            period: .today,
            deviceID: nil,
            provider: "anthropic",
            model: "claude-opus",
            now: now,
            calendar: calendar
        )

        #expect(model.availableProviders == ["anthropic", "openai"])
        #expect(model.availableModels == ["claude-opus"])
        #expect(model.dashboard.totalTokens == 20)
        #expect(model.dashboard.rows.map(\.model) == ["claude-opus"])
    }

    @Test("Distinguishes cloud-empty and filter-empty states")
    func emptyStates() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8))
        )
        let oldDay = try #require(
            calendar.date(byAdding: .day, value: -10, to: now)
        )
        let unavailable = ReadOnlyDashboardViewModel(
            payload: nil,
            fetchedAt: nil,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: calendar
        )
        let empty = ReadOnlyDashboardViewModel(
            payload: CloudSyncPayload(dailyUsage: [], quotaSnapshots: []),
            fetchedAt: now,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: calendar
        )
        let filtered = ReadOnlyDashboardViewModel(
            payload: CloudSyncPayload(
                dailyUsage: [
                    usage(
                        day: oldDay,
                        device: "macbook",
                        tokens: 10
                    ),
                ],
                quotaSnapshots: []
            ),
            fetchedAt: now,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: calendar
        )

        #expect(unavailable.emptyState == .cloudUnavailable)
        #expect(empty.emptyState == .noCloudUsage)
        #expect(filtered.emptyState == .noUsageForSelection)
    }

    @Test("Provider lookup failure is distinct from no cloud usage")
    func providerFailureState() {
        let checkedAt = Date(timeIntervalSince1970: 200)
        let payload = CloudSyncPayload(
            dailyUsage: [],
            quotaSnapshots: [],
            devices: [],
            providerStatuses: [
                LiveQuotaProviderStatus(
                    deviceID: "macbook",
                    provider: .claude,
                    accountPseudonym: "profile",
                    freshness: .error,
                    checkedAt: checkedAt,
                    capturedAt: nil,
                    errorCode: "credentials-unavailable"
                ),
            ]
        )

        let viewModel = ReadOnlyDashboardViewModel(
            payload: payload,
            fetchedAt: checkedAt,
            period: .today,
            deviceID: nil,
            now: checkedAt
        )

        #expect(viewModel.emptyState == .providerFailure)
        #expect(viewModel.providerStatuses == payload.providerStatuses)
    }

    private func usage(
        day: Date,
        device: String,
        tokens: Int,
        provider: String = "openai",
        model: String = "gpt-5"
    ) -> DailyUsage {
        DailyUsage(
            day: day,
            deviceID: device,
            source: .senpi,
            provider: provider,
            model: model,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: tokens,
            estimatedCostUSD: 1,
            eventCount: 1
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

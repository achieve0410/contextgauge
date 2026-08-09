import Foundation
import Testing
@testable import TokenHubCore

@Suite("Dashboard view model")
struct DashboardViewModelTests {
    @Test("Periods use inclusive local-calendar boundaries")
    func periodBoundaries() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 12))
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: now, tokens: 10),
                usage(day: calendar.date(byAdding: .day, value: -3, to: now)!, tokens: 20),
                usage(day: calendar.date(byAdding: .day, value: -10, to: now)!, tokens: 30),
                usage(day: calendar.date(byAdding: .month, value: -1, to: now)!, tokens: 40),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        #expect(
            DashboardViewModel(
                snapshot: snapshot,
                period: .today,
                deviceID: nil,
                now: now,
                calendar: calendar
            ).totalTokens == 10
        )
        #expect(
            DashboardViewModel(
                snapshot: snapshot,
                period: .sevenDays,
                deviceID: nil,
                now: now,
                calendar: calendar
            ).totalTokens == 30
        )
    }

    @Test
    func rollingPeriodBounds() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 9,
                    hour: 12
                )
            )
        )
        let end = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 10
                )
            )
        )
        let cases: [
            (
                String,
                DateComponents,
                DateComponents
            )
        ] = [
            (
                "today",
                DateComponents(year: 2026, month: 8, day: 9),
                DateComponents(year: 2026, month: 8, day: 8)
            ),
            (
                "sevenDays",
                DateComponents(year: 2026, month: 8, day: 3),
                DateComponents(year: 2026, month: 7, day: 27)
            ),
            (
                "twoWeeks",
                DateComponents(year: 2026, month: 7, day: 27),
                DateComponents(year: 2026, month: 7, day: 13)
            ),
            (
                "oneMonth",
                DateComponents(year: 2026, month: 7, day: 10),
                DateComponents(year: 2026, month: 6, day: 10)
            ),
            (
                "threeMonths",
                DateComponents(year: 2026, month: 5, day: 10),
                DateComponents(year: 2026, month: 2, day: 10)
            ),
            (
                "sixMonths",
                DateComponents(year: 2026, month: 2, day: 10),
                DateComponents(year: 2025, month: 8, day: 10)
            ),
            (
                "oneYear",
                DateComponents(year: 2025, month: 8, day: 10),
                DateComponents(year: 2024, month: 8, day: 10)
            ),
        ]

        for (rawValue, startComponents, previousComponents) in cases {
            let period = try #require(
                DashboardPeriod(rawValue: rawValue)
            )
            let currentStart = try #require(
                calendar.date(from: startComponents)
            )
            let previousStart = try #require(
                calendar.date(from: previousComponents)
            )
            let previousEndDay = try #require(
                calendar.date(
                    byAdding: .day,
                    value: -1,
                    to: currentStart
                )
            )
            let beforePrevious = try #require(
                calendar.date(
                    byAdding: .day,
                    value: -1,
                    to: previousStart
                )
            )
            let snapshot = DashboardSnapshot(
                dailyUsage: [
                    usage(day: currentStart, tokens: 1),
                    usage(day: now, tokens: 2),
                    usage(day: end, tokens: 4),
                    usage(day: previousStart, tokens: 8),
                    usage(day: previousEndDay, tokens: 16),
                    usage(day: beforePrevious, tokens: 32),
                ],
                quotaSnapshots: [],
                devices: [],
                collectorStatuses: []
            )
            let model = DashboardViewModel(
                snapshot: snapshot,
                period: period,
                deviceID: nil,
                now: now,
                calendar: calendar
            )
            #expect(model.periodComparison.currentTokens == 3)
            #expect(model.periodComparison.previousTokens == 24)
        }
    }

    @Test
    func historyWindowCoversCurrentAndPreviousYear() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 9,
                    hour: 12
                )
            )
        )
        let expected = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2024,
                    month: 8,
                    day: 10
                )
            )
        )

        #expect(
            DashboardHistoryWindow.earliestRequiredDay(
                now: now,
                calendar: calendar
            ) == expected
        )
    }

    @Test("Daily series includes cost event count and pricing completeness")
    func dailyBreakdown() throws {
        let calendar = utcCalendar()
        let today = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8))
        )
        let yesterday = try #require(
            calendar.date(byAdding: .day, value: -1, to: today)
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: yesterday, tokens: 5),
                usage(day: today, model: "gpt-5", tokens: 10),
                usage(
                    day: today,
                    model: "claude",
                    tokens: 20,
                    isCostComplete: false
                ),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let viewModel = DashboardViewModel(
            snapshot: snapshot,
            period: .sevenDays,
            deviceID: nil,
            now: today,
            calendar: calendar
        )

        #expect(viewModel.dailySeries.map(\.totalTokens) == [5, 30])
        #expect(
            viewModel.dailySeries.map(\.estimatedCostUSD)
                == [Decimal(string: "0.005"), Decimal(string: "0.03")]
        )
        #expect(viewModel.dailySeries.map(\.eventCount) == [1, 2])
        #expect(viewModel.dailySeries.map(\.isCostComplete) == [true, false])
    }

    @Test("Device filters preserve provider model and device rows")
    func deviceFilter() throws {
        let calendar = utcCalendar()
        let day = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 8))
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: day, deviceID: "macbook", model: "gpt-5", tokens: 10),
                usage(day: day, deviceID: "mini", model: "gpt-5", tokens: 20),
                usage(day: day, deviceID: "macbook", model: "claude", tokens: 30),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let all = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: nil,
            now: day,
            calendar: calendar
        )
        let macbook = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: "macbook",
            now: day,
            calendar: calendar
        )

        #expect(all.rows.count == 3)
        #expect(all.totalTokens == 60)
        #expect(macbook.rows.map(\.deviceID) == ["macbook", "macbook"])
        #expect(macbook.totalTokens == 40)
    }

    @Test("Latest quota status and concise collector errors are surfaced")
    func statusAndErrors() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = now.addingTimeInterval(-60)
        let snapshot = DashboardSnapshot(
            dailyUsage: [],
            quotaSnapshots: [
                quota(capturedAt: older, used: "20"),
                quota(capturedAt: now, used: "40"),
            ],
            devices: [
                Device(
                    id: "macbook",
                    name: "MacBook",
                    lastCollectedAt: older,
                    lastSyncedAt: now
                ),
            ],
            collectorStatuses: [
                CollectorStatus(
                    source: .senpi,
                    lastSuccessfulCollectionAt: older,
                    errorCode: "malformed-row"
                ),
            ]
        )

        let viewModel = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: utcCalendar()
        )

        #expect(viewModel.latestQuota?.usedPercent == Decimal(string: "40"))
        #expect(viewModel.lastCollectionAt == older)
        #expect(viewModel.lastSyncAt == now)
        #expect(viewModel.collectorErrors.map(\.errorCode) == ["malformed-row"])
        #expect(viewModel.isCostEstimated)
    }

    @Test("Marks totals partial when any aggregate lacks pricing")
    func incompletePricing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: now, tokens: 10, isCostComplete: false),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let viewModel = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: utcCalendar()
        )

        #expect(!viewModel.isCostComplete)
    }

    private func usage(
        day: Date,
        deviceID: String = "macbook",
        model: String = "gpt-5",
        tokens: Int,
        isCostComplete: Bool = true
    ) -> DailyUsage {
        DailyUsage(
            day: day,
            deviceID: deviceID,
            source: .senpi,
            provider: model == "claude" ? "anthropic" : "openai",
            model: model,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: tokens,
            estimatedCostUSD: Decimal(tokens) / Decimal(1_000),
            eventCount: 1,
            isCostComplete: isCostComplete
        )
    }

    private func quota(capturedAt: Date, used: String) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: "openai",
            accountPseudonym: "account",
            capturedAt: capturedAt,
            windowKind: "weekly",
            usedPercent: Decimal(string: used) ?? 0,
            resetsAt: nil,
            source: "api"
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

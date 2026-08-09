import Foundation
import Testing
@testable import TokenHubCore

@Suite("Dashboard insights")
struct DashboardInsightsTests {
    @Test("Token composition respects selected period and device")
    func tokenCompositionRespectsFilters() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 8,
                    hour: 12
                )
            )
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(
                    day: now,
                    deviceID: "selected",
                    input: 50,
                    output: 20,
                    cacheRead: 25,
                    cacheWrite: 5
                ),
                usage(
                    day: now,
                    deviceID: "other",
                    input: 900,
                    output: 90,
                    cacheRead: 9,
                    cacheWrite: 1
                ),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -1,
                        to: now
                    )!,
                    deviceID: "selected",
                    input: 400,
                    output: 300,
                    cacheRead: 200,
                    cacheWrite: 100
                ),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let viewModel = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: "selected",
            now: now,
            calendar: calendar
        )

        #expect(
            viewModel.tokenComposition
                == TokenComposition(
                    inputTokens: 50,
                    outputTokens: 20,
                    cacheReadTokens: 25,
                    cacheWriteTokens: 5
                )
        )
    }

    @Test("Seven day comparison uses the previous equivalent window")
    func previousEquivalentSevenDayWindow() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 8,
                    hour: 12
                )
            )
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: now, deviceID: "mac", input: 300),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -7,
                        to: now
                    )!,
                    deviceID: "mac",
                    input: 120
                ),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -13,
                        to: now
                    )!,
                    deviceID: "mac",
                    input: 80
                ),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -14,
                        to: now
                    )!,
                    deviceID: "mac",
                    input: 999
                ),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -7,
                        to: now
                    )!,
                    deviceID: "other",
                    input: 999
                ),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let comparison = DashboardViewModel(
            snapshot: snapshot,
            period: .sevenDays,
            deviceID: "mac",
            now: now,
            calendar: calendar
        ).periodComparison

        #expect(comparison.currentTokens == 300)
        #expect(comparison.previousTokens == 200)
        #expect(comparison.deltaTokens == 100)
        #expect(comparison.percentChange == Decimal(50))
    }

    @Test("Zero previous usage reports no percentage baseline")
    func zeroBaselineHasNoPercentChange() throws {
        let calendar = utcCalendar()
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 8,
                    hour: 12
                )
            )
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                usage(day: now, deviceID: "mac", input: 10),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let comparison = DashboardViewModel(
            snapshot: snapshot,
            period: .today,
            deviceID: "mac",
            now: now,
            calendar: calendar
        ).periodComparison

        #expect(comparison.currentTokens == 10)
        #expect(comparison.previousTokens == 0)
        #expect(comparison.deltaTokens == 10)
        #expect(comparison.percentChange == nil)
    }

    private func usage(
        day: Date,
        deviceID: String,
        input: Int,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> DailyUsage {
        DailyUsage(
            day: day,
            deviceID: deviceID,
            source: .senpi,
            provider: "openai",
            model: "gpt-5",
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: input + output + cacheRead + cacheWrite,
            estimatedCostUSD: 0,
            eventCount: 1
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

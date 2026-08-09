import Foundation
import Testing
@testable import TokenHubCore

@Suite("Aggregate CSV exporter")
struct AggregateCSVExporterTests {
    @Test("Export is deterministic, quoted, and Decimal preserving")
    func deterministicQuotedExport() throws {
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
                    deviceID: #"mac,"studio""#,
                    source: .senpi,
                    provider: "openai",
                    model: #"gpt,"quoted""#,
                    input: 8,
                    output: 2,
                    cacheRead: 1,
                    cacheWrite: 0,
                    cost: "1.2300"
                ),
                usage(
                    day: now,
                    deviceID: "alpha",
                    source: .claude,
                    provider: "anthropic",
                    model: "claude-sonnet",
                    input: 3,
                    output: 4,
                    cacheRead: 5,
                    cacheWrite: 6,
                    cost: "0.45"
                ),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let csv = AggregateCSVExporter.export(
            snapshot: snapshot,
            period: .today,
            deviceID: nil,
            now: now,
            calendar: calendar
        )

        #expect(
            csv
                == #"""
                day,device_id,source,provider,model,input_count,output_count,cache_read_count,cache_write_count,total_count,estimated_cost_usd,event_count,cost_complete
                2026-08-08,alpha,claude,anthropic,claude-sonnet,3,4,5,6,18,0.45,2,true
                2026-08-08,"mac,""studio""",senpi,openai,"gpt,""quoted""",8,2,1,0,11,1.23,2,true

                """#
        )
    }

    @Test("Export uses the selected aggregate window and safe field allowlist")
    func selectedWindowAndPrivacyAllowlist() throws {
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
                    source: .codex,
                    provider: "openai",
                    model: "gpt-5",
                    input: 10,
                    output: 0,
                    cacheRead: 0,
                    cacheWrite: 0,
                    cost: "0.1"
                ),
                usage(
                    day: calendar.date(
                        byAdding: .day,
                        value: -8,
                        to: now
                    )!,
                    deviceID: "selected",
                    source: .codex,
                    provider: "openai",
                    model: "old-model",
                    input: 999,
                    output: 0,
                    cacheRead: 0,
                    cacheWrite: 0,
                    cost: "9"
                ),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )

        let csv = AggregateCSVExporter.export(
            snapshot: snapshot,
            period: .sevenDays,
            deviceID: "selected",
            now: now,
            calendar: calendar
        )
        let lowercased = csv.lowercased()
        let forbidden = [
            "prompt",
            "response",
            "session_id",
            "event_id",
            "cwd",
            "path",
            "access_token",
            "refresh_token",
            "authorization",
            "cookie",
            "bearer",
        ]

        #expect(csv.contains("gpt-5"))
        #expect(!csv.contains("old-model"))
        #expect(forbidden.allSatisfy { !lowercased.contains($0) })
    }

    private func usage(
        day: Date,
        deviceID: String,
        source: UsageSource,
        provider: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        cost: String
    ) -> DailyUsage {
        DailyUsage(
            day: day,
            deviceID: deviceID,
            source: source,
            provider: provider,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: input + output + cacheRead + cacheWrite,
            estimatedCostUSD: Decimal(string: cost) ?? 0,
            eventCount: 2
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

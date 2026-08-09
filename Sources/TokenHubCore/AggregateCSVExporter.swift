import Foundation

public enum AggregateCSVExporter {
    private static let header = [
        "day",
        "device_id",
        "source",
        "provider",
        "model",
        "input_count",
        "output_count",
        "cache_read_count",
        "cache_write_count",
        "total_count",
        "estimated_cost_usd",
        "event_count",
        "cost_complete",
    ]

    public static func export(
        snapshot: DashboardSnapshot,
        period: DashboardPeriod,
        deviceID: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let selected = DashboardViewModel(
            snapshot: snapshot,
            period: period,
            deviceID: deviceID,
            now: now,
            calendar: calendar
        ).selectedUsage
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let rows = selected.sorted {
            (
                $0.day,
                $0.deviceID,
                $0.source.rawValue,
                $0.provider,
                $0.model
            ) < (
                $1.day,
                $1.deviceID,
                $1.source.rawValue,
                $1.provider,
                $1.model
            )
        }
        var lines = [header.joined(separator: ",")]
        lines.append(contentsOf: rows.map { usage in
            [
                formatter.string(from: usage.day),
                usage.deviceID,
                usage.source.rawValue,
                usage.provider,
                usage.model,
                String(usage.inputTokens),
                String(usage.outputTokens),
                String(usage.cacheReadTokens),
                String(usage.cacheWriteTokens),
                String(usage.totalTokens),
                NSDecimalNumber(
                    decimal: usage.estimatedCostUSD
                ).stringValue,
                String(usage.eventCount),
                String(usage.isCostComplete),
            ]
            .map(csvField)
            .joined(separator: ",")
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",")
                || value.contains("\"")
                || value.contains("\n")
                || value.contains("\r")
        else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

import Foundation

public enum DashboardHistoryWindow {
    public static func earliestRequiredDay(
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let currentEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: today
        ) ?? today
        return calendar.date(
            byAdding: .year,
            value: -2,
            to: currentEnd
        ) ?? currentEnd
    }
}

public enum DashboardPeriod: String, CaseIterable, Sendable {
    case today
    case sevenDays
    case twoWeeks
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case month

    public static let allCases: [Self] = [
        .today,
        .sevenDays,
        .twoWeeks,
        .oneMonth,
        .threeMonths,
        .sixMonths,
        .oneYear,
    ]

    public var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "Last 7 Days"
        case .twoWeeks: "Last 2 Weeks"
        case .oneMonth, .month: "Last 1 Month"
        case .threeMonths: "Last 3 Months"
        case .sixMonths: "Last 6 Months"
        case .oneYear: "Last 1 Year"
        }
    }
}

public struct CollectorStatus: Hashable, Sendable {
    public let source: UsageSource
    public let lastSuccessfulCollectionAt: Date?
    public let errorCode: String?

    public init(
        source: UsageSource,
        lastSuccessfulCollectionAt: Date?,
        errorCode: String?
    ) {
        self.source = source
        self.lastSuccessfulCollectionAt = lastSuccessfulCollectionAt
        self.errorCode = errorCode
    }
}

public struct DashboardSnapshot: Sendable {
    public let dailyUsage: [DailyUsage]
    public let quotaSnapshots: [QuotaSnapshot]
    public let devices: [Device]
    public let collectorStatuses: [CollectorStatus]

    public init(
        dailyUsage: [DailyUsage],
        quotaSnapshots: [QuotaSnapshot],
        devices: [Device],
        collectorStatuses: [CollectorStatus]
    ) {
        self.dailyUsage = dailyUsage
        self.quotaSnapshots = quotaSnapshots
        self.devices = devices
        self.collectorStatuses = collectorStatuses
    }
}

public struct DashboardRow: Hashable, Sendable {
    public let deviceID: String
    public let source: UsageSource
    public let provider: String
    public let model: String
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal
}

public struct DailyUsagePoint: Hashable, Sendable {
    public let day: Date
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal
    public let eventCount: Int
    public let isCostComplete: Bool
}

public struct TokenComposition: Hashable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct PeriodComparison: Hashable, Sendable {
    public let currentTokens: Int
    public let previousTokens: Int
    public let deltaTokens: Int
    public let percentChange: Decimal?

    public init(currentTokens: Int, previousTokens: Int) {
        self.currentTokens = currentTokens
        self.previousTokens = previousTokens
        deltaTokens = currentTokens - previousTokens
        if previousTokens == 0 {
            percentChange = nil
        } else {
            percentChange = Decimal(deltaTokens) * 100
                / Decimal(previousTokens)
        }
    }
}

public struct DashboardViewModel: Sendable {
    public let period: DashboardPeriod
    public let selectedDeviceID: String?
    public let rows: [DashboardRow]
    public let dailySeries: [DailyUsagePoint]
    public let selectedUsage: [DailyUsage]
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal
    public let tokenComposition: TokenComposition
    public let periodComparison: PeriodComparison
    public let latestQuotas: [QuotaSnapshot]
    public let collectorErrors: [CollectorStatus]
    public let lastCollectionAt: Date?
    public let lastSyncAt: Date?
    public let isCostEstimated = true
    public let isCostComplete: Bool
    public let deviceNamesByID: [String: String]

    public var latestQuota: QuotaSnapshot? {
        latestQuotas.max { $0.capturedAt < $1.capturedAt }
    }

    public init(
        snapshot: DashboardSnapshot,
        period: DashboardPeriod,
        deviceID: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.period = period
        selectedDeviceID = deviceID
        deviceNamesByID = Dictionary(
            uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0.name) }
        )
        let bounds = Self.periodBounds(
            for: period,
            now: now,
            calendar: calendar
        )
        let filtered = snapshot.dailyUsage.filter {
            $0.day >= bounds.currentStart
                && $0.day < bounds.currentEnd
                && (deviceID == nil || $0.deviceID == deviceID)
        }
        let previous = snapshot.dailyUsage.filter {
            $0.day >= bounds.previousStart
                && $0.day < bounds.previousEnd
                && (deviceID == nil || $0.deviceID == deviceID)
        }
        selectedUsage = filtered
        rows = Self.makeRows(filtered)
        dailySeries = Self.makeDailySeries(filtered, calendar: calendar)
        totalTokens = filtered.reduce(0) { $0 + $1.totalTokens }
        estimatedCostUSD = filtered.reduce(Decimal.zero) {
            $0 + $1.estimatedCostUSD
        }
        tokenComposition = TokenComposition(
            inputTokens: filtered.reduce(0) { $0 + $1.inputTokens },
            outputTokens: filtered.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: filtered.reduce(0) { $0 + $1.cacheReadTokens },
            cacheWriteTokens: filtered.reduce(0) { $0 + $1.cacheWriteTokens }
        )
        periodComparison = PeriodComparison(
            currentTokens: totalTokens,
            previousTokens: previous.reduce(0) { $0 + $1.totalTokens }
        )
        isCostComplete = filtered.allSatisfy(\.isCostComplete)
        latestQuotas = Self.latestQuotas(snapshot.quotaSnapshots)
        collectorErrors = snapshot.collectorStatuses.filter { $0.errorCode != nil }
        lastCollectionAt = snapshot.devices.compactMap(\.lastCollectedAt).max()
        lastSyncAt = snapshot.devices.compactMap(\.lastSyncedAt).max()
    }

    public func deviceName(for id: String) -> String {
        deviceNamesByID[id] ?? id
    }

    private struct PeriodBounds {
        let currentStart: Date
        let currentEnd: Date
        let previousStart: Date
        let previousEnd: Date
    }

    private static func periodBounds(
        for period: DashboardPeriod,
        now: Date,
        calendar: Calendar
    ) -> PeriodBounds {
        let today = calendar.startOfDay(for: now)
        let currentEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: today
        ) ?? now
        let component: Calendar.Component
        let length: Int
        switch period {
        case .today:
            component = .day
            length = 1
        case .sevenDays:
            component = .day
            length = 7
        case .twoWeeks:
            component = .day
            length = 14
        case .oneMonth, .month:
            component = .month
            length = 1
        case .threeMonths:
            component = .month
            length = 3
        case .sixMonths:
            component = .month
            length = 6
        case .oneYear:
            component = .year
            length = 1
        }
        let currentStart = calendar.date(
            byAdding: component,
            value: -length,
            to: currentEnd
        ) ?? today
        let previousStart = calendar.date(
            byAdding: component,
            value: -length,
            to: currentStart
        ) ?? currentStart
        return PeriodBounds(
            currentStart: currentStart,
            currentEnd: currentEnd,
            previousStart: previousStart,
            previousEnd: currentStart
        )
    }

    private static func makeRows(_ usage: [DailyUsage]) -> [DashboardRow] {
        struct Key: Hashable {
            let deviceID: String
            let source: UsageSource
            let provider: String
            let model: String
        }
        var totals: [Key: (tokens: Int, cost: Decimal)] = [:]
        for item in usage {
            let key = Key(
                deviceID: item.deviceID,
                source: item.source,
                provider: item.provider,
                model: item.model
            )
            let current = totals[key] ?? (0, .zero)
            totals[key] = (
                current.tokens + item.totalTokens,
                current.cost + item.estimatedCostUSD
            )
        }
        return totals.map { key, value in
            DashboardRow(
                deviceID: key.deviceID,
                source: key.source,
                provider: key.provider,
                model: key.model,
                totalTokens: value.tokens,
                estimatedCostUSD: value.cost
            )
        }
        .sorted {
            ($0.deviceID, $0.provider, $0.model)
                < ($1.deviceID, $1.provider, $1.model)
        }
    }

    private static func makeDailySeries(
        _ usage: [DailyUsage],
        calendar: Calendar
    ) -> [DailyUsagePoint] {
        let totals = Dictionary(grouping: usage) {
            calendar.startOfDay(for: $0.day)
        }
        return totals.map { day, items in
            DailyUsagePoint(
                day: day,
                totalTokens: items.reduce(0) { $0 + $1.totalTokens },
                estimatedCostUSD: items.reduce(.zero) {
                    $0 + $1.estimatedCostUSD
                },
                eventCount: items.reduce(0) { $0 + $1.eventCount },
                isCostComplete: items.allSatisfy(\.isCostComplete)
            )
        }
        .sorted { $0.day < $1.day }
    }

    private static func latestQuotas(
        _ snapshots: [QuotaSnapshot]
    ) -> [QuotaSnapshot] {
        struct Key: Hashable {
            let provider: String
            let accountPseudonym: String
            let windowKind: String
        }
        var latest: [Key: QuotaSnapshot] = [:]
        for snapshot in snapshots {
            let key = Key(
                provider: snapshot.provider,
                accountPseudonym: snapshot.accountPseudonym,
                windowKind: snapshot.windowKind
            )
            if latest[key].map({ $0.capturedAt < snapshot.capturedAt }) ?? true {
                latest[key] = snapshot
            }
        }
        return latest.values.sorted {
            ($0.provider, $0.windowKind) < ($1.provider, $1.windowKind)
        }
    }
}

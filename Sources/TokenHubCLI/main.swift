import Darwin
import Foundation
import TokenHubCore

private struct CLIError: Error, CustomStringConvertible {
    let description: String
}

private struct Output: Encodable {
    struct Row: Encodable {
        let deviceID: String
        let source: String
        let provider: String
        let model: String
        let totalTokens: Int
        let estimatedCostUSD: String
        let eventCount: Int
    }

    struct Status: Encodable {
        let source: String
        let errorCode: String?
    }

    let totalTokens: Int
    let eventCount: Int
    let estimatedCostUSD: String
    let rows: [Row]
    let collectorStatuses: [Status]

    init(snapshot: DashboardSnapshot) {
        totalTokens = snapshot.dailyUsage.reduce(0) { $0 + $1.totalTokens }
        eventCount = snapshot.dailyUsage.reduce(0) { $0 + $1.eventCount }
        let cost = snapshot.dailyUsage.reduce(Decimal.zero) {
            $0 + $1.estimatedCostUSD
        }
        estimatedCostUSD = NSDecimalNumber(decimal: cost).stringValue
        rows = snapshot.dailyUsage.map {
            Row(
                deviceID: $0.deviceID,
                source: $0.source.rawValue,
                provider: $0.provider,
                model: $0.model,
                totalTokens: $0.totalTokens,
                estimatedCostUSD: NSDecimalNumber(
                    decimal: $0.estimatedCostUSD
                ).stringValue,
                eventCount: $0.eventCount
            )
        }
        collectorStatuses = snapshot.collectorStatuses.map {
            Status(source: $0.source.rawValue, errorCode: $0.errorCode)
        }
    }
}

private struct QuotaOutput: Encodable {
    struct Window: Encodable {
        let windowKind: String
        let usedPercent: String
        let resetsAt: Date?
    }

    let provider: String
    let capturedAt: Date
    let freshness: String
    let windows: [Window]

    init(result: LiveQuotaFetchResult) {
        provider = result.provider.rawValue
        capturedAt = result.capturedAt
        freshness = "fresh"
        windows = result.snapshots.map {
            Window(
                windowKind: $0.windowKind,
                usedPercent: NSDecimalNumber(
                    decimal: $0.usedPercent
                ).stringValue,
                resetsAt: $0.resetsAt
            )
        }
    }
}

private struct Options {
    var databaseURL: URL?
    var senpiRoot: URL?
    var codexRoot: URL?
    var claudeRoot: URL?
    var deviceID: String?
    var deviceName: String?

    static func parse(_ arguments: [String]) throws -> Options {
        guard arguments.first == "collect" else {
            throw CLIError(
                description: "usage: contextgauge collect [--database PATH] "
                    + "[--senpi-root PATH] [--codex-root PATH] "
                    + "[--claude-root PATH] [--device-id ID] [--device-name NAME]"
            )
        }
        var options = Options()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw CLIError(description: "missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--database":
                options.databaseURL = URL(filePath: value)
            case "--senpi-root":
                options.senpiRoot = URL(filePath: value)
            case "--codex-root":
                options.codexRoot = URL(filePath: value)
            case "--claude-root":
                options.claudeRoot = URL(filePath: value)
            case "--device-id":
                options.deviceID = value
            case "--device-name":
                options.deviceName = value
            default:
                throw CLIError(description: "unknown option \(flag)")
            }
            index += 2
        }
        return options
    }
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private let helpText = """
usage:
  contextgauge collect [--database PATH] [--senpi-root PATH] \
[--codex-root PATH] [--claude-root PATH] [--device-id ID] \
[--device-name NAME]
  contextgauge quota --provider codex|claude --account-profile <pseudonym>
  contextgauge export --period today|7-days|month --format csv --output <file>
  contextgauge --help
"""

private func writeHelp() {
    FileHandle.standardOutput.write(Data("\(helpText)\n".utf8))
}

private func runCollect(_ arguments: [String]) throws {
    let options = try Options.parse(arguments)
    let defaults = try LocalUsageConfiguration.systemDefault()
    var roots = defaults.roots
    if let senpiRoot = options.senpiRoot { roots[.senpi] = senpiRoot }
    if let codexRoot = options.codexRoot { roots[.codex] = codexRoot }
    if let claudeRoot = options.claudeRoot { roots[.claude] = claudeRoot }
    let configuration = LocalUsageConfiguration(
        databaseURL: options.databaseURL ?? defaults.databaseURL,
        deviceID: options.deviceID ?? defaults.deviceID,
        deviceName: options.deviceName ?? defaults.deviceName,
        roots: roots,
        parserVersion: defaults.parserVersion
    )
    let snapshot = try LocalUsageService(configuration: configuration).collect()
    try writeJSON(Output(snapshot: snapshot))
}

private func runQuota(_ arguments: [String]) async throws {
    guard arguments.count == 5,
          arguments[0] == "quota",
          arguments[1] == "--provider",
          let provider = LiveQuotaProvider(rawValue: arguments[2]),
          arguments[3] == "--account-profile",
          !arguments[4].isEmpty
    else {
        throw CLIError(
            description: "usage: contextgauge quota --provider codex|claude "
                + "--account-profile <pseudonym>"
        )
    }
    let credential = try LiveQuotaCredentialLoader.systemCredential(
        for: provider
    )
    let result = try await LiveQuotaService().fetch(
        credential,
        accountPseudonym: arguments[4]
    )
    try writeJSON(QuotaOutput(result: result))
}

private func runExport(_ arguments: [String]) throws {
    guard arguments.count == 7,
          arguments[0] == "export",
          arguments[1] == "--period",
          arguments[3] == "--format",
          arguments[4] == "csv",
          arguments[5] == "--output",
          let period = exportPeriod(arguments[2])
    else {
        throw CLIError(
            description: "usage: contextgauge export --period "
                + "today|7-days|month --format csv --output <file>"
        )
    }
    let snapshot = try LocalUsageService(
        configuration: LocalUsageConfiguration.systemDefault()
    ).collect()
    let csv = AggregateCSVExporter.export(
        snapshot: snapshot,
        period: period,
        deviceID: nil
    )
    do {
        try Data(csv.utf8).write(
            to: URL(fileURLWithPath: arguments[6]),
            options: .atomic
        )
    } catch {
        throw CLIError(description: "export-failed")
    }
    FileHandle.standardOutput.write(Data("exported\n".utf8))
}

private func exportPeriod(_ value: String) -> DashboardPeriod? {
    switch value {
    case "today": .today
    case "7-days": .sevenDays
    case "month": .month
    default: nil
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["help"] {
        writeHelp()
    } else if arguments.first == "quota" {
        try await runQuota(arguments)
    } else if arguments.first == "export" {
        try runExport(arguments)
    } else {
        try runCollect(arguments)
    }
} catch {
    FileHandle.standardError.write(Data("contextgauge: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

import Foundation
#if os(macOS)
import LocalAuthentication
import Security
#endif

public enum LiveQuotaProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum LiveQuotaError: Error, Equatable, Sendable, CustomStringConvertible {
    case credentialsUnavailable
    case invalidCredentials
    case invalidRequest
    case unauthorized
    case rateLimited
    case providerFailure
    case invalidResponse
    case network

    public var description: String {
        switch self {
        case .credentialsUnavailable: "credentials-unavailable"
        case .invalidCredentials: "invalid-credentials"
        case .invalidRequest: "invalid-request"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate-limited"
        case .providerFailure: "provider-failure"
        case .invalidResponse: "invalid-response"
        case .network: "network-failure"
        }
    }
}

public struct LiveQuotaHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public struct LiveQuotaFetchResult: Sendable {
    public let provider: LiveQuotaProvider
    public let capturedAt: Date
    public let snapshots: [QuotaSnapshot]

    public init(
        provider: LiveQuotaProvider,
        capturedAt: Date,
        snapshots: [QuotaSnapshot]
    ) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.snapshots = snapshots
    }
}

public struct LiveQuotaCredential: Sendable {
    public let provider: LiveQuotaProvider
    fileprivate let accessToken: String
    fileprivate let accountID: String?

    fileprivate init(
        provider: LiveQuotaProvider,
        accessToken: String,
        accountID: String?
    ) {
        self.provider = provider
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public enum LiveQuotaCredentialLoader {
    public static func systemCredential(
        for provider: LiveQuotaProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveQuotaCredential {
        switch provider {
        case .codex:
            let home = environment["CODEX_HOME"].flatMap(Self.nonempty)
                .map { URL(fileURLWithPath: $0) }
                ?? homeURL(environment: environment)
                    .appending(path: ".codex", directoryHint: .isDirectory)
            return try loadCodex(from: home.appending(path: "auth.json"))
        case .claude:
            let root = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
                .flatMap(Self.nonempty)
                .map { URL(fileURLWithPath: $0) }
                ?? environment["CLAUDE_CONFIG_DIR"]
                .flatMap(Self.nonempty)
                .map { URL(fileURLWithPath: $0) }
                ?? homeURL(environment: environment)
                    .appending(path: ".claude", directoryHint: .isDirectory)
            let credentialsURL = root.appending(path: ".credentials.json")
            if let data = try? Data(contentsOf: credentialsURL),
               let credential = try? claude(data: data)
            {
                return credential
            }
            #if os(macOS)
            if let data = claudeKeychainData(),
               let credential = try? claude(data: data)
            {
                return credential
            }
            #endif
            throw LiveQuotaError.credentialsUnavailable
        }
    }

    public static func loadCodex(from url: URL) throws -> LiveQuotaCredential {
        guard let data = try? Data(contentsOf: url) else {
            throw LiveQuotaError.credentialsUnavailable
        }
        return try codex(data: data)
    }

    public static func codex(data: Data) throws -> LiveQuotaCredential {
        guard
            let root = try? JSONDecoder().decode(CodexCredentialRoot.self, from: data),
            let tokens = root.tokens,
            let accessToken = nonempty(tokens.accessToken),
            nonempty(tokens.accountID) != nil || nonempty(tokens.refreshToken) != nil
        else {
            throw LiveQuotaError.invalidCredentials
        }
        return LiveQuotaCredential(
            provider: .codex,
            accessToken: accessToken,
            accountID: nonempty(tokens.accountID)
        )
    }

    public static func claude(data: Data) throws -> LiveQuotaCredential {
        guard
            let root = try? JSONDecoder().decode(ClaudeCredentialRoot.self, from: data),
            let accessToken = nonempty(root.claudeAiOauth?.accessToken)
        else {
            throw LiveQuotaError.invalidCredentials
        }
        return LiveQuotaCredential(
            provider: .claude,
            accessToken: accessToken,
            accountID: nil
        )
    }

    private static func homeURL(environment: [String: String]) -> URL {
        if let home = environment["HOME"].flatMap(Self.nonempty) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    #if os(macOS)
    private static func claudeKeychainData() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else {
            return nil
        }
        return result as? Data
    }
    #endif

    private struct CodexCredentialRoot: Decodable {
        let tokens: CodexTokens?
    }

    private struct CodexTokens: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountID = "account_id"
        }
    }

    private struct ClaudeCredentialRoot: Decodable {
        let claudeAiOauth: ClaudeOAuth?
    }

    private struct ClaudeOAuth: Decodable {
        let accessToken: String?
    }
}

public struct LiveQuotaService: Sendable {
    public typealias Transport =
        @Sendable (URLRequest) async throws -> LiveQuotaHTTPResponse

    private let transport: Transport
    private let now: @Sendable () -> Date

    public init(
        transport: @escaping Transport = Self.urlSessionTransport,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.now = now
    }

    public func fetch(
        _ credential: LiveQuotaCredential,
        accountPseudonym: String
    ) async throws -> LiveQuotaFetchResult {
        let request = try Self.request(for: credential)
        let response: LiveQuotaHTTPResponse
        do {
            response = try await transport(request)
        } catch let error as LiveQuotaError {
            throw error
        } catch {
            throw LiveQuotaError.network
        }
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw LiveQuotaError.unauthorized
        case 429:
            throw LiveQuotaError.rateLimited
        default:
            throw LiveQuotaError.providerFailure
        }

        let capturedAt = now()
        let snapshots: [QuotaSnapshot]
        switch credential.provider {
        case .codex:
            snapshots = try Self.codexSnapshots(
                response.body,
                accountPseudonym: accountPseudonym,
                capturedAt: capturedAt
            )
        case .claude:
            snapshots = try Self.claudeSnapshots(
                response.body,
                accountPseudonym: accountPseudonym,
                capturedAt: capturedAt
            )
        }
        guard !snapshots.isEmpty else {
            throw LiveQuotaError.invalidResponse
        }
        return LiveQuotaFetchResult(
            provider: credential.provider,
            capturedAt: capturedAt,
            snapshots: snapshots
        )
    }

    public static func urlSessionTransport(
        _ request: URLRequest
    ) async throws -> LiveQuotaHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LiveQuotaError.invalidResponse
        }
        return LiveQuotaHTTPResponse(
            statusCode: response.statusCode,
            body: data
        )
    }

    private static func request(
        for credential: LiveQuotaCredential
    ) throws -> URLRequest {
        let url: URL
        switch credential.provider {
        case .codex:
            guard let value = URL(
                string: "https://chatgpt.com/backend-api/wham/usage"
            ) else {
                throw LiveQuotaError.invalidRequest
            }
            url = value
        case .claude:
            guard let value = URL(
                string: "https://api.anthropic.com/api/oauth/usage"
            ) else {
                throw LiveQuotaError.invalidRequest
            }
            url = value
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(
            "Bearer \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        switch credential.provider {
        case .codex:
            request.setValue(
                "codex-cli",
                forHTTPHeaderField: "User-Agent"
            )
            if let accountID = credential.accountID {
                request.setValue(
                    accountID,
                    forHTTPHeaderField: "ChatGPT-Account-Id"
                )
            }
        case .claude:
            request.setValue(
                "claude-cli/2.1.0 (external, cli)",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(
                "oauth-2025-04-20",
                forHTTPHeaderField: "anthropic-beta"
            )
        }
        return request
    }

    private static func codexSnapshots(
        _ data: Data,
        accountPseudonym: String,
        capturedAt: Date
    ) throws -> [QuotaSnapshot] {
        guard
            let response = try? JSONDecoder().decode(
                CodexUsageResponse.self,
                from: data
            ),
            let rateLimit = response.rateLimit
        else {
            throw LiveQuotaError.invalidResponse
        }
        return [
            rateLimit.primaryWindow.map {
                codexSnapshot(
                    $0,
                    fallbackKind: "5-hour",
                    accountPseudonym: accountPseudonym,
                    capturedAt: capturedAt
                )
            },
            rateLimit.secondaryWindow.map {
                codexSnapshot(
                    $0,
                    fallbackKind: "weekly",
                    accountPseudonym: accountPseudonym,
                    capturedAt: capturedAt
                )
            },
        ]
        .compactMap(\.self)
    }

    private static func codexSnapshot(
        _ window: CodexWindow,
        fallbackKind: String,
        accountPseudonym: String,
        capturedAt: Date
    ) -> QuotaSnapshot {
        let kind: String
        switch window.limitWindowSeconds {
        case 18_000:
            kind = "5-hour"
        case 604_800:
            kind = "weekly"
        default:
            kind = fallbackKind
        }
        return QuotaSnapshot(
            provider: LiveQuotaProvider.codex.rawValue,
            accountPseudonym: accountPseudonym,
            capturedAt: capturedAt,
            windowKind: kind,
            usedPercent: window.usedPercent,
            resetsAt: Date(
                timeIntervalSince1970: TimeInterval(window.resetAt)
            ),
            source: "codex-oauth"
        )
    }

    private static func claudeSnapshots(
        _ data: Data,
        accountPseudonym: String,
        capturedAt: Date
    ) throws -> [QuotaSnapshot] {
        guard let response = try? JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: data
        ) else {
            throw LiveQuotaError.invalidResponse
        }
        return [
            response.fiveHour.map {
                claudeSnapshot(
                    $0,
                    kind: "5-hour",
                    accountPseudonym: accountPseudonym,
                    capturedAt: capturedAt
                )
            },
            response.sevenDay.map {
                claudeSnapshot(
                    $0,
                    kind: "weekly",
                    accountPseudonym: accountPseudonym,
                    capturedAt: capturedAt
                )
            },
        ]
        .compactMap(\.self)
    }

    private static func claudeSnapshot(
        _ window: ClaudeWindow,
        kind: String,
        accountPseudonym: String,
        capturedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: LiveQuotaProvider.claude.rawValue,
            accountPseudonym: accountPseudonym,
            capturedAt: capturedAt,
            windowKind: kind,
            usedPercent: window.utilization,
            resetsAt: parseISO8601(window.resetsAt),
            source: "claude-oauth"
        )
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private struct CodexUsageResponse: Decodable {
        let rateLimit: CodexRateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }
    }

    private struct CodexRateLimit: Decodable {
        let primaryWindow: CodexWindow?
        let secondaryWindow: CodexWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct CodexWindow: Decodable {
        let usedPercent: Decimal
        let resetAt: Int64
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    private struct ClaudeUsageResponse: Decodable {
        let fiveHour: ClaudeWindow?
        let sevenDay: ClaudeWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct ClaudeWindow: Decodable {
        let utilization: Decimal
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

public enum LiveQuotaFreshness: String, Codable, Hashable, Sendable {
    case disabled
    case configurationRequired
    case fresh
    case stale
    case unavailable
    case error
}

public struct LiveQuotaProviderStatus: Codable, Hashable, Sendable {
    public let deviceID: String
    public let provider: LiveQuotaProvider
    public let accountPseudonym: String?
    public let freshness: LiveQuotaFreshness
    public let checkedAt: Date
    public let capturedAt: Date?
    public let errorCode: String?

    public init(
        deviceID: String,
        provider: LiveQuotaProvider,
        accountPseudonym: String?,
        freshness: LiveQuotaFreshness,
        checkedAt: Date,
        capturedAt: Date?,
        errorCode: String?
    ) {
        self.deviceID = deviceID
        self.provider = provider
        self.accountPseudonym = accountPseudonym
        self.freshness = freshness
        self.checkedAt = checkedAt
        self.capturedAt = capturedAt
        self.errorCode = errorCode
    }
}

public struct LiveQuotaRefreshReport: Sendable {
    public let snapshots: [QuotaSnapshot]
    public let statuses: [LiveQuotaProviderStatus]

    public init(
        snapshots: [QuotaSnapshot],
        statuses: [LiveQuotaProviderStatus]
    ) {
        self.snapshots = snapshots
        self.statuses = statuses
    }

    public static let empty = LiveQuotaRefreshReport(
        snapshots: [],
        statuses: []
    )
}

public struct QuotaThresholdWarning: Hashable, Sendable, Identifiable {
    public let provider: String
    public let windowKind: String
    public let usedPercent: Decimal
    public let resetsAt: Date?
    public let id: String

    public init(
        provider: String,
        windowKind: String,
        usedPercent: Decimal,
        resetsAt: Date?
    ) {
        self.provider = provider
        self.windowKind = windowKind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        let resetKey = resetsAt.map {
            String(Int($0.timeIntervalSince1970))
        } ?? "unknown"
        id = "\(provider)\u{1F}\(windowKind)\u{1F}\(resetKey)"
    }
}

public enum QuotaThresholdEvaluator {
    public static func warnings(
        snapshots: [QuotaSnapshot],
        threshold: Decimal = 80
    ) -> [QuotaThresholdWarning] {
        snapshots
            .filter { $0.usedPercent >= threshold }
            .map {
                QuotaThresholdWarning(
                    provider: $0.provider,
                    windowKind: $0.windowKind,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
            .sorted {
                ($0.provider, $0.windowKind) < ($1.provider, $1.windowKind)
            }
    }
}

public struct LiveQuotaRefreshCoordinator: Sendable {
    public typealias CredentialProvider =
        @Sendable (LiveQuotaProvider) throws -> LiveQuotaCredential
    public typealias Fetcher =
        @Sendable (
            LiveQuotaCredential,
            String
        ) async throws -> LiveQuotaFetchResult

    private let credentialProvider: CredentialProvider
    private let fetcher: Fetcher

    public init(
        credentialProvider: @escaping CredentialProvider = {
            try LiveQuotaCredentialLoader.systemCredential(for: $0)
        },
        fetcher: @escaping Fetcher = { credential, accountPseudonym in
            try await LiveQuotaService().fetch(
                credential,
                accountPseudonym: accountPseudonym
            )
        }
    ) {
        self.credentialProvider = credentialProvider
        self.fetcher = fetcher
    }

    public func refresh(
        providers: [LiveQuotaProvider: String],
        deviceID: String,
        previousSnapshots: [QuotaSnapshot],
        now: Date = .now
    ) async -> LiveQuotaRefreshReport {
        var snapshots: [QuotaSnapshot] = []
        var statuses: [LiveQuotaProviderStatus] = []
        for provider in LiveQuotaProvider.allCases {
            guard let accountPseudonym = providers[provider] else {
                continue
            }
            do {
                let credential = try credentialProvider(provider)
                let result = try await fetcher(
                    credential,
                    accountPseudonym
                )
                snapshots.append(contentsOf: result.snapshots)
                statuses.append(
                    LiveQuotaProviderStatus(
                        deviceID: deviceID,
                        provider: provider,
                        accountPseudonym: accountPseudonym,
                        freshness: .fresh,
                        checkedAt: result.capturedAt,
                        capturedAt: result.capturedAt,
                        errorCode: nil
                    )
                )
            } catch {
                let code = Self.errorCode(error)
                let previous = previousSnapshots
                    .filter {
                        $0.provider == provider.rawValue
                            && $0.accountPseudonym == accountPseudonym
                    }
                    .map(\.capturedAt)
                    .max()
                let freshness: LiveQuotaFreshness
                if code == LiveQuotaError.credentialsUnavailable.description {
                    freshness = .unavailable
                } else {
                    freshness = previous == nil ? .error : .stale
                }
                statuses.append(
                    LiveQuotaProviderStatus(
                        deviceID: deviceID,
                        provider: provider,
                        accountPseudonym: accountPseudonym,
                        freshness: freshness,
                        checkedAt: now,
                        capturedAt: previous,
                        errorCode: code
                    )
                )
            }
        }
        return LiveQuotaRefreshReport(
            snapshots: snapshots.sorted {
                ($0.provider, $0.windowKind)
                    < ($1.provider, $1.windowKind)
            },
            statuses: statuses
        )
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? LiveQuotaError {
            return error.description
        }
        return LiveQuotaError.network.description
    }
}

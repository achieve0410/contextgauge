import Foundation
import Testing
@testable import TokenHubCore

@Suite("Live provider quota")
struct LiveQuotaServiceTests {
    @Test("Codex usage maps session and weekly windows")
    func codexUsageMapsSessionAndWeeklyWindows() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_786_233_600)
        let credential = try LiveQuotaCredentialLoader.codex(
            data: Data(
                #"""
                {
                  "tokens": {
                    "access_token": "codex-secret-token",
                    "account_id": "account-123"
                  }
                }
                """#.utf8
            )
        )
        let recorder = RequestRecorder(
            statusCode: 200,
            body: Data(
                #"""
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 42,
                      "reset_at": 1786251600,
                      "limit_window_seconds": 18000
                    },
                    "secondary_window": {
                      "used_percent": 75,
                      "reset_at": 1786838400,
                      "limit_window_seconds": 604800
                    }
                  }
                }
                """#.utf8
            )
        )
        let service = LiveQuotaService(
            transport: { request in
                await recorder.response(for: request)
            },
            now: { capturedAt }
        )

        let result = try await service.fetch(
            credential,
            accountPseudonym: "codex-profile"
        )
        let request = try #require(await recorder.lastRequest())

        #expect(result.provider == .codex)
        #expect(result.capturedAt == capturedAt)
        #expect(result.snapshots.map(\.windowKind) == ["5-hour", "weekly"])
        #expect(
            result.snapshots.map(\.usedPercent)
                == [Decimal(42), Decimal(75)]
        )
        #expect(
            result.snapshots.map(\.resetsAt)
                == [
                    Date(timeIntervalSince1970: 1_786_251_600),
                    Date(timeIntervalSince1970: 1_786_838_400),
                ]
        )
        #expect(
            request.url?.absoluteString
                == "https://chatgpt.com/backend-api/wham/usage"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer codex-secret-token"
        )
        #expect(
            request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
                == "account-123"
        )
    }

    @Test("Claude usage maps five hour and seven day windows")
    func claudeUsageMapsFiveHourAndSevenDayWindows() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_786_233_600)
        let credential = try LiveQuotaCredentialLoader.claude(
            data: Data(
                #"""
                {
                  "claudeAiOauth": {
                    "accessToken": "claude-secret-token"
                  }
                }
                """#.utf8
            )
        )
        let recorder = RequestRecorder(
            statusCode: 200,
            body: Data(
                #"""
                {
                  "five_hour": {
                    "utilization": 12.5,
                    "resets_at": "2026-08-09T12:00:00Z"
                  },
                  "seven_day": {
                    "utilization": 64,
                    "resets_at": "2026-08-15T00:00:00Z"
                  }
                }
                """#.utf8
            )
        )
        let service = LiveQuotaService(
            transport: { request in
                await recorder.response(for: request)
            },
            now: { capturedAt }
        )

        let result = try await service.fetch(
            credential,
            accountPseudonym: "claude-profile"
        )
        let request = try #require(await recorder.lastRequest())

        #expect(result.provider == .claude)
        #expect(result.snapshots.map(\.windowKind) == ["5-hour", "weekly"])
        #expect(
            result.snapshots.map(\.usedPercent)
                == [Decimal(string: "12.5"), Decimal(64)]
        )
        #expect(
            request.url?.absoluteString
                == "https://api.anthropic.com/api/oauth/usage"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer claude-secret-token"
        )
        #expect(
            request.value(forHTTPHeaderField: "anthropic-beta")
                == "oauth-2025-04-20"
        )
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "claude-cli/2.1.0 (external, cli)"
        )
    }

    @Test("Credential failures and provider errors never expose secrets")
    func failuresAreSanitized() async throws {
        #expect(throws: LiveQuotaError.credentialsUnavailable) {
            _ = try LiveQuotaCredentialLoader.loadCodex(
                from: URL(filePath: "/definitely/missing/tokenhub-auth.json")
            )
        }

        let embeddedSecret = "must-never-escape"
        do {
            _ = try LiveQuotaCredentialLoader.codex(
                data: Data(
                    #"{"tokens":{"access_token":"\#(embeddedSecret)"}}"#.utf8
                )
            )
            Issue.record("Malformed credentials unexpectedly parsed")
        } catch {
            #expect(!String(describing: error).contains(embeddedSecret))
        }

        let credential = try LiveQuotaCredentialLoader.codex(
            data: Data(
                #"""
                {
                  "tokens": {
                    "access_token": "network-secret",
                    "refresh_token": "refresh-secret"
                  }
                }
                """#.utf8
            )
        )
        let recorder = RequestRecorder(
            statusCode: 401,
            body: Data(
                #"{"error":"Bearer network-secret refresh-secret"}"#.utf8
            )
        )
        let service = LiveQuotaService { request in
            await recorder.response(for: request)
        }

        do {
            _ = try await service.fetch(
                credential,
                accountPseudonym: "failure-profile"
            )
            Issue.record("Unauthorized provider response unexpectedly succeeded")
        } catch {
            let description = String(describing: error)
            #expect(description == LiveQuotaError.unauthorized.description)
            #expect(!description.contains("network-secret"))
            #expect(!description.contains("refresh-secret"))
            #expect(!description.contains("Bearer"))
        }
    }

    @Test("Selected account profile survives access token rotation")
    func selectedAccountProfileSurvivesTokenRotation() async throws {
        let profile = QuotaAccountProfile(
            id: "profile-pseudonym",
            provider: .claude,
            displayName: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_786_233_600)
        )
        let firstCredential = try LiveQuotaCredentialLoader.claude(
            data: Data(
                #"{"claudeAiOauth":{"accessToken":"first-secret-token"}}"#.utf8
            )
        )
        let rotatedCredential = try LiveQuotaCredentialLoader.claude(
            data: Data(
                #"{"claudeAiOauth":{"accessToken":"rotated-secret-token"}}"#.utf8
            )
        )
        let body = Data(
            #"{"five_hour":{"utilization":25}}"#.utf8
        )
        let service = LiveQuotaService(
            transport: { _ in
                LiveQuotaHTTPResponse(statusCode: 200, body: body)
            },
            now: { profile.createdAt }
        )

        let first = try await service.fetch(
            firstCredential,
            accountPseudonym: profile.id
        )
        let rotated = try await service.fetch(
            rotatedCredential,
            accountPseudonym: profile.id
        )

        #expect(first.snapshots.map(\.accountPseudonym) == [profile.id])
        #expect(rotated.snapshots.map(\.accountPseudonym) == [profile.id])
        #expect(first.snapshots == rotated.snapshots)
        let encoded = String(
            decoding: try JSONEncoder().encode(first.snapshots),
            as: UTF8.self
        )
        #expect(!encoded.contains("first-secret-token"))
        #expect(!encoded.contains("rotated-secret-token"))
    }
}

private actor RequestRecorder {
    private let statusCode: Int
    private let body: Data
    private var request: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func response(for request: URLRequest) -> LiveQuotaHTTPResponse {
        self.request = request
        return LiveQuotaHTTPResponse(
            statusCode: statusCode,
            body: body
        )
    }

    func lastRequest() -> URLRequest? {
        request
    }
}

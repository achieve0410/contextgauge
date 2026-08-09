import Foundation
import Testing
@testable import TokenHubCore

@Suite("Quota account profiles")
struct QuotaAccountDirectoryTests {
    @Test("Profiles are opaque 256-bit base64url identifiers")
    func profilesAreOpaque() async throws {
        let directory = InMemoryCloudSync()

        let first = try await directory.createAccount(
            provider: .claude,
            displayName: "Personal"
        )
        let second = try await directory.createAccount(
            provider: .claude,
            displayName: "Work"
        )

        #expect(first.id.count == 43)
        #expect(
            first.id.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
        )
        #expect(first.id != second.id)
        #expect(first.provider == .claude)
        #expect(first.displayName == "Personal")
    }

    @Test("All clients observe the same saved profiles")
    func profilesAreShared() async throws {
        let directory = InMemoryCloudSync()
        let created = try await directory.createAccount(
            provider: .codex,
            displayName: "Personal"
        )

        let firstClient = try await directory.accounts(for: .codex)
        let secondClient = try await directory.accounts(for: .codex)

        #expect(firstClient == [created])
        #expect(secondClient == [created])
        #expect(try await directory.accounts(for: .claude).isEmpty)
    }
}

import AppKit
import Combine
import SwiftUI
import TokenHubMacCore
import XCTest
@testable import TokenHubMac

final class MacVisualSnapshotTests: XCTestCase {
    @MainActor
    func testQuotaProvidersDefaultOffWithoutCredentialRefresh() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let suiteName = "TokenHubMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = UserDefaultsProviderQuotaPreferences(
            defaults: defaults
        )
        let recorder = ProviderSelectionRecorder()
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: databaseURL,
                    deviceID: "default-off",
                    deviceName: "Default Off",
                    roots: [:],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { selections, _, _ in
                await recorder.record(selections)
                return LiveQuotaRefreshReport(snapshots: [], statuses: [])
            }
        )

        await controller.refresh()

        XCTAssertFalse(controller.quotaSelection(for: .codex).isEnabled)
        XCTAssertFalse(controller.quotaSelection(for: .claude).isEnabled)
        let selections = await recorder.lastSelections()
        XCTAssertEqual(selections, [:])
    }

    @MainActor
    func testEnabledProviderUsesSelectedAccountProfile() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let suiteName = "TokenHubMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferences = UserDefaultsProviderQuotaPreferences(
            defaults: defaults
        )
        preferences.setSelection(
            ProviderQuotaSelection(
                isEnabled: true,
                accountPseudonym: "codex-profile"
            ),
            for: .codex
        )
        let recorder = ProviderSelectionRecorder()
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: databaseURL,
                    deviceID: "enabled",
                    deviceName: "Enabled",
                    roots: [:],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { selections, _, _ in
                await recorder.record(selections)
                return LiveQuotaRefreshReport(snapshots: [], statuses: [])
            }
        )

        await controller.refresh()

        let selections = await recorder.lastSelections()
        XCTAssertEqual(selections, [.codex: "codex-profile"])
    }

    @MainActor
    func testEnablingProviderCreatesOrReusesCloudAccountProfile() async throws {
        let cloud = InMemoryCloudSync()
        let firstDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let firstController = MacDashboardController(
            cloudSyncProvider: { cloud },
            quotaPreferences: UserDefaultsProviderQuotaPreferences(
                defaults: firstDefaults
            )
        )

        await firstController.updateQuotaEnabled(true, for: .claude)

        let firstSelection = firstController.quotaSelection(for: .claude)
        XCTAssertTrue(firstSelection.isEnabled)
        XCTAssertNotNil(firstSelection.accountPseudonym)
        let createdAccounts = await cloud.accounts(for: .claude)
        XCTAssertEqual(createdAccounts.count, 1)

        let secondDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let secondController = MacDashboardController(
            cloudSyncProvider: { cloud },
            quotaPreferences: UserDefaultsProviderQuotaPreferences(
                defaults: secondDefaults
            )
        )

        await secondController.updateQuotaEnabled(true, for: .claude)

        XCTAssertEqual(
            secondController.quotaSelection(for: .claude).accountPseudonym,
            firstSelection.accountPseudonym
        )
        let reusedAccounts = await cloud.accounts(for: .claude)
        XCTAssertEqual(reusedAccounts.count, 1)
    }

    @MainActor
    func testEnablingProviderCreatesLocalAccountWithoutCloudSync() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let preferences = UserDefaultsProviderQuotaPreferences(
            defaults: defaults
        )
        let controller = MacDashboardController(
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { _, _, _ in .empty }
        )

        await controller.updateQuotaEnabled(true, for: .codex)

        let selection = controller.quotaSelection(for: .codex)
        let profile = try XCTUnwrap(
            controller.quotaAccounts[.codex]?.first
        )
        let encodedID = profile.id
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(
            repeating: "=",
            count: (4 - encodedID.count % 4) % 4
        )
        XCTAssertTrue(selection.isEnabled)
        XCTAssertEqual(selection.accountPseudonym, profile.id)
        XCTAssertEqual(profile.displayName, "Local")
        XCTAssertEqual(
            Data(base64Encoded: encodedID + padding)?.count,
            32
        )
        XCTAssertNil(controller.quotaSetupErrors[.codex])

        let reloaded = MacDashboardController(
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { _, _, _ in .empty }
        )
        XCTAssertEqual(
            reloaded.quotaSelection(for: .codex),
            selection
        )
        XCTAssertEqual(
            reloaded.quotaAccounts[.codex]?.map(\.id),
            [profile.id]
        )
    }

    @MainActor
    func testEnabledProviderMigratesToLocalAccountWithoutCloudSync() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let preferences = UserDefaultsProviderQuotaPreferences(
            defaults: defaults
        )
        preferences.setSelection(
            ProviderQuotaSelection(
                isEnabled: true,
                accountPseudonym: nil
            ),
            for: .codex
        )

        let controller = MacDashboardController(
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { _, _, _ in .empty }
        )

        let selection = controller.quotaSelection(for: .codex)
        let profile = try XCTUnwrap(
            controller.quotaAccounts[.codex]?.first
        )
        let encodedID = profile.id
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(
            repeating: "=",
            count: (4 - encodedID.count % 4) % 4
        )
        XCTAssertTrue(selection.isEnabled)
        XCTAssertEqual(selection.accountPseudonym, profile.id)
        XCTAssertEqual(profile.displayName, "Local")
        XCTAssertEqual(
            Data(base64Encoded: encodedID + padding)?.count,
            32
        )
        XCTAssertEqual(
            preferences.selection(for: .codex),
            selection
        )
        XCTAssertNil(controller.quotaSetupErrors[.codex])
    }

    @MainActor
    func testLiveQuotaRefreshAndWarningPresentation() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let capturedAt = Date(timeIntervalSince1970: 1_786_233_600)
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try store.replaceDailyUsage(
            [
                DailyUsage(
                    day: Calendar.current.startOfDay(for: capturedAt),
                    deviceID: "aggregate-fixture",
                    source: .senpi,
                    provider: "openai-codex",
                    model: "gpt-5.6-sol",
                    inputTokens: 50,
                    outputTokens: 20,
                    cacheReadTokens: 25,
                    cacheWriteTokens: 5,
                    totalTokens: 100,
                    estimatedCostUSD: Decimal(string: "0.25")!,
                    eventCount: 4
                ),
            ]
        )
        let recorder = QuotaWarningRecorder()
        let preferences = UserDefaultsProviderQuotaPreferences(
            defaults: try XCTUnwrap(
                UserDefaults(
                    suiteName: "TokenHubMacTests.\(UUID().uuidString)"
                )
            )
        )
        preferences.setSelection(
            ProviderQuotaSelection(
                isEnabled: true,
                accountPseudonym: "account"
            ),
            for: .codex
        )
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: databaseURL,
                    deviceID: "live-quota-mac",
                    deviceName: "Live Quota Mac",
                    roots: [:],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: preferences,
            liveQuotaRefreshProvider: { _, _, _ in
                LiveQuotaRefreshReport(
                    snapshots: [
                        QuotaSnapshot(
                            provider: "codex",
                            accountPseudonym: "account",
                            capturedAt: capturedAt,
                            windowKind: "5-hour",
                            usedPercent: 85,
                            resetsAt: capturedAt.addingTimeInterval(3_600),
                            source: "codex-oauth"
                        ),
                    ],
                    statuses: [
                        LiveQuotaProviderStatus(
                            deviceID: "live-quota-mac",
                            provider: .codex,
                            accountPseudonym: "account",
                            freshness: .fresh,
                            checkedAt: capturedAt,
                            capturedAt: capturedAt,
                            errorCode: nil
                        ),
                        LiveQuotaProviderStatus(
                            deviceID: "live-quota-mac",
                            provider: .claude,
                            accountPseudonym: nil,
                            freshness: .error,
                            checkedAt: capturedAt,
                            capturedAt: nil,
                            errorCode: "credentials-unavailable"
                        ),
                    ]
                )
            },
            quotaWarningSink: { warning in
                await recorder.record(warning)
            }
        )

        await controller.refresh()
        await controller.refresh()

        XCTAssertEqual(
            controller.snapshot?.quotaSnapshots.map(\.usedPercent),
            [Decimal(85)]
        )
        XCTAssertEqual(
            controller.liveQuotaStatuses.map(\.freshness),
            [.fresh, .error]
        )
        XCTAssertEqual(controller.quotaWarnings.count, 1)
        let deliveredWarningCount = await recorder.count()
        XCTAssertEqual(deliveredWarningCount, 1)

        let renderer = ImageRenderer(
            content: TokenHubMenuView(controller: controller, snapshotMode: true)
                .environment(\.colorScheme, .light)
                .fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        XCTAssertNotNil(
            bitmap.representation(using: .png, properties: [:])
        )
        XCTAssertGreaterThan(bitmap.pixelsWide, 700)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 500)
    }

    @MainActor
    func testStartIfNeededRefreshesExactlyOnce() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let recorder = RefreshInvocationRecorder()
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: databaseURL,
                    deviceID: "startup",
                    deviceName: "Startup",
                    roots: [:],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            liveQuotaRefreshProvider: { _, _, _ in
                await recorder.record()
                return .empty
            }
        )

        await controller.startIfNeeded()
        await controller.startIfNeeded()

        let invocations = await recorder.count()
        XCTAssertEqual(invocations, 1)
    }

    func testMenuHeightFitsAvailableDisplay() {
        XCTAssertEqual(
            TokenHubMenuLayout.maximumHeight(
                visibleScreenHeight: 480
            ),
            464
        )
        XCTAssertEqual(
            TokenHubMenuLayout.maximumHeight(
                visibleScreenHeight: 600
            ),
            584
        )
        XCTAssertEqual(
            TokenHubMenuLayout.maximumHeight(
                visibleScreenHeight: 900
            ),
            720
        )
        XCTAssertEqual(
            TokenHubMenuLayout.minimumHeight(
                visibleScreenHeight: 480
            ),
            464
        )
        XCTAssertEqual(
            TokenHubMenuLayout.minimumHeight(
                visibleScreenHeight: 600
            ),
            584
        )
        XCTAssertEqual(
            TokenHubMenuLayout.minimumHeight(
                visibleScreenHeight: 900
            ),
            720
        )
    }

    func testApplicationUsesRegularActivationPolicy() {
        XCTAssertEqual(
            TokenHubApplicationActivation.policy,
            .regular
        )
    }

    func testApplicationIsNotAgentOnly() {
        XCTAssertNotEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            true
        )
    }

    func testDailyUsageChartSelectionUsesClosestDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(secondsFromGMT: 0)
        )
        let firstDay = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 10
                )
            )
        )
        let secondDay = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: firstDay)
        )
        let snapshot = DashboardSnapshot(
            dailyUsage: [
                dailyUsage(day: firstDay, totalTokens: 1_000),
                dailyUsage(day: secondDay, totalTokens: 2_000),
            ],
            quotaSnapshots: [],
            devices: [],
            collectorStatuses: []
        )
        let viewModel = DashboardViewModel(
            snapshot: snapshot,
            period: .sevenDays,
            deviceID: nil,
            now: secondDay,
            calendar: calendar
        )
        let hoveredDate = try XCTUnwrap(
            calendar.date(
                byAdding: .hour,
                value: 20,
                to: firstDay
            )
        )

        let selected = DailyUsageChartSelection.nearestPoint(
            to: hoveredDate,
            in: viewModel.dailySeries
        )

        XCTAssertEqual(selected?.day, secondDay)
        XCTAssertEqual(selected?.totalTokens, 2_000)
    }

    @MainActor
    func testRenderCompactMenuAndSettingsSnapshots() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let evidenceRoot = projectRoot.appending(
            path: ".omo/evidence/market-value",
            directoryHint: .isDirectory
        )
        let snapshotRequest = try? String(
            contentsOf: evidenceRoot.appending(
                path: "snapshot-request.txt"
            ),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let outputDirectory = snapshotRequest.flatMap { request in
            request.isEmpty ? nil : evidenceRoot.appending(
                path: request,
                directoryHint: .isDirectory
            )
        } ?? temporary
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: temporary.appending(path: "usage.sqlite"),
                    deviceID: "responsive-ui",
                    deviceName: "Responsive UI",
                    roots: Dictionary(
                        uniqueKeysWithValues: UsageSource.allCases.map { source in
                            (
                                source,
                                temporary.appending(
                                    path: "missing-\(source.rawValue)"
                                )
                            )
                        }
                    ),
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: UserDefaultsProviderQuotaPreferences(
                defaults: defaults
            )
        )
        await controller.refresh()

        let menuView = NSHostingView(
            rootView: TokenHubMenuView(
                controller: controller,
                snapshotMode: true,
                availableScreenHeight: 480
            )
            .environment(\.colorScheme, .light)
        )
        menuView.frame = NSRect(x: 0, y: 0, width: 420, height: 464)
        menuView.layoutSubtreeIfNeeded()
        try render(
            menuView,
            to: outputDirectory.appending(
                path: "macos-menu-compact.png"
            )
        )

        let settingsView = NSHostingView(
            rootView: TokenHubSettingsView(controller: controller)
                .environment(\.colorScheme, .light)
        )
        settingsView.frame = NSRect(
            x: 0,
            y: 0,
            width: 520,
            height: 420
        )
        settingsView.layoutSubtreeIfNeeded()
        try render(
            settingsView,
            to: outputDirectory.appending(
                path: "macos-settings-compact.png"
            )
        )

        let diagnosticsView = NSHostingView(
            rootView: TokenHubSettingsView(controller: controller)
                .diagnosticsSettings
                .frame(width: 520, height: 420)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
        )
        diagnosticsView.frame = NSRect(
            x: 0,
            y: 0,
            width: 520,
            height: 420
        )
        diagnosticsView.layoutSubtreeIfNeeded()
        try render(
            diagnosticsView,
            to: outputDirectory.appending(
                path: "macos-diagnostics-compact.png"
            )
        )
    }

    @MainActor
    func testRenderQuotaConsentSnapshot() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "TokenHubMacTests.\(UUID().uuidString)"
            )
        )
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: temporary.appending(path: "usage.sqlite"),
                    deviceID: "visual-consent",
                    deviceName: "Visual Consent",
                    roots: [:],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: UserDefaultsProviderQuotaPreferences(
                defaults: defaults
            )
        )
        await controller.refresh()

        let hostingView = NSHostingView(
            rootView: TokenHubSettingsView(controller: controller)
            .environment(\.colorScheme, .light)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 620)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let outputDirectory = temporary
        try png.write(
            to: outputDirectory.appending(
                path: "macos-quota-consent.png"
            ),
            options: .atomic
        )

        await controller.updateQuotaEnabled(true, for: .codex)
        let enabledView = NSHostingView(
            rootView: TokenHubSettingsView(controller: controller)
            .environment(\.colorScheme, .light)
        )
        enabledView.frame = NSRect(
            x: 0,
            y: 0,
            width: 600,
            height: 620
        )
        enabledView.layoutSubtreeIfNeeded()
        let enabledBitmap = try XCTUnwrap(
            enabledView.bitmapImageRepForCachingDisplay(
                in: enabledView.bounds
            )
        )
        enabledView.cacheDisplay(
            in: enabledView.bounds,
            to: enabledBitmap
        )
        let enabledPNG = try XCTUnwrap(
            enabledBitmap.representation(
                using: .png,
                properties: [:]
            )
        )
        try enabledPNG.write(
            to: outputDirectory.appending(
                path: "macos-quota-consent-setup-required.png"
            ),
            options: .atomic
        )

        controller.setQuotaEnabled(false, for: .codex)
        let darkView = NSHostingView(
            rootView: TokenHubSettingsView(controller: controller)
            .environment(\.colorScheme, .dark)
        )
        darkView.frame = NSRect(x: 0, y: 0, width: 600, height: 620)
        darkView.layoutSubtreeIfNeeded()
        let darkBitmap = try XCTUnwrap(
            darkView.bitmapImageRepForCachingDisplay(
                in: darkView.bounds
            )
        )
        darkView.cacheDisplay(in: darkView.bounds, to: darkBitmap)
        let darkPNG = try XCTUnwrap(
            darkBitmap.representation(
                using: .png,
                properties: [:]
            )
        )
        try darkPNG.write(
            to: outputDirectory.appending(
                path: "macos-quota-consent-dark.png"
            ),
            options: .atomic
        )
    }

    @MainActor
    func testPeriodSelectionPublishesAfterBindingSetterReturns() async {
        let controller = MacDashboardController()
        let publication = expectation(description: "period publication")
        var didReturnFromBindingSetter = false
        var publicationWasDeferred = false
        let observation = controller.objectWillChange.sink {
            publicationWasDeferred = didReturnFromBindingSetter
            publication.fulfill()
        }

        controller.setPeriodFromView(.sevenDays)
        didReturnFromBindingSetter = true
        await fulfillment(of: [publication], timeout: 1)
        withExtendedLifetime(observation) {}

        XCTAssertTrue(
            publicationWasDeferred,
            "Period selection published during the SwiftUI binding update"
        )
        XCTAssertEqual(controller.period, .sevenDays)
    }

    @MainActor
    func testMenuRefreshDefersPublicationUntilNextMainQueueTurn() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let controller = MacDashboardController {
            LocalUsageConfiguration(
                databaseURL: databaseURL,
                deviceID: "publication-timing-mac",
                deviceName: "Publication Timing Mac",
                roots: [:],
                parserVersion: 1
            )
        }
        var didReachNextMainQueueTurn = false
        var publicationTiming: [Bool] = []
        let observation = controller.objectWillChange.sink {
            publicationTiming.append(didReachNextMainQueueTurn)
        }

        DispatchQueue.main.async {
            didReachNextMainQueueTurn = true
        }
        await controller.refreshAfterViewUpdate()
        withExtendedLifetime(observation) {}

        XCTAssertFalse(publicationTiming.isEmpty)
        XCTAssertTrue(
            publicationTiming.allSatisfy(\.self),
            "Menu refresh published while SwiftUI was still updating the view"
        )
    }

    @MainActor
    func testRenderFixtureBackedDashboardSnapshot() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporary)
        }
        let suiteName = "TokenHubMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fixture = try XCTUnwrap(
            Bundle(for: MacVisualSnapshotTests.self).url(
                forResource: "senpi-normal",
                withExtension: "jsonl"
            )
        )
        var fixtureText = String(
            decoding: try Data(contentsOf: fixture),
            as: UTF8.self
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let eventStart = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(12 * 60 * 60)
        for (index, timestamp) in [
            "2026-08-01T10:00:00.000Z",
            "2026-08-01T10:00:01.000Z",
            "2026-08-01T10:00:02.000Z",
            "2026-08-01T10:00:03.000Z",
        ].enumerated() {
            fixtureText = fixtureText.replacingOccurrences(
                of: timestamp,
                with: formatter.string(
                    from: eventStart.addingTimeInterval(
                        TimeInterval(index)
                    )
                )
            )
        }
        try Data(fixtureText.utf8).write(
            to: temporary.appending(path: "senpi-normal.jsonl"),
            options: .atomic
        )
        let controller = MacDashboardController(
            configurationProvider: {
                LocalUsageConfiguration(
                    databaseURL: temporary.appending(path: "usage.sqlite"),
                    deviceID: "visual-qa-mac",
                    deviceName: "Visual QA Mac",
                    roots: [.senpi: temporary],
                    parserVersion: 1
                )
            },
            cloudSyncProvider: { nil },
            quotaPreferences: UserDefaultsProviderQuotaPreferences(
                defaults: defaults
            ),
            liveQuotaRefreshProvider: { _, _, _ in .empty }
        )
        await controller.refresh()
        XCTAssertNil(controller.refreshError, controller.refreshError ?? "")
        XCTAssertGreaterThan(controller.viewModel.totalTokens, 0)

        let renderer = ImageRenderer(
            content: TokenHubMenuView(controller: controller, snapshotMode: true)
                .environment(\.colorScheme, .light)
                .fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertNotNil(
            bitmap.representation(using: .png, properties: [:])
        )
        if let evidenceURL = try requestedVisualEvidenceURL(
            named: "macos-insights.png"
        ) {
            let evidenceView = NSHostingView(
                rootView: TokenHubMenuView(
                    controller: controller,
                    snapshotMode: true,
                    availableScreenHeight: 720
                )
                .environment(\.colorScheme, .light)
            )
            evidenceView.frame = NSRect(
                x: 0,
                y: 0,
                width: 420,
                height: 704
            )
            evidenceView.layoutSubtreeIfNeeded()
            try render(evidenceView, to: evidenceURL)
        }

        XCTAssertGreaterThan(bitmap.pixelsWide, 700)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 500)

        controller.period = .sevenDays
        let sevenDayRenderer = ImageRenderer(
            content: TokenHubMenuView(controller: controller, snapshotMode: true)
                .environment(\.colorScheme, .light)
                .fixedSize(horizontal: false, vertical: true)
        )
        sevenDayRenderer.scale = 2
        let sevenDayImage = try XCTUnwrap(sevenDayRenderer.nsImage)
        let sevenDayTIFF = try XCTUnwrap(sevenDayImage.tiffRepresentation)
        let sevenDayBitmap = try XCTUnwrap(
            NSBitmapImageRep(data: sevenDayTIFF)
        )
        XCTAssertNotNil(
            sevenDayBitmap.representation(using: .png, properties: [:])
        )

        XCTAssertGreaterThan(sevenDayBitmap.pixelsWide, 700)
        XCTAssertGreaterThan(sevenDayBitmap.pixelsHigh, 500)
        XCTAssertEqual(controller.viewModel.period, .sevenDays)
        XCTAssertGreaterThan(controller.viewModel.totalTokens, 0)
    }
}

private actor QuotaWarningRecorder {
    private var warnings: [QuotaThresholdWarning] = []

    func record(_ warning: QuotaThresholdWarning) {
        warnings.append(warning)
    }

    func count() -> Int {
        warnings.count
    }
}

private actor ProviderSelectionRecorder {
    private var selections: [LiveQuotaProvider: String] = [:]

    func record(_ selections: [LiveQuotaProvider: String]) {
        self.selections = selections
    }

    func lastSelections() -> [LiveQuotaProvider: String] {
        selections
    }
}

@MainActor
private func render(
    _ view: NSView,
    to outputURL: URL
) throws {
    let bitmap = try XCTUnwrap(
        view.bitmapImageRepForCachingDisplay(in: view.bounds)
    )
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(
        bitmap.representation(using: .png, properties: [:])
    )
    try png.write(to: outputURL, options: .atomic)
}

private func requestedVisualEvidenceURL(
    named fileName: String
) throws -> URL? {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let evidenceRoot = projectRoot.appending(
        path: ".omo/evidence/market-value",
        directoryHint: .isDirectory
    )
    let requestURL = evidenceRoot.appending(path: "snapshot-request.txt")
    guard FileManager.default.fileExists(atPath: requestURL.path) else {
        return nil
    }
    let request = try String(contentsOf: requestURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else {
        return nil
    }
    let outputDirectory = evidenceRoot.appending(
        path: request,
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )
    return outputDirectory.appending(path: fileName)
}

private actor RefreshInvocationRecorder {
    private var invocations = 0

    func record() {
        invocations += 1
    }

    func count() -> Int {
        invocations
    }
}

private func dailyUsage(
    day: Date,
    totalTokens: Int
) -> DailyUsage {
    DailyUsage(
        day: day,
        deviceID: "chart-device",
        source: .senpi,
        provider: "openai",
        model: "gpt-5",
        inputTokens: totalTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalTokens: totalTokens,
        estimatedCostUSD: 1,
        eventCount: 1
    )
}

import Foundation

/// The complete, privacy-safe payload permitted to cross the cloud boundary.
/// It intentionally contains aggregates only: raw events and collection metadata
/// are not part of this contract.
public struct CloudSyncPayload: Codable, Hashable, Sendable {
    public let dailyUsage: [DailyUsage]
    public let quotaSnapshots: [QuotaSnapshot]
    public let devices: [Device]
    public let providerStatuses: [LiveQuotaProviderStatus]

    public init(
        dailyUsage: [DailyUsage],
        quotaSnapshots: [QuotaSnapshot],
        devices: [Device] = [],
        providerStatuses: [LiveQuotaProviderStatus] = []
    ) {
        self.dailyUsage = dailyUsage
        self.quotaSnapshots = quotaSnapshots
        self.devices = devices
        self.providerStatuses = providerStatuses
    }
}

public struct DeviceSyncEnvelope: Hashable, Sendable {
    public let device: Device
    public let dailyUsage: [DailyUsage]
    public let quotaSnapshots: [QuotaSnapshot]
    public let providerStatuses: [LiveQuotaProviderStatus]

    public init(
        device: Device,
        dailyUsage: [DailyUsage],
        quotaSnapshots: [QuotaSnapshot],
        providerStatuses: [LiveQuotaProviderStatus]
    ) {
        self.device = device
        self.dailyUsage = dailyUsage
        self.quotaSnapshots = quotaSnapshots
        self.providerStatuses = providerStatuses
    }
}

public enum DeviceSyncEnvelopeError: Error, Equatable, Sendable {
    case mismatchedDeviceID
}

public protocol CloudSync: Sendable {
    func accounts(
        for provider: LiveQuotaProvider
    ) async throws -> [QuotaAccountProfile]
    func createAccount(
        provider: LiveQuotaProvider,
        displayName: String
    ) async throws -> QuotaAccountProfile
    func reconcileDevice(_ envelope: DeviceSyncEnvelope) async throws
    func dashboardPayload(
        since day: Date
    ) async throws -> CloudSyncPayload
    func upsertDailyUsage(_ usage: [DailyUsage]) async throws
    func upsertQuotaSnapshots(_ snapshots: [QuotaSnapshot]) async throws
    func upsertDevices(_ devices: [Device]) async throws
    func upsertProviderStatuses(
        _ statuses: [LiveQuotaProviderStatus]
    ) async throws
    func dailyUsage() async throws -> [DailyUsage]
    func quotaSnapshots() async throws -> [QuotaSnapshot]
    func devices() async throws -> [Device]
    func providerStatuses() async throws -> [LiveQuotaProviderStatus]
}

struct DailyUsageCloudKey: Hashable, Sendable {
    let day: Date
    let deviceID: String
    let source: UsageSource
    let provider: String
    let model: String

    init(_ usage: DailyUsage) {
        day = usage.day
        deviceID = usage.deviceID
        source = usage.source
        provider = usage.provider
        model = usage.model
    }
}

struct QuotaSnapshotCloudKey: Hashable, Sendable {
    let provider: String
    let accountPseudonym: String
    let windowKind: String

    init(_ snapshot: QuotaSnapshot) {
        provider = snapshot.provider
        accountPseudonym = snapshot.accountPseudonym
        windowKind = snapshot.windowKind
    }
}

struct ProviderStatusCloudKey: Hashable, Sendable {
    let deviceID: String
    let provider: LiveQuotaProvider

    init(_ status: LiveQuotaProviderStatus) {
        deviceID = status.deviceID
        provider = status.provider
    }
}

func cloudDailyUsageOrder(_ lhs: DailyUsage, _ rhs: DailyUsage) -> Bool {
    (lhs.day, lhs.deviceID, lhs.source.rawValue, lhs.provider, lhs.model)
        < (rhs.day, rhs.deviceID, rhs.source.rawValue, rhs.provider, rhs.model)
}

func cloudQuotaOrder(_ lhs: QuotaSnapshot, _ rhs: QuotaSnapshot) -> Bool {
    (lhs.provider, lhs.accountPseudonym, lhs.windowKind, lhs.capturedAt)
        < (rhs.provider, rhs.accountPseudonym, rhs.windowKind, rhs.capturedAt)
}

func cloudDeviceOrder(_ lhs: Device, _ rhs: Device) -> Bool {
    lhs.id < rhs.id
}

func cloudProviderStatusOrder(
    _ lhs: LiveQuotaProviderStatus,
    _ rhs: LiveQuotaProviderStatus
) -> Bool {
    (lhs.deviceID, lhs.provider.rawValue)
        < (rhs.deviceID, rhs.provider.rawValue)
}

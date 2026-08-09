import Charts
import OSLog
import SwiftUI
import TokenHubCore

struct TokenHubDashboardView: View {
    @ObservedObject var controller: IOSDashboardController
    private let logger = Logger(
        subsystem: "com.example.contextgauge.ios",
        category: "dashboard"
    )

    private var model: ReadOnlyDashboardViewModel {
        controller.model
    }

    private var qaDetailsMode: Bool {
        CommandLine.arguments.contains("--qa-details")
    }

    private var qaQuotaMode: Bool {
        CommandLine.arguments.contains("--qa-quota")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    readOnlyBadge
                    periodPicker
                    devicePicker
                    aggregateFilters
                    content
                    syncStatus
                }
                .padding()
            }
            .refreshable { await controller.reload() }
            .navigationTitle("ContextGauge")
            .toolbar {
                ToolbarItem(placement: topBarPlacement) {
                    Button {
                        Task { await controller.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(controller.isLoading)
                    .accessibilityLabel("Refresh cloud aggregates")
                }
            }
            .task(id: controller.payload) {
                guard controller.payload != nil else { return }
                await Task.yield()
                logger.notice("TOKENHUB_UI_RENDERED")
            }
        }
    }

    @ViewBuilder
    private var aggregateFilters: some View {
        if !model.availableProviders.isEmpty {
            VStack {
                LabeledContent("Provider") {
                    Picker(
                        "Provider",
                        selection: Binding(
                            get: { controller.selectedProvider },
                            set: {
                                controller.selectedProvider = $0
                                controller.selectedModel = nil
                            }
                        )
                    ) {
                        Text("All providers").tag(String?.none)
                        ForEach(model.availableProviders, id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                    .labelsHidden()
                }
                LabeledContent("Model") {
                    Picker("Model", selection: $controller.selectedModel) {
                        Text("All models").tag(String?.none)
                        ForEach(model.availableModels, id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var readOnlyBadge: some View {
        Label("Read-only CloudKit dashboard", systemImage: "lock.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var periodPicker: some View {
        LabeledContent("Period") {
            Picker("Period", selection: $controller.period) {
                ForEach(DashboardPeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var devicePicker: some View {
        if !model.availableDeviceIDs.isEmpty {
            Picker("Device", selection: $controller.selectedDeviceID) {
                Text("All devices").tag(String?.none)
                ForEach(model.availableDeviceIDs, id: \.self) {
                    Text(model.dashboard.deviceName(for: $0))
                        .tag(String?.some($0))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.isLoading, controller.payload == nil {
            ProgressView("Reading CloudKit aggregates")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let emptyState = model.emptyState {
            emptyStateView(emptyState)
        } else if qaQuotaMode {
            providerStatusSection
            quotaSection
        } else if qaDetailsMode {
            modelRows
            providerStatusSection
            quotaSection
        } else {
            summaryCards
            Text(
                model.dashboard.isCostComplete
                    ? "API-equivalent estimate; not a subscription invoice."
                    : "Partial API estimate; unknown model costs excluded."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            dailyChart
            modelRows
            providerStatusSection
            quotaSection
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "Tokens",
                value: model.dashboard.totalTokens.formatted(
                    .number.notation(.compactName)
                )
            )
            summaryCard(
                title: "Estimated USD",
                value: NSDecimalNumber(
                    decimal: model.dashboard.estimatedCostUSD
                ).doubleValue.formatted(.currency(code: "USD"))
            )
        }
    }

    private func summaryCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily usage")
                .font(.headline)
            Chart(model.dashboard.dailySeries, id: \.day) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Tokens", point.totalTokens)
                )
                .foregroundStyle(.blue.gradient)
            }
            .frame(height: 180)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
        }
    }

    private var modelRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Providers and models")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(model.dashboard.rows, id: \.self) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.model)
                        Text(
                            "\(row.provider) · \(model.dashboard.deviceName(for: row.deviceID))"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(
                        row.totalTokens.formatted(
                            .number.notation(.compactName)
                        )
                    )
                    .monospacedDigit()
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quota")
                .font(.headline)
            if model.dashboard.latestQuotas.isEmpty {
                Text("No reusable provider quota available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.dashboard.latestQuotas, id: \.self) { quota in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(quota.provider) · \(quota.windowKind)")
                            Spacer()
                            Text(
                                "\(NSDecimalNumber(decimal: quota.usedPercent))%"
                            )
                            .monospacedDigit()
                        }
                        ProgressView(
                            value: NSDecimalNumber(
                                decimal: quota.usedPercent
                            ).doubleValue,
                            total: 100
                        )
                        if let resetsAt = quota.resetsAt {
                            Text(
                                "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var providerStatusSection: some View {
        if !model.providerStatuses.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider status")
                    .font(.headline)
                ForEach(model.providerStatuses, id: \.self) { status in
                    Label {
                        Text(
                            "\(status.provider.rawValue.capitalized): "
                                + providerStatusText(status)
                        )
                    } icon: {
                        Image(
                            systemName: providerStatusSymbol(status)
                        )
                    }
                    .foregroundStyle(providerStatusColor(status))
                }
            }
        }
    }

    private func providerStatusText(
        _ status: LiveQuotaProviderStatus
    ) -> String {
        switch status.freshness {
        case .disabled:
            "Off"
        case .configurationRequired:
            "Setup required"
        case .fresh:
            "Fresh"
        case .stale:
            "Stale"
        case .unavailable:
            "Unavailable"
        case .error:
            status.errorCode ?? "Provider error"
        }
    }

    private func providerStatusSymbol(
        _ status: LiveQuotaProviderStatus
    ) -> String {
        status.freshness == .fresh
            ? "checkmark.circle"
            : "exclamationmark.triangle"
    }

    private func providerStatusColor(
        _ status: LiveQuotaProviderStatus
    ) -> Color {
        status.freshness == .fresh ? .secondary : .orange
    }

    private var topBarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let synced = model.dashboard.lastSyncAt {
                Text("Last sync \(synced, style: .relative)")
            }
            if let error = controller.errorCode {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func emptyStateView(
        _ state: ReadOnlyDashboardEmptyState
    ) -> some View {
        let message: (String, String)
        switch state {
        case .cloudUnavailable:
            message = ("Cloud data unavailable", "Check iCloud and container setup.")
        case .providerFailure:
            message = (
                "Provider lookup failed",
                "Refresh provider access on a Mac and try again."
            )
        case .noCloudUsage:
            message = (
                "No synced usage yet",
                "Refresh ContextGauge on a Mac first."
            )
        case .noUsageForSelection:
            message = ("No usage in this view", "Choose another period or device.")
        }
        return ContentUnavailableView(
            message.0,
            systemImage: "icloud.slash",
            description: Text(message.1)
        )
        .frame(minHeight: 280)
    }
}

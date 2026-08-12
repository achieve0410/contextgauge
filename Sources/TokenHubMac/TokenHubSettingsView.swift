import SwiftUI
import TokenHubMacCore

struct TokenHubSettingsView: View {
    @ObservedObject var controller: MacDashboardController

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            liveQuotaSettings
                .tabItem {
                    Label("Live Quota", systemImage: "gauge.with.dots.needle.50percent")
                }
            diagnosticsSettings
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        .frame(
            minWidth: 520,
            idealWidth: 600,
            minHeight: 420,
            idealHeight: 620
        )
    }

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch ContextGauge at login",
                    isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.setLaunchAtLogin($0) }
                    )
                )
                Text(
                    "ContextGauge starts in the menu bar and collects local usage "
                        + "without opening a window."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var liveQuotaSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Live quota access is off by default. When enabled, "
                        + "ContextGauge reads the selected provider credential "
                        + "only for a direct usage request."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(LiveQuotaProvider.allCases, id: \.self) {
                    providerSettings($0)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func providerSettings(
        _ provider: LiveQuotaProvider
    ) -> some View {
        GroupBox(provider.rawValue.capitalized) {
            VStack(alignment: .leading, spacing: 10) {
                if provider == .codex {
                    codexSetupGuidance
                }

                Toggle(
                    "Enable live quota",
                    isOn: Binding(
                        get: {
                            controller.quotaSelection(for: provider).isEnabled
                        },
                        set: { enabled in
                            Task {
                                await controller.updateQuotaEnabled(
                                    enabled,
                                    for: provider
                                )
                                await controller.refresh()
                            }
                        }
                    )
                )

                if controller.quotaSelection(for: provider).isEnabled {
                    accountControl(provider)
                } else {
                    Text("Off")
                        .foregroundStyle(.secondary)
                }

                providerStatus(provider)
                providerQuota(provider)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codexSetupGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Set up Codex", systemImage: "terminal")
                .font(.headline)
            Text("1. Run `codex login` in Terminal.")
            Text(
                "2. ContextGauge reads `$CODEX_HOME/auth.json` or "
                    + "`~/.codex/auth.json` only after you enable live quota."
            )
            Text("3. Return here and choose Retry setup if needed.")
            Text("ContextGauge does not copy Codex credentials into Keychain.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func accountControl(
        _ provider: LiveQuotaProvider
    ) -> some View {
        let selection = controller.quotaSelection(for: provider)
        let accounts = controller.quotaAccounts[provider] ?? []
        if let error = controller.quotaSetupErrors[provider] {
            HStack {
                Label(
                    error == "cloud-account-profile-unavailable"
                        ? "Setup required"
                        : "Unavailable",
                    systemImage: "exclamationmark.triangle.fill"
                )
                Spacer()
                retrySetupButton(provider)
            }
        } else if accounts.isEmpty || selection.accountPseudonym == nil {
            HStack {
                Label(
                    "Setup required",
                    systemImage: "exclamationmark.triangle.fill"
                )
                Spacer()
                retrySetupButton(provider)
            }
        } else {
            HStack {
                Picker(
                    "Account profile",
                    selection: Binding(
                        get: { selection.accountPseudonym },
                        set: {
                            controller.setQuotaAccount($0, for: provider)
                        }
                    )
                ) {
                    ForEach(accounts) { profile in
                        Text(profile.displayName)
                            .tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: 280)

                Button {
                    Task {
                        await controller.createAndSelectQuotaAccount(
                            for: provider
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(
                    "Add \(provider.rawValue.capitalized) account profile"
                )
            }
        }
    }

    private func retrySetupButton(
        _ provider: LiveQuotaProvider
    ) -> some View {
        Button("Retry setup") {
            Task {
                await controller.updateQuotaEnabled(true, for: provider)
                await controller.refresh()
            }
        }
    }

    @ViewBuilder
    private func providerStatus(
        _ provider: LiveQuotaProvider
    ) -> some View {
        ForEach(
            controller.liveQuotaStatuses.filter {
                $0.provider == provider
            },
            id: \.self
        ) { status in
            HStack {
                Label(
                    freshnessTitle(status.freshness),
                    systemImage: freshnessSymbol(status.freshness)
                )
                .foregroundStyle(freshnessColor(status.freshness))
                Spacer()
                if let capturedAt = status.capturedAt {
                    Text(capturedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorCode = status.errorCode {
                Text(errorCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func providerQuota(
        _ provider: LiveQuotaProvider
    ) -> some View {
        let selectedAccount = controller.quotaSelection(
            for: provider
        ).accountPseudonym
        let quotas = controller.viewModel.latestQuotas.filter { quota in
            let matchesSelectedAccount = selectedAccount.map {
                $0 == quota.accountPseudonym
            } ?? true
            return quotaProvider(quota.provider, matches: provider)
                && matchesSelectedAccount
        }
        let warnings = controller.quotaWarnings.filter {
            quotaProvider($0.provider, matches: provider)
        }

        ForEach(warnings) { warning in
            Label(
                "\(warning.windowKind) at "
                    + "\(NSDecimalNumber(decimal: warning.usedPercent))%",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }

        ForEach(quotas, id: \.self) { quota in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(quota.windowKind.capitalized)
                    Spacer()
                    Text(
                        "\(NSDecimalNumber(decimal: quota.usedPercent))%"
                    )
                    .monospacedDigit()
                }
                quotaProgress(quota.usedPercent)
                if let reset = quota.resetsAt {
                    Text("Resets \(reset, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var diagnosticsSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Collection") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let collected = controller.viewModel.lastCollectionAt {
                            if controller.viewModel.collectorErrors.isEmpty {
                                Label(
                                    "Collected \(collected, style: .relative)",
                                    systemImage: "externaldrive"
                                )
                            } else {
                                Label {
                                    Text("Collection attempted ")
                                        + Text(collected, style: .relative)
                                } icon: {
                                    Image(
                                        systemName:
                                            "externaldrive.badge.exclamationmark"
                                    )
                                }
                            }
                        } else {
                            Text("No collection has completed.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(
                            controller.viewModel.collectorErrors,
                            id: \.self
                        ) { status in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        "\(sourceTitle(status.source)): "
                                            + collectorErrorTitle(
                                                status.errorCode
                                            )
                                    )
                                    Text(
                                        collectorErrorGuidance(
                                            status.errorCode,
                                            source: status.source
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                }
                            } icon: {
                                Image(
                                    systemName: "exclamationmark.triangle"
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Synchronization") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let synced = controller.viewModel.lastSyncAt {
                            Label(
                                "Synced \(synced, style: .relative)",
                                systemImage: "icloud"
                            )
                        } else {
                            Text("No CloudKit synchronization has completed.")
                                .foregroundStyle(.secondary)
                        }
                        if let error = controller.refreshError {
                            Label(error, systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceTitle(_ source: UsageSource) -> String {
        switch source {
        case .senpi: "Senpi"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    private func collectorErrorTitle(_ errorCode: String?) -> String {
        switch errorCode {
        case "root-missing": "Source folder not found"
        case "no-jsonl-files": "No usage logs found"
        case "malformed-row": "Some usage rows were skipped"
        case "pricing-incomplete": "Cost estimate incomplete"
        case "collection-failed": "Collection failed"
        default: "Collection needs attention"
        }
    }

    private func collectorErrorGuidance(
        _ errorCode: String?,
        source: UsageSource
    ) -> String {
        switch errorCode {
        case "root-missing", "no-jsonl-files":
            "Run \(sourceTitle(source)) once, then choose Refresh in the menu."
        case "malformed-row":
            "Token totals exclude malformed rows and may be incomplete."
        case "pricing-incomplete":
            "Token totals are available, but some models need catalog pricing."
        case "collection-failed":
            "Choose Refresh again. If this persists, verify the source setup."
        default:
            "Choose Refresh again. This status is safe to include in a bug report."
        }
    }

    private func freshnessTitle(
        _ freshness: LiveQuotaFreshness
    ) -> String {
        switch freshness {
        case .disabled: "Off"
        case .configurationRequired: "Setup required"
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .unavailable: "Not signed in"
        case .error: "Unavailable"
        }
    }

    private func freshnessSymbol(
        _ freshness: LiveQuotaFreshness
    ) -> String {
        switch freshness {
        case .disabled: "pause.circle"
        case .configurationRequired: "gearshape.badge.questionmark"
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .unavailable: "person.crop.circle.badge.questionmark"
        case .error: "xmark.octagon.fill"
        }
    }

    private func freshnessColor(
        _ freshness: LiveQuotaFreshness
    ) -> Color {
        switch freshness {
        case .disabled, .unavailable: .secondary
        case .configurationRequired, .stale: .orange
        case .fresh: .green
        case .error: .red
        }
    }

    private func quotaProvider(
        _ value: String,
        matches provider: LiveQuotaProvider
    ) -> Bool {
        switch provider {
        case .codex:
            value == "codex" || value == "openai-codex"
        case .claude:
            value == "claude" || value == "anthropic"
        }
    }

    private func quotaProgress(
        _ usedPercent: Decimal
    ) -> some View {
        let percentage = NSDecimalNumber(
            decimal: usedPercent
        ).doubleValue
        return ProgressView(
            value: min(max(percentage, 0), 100),
            total: 100
        )
        .accessibilityValue(
            percentage.formatted(.percent.scale(1))
        )
    }
}

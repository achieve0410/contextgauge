import AppKit
import Charts
import SwiftUI
import TokenHubMacCore

enum TokenHubMenuLayout {
    static func minimumHeight(
        visibleScreenHeight: CGFloat
    ) -> CGFloat {
        maximumHeight(visibleScreenHeight: visibleScreenHeight)
    }

    static func maximumHeight(
        visibleScreenHeight: CGFloat
    ) -> CGFloat {
        max(240, min(720, visibleScreenHeight - 16))
    }
}

enum DailyUsageChartSelection {
    static func nearestPoint(
        to date: Date,
        in points: [DailyUsagePoint]
    ) -> DailyUsagePoint? {
        points.min {
            abs($0.day.timeIntervalSince(date))
                < abs($1.day.timeIntervalSince(date))
        }
    }
}

struct TokenHubMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var controller: MacDashboardController
    @State private var hoveredUsagePoint: DailyUsagePoint?
    var snapshotMode = false
    var availableScreenHeight: CGFloat?

    private var viewModel: DashboardViewModel {
        controller.viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if snapshotMode {
                        snapshotControls
                    } else {
                        controls
                    }
                    Divider()
                    usageSummary
                    Text(
                        viewModel.isCostComplete
                            ? "API-equivalent estimate; not a subscription invoice."
                            : "Partial API estimate; unknown model costs excluded."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if !viewModel.rows.isEmpty {
                        insightsSummary
                    }
                    dailyUsageSection
                    if snapshotMode {
                        snapshotUsageRows
                    } else {
                        usageRows
                    }
                }
                .padding(16)
            }
            Divider()
            if snapshotMode {
                snapshotFooter
            } else {
                footer
            }
        }
        .frame(width: 420)
        .frame(
            minHeight: menuMinimumHeight,
            maxHeight: menuMaximumHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var menuMinimumHeight: CGFloat {
        TokenHubMenuLayout.minimumHeight(
            visibleScreenHeight: visibleScreenHeight
        )
    }

    private var menuMaximumHeight: CGFloat {
        return TokenHubMenuLayout.maximumHeight(
            visibleScreenHeight: visibleScreenHeight
        )
    }

    private var visibleScreenHeight: CGFloat {
        availableScreenHeight
            ?? NSScreen.screens.map(\.visibleFrame.height).min()
            ?? 720
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Period")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "Period",
                    selection: Binding(
                        get: { controller.period },
                        set: { controller.setPeriodFromView($0) }
                    )
                ) {
                    ForEach(DashboardPeriod.allCases, id: \.self) {
                        period in
                        Text(period.title).tag(period)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Picker(
                "Device",
                selection: Binding(
                    get: { controller.selectedDeviceID },
                    set: { controller.setSelectedDeviceFromView($0) }
                )
            ) {
                Text("All devices").tag(String?.none)
                ForEach(controller.snapshot?.devices ?? [], id: \.id) {
                    device in
                    Text(device.name)
                        .tag(String?.some(device.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Device")
        }
    }

    private var snapshotControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Period")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "Period",
                    selection: .constant(controller.period)
                ) {
                    ForEach(DashboardPeriod.allCases, id: \.self) {
                        period in
                        Text(period.title).tag(period)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(
                controller.snapshot?.devices.first?.name
                    ?? "All devices"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var usageSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                tokenMetric
                Spacer()
                costMetric
            }
            VStack(alignment: .leading, spacing: 10) {
                tokenMetric
                costMetric
            }
        }
    }

    private var tokenMetric: some View {
        metric(
            title: "Tokens",
            value: viewModel.totalTokens.formatted(
                .number.notation(.compactName)
            )
        )
    }

    private var costMetric: some View {
        metric(
            title: "Estimated USD",
            value: NSDecimalNumber(
                decimal: viewModel.estimatedCostUSD
            ).doubleValue.formatted(.currency(code: "USD"))
        )
    }

    private func metric(
        title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var dailyUsageSection: some View {
        if !viewModel.dailySeries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily token usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Chart(viewModel.dailySeries, id: \.day) { point in
                    BarMark(
                        x: .value("Date", point.day, unit: .day),
                        y: .value("Tokens", point.totalTokens)
                    )
                    .foregroundStyle(
                        hoveredUsagePoint?.day == point.day
                            ? Color.accentColor
                            : Color.accentColor.opacity(
                                hoveredUsagePoint == nil ? 1 : 0.45
                            )
                    )
                    .accessibilityLabel(
                        point.day.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .accessibilityValue(
                        "\(point.totalTokens.formatted()) tokens"
                    )

                    if hoveredUsagePoint?.day == point.day {
                        RuleMark(
                            x: .value("Selected date", point.day)
                        )
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 1,
                                dash: [3, 3]
                            )
                        )
                    }
                }
                .chartXAxis {
                    AxisMarks(
                        values: .automatic(
                            desiredCount: min(
                                viewModel.dailySeries.count,
                                5
                            )
                        )
                    ) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(
                            format: .dateTime
                                .month(.abbreviated)
                                .day()
                        )
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(
                                    tokens.formatted(
                                        .number.notation(.compactName)
                                    )
                                )
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    guard
                                        let plotFrame = proxy.plotFrame,
                                        let date: Date = proxy.value(
                                            atX: location.x
                                                - geometry[plotFrame].origin.x
                                        )
                                    else {
                                        hoveredUsagePoint = nil
                                        return
                                    }
                                    hoveredUsagePoint =
                                        DailyUsageChartSelection.nearestPoint(
                                            to: date,
                                            in: viewModel.dailySeries
                                        )
                                case .ended:
                                    hoveredUsagePoint = nil
                                }
                            }
                            .overlay(alignment: .topLeading) {
                            if
                                let point = hoveredUsagePoint,
                                let plotFrame = proxy.plotFrame,
                                let xPosition = proxy.position(
                                    forX: point.day
                                )
                            {
                                let chartX =
                                    geometry[plotFrame].origin.x + xPosition
                                dailyUsageTooltip(point)
                                    .fixedSize()
                                    .position(
                                        x: min(
                                            max(chartX, 74),
                                            geometry.size.width - 74
                                        ),
                                        y: 34
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .accessibilityLabel("Daily token usage chart")
            }
        }
    }

    private func dailyUsageTooltip(
        _ point: DailyUsagePoint
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                point.day.formatted(
                    .dateTime
                        .weekday(.abbreviated)
                        .month(.abbreviated)
                        .day()
                )
            )
            .foregroundStyle(.secondary)
            Text("\(point.totalTokens.formatted()) tokens")
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(
                NSDecimalNumber(
                    decimal: point.estimatedCostUSD
                ).doubleValue.formatted(.currency(code: "USD"))
            )
            .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator.opacity(0.7))
        }
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var usageRows: some View {
        if viewModel.rows.isEmpty {
            emptyUsageView
        } else {
            modelRows(viewModel.rows)
        }
    }

    @ViewBuilder
    private var snapshotUsageRows: some View {
        if viewModel.rows.isEmpty {
            emptyUsageView
        } else {
            modelRows(Array(viewModel.rows.prefix(6)))
        }
    }

    private var emptyUsageView: some View {
        ContentUnavailableView(
            "No matching usage",
            systemImage: "chart.bar.xaxis",
            description: Text(
                "Run Senpi, Codex, or Claude Code, or choose another period. "
                    + "Refresh, then open Settings > Diagnostics if data stays empty."
            )
        )
        .frame(minHeight: 112)
    }

    private var insightsSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            insightCard(
                title: "Period change",
                value: periodChangeValue,
                detail: viewModel.periodComparison.currentTokens.formatted()
                    + " current · "
                    + viewModel.periodComparison.previousTokens.formatted()
                    + " previous"
            )
            insightCard(
                title: "Token mix",
                value: viewModel.tokenComposition.inputTokens.formatted()
                    + " input · "
                    + viewModel.tokenComposition.outputTokens.formatted()
                    + " output",
                detail: viewModel.tokenComposition.cacheReadTokens.formatted()
                    + " cache read · "
                    + viewModel.tokenComposition.cacheWriteTokens.formatted()
                    + " cache write"
            )
        }
    }

    private func insightCard(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .combine)
    }

    private var periodChangeValue: String {
        guard let percentChange = viewModel.periodComparison.percentChange else {
            return "No previous usage"
        }
        let rounded = NSDecimalNumber(decimal: percentChange).intValue
        let prefix = rounded > 0 ? "+" : ""
        return "\(prefix)\(rounded)%"
    }

    private func modelRows(
        _ rows: [DashboardRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By model")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.model)
                                .lineLimit(1)
                                .help(row.model)
                            Text(
                                "\(row.provider) · "
                                    + "\(viewModel.deviceName(for: row.deviceID))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(
                            row.totalTokens.formatted(
                                .number.notation(.compactName)
                            )
                        )
                        .monospacedDigit()
                        .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(row.model), \(row.provider), "
                            + "\(viewModel.deviceName(for: row.deviceID)), "
                            + "\(row.totalTokens) tokens"
                    )
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing usage")
            }
            Button {
                Task {
                    await controller.refreshAfterViewUpdate()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isRefreshing)
            Button("Settings…") {
                openSettings()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private var snapshotFooter: some View {
        HStack(spacing: 10) {
            Spacer()
            Text("Refresh")
                .fontWeight(.medium)
            Text("Settings…")
                .fontWeight(.medium)
            Text("Quit")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

}

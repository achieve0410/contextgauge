import SwiftUI
import TokenHubCore

@main
@MainActor
struct TokenHubiOSApp: App {
    @StateObject private var controller: IOSDashboardController

    init() {
        let dataSource: any ReadOnlyDashboardDataSource
        if CommandLine.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["TOKENHUB_UI_TESTING"] == "1"
        {
            dataSource = SeededDashboardDataSource()
        } else {
            let identifier = Bundle.main.object(
                forInfoDictionaryKey: "TokenHubCloudContainerIdentifier"
            ) as? String ?? CloudKitSync.Configuration.placeholder.containerIdentifier
            dataSource = CloudKitDashboardDataSource(
                sync: CloudKitSync(
                    configuration: .init(containerIdentifier: identifier)
                )
            )
        }
        let controller = IOSDashboardController(dataSource: dataSource)
        let arguments = CommandLine.arguments
        if let period = Self.argument(after: "--period", in: arguments)
            .flatMap(DashboardPeriod.init(rawValue:))
        {
            controller.period = period
        }
        controller.selectedDeviceID = Self.argument(
            after: "--device",
            in: arguments
        )
        controller.selectedProvider = Self.argument(
            after: "--provider",
            in: arguments
        )
        controller.selectedModel = Self.argument(
            after: "--model",
            in: arguments
        )
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            TokenHubDashboardView(controller: controller)
                .task {
                    guard controller.payload == nil else { return }
                    await controller.reload()
                }
        }
    }

    private static func argument(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

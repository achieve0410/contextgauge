import AppKit
import SwiftUI
import TokenHubMacCore

enum TokenHubApplicationActivation {
    static let policy: NSApplication.ActivationPolicy = .regular

    @MainActor
    static func apply(
        to application: NSApplication = .shared
    ) {
        application.setActivationPolicy(policy)
        application.activate(ignoringOtherApps: true)
    }
}

@main
@MainActor
struct TokenHubMacApp: App {
    @StateObject private var controller: MacDashboardController

    init() {
        TokenHubApplicationActivation.apply()
        let controller = MacDashboardController()
        _controller = StateObject(wrappedValue: controller)
        Task {
            await controller.startIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TokenHubMenuView(controller: controller)
        } label: {
            Label(
                controller.menuBarTokenLabel,
                systemImage: "gauge.with.dots.needle.50percent"
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            TokenHubSettingsView(controller: controller)
        }
    }
}

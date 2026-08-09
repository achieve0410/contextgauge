import XCTest

final class TokenHubiOSUITests: XCTestCase {
    @MainActor
    func testPeriodsDeviceFilterAndReadOnlySections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Read-only CloudKit dashboard"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["Tokens"].exists)

        let periodPicker = app.buttons.matching(NSPredicate(
            format: "label == 'Period, Period, Today'"
        )).firstMatch
        XCTAssertTrue(periodPicker.waitForExistence(timeout: 5))
        periodPicker.tap()
        let sevenDays = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Last 7 Days'"
        )).firstMatch
        XCTAssertTrue(sevenDays.waitForExistence(timeout: 5))
        sevenDays.tap()
        XCTAssertTrue(
            app.staticTexts["Daily usage"].waitForExistence(timeout: 5)
        )

        let sevenDayPicker = app.buttons.matching(NSPredicate(
            format: "label == 'Period, Period, Last 7 Days'"
        )).firstMatch
        XCTAssertTrue(sevenDayPicker.waitForExistence(timeout: 5))
        sevenDayPicker.tap()
        let month = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Last 1 Month'"
        )).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()

        let devicePicker = app.buttons.matching(NSPredicate(
            format: "label == 'Device, All devices'"
        )).firstMatch
        XCTAssertTrue(devicePicker.waitForExistence(timeout: 5))
        devicePicker.tap()
        let macBook = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'MacBook'"
        )).firstMatch
        XCTAssertTrue(macBook.waitForExistence(timeout: 5))
        macBook.tap()

        app.swipeUp()
        XCTAssertTrue(
            app.staticTexts["Providers and models"]
                .waitForExistence(timeout: 5)
        )
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Quota"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Resets '"
        )).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Last sync'"
        )).firstMatch.waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "iOS dashboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

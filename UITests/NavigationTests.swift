import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testSchedulingVerificationFailureDoesNotDismissChallenge() {
        let app = XCUIApplication()
        app.launchEnvironment["OKIRU_UI_TEST_DUE_WAKE"] = "1"
        app.launchEnvironment["OKIRU_UI_TEST_SCHEDULING_FAILURE"] = "1"
        app.launchArguments = ["-language","en","-permissionSetupVersion","2"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Wake-up challenge"].waitForExistence(timeout:20))
        XCTAssertFalse(app.alerts["Attention"].exists)
        XCTAssertTrue(app.staticTexts["The system did not retain all requested alerts. This schedule is not confirmed."].waitForExistence(timeout:10))
        XCTAssertTrue(app.navigationBars["Wake-up challenge"].exists)
    }

    @MainActor func testIconLaunchAndForegroundResumeRouteUnfinishedWake() {
        let app = XCUIApplication()
        app.launchEnvironment["OKIRU_UI_TEST_DUE_WAKE"] = "1"
        app.launchArguments = ["-language","en","-permissionSetupVersion","2"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Wake-up challenge"].waitForExistence(timeout:20))
        XCTAssertFalse(app.tabBars.buttons["Alarm"].isHittable)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Wake-up challenge"].waitForExistence(timeout:10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Wake-up challenge"].waitForExistence(timeout:20))
    }

    @MainActor func testAppStoreScreenshotsTraditionalChinese() {
        let app = XCUIApplication()
        app.launchArguments = ["-language", "zh-Hant", "-onboarded", "YES"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["首頁"].waitForExistence(timeout: 20))
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "AppStore-01-Home-zh-Hant"
        home.lifetime = .keepAlways
        add(home)

        app.tabBars.buttons["鬧鐘"].tap()
        XCTAssertTrue(app.buttons["新增鬧鐘"].waitForExistence(timeout: 5))
        let alarms = XCTAttachment(screenshot: app.screenshot())
        alarms.name = "AppStore-02-Alarms-zh-Hant"
        alarms.lifetime = .keepAlways
        add(alarms)

        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(app.staticTexts["語言"].firstMatch.waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "AppStore-03-Settings-zh-Hant"
        settings.lifetime = .keepAlways
        add(settings)
    }

    @MainActor func testThreeTabsEditorHistoryAndFeedbackDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-language","en","-onboarded","YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["Next alarm"].exists)
        app.tabBars.buttons["Alarm"].tap()
        app.buttons["Add alarm"].tap()
        XCTAssertTrue(app.textFields["Alarm name"].waitForExistence(timeout:5))
        app.textFields["Alarm name"].tap()
        app.textFields["Alarm name"].typeText("UI test morning")
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Send feedback"].tap()
        XCTAssertTrue(app.textFields["Summary (up to 160 characters)"].waitForExistence(timeout:5))
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Settings-feedback"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Home"].tap()
        let home = XCTAttachment(screenshot:app.screenshot()); home.name = "Home"; home.lifetime = .keepAlways; add(home)
    }
    @MainActor func testChineseNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["-language","zh-Hant","-onboarded","YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首頁"].waitForExistence(timeout:20))
        app.tabBars.buttons["鬧鐘"].tap()
        XCTAssertTrue(app.buttons["新增鬧鐘"].exists)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Alarm-zh-Hant"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testArabicRightToLeft() {
        let app = XCUIApplication(); app.launchArguments = ["-language","ar","-onboarded","YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["الرئيسية"].waitForExistence(timeout:20))
        app.tabBars.buttons["الإعدادات"].tap()
        XCTAssertTrue(app.staticTexts["اللغة"].firstMatch.exists)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Settings-ar-RTL"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testLargestTextNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-language","en","-onboarded","YES","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout:20))
        let tagline = app.staticTexts["A little movement. A new morning."]
        XCTAssertTrue(tagline.waitForExistence(timeout:5))
        XCTAssertGreaterThanOrEqual(tagline.frame.minX,0)
        XCTAssertLessThanOrEqual(tagline.frame.maxX,app.frame.width)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Home-largest-text"; shot.lifetime = .keepAlways; add(shot)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Language"].firstMatch.exists)
        app.tabBars.buttons["Alarm"].tap()
        app.buttons["Add alarm"].tap()
        XCTAssertTrue(app.textFields["Alarm name"].waitForExistence(timeout:5))
        app.buttons["Cancel"].tap()
    }
    @MainActor func testPracticeCanExitWithoutARecordedAlarm() {
        let app = XCUIApplication(); app.launchArguments = ["-language","en","-onboarded","YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout:20))
        app.tabBars.buttons["Settings"].tap()
        let practice = app.buttons["Try the camera challenge"]
        for _ in 0..<6 { if practice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(practice.isHittable); practice.tap()
        let leave = app.buttons["Close"].firstMatch
        XCTAssertTrue(leave.waitForExistence(timeout:10))
        // No fake camera frames or manual count override: this only tests routing.
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Practice-simulator"; shot.lifetime = .keepAlways; add(shot)
        leave.tap()
        let discard = app.buttons["Discard and close"]
        if discard.waitForExistence(timeout:3) { discard.tap() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout:5))
    }
}

import CoreLocation
import XCTest

final class WalkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func selectNear(in game: XCUIElement) {
        // WebKit exposes the HTML aria-pressed control as a switch on iOS 26.
        let near = game.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "近 ~500m")
        ).firstMatch
        XCTAssertTrue(near.waitForExistence(timeout: 10))
        near.tap()
    }

    @MainActor
    func testCreditsOpenAndClose() {
        let app = XCUIApplication()
        app.launch()
        let game = app.webViews.firstMatch
        let credits = game.links["資料來源"]
        XCTAssertTrue(credits.waitForExistence(timeout: 20))
        credits.tap()

        let navigation = app.navigationBars["資料來源與授權"]
        let done = navigation.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.links["OpenStreetMap 著作權說明"].waitForExistence(timeout: 10))
        done.tap()
        let start = game.buttons["出門散步吧"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
    }

    @MainActor
    private func setLocation(_ coordinate: CLLocationCoordinate2D) {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(coordinate: coordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()))
    }

    @MainActor
    private func startGPSWalk(_ app: XCUIApplication, at coordinate: CLLocationCoordinate2D) {
        let game = app.webViews.firstMatch
        let start = game.buttons["出門散步吧"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        selectNear(in: game)
        setLocation(coordinate)
        start.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["Allow While Using App", "Allow While Using the App", "使用 App 期間允許", "使用 App 時允許"]
        )).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        setLocation(coordinate)
        let allowNotifications = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["Allow", "允許"]
        )).firstMatch
        if allowNotifications.waitForExistence(timeout: 4) { allowNotifications.tap() }
        let gps = game.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "GPS")).firstMatch
        XCTAssertTrue(gps.waitForExistence(timeout: 12), "定位必須經過 Core Location 進入實走")
        if allowNotifications.waitForExistence(timeout: 2) { allowNotifications.tap() }
        XCTAssertTrue(game.buttons["換個地方"].exists)
        XCTAssertFalse(game.buttons["▲ 往目的地走"].exists)
    }

    @MainActor
    func testGPSWalkUsesSimulatedCoreLocation() {
        let previousLocation = XCUIDevice.shared.location
        defer { XCUIDevice.shared.location = previousLocation }
        // 鹿港天后宮周邊有多個近距離地點，與背景測試造訪的南投景點分開。
        let start = CLLocationCoordinate2D(latitude: 24.059446, longitude: 120.431209)
        setLocation(start)
        let app = XCUIApplication()
        app.launch()
        startGPSWalk(app, at: start)
        let game = app.webViews.firstMatch
        game.buttons["收工"].tap()
        XCTAssertTrue(game.staticTexts["已收工"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackgroundArrivalNotifiesAndPreservesFootprint() throws {
        let device = XCUIDevice.shared
        let previousLocation = device.location
        defer { device.location = previousLocation }
        // 仙洞坪棋盤石（編號 1001）以北約 222 公尺，近距離選項內只有這一站。
        let start = CLLocationCoordinate2D(latitude: 23.90365, longitude: 120.79928)
        setLocation(start)
        let app = XCUIApplication()
        app.launch()
        let game = app.webViews.firstMatch
        let status = game.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "出發過 ")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let before = status.label.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(before.count, 2)
        startGPSWalk(app, at: start)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        device.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8), "按下主畫面後應在背景接收定位")
        setLocation(.init(latitude: 23.90179, longitude: start.longitude))
        Thread.sleep(forTimeInterval: 1.2)
        setLocation(.init(latitude: 23.90160, longitude: start.longitude))
        // 只操作模擬器定位與 SpringBoard，讓 App 在背景確認抵達。
        Thread.sleep(forTimeInterval: 2)
        setLocation(.init(latitude: 23.90565, longitude: start.longitude))
        XCTAssertNotEqual(app.state, .runningForeground)
        let notification = springboard.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "散步到站了", "小嚮導已經找到目的地"
        )).firstMatch
        if !notification.waitForExistence(timeout: 2) || !notification.isHittable {
            // 橫幅消失後，從主畫面左上側下拉通知中心。
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.005))
            let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.85))
            top.press(forDuration: 0.15, thenDragTo: bottom)
        }
        let notificationIsVisible = notification.waitForExistence(timeout: 10)
        let evidence = XCTAttachment(screenshot: springboard.screenshot())
        evidence.name = "背景抵達的系統通知"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(notificationIsVisible, "系統應顯示散步到站的本機通知")
        XCTAssertNotEqual(app.state, .runningForeground)
        notification.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let place = game.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "仙洞坪棋盤石")
        ).firstMatch
        let again = game.buttons["再走一趟"]
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        XCTAssertTrue(place.exists, "離開抵達範圍後，揭曉的仍應是背景抵達的地點")
        again.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let after = status.label.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0], before[0] + 1)
        XCTAssertTrue((max(1, before[1])...before[1] + 1).contains(after[1]))
        let saved = status.label
        app.terminate()
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertEqual(status.label, saved)
    }

    @MainActor
    func testSimulatedWalkPersistsDrawAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-simulate-walk"]
        app.launch()

        let game = app.webViews.firstMatch
        let status = game.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "模擬：出發過 ")
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let previousCount = try XCTUnwrap(status.label.split(separator: " ").compactMap { Int($0) }.first)

        selectNear(in: game)
        let start = game.buttons["出門散步吧"]
        start.tap()
        let forward = game.buttons["▲ 往目的地走"]
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.press(forDuration: 0.6)
        game.buttons["收工"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let expected = "模擬：出發過 \(previousCount + 1) 次"
        XCTAssertTrue(status.label.hasPrefix(expected))

        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix(expected), "重新啟動後的足跡：\(status.label)")
    }
}

import CoreLocation
import UIKit
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
    private func selectPhotoFromSystemLibrary(_ app: XCUIApplication) {
        let library = app.buttons["從相簿選取"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let grid = app.otherElements["PXGGridLayout-Group"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), app.debugDescription)
        let frame = grid.frame
        // iPhone 16 的系統選擇器每列三張，剛加入的測試圖在左上角。
        let center = CGPoint(x: frame.minX + frame.width / 6, y: frame.minY + frame.width / 6)
        let tile = grid.descendants(matching: .any).allElementsBoundByIndex.first {
            $0.frame.contains(center) && $0.frame.width < frame.width / 2 && $0.isHittable
        }
        if let tile {
            tile.tap()
        } else {
            // 有些系統版本只公開整個格狀檢視的合併標籤，改以真實格子的中心點操作。
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y - app.frame.minY)).tap()
        }
        let add = app.buttons.matching(NSPredicate(format: "label IN %@", ["Add", "加入", "新增"])).firstMatch
        if add.waitForExistence(timeout: 2) { add.tap() }
    }

    @MainActor
    private func checkSavedPhoto(_ photo: XCUIElement) throws {
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let image = try XCTUnwrap(photo.screenshot().image.cgImage)
        let rgb = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
        rgb.draw(image, in: CGRect(x: 0, y: 0, width: 20, height: 20))
        let pixels = try XCTUnwrap(rgb.data).assumingMemoryBound(to: UInt8.self)
        let left = (10 * 20 + 8) * 4
        let right = (10 * 20 + 12) * 4
        XCTAssertTrue(pixels[left] > 160 && pixels[left + 1] < 120 && pixels[left + 2] < 140,
                      "照片左半應為系統相簿測試圖的紅色")
        XCTAssertTrue(pixels[right] < 130 && pixels[right + 1] > 140 && pixels[right + 2] > 140,
                      "照片右半應為系統相簿測試圖的藍綠色")
    }

    @MainActor
    func testPhotoPickerPersistsArrivalAndOpensSystemShareSheet() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("這個情境使用預先放入模擬器相簿的測試圖。")
        #else
        let device = XCUIDevice.shared
        let previousLocation = device.location
        defer { device.location = previousLocation }
        // 奧萬大自然教育中心（編號 1004）是此起點 500 公尺內唯一的地點。
        let start = CLLocationCoordinate2D(latitude: 23.955645, longitude: 121.179027)
        setLocation(start)
        let app = XCUIApplication()
        app.launch()
        startGPSWalk(app, at: start)
        let game = app.webViews.firstMatch
        game.buttons["記一筆"].tap()
        let detail = app.tables["walkJournalDetail"]
        let addPhoto = detail.cells["walkJournalAddPhoto"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 8))
        addPhoto.tap()
        selectPhotoFromSystemLibrary(app)
        XCTAssertTrue(detail.cells["walkJournalPhoto"].waitForExistence(timeout: 15))
        app.buttons["walkJournalDone"].tap()

        setLocation(.init(latitude: 23.95376, longitude: start.longitude))
        Thread.sleep(forTimeInterval: 1.2)
        setLocation(.init(latitude: 23.95361, longitude: start.longitude))
        let keepPhoto = game.buttons["拍一張留念"]
        XCTAssertTrue(keepPhoto.waitForExistence(timeout: 15))
        keepPhoto.tap()
        selectPhotoFromSystemLibrary(app)

        let placeName = "奧萬大自然教育中心"
        let card = app.images["walkAlbumCardImage"]
        XCTAssertTrue(app.navigationBars[placeName].waitForExistence(timeout: 20))
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let savedCard = XCTAttachment(screenshot: app.screenshot())
        savedCard.name = "到站保存的小嚮導透卡"
        savedCard.lifetime = .keepAlways
        add(savedCard)
        app.terminate()
        app.launch()
        let journal = game.buttons["散步日誌"]
        XCTAssertTrue(journal.waitForExistence(timeout: 15))
        journal.tap()
        let row = app.tables["walkJournalList"].cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "walkJournalEntry-", placeName
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars[placeName].waitForExistence(timeout: 8))
        let photos = detail.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkJournalPhoto-"))
        let earlier = photos.matching(NSPredicate(format: "label CONTAINS %@", "散步途中")).firstMatch
        XCTAssertTrue(earlier.waitForExistence(timeout: 8))
        XCTAssertEqual(photos.count, 2, "同一趟的途中和到站相片都要留下")
        earlier.tap()
        XCTAssertTrue(app.navigationBars["散步途中"].waitForExistence(timeout: 8))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.buttons["walkAlbumDone"].tap()
        let arrivalPhoto = photos.matching(NSPredicate(format: "label CONTAINS %@", placeName)).firstMatch
        XCTAssertTrue(arrivalPhoto.waitForExistence(timeout: 8))
        arrivalPhoto.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let picker = app.segmentedControls["walkAlbumImagePicker"]
        picker.buttons["照片"].tap()
        try checkSavedPhoto(app.images["walkAlbumOriginalImage"])
        picker.buttons["透卡"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.buttons["walkAlbumShare"].tap()
        let sheet = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "ActivityListView",
            ["Copy", "Copy Photo", "Save Image", "Save to Files", "AirDrop", "拷貝", "儲存影像", "儲存到檔案"]
        )).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "從足跡詳情開啟 iOS 分享面板")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "相片足跡的系統分享面板"
        evidence.lifetime = .keepAlways
        add(evidence)
        #endif
    }

    @MainActor
    private func openJournal(_ app: XCUIApplication) {
        let button = app.webViews.firstMatch.buttons["散步日誌"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(app.tables["walkJournalList"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testJournalImportsTwoPhotoVisitsAndOneUndatedPlaceOnlyOnce() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("此情境使用模擬器預先放入的 1.3 足跡。")
        #else
        let app = XCUIApplication()
        for round in 0..<2 {
            app.launch()
            openJournal(app)
            let table = app.tables["walkJournalList"]
            let place = "楠仔腳蔓社學堂遺蹟"
            let visits = table.cells.matching(NSPredicate(format: "label CONTAINS %@", place))
            XCTAssertEqual(visits.count, 2, "同地兩張舊照片是兩筆不同日期的紀錄")
            for date in ["2026.11.05", "2026.10.16"] {
                let visit = visits.matching(NSPredicate(format: "label CONTAINS %@", date)).firstMatch
                XCTAssertTrue(visit.exists)
                if round == 0 {
                    visit.tap()
                    let fullPhoto = app.cells["walkJournalPhoto"]
                    XCTAssertTrue(fullPhoto.waitForExistence(timeout: 6))
                    fullPhoto.tap()
                    XCTAssertTrue(app.images["walkAlbumCardImage"].waitForExistence(timeout: 8))
                    app.buttons["walkAlbumDone"].tap()
                    app.navigationBars[place].buttons.element(boundBy: 0).tap()
                }
            }
            let legacy = table.cells.matching(NSPredicate(format: "label CONTAINS %@", "東埔溫泉"))
            XCTAssertEqual(legacy.count, 1)
            XCTAssertTrue(table.staticTexts["以往到過的地點"].exists)
            legacy.firstMatch.tap()
            let detail = app.tables["walkJournalDetail"]
            XCTAssertTrue(detail.staticTexts["以往到過"].waitForExistence(timeout: 6))
            XCTAssertFalse(detail.staticTexts["日期"].exists)
            XCTAssertFalse(detail.staticTexts["出發時間"].exists)
            XCTAssertFalse(detail.cells["walkJournalAddPhoto"].exists)
            XCTAssertTrue(detail.cells["walkJournalMap"].exists)
            if round == 0 {
                detail.cells["walkJournalMap"].tap()
                XCTAssertTrue(app.navigationBars["地點地圖"].waitForExistence(timeout: 8))
                XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
            }
            app.terminate()
        }
        #endif
    }

    @MainActor
    func testJournalSavesNotesFiltersFavoritesAndHidesUnreachedDestination() {
        let previousLocation = XCUIDevice.shared.location
        defer { XCUIDevice.shared.location = previousLocation }
        // 這個起點只會抽到鳶峰觀景台；測試全程留在起點。
        let start = CLLocationCoordinate2D(latitude: 24.11967, longitude: 121.23742)
        setLocation(start)
        let app = XCUIApplication()
        app.launch()
        startGPSWalk(app, at: start)
        let game = app.webViews.firstMatch
        game.buttons["記一筆"].tap()
        let detail = app.tables["walkJournalDetail"]
        XCTAssertTrue(detail.staticTexts["散步中"].waitForExistence(timeout: 8))
        XCTAssertFalse(detail.cells["walkJournalMap"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "鳶峰觀景台")).firstMatch.exists)
        detail.cells["walkJournalNote"].tap()
        let editor = app.textViews["walkJournalEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let note = "Walk " + String(UUID().uuidString.prefix(8))
        editor.typeText(note)
        app.buttons["walkJournalSaveNote"].tap()
        detail.cells["walkJournalFavorite"].tap()
        XCTAssertTrue(detail.staticTexts["取消收藏"].waitForExistence(timeout: 5))
        app.buttons["walkJournalDone"].tap()
        game.buttons["收工"].tap()
        XCTAssertTrue(game.staticTexts["已收工"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openJournal(app)
        app.buttons["walkJournalFavoritesFilter"].tap()
        let search = app.searchFields["walkJournalSearch"]
        search.tap()
        search.typeText(note)
        let result = app.tables["walkJournalList"].cells.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertTrue(result.label.contains("已收工"))
        XCTAssertTrue(result.label.contains("已收藏"))
        XCTAssertFalse(result.label.contains("鳶峰"))
        result.tap()
        XCTAssertTrue(detail.staticTexts["已收工"].waitForExistence(timeout: 8))
        XCTAssertFalse(detail.cells["walkJournalMap"].exists)
        XCTAssertTrue(detail.staticTexts[note].exists)
        detail.cells["walkJournalNote"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" updated")
        app.buttons["walkJournalSaveNote"].tap()
        XCTAssertTrue(detail.staticTexts[note + " updated"].waitForExistence(timeout: 5))
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "重新開啟的散步日誌筆記"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testReturnUsesSavedPointAndNotifiesWithoutAddingFootprints() throws {
        let device = XCUIDevice.shared
        let previousLocation = device.location
        defer { device.location = previousLocation }
        let point = CLLocationCoordinate2D(latitude: 24.12567, longitude: 121.23742)
        let start = CLLocationCoordinate2D(latitude: 24.11967, longitude: 121.23742)
        setLocation(point)
        let app = XCUIApplication()
        app.launch()
        let game = app.webViews.firstMatch
        let settingsButton = game.buttons["導航設定"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        let settings = app.tables["walkNavigationSettings"]
        let save = settings.cells["walkSaveReturnPoint"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        setLocation(point)
        save.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let locationPermission = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["Allow While Using App", "Allow While Using the App", "使用 App 期間允許", "使用 App 時允許"]
        )).firstMatch
        if locationPermission.waitForExistence(timeout: 2) { locationPermission.tap() }
        setLocation(point)
        XCTAssertTrue(settings.staticTexts["已儲存回程地點"].waitForExistence(timeout: 18))
        let toggle = app.switches["walkHideDistance"]
        XCTAssertTrue(toggle.exists)
        if toggle.value as? String != "1" { toggle.tap() }
        settings.cells["walkArrivalRadius100"].tap()
        app.navigationBars["導航設定"].buttons["完成"].tap()

        app.terminate()
        setLocation(start)
        app.launch()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        XCTAssertTrue(settings.staticTexts["已儲存回程地點"].waitForExistence(timeout: 6))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(settings.cells["walkArrivalRadius100"].isSelected)
        app.navigationBars["導航設定"].buttons["完成"].tap()
        let stats = game.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "出發過 ")).firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        let before = stats.label.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(before.count, 2)
        openJournal(app)
        let journal = app.tables["walkJournalList"]
        let previousRows = journal.cells.count
        app.buttons["walkJournalDone"].tap()

        startGPSWalk(app, at: start)
        game.buttons["帶我回去"].tap()
        let confirm = app.alerts.buttons["結束散步並回程"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["帶我回去"].waitForExistence(timeout: 10), "選擇結束散步後應開啟回程導航")
        let status = app.descendants(matching: .any).matching(identifier: "walkReturnStatus").firstMatch
        let distance = app.descendants(matching: .any).matching(identifier: "walkReturnDistance").firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        XCTAssertEqual(distance.label, "距離已隱藏")
        setLocation(start)
        let north = NSPredicate(format: "label == %@", "朝北方回程")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: north, object: status)], timeout: 12),
                       .completed)
        distance.press(forDuration: 0.8)
        XCTAssertTrue(distance.label.contains("公尺"))
        let guide = XCTAttachment(screenshot: app.screenshot())
        guide.name = "回程方位與距離"
        guide.lifetime = .keepAlways
        add(guide)

        device.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        // 兩筆都距離保存點約 65 公尺，只在設定的 100 公尺範圍內。
        setLocation(.init(latitude: point.latitude - 0.00061, longitude: point.longitude))
        Thread.sleep(forTimeInterval: 1.2)
        setLocation(.init(latitude: point.latitude - 0.00057, longitude: point.longitude))
        Thread.sleep(forTimeInterval: 2)
        setLocation(start)
        XCTAssertNotEqual(app.state, .runningForeground)
        let notification = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "已抵達回程地點")
        ).firstMatch
        if !notification.waitForExistence(timeout: 2) || !notification.isHittable {
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.005))
            let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.85))
            top.press(forDuration: 0.15, thenDragTo: bottom)
        }
        XCTAssertTrue(notification.waitForExistence(timeout: 10), "系統通知應證明已在背景抵達回程地點")
        XCTAssertNotEqual(app.state, .runningForeground)
        notification.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "已抵達回程地點")
        app.buttons["walkFinishReturn"].tap()
        XCTAssertTrue(stats.waitForExistence(timeout: 8))
        XCTAssertEqual(stats.label.split(separator: " ").compactMap { Int($0) }, [before[0] + 1, before[1]])
        openJournal(app)
        XCTAssertEqual(journal.cells.count, previousRows + 1, "原本的散步收工後，回程不增加日誌趟次")
        app.buttons["walkJournalDone"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        let homeReturn = game.buttons["帶我回去"]
        homeReturn.tap()
        let stopReturn = app.buttons["walkFinishReturn"]
        XCTAssertTrue(stopReturn.waitForExistence(timeout: 8))
        XCTAssertEqual(stopReturn.label, "停止回程")
        stopReturn.tap()
        XCTAssertTrue(stats.waitForExistence(timeout: 8))
        XCTAssertEqual(stats.label.split(separator: " ").compactMap { Int($0) }, [before[0] + 1, before[1]])
        settingsButton.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 6))
        XCTAssertEqual(toggle.value as? String, "0", "回程長按顯示距離的選擇應保存")
        settings.cells["walkClearReturnPoint"].tap()
        app.alerts.buttons["清除"].tap()
        XCTAssertTrue(settings.staticTexts["尚未設定回程地點"].waitForExistence(timeout: 5))
        settings.cells["walkArrivalRadius0"].tap()
        app.navigationBars["導航設定"].buttons["完成"].tap()
        homeReturn.tap()
        XCTAssertTrue(settings.staticTexts["尚未設定回程地點"].waitForExistence(timeout: 8))
        XCTAssertFalse(settings.cells["walkStartReturn"].exists)
        app.navigationBars["導航設定"].buttons["完成"].tap()
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

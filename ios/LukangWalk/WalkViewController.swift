import CoreHaptics
import CoreLocation
import UIKit
import UserNotifications
import WebKit

private let bridgeName = "lukangWalk"

// WKUserContentController retains its handlers, so it must not own the view controller.
private final class WalkMessages: NSObject, WKScriptMessageHandler {
    weak var owner: WalkViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

final class WalkViewController: UIViewController, WKNavigationDelegate {
    private let preferences = WalkNavigationPreferences()
    private lazy var location = WalkLocation(preferences: preferences)
    private var returnScreen: WalkNavigationViewController?
    private var returnSession: Int?
    private var deferredReturnArrivalToken: String?
    private var returnSerial = 0
    private let returnReceiptKey = "Walk.pendingReturnReceipt"
    private let progress = WalkProgress()
    private let album = WalkPhotoAlbum()
    private let journal = WalkJournalStore()
    private var activeTrip: (id: String, session: Int?)?
    private var tripWentIntoBackground = false
    private var previousVisits: (real: [Int], simulated: [Int]) = ([], [])
    private var previousReceipt: WalkProgress.Arrival?
    private var capturedPreviousVisits = false
    private var journalPreparation: Task<Void, Error>?
    private var journalPrepared = false
    private static let photoScript: String = {
        var sprites: [String: String] = [:]
        for name in ["cheer", "idle"] {
            guard let file = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "Web/sprites"),
                  let bytes = try? Data(contentsOf: file) else { return "" }
            sprites[name] = "data:image/webp;base64," + bytes.base64EncodedString()
        }
        guard let data = try? JSONEncoder().encode(sprites), let json = String(data: data, encoding: .utf8) else { return "" }
        return "window.lukangCardSprites = " + json + "; window.lukangWalkPhotos = true;"
    }()
    private let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web")
    private var web: WKWebView!
    private var awake = false
    private var foreground = false
    private var pageReady = false
    private var pageGeneration = 0
    private var deferredLocationError: [String: Any]?
    private var notificationSession: Int?
    private var notificationsUnavailable = false
    private var haptics: CHHapticEngine?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let handler = WalkMessages()
        handler.owner = self
        configuration.userContentController.add(handler, name: bridgeName)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(named: "LaunchBackground") ?? .systemBackground
        web.underPageBackgroundColor = web.backgroundColor
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        do { try capturePreviousVisits() }
        catch { deferredLocationError = ["type": "storeError"] }
        location.onEvent = { [weak self] event in
            guard let self else { return }
            if let session = event["session"] as? Int, session < 0 {
                if session == self.returnSession {
                    self.returnScreen?.receive(event)
                    if event["type"] as? String == "error" {
                        self.awake = false
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                }
                return
            }
            if event["type"] as? String == "error", let session = event["session"] as? Int,
               let trip = self.activeTrip, trip.session == session {
                self.endTrip(id: trip.id, status: .interrupted)
            }
            if self.foreground && self.pageReady {
                self.send(event)
            } else if event["type"] as? String == "error" {
                self.deferredLocationError = event
            }
        }
        location.onArrival = { [weak self] session, placeID, inBackground in
            self?.finishWalk(session: session, placeID: placeID, inBackground: inBackground)
        }
        location.onReturnArrival = { [weak self] session, inBackground in
            self?.finishReturn(session: session, inBackground: inBackground)
        }
        loadGame()
    }

    private func loadGame() {
        pageReady = false
        pageGeneration += 1
        guard let index else {
            let label = UILabel()
            label.text = "讀不到散步吧的畫面。請重新安裝 App。"
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 24, dy: 0)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
            return
        }
        let scripts = web.configuration.userContentController
        scripts.removeAllUserScripts()
        let nav = (try? JSONSerialization.data(withJSONObject: navigationValues))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        scripts.addUserScript(WKUserScript(source: progress.initialScript + Self.photoScript
                                           + "window.lukangWalkJournal = true;window.lukangPlaceReporting = true;"
                                           + "window.lukangNavigation = " + nav + ";",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        var entry = index
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-simulate-walk") {
            var url = URLComponents(url: index, resolvingAgainstBaseURL: false)
            url?.fragment = "sim"
            entry = url?.url ?? index
        }
        #endif
        web.loadFileURL(entry, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func setForeground(_ active: Bool) {
        foreground = active
        location.setForeground(active)
        UIApplication.shared.isIdleTimerDisabled = awake && active
        if !active {
            if activeTrip?.session != nil { tripWentIntoBackground = true }
            haptics?.stop(completionHandler: nil)
            haptics = nil
        } else {
            restorePage()
        }
    }

    private var canPresentWalk: Bool {
        foreground && pageReady && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func restorePage() {
        guard canPresentWalk else { return }
        if returnScreen != nil { return }
        if let token = UserDefaults.standard.string(forKey: returnReceiptKey), presentedViewController == nil {
            if let point = preferences.returnPoint {
                presentReturn(point: point, alreadyArrived: true)
                return
            }
            clearReturnReceipt(token)
        }
        if var arrival = progress.arrivalEvent {
            if let token = deferredReturnArrivalToken, token == progress.pendingArrival?.token {
                arrival["replayAfterReturn"] = true
            }
            send(arrival)
        } else if let walk = location.activeTarget {
            var event: [String: Any] = ["type": "resumeWalk", "session": walk.session, "placeID": walk.placeID]
            if let trip = activeTrip, walk.session == trip.session { event["id"] = trip.id }
            send(event)
            requestArrivalAlerts(for: walk.session)
        } else if let error = deferredLocationError {
            deferredLocationError = nil
            send(error)
        }
    }

    private func requestArrivalAlerts(for session: Int) {
        guard foreground else { return }
        if notificationSession == session {
            if notificationsUnavailable { send(["type": "notificationUnavailable", "session": session]) }
            return
        }
        notificationSession = session
        notificationsUnavailable = false
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self, self.notificationSession == session else { return }
                self.notificationsUnavailable = !granted
                if !granted && self.returnSession == session {
                    self.returnScreen?.receive(["type": "notificationUnavailable"])
                } else if !granted && self.foreground && self.pageReady && self.location.activeTarget?.session == session {
                    self.send(["type": "notificationUnavailable", "session": session])
                }
            }
        }
    }

    private func finishWalk(session: Int, placeID: Int, inBackground: Bool) {
        awake = false
        UIApplication.shared.isIdleTimerDisabled = false
        let visitID = activeTrip.flatMap { $0.session == session ? $0.id : nil } ?? UUID().uuidString
        do {
            try progress.recordArrival(placeID: placeID, session: session, visitID: visitID,
                                       distanceIncomplete: inBackground || tripWentIntoBackground)
        }
        catch { if foreground && pageReady { send(["type": "storeError"]) } }
        let receipt = progress.pendingArrival.flatMap { $0.token == visitID ? $0 : nil }
        endTrip(id: visitID, status: .arrived, date: receipt?.date,
                stop: receipt == nil ? nil : progress.visitedPlaces.real.count)
        guard let arrival = receipt else { return }
        if inBackground || view.window?.windowScene?.activationState != .foregroundActive {
            postArrivalNotification(arrival.token)
        } else {
            playArrival()
        }
        restorePage()
    }

    private func postArrivalNotification(_ token: String, returning: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = returning ? "已抵達回程地點" : "散步到站了"
        content.body = returning ? "你已經回到設定的位置了。" : "小嚮導已經找到目的地，點一下揭曉這一站。"
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        let endTask = {
            if task != .invalid { app.endBackgroundTask(task); task = .invalid }
        }
        task = app.beginBackgroundTask(withName: "Walk arrival", expirationHandler: endTask)
        let request = UNNotificationRequest(identifier: token, content: content, trigger: nil)
        center.add(request) { [weak self] _ in
            DispatchQueue.main.async {
                endTask()
                guard let self else { return }
                let pending = returning ? UserDefaults.standard.string(forKey: self.returnReceiptKey) : self.progress.pendingArrival?.token
                if pending != token {
                    center.removeDeliveredNotifications(withIdentifiers: [token])
                }
            }
        }
    }

    private func isGameURL(_ url: URL?) -> Bool {
        guard let url, let index, url.isFileURL else { return false }
        return url.standardizedFileURL.path == index.standardizedFileURL.path
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == bridgeName, message.frameInfo.isMainFrame,
              isGameURL(message.frameInfo.request.url),
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        // 原生回程開始時，舊頁面可能還有排隊中的抽點、收工或感測器訊息。
        if returnScreen != nil, action != "ready", action != "store", action != "arrivalShown" { return }
        switch action {
        case "ready":
            pageReady = true
            sendNavigationPreferences()
            restorePage()
            Task {
                do {
                    try await prepareJournal()
                    if progress.pendingArrival != nil { restorePage() }
                } catch { send(["type": "storeError"]) }
            }
        case "navigationSettings":
            showNavigationSettings(startReturnAfterSetup: false)
        case "returnNavigation":
            requestReturn()
        case "setHideDistance":
            guard let hidden = body["hidden"] as? Bool else { return }
            do { try preferences.setHideDistance(hidden) }
            catch { send(["type": "storeError"]) }
            sendNavigationPreferences()
        case "start":
            guard progress.pendingArrival == nil else { restorePage(); return }
            if let session = body["session"] as? Int, session > 0 {
                deferredLocationError = nil
                notificationSession = nil
                location.start(session)
            }
        case "target":
            guard let session = body["session"] as? Int, let placeID = body["placeID"] as? Int,
                  let latitude = body["latitude"] as? Double, let longitude = body["longitude"] as? Double else { return }
            location.setTarget(session: session, placeID: placeID, latitude: latitude, longitude: longitude)
            if let target = location.activeTarget, target.session == session, target.placeID == placeID {
                beginTrip(body, session: session)
                requestArrivalAlerts(for: session)
            }
        case "journalBegin":
            if body["isSimulated"] as? Bool == true { beginTrip(body, session: nil) }
        case "journalFinish":
            guard let id = body["id"] as? String, activeTrip?.id == id,
                  let value = body["status"] as? String, let status = WalkJournalStore.Status(rawValue: value),
                  status == .stopped || status == .interrupted || (status == .arrived && activeTrip?.session == nil) else { return }
            endTrip(id: id, status: status, stop: body["stop"] as? Int, walked: body["walked"] as? Double)
        case "journal":
            openJournal(showing: body["id"] as? String)
        case "reportPlace":
            guard let visitID = body["visitID"] as? String, let placeID = body["placeID"] as? Int else { return }
            openPlaceReport(visitID: visitID, placeID: placeID)
        case "arrivalShown":
            guard canPresentWalk, let token = body["token"] as? String, progress.pendingArrival?.token == token else { return }
            do {
                guard journalPrepared else { return }
                guard let entry = try journal.entry(id: token) else {
                    previousReceipt = progress.pendingArrival
                    journalPrepared = false
                    Task {
                        do { try await prepareJournal(); restorePage() }
                        catch { send(["type": "storeError"]) }
                    }
                    return
                }
                if entry.status != .arrived {
                    try journal.finish(id: token, status: .arrived, date: progress.pendingArrival?.date,
                                       stop: progress.visitedPlaces.real.count)
                }
                try progress.acknowledgeArrival(token)
                if deferredReturnArrivalToken == token { deferredReturnArrivalToken = nil }
            } catch { send(["type": "storeError"]); return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [token])
        case "stop":
            if let session = body["session"] as? Int { location.stop(session) }
        case "awake":
            guard let enabled = body["enabled"] as? Bool else { return }
            awake = enabled
            UIApplication.shared.isIdleTimerDisabled = enabled && foreground
        case "arrived":
            if foreground { playArrival() }
        case "credits":
            showCredits()
        case "photoAlbum":
            if canPresentWalk && presentedViewController == nil { album.present(from: self) }
        case "walkPhoto":
            if let fields = body["visit"] as? [String: Any] { takeWalkPhoto(fields) }
        case "store":
            let changes: [String: Any]
            if let batch = body["values"] as? [String: Any] {
                changes = batch
            } else if let key = body["key"] as? String, let value = body["value"] {
                changes = [key: value]
            } else { return }
            do {
                try progress.save(changes)
            } catch {
                send(["type": "storeError"])
            }
        default: break
        }
    }

    private func send(_ event: [String: Any]) {
        web.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('lukangNative', {detail: event}));",
                                arguments: ["event": event], in: nil, in: .page, completionHandler: nil)
    }

    private var navigationValues: [String: Any] {
        ["hideDistance": preferences.hideDistance, "arrivalRadius": preferences.arrivalRadius,
         "hasReturnPoint": preferences.returnPoint != nil]
    }

    private func sendNavigationPreferences() {
        guard pageReady else { return }
        var event = navigationValues
        event["type"] = "navigationPreferences"
        send(event)
    }

    private func showNavigationSettings(startReturnAfterSetup: Bool) {
        guard canPresentWalk, presentedViewController == nil else { return }
        let afterSetup: (() -> Void)? = startReturnAfterSetup ? { [weak self] in self?.requestReturn() } : nil
        let screen = WalkNavigationSettingsViewController(preferences: preferences,
                                                          onChanged: { [weak self] in self?.sendNavigationPreferences() },
                                                          onStartReturn: afterSetup)
        present(UINavigationController(rootViewController: screen), animated: true)
    }

    private func requestReturn() {
        guard canPresentWalk, presentedViewController == nil else { return }
        guard let point = preferences.returnPoint else { showNavigationSettings(startReturnAfterSetup: true); return }
        let manager = CLLocationManager()
        let permission = manager.authorizationStatus
        if permission == .denied || permission == .restricted ||
            (permission != .notDetermined && manager.accuracyAuthorization != .fullAccuracy) {
            let alert = UIAlertController(title: "回程需要準確位置",
                                          message: "請在 iPhone 設定允許《散步吧》使用定位，並開啟準確位置。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        guard let trip = activeTrip else { presentReturn(point: point); return }
        let alert = UIAlertController(title: "現在回程？", message: "這趟散步會收工。照片和筆記會留在日誌裡。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "繼續散步", style: .cancel))
        alert.addAction(UIAlertAction(title: "結束散步並回程", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let start = {
                guard self.canPresentWalk, self.presentedViewController == nil else { return }
                if let current = self.activeTrip {
                    guard current.id == trip.id else { return }
                    do { try self.journal.finish(id: current.id, status: .stopped) }
                    catch { self.send(["type": "storeError"]); return }
                    self.activeTrip = nil
                }
                self.presentReturn(point: point)
            }
            if let alert, alert.presentingViewController != nil { alert.dismiss(animated: true, completion: start) }
            else { start() }
        })
        present(alert, animated: true)
    }

    private func presentReturn(point: WalkNavigationPreferences.Point, alreadyArrived: Bool = false) {
        guard returnScreen == nil, presentedViewController == nil else { return }
        let screen = WalkNavigationViewController(point: point, preferences: preferences,
            onChanged: { [weak self] in self?.sendNavigationPreferences() },
            onStop: { [weak self] in self?.closeReturn() },
            onRetry: { [weak self] in self?.startReturnLocation(point) },
            onClose: { [weak self] in self?.closeReturn() })
        returnScreen = screen
        let nav = UINavigationController(rootViewController: screen)
        nav.isModalInPresentation = true
        present(nav, animated: true)
        if alreadyArrived {
            screen.loadViewIfNeeded()
            screen.didArrive()
        } else {
            deferredReturnArrivalToken = progress.pendingArrival?.token
            send(["type": "leaveForReturn"])
            startReturnLocation(point)
        }
    }

    private func startReturnLocation(_ point: WalkNavigationPreferences.Point) {
        returnSerial -= 1
        returnSession = returnSerial
        awake = true
        UIApplication.shared.isIdleTimerDisabled = foreground
        returnScreen?.loadViewIfNeeded()
        location.startReturn(session: returnSerial, latitude: point.latitude, longitude: point.longitude)
        if location.activeReturn == returnSerial { requestArrivalAlerts(for: returnSerial) }
    }

    private func finishReturn(session: Int, inBackground: Bool) {
        guard session == returnSession else { return }
        awake = false
        UIApplication.shared.isIdleTimerDisabled = false
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: returnReceiptKey)
        returnScreen?.didArrive()
        if inBackground || view.window?.windowScene?.activationState != .foregroundActive {
            postArrivalNotification(token, returning: true)
        } else { playArrival() }
    }

    private func clearReturnReceipt(_ token: String) {
        UserDefaults.standard.removeObject(forKey: returnReceiptKey)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [token])
    }

    private func closeReturn() {
        guard let screen = returnScreen else { return }
        if let session = returnSession { location.stop(session) }
        returnSession = nil
        awake = false
        UIApplication.shared.isIdleTimerDisabled = false
        if let token = UserDefaults.standard.string(forKey: returnReceiptKey) { clearReturnReceipt(token) }
        screen.dismiss(animated: true) { [weak self] in
            self?.returnScreen = nil
            self?.restorePage()
        }
    }

    private func beginTrip(_ body: [String: Any], session: Int?) {
        guard let id = body["id"] as? String, UUID(uuidString: id) != nil,
              let placeID = body["placeID"] as? Int, placeID > 0,
              let name = body["name"] as? String, !name.isEmpty else { return }
        if activeTrip?.id != id {
            if let previous = activeTrip { endTrip(id: previous.id, status: .interrupted) }
            tripWentIntoBackground = !foreground
        }
        activeTrip = (id, session)
        do {
            try journal.begin(id: id, placeID: placeID, name: name, isSimulated: session == nil,
                              latitude: body["latitude"] as? Double, longitude: body["longitude"] as? Double)
        } catch { send(["type": "storeError"]) }
    }

    private func endTrip(id: String, status: WalkJournalStore.Status, date: String? = nil,
                         stop: Int? = nil, walked: Double? = nil) {
        do { try journal.finish(id: id, status: status, date: date, stop: stop, walked: walked) }
        catch { send(["type": "storeError"]) }
        if activeTrip?.id == id { activeTrip = nil }
    }

    private func prepareJournal() async throws {
        if journalPrepared { return }
        if let journalPreparation { try await journalPreparation.value; return }
        let task = Task { try await self.importPreviousWalks() }
        journalPreparation = task
        defer { journalPreparation = nil }
        try await task.value
        journalPrepared = true
    }

    private func capturePreviousVisits() throws {
        guard !capturedPreviousVisits else { return }
        try progress.ensureLoaded()
        previousVisits = progress.visitedPlaces
        previousReceipt = progress.pendingArrival
        try journal.interruptWalking(except: previousReceipt?.token ?? activeTrip?.id)
        capturedPreviousVisits = true
    }

    private func importPreviousWalks() async throws {
        try capturePreviousVisits()
        let pending = previousReceipt
        guard journal.needsMigration || pending != nil else { return }
        let photos = journal.needsMigration ? try await album.savedVisits() : []
        var ids = Set(photos.map { $0.placeID })
        if journal.needsMigration { ids.formUnion(previousVisits.real); ids.formUnion(previousVisits.simulated) }
        if let pending { ids.insert(pending.placeID) }
        var places: [Int: WalkJournalStore.Place] = [:]
        if !ids.isEmpty {
            let result = try await web.callAsyncJavaScript("return window.lukangJournalPlaces(ids);",
                                                           arguments: ["ids": Array(ids)], in: nil, contentWorld: .page)
            guard let rows = result as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            for row in rows {
                guard let id = row["placeID"] as? Int, let name = row["name"] as? String else { continue }
                places[id] = WalkJournalStore.Place(name: name, latitude: row["latitude"] as? Double,
                                                    longitude: row["longitude"] as? Double)
            }
        }
        if let pending {
            let place = places[pending.placeID]
            try journal.recoverArrival(id: pending.token, placeID: pending.placeID,
                                       name: place?.name ?? "先前到訪的地點", isSimulated: false,
                                       date: pending.date, latitude: place?.latitude, longitude: place?.longitude)
        }
        if journal.needsMigration {
            try journal.migrate(photoVisits: photos, seen: previousVisits.real, simSeen: previousVisits.simulated,
                                place: { places[$0] })
        }
        previousReceipt = nil
    }

    private func openPlaceReport(visitID: String, placeID: Int) {
        guard canPresentWalk, presentedViewController == nil else { return }
        let generation = pageGeneration
        Task {
            do {
                try await prepareJournal()
                guard generation == pageGeneration, canPresentWalk, presentedViewController == nil,
                      let entry = try journal.entry(id: visitID), entry.status == .arrived,
                      !entry.isSimulated, entry.placeID == placeID else { return }
                let report = WalkPlaceReportViewController(placeID: entry.placeID, placeName: entry.name)
                present(UINavigationController(rootViewController: report), animated: true)
            } catch {
                send(["type": "storeError"])
            }
        }
    }

    private func openJournal(showing id: String?) {
        guard canPresentWalk, presentedViewController == nil else { return }
        Task {
            do {
                try await prepareJournal()
                guard canPresentWalk, presentedViewController == nil else { return }
                WalkJournalViewController.present(from: self, store: journal, album: album, showing: id) {
                    [weak self] presenter, id in self?.takeJournalPhoto(from: presenter, id: id)
                }
            } catch {
                let alert = UIAlertController(title: "暫時無法讀取散步日誌", message: "請再開啟一次日誌。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                if presentedViewController == nil { present(alert, animated: true) }
            }
        }
    }

    private func takeJournalPhoto(from presenter: UIViewController, id: String) {
        guard presenter.presentedViewController == nil, let entry = try? journal.entry(id: id),
              entry.status != .legacy else { return }
        // 途中、中斷與收工的行程都不會從相機標題或透卡透露未揭曉的地點。
        let title = entry.status == .arrived ? entry.name : "散步途中"
        let visit = WalkPhotoAlbum.Visit(id: UUID().uuidString, placeID: entry.placeID, name: title,
                                         date: entry.date, isSimulated: entry.isSimulated, tripID: entry.id)
        var snapshot: [String: Any] = ["id": id, "status": entry.status.rawValue, "name": title,
                                       "date": entry.date, "placeID": entry.placeID]
        if let stop = entry.stop { snapshot["stop"] = stop }
        if let walked = entry.walked { snapshot["walked"] = walked }
        let capture = WalkPhotoCaptureController(place: title, save: { [weak self] photo in
            guard let self else { throw CocoaError(.userCancelled) }
            let card = try await self.renderPhotoCard("return await window.lukangRenderJournalCard(photo, snapshot);",
                                                      photo: photo, arguments: ["snapshot": snapshot])
            try await self.album.save(visit: visit, photo: photo, card: card)
        }, onSaved: { NotificationCenter.default.post(name: .walkJournalDidChange, object: nil) })
        presenter.present(UINavigationController(rootViewController: capture), animated: true)
    }

    private func renderPhotoCard(_ script: String, photo: Data, arguments: [String: Any]) async throws -> Data {
        var fields = arguments
        fields["photo"] = photo.base64EncodedString()
        let result = try await web.callAsyncJavaScript(script, arguments: fields, in: nil, contentWorld: .page)
        guard let base64 = result as? String, let card = Data(base64Encoded: base64),
              card.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw CocoaError(.fileReadCorruptFile) }
        return card
    }

    private func takeWalkPhoto(_ fields: [String: Any]) {
        guard canPresentWalk, presentedViewController == nil,
              let id = fields["id"] as? String, UUID(uuidString: id) != nil,
              let placeID = fields["placeID"] as? Int, placeID > 0,
              let name = fields["name"] as? String, !name.isEmpty,
              let date = fields["date"] as? String, let simulated = fields["isSimulated"] as? Bool else { return }
        let visit = WalkPhotoAlbum.Visit(id: UUID().uuidString, placeID: placeID, name: name, date: date,
                                         isSimulated: simulated, tripID: id)
        let originalPage = pageGeneration
        let capture = WalkPhotoCaptureController(place: name, save: { [weak self] photo in
            guard let self else { throw CocoaError(.userCancelled) }
            // 相機開啟時，系統可能回收下方的網頁。只有重載後才使用按下拍照時保留的到站資料。
            var arguments: [String: Any] = ["visitID": id, "recovered": NSNull()]
            if self.pageGeneration != originalPage {
                for _ in 0..<30 {
                    if self.pageReady { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.pageReady else { throw CocoaError(.fileReadUnknown) }
                arguments["recovered"] = fields
            }
            let card = try await self.renderPhotoCard("return await window.lukangRenderWalkCard(photo, visitID, recovered);",
                                                      photo: photo, arguments: arguments)
            try await self.album.save(visit: visit, photo: photo, card: card)
        }, onSaved: { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .walkJournalDidChange, object: nil)
            self.album.present(from: self, showing: visit.id)
        })
        present(UINavigationController(rootViewController: capture), animated: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && isGameURL(navigationAction.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let trip = activeTrip, trip.session == nil { endTrip(id: trip.id, status: .interrupted) }
        if location.activeTarget == nil && location.activeReturn == nil { location.end() }
        if returnScreen == nil {
            awake = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        loadGame()
    }

    private func playArrival() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if haptics == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = true
                haptics = engine
            }
            guard let engine = haptics else { return }
            let pulses = [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [], relativeTime: 0, duration: 0.06),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [], relativeTime: 0.10, duration: 0.12)
            ]
            let pattern = try CHHapticPattern(events: pulses, parameters: [])
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            haptics = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func showCredits() {
        guard presentedViewController == nil,
              let page = Bundle.main.url(forResource: "credits", withExtension: "html", subdirectory: "Web")
        else { return }
        present(UINavigationController(rootViewController: CreditsViewController(page: page)), animated: true)
    }
}

private final class CreditsViewController: UIViewController, WKNavigationDelegate {
    private let page: URL
    private var initialLoad: WKNavigation?
    private var retriedAfterTermination = false

    init(page: URL) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "資料來源與授權"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .plain, target: self,
                                                           action: #selector(close))
        if let web = view as? WKWebView {
            loadCredits(in: web)
        }
    }

    private func loadCredits(in web: WKWebView) {
        guard let html = try? String(contentsOf: page, encoding: .utf8) else {
            showLoadError()
            return
        }
        // 授權頁的樣式與文字都在此檔案內，對外連結均使用完整網址。
        initialLoad = web.loadHTMLString(html, baseURL: nil)
    }

    private func showLoadError() {
        let message = UILabel()
        message.text = "無法讀取資料來源與授權。請關閉此頁後再試一次。"
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.backgroundColor = .systemBackground
        view = message
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        if navigation === initialLoad { showLoadError() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === initialLoad { showLoadError() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !retriedAfterTermination else { showLoadError(); return }
        retriedAfterTermination = true
        loadCredits(in: webView)
    }

    @objc private func close() { dismiss(animated: true) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .other && url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
            UIApplication.shared.open(url)
        }
    }
}

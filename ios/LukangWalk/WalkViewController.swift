import CoreHaptics
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
    private let location = WalkLocation()
    private let progress = WalkProgress()
    private let album = WalkPhotoAlbum()
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
        location.onEvent = { [weak self] event in
            guard let self else { return }
            if self.foreground && self.pageReady {
                self.send(event)
            } else if event["type"] as? String == "error" {
                self.deferredLocationError = event
            }
        }
        location.onArrival = { [weak self] session, placeID, inBackground in
            self?.finishWalk(session: session, placeID: placeID, inBackground: inBackground)
        }
        loadGame()
    }

    private func loadGame() {
        pageReady = false
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
        scripts.addUserScript(WKUserScript(source: progress.initialScript + Self.photoScript,
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
        if let arrival = progress.arrivalEvent {
            send(arrival)
        } else if let walk = location.activeTarget {
            send(["type": "resumeWalk", "session": walk.session, "placeID": walk.placeID])
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
                if !granted && self.foreground && self.pageReady && self.location.activeTarget?.session == session {
                    self.send(["type": "notificationUnavailable", "session": session])
                }
            }
        }
    }

    private func finishWalk(session: Int, placeID: Int, inBackground: Bool) {
        awake = false
        UIApplication.shared.isIdleTimerDisabled = false
        do { try progress.recordArrival(placeID: placeID, session: session) }
        catch { if foreground && pageReady { send(["type": "storeError"]) } }
        guard let arrival = progress.pendingArrival else { return }
        if inBackground || view.window?.windowScene?.activationState != .foregroundActive {
            postArrivalNotification(arrival.token)
        } else {
            playArrival()
        }
        restorePage()
    }

    private func postArrivalNotification(_ token: String) {
        let content = UNMutableNotificationContent()
        content.title = "散步到站了"
        content.body = "小嚮導已經找到目的地，點一下揭曉這一站。"
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
                if let self, self.progress.pendingArrival?.token != token {
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
        switch action {
        case "ready":
            pageReady = true
            restorePage()
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
            if location.activeTarget?.session == session { requestArrivalAlerts(for: session) }
        case "arrivalShown":
            guard canPresentWalk, let token = body["token"] as? String, progress.pendingArrival?.token == token else { return }
            do { try progress.acknowledgeArrival(token) } catch { send(["type": "storeError"]) }
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

    private func takeWalkPhoto(_ fields: [String: Any]) {
        guard canPresentWalk, presentedViewController == nil,
              let id = fields["id"] as? String, UUID(uuidString: id) != nil,
              let placeID = fields["placeID"] as? Int, placeID > 0,
              let name = fields["name"] as? String, !name.isEmpty,
              let date = fields["date"] as? String, let simulated = fields["isSimulated"] as? Bool else { return }
        let visit = WalkPhotoAlbum.Visit(id: id, placeID: placeID, name: name, date: date, isSimulated: simulated)
        let capture = WalkPhotoCaptureController(place: name, save: { [weak self] photo in
            guard let self else { throw CocoaError(.userCancelled) }
            let result = try await self.web.callAsyncJavaScript(
                "return await window.lukangRenderWalkCard(photo, visitID);",
                arguments: ["photo": photo.base64EncodedString(), "visitID": id], in: nil, contentWorld: .page)
            guard let base64 = result as? String, let card = Data(base64Encoded: base64),
                  card.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw CocoaError(.fileReadCorruptFile) }
            try await self.album.save(visit: visit, photo: photo, card: card)
        }, onSaved: { [weak self] in
            guard let self else { return }
            self.album.present(from: self, showing: id)
        })
        present(UINavigationController(rootViewController: capture), animated: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && isGameURL(navigationAction.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if location.activeTarget == nil { location.end() }
        awake = false
        UIApplication.shared.isIdleTimerDisabled = false
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self,
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

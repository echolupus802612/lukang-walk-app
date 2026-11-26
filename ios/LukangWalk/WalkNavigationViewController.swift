import CoreLocation
import UIKit

@MainActor
final class WalkNavigationSettingsViewController: UITableViewController, CLLocationManagerDelegate {
    private let preferences: WalkNavigationPreferences
    private let onChanged: () -> Void
    private let onStartReturn: (() -> Void)?
    private let radii = [0, 25, 50, 100]
    private var locator: CLLocationManager?
    private var askedPermission = false
    private var askedLocation = false
    private var locateTimeout: Timer?
    private var pointMessage: String?
    private var suggestSettings = false

    init(preferences: WalkNavigationPreferences, onChanged: @escaping () -> Void,
         onStartReturn: (() -> Void)? = nil) {
        self.preferences = preferences
        self.onChanged = onChanged
        self.onStartReturn = onStartReturn
        super.init(style: .insetGrouped)
        title = "導航設定"
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "walkNavigationSettings"
        WalkTheme.paint(tableView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .plain, target: self,
                                                           action: #selector(close))
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLocating()
    }

    @objc private func close() {
        stopLocating()
        dismiss(animated: true)
    }

    @objc private func enteredBackground() {
        guard locator != nil else { return }
        finishLocating("已暫停取得位置，請回到這裡再試一次。")
    }

    private enum Row {
        case capture, clear, settings, start, hide, radius(Int)
    }

    private func rows(in section: Int) -> [Row] {
        switch section {
        case 0:
            var rows: [Row] = [.capture]
            if suggestSettings { rows.append(.settings) }
            if preferences.returnPoint != nil {
                if onStartReturn != nil { rows.append(.start) }
                rows.append(.clear)
            }
            return rows
        case 1: return [.hide]
        default: return radii.map { .radius($0) }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["回程地點", "距離顯示", "到站範圍"][section]
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        WalkTheme.style(header: view)
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        WalkTheme.style(header: view, footer: true)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return pointMessage ?? "點選後才會取得目前位置。回程地點只儲存在這支 iPhone。"
        case 1: return "散步或回程時，也可以長按距離來切換。"
        default: return "自動會依定位精確度調整到站範圍。"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch rows(in: indexPath.section)[indexPath.row] {
        case .capture:
            cell.accessibilityIdentifier = "walkSaveReturnPoint"
            let hasPoint = preferences.returnPoint != nil
            content.text = hasPoint ? "改用目前位置" : "將目前位置設為回程地點"
            content.secondaryText = locator != nil ? "正在取得位置⋯" : (hasPoint ? "已儲存回程地點" : "尚未設定回程地點")
            content.image = UIImage(systemName: "location.circle")
        case .clear:
            cell.accessibilityIdentifier = "walkClearReturnPoint"
            content.text = "清除回程地點"
            content.textProperties.color = .systemRed
        case .settings:
            content.text = "開啟 iPhone 設定"
            cell.accessoryType = .disclosureIndicator
        case .start:
            cell.accessibilityIdentifier = "walkStartReturn"
            content.text = "開始回程"
            content.image = UIImage(systemName: "arrow.uturn.backward")
        case .hide:
            content.text = "隱藏距離"
            let toggle = UISwitch()
            toggle.isOn = preferences.hideDistance
            toggle.accessibilityLabel = "隱藏距離"
            toggle.accessibilityIdentifier = "walkHideDistance"
            toggle.addTarget(self, action: #selector(toggleDistance(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .radius(let value):
            content.text = value == 0 ? "自動" : "\(value) 公尺"
            cell.accessibilityIdentifier = "walkArrivalRadius\(value)"
            if preferences.arrivalRadius == value {
                cell.accessoryType = .checkmark
                cell.accessibilityTraits.insert(.selected)
            }
        }
        WalkTheme.style(cell, &content)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(in: indexPath.section)[indexPath.row] {
        case .capture: capturePoint()
        case .clear:
            let alert = WalkAlert(title: "清除回程地點？", message: nil)
            alert.addAction(WalkAlert.Action(title: "取消", style: .cancel))
            alert.addAction(WalkAlert.Action(title: "清除", style: .destructive) { [weak self] _ in
                guard let self else { return }
                stopLocating()
                do {
                    try preferences.clearReturnPoint()
                    pointMessage = nil
                    suggestSettings = false
                    onChanged()
                    tableView.reloadData()
                } catch { showSaveError() }
            })
            present(alert, animated: true)
        case .settings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .start:
            stopLocating()
            dismiss(animated: true, completion: onStartReturn)
        case .hide:
            if let toggle = tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch {
                toggle.setOn(!toggle.isOn, animated: true)
                toggleDistance(toggle)
            }
        case .radius(let value):
            do {
                try preferences.setArrivalRadius(value)
                onChanged()
                tableView.reloadData()
            } catch { showSaveError() }
        }
    }

    @objc private func toggleDistance(_ toggle: UISwitch) {
        do {
            try preferences.setHideDistance(toggle.isOn)
            onChanged()
        } catch {
            toggle.setOn(preferences.hideDistance, animated: true)
            showSaveError()
        }
    }

    private func showSaveError() {
        let alert = WalkAlert(title: "無法儲存導航設定", message: "請再試一次。")
        alert.addAction(WalkAlert.Action(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func capturePoint() {
        guard locator == nil else { return }
        let manager = CLLocationManager()
        locator = manager
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.delegate = self
        suggestSettings = false
        pointMessage = nil
        tableView.reloadData()
        applyAuthorization(manager)
    }

    private func applyAuthorization(_ manager: CLLocationManager) {
        guard locator === manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !askedPermission {
                askedPermission = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            guard manager.accuracyAuthorization == .fullAccuracy else {
                finishLocating("請在 iPhone 設定開啟「準確位置」，再回來設定回程地點。", settings: true)
                return
            }
            guard !askedLocation else { return }
            askedLocation = true
            manager.requestLocation()
            locateTimeout = Timer.scheduledTimer(timeInterval: 20, target: self,
                                                 selector: #selector(locationTimedOut), userInfo: nil, repeats: false)
        case .restricted, .denied:
            finishLocating("尚未取得定位權限。請確認 iPhone 設定，再回來試一次。", settings: true)
        @unknown default:
            finishLocating("暫時無法取得位置，請再試一次。")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorization(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locator === manager, askedLocation, manager.accuracyAuthorization == .fullAccuracy else { return }
        let now = Date()
        guard let fix = locations.last(where: {
            CLLocationCoordinate2DIsValid($0.coordinate) && (0...40).contains($0.horizontalAccuracy)
                && (0...10).contains(now.timeIntervalSince($0.timestamp))
        }) else {
            finishLocating("定位還不夠準確，請到空曠處再試一次。")
            return
        }
        do {
            try preferences.saveReturnPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
            finishLocating("已將這裡設為回程地點。")
            onChanged()
        } catch {
            finishLocating("暫時無法儲存回程地點，請再試一次。")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard locator === manager else { return }
        if (error as? CLError)?.code == .denied {
            finishLocating("尚未取得定位權限。請確認 iPhone 設定，再回來試一次。", settings: true)
        } else {
            finishLocating("暫時無法取得位置，請到空曠處再試一次。")
        }
    }

    @objc private func locationTimedOut() { finishLocating("等待定位逾時，請再試一次。") }

    private func finishLocating(_ message: String, settings: Bool = false) {
        stopLocating()
        pointMessage = message
        suggestSettings = settings
        tableView.reloadData()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func stopLocating() {
        locateTimeout?.invalidate()
        locateTimeout = nil
        locator?.delegate = nil
        locator?.stopUpdatingLocation()
        locator = nil
        askedPermission = false
        askedLocation = false
    }
}

@MainActor
final class WalkNavigationViewController: UIViewController {
    private let point: WalkNavigationPreferences.Point
    private let preferences: WalkNavigationPreferences
    private let onChanged: () -> Void
    private let onStop: () -> Void
    private let onRetry: () -> Void
    private let onClose: () -> Void
    private let stage = WalkStageView()
    private let bubble = UIView()
    private var lastMoveAt = Date.distantPast
    private let status = UILabel()
    private let guidance = UILabel()
    private let distance = UILabel()
    private let notificationHint = UILabel()
    private let retry = UIButton(type: .system)
    private let action = UIButton(type: .system)
    private var heading: Double?
    private var bearing: Double?
    private var meters: Double?
    private var fixTimeout: Timer?
    private var ended = false
    private var locationFailed = false
    private var fixExpired = false
    private var notifyUnavailable = false

    init(point: WalkNavigationPreferences.Point, preferences: WalkNavigationPreferences,
         onChanged: @escaping () -> Void, onStop: @escaping () -> Void,
         onRetry: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.point = point
        self.preferences = preferences
        self.onChanged = onChanged
        self.onStop = onStop
        self.onRetry = onRetry
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        title = "帶我回去"
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        WalkTheme.stage(self)
        navigationController?.isModalInPresentation = true

        // 版面照主畫面：提示、小嚮導踩在地面箭頭上、距離、對話框、按鈕。
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        view.addSubview(scroll)
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let frame = scroll.frameLayoutGuide
        let content = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -32),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor, constant: -24)
        ])

        // 跟主畫面一樣：文楷寫提示與台詞、黑體寫距離，米白字在紅磚底上。
        let looks: [(UILabel, UIFont, UIColor)] = [
            (status, WalkTheme.kai(20, style: .title3), WalkTheme.soft),
            (guidance, WalkTheme.kai(18, style: .body), WalkTheme.ink),
            (distance, WalkTheme.sans(48, weight: .bold, style: .largeTitle), WalkTheme.ink),
            (notificationHint, WalkTheme.sans(13, weight: .regular, style: .footnote), WalkTheme.soft)
        ]
        for (label, font, color) in looks {
            label.font = font
            label.textColor = color
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        status.accessibilityIdentifier = "walkReturnStatus"
        guidance.accessibilityIdentifier = "walkReturnGuidance"
        distance.accessibilityIdentifier = "walkReturnDistance"
        distance.isUserInteractionEnabled = true
        distance.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(heldDistance(_:))))
        distance.accessibilityHint = "長按可切換距離顯示。"
        notificationHint.text = "目前無法傳送通知。回到 App 即可查看回程狀態。"
        // 小嚮導的話放在半透明的圓角框裡，跟主畫面的對話框一樣。
        bubble.backgroundColor = WalkTheme.shade
        bubble.layer.cornerRadius = 16
        bubble.layer.cornerCurve = .continuous
        guidance.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(guidance)
        NSLayoutConstraint.activate([
            guidance.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            guidance.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
            guidance.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            guidance.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16)
        ])

        WalkTheme.dress(retry, .stageOutline, title: "重新定位", image: "location")
        retry.accessibilityIdentifier = "walkRetryReturn"
        retry.addTarget(self, action: #selector(retryLocation), for: .touchUpInside)
        WalkTheme.dress(action, .stageOutline)
        action.accessibilityIdentifier = "walkFinishReturn"
        action.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let spacer = UIView()
        for item in [status, stage, distance, bubble, notificationHint, spacer, retry, action] {
            stack.addArrangedSubview(item)
        }
        let stageWidth = stage.widthAnchor.constraint(equalTo: stack.widthAnchor)
        stageWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stageWidth,
            stage.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 330.0 / 400.0),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            distance.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            distance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            action.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            action.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            retry.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !ended && !locationFailed { scheduleFixTimeout() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        fixTimeout?.invalidate()
    }

    func didArrive() {
        ended = true
        fixTimeout?.invalidate()
        refresh()
    }

    func receive(_ event: [String: Any]) {
        guard !ended, let type = event["type"] as? String else { return }
        switch type {
        case "position":
            guard !locationFailed, let coords = event["coords"] as? [String: Any],
                  let lat = coords["latitude"] as? Double, let lon = coords["longitude"] as? Double,
                  let accuracy = coords["accuracy"] as? Double,
                  CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon)) else { return }
            guard (0...40).contains(accuracy) else {
                expireFix()
                return
            }
            let start = CLLocation(latitude: lat, longitude: lon)
            let destination = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let previous = meters
            let current = start.distance(from: destination)
            if let previous, abs(previous - current) >= 3 { lastMoveAt = Date() }
            meters = current
            let toRadians = Double.pi / 180
            let a = lat * toRadians, b = point.latitude * toRadians
            let delta = (point.longitude - lon) * toRadians
            let east = sin(delta) * cos(b)
            let north = cos(a) * sin(b) - sin(a) * cos(b) * cos(delta)
            bearing = (atan2(east, north) / toRadians + 360).truncatingRemainder(dividingBy: 360)
            fixExpired = false
            scheduleFixTimeout()
        case "heading":
            heading = event["degrees"] as? Double
        case "pause":
            meters = nil
            bearing = nil
            heading = nil
            fixExpired = false
            if !locationFailed { scheduleFixTimeout() }
        case "error":
            locationFailed = true
            fixTimeout?.invalidate()
            meters = nil
            bearing = nil
            heading = nil
            let reason = event["reason"] as? String
            if reason == "denied" {
                errorMessage = "請在 iPhone 設定允許定位，再回來重新定位。"
            } else if reason == "approximate" {
                errorMessage = "請在 iPhone 設定開啟「準確位置」，再回來重新定位。"
            } else {
                errorMessage = "請到空曠處重新定位。"
            }
        case "notificationUnavailable": notifyUnavailable = true
        default: return
        }
        refresh()
    }

    private var errorMessage = "請到空曠處重新定位。"

    private func scheduleFixTimeout() {
        fixTimeout?.invalidate()
        fixTimeout = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(expireFix),
                                         userInfo: nil, repeats: false)
    }

    @objc private func expireFix() {
        guard !ended, !locationFailed else { return }
        bearing = nil
        meters = nil
        fixExpired = true
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        retry.isHidden = ended || !(locationFailed || fixExpired)
        notificationHint.isHidden = !notifyUnavailable || ended
        if ended != (action.tag == 1) {
            // 回到原地後，「完成」換成主畫面那顆金色主按鈕。
            WalkTheme.dress(action, ended ? .stageMain : .stageOutline)
            action.tag = ended ? 1 : 0
        }
        action.setTitle(ended ? "完成" : "停止回程", for: .normal)
        distance.isHidden = ended
        distance.text = "等待定位"
        defer { styleDistance() }
        if ended {
            stage.showsArrow = false
            stage.setPose(.cheer, flip: false)
            status.text = "已抵達回程地點"
            guidance.text = "你已經回到儲存的位置。"
            return
        }
        if let meters, let bearing {
            let directions = ["北", "東北", "東", "東南", "南", "西南", "西", "西北"]
            let direction = directions[Int((bearing + 22.5) / 45) % directions.count]
            status.text = "朝\(direction)方回程"
            // 小嚮導的動作照主畫面：在背後就往回拉、在側邊就指方向、在前方且在走就一起走，停著就指前方。
            let angle = WalkStageView.norm180(bearing - (heading ?? 0))
            stage.angle = angle
            stage.heading = heading
            stage.showsArrow = true
            if heading != nil && abs(angle) > 120 { stage.setPose(.pull, flip: angle > 0) }
            else if heading != nil && abs(angle) > 35 { stage.setPose(.point, flip: angle < 0) }
            else if Date().timeIntervalSince(lastMoveAt) < 6 { stage.setPose(.walk, flip: false) }
            else { stage.setPose(.pointup, flip: false) }
            guidance.text = heading == nil ? "上方為北，箭頭指向回程地點的方位。" : "將手機朝向箭頭所指的方向。"
            distance.text = meters >= 1000 ? String(format: "距離 %.1f 公里", meters / 1000) : "距離 \(Int(meters.rounded())) 公尺"
        } else {
            stage.showsArrow = false
            stage.setPose(locationFailed || fixExpired ? .care : .idle, flip: false)
            status.text = locationFailed || fixExpired ? "暫時無法定位" : "正在取得位置"
            guidance.text = locationFailed ? errorMessage : (fixExpired ? "正在等待較準確的位置，請到空曠處再試一次。" : "取得位置後會顯示回程方向。")
        }
        if preferences.hideDistance { distance.text = "距離已隱藏" }
        distance.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: preferences.hideDistance ? "顯示距離" : "隱藏距離",
                                        target: self, selector: #selector(toggleDistance))
        ]
    }

    /// 距離跟主畫面一樣：數字大字，「距離」與單位小一號；沒有數字時用文楷。
    private func styleDistance() {
        guard let text = distance.text else { return }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: WalkTheme.sans(18, weight: .medium, style: .body), .foregroundColor: WalkTheme.soft
        ])
        let digits = (try? NSRegularExpression(pattern: "[0-9.]+"))?.matches(in: text, range: whole) ?? []
        for match in digits {
            styled.addAttributes([.font: WalkTheme.sans(48, weight: .bold, style: .largeTitle),
                                  .foregroundColor: WalkTheme.ink], range: match.range)
        }
        if digits.isEmpty {
            styled.addAttributes([.font: WalkTheme.kai(24, bold: true, style: .title2), .foregroundColor: WalkTheme.ink],
                                 range: whole)
        }
        distance.attributedText = styled
    }

    @objc private func heldDistance(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { _ = toggleDistance() }
    }

    @objc private func toggleDistance() -> Bool {
        do {
            try preferences.setHideDistance(!preferences.hideDistance)
            onChanged()
            refresh()
            UIAccessibility.post(notification: .announcement, argument: distance.text)
            return true
        } catch {
            let alert = WalkAlert(title: "無法儲存距離設定", message: "請再試一次。")
            alert.addAction(WalkAlert.Action(title: "好", style: .default))
            present(alert, animated: true)
            return false
        }
    }

    @objc private func retryLocation() {
        locationFailed = false
        fixExpired = false
        scheduleFixTimeout()
        refresh()
        onRetry()
    }

    @objc private func finish() {
        fixTimeout?.invalidate()
        if ended { onClose() } else { onStop() }
    }
}

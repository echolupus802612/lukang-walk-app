import CoreLocation
import Foundation

// Core Location delivers delegate calls on the run loop where the manager was created (here, main).
final class WalkLocation: NSObject, CLLocationManagerDelegate {
    private enum Destination: Equatable {
        case place(Int)
        case returnPoint
    }

    private struct Target {
        let destination: Destination
        let location: CLLocation
        let selectedAt: Date
    }

    var onEvent: (([String: Any]) -> Void)?
    var onArrival: ((Int, Int, Bool) -> Void)?
    var onReturnArrival: ((Int, Bool) -> Void)?
    private let preferences: WalkNavigationPreferences
    private var session: Int?
    private var target: Target?
    private var arrivalCheck = WalkArrivalCheck()
    private var manager: CLLocationManager?
    private var foreground = false
    private var lastFix = Date.distantPast
    private var lastBackgroundStart = Date.distantFuture
    private var lastForegroundStart = Date.distantPast
    private var headingStartedAt = Date.distantPast
    private var requestedPermission = false
    private var updating = false

    init(preferences: WalkNavigationPreferences = WalkNavigationPreferences()) {
        self.preferences = preferences
        super.init()
    }

    var activeTarget: (session: Int, placeID: Int)? {
        guard let session, let target, case .place(let id) = target.destination else { return nil }
        return (session, id)
    }

    var activeReturn: Int? { target?.destination == .returnPoint ? session : nil }

    func start(_ session: Int) {
        guard self.session != session else { return }
        end()
        self.session = session
        lastFix = .distantPast
        connectIfNeeded()
    }

    func setTarget(session: Int, placeID: Int, latitude: Double, longitude: Double) {
        guard self.session == session, activeReturn == nil, placeID > 0 else { return }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return }
        select(.place(placeID), coordinate: coordinate)
    }

    func startReturn(session: Int, latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let wasUpdating = updating
        // 已授權且正在定位時沿用同一個 manager，切換目的地或行程都須重新收兩筆。
        if self.session != session {
            self.session = session
            target = nil
            lastFix = .distantPast
        }
        select(.returnPoint, coordinate: coordinate)
        connectIfNeeded()
        guard foreground, updating, let manager else { return }
        // 人還站在原地時，系統可能不再送相同位置。這一筆只給新畫面顯示方位。
        if let fix = manager.location, (0...15).contains(Date().timeIntervalSince(fix.timestamp)),
           (0...40).contains(fix.horizontalAccuracy), CLLocationCoordinate2DIsValid(fix.coordinate) {
            emitPosition(fix)
        } else if wasUpdating {
            // 重新啟動現有定位服務，讓系統提供這一程的第一筆定位。
            manager.stopUpdatingLocation()
            manager.startUpdatingLocation()
        }
    }

    private func select(_ destination: Destination, coordinate: CLLocationCoordinate2D) {
        if let target, target.destination == destination,
           target.location.coordinate.latitude == coordinate.latitude,
           target.location.coordinate.longitude == coordinate.longitude { return }
        target = Target(destination: destination,
                        location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        selectedAt: Date())
        arrivalCheck = WalkArrivalCheck()
        if let manager, !manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            if foreground && updating { manager.startUpdatingLocation() }
        }
    }

    func stop(_ session: Int) {
        if self.session == session { end() }
    }

    func end() {
        disconnect()
        session = nil
        target = nil
        arrivalCheck = WalkArrivalCheck()
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        guard session != nil else { return }
        if active {
            lastForegroundStart = Date()
            emit(["type": "pause"])
            if let manager {
                headingStartedAt = Date()
                emit(["type": "heading", "degrees": NSNull()])
                if updating && CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
                applyAuthorization(manager)
            } else {
                lastFix = Date()
                connectIfNeeded()
            }
        } else if target != nil {
            lastBackgroundStart = Date()
            manager?.stopUpdatingHeading()
        } else {
            disconnect()
        }
    }

    private func disconnect() {
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager?.stopUpdatingHeading()
        manager?.allowsBackgroundLocationUpdates = false
        manager?.showsBackgroundLocationIndicator = false
        manager = nil
        updating = false
        requestedPermission = false
    }

    private func connectIfNeeded() {
        guard foreground, session != nil, manager == nil else { return }
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingOrientation = .portrait
        manager.allowsBackgroundLocationUpdates = target != nil
        manager.showsBackgroundLocationIndicator = target != nil
        headingStartedAt = Date()
        emit(["type": "heading", "degrees": NSNull()])
        applyAuthorization(manager)
    }

    private func emit(_ fields: [String: Any]) {
        guard let session else { return }
        var event = fields
        event["session"] = session
        onEvent?(event)
    }

    private func emitPosition(_ fix: CLLocation) {
        let coords = ["latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
                      "accuracy": fix.horizontalAccuracy, "speed": fix.speed]
        emit(["type": "position", "coords": coords, "timestamp": fix.timestamp.timeIntervalSince1970 * 1000])
    }

    private func fail(_ reason: String) {
        guard let session else { return }
        end()
        onEvent?(["type": "error", "reason": reason, "session": session])
    }

    private func applyAuthorization(_ manager: CLLocationManager) {
        guard self.manager === manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if foreground && !requestedPermission {
                requestedPermission = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            guard manager.accuracyAuthorization == .fullAccuracy else {
                fail("approximate")
                return
            }
            if !updating {
                updating = true
                manager.startUpdatingLocation()
                if foreground && CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
            }
        case .restricted, .denied:
            fail("denied")
        @unknown default:
            fail("unavailable")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorization(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, updating else { return }
        let now = Date()
        for fix in locations {
            let age = now.timeIntervalSince(fix.timestamp)
            let backgroundFix = !foreground || (lastBackgroundStart <= fix.timestamp && fix.timestamp <= lastForegroundStart)
            let maxAge: TimeInterval = target != nil && backgroundFix ? WalkArrivalCheck.window : 2
            guard fix.timestamp > lastFix, (0...maxAge).contains(age),
                  CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy >= 0 else { continue }
            lastFix = fix.timestamp
            if let target, let session,
               arrivalCheck.confirms(distance: fix.distance(from: target.location), accuracy: fix.horizontalAccuracy,
                                     timestamp: fix.timestamp, now: now, since: max(target.selectedAt, preferences.radiusChangedAt),
                                     radius: preferences.arrivalRadius) {
                let wasInBackground = !foreground
                end()
                switch target.destination {
                case .place(let id): onArrival?(session, id, wasInBackground)
                case .returnPoint: onReturnArrival?(session, wasInBackground)
                }
                return
            }
            guard foreground && age <= 2 else { continue }
            emitPosition(fix)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard self.manager === manager, foreground, updating else { return }
        let age = Date().timeIntervalSince(heading.timestamp)
        guard heading.timestamp >= headingStartedAt, (0...2).contains(age) else { return }
        let degrees = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        if heading.headingAccuracy >= 0 && (0..<360).contains(degrees) {
            emit(["type": "heading", "degrees": degrees])
        } else {
            emit(["type": "heading", "degrees": NSNull()])
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager else { return }
        // locationUnknown is recoverable. Let the page's 12-second first-fix timer govern fallback.
        switch (error as? CLError)?.code {
        case .locationUnknown: return
        case .headingFailure:
            if foreground { emit(["type": "heading", "degrees": NSNull()]) }
        case .denied: fail("denied")
        default: fail("unavailable")
        }
    }
}

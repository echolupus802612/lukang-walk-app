import CoreLocation
import Foundation

// Core Location delivers delegate calls on the run loop where the manager was created (here, main).
final class WalkLocation: NSObject, CLLocationManagerDelegate {
    // 系統偶爾會一次送來多筆背景定位；確認抵達的兩筆讀值都須在最近半分鐘內。
    private static let arrivalWindow: TimeInterval = 30

    private struct Target {
        let placeID: Int
        let location: CLLocation
        let selectedAt: Date
    }

    var onEvent: (([String: Any]) -> Void)?
    var onArrival: ((Int, Int, Bool) -> Void)?
    private var session: Int?
    private var target: Target?
    private var previousInsideFix: Date?
    private var manager: CLLocationManager?
    private var foreground = false
    private var lastFix = Date.distantPast
    private var lastBackgroundStart = Date.distantFuture
    private var lastForegroundStart = Date.distantPast
    private var headingStartedAt = Date.distantPast
    private var requestedPermission = false
    private var updating = false

    var activeTarget: (session: Int, placeID: Int)? {
        guard let session, let target else { return nil }
        return (session, target.placeID)
    }

    func start(_ session: Int) {
        guard self.session != session else { return }
        end()
        self.session = session
        lastFix = .distantPast
        connectIfNeeded()
    }

    func setTarget(session: Int, placeID: Int, latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard self.session == session, placeID > 0, latitude.isFinite, longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return }
        if let target, target.placeID == placeID, target.location.coordinate.latitude == latitude,
           target.location.coordinate.longitude == longitude { return }
        target = Target(placeID: placeID, location: CLLocation(latitude: latitude, longitude: longitude),
                        selectedAt: Date())
        previousInsideFix = nil
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
        previousInsideFix = nil
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
            let maxAge: TimeInterval = target != nil && backgroundFix ? Self.arrivalWindow : 2
            guard fix.timestamp > lastFix, (0...maxAge).contains(age),
                  CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy >= 0 else { continue }
            lastFix = fix.timestamp
            if let target, let session, fix.timestamp >= target.selectedAt {
                let accuracy = fix.horizontalAccuracy
                let inside = accuracy <= 40 && fix.distance(from: target.location) <= min(25 + accuracy / 2, 40)
                if inside, let previousInsideFix, now.timeIntervalSince(previousInsideFix) <= Self.arrivalWindow {
                    let wasInBackground = !foreground
                    end()
                    onArrival?(session, target.placeID, wasInBackground)
                    return
                }
                previousInsideFix = inside ? fix.timestamp : nil
            }
            guard foreground && age <= 2 else { continue }
            let coords: [String: Any] = [
                "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
                "accuracy": fix.horizontalAccuracy, "speed": fix.speed
            ]
            emit(["type": "position", "coords": coords, "timestamp": fix.timestamp.timeIntervalSince1970 * 1000])
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

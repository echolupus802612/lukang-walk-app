import Foundation

@main
struct WalkNavigationTests {
    static func main() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let prefs = WalkNavigationPreferences(folder: folder)
        precondition(prefs.returnPoint == nil && !prefs.hideDistance && prefs.arrivalRadius == 0)
        try prefs.saveReturnPoint(latitude: 24.03, longitude: 120.43)
        try prefs.setHideDistance(true)
        try prefs.setArrivalRadius(50)
        let changed = prefs.radiusChangedAt
        try prefs.setArrivalRadius(50)
        precondition(prefs.radiusChangedAt == changed)
        for invalid in [-5, 1, 26, 500] {
            do { try prefs.setArrivalRadius(invalid); preconditionFailure("Invalid radius saved") } catch {}
        }
        for invalid in [Double.nan, .infinity, -91.0, 91.0] {
            do { try prefs.saveReturnPoint(latitude: invalid, longitude: 0); preconditionFailure("Invalid point saved") } catch {}
        }
        let reopened = WalkNavigationPreferences(folder: folder)
        precondition(reopened.returnPoint == .init(latitude: 24.03, longitude: 120.43))
        precondition(reopened.hideDistance && reopened.arrivalRadius == 50)
        try reopened.clearReturnPoint()
        let cleared = WalkNavigationPreferences(folder: folder)
        precondition(cleared.returnPoint == nil && cleared.hideDistance && cleared.arrivalRadius == 50)

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var arrival = WalkArrivalCheck()
        func fix(_ second: Double, _ distance: Double, _ accuracy: Double, _ radius: Int,
                 since: Double = 0, received: Double? = nil) -> Bool {
            arrival.confirms(distance: distance, accuracy: accuracy, timestamp: base.addingTimeInterval(second),
                             now: base.addingTimeInterval(received ?? second), since: base.addingTimeInterval(since), radius: radius)
        }
        // Automatic boundaries: at 10 m accuracy the threshold is 30 m; at 40 m it is capped at 40 m.
        precondition(!fix(1, 30, 10, 0) && !fix(2, 30.1, 10, 0))
        precondition(!fix(3, 40, 40, 0) && !fix(4, 40.1, 40, 0))
        precondition(!fix(5, 40, 40, 0) && fix(6, 40, 40, 0))
        for radius in [25, 50, 100] {
            arrival = WalkArrivalCheck()
            let r = Double(radius)
            precondition(!fix(1, r + 0.1, 5, radius) && !fix(2, r, 5, radius))
            precondition(!fix(3, r, 41, radius) && !fix(4, r, 40, radius) && fix(5, r, 40, radius))
        }
        arrival = WalkArrivalCheck()
        precondition(!fix(1, 10, 2, 25))
        precondition(!fix(2, 10, 2, 100, since: 2.5, received: 4))
        precondition(!fix(3, 10, 2, 100, since: 2.5) && !fix(3, 10, 2, 100, since: 2.5))
        precondition(fix(4, 10, 2, 100, since: 2.5))
        // Background batched fixes: both must be distinct and at most thirty seconds old.
        arrival = WalkArrivalCheck()
        precondition(!fix(1, 1, 5, 0, received: 40) && !fix(11, 1, 5, 0, received: 40))
        precondition(fix(35, 1, 5, 0, received: 40))
        print("Walk navigation preferences, radius boundaries, and two-fix confirmation passed")
    }
}

import Foundation

final class WalkNavigationPreferences {
    struct Point: Codable, Equatable {
        let latitude: Double
        let longitude: Double

        var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    }

    private struct Values: Codable, Equatable {
        var returnPoint: Point?
        var hideDistance = false
        var arrivalRadius = 0
    }

    private enum InvalidSetting: Error { case point, radius }

    private let folder: URL
    private var file: URL { folder.appendingPathComponent("preferences.json") }
    private var values = Values()
    private(set) var radiusChangedAt = Date.distantPast
    var returnPoint: Point? { values.returnPoint }
    var hideDistance: Bool { values.hideDistance }
    var arrivalRadius: Int { values.arrivalRadius }

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("Walk/Navigation", isDirectory: true)
        if let saved = try? read() { values = saved }
    }

    func saveReturnPoint(latitude: Double, longitude: Double) throws {
        let point = Point(latitude: latitude, longitude: longitude)
        guard point.isValid else { throw InvalidSetting.point }
        try update { $0.returnPoint = point }
    }

    func clearReturnPoint() throws { try update { $0.returnPoint = nil } }
    func setHideDistance(_ value: Bool) throws { try update { $0.hideDistance = value } }

    func setArrivalRadius(_ value: Int) throws {
        guard [0, 25, 50, 100].contains(value) else { throw InvalidSetting.radius }
        try update { $0.arrivalRadius = value }
    }

    private func read() throws -> Values {
        do {
            let saved = try JSONDecoder().decode(Values.self, from: Data(contentsOf: file))
            guard saved.returnPoint?.isValid != false, [0, 25, 50, 100].contains(saved.arrivalRadius) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return saved
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return Values()
        }
    }

    private func update(_ change: (inout Values) -> Void) throws {
        let previous = try read()
        var next = previous
        change(&next)
        if next != previous {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var directory = folder
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if next.arrivalRadius != values.arrivalRadius { radiusChangedAt = Date() }
        values = next
    }
}

struct WalkArrivalCheck {
    static let window: TimeInterval = 30
    private var previousInsideFix: Date?

    // 目標或半徑切換前的讀值不能算進新設定，即使系統稍後才整批送來。
    mutating func confirms(distance: Double, accuracy: Double, timestamp: Date, now: Date,
                           since: Date, radius: Int) -> Bool {
        guard timestamp >= since, (0...Self.window).contains(now.timeIntervalSince(timestamp)) else { return false }
        if let previousInsideFix, timestamp <= previousInsideFix { return false }
        let threshold = radius == 0 ? min(25 + accuracy / 2, 40) : Double(radius)
        guard (0...40).contains(accuracy), distance >= 0, distance <= threshold else {
            previousInsideFix = nil
            return false
        }
        let previous = previousInsideFix
        previousInsideFix = timestamp
        guard let previous else { return false }
        return previous >= since && now.timeIntervalSince(previous) <= Self.window
    }
}
